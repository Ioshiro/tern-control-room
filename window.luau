--!strict
-- Control Room, window half: reads Tern's own model of this window's sessions,
-- tabs, panes and agents, pushes it to every Control Room block as a snapshot,
-- and performs the actions those blocks ask for (go, park/restore, ask an
-- agent for an update, peek at what a pane shows).
--
-- Nothing here invents state. Each snapshot is read fresh from `cx.session`
-- and `cx.agents`; the only things remembered are when a pane last changed
-- (Tern does not report that), the agents asked for an update, and the agents
-- whose last turn failed (`agent_finished`).
--
-- Every window call has a 50 ms budget, and one that runs over disables its
-- hook (every `timer`, or `route.link`) until the plugin reloads. So each
-- call does one bounded thing: `route.link` only queues work, and a snapshot
-- reads Tern's lists once and encodes JSON once. A peek reads one pane on
-- request, never in the snapshot.

local common = require("./common")

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

local function ask(cx: WindowCx, pane: number)
	local title = (cx.session:pane(pane) or { title = "agent" } :: any).title
	local text = ask_text()
	local ok, err = pcall(function()
		cx.agents:ask(pane, text)
	end)
	if not ok then
		cx:toast("error", "Could not ask " .. common.clip(title, 40) .. " for an update", tostring(err))
		return
	end
	local s = seen[common.id(pane)]
	if s then
		s.ask = { text = text, at = os.time() }
	end
	cx:toast("info", "Asked " .. common.clip(title, 40) .. " for an update", "Its reply stays in Control Room until the agent finishes its next turn.")
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

local ACTIONS: { [string]: (WindowCx, number) -> () } = { go = go, park = park, ask = ask, peek = peek }

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
	local action = ACTIONS[verb]
	if action and target then
		tern.timer(0, function(later: WindowCx?)
			if later and claim(nonce) then
				action(later, target)
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
	"pane_closed",
	"tab_created",
	"tab_closed",
	"command_started",
	"cwd",
	"title",
	"agent_state",
	"session_ended",
} do
	tern.on(name, function(...)
		poke()
	end)
end

-- A reload replaces this half after the host's: the block's `hello` may have
-- gone to the old one, so report once now without waiting for an event.
poke(true)
