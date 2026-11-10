--!strict
-- Shared by both halves: the block kind, the snapshot the window half sends
-- to the block, how a row is classified, the link scheme the block uses to
-- ask the window half for actions, and the Archive's types and search words.
--
-- Data flows one way each:
--   window -> block: `cx.session:event(block, {ev = "action", act = <what>, value = json})`
--                    (`snapshot`, `peek`, `catalog`, `hits`, `speek`)
--   block -> window: `cx:open("control-room://<verb>[/<target>[/<nonce>]]")`, claimed by
--                    the window half's `tern.route.link`; the target is a pane id, an omp
--                    session id or a URL-safe base64 search query.

local common = {}

common.KIND = "control-room.room"
common.SCHEME = "control-room://"

export type Last = { line: string, status: number, took_ms: number }

export type Agent = {
	--- `idle`, `working`, `waiting_input` or `exited`, as `cx.agents:list()` reports it.
	state: string,
	model: string?,
	command: string?,
	--- The agent's last assistant message, clipped.
	message: string?,
	--- Why a queued prompt could not be delivered.
	delivery_error: string?,
	--- When its last turn ended as `failed` (`agent_finished`), until it works again.
	failed_at: number?,
}

--- One pane as Tern reports it. Every field is read from Tern when the snapshot
--- is taken, except the `*_at` times (seconds, `os.time()`), which the window
--- half records when it sees things change.
export type Row = {
	pane: number,
	kind: string,
	title: string,
	program: string?,
	cwd: string,
	session: number?,
	tab: number?,
	tab_pos: number?,
	tab_name: string?,
	parked: boolean,
	--- Shown as a picture-in-picture over another pane.
	floating: boolean?,
	focused: boolean,
	busy: boolean,
	running: { line: string, ms: number }?,
	last: Last?,
	exited: number?,
	error: string?,
	alert: boolean,
	agent: Agent?,
	--- Last time anything Tern reports about the pane changed.
	active_at: number?,
	--- Last time its command finished.
	finished_at: number?,
	--- Last time the agent's last message changed.
	message_at: number?,
	--- The update Control Room asked the agent for, while its reply is worth showing:
	--- from the request until a later turn ends with something newer than the reply.
	update: Update?,
	--- When Control Room asked the agent for a handoff note before closing it (`archive`).
	archiving: number?,
}

--- `reply` is the agent's own text, as its transcript (or last message) holds it.
export type Update = { asked_at: number, reply: string?, reply_at: number? }

--- A failed command, as a `command_finished` event reported it.
export type Failure = { pane: number, title: string, line: string, status: number, took_ms: number, at: number }

export type SessionRef = { id: number, name: string, current: boolean }

export type Snapshot = { at: number, rows: { Row }, sessions: { SessionRef }, failures: { Failure } }

--- One chat message of an agent's transcript, clipped.
export type Chat = { role: string, text: string }

--- What a pane shows, read once on request (`control-room://peek/<pane>`): the last
--- lines of a terminal or agent, a plugin block's text, and an agent's last exchanges.
export type Peek = {
	pane: number,
	at: number,
	kind: string?,
	lines: { string }?,
	--- Lines above the ones returned.
	more: number?,
	text: string?,
	chat: { Chat }?,
	error: string?,
}

--- One omp session no running omp holds, as `history.db` and the session files report it.
export type Session = {
	id: string,
	title: string?,
	--- The directory of its last prompt (else of its last recap).
	cwd: string?,
	--- Last activity: its newest prompt, recap or handoff note (seconds).
	at: number,
	--- Prompts recorded for it.
	prompts: number,
	--- omp's latest recap of it, clipped.
	recap: string?,
	recap_at: number?,
	--- Its last prompt, clipped.
	prompt: string?,
	--- The handoff note the agent wrote when Control Room archived it.
	note: string?,
	note_at: number?,
}

--- The Archive: closed sessions, newest first. `open` counts those left out because an omp
--- holds them; `lease` is false when that could not be checked (all are listed then).
export type Catalog = { at: number, sessions: { Session }, open: number, lease: boolean, error: string? }

--- A search hit for word `t` (1-based, in `common.terms` order) in session `s`: `k` is `p`
--- (your prompts, BM25 weight `w`) or `r` (a recap); `n` counts the hits, `x` is the best
--- snippet (prompt snippets mark the match with `\2`…`\3`).
export type Hit = { t: number, s: string, k: string, w: number, n: number, x: string? }

export type Hits = { query: string, hits: { Hit }, error: string? }

export type Said = { text: string, at: number }

--- A closed session's last prompts and recaps, read on request (`control-room://speek/<id>`).
export type SessionPeek = { id: string, at: number, prompts: { Said }?, recaps: { Said }?, error: string? }
--- Where a row stands: `attention`, `running`, `waiting` or `idle` (the order rows sort in).
export type Status = { level: string, rank: number, tone: string, text: string }

local RANK: { [string]: number } = { attention = 1, running = 2, waiting = 3, idle = 4 }

--- A pane id as text; ids are exact integers below 2^53.
function common.id(pane: number): string
	return string.format("%.0f", pane)
end

--- `control-room://<verb>[/<target>[/<nonce>]]`; a numeric target is a pane id.
function common.url(verb: string, target: (number | string)?, nonce: string?): string
	local url = common.SCHEME .. verb
	if target ~= nil then
		url ..= "/" .. (if type(target) == "number" then common.id(target) else target)
		if nonce then
			url ..= "/" .. nonce
		end
	end
	return url
end

--- Verb, target and nonce of a control-room link; a nil verb for any other link.
function common.parse(url: string): (string?, string?, string?)
	if string.sub(url, 1, #common.SCHEME) ~= common.SCHEME then
		return nil, nil, nil
	end
	local verb, target, nonce = string.match(string.sub(url, #common.SCHEME + 1), "^([%a_]+)/?([%w%-_]*)/?(%w*)/?$")
	if verb == nil then
		return nil, nil, nil
	end
	return verb, if target ~= "" then target else nil, if nonce ~= "" then nonce else nil
end

-- Latin-1 letters with accents (UTF-8 `\xC3` + one byte) and the ASCII letter they fold to.
local FOLD: { [string]: string } = {}
for _, r in { { 0x80, 0x85, "a" }, { 0x87, 0x87, "c" }, { 0x88, 0x8B, "e" }, { 0x8C, 0x8F, "i" }, { 0x91, 0x91, "n" }, { 0x92, 0x96, "o" }, { 0x99, 0x9C, "u" }, { 0xA0, 0xA5, "a" }, { 0xA7, 0xA7, "c" }, { 0xA8, 0xAB, "e" }, { 0xAC, 0xAF, "i" }, { 0xB1, 0xB1, "n" }, { 0xB2, 0xB6, "o" }, { 0xB9, 0xBC, "u" } } :: { { any } } do
	for b = r[1], r[2] do
		FOLD["\xC3" .. string.char(b)] = r[3]
	end
end

--- `s` lowercased, with accented Latin letters folded to plain ones (`Perché` → `perche`).
function common.fold(s: string): string
	return (string.gsub(string.lower(s), "\xC3[\x80-\xBF]", FOLD))
end

--- The words a search looks for: folded, split at anything but letters and digits, without
--- repeats, at most 8; one-letter words only when there is nothing longer.
function common.terms(query: string): { string }
	local out: { string } = {}
	local short: { string } = {}
	local seen: { [string]: boolean } = {}
	for w in string.gmatch(common.fold(query), "[%w\x80-\xFF]+") do
		if not seen[w] then
			seen[w] = true
			table.insert(if #w >= 2 then out else short, w)
		end
	end
	if #out == 0 then
		out = short
	end
	while #out > 8 do
		table.remove(out)
	end
	return out
end

--- At most `n` characters of `s`, cut at a character boundary, with an ellipsis when cut.
function common.cut(s: string, n: number): string
	local len = utf8.len(s)
	if len == nil or len <= n then
		return s
	end
	local stop = utf8.offset(s, n + 1) or (#s + 1)
	return string.sub(s, 1, stop - 1) .. "…"
end

--- `s` on one trimmed line, at most `n` characters.
function common.clip(s: string, n: number): string
	local one = string.gsub(s, "%s+", " ")
	return common.cut(string.match(one, "^ ?(.-) ?$") or one, n)
end

--- The last component of a path, either separator.
function common.basename(path: string): string
	local trimmed = string.gsub(path, "[/\\]+$", "")
	return string.match(trimmed, "([^/\\]+)$") or trimmed
end

--- Identifies the problem a row shows (a failed last command, a nonzero exit), so an
--- acknowledgement covers that one run only; nil when there is none.
function common.problem(row: Row): string?
	if row.exited ~= nil and row.exited ~= 0 then
		return "exit|" .. row.exited
	end
	local agent = row.agent
	if agent and agent.failed_at then
		return "turn|" .. agent.failed_at
	end
	local last = row.last
	if last == nil or last.status == 0 or row.running ~= nil or agent ~= nil then
		return nil
	end
	return string.format("cmd|%s|%d|%d", last.line, last.status, last.took_ms)
end

local function status(level: string, tone: string, text: string): Status
	return { level = level, rank = RANK[level], tone = tone, text = text }
end

--- Where a row stands, from Tern's facts alone. `acks` maps pane ids to the
--- problem (see `problem`) the user acknowledged.
function common.classify(row: Row, acks: { [string]: string }): Status
	local problem = common.problem(row)
	local acked = problem ~= nil and acks[common.id(row.pane)] == problem
	if row.error then
		return status("attention", "error", "failed to start: " .. common.clip(row.error, 80))
	end
	local agent = row.agent
	if agent then
		if row.archiving then
			return status("running", "accent", "archiving: writing its handoff note")
		end
		if agent.delivery_error then
			return status("attention", "error", "prompt not delivered: " .. common.clip(agent.delivery_error, 80))
		elseif agent.state == "waiting_input" then
			return status("attention", "warning", "needs your input")
		elseif agent.state == "working" then
			return status("running", "accent", "working")
		elseif agent.state == "exited" or row.exited ~= nil then
			if problem and not acked then
				return status("attention", "error", "exited " .. (row.exited or 0))
			end
			return status("idle", "muted", "exited")
		elseif agent.failed_at and not acked then
			return status("attention", "error", "turn failed")
		elseif row.alert then
			return status("attention", "warning", "turn finished, not seen yet")
		end
		return status("waiting", "pending", "waiting for a prompt")
	end
	if row.exited ~= nil then
		if problem and not acked then
			return status("attention", "error", "exited " .. row.exited)
		end
		return status("idle", "muted", "exited")
	end
	local running = row.running
	if running then
		return status("running", "accent", "running " .. common.clip(running.line, 60))
	end
	if row.busy then
		return status("running", "accent", "busy")
	end
	if problem and not acked then
		return status("attention", "error", "failed, exit " .. (row.last :: Last).status)
	end
	if row.alert then
		return status("attention", "warning", "alert, not seen yet")
	end
	return status("idle", "muted", "idle")
end

--- Acknowledged problems by pane id, kept in `tern.kv` under `acks`.
function common.acks(): { [string]: string }
	local ok, value = pcall(tern.kv.get, "acks")
	return if ok and type(value) == "table" then value else {}
end

--- `1.2s`, `3m 05s`, `1h 02m`.
function common.duration(ms: number): string
	local s = ms / 1000
	if s < 60 then
		return string.format("%.1fs", s)
	elseif s < 3600 then
		return string.format("%dm %02ds", s // 60, s % 60)
	end
	return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
end

--- How long ago `t` (seconds, `os.time()`) was: `now`, `12s`, `5m`, `3h`, `2d`.
function common.ago(t: number?): string
	if t == nil then
		return ""
	end
	local s = math.max(0, os.time() - t)
	if s < 5 then
		return "now"
	elseif s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return s // 60 .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	end
	return s // 86400 .. "d"
end

return common
