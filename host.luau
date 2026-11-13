--!strict
-- Control Room, host half: the `room` block.
--
-- The block owns no data about panes. The window half reads Tern
-- (`cx.session`, `cx.sessions`, `cx.agents`) and pushes a snapshot into the
-- block as a view event; the block keeps only the latest one, plus the last
-- peek it asked for and its own UI state (view, filter, scope, grouping,
-- selection). Actions the block cannot do on the host (focus, park, prompt an
-- agent, read a pane) go back to the window half as `control-room://` links.
-- Until a window reports, the block lists the host's panes from
-- `tern.pane.list()` with the little it says.
--
-- The Archive view works the same way: the window half reads omp's records of
-- the closed sessions (`catalog`), searches every prompt on request (`hits`)
-- and resumes one; the ranking itself is `archive.luau`, here.
--
-- The page follows Tern's own apps: a head row, a stats strip, tabs, and in
-- each view a full-width table beside the selected pane's card.

local common = require("./common")
local archive = require("./archive")
local editor = require("./field")
local boards = require("./boards")
local boards_view = require("./boards_view")
local ui = tern.ui

type Row = common.Row
type Snapshot = common.Snapshot
type Status = common.Status
type Peek = common.Peek
type Ranked = archive.Ranked

type Entry = {
	row: Row,
	status: Status,
	--- Most recent known activity (seconds), 0 when none was seen.
	recent: number,
	group: string,
	group_label: string,
	group_order: number,
}

type Group = { key: string, label: string, order: number, entries: { Entry }, best: Entry }
--- An action awaiting confirmation, with an optional warning about services.
type Confirmation = { verb: string, pane: number, title: string, panes: { number }?, note: string? }

type State = {
	cx: BlockCx,
	snap: Snapshot?,
	received: number?,
	--- The window hook currently paused for exceeding its budget.
	pause: common.Pause?,
	--- The latest provider limits and credential report.
	usage: common.Usage?,
	board_report: boards.Report?,
	board_asked: number?,
	board_done: boolean,
	board_collapsed: { [string]: boolean },
	board_filter: string,
	board_mode: string,
	board_selected: string?,
	board_menu: boolean,
	board_menu_cursor: number,
	board_anchor: string?,
	board_entries: { boards_view.Entry },
	--- `panes`, `agents`, `failures`, `limits` or `archive`.
	view: string,
	filter: string,
	editing: boolean,
	--- The dock lists every key, not just each view's main ones (`?`).
	all_keys: boolean,
	--- The edited field's caret in UTF-16 units.
	caret: number,
	scope: string,
	group: string,
	cursor: number?,
	--- The last peek the window sent; shown while it is about the selected pane.
	peek: Peek?,
	--- The pane a peek was requested for and not yet answered.
	peeking: number?,
	--- An action waiting for the user's confirmation in the dock (`interrupt`, `archive`,
	--- `archive_idle`); `panes` when it covers several.
	confirm: Confirmation?,
	timer: TimerHandle?,
	--- The rows in display order, as the last `view` laid them out.
	order: { Entry },
	--- The Archive's search text (the panes filter is its own).
	query: string,
	catalog: common.Catalog?,
	index: archive.Index?,
	catalog_asked: number?,
	--- Deep-search results, for the words `deep_key` names; `deep_stamp` counts arrivals.
	deep: archive.Deep?,
	deep_key: string?,
	deep_stamp: number,
	deep_error: string?,
	--- The words a deep search was last scheduled for, and the request sent for them.
	deep_wanted: string?,
	deep_sent: string?,
	deep_sent_key: string?,
	search_timer: TimerHandle?,
	--- The Archive in display order, and what it was ranked for.
	ranked: { Ranked },
	rank_key: string?,
	--- The selected session.
	scursor: string?,
	speek: common.SessionPeek?,
	speeking: string?,
}

local VIEWS = { "panes", "agents", "boards", "failures", "limits", "archive" }
local FEATURES: { "edit" | "undo" } = { "edit" }
local SCOPES = { "all", "attention", "active" }
local SCOPE_LABEL: { [string]: string } = { all = "All", attention = "Attention", active = "Active" }
local GROUPS = { "none", "session", "project" }
local GROUP_LABEL: { [string]: string } = { none = "Flat", session = "Session", project = "Project" }
-- The window half sends a snapshot at least this often while it runs.
local STALE_S = 25
local TICK_MS = 15000
local MESSAGE_CHARS = 1500
-- The Archive is read again when older than this, as the view opens.
local CATALOG_TTL_S = 120
-- The deep search starts once typing has paused this long.
local SEARCH_DELAY_MS = 280
local ARCHIVE_ROWS = 200
-- Right-click actions of a pane row; sent lowercased as the action verb.
local ROW_MENU = { "Go", "Peek", "Ask", "Interrupt", "Pin", "New agent", "Park", "Archive", "Dismiss" }
local SESSION_MENU = { "Resume", "Restore", "Peek", "Copy command" }
-- "Archive idle" takes the agents that changed nothing for this long (`bulk_idle_minutes` in kv).
local BULK_IDLE_MIN = 60
-- Row-menu labels and button acts, as the verbs the window half knows.
local ACTION_VERBS: { [string]: string } = {
	go = "go",
	peek = "peek",
	ask = "ask",
	interrupt = "interrupt",
	pin = "pin",
	["new agent"] = "new_agent",
	new_agent = "new_agent",
	park = "park",
	archive = "archive",
	dismiss = "dismiss",
}
-- Actions that wait for a confirmation in the dock.
local CONFIRM: { [string]: { head: string, button: string, text: string } } = {
	interrupt = { head = "Interrupt", button = "Interrupt", text = "Sends Ctrl-C to its current turn; the agent and its block stay open." },
	archive = {
		head = "Archive",
		button = "Archive",
		text = "Asks it for a short handoff note, then closes it. It stays in the Archive with the note, ready to resume.",
	},
	archive_idle = {
		head = "Archive",
		button = "Archive all",
		text = "Asks each for a short handoff note, then closes it. They stay in the Archive with their notes, ready to resume.",
	},
}

local KIND_ICON: { [string]: string } = {
	terminal = "terminal",
	agent = "sparkle",
	plugin = "puzzle",
	browser = "globe",
	file = "file",
	git = "branch",
	database = "database",
	notebook = "note",
	board = "kanban",
	canvas = "pen",
	procs = "activity",
	screen = "monitor",
	profile = "gauge",
	carly = "sparkle",
}

-- A pane id survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	return false
end

local function cycle(list: { string }, current: string, step: number?): string
	for i, v in list do
		if v == current then
			return list[(i - 1 + (step or 1)) % #list + 1]
		end
	end
	return list[1]
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Asks every window half showing this block to act; the nonce lets only one of them do it.
local nonce_seq = 0
local function request(state: State, verb: string, target: (number | string)?)
	nonce_seq += 1
	local nonce = string.format("%x%x%x", os.time(), nonce_seq, math.random(0, 0xfffff))
	state.cx:open(common.url(verb, target, nonce))
end

--- Why `row` cannot be archived now, nil when it can: an omp agent waiting for a prompt.
local function archive_blocked(row: Row): string?
	local agent = row.agent
	if agent == nil or agent.state == "exited" then
		return "Only a running agent"
	elseif row.archiving then
		return "Already archiving"
	elseif agent.state ~= "idle" then
		return "Wait until it is waiting for a prompt"
	elseif agent.command and not string.find(string.lower(agent.command), "omp", 1, true) then
		return "Only omp agents keep a session to resume"
	end
	return nil
end

local function bulk_idle_s(): number
	local ok, value = pcall(tern.kv.get, "bulk_idle_minutes")
	return 60 * (if ok and type(value) == "number" and value >= 0 then value else BULK_IDLE_MIN)
end

--- `90m` as `1h 30m`, for the bulk archive's threshold.
local function minutes(s: number): string
	local m = s // 60
	if m < 60 then
		return m .. "m"
	end
	return (m // 60) .. "h" .. (if m % 60 > 0 then " " .. (m % 60) .. "m" else "")
end

--- The listed agents a bulk action takes: those waiting for a prompt that owe no reply
--- (`Ask all`), and among them the omp agents idle for the threshold (`Archive idle`).
local function bulk_targets(state: State): ({ number }, { number })
	local ask: { number } = {}
	local idle: { number } = {}
	local now = os.time()
	local threshold = bulk_idle_s()
	for _, e in state.order do
		local row = e.row
		local agent = row.agent
		if agent and agent.state == "idle" and not row.archiving then
			local update = row.update
			if not (update and update.reply == nil) then
				table.insert(ask, row.pane)
			end
			if archive_blocked(row) == nil and e.recent > 0 and now - e.recent >= threshold then
				table.insert(idle, row.pane)
			end
		end
	end
	return ask, idle
end

local function join_panes(panes: { number }): string
	local ids: { string } = {}
	for _, pane in panes do
		table.insert(ids, common.id(pane))
	end
	return table.concat(ids, "-")
end

--- Rows from the host's own pane list, used until a window half reports.
local function fallback_rows(self: number): { Row }
	local rows: { Row } = {}
	for _, p in tern.pane.list() do
		if p.pane ~= self and p.program ~= common.KIND then
			table.insert(rows, {
				pane = p.pane,
				kind = "pane",
				title = p.title,
				program = p.program,
				cwd = p.cwd or "",
				parked = false,
				focused = false,
				busy = p.busy == true,
				alert = false,
			})
		end
	end
	return rows
end

local function project_of(row: Row): string
	return if row.cwd ~= "" then common.basename(row.cwd) else "(unknown directory)"
end

-- A node key from any text: `.` would split the node id, so escape everything else.
local function keyof(s: string): string
	return (string.gsub(s, "[^%w%-]", function(c: string): string
		return string.format("_%02x", string.byte(c))
	end))
end

local function where(row: Row, snap: Snapshot?): string
	local parts = {}
	if snap and row.session then
		for _, s in snap.sessions do
			if s.id == row.session then
				table.insert(parts, s.name)
			end
		end
	end
	if row.parked then
		table.insert(parts, "parked")
	elseif row.tab_pos then
		table.insert(parts, "tab " .. row.tab_pos .. (if row.tab_name then " " .. common.clip(row.tab_name, 24) else ""))
	end
	return table.concat(parts, " › ")
end

--- Every word of `query` appears in what the row shows (or its full title, directory and command).
local function matches(row: Row, place: string, status: Status, query: string): boolean
	if query == "" then
		return true
	end
	local hay: { string } = {}
	local function add(v: any)
		if type(v) == "string" then
			table.insert(hay, v)
		end
	end
	add(row.title)
	add(common.label(row))
	add(row.path)
	add(row.url)
	add(row.session_title)
	add(row.cwd)
	add(row.program)
	add(row.kind)
	add(place)
	add(status.text)
	add(status.level)
	add(row.tab_name)
	add(if row.running then row.running.line else nil)
	add(if row.last then row.last.line else nil)
	local agent = row.agent
	if agent then
		add(agent.command)
		add(agent.model)
	end
	local text = string.lower(table.concat(hay, "\n"))
	for word in string.gmatch(string.lower(query), "%S+") do
		if string.find(text, word, 1, true) == nil then
			return false
		end
	end
	return true
end

local function in_scope(scope: string, status: Status): boolean
	if scope == "attention" then
		return status.level == "attention"
	elseif scope == "active" then
		return status.level ~= "idle"
	end
	return true
end

local function recent_of(row: Row): number
	local update = row.update
	local asked = if update then math.max(update.asked_at, update.reply_at or 0) else 0
	return math.max(row.active_at or 0, row.finished_at or 0, row.message_at or 0, asked)
end

local function before(a: Entry, b: Entry): boolean
	if a.status.rank ~= b.status.rank then
		return a.status.rank < b.status.rank
	end
	if a.recent ~= b.recent then
		return a.recent > b.recent
	end
	local sa, sb = a.row.tab_pos or math.huge, b.row.tab_pos or math.huge
	if sa ~= sb then
		return sa < sb
	end
	return a.row.pane < b.row.pane
end

type Counts = { [string]: number }

--- Every row as an entry, filtered and grouped; groups in display order. The
--- counts cover every row (before filter and scope), per level and for agents.
local function layout(state: State): ({ Group }, Counts, number)
	local snap = state.snap
	local rows: { Row } = if snap then snap.rows else fallback_rows(state.cx.pane)
	local session_names: { [number]: string } = {}
	local session_order: { [number]: number } = {}
	if snap then
		for i, s in snap.sessions do
			session_names[s.id] = s.name
			session_order[s.id] = i
		end
	end
	local acks = common.acks()
	local counts: Counts = { attention = 0, running = 0, waiting = 0, idle = 0, agents = 0, agents_waiting = 0, agents_working = 0, commands = 0, failed = 0, unseen = 0 }
	local total = 0
	local groups: { [string]: Group } = {}
	local list: { Group } = {}
	local only_agents = state.view == "agents"
	for _, row in rows do
		local status = common.classify(row, acks)
		counts[status.level] += 1
		total += 1
		local agent = row.agent
		if agent then
			counts.agents += 1
			if agent.state == "waiting_input" then
				counts.agents_waiting += 1
			elseif agent.state == "working" then
				counts.agents_working += 1
			end
		elseif row.running then
			counts.commands += 1
		end
		if status.level == "attention" then
			if status.tone == "error" then
				counts.failed += 1
			elseif not (agent and agent.state == "waiting_input") then
				counts.unseen += 1
			end
		end
		if (not only_agents or agent ~= nil) and in_scope(state.scope, status) and matches(row, where(row, snap), status, state.filter) then
			local key, label, order = "all", "", 0
			if state.group == "session" then
				if row.session and session_names[row.session] then
					key = "s" .. common.id(row.session)
					label = session_names[row.session]
					order = session_order[row.session]
				else
					key, label, order = "s-none", if row.parked then "Parked" else "No session", math.huge
				end
			elseif state.group == "project" then
				label = project_of(row)
				key = "d-" .. keyof(string.lower(label))
			end
			local entry: Entry = {
				row = row,
				status = status,
				recent = recent_of(row),
				group = key,
				group_label = label,
				group_order = order,
			}
			local g = groups[key]
			if g == nil then
				g = { key = key, label = label, order = order, entries = {}, best = entry }
				groups[key] = g
				table.insert(list, g)
			end
			table.insert(g.entries, entry)
			if before(entry, g.best) then
				g.best = entry
			end
		end
	end
	for _, g in list do
		table.sort(g.entries, before)
	end
	table.sort(list, function(a: Group, b: Group): boolean
		if a.best.status.rank ~= b.best.status.rank then
			return a.best.status.rank < b.best.status.rank
		end
		if state.group == "session" and a.order ~= b.order then
			return a.order < b.order
		end
		if a.best.recent ~= b.best.recent then
			return a.best.recent > b.best.recent
		end
		return a.label < b.label
	end)
	return list, counts, total
end

--- The entries of every group in display order.
local function flatten(groups: { Group }): { Entry }
	local out: { Entry } = {}
	for _, g in groups do
		for _, e in g.entries do
			table.insert(out, e)
		end
	end
	return out
end

local function selected(state: State): Entry?
	for _, e in state.order do
		if e.row.pane == state.cursor then
			return e
		end
	end
	return nil
end

--- The row's latest result in one line, as Tern reported it.
local function result_spans(row: Row): { Span }
	local agent = row.agent
	local update = row.update
	if agent and update and update.reply then
		return { ui.span("update: ", "info"), ui.span(common.clip(update.reply, 48), "muted") }
	end
	if agent and agent.message then
		return { ui.span(common.clip(agent.message, 56), "muted") }
	end
	local last = row.last
	if last then
		local line = if last.line ~= "" then common.clip(last.line, 36) else "(command)"
		local exit, tone = common.exit_text(last.status)
		return {
			ui.span(line, "mono"),
			ui.span("  " .. exit, tone),
			ui.span(" · " .. common.duration(last.took_ms), "muted"),
		}
	end
	return {}
end

local function row_id(pane: number): string
	return "p" .. common.id(pane)
end

--- The pane a table row or event item names, from its `p<pane>` id.
local function pane_of(item: any): number?
	local id = string.match(tostring(item or ""), "p(%d+)$")
	return if id then tonumber(id) else nil
end

-- Status is an icon and a word (the full sentence is the tooltip and the card's).
-- Where a pane lives is not a column: grouping by session or project says it, and
-- the card's head and the filter keep it.
local PANE_COLS: { Col } = {
	{ id = "name", head = "Pane", grow = 1, priority = 9 },
	{ id = "status", head = "Status", priority = 8 },
	{ id = "last", head = "Last", grow = 1, priority = 6 },
	{ id = "age", head = "Age", align = "end", mono = true, priority = 5 },
}

local function pane_table(state: State, entries: { Entry }, key: string, empty: string): Node
	local rows: { any } = {}
	for _, e in entries do
		local row = e.row
		local level = e.status.level
		local name: { Span } = { ui.span(common.label(row), if level == "attention" then "strong" else "") }
		if row.focused then
			table.insert(name, ui.span("  ●", "accent"))
		end
		local status_tone = if level == "idle" then "muted" else e.status.tone
		table.insert(rows, {
			id = row_id(row.pane),
			menu = ROW_MENU,
			title = if row.cwd ~= "" then row.cwd else nil,
			cells = {
				name = { text = name },
				status = { text = { ui.span(e.status.word, status_tone) }, icon = e.status.icon, tone = status_tone, title = e.status.text },
				last = result_spans(row),
				age = { ui.span(if e.recent > 0 then common.ago(e.recent) else "", "muted") },
			},
		})
	end
	return ui.node("table", {
		key = key,
		role = "control-room.panes",
		cols = PANE_COLS,
		rows = rows,
		selectable = true,
		selected = if state.cursor then row_id(state.cursor) else nil,
		empty = { ui.span(empty, "muted") },
	})
end

local FAIL_COLS: { Col } = {
	{ id = "line", head = "Command", grow = 1, mono = true, priority = 9 },
	{ id = "pane", head = "Pane", priority = 6, truncate = "middle" },
	{ id = "exit", head = "Exit", align = "end", mono = true, priority = 8 },
	{ id = "took", head = "Took", align = "end", mono = true, priority = 5 },
	{ id = "when", head = "When", align = "end", mono = true, priority = 7 },
}

local function failures_table(state: State): Node
	local snap = state.snap
	local rows: { any } = {}
	if snap then
		for i, f in snap.failures do
			local exit, tone = common.exit_text(f.status)
			local slip = common.slip(f.line, f.status, f.took_ms)
			table.insert(rows, {
				id = "f" .. i .. "-" .. row_id(f.pane),
				menu = { "Go", "Peek" },
				title = if slip then "Probably a typing slip: it failed at once" else nil,
				cells = {
					line = { ui.span(if f.line ~= "" then common.clip(f.line, 120) else "(line not reported)", if slip then "muted" else "") },
					pane = { ui.span(common.clip(f.title, 40), "muted") },
					exit = { ui.span(exit, if slip then "muted" else tone) },
					took = { ui.span(common.duration(f.took_ms), "muted") },
					when = { ui.span(common.ago(f.at), "muted") },
				},
			})
		end
	end
	return ui.node("table", {
		key = "table",
		cols = FAIL_COLS,
		rows = rows,
		selectable = true,
		empty = { ui.span("No command has failed since this window loaded the plugin", "muted") },
	})
end

local function chat_nodes(peek: Peek): { Node }
	local out: { Node } = {}
	local chat = peek.chat
	if chat == nil or #chat == 0 then
		return out
	end
	table.insert(out, with(ui.rule("Transcript · last " .. #chat), { key = "chat-rule" }))
	for i, m in chat do
		local who = if m.role == "user" then "you" else "agent"
		table.insert(out, with(ui.text({ ui.span(who, "strong muted") }), { key = "who" .. i }))
		table.insert(out, with(ui.md(m.text), { key = "chat" .. i }))
	end
	return out
end

local function peek_nodes(state: State, pane: number): { Node }
	local out: { Node } = {}
	local peek = state.peek
	if peek == nil or peek.pane ~= pane then
		return out
	end
	local head = "Last lines · " .. common.since(peek.at)
	if peek.more and peek.more > 0 then
		head ..= " · " .. peek.more .. " more above"
	end
	table.insert(out, with(ui.rule(head), { key = "peek-rule" }))
	if peek.error then
		table.insert(out, with(ui.text({ ui.span(peek.error, "error") }), { key = "peek-err" }))
	elseif peek.lines and #peek.lines > 0 then
		table.insert(out, with(ui.ansi(table.concat(peek.lines, "\n")), { key = "peek" }))
	elseif peek.text and peek.text ~= "" then
		table.insert(out, with(ui.code(common.cut(peek.text, 4000)), { key = "peek" }))
	else
		table.insert(out, with(ui.text({ ui.span("(nothing shown)", "muted") }), { key = "peek-none" }))
	end
	for _, n in chat_nodes(peek) do
		table.insert(out, n)
	end
	return out
end

local function sm(text: string, act: string, props: { [string]: any }): Node
	local p: { [string]: any } = { key = act, size = "sm", actions = { click = act } }
	for k, v in props do
		p[k] = v
	end
	return ui.button(text, p)
end

local function detail_card(state: State, entry: Entry?, rows: number): Node
	local props: { [string]: any } = { key = "detail", role = "control-room.card", min = { w = "38ch" }, max = { w = "48ch" } }
	if entry == nil then
		return ui.card("No pane selected", { ui.text({ ui.span("Select a row to see what it is doing", "muted") }) }, props)
	end
	local row = entry.row
	local snap = state.snap
	local level = entry.status.level
	local agent = row.agent
	local online = snap ~= nil and os.time() - (state.received or 0) <= STALE_S
	local is_agent = agent ~= nil and agent.state ~= "exited"
	local has_problem = common.problem(row) ~= nil
	local offline = if online then nil else "Control Room is not getting updates from the window"

	local facts: { { Spans } } = {}
	local function fact(k: string, v: Spans)
		table.insert(facts, { k :: Spans, v })
	end
	fact("status", { ui.span(entry.status.text, if level == "idle" then "muted" else entry.status.tone) })
	if row.cwd ~= "" then
		fact("directory", { ui.path(row.cwd) })
	end
	if row.program then
		fact("program", { ui.span(row.program, "mono") })
	end
	local running = row.running
	if running then
		fact("running", { ui.span(common.clip(running.line, 120), "mono"), ui.span(" · " .. common.duration(running.ms), "muted") })
	end
	local last = row.last
	if last then
		local exit, tone = common.exit_text(last.status)
		fact("last command", {
			ui.span(if last.line ~= "" then common.clip(last.line, 120) else "(line not reported)", "mono"),
			ui.span("  " .. exit, tone),
			ui.span(" · " .. common.duration(last.took_ms) .. (if row.finished_at then " · " .. common.since(row.finished_at) else ""), "muted"),
		})
	end
	if row.exited ~= nil then
		local exit, tone = common.exit_text(row.exited)
		fact("exited", { ui.span(exit, tone) })
	end
	if agent then
		fact("agent", { ui.span(agent.state, "strong"), ui.span(if agent.model then " · " .. agent.model else "", "muted") })
		if agent.command then
			fact("command", { ui.span(common.clip(agent.command, 120), "mono") })
		end
		if agent.failed_at then
			fact("last turn", { ui.span("failed", "error"), ui.span(" · " .. common.since(agent.failed_at), "muted") })
		end
		local update = row.update
		if update then
			fact("update asked", common.since(update.asked_at))
		end
	end

	local children: { Node } = {}
	-- The head's end: the one primary action, on the selected pane.
	table.insert(children, ui.node("row", { key = "end", gap = "sm" }, {
		ui.button("Go", { key = "go", variant = "primary", size = "sm", keys = { "enter" }, disabled = offline, actions = { click = "go" } }),
	}))
	-- Everything under the head scrolls as one box, capped like the table is:
	-- the pane's height in cells (about 16px) minus the page chrome above the
	-- card and the card's head (about 275px), in sans lines of 18px.
	local body: { Node } = {}
	table.insert(body, with(ui.kv(facts), { key = "facts" }))
	local not_agent = if is_agent then nil else "Only a running agent"
	table.insert(body, ui.node("row", { key = "actions", gap = "sm", wrap = true }, {
		sm("Peek", "peek", { icon = "eye", keys = { "." }, busy = state.peeking == row.pane, disabled = offline }),
		sm("Ask", "ask", { icon = "message", keys = { "u" }, disabled = offline or not_agent }),
		sm("Interrupt", "interrupt", { icon = "stop", keys = { "i" }, variant = "danger", disabled = offline or not_agent }),
		sm(if row.floating then "Unpin" else "Pin", "pin", { icon = "pin", keys = { "f" }, on = row.floating == true, disabled = offline }),
		sm("New agent", "new_agent", { icon = "sparkle", keys = { "n" }, disabled = offline or (if row.cwd ~= "" then nil else "No known directory") }),
		sm(if row.parked then "Restore" else "Park", "park", { icon = "stack", keys = { "p" }, disabled = offline }),
		sm("Archive", "archive", { icon = "archive", keys = { "a" }, disabled = offline or archive_blocked(row) }),
		sm("Dismiss", "dismiss", { icon = "check", keys = { "x" }, disabled = if has_problem then nil else "Nothing to dismiss on this pane" }),
	}))
	local services: { common.Service } = row.services or {}
	if #services > 0 then
		table.insert(body, with(ui.rule("Services"), { key = "services-rule" }))
		for i, service in services do
			local exit, exit_tone = service.state, "muted"
			if service.exit ~= nil then
				exit, exit_tone = common.exit_text(service.exit)
			end
			local tone = if service.running then "accent" elseif exit_tone == "error" then "error" else "muted"
			local description = if service.running then service.state else exit
			local when = common.since(service.at)
			table.insert(body, with(ui.text({ ui.span("● ", tone), ui.span(service.name, "strong"), ui.span(" · " .. description .. " · ", tone), ui.span(common.clip(service.command, 120), "mono"), ui.span(if when ~= "" then " · " .. when else "", "muted") }), { key = "service" .. i }))
		end
	end
	local update = if agent then row.update else nil
	if update then
		local head = if update.reply
			then "Reply to the update request · " .. common.since(update.reply_at)
			else "Update requested · waiting for the reply"
		table.insert(body, with(ui.rule(head), { key = "upd-rule" }))
		if update.reply then
			table.insert(body, with(ui.md(common.cut(update.reply, MESSAGE_CHARS)), { key = "upd" }))
		end
	end
	-- The last message, unless it is the reply shown above.
	if agent and agent.message and not (update and update.reply == agent.message) then
		local head = "Last message from the agent" .. (if row.message_at then " · " .. common.since(row.message_at) else "")
		table.insert(body, with(ui.rule(head), { key = "msg-rule" }))
		table.insert(body, with(ui.md(common.cut(agent.message, MESSAGE_CHARS)), { key = "msg" }))
	end
	-- What omp itself last summed the session up as: where it stands, without asking.
	if agent and row.recap then
		table.insert(body, with(ui.rule("omp's last recap" .. (if row.recap_at then " · " .. common.since(row.recap_at) else "")), { key = "recap-rule" }))
		table.insert(body, with(ui.md(row.recap), { key = "recap" }))
	end
	for _, n in peek_nodes(state, row.pane) do
		table.insert(body, n)
	end
	local cap = math.max(4, math.floor((rows * 16 - 275) / 18))
	table.insert(children, ui.node("scroll", { key = "body", role = "control-room.scroll", variant = "fade", gap = "sm", max = { h = cap .. "lines" } }, body))

	props.icon = if row.parked then "stack" else KIND_ICON[row.kind] or "terminal"
	props.meta = where(row, snap) .. (if row.cwd ~= "" then " · " .. project_of(row) else "")
	props["end"] = "main." .. state.view .. ".body.detail.end"
	-- The ring takes a tone only when the whole pane needs attention.
	if level == "attention" then
		props.tone = entry.status.tone
	end
	return ui.card(common.label(row), children, props)
end

local function head_row(state: State, total: number): Node
	local snap = state.snap
	local meta = { tostring(total) .. (if total == 1 then " pane" else " panes") }
	if snap then
		table.insert(meta, #snap.sessions .. (if #snap.sessions == 1 then " session" else " sessions"))
		table.insert(meta, "updated " .. common.since(state.received))
	end
	local pause = state.pause
	if pause and pause.ends_at and pause.ends_at <= os.time() then
		state.pause = nil
		pause = nil
	end
	local link: Node
	local recovery = " Tern resumes a paused hook by itself within 5 minutes; Reload plugins restarts it now."
	if pause and pause.state == "paused" then
		local left = if pause.ends_at then " " .. math.max(0, math.ceil(pause.ends_at - os.time())) .. "s" else ""
		link = with(ui.badge("Paused" .. left, "warning"), { key = "link", title = "A window hook ran over its time budget. Tern resumes it by itself." })
	elseif snap == nil then
		link = with(ui.badge("No window report", "warning"), { key = "link", title = "Showing only what this host knows (titles, directories, busy)." .. recovery })
	elseif os.time() - (state.received or 0) > STALE_S then
		link = with(ui.badge("Stale " .. common.ago(state.received), "warning"), { key = "link", title = "No report from the window: the list may be out of date." .. recovery })
	else
		link = with(ui.badge("Live", "success"), { key = "link", title = "The window reports every change and at least every 15 seconds" })
	end
	return ui.node("row", { key = "head", justify = "between", align = "center" }, {
		ui.node("text", { key = "title", spans = { ui.span("Control Room", "title"), ui.span("   " .. table.concat(meta, " · "), "muted") }, lines = 1 }),
		ui.node("row", { key = "end", gap = "sm", align = "center" }, {
			link,
			ui.button("Refresh", { key = "refresh", icon = "repeat", keys = { "r" }, actions = { click = "refresh" } }),
		}),
	})
end

--- The limit with the highest known usage, or nil when none reports usage.
local function worst_limit(report: common.Usage): common.Limit?
	local worst: common.Limit? = nil
	for _, limit in report.limits do
		if limit.used ~= nil and (worst == nil or limit.used > (worst.used or -math.huge)) then
			worst = limit
		end
	end
	return worst
end

--- The limits summary tile for the latest report.
local function limit_tile(report: common.Usage?): StatItem
	if report == nil then
		return { label = "Limits", value = "…", sub = "not read yet" }
	end
	local worst = worst_limit(report)
	local used = if worst then worst.used else nil
	-- The tile's tone is the worst window's use; credentials omp stopped using
	-- are a separate problem, told in the subtitle, not by painting the number.
	local exhausted = false
	for _, limit in report.limits do
		if limit.status == "exhausted" then
			exhausted = true
		end
	end
	local sub: Spans
	if worst == nil and #report.errors > 0 then
		sub = { ui.span("could not read: " .. table.concat(report.errors, ", "), "warning") }
	elseif #report.off > 0 then
		sub = { ui.span(#report.off .. (if #report.off == 1 then " credential off" else " credentials off"), "warning") }
	elseif worst then
		sub = worst.provider .. " · " .. worst.label .. (if worst.resets_at then " · resets in " .. common.duration(math.max(0, worst.resets_at - os.time()) * 1000) else "")
	elseif #report.errors > 0 then
		sub = { ui.span("could not read: " .. table.concat(report.errors, ", "), "warning") }
	else
		sub = "read " .. common.since(report.at)
	end
	return { label = "Limits", value = if used then string.format("%.0f%%", used * 100) else "—", sub = sub, tone = if exhausted or (used and used >= 1) then "error" elseif used and used >= 0.8 then "warning" else nil }
end

local LIMIT_COLS: { Col } = {
	{ id = "window", head = "Window", priority = 9 },
	{ id = "used", head = "Used", grow = 1, priority = 9 },
	{ id = "percent", head = "%", align = "end", mono = true, priority = 8 },
	{ id = "reset", head = "Resets", align = "end", mono = true, priority = 6 },
}
local OFF_COLS: { Col } = {
	{ id = "provider", head = "Provider", priority = 9 },
	{ id = "account", head = "Account", truncate = "middle", priority = 4 },
	{ id = "cause", head = "Cause", grow = 1, priority = 8 },
	{ id = "since", head = "Since", align = "end", mono = true, priority = 6 },
}

--- The limits, one section per provider account, and the credentials omp stopped using.
local function limits_nodes(report: common.Usage?): { Node }
	if report == nil then
		return { ui.node("skeleton", { key = "reading", shape = "rows", rows = 4 }) }
	end
	local nodes: { Node } = {}
	for i, problem in report.errors do
		table.insert(nodes, with(ui.text({ ui.span(problem, "warning") }), { key = "error" .. i }))
	end
	local groups = common.group_limits(report.limits)
	for gi, g in groups do
		local rows: { TableRow } = {}
		for li, limit in g.limits do
			local used = limit.used
			table.insert(rows, {
				id = "l" .. li,
				cells = {
					limit.label,
					if used ~= nil then ui.meter_cell(math.clamp(used, 0, 1), { 0.8, 1 }) else { ui.span("—", "muted") },
					{ ui.span(if used ~= nil then string.format("%.0f%%", used * 100) else "—", if used and used >= 1 then "error" elseif used and used >= 0.8 then "warning" elseif used and used > 0 then "" else "muted") },
					{ ui.span(if limit.resets_at then "in " .. common.duration(math.max(0, limit.resets_at - os.time()) * 1000) else "", "muted") },
				},
			})
		end
		local head: { Span } = { ui.span(g.provider, "strong") }
		if g.account then table.insert(head, ui.span("  " .. g.account, "muted")) end
		local tbl = with(ui.table(LIMIT_COLS, rows, nil), { key = "t", role = "control-room.limits" })
		table.insert(nodes, with(ui.section(head, { tbl }), { key = "g" .. gi, collapsible = true }))
	end
	if #groups == 0 then
		table.insert(nodes, ui.node("empty", { key = "none", variant = "inline", icon = "gauge", text = "omp reported no provider limits" }))
	end
	if #report.off > 0 then
		local off: { TableRow } = {}
		for i, credential in report.off do
			table.insert(off, {
				id = "c" .. i,
				title = credential.cause,
				cells = {
					credential.provider,
					{ ui.span(credential.account or "", "muted") },
					{ ui.span(common.short_cause(credential.cause), "warning") },
					{ ui.span(common.ago(credential.at), "muted") },
				},
			})
		end
		table.insert(nodes, with(ui.section({ ui.span("Credentials not in use", "strong"), ui.span("  " .. #report.off, "muted") }, {
			with(ui.table(OFF_COLS, off, nil), { key = "t" }),
		}), { key = "off", collapsible = true }))
	end
	return nodes
end

local function stats_strip(state: State, counts: Counts): Node
	local function n(v: number): string
		return tostring(v)
	end
	local att_sub = {}
	if counts.agents_waiting > 0 then
		table.insert(att_sub, counts.agents_waiting .. (if counts.agents_waiting == 1 then " agent waiting" else " agents waiting"))
	end
	if counts.failed > 0 then
		table.insert(att_sub, counts.failed .. " failed")
	end
	if counts.unseen > 0 then
		table.insert(att_sub, counts.unseen .. " not seen yet")
	end
	local run_sub = {}
	if counts.agents_working > 0 then
		table.insert(run_sub, counts.agents_working .. (if counts.agents_working == 1 then " agent" else " agents"))
	end
	if counts.commands > 0 then
		table.insert(run_sub, counts.commands .. (if counts.commands == 1 then " command" else " commands"))
	end
	local items: { StatItem } = {
		{ label = "Attention", value = n(counts.attention), tone = if counts.attention > 0 then "error" else nil, sub = if #att_sub > 0 then table.concat(att_sub, " · ") else "nothing waits on you" },
		{ label = "Running", value = n(counts.running), sub = if #run_sub > 0 then table.concat(run_sub, " · ") else nil },
		{ label = "Waiting", value = n(counts.waiting), sub = if counts.waiting > 0 then "agents at a prompt" else nil },
		{ label = "Idle", value = n(counts.idle) },
		limit_tile(state.usage),
	}
	return ui.node("stats", { key = "stats", items = items })
end

--- View tabs. A count shows only once its data has been read: no `0` or `…` standing in.
local function nav(state: State, total: number, counts: Counts): Node
	local snap = state.snap
	local function tab(id: string, label: string, count: number?, tone: string?): { [string]: any }
		return { id = id, label = if count then { ui.span(label .. " "), ui.span(tostring(count), tone or "muted") } else { ui.span(label) } }
	end
	local fails = if snap then #snap.failures else nil
	return ui.node("tabs", { key = "nav", active = state.view, items = {
		tab("panes", "Panes", if snap then total else nil),
		tab("agents", "Agents", if snap then counts.agents else nil),
		tab("boards", "Boards", if state.board_report then #state.board_report.boards else nil),
		tab("failures", "Failures", if fails and fails > 0 then fails else nil),
		tab("limits", "Limits", if state.usage and #state.usage.off > 0 then #state.usage.off else nil, "warning"),
		tab("archive", "Archive", if state.catalog then #state.catalog.sessions else nil),
	} })
end

local function toolbar(state: State): Node
	local archive_view = state.view == "archive"
	local text = if archive_view then state.query else state.filter
	local filter = ui.node("input", {
		key = "filter",
		text = text,
		cursor = state.caret,
		placeholder = if archive_view then "Search titles, notes, recaps and every prompt you sent" else "Filter panes",
		icon = "search",
		keys = { "/" },
		clear = true,
		max = { w = if archive_view then "64ch" else "40ch" },
		grow = 1,
	})
	if archive_view then
		local meta: { Span } = {}
		local catalog = state.catalog
		if catalog then
			table.insert(meta, ui.span(#state.ranked .. " of " .. #catalog.sessions, "muted"))
			if catalog.open > 0 then
				table.insert(meta, ui.span(" · " .. catalog.open .. " open elsewhere", "muted"))
			end
			if not catalog.lease then
				table.insert(meta, ui.span(" · open sessions not checked", "warning"))
			end
		end
		if state.deep_sent and state.deep_key ~= state.deep_sent_key then
			table.insert(meta, ui.span(" · searching prompts…", "info"))
		end
		return ui.node("row", { key = "bar", justify = "between", align = "center", gap = "md" }, {
			filter,
			ui.node("text", { key = "end", spans = meta, lines = 1 }),
		})
	end
	local function seg(key: string, active: string, list: { string }, labels: { [string]: string }): Node
		local items = {}
		for _, v in list do
			table.insert(items, { id = v, label = labels[v] })
		end
		return ui.node("tabs", { key = key, variant = "segmented", active = active, items = items })
	end
	local tools: { Node } = {}
	if state.view == "agents" then
		local ask, idle = bulk_targets(state)
		local offline = if state.snap ~= nil and os.time() - (state.received or 0) <= STALE_S then nil else "Control Room is not getting updates from the window"
		table.insert(tools, sm("Ask all " .. #ask, "ask_all", {
			icon = "message",
			keys = { "U" },
			title = "Send one message (the status check, to rewrite) to every listed agent waiting for a prompt",
			disabled = offline or (if #ask > 0 then nil else "No listed agent is waiting for a prompt"),
		}))
		table.insert(tools, sm("Archive idle " .. #idle, "archive_idle", {
			icon = "archive",
			keys = { "A" },
			title = "Archive every listed omp agent that has been waiting for over " .. minutes(bulk_idle_s()),
			disabled = offline or (if #idle > 0 then nil else "No listed omp agent has been waiting for over " .. minutes(bulk_idle_s())),
		}))
	end
	table.insert(tools, seg("scope", state.scope, SCOPES, SCOPE_LABEL))
	table.insert(tools, seg("group", state.group, GROUPS, GROUP_LABEL))
	return ui.node("row", { key = "bar", justify = "between", align = "center", gap = "md", wrap = true }, {
		filter,
		ui.node("row", { key = "end", gap = "sm", align = "center", wrap = true }, tools),
	})
end

--- The table (or one per group) of the current pane view.
local function pane_lists(state: State, groups: { Group }): Node
	local empty = if state.filter ~= "" then "Nothing matches the filter"
		elseif state.scope ~= "all" then "Nothing in this scope"
		elseif state.view == "agents" then "No agents are open"
		else "No other panes"
	if state.group == "none" then
		local entries = if groups[1] then groups[1].entries else {}
		return pane_table(state, entries, "table", empty)
	end
	if #groups == 0 then
		return ui.node("empty", { key = "table", variant = "inline", frame = true, icon = "search", text = empty }, {
			ui.button("Clear filter", { key = "clear", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "clear" } }),
		})
	end
	local sections: { Node } = {}
	for _, g in groups do
		local att = 0
		for _, e in g.entries do
			if e.status.level == "attention" then
				att += 1
			end
		end
		local head: { Span } = { ui.span(g.label, "strong"), ui.span("  " .. #g.entries, "muted") }
		if att > 0 then
			table.insert(head, ui.span("  " .. att .. " need attention", "error"))
		end
		table.insert(sections, with(ui.section(head, { pane_table(state, g.entries, "table", empty) }), { key = "g-" .. g.key, collapsible = true }))
	end
	return ui.node("col", { key = "table", gap = "md" }, sections)
end

-- The Archive ---------------------------------------------------------------

--- The search words as one key, to tell which results belong to which words.
local function terms_key(terms: { string }): string
	return table.concat(terms, " ")
end

local function ask_catalog(state: State)
	state.catalog_asked = os.time()
	request(state, "catalog", nil)
end

--- Schedules the deep search for the current words, once typing pauses.
local function schedule_deep(state: State)
	local index = state.index
	local terms = common.terms(state.query)
	local key = terms_key(terms)
	if index == nil or #terms == 0 or key == state.deep_wanted then
		return
	end
	state.deep_wanted = key
	if state.search_timer then
		state.search_timer:cancel()
	end
	state.search_timer = tern.timer(SEARCH_DELAY_MS, function()
		state.search_timer = nil
		if running[state.cx.pane] ~= state or terms_key(common.terms(state.query)) ~= key then
			return
		end
		local body = tern.json.encode(archive.variants(index, terms))
		state.deep_sent = body
		state.deep_sent_key = key
		request(state, "search", tern.base64.encode(body, { url = true }))
		state.cx:render()
	end)
end

--- The Archive in display order for the current words; ranked again only when they or the data change.
local function ranked(state: State): { Ranked }
	local index = state.index
	if index == nil then
		state.ranked = {}
		return state.ranked
	end
	local terms = common.terms(state.query)
	local key = terms_key(terms)
	local deep = if state.deep_key == key then state.deep else nil
	local rank_key = key .. "\0" .. (if deep then tostring(state.deep_stamp) else "-")
	if state.rank_key ~= rank_key then
		state.rank_key = rank_key
		state.ranked = archive.rank(index, terms, deep)
	end
	return state.ranked
end

local function selected_session(state: State): Ranked?
	for _, r in state.ranked do
		if r.doc.s.id == state.scursor then
			return r
		end
	end
	return nil
end

--- `text` with each search word in bold, matched without case or accents (prompts snippets come marked).
local function marked(text: string, terms: { string }, tone: string): { Span }
	local out: { Span } = {}
	if string.find(text, "\2", 1, true) then
		for plain, hit in string.gmatch(text .. "\2\3", "([^\2]*)\2([^\3]*)\3") do
			if plain ~= "" then
				table.insert(out, ui.span(plain, tone))
			end
			if hit ~= "" then
				table.insert(out, ui.span(hit :: string, "strong"))
			end
		end
		return out
	end
	local folded = common.fold(text)
	-- Folding keeps byte offsets only for ASCII; otherwise show it plain.
	if #folded ~= #text or #terms == 0 then
		return { ui.span(text, tone) }
	end
	local at = 1
	while at <= #text do
		local best_s, best_e = nil :: number?, nil :: number?
		for _, t in terms do
			local s, e = string.find(folded, t, at, true)
			if s and (best_s == nil or s < best_s) then
				best_s, best_e = s, e
			end
		end
		if best_s == nil or best_e == nil then
			table.insert(out, ui.span(string.sub(text, at), tone))
			break
		end
		if best_s > at then
			table.insert(out, ui.span(string.sub(text, at, best_s - 1), tone))
		end
		table.insert(out, ui.span(string.sub(text, best_s, best_e), "strong"))
		at = best_e + 1
	end
	return out
end

--- What a session row says about where it stood: the snippet that matched, else its note, recap or last prompt.
local function gist(r: Ranked): (string?, string)
	local s = r.doc.s
	if r.snippet then
		return r.snippet, "prompt"
	elseif s.note then
		return s.note, "note"
	elseif s.recap then
		return s.recap, "recap"
	end
	return s.prompt, "prompt"
end

local function session_label(s: common.Session): string
	return common.clip(s.title or s.prompt or s.id, 80)
end

local ARCHIVE_COLS: { Col } = {
	{ id = "name", head = "Session", grow = 1, priority = 9 },
	{ id = "project", head = "Project", priority = 6, truncate = "middle" },
	{ id = "last", head = "Where it stood", grow = 1, priority = 7 },
	{ id = "age", head = "Age", align = "end", mono = true, priority = 8 },
}

local function archive_table(state: State, list: { Ranked }): Node
	local terms = common.terms(state.query)
	local rows: { any } = {}
	for i, r in list do
		if i > ARCHIVE_ROWS then
			break
		end
		local s = r.doc.s
		local text, from = gist(r)
		local last: { Span } = {}
		if text then
			if from == "note" then
				table.insert(last, ui.span("note: ", "info"))
			end
			for _, sp in marked(common.clip(text, 90), terms, "muted") do
				table.insert(last, sp)
			end
		end
		table.insert(rows, {
			id = "s" .. s.id,
			menu = SESSION_MENU,
			title = s.cwd,
			cells = {
				name = { text = marked(session_label(s), terms, ""), icon = if s.note then "archive" else "sparkle", tone = "muted" },
				project = marked(r.doc.project, terms, "muted"),
				last = last,
				age = { ui.span(common.ago(s.at), "muted") },
			},
		})
	end
	local empty = if state.catalog == nil
		then "Reading omp's sessions…"
		elseif state.query ~= "" then "No closed session matches every word"
		else "No closed sessions"
	return ui.node("table", {
		key = "table",
		cols = ARCHIVE_COLS,
		rows = rows,
		selectable = true,
		selected = if state.scursor then "s" .. state.scursor else nil,
		empty = { ui.span(empty, "muted") },
	})
end

local function said_nodes(key: string, head: string, list: { common.Said }?, md: boolean): { Node }
	local out: { Node } = {}
	if list == nil or #list == 0 then
		return out
	end
	table.insert(out, with(ui.rule(head), { key = key .. "-rule" }))
	for i, said in list do
		table.insert(out, with(ui.text({ ui.span(common.since(said.at), "strong muted") }), { key = key .. "-at" .. i }))
		table.insert(out, with(if md then ui.md(said.text) else ui.text({ ui.span(said.text) }), { key = key .. i }))
	end
	return out
end

local function session_card(state: State, r: Ranked?, rows: number): Node
	local props: { [string]: any } = { key = "detail", role = "control-room.card", min = { w = "44ch" }, max = { w = "60ch" } }
	if r == nil then
		return ui.card("No session selected", { ui.text({ ui.span("Select a closed session to see where it stood", "muted") }) }, props)
	end
	local s = r.doc.s
	local terms = common.terms(state.query)
	local offline = if state.snap ~= nil and os.time() - (state.received or 0) <= STALE_S then nil else "Control Room is not getting updates from the window"
	local facts: { { Spans } } = {}
	local function fact(k: string, v: Spans)
		table.insert(facts, { k :: Spans, v })
	end
	if s.cwd then
		fact("directory", { ui.path(s.cwd) })
	end
	fact("last activity", common.since(s.at))
	fact("prompts", tostring(s.prompts))
	fact("session", { ui.span(s.id, "mono muted") })
	local children: { Node } = {}
	table.insert(children, ui.node("row", { key = "end", gap = "sm" }, {
		ui.button("Resume", { key = "resume", variant = "primary", size = "sm", keys = { "enter" }, disabled = offline, actions = { click = "resume" } }),
	}))
	local body: { Node } = {}
	table.insert(body, with(ui.kv(facts), { key = "facts" }))
	table.insert(body, ui.node("row", { key = "actions", gap = "sm", wrap = true }, {
		sm("Restore", "restore", {
			icon = "repeat",
			keys = { "R" },
			title = "Resume it and go on with what its last process left unfinished: the interrupted turn and its subagents (omp --restore)",
			disabled = offline,
		}),
		sm("Peek", "speek", { icon = "eye", keys = { "." }, busy = state.speeking == s.id, disabled = offline }),
		sm("Copy command", "copy", { icon = "copy", keys = { "c" } }),
	}))
	if r.snippet then
		table.insert(body, with(ui.rule("Matching prompt"), { key = "snip-rule" }))
		table.insert(body, with(ui.text(marked(r.snippet, terms, "")), { key = "snip" }))
	end
	if s.note then
		table.insert(body, with(ui.rule("Handoff note · " .. common.since(s.note_at)), { key = "note-rule" }))
		table.insert(body, with(ui.md(s.note), { key = "note" }))
	end
	local peek = state.speek
	if peek and peek.id == s.id then
		if peek.error then
			table.insert(body, with(ui.text({ ui.span(peek.error, "error") }), { key = "speek-err" }))
		end
		for _, n in said_nodes("recaps", "omp's recaps", peek.recaps, true) do
			table.insert(body, n)
		end
		for _, n in said_nodes("prompts", "Your last prompts", peek.prompts, false) do
			table.insert(body, n)
		end
	else
		if s.recap then
			table.insert(body, with(ui.rule("omp's last recap" .. (if s.recap_at then " · " .. common.since(s.recap_at) else "")), { key = "recap-rule" }))
			table.insert(body, with(ui.md(s.recap), { key = "recap" }))
		end
		if s.prompt then
			table.insert(body, with(ui.rule("Your last prompt"), { key = "prompt-rule" }))
			table.insert(body, with(ui.text(marked(common.cut(s.prompt, 300), terms, "")), { key = "prompt" }))
		end
	end
	local cap = math.max(4, math.floor((rows * 16 - 275) / 18))
	table.insert(children, ui.node("scroll", { key = "body", role = "control-room.scroll", variant = "fade", gap = "sm", max = { h = cap .. "lines" } }, body))
	props.icon = if s.note then "archive" else "sparkle"
	props.meta = r.doc.project .. " · closed"
	props["end"] = "main.archive.body.detail.end"
	return ui.card(session_label(s), children, props)
end

local function resume_command(s: common.Session): string
	return "omp --resume " .. s.id
end

local function view(state: State, cx: BlockCx): BlockView
	local groups, counts, total = layout(state)
	local order = flatten(groups)
	state.order = order
	if state.view ~= "failures" and selected(state) == nil then
		state.cursor = if order[1] then order[1].row.pane else nil
	end
	local sel_entry = selected(state)
	if state.peek and state.peek.pane ~= state.cursor then
		state.peek = nil
	end

	local parts: { Node } = { head_row(state, total), stats_strip(state, counts), nav(state, total, counts) }
	-- Only the table (and the long part of the card) scroll; the block never
	-- does. The cap is in sans lines (18px): the pane's height in cells (about
	-- 16px each) minus what the head, stats, tabs, toolbar, gaps and dock take
	-- (about 240px). The window half's sheet hands it to the scrolling view.
	local lines = math.max(6, math.floor((cx.rows * 16 - 240) / 18))
	local function scroller(key: string, children: { Node }): Node
		return ui.node("scroll", { key = key, role = "control-room.scroll", gap = "md", max = { h = lines .. "lines" } }, children)
	end
	local page: Node
	if state.view == "archive" then
		if state.catalog == nil or os.time() - (state.catalog_asked or 0) > CATALOG_TTL_S then
			if state.catalog_asked == nil or os.time() - state.catalog_asked > 5 then
				ask_catalog(state)
			end
		end
		schedule_deep(state)
		local list_rows = ranked(state)
		if selected_session(state) == nil then
			state.scursor = if list_rows[1] then list_rows[1].doc.s.id else nil
		end
		if state.speek and state.speek.id ~= state.scursor then
			state.speek = nil
		end
		local notes: { Node } = {}
		local catalog = state.catalog
		local problem = if catalog and catalog.error then catalog.error else state.deep_error
		if problem then
			table.insert(notes, ui.node("text", { key = "problem", spans = { ui.span(common.clip(problem, 200), "warning") } }))
		end
		local list = ui.node("col", { key = "list", gap = "md", grow = 1, basis = 0, min = { w = "60ch" } }, {
			toolbar(state),
			ui.node("col", { key = "notes" }, notes),
			scroller("scroll", { archive_table(state, list_rows) }),
		})
		page = ui.node("col", { key = "archive" }, {
			ui.node("row", { key = "body", gap = "lg", align = "start", wrap = true }, { list, session_card(state, selected_session(state), cx.rows) }),
		})
	elseif state.view == "boards" then
		if not state.board_menu and (state.board_asked == nil or os.time() - state.board_asked >= 15) then
			state.board_asked = os.time()
			request(state, "boards", cx.pane)
		end
		local fresh = state.board_report ~= nil and os.time() - state.board_report.at <= 45 and state.board_report.error == nil and state.snap ~= nil and os.time() - (state.received or 0) <= STALE_S
		if not fresh then state.board_menu = false end
		local nodes, entries = boards_view.render(state.board_report, {
			room = cx.pane,
			show_done = state.board_done,
			collapsed = state.board_collapsed,
			query = state.board_filter,
			mode = if state.board_mode == "list" then "list" else "board",
			selected = state.board_selected,
			enabled = fresh,
		})
		state.board_entries = entries
		local found = false
		for _, entry in entries do if entry.token == state.board_selected then found = true; break end end
		if not found then state.board_selected = nil; state.board_menu = false end
		local open, done = boards_view.totals(state.board_report)
		local updated = if state.board_report then "updated " .. common.since(state.board_report.at) else "reading…"
		page = ui.node("col", { key = "boards", gap = "md" }, {
			ui.node("row", { key = "bar", gap = "sm", align = "center", wrap = true }, {
				ui.node("input", { key = "filter", text = state.board_filter, cursor = state.caret, placeholder = "Filter", icon = "search", clear = true, max = { w = "32ch" }, grow = 1 }),
				ui.node("text", { key = "count", grow = 1, spans = { ui.span(open .. " open · " .. done .. " done", "mono muted"), ui.span("  " .. updated, "muted") } }),
				ui.button("", { key = "done", size = "sm", variant = "quiet", icon = if state.board_done then "eye" else "eye-off", on = not state.board_done, title = if state.board_done then "Hide done cards" else "Show done cards", actions = { click = "board_done" } }),
				ui.node("tabs", { key = "mode", variant = "segmented", active = state.board_mode, items = { { id = "board", label = "Board" }, { id = "list", label = "List" } } }),
			}),
			scroller("scroll", nodes),
		})
	elseif state.view == "limits" then
		page = ui.node("col", { key = "limits", gap = "md" }, {
			ui.node("text", { key = "about", spans = { ui.span("Provider limits as omp reports them (omp usage), and the credentials it has stopped using", "muted"), ui.span(if state.usage then " · read " .. common.since(state.usage.at) else "", "muted") } }),
			scroller("scroll", limits_nodes(state.usage)),
		})
	elseif state.view == "failures" then
		page = ui.node("col", { key = "failures", gap = "md" }, {
			ui.node("text", { key = "about", spans = { ui.span("Commands that ended with a nonzero exit, as this window saw them finish; newest first. Right-click a row to go to its pane.", "muted") } }),
			scroller("scroll", { failures_table(state) }),
		})
	elseif state.snap == nil and total == 0 then
		page = ui.node("skeleton", { key = state.view, shape = "rows", rows = 6 })
	else
		-- The table takes the spare width and the card keeps its own; when both
		-- don't fit side by side the row wraps and the card goes under the table.
		-- (`cx.cols` is not reliable for a block in a split, so no width check.)
		local list = ui.node("col", { key = "list", gap = "md", grow = 1, basis = 0, min = { w = "60ch" } }, {
			toolbar(state),
			scroller("scroll", { pane_lists(state, groups) }),
		})
		local card = detail_card(state, sel_entry, cx.rows)
		page = ui.node("col", { key = state.view }, {
			ui.node("row", { key = "body", gap = "lg", align = "start", wrap = true }, { list, card }),
		})
	end
	table.insert(parts, page)

	-- The dock shows each view's main keys; `?` adds the rest.
	local keys: { Span } = {}
	local hidden = false
	local function hint(k: string, label: string, more: boolean?)
		if more and not state.all_keys then
			hidden = true
			return
		end
		table.insert(keys, ui.span(k, "key"))
		table.insert(keys, ui.span(" " .. label .. "  ", "muted"))
	end
	local dock: { Node } = {}
	local confirm = state.confirm
	if confirm then
		local what = CONFIRM[confirm.verb]
		hint("⏎", "confirm")
		hint("esc", "cancel")
		local children: { Node } = {
			ui.node("row", { key = "end", gap = "sm" }, {
				ui.button("Cancel", { key = "cancel", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "cancel" } }),
				ui.button(what.button, { key = "ok", variant = if confirm.verb == "interrupt" then "danger" else "primary", size = "sm", keys = { "enter" }, actions = { click = "confirm" } }),
			}),
			ui.text({ ui.span(what.text, "muted") }),
		}
		if confirm.note then
			table.insert(children, with(ui.text({ ui.span(confirm.note, "warning") }), { key = "note" }))
		end
		table.insert(dock, ui.node("card", { key = "confirm", tone = if confirm.verb == "interrupt" then "error" else "warning", icon = "warn", head = what.head .. " " .. confirm.title .. "?", ["end"] = "dock.confirm.end" }, children))
	elseif state.editing then
		hint("⏎", if state.view == "archive" then "keep search" else "keep filter")
		hint("↑↓", "select")
		hint("esc", "clear")
	elseif state.view == "archive" then
		hint("↑↓", "select")
		hint("⏎", "resume")
		hint(".", "peek")
		hint("/", "search")
		hint("⇧r", "restore", true)
		hint("c", "copy command", true)
		hint("r", "reload", true)
		hint("tab", "view", true)
	elseif state.view == "boards" then
		hint("↑↓", "select")
		hint("←→", "move")
		hint("space", "done")
		hint("⏎", "open")
		hint("/", "filter")
		hint("m", "menu", true)
		hint("e", "edit", true)
		hint("d", if state.board_done then "hide done" else "show done", true)
		hint("v", if state.board_mode == "board" then "list" else "board", true)
		hint("r", "reload", true)
		hint("tab", "view", true)
	elseif state.view == "limits" then
		hint("r", "reload")
		hint("tab", "view")
	else
		hint("↑↓", "select")
		hint("⏎", "go")
		hint(".", "peek")
		hint("u", "ask")
		hint("f", "pin")
		hint("/", "filter")
		hint("i", "interrupt", true)
		hint("n", "new agent", true)
		hint("p", "park", true)
		hint("a", "archive", true)
		if state.view == "agents" then
			hint("⇧u", "ask all", true)
			hint("⇧a", "archive idle", true)
		end
		hint("x", "dismiss", true)
		hint("tab", "view", true)
		hint("v", "scope", true)
		hint("g", "group", true)
	end
	if hidden or state.all_keys then
		hint("?", if state.all_keys then "fewer keys" else "all keys")
	end
	table.insert(dock, ui.node("text", { key = "keys", spans = keys, lines = 1 }))
	local layer: Node? = nil
	if state.view == "boards" and state.board_menu then
		for _, entry in state.board_entries do
			if entry.token == state.board_selected then
				local anchored = table.clone(entry)
				anchored.anchor = state.board_anchor or entry.anchor
				layer = ui.col({ ui.el("div", { key = "board_backdrop", role = "control-room.board-backdrop", actions = { click = "board_dismiss" } }), boards_view.overlay(anchored, state.board_menu_cursor) })
				break
			end
		end
	end
	return {
		main = with(ui.node("col", { gap = "lg" }, parts), { role = "control-room.main" }),
		dock = ui.col(dock),
		layer = layer,
	}
end

local function title(state: State): string?
	local n = 0
	local acks = common.acks()
	local snap = state.snap
	if snap == nil then
		return "Control Room"
	end
	for _, row in snap.rows do
		if common.classify(row, acks).level == "attention" then
			n += 1
		end
	end
	return if n > 0 then string.format("Control Room · %d need attention", n) else "Control Room"
end

local function move(state: State, delta: number)
	if state.view == "limits" or state.view == "boards" then
		return
	end
	if state.view == "archive" then
		local n = math.min(#state.ranked, ARCHIVE_ROWS)
		if n == 0 then
			return
		end
		local at = 1
		for i, r in state.ranked do
			if r.doc.s.id == state.scursor then
				at = i
			end
		end
		state.scursor = state.ranked[math.clamp(at + delta, 1, n)].doc.s.id
		return
	end
	local n = #state.order
	if n == 0 then
		return
	end
	local at = 1
	for i, e in state.order do
		if e.row.pane == state.cursor then
			at = i
		end
	end
	state.cursor = state.order[math.clamp(at + delta, 1, n)].row.pane
end

local function online(state: State): boolean
	if state.snap == nil or os.time() - (state.received or 0) > STALE_S then
		state.cx:toast("info", "Control Room is not getting updates from the window", "Tern resumes a paused hook by itself within 5 minutes; Reload plugins restarts it now.")
		return false
	end
	return true
end

local BOARD_VERBS = { board_open = true, board_pin = true, board_check = true, board_move = true, board_add = true, board_edit = true }

--- Sends a board action (`board_<verb>:<payload>`) to the window half, only while the report is fresh:
--- card ids come from that read and go stale when the file is reloaded.
local function board_run(state: State, act: string?): boolean
	if act == nil then return false end
	local verb, target = string.match(act, "^(board_%a+):([%w_%-]+)$")
	if not verb or not target or not BOARD_VERBS[verb] then return false end
	local report = state.board_report
	if report == nil or os.time() - report.at > 45 or report.error then
		state.cx:toast("info", "Boards are being read again", "Try again in a moment.")
		return false
	end
	if not online(state) then return false end
	request(state, verb, target)
	return true
end

local function board_entry(state: State): boards_view.Entry?
	for _, entry in state.board_entries do
		if entry.token == state.board_selected then return entry end
	end
	return nil
end

--- An action on the selected closed session: `resume`, `restore`, `speek` or `copy`.
local function act_session(state: State, verb: string)
	local r = selected_session(state)
	if r == nil then
		return
	end
	local s = r.doc.s
	if verb == "copy" then
		state.cx:copy(resume_command(s))
		state.cx:toast("success", "Copied", resume_command(s))
		return
	end
	if not online(state) then
		return
	end
	if verb == "speek" then
		state.speeking = s.id
	end
	request(state, verb, s.id)
end

local function act(state: State, verb: string)
	if state.view == "limits" or state.view == "boards" then
		return
	end
	if state.view == "archive" then
		local map: { [string]: string } = { go = "resume", resume = "resume", restore = "restore", peek = "speek", speek = "speek", copy = "copy", ["copy command"] = "copy" }
		if map[verb] then
			act_session(state, map[verb])
		end
		return
	end
	local entry = selected(state)
	if entry == nil then
		return
	end
	local row = entry.row
	if verb == "dismiss" then
		local problem = common.problem(row)
		if problem == nil then
			return
		end
		local acks = common.acks()
		-- Forget acknowledgements of panes that are gone.
		local live: { [string]: boolean } = {}
		for _, r in (if state.snap then state.snap.rows else {}) :: { Row } do
			live[common.id(r.pane)] = true
		end
		for id in acks do
			if not live[id] then
				acks[id] = nil
			end
		end
		acks[common.id(row.pane)] = problem
		tern.kv.set("acks", acks)
		request(state, "refresh", nil)
		return
	end
	if not online(state) then
		return
	end
	local is_agent = row.agent ~= nil and row.agent.state ~= "exited"
	if (verb == "ask" or verb == "interrupt") and not is_agent then
		state.cx:toast("info", "Only a running agent can be " .. (if verb == "ask" then "asked" else "interrupted"), common.label(row))
		return
	end
	if verb == "archive" then
		local why = archive_blocked(row)
		if why then
			state.cx:toast("info", "Cannot archive " .. common.label(row) .. " now", why)
			return
		end
	end
	if CONFIRM[verb] then
		-- Confirmed from the dock's strip (Enter or its button) before it is sent.
		local names: { string } = {}
		local services: { common.Service } = row.services or {}
		if verb == "archive" then
			for _, service in services do
				if service.running then
					table.insert(names, service.name)
				end
			end
		end
		local note = if #names > 0 then "It still runs " .. #names .. (if #names == 1 then " service: " else " services: ") .. table.concat(names, ", ") .. "." else nil
		local confirmation: Confirmation = { verb = verb, pane = row.pane, title = common.label(row), note = note }
		state.confirm = confirmation
		return
	end
	if verb == "peek" then
		state.peeking = row.pane
	end
	request(state, verb, row.pane)
end

--- A bulk action on the listed agents: `ask_all` (the window asks for the text) or
--- `archive_idle` (confirmed in the dock first).
local function act_bulk(state: State, verb: string)
	if (state.view ~= "panes" and state.view ~= "agents") or not online(state) then
		return
	end
	local ask, idle = bulk_targets(state)
	local panes = if verb == "ask_all" then ask else idle
	if #panes == 0 then
		state.cx:toast(
			"info",
			if verb == "ask_all" then "No listed agent is waiting for a prompt" else "No listed omp agent has been waiting for over " .. minutes(bulk_idle_s()),
			"Bulk actions take the agents this list shows: check the filter and the scope."
		)
		return
	end
	if verb == "archive_idle" then
		local title = #panes .. (if #panes == 1 then " agent" else " agents") .. " idle for over " .. minutes(bulk_idle_s())
		local count = 0
		for _, entry in state.order do
			if table.find(panes, entry.row.pane) then
				local services: { common.Service } = entry.row.services or {}
				for _, service in services do
					if service.running then
						count += 1
						break
					end
				end
			end
		end
		local note = if count > 0 then count .. (if count == 1 then " agent still runs services." else " agents still run services.") else nil
		local confirmation: Confirmation = { verb = "archive_idle", pane = panes[1], title = title, panes = panes, note = note }
		state.confirm = confirmation
		return
	end
	request(state, verb, join_panes(panes))
end

--- Sends the action waiting in the dock's confirm strip.
local function confirmed(state: State)
	local pending = state.confirm
	state.confirm = nil
	if pending == nil then
		return
	end
	if pending.panes then
		request(state, pending.verb, join_panes(pending.panes))
	else
		state.cursor = pending.pane
		request(state, pending.verb, pending.pane)
	end
end

local function focus_filter(state: State, on: boolean)
	state.editing = on
	if on then
		state.caret = editor.units(if state.view == "archive" then state.query else if state.view == "boards" then state.board_filter else state.filter)
	end
	local id: any = if on then (if state.view == "boards" then "main.boards.bar.filter" else "main." .. state.view .. ".body.list.bar.filter") else tern.json.null
	state.cx:frame({ { "focus", id } })
end

--- The text the search field edits: the Archive's query or the panes filter.
local function field(state: State): string
	return if state.view == "archive" then state.query else if state.view == "boards" then state.board_filter else state.filter
end

local function set_field(state: State, text: string)
	if state.view == "archive" then
		state.query = text
	elseif state.view == "boards" then
		state.board_filter = text
		state.board_menu = false
	else
		state.filter = text
	end
	state.caret = editor.units(text)
end

--- The session a table row or event item names, from its `s<id>` id.
local function session_of(item: any): string?
	return string.match(tostring(item or ""), "^s([%w%-]+)$")
end

--- A catalog, search result or session peek the window half sent; true when `ev` was one.
local function archive_event(state: State, ev: UiEvent): boolean
	if ev.ev ~= "action" or type(ev.value) ~= "string" then
		return false
	end
	local act_name = ev.act
	if act_name ~= "catalog" and act_name ~= "hits" and act_name ~= "speek" then
		return false
	end
	local ok, value = pcall(tern.json.decode, ev.value)
	if not ok or type(value) ~= "table" then
		return true
	end
	if act_name == "catalog" and type(value.sessions) == "table" then
		state.catalog = value :: common.Catalog
		state.catalog_asked = os.time()
		state.index = archive.index(value.sessions)
		-- New data: rank again, and search the prompts again for the current words.
		state.rank_key, state.deep, state.deep_key, state.deep_wanted = nil, nil, nil, nil
	elseif act_name == "hits" and type(value.hits) == "table" then
		-- Only the answer to the last request counts; older ones arrive late.
		if state.deep_sent and value.query == state.deep_sent then
			state.deep = archive.deep(value.hits)
			state.deep_key = state.deep_sent_key
			state.deep_stamp += 1
			state.deep_error = value.error
		end
	elseif act_name == "speek" and type(value.id) == "string" then
		state.speek = value :: common.SessionPeek
		if state.speeking == value.id then
			state.speeking = nil
		end
	end
	return true
end

local function start_timer(state: State)
	state.timer = tern.timer(TICK_MS, function()
		state.timer = nil
		if not alive(state) then
			return
		end
		-- Ages and staleness move with the clock; the data only changes by snapshot.
		state.cx:render()
		start_timer(state)
	end)
end

local room: BlockDef<State> = {
	font = "sans",
	features = FEATURES,
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local old = running[cx.pane]
		if old and old.timer then
			old.timer:cancel()
		end
		local prefs = if type(saved) == "table" then saved else {}
		local ok, saved_usage = pcall(tern.kv.get, "usage")
		local state: State = {
			cx = cx,
			snap = nil,
			received = nil,
			pause = nil,
			usage = if ok then common.usage_of(saved_usage) else nil,
			board_report = nil,
			board_asked = nil,
			board_done = prefs.board_done == true,
			board_collapsed = if type(prefs.board_collapsed) == "table" then prefs.board_collapsed else {},
			board_filter = if type(prefs.board_filter) == "string" then prefs.board_filter else "",
			board_mode = if prefs.board_mode == "list" then "list" else "board",
			board_selected = nil,
			board_menu = false,
			board_menu_cursor = 1,
			board_anchor = nil,
			board_entries = {},
			view = if table.find(VIEWS, prefs.view) then prefs.view else "panes",
			filter = if type(prefs.filter) == "string" then prefs.filter else "",
			editing = false,
			all_keys = prefs.all_keys == true,
			caret = 0,
			scope = if SCOPE_LABEL[prefs.scope] then prefs.scope else "all",
			group = if GROUP_LABEL[prefs.group] then prefs.group else "none",
			cursor = nil,
			peek = nil,
			peeking = nil,
			timer = nil,
			order = {},
			confirm = nil,
			query = if type(prefs.query) == "string" then prefs.query else "",
			catalog = nil,
			index = nil,
			catalog_asked = nil,
			deep = nil,
			deep_key = nil,
			deep_stamp = 0,
			deep_error = nil,
			deep_wanted = nil,
			deep_sent = nil,
			deep_sent_key = nil,
			search_timer = nil,
			ranked = {},
			rank_key = nil,
			scursor = nil,
			speek = nil,
			speeking = nil,
		}
		state.caret = editor.units(if state.view == "archive" then state.query else state.filter)
		running[cx.pane] = state
		start_timer(state)
		-- Ask the window halves for a snapshot now rather than at their next tick.
		cx:open(common.url("hello", cx.pane))
		return state
	end,
	view = view,
	-- The scroll caps follow `cx.rows`: a resize must render again.
	resize = function(_state: State, _cols: number, _rows: number, _cx: BlockCx) end,
	title = title,
	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		local name = key.name
		local text = key.text
		if state.editing then
			local current: editor.Field = { text = field(state), caret = state.caret }
			if name == "enter" then
				focus_filter(state, false)
				return true
			elseif name == "escape" then
				set_field(state, "")
				focus_filter(state, false)
				return true
			elseif name == "up" or name == "down" then
				move(state, if name == "up" then -1 else 1)
				return true
			elseif name == "backspace" then
				current = editor.backspace(current)
			elseif name == "delete" then
				current = editor.delete(current)
			elseif name == "left" then
				current = editor.left(current)
			elseif name == "right" then
				current = editor.right(current)
			elseif name == "home" then
				current = editor.home(current)
			elseif name == "end" then
				current = editor.finish(current)
			elseif name == "paste" and text then
				current = editor.insert(current, (string.gsub(text, "%s+", " ")))
			elseif text and text ~= "" and not key.ctrl and not key.meta then
				current = editor.insert(current, text)
			else
				return false
			end
			set_field(state, current.text)
			state.caret = current.caret
			return true
		end
		if key.ctrl or key.meta or key.alt then
			return false
		end
		local pending = state.confirm
		if pending then
			if name == "enter" then
				confirmed(state)
			elseif name == "escape" then
				state.confirm = nil
			else
				return false
			end
			return true
		end
		if text == "?" then
			state.all_keys = not state.all_keys
			return true
		end
		if state.view == "boards" then
			local press = text or name
			if state.board_menu then
				if name == "escape" then state.board_menu = false; return true end
				local entry = board_entry(state)
				if entry then
					local count = #entry.destinations
					if count > 0 and (name == "up" or name == "down") then
						state.board_menu_cursor = ((state.board_menu_cursor - 1 + (if name == "up" then -1 else 1)) % count) + 1
						return true
					elseif name == "enter" then
						local dest = entry.destinations[state.board_menu_cursor]
						if dest then board_run(state, dest.action) end
						state.board_menu = false; return true
					end
				end
				return false
			end
			local entry = board_entry(state)
			if name == "tab" or press == "]" then
				state.view = cycle(VIEWS, state.view, if key.shift then -1 else 1)
			elseif press == "[" then
				state.view = cycle(VIEWS, state.view, -1)
			elseif name == "up" or name == "down" then
				local n = #state.board_entries
				if n > 0 then
					local at = 0
					for i, item in state.board_entries do if item.token == state.board_selected then at = i; break end end
					at = if at == 0 then (if name == "up" then n else 1) else math.clamp(at + (if name == "up" then -1 else 1), 1, n)
					state.board_selected = state.board_entries[at].token
					state.board_anchor = nil
				end
			elseif press == "/" then
				focus_filter(state, true)
			elseif press == "m" then
				if entry and state.board_report and os.time() - state.board_report.at <= 45 and not state.board_report.error and online(state) then state.board_menu = true; state.board_menu_cursor = 1; state.board_anchor = nil end
			elseif (name == "left" or name == "right") and entry then
				board_run(state, if name == "left" then entry.left else entry.right)
			elseif (press == " " or name == "space") and entry then
				board_run(state, entry.check)
			elseif press == "e" and entry then
				board_run(state, entry.edit)
			elseif name == "enter" and entry then
				board_run(state, entry.open)
			elseif press == "v" then
				state.board_mode = if state.board_mode == "board" then "list" else "board"
			elseif press == "d" then
				state.board_done = not state.board_done
			elseif press == "r" then
				state.board_asked = os.time()
				request(state, "boards", state.cx.pane)
			else
				return false
			end
			return true
		end
		local press = text or name
		-- Shifted letters: the bulk actions and the Archive's restore.
		local shifted = if text and #text == 1 and (key.shift or string.match(text, "%u")) then string.lower(text) else nil
		if shifted == "u" then
			act_bulk(state, "ask_all")
		elseif shifted == "a" then
			if state.view ~= "archive" then
				act_bulk(state, "archive_idle")
			end
		elseif shifted == "r" and state.view == "archive" then
			act(state, "restore")
		elseif name == "up" or press == "k" then
			move(state, -1)
		elseif name == "down" or press == "j" then
			move(state, 1)
		elseif name == "page_up" then
			move(state, -10)
		elseif name == "page_down" then
			move(state, 10)
		elseif name == "home" then
			move(state, -math.huge)
		elseif name == "end" then
			move(state, math.huge)
		elseif name == "enter" or press == "o" then
			act(state, "go")
		elseif press == "." then
			act(state, "peek")
		elseif press == "u" then
			act(state, "ask")
		elseif press == "p" then
			act(state, "park")
		elseif press == "x" then
			act(state, "dismiss")
		elseif press == "i" then
			act(state, "interrupt")
		elseif press == "f" then
			act(state, "pin")
		elseif press == "n" then
			act(state, "new_agent")
		elseif press == "a" and state.view ~= "archive" then
			act(state, "archive")
		elseif press == "c" and state.view == "archive" then
			act(state, "copy")
		elseif press == "/" and state.view ~= "limits" and state.view ~= "failures" then
			focus_filter(state, true)
		elseif name == "tab" or press == "]" then
			state.view = cycle(VIEWS, state.view, if key.shift then -1 else 1)
			state.caret = editor.units(field(state))
		elseif press == "[" then
			state.view = cycle(VIEWS, state.view, -1)
			state.caret = editor.units(field(state))
		elseif press == "v" then
			state.scope = cycle(SCOPES, state.scope)
		elseif press == "g" then
			state.group = cycle(GROUPS, state.group)
		elseif press == "r" then
			if state.view == "archive" then
				ask_catalog(state)
			elseif state.view == "limits" then
				request(state, "usage", nil)
			else
				request(state, "refresh", nil)
			end
		elseif name == "escape" and field(state) ~= "" then
			set_field(state, "")
		else
			return false
		end
		return true
	end,
	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if archive_event(state, ev) then
			return
		end
		if ev.ev == "action" and ev.act == "boards" and type(ev.value) == "string" then
			local ok, value = pcall(tern.json.decode, ev.value)
			if ok then
				local report = boards.report_of(value)
				if report then
					state.board_report = report
				end
			end
			return
		end
		if ev.ev == "action" and (ev.act == "usage" or ev.act == "budget") and type(ev.value) == "string" then
			local ok, value = pcall(tern.json.decode, ev.value)
			if ok and ev.act == "usage" then
				local report = common.usage_of(value)
				if report then
					state.usage = report
				end
			elseif ok and type(value) == "table" and type(value.hook) == "string" and (value.state == "paused" or value.state == "resumed") and (value.ends_at == nil or type(value.ends_at) == "number") then
				state.pause = if value.state == "paused" then value :: common.Pause else nil
			end
			return
		end
		if ev.ev == "action" and ev.act == "snapshot" then
			local ok, snap = pcall(tern.json.decode, ev.value)
			if ok and type(snap) == "table" and type(snap.rows) == "table" then
				state.snap = snap :: Snapshot
				state.pause = nil
				state.received = os.time()
			end
			return
		end
		if ev.ev == "action" and ev.act == "peek" and type(ev.value) == "string" then
			local ok, peek = pcall(tern.json.decode, ev.value)
			if ok and type(peek) == "table" and type(peek.pane) == "number" then
				state.peek = peek :: Peek
				if state.peeking == peek.pane then
					state.peeking = nil
				end
			end
			return
		end
		local id = tostring(ev.id or "")
		if ev.ev == "edit" and state.editing and string.find(id, "%.bar%.filter$") and type(ev.from) == "number" and type(ev.to) == "number" and type(ev.text) == "string" and type(ev.cursor) == "number" and type(ev.len) == "number" then
			local updated = editor.edit({ text = field(state), caret = state.caret }, ev.from, ev.to, ev.text, ev.cursor, ev.len)
			if updated then
				set_field(state, updated.text)
				state.caret = updated.caret
			end
			return
		end
		if ev.ev == "focus" and string.find(id, "%.bar%.filter$") then
			focus_filter(state, true)
			return
		end
		if ev.ev == "select" and state.view == "boards" and string.find(id, "%.bar%.mode$") and (ev.item == "board" or ev.item == "list") then
			state.board_mode = ev.item
			state.board_menu = false
			return
		end
		if ev.ev == "select" and string.find(id, "%.nav$") and table.find(VIEWS, ev.item) then
			state.view = ev.item
			focus_filter(state, false)
			state.caret = editor.units(field(state))
			return
		end
		if state.view == "boards" and ev.ev == "action" then
			local verb = tostring(ev.act or "")
			if verb == "board_done" then
				state.board_menu = false
				state.board_done = not state.board_done
				return
			elseif verb == "board_dismiss" then
				state.board_menu = false
				return
			elseif verb == "board_menu" then
				if state.board_report and os.time() - state.board_report.at <= 45 and not state.board_report.error and online(state) then state.board_menu = not state.board_menu; state.board_menu_cursor = 1; state.board_anchor = id end
				return
			elseif verb == "refresh" then
				state.board_asked = os.time()
				request(state, "boards", state.cx.pane)
				return
			end
			local selection = string.match(verb, "^board_select:([%w_%-]+)$")
			if selection then
				state.board_selected = selection
				state.board_menu = false
				state.board_anchor = nil
				return
			end
			local session = string.match(verb, "^board_session:(%d+)$")
			if session then
				state.board_collapsed[session] = not state.board_collapsed[session]
				state.board_menu = false
				return
			end
			local pane = string.match(verb, "^board_agent:(%d+)$")
			if pane then
				if online(state) then request(state, "pin", tonumber(pane)) end
				return
			end
			if BOARD_VERBS[string.match(verb, "^(board_%a+):") or ""] then
				board_run(state, verb)
				state.board_menu = false
				return
			end
		end
		if ev.ev == "select" and string.find(id, "%.scope$") and SCOPE_LABEL[ev.item] then
			state.scope = ev.item
			return
		end
		if ev.ev == "select" and string.find(id, "%.group$") and GROUP_LABEL[ev.item] then
			state.group = ev.item
			return
		end
		if ev.ev == "select" or ev.ev == "activate" then
			local sid = session_of(ev.item)
			if sid then
				state.scursor = sid
				if ev.ev == "activate" then
					act(state, "resume")
				end
				return
			end
			local pane = pane_of(ev.item)
			if pane then
				state.cursor = pane
				if ev.ev == "activate" then
					act(state, "go")
				end
			end
			return
		end
		if ev.ev == "action" and ev.act == "clear" then
			set_field(state, "")
			return
		end
		if ev.ev == "action" and ev.act == "refresh" then
			if state.view == "archive" then
				ask_catalog(state)
			elseif state.view == "limits" then
				request(state, "usage", nil)
			else
				request(state, "refresh", nil)
			end
			return
		end
		if ev.ev == "action" then
			local verb = string.lower(tostring(ev.act))
			if verb == "confirm" or verb == "cancel" then
				if verb == "confirm" then
					confirmed(state)
				else
					state.confirm = nil
				end
				return
			end
			if verb == "ask_all" or verb == "archive_idle" then
				act_bulk(state, verb)
				return
			end
			local sid = session_of(ev.item)
			if sid or verb == "resume" or verb == "restore" or verb == "speek" or verb == "copy" or verb == "copy command" then
				if sid then
					state.scursor = sid
				end
				act(state, verb)
				return
			end
			if ACTION_VERBS[verb] then
				local pane = pane_of(ev.item)
				if pane then
					state.cursor = pane
					if state.view == "failures" then
						-- A failure row names a pane: act on it in the Panes view, where it is listed.
						state.view = "panes"
						state.scope, state.filter = "all", ""
						state.order = flatten((layout(state)))
					end
				end
				act(state, ACTION_VERBS[verb])
			end
		end
	end,
	save = function(state: State): any
		return { view = state.view, filter = state.filter, scope = state.scope, group = state.group, query = state.query, all_keys = state.all_keys, board_done = state.board_done, board_filter = state.board_filter, board_mode = state.board_mode, board_collapsed = state.board_collapsed }
	end,
}

tern.block.define("room", room)
