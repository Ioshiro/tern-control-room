--!strict
-- Control Room, window half: reads Tern's own model of this window's sessions,
-- tabs, panes and agents, pushes it to every Control Room block as a snapshot,
-- and performs the actions those blocks ask for (go, park/restore, ask an
-- agent for an update, peek at what a pane shows, archive an agent, and the
-- Archive's catalog, search, peek and resume, which `sessions.luau` reads).
--
-- Nothing here invents state. Each snapshot is read fresh from `cx.session`
-- and `cx.agents`; the only things remembered are when a pane last changed
-- (Tern does not report that), the agents asked for an update or a handoff
-- note, and the agents whose last turn failed (`agent_finished`).
--
-- Every window call has a 50 ms budget, and one that runs over disables its
-- hook (every `timer`, or `route.link`) until the plugin reloads. So each
-- call does one bounded thing: `route.link` only queues work, and a snapshot
-- reads Tern's lists once and encodes JSON once. A peek reads one pane on
-- request, never in the snapshot.

local common = require("./common")
local sessions = require("./sessions")

type Row = common.Row
type Agent = common.Agent

local KIND = common.KIND
-- Snapshots go out at least this often while a block is open, as a heartbeat
-- (agent state changes raise `agent_state`; the tick covers what no event
-- reports, such as a command's elapsed time), and soon after any event.
local TICK_MS = 5000
local SOON_MS = 250
local MESSAGE_CHARS = 1500
local ASK_TIMEOUT_MS = 10 * 60 * 1000
local PEEK_LINES = 12
local PEEK_CHARS = 4000
local CHAT_MESSAGES = 4
local CHAT_CHARS = 600
local DEFAULT_ASK =
	"Status check from Control Room: in a few lines, what have you done so far, what are you doing now, and is anything blocking you or waiting on me?"
-- How long an agent may take to write its handoff note before archiving gives up.
local HANDOFF_TIMEOUT_MS = 5 * 60 * 1000
local HANDOFF_ASK = "]: this session is about to be closed and archived, to be resumed later. "
	.. "Write a short handoff note, in the language of this conversation, for whoever resumes it: "
	.. "the goal, what is done, what is left, and anything not committed or saved. "
	.. "Reply with the note only; do not run tools."
-- A closing omp releases its session lease shortly after it exits.
local RELEASE_MS = 2500

-- What changed per pane, keyed by pane id: the fingerprint of what Tern
-- reports and the times things were seen to change.
type Seen = {
	print: string,
	active_at: number?,
	finished_at: number?,
	message: string?,
	message_at: number?,
	--- The agent state at the last snapshot, to see a turn end.
	state: string?,
	--- When `agent_finished` last reported `failed`; cleared once the agent works again.
	failed_at: number?,
	--- An update request Control Room sent, until its reply is no longer needed.
	ask: Ask?,
	--- When Control Room asked for a handoff note before closing the agent.
	archiving: number?,
}
-- `text` is the prompt sent; `reply` is what `cx.agents:wait` returned when the
-- turn that answered it ended (the agent's last message then). It stays until a
-- later turn ends with a different last message.
type Ask = { text: string, at: number, reply: string?, reply_at: number? }
local seen: { [string]: Seen } = {}
-- A snapshot slower than this is logged: the hard limit is 50 ms.
local SLOW_MS = 25
-- Failed commands exactly as `command_finished` reported them, newest first,
-- kept in `tern.kv` under `failures` so they survive a reload; a pane's
-- current last command is read from Tern in every snapshot instead.
local KEEP_FAILURES = 20
local tick: TimerHandle? = nil
local soon: TimerHandle? = nil
local last_sent: { [string]: string } = {}

local function failures_list(): { common.Failure }
	local ok, value = pcall(tern.kv.get, "failures")
	return if ok and type(value) == "table" then value else {}
end

local function ask_text(): string
	local ok, value = pcall(tern.kv.get, "ask_prompt")
	return if ok and type(value) == "string" and value ~= "" then value else DEFAULT_ASK
end

local function str(v: any): string?
	-- Unknown optional fields arrive as `tern.json.null` or are absent.
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Panes needing attention at the last snapshot, for the window title and the status line.
local chrome_attention = 0

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

local function fingerprint(row: Row): string
	local agent = row.agent
	local last = row.last
	return table.concat({
		row.title,
		row.cwd,
		tostring(row.busy),
		if row.running then row.running.line else "",
		if last then string.format("%s|%d|%d", last.line, last.status, last.took_ms) else "",
		tostring(row.exited),
		tostring(row.error),
		tostring(row.alert),
		if agent then agent.state .. "|" .. tostring(agent.delivery_error) else "",
	}, "\0")
end

--- Retires the update request of an agent row once its reply is no longer needed.
local function follow_ask(row: Row, s: Seen, now: number)
	local ask = s.ask
	local agent = row.agent
	if ask == nil then
		return
	end
	if agent == nil or agent.state == "exited" then
		s.ask = nil
		return
	end
	local turn_ended = s.state == "working" and agent.state ~= "working"
	if turn_ended and ask.reply and agent.message ~= ask.reply then
		-- A later turn finished with something newer than the reply.
		s.ask = nil
	elseif ask.reply == nil and now - ask.at > ASK_TIMEOUT_MS / 1000 then
		s.ask = nil
	end
end

local function note(row: Row, now: number)
	local id = common.id(row.pane)
	local s = seen[id]
	local print = fingerprint(row)
	local message = if row.agent then row.agent.message else nil
	if s == nil then
		-- First sight: nothing is known about when it last changed.
		s = { print = print, message = message }
		seen[id] = s
	else
		if s.print ~= print then
			s.print = print
			s.active_at = now
		end
		if s.message ~= message then
			s.message = message
			s.message_at = now
			s.active_at = now
		end
	end
	follow_ask(row, s, now)
	local agent = row.agent
	if agent and agent.state == "working" then
		s.failed_at = nil
	end
	if agent then
		agent.failed_at = s.failed_at
	end
	s.state = if agent then agent.state else nil
	row.active_at = s.active_at
	row.finished_at = s.finished_at
	row.message_at = s.message_at
	local ask = s.ask
	if ask then
		row.update = { asked_at = ask.at, reply = ask.reply, reply_at = ask.reply_at }
	end
	row.archiving = s.archiving
end

local function control_rooms(cx: WindowCx): { number }
	local out: { number } = {}
	for _, p in cx.session:panes() do
		if p.block == KIND then
			table.insert(out, p.pane)
		end
	end
	return out
end

--- Tern's model of this window as rows, from one read of each of Tern's lists;
--- also the Control Room blocks among the panes.
local function snapshot(cx: WindowCx): (common.Snapshot, { number })
	local now = os.time()
	local tabs: { [number]: TabInfo } = {}
	for _, t in cx.session:tabs() do
		tabs[t.id] = t
	end
	local agents: { [string]: AgentBlock & { [string]: any } } = {}
	local ok_agents, list = pcall(function()
		return cx.agents:list()
	end)
	if ok_agents then
		for _, a in list do
			agents[common.id(a.pane)] = a :: any
		end
	end
	local rows: { Row } = {}
	local blocks: { number } = {}
	local live: { [string]: boolean } = {}
	for _, p in cx.session:panes() do
		if p.block == KIND then
			table.insert(blocks, p.pane)
		else
			local id = common.id(p.pane)
			live[id] = true
			local tab = if p.tab then tabs[p.tab] else nil
			local a = agents[id]
			local agent: Agent? = nil
			local session: number? = if tab then tab.session else nil
			if a then
				local msg = str(a.last_message)
				agent = {
					state = str(a.state) or "idle",
					model = str(a.model),
					command = str(a.command),
					message = if msg then common.cut(msg, MESSAGE_CHARS) else nil,
					delivery_error = str(a.delivery_error),
				}
				session = session or num(a.session)
			end
			local row: Row = {
				pane = p.pane,
				kind = p.kind or "terminal",
				title = str(p.title) or "",
				program = str(p.program),
				cwd = str(p.cwd) or "",
				session = session,
				tab = p.tab,
				tab_pos = if tab then tab.position else nil,
				tab_name = if tab and type(tab.name) == "string" and tab.name ~= "" then tab.name else nil,
				parked = p.parked == true,
				floating = p.floating == true,
				focused = p.focused == true,
				busy = p.busy == true,
				running = p.running,
				last = p.last,
				exited = num(p.exited),
				error = str(p.error),
				alert = p.alert == true,
				agent = agent,
			}
			note(row, now)
			table.insert(rows, row)
		end
	end
	for id in seen do
		if not live[id] then
			seen[id] = nil
		end
	end
	-- The attention count the chrome formatters show.
	local acks = common.acks()
	local attention = 0
	for _, row in rows do
		if common.classify(row, acks).level == "attention" then
			attention += 1
		end
	end
	if attention ~= chrome_attention then
		chrome_attention = attention
		tern.chrome.refresh()
	end
	local sessions: { common.SessionRef } = {}
	for _, s in cx.session:sessions() do
		table.insert(sessions, { id = s.id, name = s.name, current = s.current })
	end
	local fails: { common.Failure } = {}
	for _, f in failures_list() do
		if live[common.id(f.pane)] then
			table.insert(fails, f)
		end
	end
	return { at = now, rows = rows, sessions = sessions, failures = fails }, blocks
end

--- Sends the current snapshot to every Control Room block in this window,
--- skipping blocks that already have this exact one unless `force`.
--- Returns whether any Control Room block is open.
local function push(cx: WindowCx, force: boolean?): boolean
	local started = tern.now()
	local snap, blocks = snapshot(cx)
	if #blocks == 0 then
		return false
	end
	-- `at` ticks every second: leave it out so unchanged data compares equal.
	snap.at = 0
	local body = tern.json.encode(snap)
	for _, pane in blocks do
		local id = common.id(pane)
		-- Resend unchanged data now and then so the block knows a window is alive.
		if force or last_sent[id] ~= body then
			last_sent[id] = body
			local ok, err = pcall(function()
				cx.session:event(pane, { ev = "action", id = "main", act = "snapshot", value = body })
			end)
			if not ok then
				tern.log.warn("control-room: snapshot not delivered", pane, err)
			end
		end
	end
	local took = tern.now() - started
	if took > SLOW_MS then
		tern.log.warn(string.format("control-room: snapshot of %d panes took %.1f ms", #snap.rows, took))
	end
	return true
end

-- One loop per window: a snapshot every TICK_MS while a Control Room is open
-- (agent state changes raise no window event). It stops when none is open;
-- the next event or block start wakes it again.
local beats = 0
local function schedule()
	if tick ~= nil then
		return
	end
	tick = tern.timer(TICK_MS, function(cx: WindowCx?)
		tick = nil
		if cx == nil then
			return
		end
		beats += 1
		if push(cx, beats % 3 == 0) then
			schedule()
		end
	end)
end

-- Several events in a burst (a command finishing changes title, cwd and
-- status) make one snapshot.
local force_next = false
local function poke(force: boolean?)
	force_next = force_next or force == true
	if soon ~= nil then
		return
	end
	soon = tern.timer(SOON_MS, function(cx: WindowCx?)
		soon = nil
		local f = force_next
		force_next = false
		if cx then
			push(cx, f)
		end
		schedule()
	end)
end

-- Actions -------------------------------------------------------------------

local function session_of(cx: WindowCx, pane: number): number?
	local tab = cx.session:tab_of(pane)
	if tab then
		for _, t in cx.session:tabs() do
			if t.id == tab then
				return t.session
			end
		end
	end
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		for _, a in list do
			if a.pane == pane then
				return num((a :: any).session)
			end
		end
	end
	return nil
end

local function go(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	if info == nil then
		cx:toast("error", "That pane is gone")
		return
	end
	if info.parked then
		local ok, why = cx.layout:unpark(pane)
		if not ok then
			cx:toast("error", "Could not restore the parked pane", why)
			return
		end
	else
		local session = session_of(cx, pane)
		if session then
			for _, s in cx.session:sessions() do
				if s.id == session and not s.current then
					cx.sessions:switch(session)
				end
			end
		end
	end
	cx.layout:focus(pane)
	-- Looking at it is what "seen" means for its alert; Tern clears the alert itself.
end

local function park(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	if info == nil then
		cx:toast("error", "That pane is gone")
		return
	end
	if info.parked then
		local ok, why = cx.layout:unpark(pane, { focus = false })
		if not ok then
			cx:toast("error", "Could not restore the pane", why)
		end
	else
		local ok, why = cx.layout:park(pane)
		if not ok then
			cx:toast("error", "Could not park the pane", why)
		end
	end
end

local function title_of(cx: WindowCx, pane: number): string
	local info = cx.session:pane(pane)
	return common.clip(if info and info.title ~= "" then info.title else "agent", 40)
end

--- Sends `text` to the agent in `pane` and keeps its reply pinned in the block
--- until a later turn ends with something newer.
local function send(cx: WindowCx, pane: number, text: string)
	local title = title_of(cx, pane)
	local ok, err = pcall(function()
		cx.agents:ask(pane, text)
	end)
	if not ok then
		cx:toast("error", "Could not send to " .. title, tostring(err))
		return
	end
	local s = seen[common.id(pane)]
	if s then
		s.ask = { text = text, at = os.time() }
	end
	cx:toast("info", "Sent to " .. title, "Its reply stays in Control Room until the agent finishes its next turn.")
	-- Resolves when the turn that answers the request ends, with its last message.
	cx.agents:wait(pane, { timeout = ASK_TIMEOUT_MS }):next(function(message: string?, wait_err: string?, _later: WindowCx?)
		local s2 = seen[common.id(pane)]
		local pending = if s2 then s2.ask else nil
		if wait_err then
			-- Timeouts and closed agents: the next snapshot shows the real state.
			tern.log.warn("control-room: update wait ended", pane, wait_err)
		elseif pending and pending.reply == nil and type(message) == "string" and message ~= "" then
			pending.reply = common.cut(message, MESSAGE_CHARS)
			pending.reply_at = os.time()
		end
		poke()
	end)
end

--- Asks the user what to send, starting from the status-check prompt.
local function ask(cx: WindowCx, pane: number)
	cx:prompt({ value = ask_text(), placeholder = "Message for " .. title_of(cx, pane), icon = "message", action = "send" })
		:next(function(text: string?, _err: string?, later: WindowCx?)
			local trimmed = if text then string.match(text, "^%s*(.-)%s*$") else nil
			if later and trimmed and trimmed ~= "" then
				send(later, pane, trimmed)
			end
		end)
end

--- Ctrl-C to the agent's current turn; the block stays. The block asks only
--- after its confirm strip, so no second confirmation here.
local function interrupt(cx: WindowCx, pane: number)
	local title = title_of(cx, pane)
	local ok, err = pcall(function()
		cx.agents:interrupt(pane)
	end)
	if ok then
		cx:toast("info", "Interrupted " .. title)
	else
		cx:toast("error", "Could not interrupt " .. title, tostring(err))
	end
end

-- Where a pinned pane came from: its tab and session, and the pane it sat
-- beside (on which side) in that tab's split tree, so unpinning puts it back
-- there rather than beside the Control Room. Kept in `tern.kv` (`pinned`) so
-- a plugin reload does not lose it.
type Origin = { tab: number, session: number?, position: number?, beside: number?, dir: string? }

local function origins(): { [string]: Origin }
	local ok, value = pcall(tern.kv.get, "pinned")
	return if ok and type(value) == "table" then value else {}
end

--- The leaf pane at the far side of `tree`: first (left/top) or last (right/bottom).
local function edge_leaf(tree: TabTree, first: boolean): number?
	local t = tree
	while t.pane == nil do
		local next = t[if first then 1 else 2]
		if next == nil then
			return nil
		end
		t = next
	end
	return t.pane
end

--- The pane next to `pane` in `tree` and the side `pane` is on: `left`/`up`
--- when it is the first half of its split, `right`/`down` when the second.
local function place_in(tree: TabTree, pane: number): (number?, string?)
	if tree.pane ~= nil or tree[1] == nil or tree[2] == nil then
		return nil, nil
	end
	for i = 1, 2 do
		local half = tree[i]
		if half.pane == pane then
			local other = tree[3 - i]
			local first = i == 1
			local dir = if tree.split == "down" then (if first then "up" else "down") else (if first then "left" else "right")
			-- Beside the sibling's leaf nearest to where the pane was.
			return edge_leaf(other, first), dir
		end
		local beside, dir = place_in(half, pane)
		if beside then
			return beside, dir
		end
	end
	return nil, nil
end

local function origin_of(cx: WindowCx, pane: number): Origin?
	local tab = cx.session:tab_of(pane)
	if tab == nil then
		return nil
	end
	local origin: Origin = { tab = tab }
	for _, t in cx.session:tabs() do
		if t.id == tab then
			origin.session, origin.position = t.session, t.position
		end
	end
	local layout = cx.session:layout(tab)
	if layout then
		origin.beside, origin.dir = place_in(layout.root, pane)
	end
	return origin
end

--- Puts a docked pane back where `origin` says: beside its old neighbour, else
--- in its old tab, else in a new tab of its old session.
local function restore(cx: WindowCx, pane: number, origin: Origin): (boolean, string?)
	local quiet: Reveal = { focus = false }
	if origin.beside and origin.dir and cx.session:pane(origin.beside) then
		if cx.layout:move(pane, origin.beside, origin.dir :: Dir, quiet) then
			return true, nil
		end
	end
	if cx.session:layout(origin.tab) then
		if cx.session:tab_of(pane) == origin.tab then
			return true, nil
		end
		return cx.layout:move_to_tab(pane, origin.tab, quiet)
	end
	local tab, why = cx.layout:move_to_new_tab(pane, origin.session, quiet)
	if tab == nil then
		return false, why
	end
	if origin.position then
		cx.layout:order_tab(tab, origin.position)
	end
	return true, nil
end

--- Floats the pane over the Control Room block that asked (`from`), so it can
--- be watched without leaving the room; floating already, puts it back.
local function pin(cx: WindowCx, pane: number, from: number?)
	local info = cx.session:pane(pane)
	if info == nil then
		cx:toast("error", "That pane is gone")
		return
	end
	local id = common.id(pane)
	local pinned = origins()
	if info.floating then
		local origin = pinned[id]
		pinned[id] = nil
		pcall(tern.kv.set, "pinned", pinned)
		-- A floating pane still belongs to a tab for `move_to_tab`: dock it first.
		local ok, why = cx.layout:dock(pane, nil, nil, { focus = false })
		if ok and origin then
			ok, why = restore(cx, pane, origin)
		end
		if not ok then
			cx:toast("error", "Could not put the pane back", why)
		end
		return
	end
	if info.parked then
		local ok, why = cx.layout:unpark(pane, { focus = false })
		if not ok then
			cx:toast("error", "Could not restore the parked pane", why)
			return
		end
	end
	local origin = origin_of(cx, pane)
	local ok, why = cx.layout:float(pane, from, "br", { focus = false, size = { 0.5, 0.5 } })
	if not ok then
		cx:toast("error", "Could not float " .. title_of(cx, pane), why)
		return
	end
	if origin then
		pinned[id] = origin
		pcall(tern.kv.set, "pinned", pinned)
	end
end

--- Asks for a prompt and starts a new agent in the pane's directory, in a tab.
local function new_agent(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	local cwd = if info and info.cwd and info.cwd ~= "" then info.cwd else nil
	if cwd == nil then
		cx:toast("error", "That pane has no known directory")
		return
	end
	cx:prompt({ placeholder = "Prompt for a new agent in " .. common.basename(cwd), icon = "sparkle", action = "start" })
		:next(function(text: string?, _err: string?, later: WindowCx?)
			local trimmed = if text then string.match(text, "^%s*(.-)%s*$") else nil
			if later == nil or trimmed == nil or trimmed == "" then
				return
			end
			local ok, err = pcall(function()
				later.agents:start({ prompt = trimmed, cwd = cwd, how = "tab" })
			end)
			if not ok then
				later:toast("error", "Could not start an agent in " .. common.basename(cwd), tostring(err))
			end
			poke()
		end)
end

--- Reads what `pane` shows now and sends it to every Control Room block as a
--- `peek` event: the last lines of a terminal or agent (a plugin block's
--- text), and an agent's last exchanges from its transcript.
local function peek(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	local out: common.Peek = { pane = pane, at = os.time() }
	if info == nil then
		out.error = "That pane is gone"
	else
		out.kind = info.kind
		local ok, read = pcall(function()
			return cx.session:read(pane, { lines = PEEK_LINES, max_chars = PEEK_CHARS })
		end)
		if not ok then
			out.error = tostring(read)
		elseif type(read) == "string" then
			out.text = read
		elseif type(read) == "table" then
			local r = read :: any
			if type(r.lines) == "table" then
				out.lines = tern.json.array(r.lines)
				out.more = num(r.more)
			elseif type(r.text) == "string" then
				out.text = r.text
			end
		end
		if info.kind == "agent" then
			local ok_chat, chat = pcall(function()
				return cx.agents:transcript(pane, { last = CHAT_MESSAGES })
			end)
			if ok_chat and type(chat) == "table" then
				local list: { common.Chat } = tern.json.array({})
				for _, m in chat do
					local text = str(m.text)
					local tools = if type(m.tools) == "table" then #m.tools else 0
					if text then
						table.insert(list, { role = m.role :: string, text = common.cut(text, CHAT_CHARS) })
					elseif tools > 0 then
						table.insert(list, { role = m.role :: string, text = "_(" .. tools .. (if tools == 1 then " tool call" else " tool calls") .. ", no text)_" })
					end
				end
				if #list > 0 then
					out.chat = list
				end
			end
		end
	end
	local body = tern.json.encode(out)
	for _, block in control_rooms(cx) do
		pcall(function()
			cx.session:event(block, { ev = "action", id = "main", act = "peek", value = body })
		end)
	end
end

--- Sends `act` with a JSON body to every Control Room block in this window.
local function send_all(cx: WindowCx, act: string, body: string)
	for _, block in control_rooms(cx) do
		local ok, err = pcall(function()
			cx.session:event(block, { ev = "action", id = "main", act = act, value = body })
		end)
		if not ok then
			tern.log.warn("control-room: " .. act .. " not delivered", block, err)
		end
	end
end

-- Set once a block has shown the Archive: closing a pane then refreshes it.
local catalog_wanted = false

local function refresh_catalog(ms: number)
	tern.timer(ms, function(later: WindowCx?)
		if later then
			sessions.catalog(later, send_all)
		end
	end)
end

--- Asks the agent for a handoff note, keeps it for the Archive, then closes the
--- agent. The block asks first (its confirm strip); a failed request closes nothing.
local function archive(cx: WindowCx, pane: number)
	local title = title_of(cx, pane)
	local s = seen[common.id(pane)]
	if s and s.archiving then
		return
	end
	local nonce = string.format("%x%04x", os.time(), math.random(0, 0xffff))
	local ok, err = pcall(function()
		cx.agents:ask(pane, sessions.HANDOFF_TAG .. nonce .. HANDOFF_ASK)
	end)
	if not ok then
		cx:toast("error", "Could not ask " .. title .. " for a handoff note", tostring(err))
		return
	end
	if s then
		s.archiving = os.time()
	end
	cx:toast("info", "Archiving " .. title, "It closes once it has written its handoff note.")
	cx.agents:wait(pane, { timeout = HANDOFF_TIMEOUT_MS }):next(function(message: string?, wait_err: string?, later: WindowCx?)
		local s2 = seen[common.id(pane)]
		if s2 then
			s2.archiving = nil
		end
		if later == nil then
			return
		end
		local note = if type(message) == "string" then string.match(message, "^%s*(.-)%s*$") else nil
		if wait_err or note == nil or note == "" then
			later:toast("error", title .. " was not archived", wait_err or "It wrote no handoff note; the agent stays open.")
			poke()
			return
		end
		sessions.keep_note(nonce, note)
		local stopped, stop_err = pcall(function()
			later.agents:stop(pane)
		end)
		if stopped then
			later:toast("success", "Archived " .. title, "Find it in Control Room's Archive.")
		else
			later:toast("error", "Kept the note but could not close " .. title, tostring(stop_err))
		end
		poke()
		refresh_catalog(RELEASE_MS)
	end)
end

-- One window acts on each request, even when several show the block.
local function claim(nonce: string?): boolean
	if nonce == nil then
		return true
	end
	local ok, last = pcall(tern.kv.get, "handled")
	if ok and last == nonce then
		return false
	end
	pcall(tern.kv.set, "handled", nonce)
	return true
end

local ACTIONS: { [string]: (WindowCx, number, number?) -> () } = {
	go = go,
	park = park,
	ask = ask,
	peek = peek,
	interrupt = interrupt,
	pin = pin,
	new_agent = new_agent,
	archive = archive,
}

--- Archive requests: the target is a session id or, for `search`, an encoded query.
local SESSION_ACTIONS: { [string]: (WindowCx, string?) -> () } = {
	catalog = function(cx: WindowCx, _target: string?)
		catalog_wanted = true
		sessions.catalog(cx, send_all)
	end,
	search = function(cx: WindowCx, target: string?)
		if target then
			sessions.search(cx, target, send_all)
		end
	end,
	speek = function(cx: WindowCx, target: string?)
		if target then
			sessions.peek(cx, target, send_all)
		end
	end,
	resume = function(cx: WindowCx, target: string?)
		if target == nil then
			return
		end
		local ok, why = sessions.resume(cx, target)
		if not ok then
			cx:toast("error", "Could not resume the session", why)
			return
		end
		-- Once its omp holds the session, it leaves the Archive.
		refresh_catalog(5000)
	end,
}

-- The link handler only checks the request and queues it: the action and the
-- snapshot after it each get a call (and a budget) of their own.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local verb, target, nonce = common.parse(link.url)
	if verb == nil then
		return nil
	end
	-- Only a Control Room block may drive these; a link printed elsewhere is ignored.
	local from = if link.pane then cx.session:pane(link.pane) else nil
	if from == nil or from.block ~= KIND then
		return { handled = true }
	end
	if verb == "hello" or verb == "refresh" then
		poke(true)
		return { handled = true }
	end
	local room = from.pane
	local session_action = SESSION_ACTIONS[verb]
	if session_action then
		tern.timer(0, function(later: WindowCx?)
			if later and claim(nonce) then
				session_action(later, target)
			end
		end)
		return { handled = true }
	end
	local action = ACTIONS[verb]
	local pane = if target then tonumber(target) else nil
	if action and pane then
		tern.timer(0, function(later: WindowCx?)
			if later and claim(nonce) then
				action(later, pane, room)
			end
			poke()
		end)
	end
	return { handled = true }
end)

-- Opening the block --------------------------------------------------------

local function open(cx: WindowCx)
	local blocks = control_rooms(cx)
	if #blocks > 0 then
		go(cx, blocks[1])
		return
	end
	if cx:new_block(KIND, nil, "tab") == nil then
		cx:toast("error", "Control Room is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open Control Room",
	icon = "gauge",
	run = open,
})

-- `…+c` is taken by the canvas (`canvas.copy_as_png`) and plugin binds cannot
-- replace a default: `r` for Room instead.
tern.bind(if tern.runtime.os == "macos" then "cmd+alt+shift+r" else "ctrl+alt+shift+r", "plugin.control-room.open")

-- Sizing: the host caps the table's and the card's scroll boxes in lines
-- (`max.h`); Tern puts that on the box, but what scrolls is the view inside
-- it, which this hands the cap down to. Without it the box grows with its
-- rows and the whole block scrolls instead (as it does in the web client).
tern.css("fill", [[
.sf-main[data-surface='plugin.control-room.room'] .sf-scroll[data-role='control-room.scroll'] > .sf-scroll-view { max-height: inherit !important; }
]])

-- Chrome: how many panes need attention, in the window title and the status line.
tern.chrome.window_title(function(win: WindowInfo): string?
	if chrome_attention == 0 then
		return nil
	end
	local parts = { "⚠ " .. chrome_attention }
	if type(win.tab) == "string" and win.tab ~= "" then
		table.insert(parts, win.tab)
	end
	if type(win.space) == "string" and win.space ~= "" then
		table.insert(parts, win.space)
	end
	return table.concat(parts, " · ")
end)

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	if chrome_attention == 0 then
		return nil
	end
	return { {
		text = chrome_attention .. (if chrome_attention == 1 then " needs attention" else " need attention"),
		icon = "gauge",
		tone = "error",
		command = "plugin.control-room.open",
	} }
end)

-- Events --------------------------------------------------------------------

tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
	local now = os.time()
	local s = seen[common.id(ev.pane)]
	if s then
		s.finished_at = now
	end
	if ev.status ~= 0 then
		local info = cx.session:pane(ev.pane)
		local failures = failures_list()
		table.insert(failures, 1, {
			pane = ev.pane,
			title = if info then info.title else "",
			line = ev.line,
			status = ev.status,
			took_ms = ev.took_ms,
			at = now,
		})
		while #failures > KEEP_FAILURES do
			table.remove(failures)
		end
		pcall(tern.kv.set, "failures", tern.json.array(failures))
	end
	poke()
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, _cx: WindowCx)
	local s = seen[common.id(ev.pane)]
	if s then
		s.finished_at = os.time()
		if ev.result == "failed" then
			s.failed_at = os.time()
		end
	end
	poke()
end)

for _, name in {
	"window_start",
	"focus",
	"pane_created",
	"tab_created",
	"command_started",
	"cwd",
	"title",
	"agent_state",
} do
	tern.on(name, function(...)
		poke()
	end)
end

-- A closed omp releases its session: it now belongs in the Archive.
for _, name in { "pane_closed", "tab_closed", "session_ended" } do
	tern.on(name, function(...)
		poke()
		if catalog_wanted then
			refresh_catalog(RELEASE_MS)
		end
	end)
end

-- A reload replaces this half after the host's: the block's `hello` may have
-- gone to the old one, so report once now without waiting for an event.
poke(true)
