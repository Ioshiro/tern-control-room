--!strict
-- Control Room, window half: the Archive's data. Closed omp sessions come from
-- omp's own records, read-only: `history.db` (session titles, recaps, every
-- prompt with its session, and the FTS5 index omp keeps over the prompts) and
-- the names of the session files. A running omp holds a lease on each session
-- it writes; `omp session lease` reports those without taking them, so the
-- sessions still open anywhere stay out of the Archive.
--
-- Queries run off the UI thread (`cx.db`) and each callback does one bounded
-- step, as the window half's 50 ms budget requires.

local common = require("./common")

local sessions = {}

--- What the window sends a block: `act` and its JSON body.
export type Send = (cx: WindowCx, act: string, body: string) -> ()

-- The prompt the close-and-archive action sends starts with this tag and a
-- nonce, so its row in `history.db` names the session the note belongs to.
sessions.HANDOFF_TAG = "Control Room handoff [cr-"
local STATUS_PREFIX = "Status check from Control Room"
local CATALOG_ROWS = 2000
local LEASE_BATCH = 200
local LEASE_TIMEOUT_MS = 20000
local FTS_ROWS = 600
local NOTE_CHARS = 1500
local KEEP_NOTES = 300
local PEEK_PROMPTS = 6
local PEEK_RECAPS = 3

local db: Database? = nil
-- Session file by session id, from the last listing of the sessions directory.
local paths: { [string]: string } = {}
-- Directory of each catalogued session, for resuming it there.
local cwds: { [string]: string } = {}
local catalog_running = false

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

local function agent_dir(): string?
	local dir = tern.getenv("PI_CODING_AGENT_DIR")
	if dir and dir ~= "" then
		return dir
	end
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	return if home and home ~= "" then home .. "/.omp/agent" else nil
end

--- A session id as omp writes them (UUIDs, older hex ids); anything else is refused.
function sessions.valid_id(id: string?): boolean
	return id ~= nil and #id <= 64 and string.match(id, "^[%w%-]+$") ~= nil
end

--- Runs `sql` on omp's `history.db` (read-only), opening it the first time.
local function query(cx: WindowCx, sql: string, limit: number, done: (rows: { { DbCell } }?, err: string?, cx: WindowCx?) -> ())
	local function run(handle: Database, on: WindowCx)
		local ok, pending = pcall(function()
			return on.db:query(handle, sql, { limit = limit })
		end)
		if not ok then
			db = nil
			done(nil, tostring(pending), on)
			return
		end
		(pending :: Awaitable<DbResult>):next(function(result: DbResult?, err: string?, later: WindowCx?)
			if result == nil then
				-- A dropped handle reopens on the next query.
				db = nil
				done(nil, err or "query failed", later)
				return
			end
			done(result.rows, nil, later)
		end)
	end
	if db then
		run(db, cx)
		return
	end
	local dir = agent_dir()
	if dir == nil then
		done(nil, "omp's directory is unknown (no USERPROFILE or HOME)", cx)
		return
	end
	local ok, pending = pcall(function()
		return cx.db:open(dir .. "/history.db")
	end)
	if not ok then
		done(nil, tostring(pending), cx)
		return
	end
	(pending :: Awaitable<Database>):next(function(handle: Database?, err: string?, later: WindowCx?)
		if handle == nil or later == nil then
			done(nil, err or "history.db could not be opened", later)
			return
		end
		db = handle
		run(handle, later)
	end)
end

--- Session files by id: `<sessions>/<project>/<timestamp>_<id>.jsonl`.
local function list_files(): number
	local dir = agent_dir()
	if dir == nil then
		return 0
	end
	local root = dir .. "/sessions"
	local found: { [string]: string } = {}
	local count = 0
	local ok, projects = pcall(tern.fs.list, root)
	if not ok then
		return 0
	end
	for _, project in projects :: { string } do
		local listed, names = pcall(tern.fs.list, root .. "/" .. project)
		if listed then
			for _, name in names :: { string } do
				local id = string.match(name, "_([%w%-]+)%.jsonl$")
				if id then
					found[id] = root .. "/" .. project .. "/" .. name
					count += 1
				end
			end
		end
	end
	paths = found
	return count
end

local function omp_exe(): string
	-- Tern ships omp beside itself on Windows; elsewhere (or without it) PATH decides.
	local local_app = tern.getenv("LOCALAPPDATA")
	if local_app then
		local bundled = local_app .. "\\Tern\\omp\\bin\\omp.exe"
		local ok, there = pcall(tern.fs.exists, bundled)
		if ok and there then
			return bundled
		end
	end
	return "omp"
end

--- The ids among `ids` some running omp holds, asked `LEASE_BATCH` at a time; nil when that could not be checked.
local function leases(ids: { string }, done: (held: { [string]: boolean }?, err: string?, cx: WindowCx?) -> ())
	local held: { [string]: boolean } = {}
	local exe = omp_exe()
	local function batch(from: number, latest: WindowCx?)
		if from > #ids then
			done(held, nil, latest)
			return
		end
		local argv = { exe, "session", "lease", "--json", "--" }
		for i = from, math.min(#ids, from + LEASE_BATCH - 1) do
			table.insert(argv, ids[i])
		end
		local ok, err = pcall(function()
			tern.process.run(argv, { timeout_ms = LEASE_TIMEOUT_MS }, function(result: ProcessResult, cx: WindowCx?)
				local parsed, value = pcall(tern.json.decode, result.stdout)
				if result.status ~= 0 or not parsed or type(value) ~= "table" or type(value.held) ~= "table" then
					done(nil, common.clip(if result.stderr ~= "" then result.stderr else "omp session lease failed", 200), cx)
					return
				end
				for _, id in value.held do
					held[id] = true
				end
				batch(from + LEASE_BATCH, cx)
			end)
		end)
		if not ok then
			done(nil, tostring(err), nil)
		end
	end
	batch(1, nil)
end

--- Sessions an omp pane of Tern shows, from `tern inspect` (it names each pane's omp session
--- file): a resumed omp may not hold the lease until its first turn. Empty when it fails.
local function open_in_tern(done: (shown: { [string]: boolean }) -> ())
	local exe = tern.getenv("TERN_EXE")
	local argv = { if exe and exe ~= "" then exe else "tern", "inspect", "--json" }
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = LEASE_TIMEOUT_MS }, function(result: ProcessResult, _cx: WindowCx?)
			local shown: { [string]: boolean } = {}
			local parsed, value = pcall(tern.json.decode, result.stdout)
			if result.status == 0 and parsed and type(value) == "table" and type(value.panes) == "table" then
				for _, p in value.panes do
					local file = if type(p) == "table" then p.omp_session_file else nil
					local id = if type(file) == "string" then string.match(file, "_([%w%-]+)%.jsonl$") else nil
					if id then
						shown[id] = true
					end
				end
			end
			done(shown)
		end)
	end)
	if not ok then
		done({})
	end
end

--- Handoff notes by session id. Notes are kept under their nonce until the prompt
--- that asked for them shows up in `history.db`, which names the session.
local function notes_by_session(handoffs: { { DbCell } }): { [string]: { text: string, at: number } }
	local ok, stored = pcall(tern.kv.get, "notes")
	local notes: { [string]: any } = if ok and type(stored) == "table" then stored else {}
	local owner: { [string]: string } = {}
	for _, row in handoffs do
		local sid, prompt = str(row[1]), str(row[2])
		local nonce = if prompt then string.match(prompt, "%[cr%-(%w+)%]") else nil
		if sid and nonce then
			owner[nonce] = sid
		end
	end
	local out: { [string]: { text: string, at: number } } = {}
	local changed = false
	for key, note in notes do
		if type(note) == "table" and type(note.text) == "string" then
			local sid = note.sid or owner[key]
			if sid and note.sid == nil then
				note.sid = sid
				changed = true
			end
			if sid and (out[sid] == nil or out[sid].at < (note.at or 0)) then
				out[sid] = { text = note.text, at = note.at or 0 }
			end
		end
	end
	if changed then
		pcall(tern.kv.set, "notes", notes)
	end
	return out
end

--- Keeps the agent's reply to a handoff request, under the request's nonce.
function sessions.keep_note(nonce: string, text: string)
	local ok, stored = pcall(tern.kv.get, "notes")
	local notes: { [string]: any } = if ok and type(stored) == "table" then stored else {}
	-- The agent may repeat the request's tag; it means nothing to whoever reads the note.
	local clean = string.gsub(text, "%s*%[cr%-%w+%]", "")
	notes[nonce] = { text = common.cut(clean, NOTE_CHARS), at = os.time() }
	-- Forget the oldest beyond KEEP_NOTES.
	local keys: { string } = {}
	for key in notes do
		table.insert(keys, key)
	end
	if #keys > KEEP_NOTES then
		table.sort(keys, function(a: string, b: string): boolean
			return (notes[a].at or 0) > (notes[b].at or 0)
		end)
		for i = KEEP_NOTES + 1, #keys do
			notes[keys[i]] = nil
		end
	end
	pcall(tern.kv.set, "notes", notes)
end

local CATALOG_SQL = string.format(
	[[
WITH h AS (
  SELECT session_id AS sid, max(created_at) AS at, count(*) AS n,
    max(CASE WHEN prompt NOT LIKE '%s%%' AND prompt NOT LIKE '%s%%' THEN id END) AS last_id,
    max(id) AS any_id
  FROM history WHERE session_id IS NOT NULL GROUP BY session_id),
r AS (SELECT session_id AS sid, max(id) AS rid, max(created_at) AS at FROM session_recaps GROUP BY session_id),
ids AS (SELECT sid FROM h UNION SELECT sid FROM r)
SELECT ids.sid, substr(t.title, 1, 160), coalesce(hc.cwd, rc.cwd),
  max(coalesce(h.at, 0), coalesce(r.at, 0)) AS at, coalesce(h.n, 0),
  substr(rc.recap, 1, 700), rc.created_at, substr(hl.prompt, 1, 300)
FROM ids
LEFT JOIN h ON h.sid = ids.sid
LEFT JOIN r ON r.sid = ids.sid
LEFT JOIN session_titles t ON t.session_id = ids.sid
LEFT JOIN session_recaps rc ON rc.id = r.rid
LEFT JOIN history hl ON hl.id = h.last_id
LEFT JOIN history hc ON hc.id = h.any_id
ORDER BY at DESC]],
	sessions.HANDOFF_TAG,
	STATUS_PREFIX
)

local HANDOFF_SQL = string.format(
	"SELECT session_id, substr(prompt, 1, 60) FROM history WHERE prompt LIKE '%s%%' AND session_id IS NOT NULL",
	sessions.HANDOFF_TAG
)

--- Reads the Archive (closed sessions, newest first) and sends it as `catalog`.
function sessions.catalog(cx: WindowCx, send: Send)
	if catalog_running then
		return
	end
	catalog_running = true
	local function fail(on: WindowCx?, err: string)
		catalog_running = false
		tern.log.warn("control-room: archive catalog failed", err)
		if on then
			send(on, "catalog", tern.json.encode({ at = os.time(), sessions = tern.json.array({}), open = 0, lease = false, error = err }))
		end
	end
	query(cx, CATALOG_SQL, CATALOG_ROWS, function(rows: { { DbCell } }?, err: string?, c1: WindowCx?)
		if rows == nil or c1 == nil then
			fail(c1, err or "history.db is not available")
			return
		end
		query(c1, HANDOFF_SQL, 1000, function(handoffs: { { DbCell } }?, _err: string?, c2: WindowCx?)
			if c2 == nil then
				catalog_running = false
				return
			end
			-- Native file listing and Lua work over the rows: one bounded step.
			local notes = notes_by_session(handoffs or {})
			list_files()
			local list: { common.Session } = {}
			local ids: { string } = {}
			for _, row in rows do
				local id = str(row[1])
				if id and paths[id] then
					local cwd = str(row[3])
					local note = notes[id]
					local recap_at = num(row[7])
					local session: common.Session = {
						id = id,
						title = str(row[2]),
						cwd = cwd,
						at = math.max(num(row[4]) or 0, if note then note.at else 0),
						prompts = num(row[5]) or 0,
						recap = str(row[6]),
						recap_at = recap_at,
						prompt = str(row[8]),
						note = if note then note.text else nil,
						note_at = if note then note.at else nil,
					}
					if cwd then
						cwds[id] = cwd
					end
					table.insert(list, session)
					table.insert(ids, id)
				end
			end
			leases(ids, function(held: { [string]: boolean }?, lease_err: string?, _c3: WindowCx?)
				-- A resumed omp may not hold its lease yet: Tern's own panes say what is open too.
				open_in_tern(function(shown: { [string]: boolean })
					catalog_running = false
					local closed: { common.Session } = tern.json.array({})
					local open = 0
					for _, s in list do
						if (held and held[s.id]) or shown[s.id] then
							open += 1
						else
							table.insert(closed, s)
						end
					end
					table.sort(closed, function(a: common.Session, b: common.Session): boolean
						return a.at > b.at
					end)
					local catalog: common.Catalog = { at = os.time(), sessions = closed, open = open, lease = held ~= nil, error = lease_err }
					if lease_err then
						tern.log.warn("control-room: session leases not checked", lease_err)
					end
					local body = tern.json.encode(catalog)
					-- A callback's cx may be gone by now: a timer brings a fresh one.
					tern.timer(0, function(fresh: WindowCx?)
						if fresh then
							send(fresh, "catalog", body)
						end
					end)
				end)
			end)
		end)
	end)
end

--- A search word or typo correction as the host sent it: letters and digits only.
local function word_ok(w: any): boolean
	return type(w) == "string" and #w > 0 and #w <= 64 and string.match(w, "^[%w\128-\255]+$") ~= nil
end

local function quote(s: string): string
	return "'" .. string.gsub(s, "'", "''") .. "'"
end

--- Deep search: for each query word (with its typo corrections), the sessions whose
--- prompts match it in omp's FTS5 index (best BM25, count, best snippet) and those
--- whose recaps contain it. `payload` is the URL-safe base64 of a JSON array of word lists.
function sessions.search(cx: WindowCx, payload: string, send: Send)
	local ok, text = pcall(tern.base64.decode, payload)
	local parsed, words = false, nil
	if ok then
		parsed, words = pcall(tern.json.decode, text)
	end
	if not parsed or type(words) ~= "table" then
		return
	end
	local arms: { string } = {}
	for t, variants in words :: { any } do
		if t > 8 or type(variants) ~= "table" then
			return
		end
		local fts: { string } = {}
		local like: { string } = {}
		for i, w in variants :: { any } do
			if i <= 4 and word_ok(w) then
				table.insert(fts, '"' .. w .. '"*')
				table.insert(like, "recap LIKE " .. quote("%" .. w .. "%"))
			end
		end
		if #fts == 0 then
			return
		end
		table.insert(
			arms,
			string.format(
				"SELECT * FROM (SELECT %d AS t, h.session_id AS s, 'p' AS k, bm25(history_fts) AS r, snippet(history_fts, 0, char(2), char(3), '…', 14) AS x FROM history_fts JOIN history h ON h.id = history_fts.rowid WHERE history_fts MATCH %s AND h.session_id IS NOT NULL AND h.prompt NOT LIKE '"
					.. sessions.HANDOFF_TAG
					.. "%%' ORDER BY r LIMIT %d)",
				t,
				quote(table.concat(fts, " OR ")),
				FTS_ROWS
			)
		)
		table.insert(arms, string.format("SELECT %d, session_id, 'r', -3.0, NULL FROM session_recaps WHERE %s", t, table.concat(like, " OR ")))
	end
	if #arms == 0 then
		return
	end
	local sql = "WITH hits AS (" .. table.concat(arms, " UNION ALL ") .. ") "
		.. "SELECT t, s, k, -r, n, x FROM (SELECT t, s, k, r, x, count(*) OVER (PARTITION BY t, s, k) AS n, "
		.. "row_number() OVER (PARTITION BY t, s, k ORDER BY r) AS q FROM hits) WHERE q = 1"
	local started = tern.now()
	query(cx, sql, 20000, function(rows: { { DbCell } }?, err: string?, later: WindowCx?)
		if later == nil then
			return
		end
		local hits: { common.Hit } = tern.json.array({})
		local list: { { DbCell } } = rows or {}
		for _, row in list do
			local s = str(row[2])
			if s then
				table.insert(hits, { t = num(row[1]) or 0, s = s, k = str(row[3]) or "p", w = num(row[4]) or 0, n = num(row[5]) or 1, x = str(row[6]) })
			end
		end
		local result: common.Hits = { query = text, hits = hits, error = err }
		send(later, "hits", tern.json.encode(result))
		local took = tern.now() - started
		if took > 1000 then
			tern.log.warn(string.format("control-room: archive search took %.0f ms", took))
		end
	end)
end

--- A closed session's last prompts and recaps, sent as `speek`.
function sessions.peek(cx: WindowCx, id: string, send: Send)
	local out: common.SessionPeek = { id = id, at = os.time() }
	if not sessions.valid_id(id) then
		out.error = "Not a session id"
		send(cx, "speek", tern.json.encode(out))
		return
	end
	local sid = quote(id)
	local sql = string.format(
		"SELECT * FROM (SELECT 'p' AS k, substr(prompt, 1, 800) AS x, created_at AS at FROM history WHERE session_id = %s ORDER BY id DESC LIMIT %d) "
			.. "UNION ALL SELECT * FROM (SELECT 'r', substr(recap, 1, 1500), created_at FROM session_recaps WHERE session_id = %s ORDER BY id DESC LIMIT %d)",
		sid,
		PEEK_PROMPTS,
		sid,
		PEEK_RECAPS
	)
	query(cx, sql, 20, function(rows: { { DbCell } }?, err: string?, later: WindowCx?)
		if later == nil then
			return
		end
		if rows == nil then
			out.error = err
		else
			local prompts: { common.Said } = tern.json.array({})
			local recaps: { common.Said } = tern.json.array({})
			for _, row in rows do
				local said: common.Said = { text = str(row[2]) or "", at = num(row[3]) or 0 }
				table.insert(if row[1] == "r" then recaps else prompts, said)
			end
			out.prompts, out.recaps = prompts, recaps
		end
		send(later, "speek", tern.json.encode(out))
	end)
end

--- Opens a tab resuming the session in its own directory: `omp --resume <file>`.
function sessions.resume(cx: WindowCx, id: string): (boolean, string?)
	if not sessions.valid_id(id) then
		return false, "Not a session id"
	end
	if paths[id] == nil then
		list_files()
	end
	local path = paths[id]
	if path == nil then
		return false, "Its session file is gone"
	end
	local quoted = if tern.runtime.os == "windows"
		then "'" .. string.gsub(path, "'", "''") .. "'"
		else "'" .. string.gsub(path, "'", "'\\''") .. "'"
	local cwd: string? = cwds[id]
	if cwd then
		local ok, there = pcall(tern.fs.exists, cwd)
		if not (ok and there) then
			cwd = nil
		end
	end
	local ok, err = pcall(function()
		cx.layout:new_tab({ cwd = cwd, command = "omp --resume " .. quoted })
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

return sessions
