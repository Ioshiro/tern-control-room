--!strict
-- Control Room, host half: the Archive's search. Two layers, merged per word:
--
-- 1. Instant, on every key: each closed session is indexed once per catalog
--    (folded title, project, directory, handoff note, recap, last prompt, and
--    the words of the title, project and note). A word scores by the best field
--    it is found in, more at a word start than inside a word, less as a typo
--    (bounded edit distance against the indexed words).
-- 2. Deep, shortly after typing stops: the window half searches every prompt
--    you ever sent with omp's own FTS5 index (BM25, prefix match) and every
--    recap. Words that start no word of the catalog are sent with up to three
--    close words from it, so a typo still reaches the index.
--
-- Every word must match somewhere (in either layer). Ties break on recency.

local common = require("./common")

type Session = common.Session

local archive = {}

local W_TITLE, W_PROJECT, W_NOTE, W_RECAP, W_CWD, W_PROMPT = 8, 6, 5, 3, 2, 2
local Q_START, Q_INSIDE, Q_TYPO = 1.0, 0.7, 0.5
-- Recency adds up to this much, halving every HALF_LIFE_DAYS.
local RECENCY, HALF_LIFE_DAYS = 1.5, 14
local MAX_VARIANTS = 3

export type Doc = {
	s: Session,
	project: string,
	--- Folded fields.
	title: string,
	proj: string,
	cwd: string,
	note: string,
	recap: string,
	prompt: string,
	--- Words of the title, project and note (for typos).
	words: { string },
}

export type Index = {
	docs: { Doc },
	--- Every word (3+ characters) of the catalog, with how many sessions use it.
	vocab: { [string]: number },
}

--- Per word of the query: the deep layer's best score and snippet for each session.
export type Deep = { [number]: { [string]: { w: number, x: string? } } }

export type Ranked = {
	doc: Doc,
	score: number,
	--- The best prompt snippet the deep layer found for it.
	snippet: string?,
}

local function words_of(s: string, into: { string }?, seen: { [string]: boolean })
	for w in string.gmatch(s, "[%w\128-\255]+") do
		if #w >= 3 and not seen[w] then
			seen[w] = true
			if into then
				table.insert(into, w)
			end
		end
	end
end

function archive.project_of(cwd: string?): string
	return if cwd and cwd ~= "" then common.basename(cwd) else "(unknown directory)"
end

--- Indexes a catalog; done once per catalog, not per key.
function archive.index(sessions: { Session }): Index
	local docs: { Doc } = {}
	local vocab: { [string]: number } = {}
	for _, s in sessions do
		local project = archive.project_of(s.cwd)
		local doc: Doc = {
			s = s,
			project = project,
			title = common.fold(s.title or ""),
			proj = common.fold(project),
			cwd = common.fold(s.cwd or ""),
			note = common.fold(s.note or ""),
			recap = common.fold(s.recap or ""),
			prompt = common.fold(s.prompt or ""),
			words = {},
		}
		local seen: { [string]: boolean } = {}
		words_of(doc.title, doc.words, seen)
		words_of(doc.proj, doc.words, seen)
		words_of(doc.note, doc.words, seen)
		words_of(doc.recap, nil, seen)
		words_of(doc.prompt, nil, seen)
		for w in seen do
			vocab[w] = (vocab[w] or 0) + 1
		end
		table.insert(docs, doc)
	end
	return { docs = docs, vocab = vocab }
end

--- Levenshtein distance of `a` and `b` when it is at most `k`, else `k + 1`.
local function distance(a: string, b: string, k: number): number
	local la, lb = #a, #b
	if math.abs(la - lb) > k then
		return k + 1
	end
	local prev: { number } = table.create(lb + 1, 0)
	local cur: { number } = table.create(lb + 1, 0)
	for j = 0, lb do
		prev[j + 1] = j
	end
	for i = 1, la do
		cur[1] = i
		local best = i
		local ca = string.byte(a, i)
		for j = 1, lb do
			local cost = if ca == string.byte(b, j) then 0 else 1
			local v = math.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
			cur[j + 1] = v
			if v < best then
				best = v
			end
		end
		if best > k then
			return k + 1
		end
		prev, cur = cur, prev
	end
	return prev[lb + 1]
end

--- Edits a typo of `term` may have: none under 4 characters, one up to 7, two from 8.
local function typo_budget(term: string): number
	return if #term < 4 then 0 elseif #term < 8 then 1 else 2
end

--- Whether `w` is `term` mistyped: the whole word, or its start (`swager` for `swagger`).
local function near(term: string, w: string, k: number): number
	local d = distance(term, w, k)
	if d > k and #w > #term then
		d = distance(term, string.sub(w, 1, #term), k)
	end
	return d
end

local function find_quality(field: string, term: string): number
	local at = 1
	local best = 0
	while true do
		local p = string.find(field, term, at, true)
		if p == nil then
			return best
		end
		local before = if p > 1 then string.sub(field, p - 1, p - 1) else ""
		if before == "" or string.match(before, "[%w\128-\255]") == nil then
			return Q_START
		end
		best = Q_INSIDE
		at = p + 1
	end
end

local function typo_quality(doc: Doc, term: string): number
	local k = typo_budget(term)
	if k == 0 then
		return 0
	end
	for _, w in doc.words do
		if near(term, w, k) <= k then
			return Q_TYPO
		end
	end
	return 0
end

--- The instant layer's score of `term` in `doc`, 0 when absent.
local function instant(doc: Doc, term: string): number
	local best = 0
	local function field(text: string, weight: number)
		if weight * Q_START <= best or text == "" then
			return
		end
		local q = find_quality(text, term)
		if q * weight > best then
			best = q * weight
		end
	end
	field(doc.title, W_TITLE)
	field(doc.proj, W_PROJECT)
	field(doc.note, W_NOTE)
	field(doc.recap, W_RECAP)
	field(doc.cwd, W_CWD)
	field(doc.prompt, W_PROMPT)
	if best == 0 then
		local q = typo_quality(doc, term)
		if q > 0 then
			best = q * W_TITLE * 0.6
		end
	end
	return best
end

local function recency(at: number, now: number): number
	local days = math.max(0, now - at) / 86400
	return RECENCY * 0.5 ^ (days / HALF_LIFE_DAYS)
end

--- The deep layer's hits, by word and session: a prompt hit scores by BM25 and how many
--- prompts matched, a recap hit as a recap field does.
function archive.deep(hits: { common.Hit }): Deep
	local out: Deep = {}
	for _, h in hits do
		local per = out[h.t]
		if per == nil then
			per = {}
			out[h.t] = per
		end
		local w = if h.k == "r"
			then W_RECAP * Q_INSIDE
			else 1.5 + math.min(3, h.w * 0.4) + math.min(1.5, 0.5 * math.log(h.n + 1))
		local cur = per[h.s]
		if cur == nil then
			per[h.s] = { w = w, x = if h.k == "p" then h.x else nil }
		else
			cur.w = math.max(cur.w, w)
			if cur.x == nil and h.k == "p" then
				cur.x = h.x
			end
		end
	end
	return out
end

--- The sessions matching every word of `terms`, best first; all of them, newest first, when there are none.
function archive.rank(index: Index, terms: { string }, deep: Deep?): { Ranked }
	local now = os.time()
	local out: { Ranked } = {}
	for _, doc in index.docs do
		local total = 0
		local snippet: string? = nil
		local hit_all = true
		for t, term in terms do
			local score = instant(doc, term)
			local d = if deep and deep[t] then deep[t][doc.s.id] else nil
			if d then
				-- Found in a prompt or a recap beyond what the catalog keeps.
				score = math.max(score, d.w)
				snippet = snippet or d.x
			end
			if score == 0 then
				hit_all = false
				break
			end
			total += score
		end
		if hit_all then
			table.insert(out, { doc = doc, score = total + recency(doc.s.at, now), snippet = snippet })
		end
	end
	table.sort(out, function(a: Ranked, b: Ranked): boolean
		if #terms > 0 and a.score ~= b.score then
			return a.score > b.score
		end
		if a.doc.s.at ~= b.doc.s.at then
			return a.doc.s.at > b.doc.s.at
		end
		return a.doc.s.id < b.doc.s.id
	end)
	return out
end

--- For the deep layer: each word, plus up to three close words of the catalog when the
--- word starts none of them (a likely typo).
function archive.variants(index: Index, terms: { string }): { { string } }
	local out: { { string } } = {}
	for _, term in terms do
		local list = { term }
		local k = typo_budget(term)
		local known = false
		if k > 0 then
			for w in index.vocab do
				if string.sub(w, 1, #term) == term then
					known = true
					break
				end
			end
		end
		if k > 0 and not known then
			local close: { { w: string, d: number, n: number } } = {}
			for w, count in index.vocab do
				local d = near(term, w, k)
				if d <= k then
					table.insert(close, { w = w, d = d, n = count })
				end
			end
			table.sort(close, function(a, b): boolean
				if a.d ~= b.d then
					return a.d < b.d
				end
				return a.n > b.n
			end)
			for i = 1, math.min(MAX_VARIANTS, #close) do
				table.insert(list, close[i].w)
			end
		end
		table.insert(out, list)
	end
	return out
end

return archive
