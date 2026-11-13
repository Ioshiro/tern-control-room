--!strict
-- Native boards are discovered from local active panes; no task data is persisted.
local common = require("./common")
local boards = {}

export type Card = { id: string, text: string, done: boolean, tags: { string }, due: string? }
export type Lane = { id: string, title: string, complete: boolean, cards: { Card }, more: number }
export type Board = { path: string, title: string, sessions: { { id: number, name: string } }, agents: { { pane: number, title: string, session: number? } }, lanes: { Lane }, open: number, done: number, more: number, error: string? }
export type Report = { at: number, boards: { Board }, error: string? }
export type Send = (WindowCx, string, string) -> ()
type Source = { cwd: string, session: number, name: string, pane: number, title: string, agent: boolean }
type Candidate = { path: string, sources: { Source } }

local function key(path: string): string
	local p = string.gsub(path, "\\", "/")
	-- Native board discovery canonicalizes Windows paths with an extended prefix.
	if string.sub(p, 1, 8) == "//?/UNC/" then
		p = "//" .. string.sub(p, 9)
	elseif string.sub(p, 1, 4) == "//?/" then
		p = string.sub(p, 5)
	end
	p = string.gsub(p, "/+", "/")
	if #p > 1 and not string.match(p, "^%a:/$") then p = string.gsub(p, "/$", "") end
	if string.match(p, "^%a:") then p = string.lower(p) end
	return p
end

local function directory(path: string): string
	return string.match(key(path), "^(.*)/[^/]+$") or ""
end

local function valid_number(v: any): boolean
	return type(v) == "number" and v == v and v >= 0 and v < math.huge
end

-- Validate the whole decoded report before it crosses into the host view.
function boards.report_of(value: any): Report?
	if type(value) ~= "table" or not valid_number(value.at) or type(value.boards) ~= "table" or (value.error ~= nil and type(value.error) ~= "string") then return nil end
	for _, b in value.boards do
		if type(b) ~= "table" or type(b.path) ~= "string" or type(b.title) ~= "string" or type(b.sessions) ~= "table" or type(b.agents) ~= "table" or type(b.lanes) ~= "table" or not valid_number(b.open) or not valid_number(b.done) or not valid_number(b.more) or (b.error ~= nil and type(b.error) ~= "string") then return nil end
		for _, s in b.sessions do
			if type(s) ~= "table" or not valid_number(s.id) or type(s.name) ~= "string" then return nil end
		end
		for _, a in b.agents do
			if type(a) ~= "table" or not valid_number(a.pane) or type(a.title) ~= "string" or (a.session ~= nil and not valid_number(a.session)) then return nil end
		end
		for _, lane in b.lanes do
			if type(lane) ~= "table" or type(lane.id) ~= "string" or type(lane.title) ~= "string" or type(lane.complete) ~= "boolean" or not valid_number(lane.more) or type(lane.cards) ~= "table" then return nil end
			for _, card in lane.cards do
				if type(card) ~= "table" or type(card.id) ~= "string" or type(card.text) ~= "string" or type(card.done) ~= "boolean" or type(card.tags) ~= "table" or (card.due ~= nil and type(card.due) ~= "string") then return nil end
				for _, tag in card.tags do if type(tag) ~= "string" then return nil end end
			end
		end
	end
	return value
end

local function sources(cx: WindowCx, agents: { [string]: boolean }): { Source }
	local hosts: { [number]: boolean } = {}
	for _, h in cx.hosts:list() do hosts[h.id] = h.kind == "local" end
	local local_sessions: { [number]: boolean } = {}
	for _, s in cx.sessions:list() do local_sessions[s.id] = hosts[s.host] == true end
	local names: { [number]: string } = {}
	for _, s in cx.session:sessions() do names[s.id] = s.name end
	local tabs: { [number]: number } = {}
	for _, t in cx.session:tabs() do tabs[t.id] = t.session end
	local ok, saved = pcall(tern.kv.get, "pinned")
	local pinned = if ok and type(saved) == "table" then saved else {}
	local out: { Source } = {}
	for _, p in cx.session:panes() do
		local origin = pinned[common.id(p.pane)]
		local session = if p.floating and type(origin) == "table" and type(origin.session) == "number" then origin.session else if p.tab then tabs[p.tab] else nil
		if session and local_sessions[session] and p.cwd and p.cwd ~= "" and (p.kind == "terminal" or p.kind == "agent") then
			table.insert(out, { cwd = p.cwd, session = session, name = names[session] or tostring(session), pane = p.pane, title = p.title, agent = p.kind == "agent" or agents[common.id(p.pane)] == true })
		end
	end
	return out
end

local function new_board(c: Candidate): Board
	local sessions, agents = tern.json.array(), tern.json.array()
	local seen: { [number]: boolean } = {}
	for _, s in c.sources do
		if not seen[s.session] then
			seen[s.session] = true
			table.insert(sessions, { id = s.session, name = s.name })
		end
		if s.agent then table.insert(agents, { pane = s.pane, title = s.title, session = s.session }) end
	end
	local dir = directory(c.path)
	local title = string.match(dir, "([^/]+)$") or dir
	return { path = c.path, title = title, sessions = sessions, agents = agents, lanes = tern.json.array(), open = 0, done = 0, more = 0 }
end

-- Each asynchronous callback receives a new context; no context survives its call.
function boards.collect(cx: WindowCx, agents: { [string]: boolean }, done: (Report, WindowCx?) -> ())
	local ok, src = pcall(sources, cx, agents)
	if not ok then done({ at = os.time(), boards = tern.json.array(), error = tostring(src) }, cx); return end
	local found = src :: { Source }
	local roots: { [string]: string } = {}
	local dirs: { string } = {}
	for _, s in found do
		local k = key(s.cwd)
		if roots[k] == nil then roots[k] = s.cwd; table.insert(dirs, s.cwd) end
	end
	local function discover(on: WindowCx)
		local started, pending = pcall(function() return on.board:boards() end)
		if not started then done({ at = os.time(), boards = tern.json.array(), error = tostring(pending) }, on); return end
		(pending :: Awaitable<{{path: string, pane: number?, open: boolean}}>):next(function(list, err, later)
			if later == nil then done({ at = os.time(), boards = tern.json.array(), error = err or "Board discovery interrupted" }, nil); return end
			if list == nil then done({ at = os.time(), boards = tern.json.array(), error = err or "Board discovery failed" }, later); return end
			local candidates: { Candidate } = {}
			local bypath: { [string]: Candidate } = {}
			for _, item in list do
				local pathkey = key(item.path)
				if string.lower(string.match(pathkey, "([^/]+)$") or "") == "todo.md" then
					local dir = directory(item.path)
					local matching: { Source } = {}
					for _, s in found do
						local cwd = key(s.cwd)
						if dir == cwd or dir == roots[cwd] then table.insert(matching, s) end
					end
					local exists, present = pcall(tern.fs.exists, item.path)
					if #matching > 0 and exists and present and bypath[pathkey] == nil then
						local c: Candidate = { path = item.path, sources = matching }
						bypath[pathkey] = c; table.insert(candidates, c)
					end
				end
			end
			table.sort(candidates, function(a, b) return key(a.path) < key(b.path) end)
			local report: Report = { at = os.time(), boards = tern.json.array() }
			local function read_next(index: number, current: WindowCx)
				local candidate = candidates[index]
				if not candidate then done(report, current); return end
				local board = new_board(candidate)
				table.insert(report.boards, board)
				local started_read, result = pcall(function() return current.board:read(candidate.path, { rows = 500, max_chars = 64000 }) end)
				if not started_read then board.error = tostring(result); read_next(index + 1, current); return end
				(result :: Awaitable<BoardSnapshot>):next(function(snapshot, why, nextcx)
					if nextcx == nil then done(report, nil); return end
					if snapshot == nil then board.error = why or "Board read failed" else
						board.open, board.done, board.more = snapshot.open, snapshot.done, snapshot.more
						for _, lane in snapshot.lanes do
							local cards: { Card } = tern.json.array()
							for _, card in lane.cards do table.insert(cards, { id = card.id, text = card.text, done = card.done, tags = card.tags, due = card.due }) end
							table.insert(board.lanes, { id = lane.id, title = lane.title or "", complete = lane.complete, cards = cards, more = lane.more })
						end
					end
					read_next(index + 1, nextcx)
				end)
			end
			read_next(1, later)
		end)
	end
	local function repo(index: number, on: WindowCx)
		local dir = dirs[index]
		if dir == nil then discover(on); return end
		local started, pending = pcall(function() return on.git:repo(dir) end)
		if not started then roots[key(dir)] = ""; repo(index + 1, on); return end
		(pending :: Awaitable<GitRepo>):next(function(result, _err, later)
			if later then roots[key(dir)] = if result then key(result.root) else ""; repo(index + 1, later) else done({ at = os.time(), boards = tern.json.array(), error = "Board discovery interrupted" }, nil) end
		end)
	end
	repo(1, cx)
end

local refreshing = false
local refresh_again = false

function boards.refresh(cx: WindowCx, agents: { [string]: boolean }, send: Send)
	if refreshing then refresh_again = true; return end
	refreshing = true
	boards.collect(cx, agents, function(report, later)
		refreshing = false
		if later then
			send(later, "boards", tern.json.encode(report))
			if refresh_again then
				refresh_again = false
				boards.refresh(later, agents, send)
			end
		else
			refresh_again = false
		end
	end)
end

return boards
