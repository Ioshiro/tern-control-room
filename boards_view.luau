--!strict
-- The aggregate reuses the native board block's markup (`tn-board`, `bd-*`), so
-- Tern's own board.css draws it; boards.css only adapts it to a scrolling page.
-- IDs in actions always come from the current native board report.
local boards = require("./boards")
local common = require("./common")
local ui = tern.ui

type Report = boards.Report
type Board = boards.Board
type Card = boards.Card
type Lane = boards.Lane
export type Destination = { label: string, action: string }
export type Entry = {
	token: string,
	anchor: string,
	destinations: { Destination },
	edit: string,
	check: string,
	open: string,
	--- Moves to the neighbouring lanes, as the native board's ←→ chords do.
	left: string?,
	right: string?,
}
export type Options = {
	room: number,
	show_done: boolean,
	collapsed: { [string]: boolean },
	query: string,
	mode: "board" | "list",
	selected: string?,
	enabled: boolean,
}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function action(verb: string, payload: any): string
	return verb .. ":" .. tern.base64.encode(tern.json.encode(payload), { url = true })
end

local function box(tag: string, key: string, class: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = { key = key, class = class }
	if props then
		for k, v in props do p[k] = v end
	end
	return ui.el(tag, p, children)
end

local function icon(name: string): Node
	return ui.node("icon", { key = "ic", name = name })
end

local function label(key: string, text: string): Node
	return ui.el("span", { key = key, text = text })
end

-- A native-looking button; without an action it is drawn inert.
local function clicker(key: string, class: string, act: string?, title: string, children: { Node }): Node
	return box("button", key, if act then class else class .. " cr-off", { title = title, aria = title, actions = if act then { click = act } else nil }, children)
end

local function matches(text: string, query: string): boolean
	return query == "" or string.find(string.lower(text), query, 1, true) ~= nil
end

-- The native board's tag hue: FNV-1a of the tag over its eight `t0`…`t7` hues.
local function hue(tag: string): number
	local h = 2166136261
	for i = 1, #tag do
		h = bit32.bxor(h, string.byte(tag, i))
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return h % 8
end

-- Tags show as chips, so their `#tag` leaves the title as the native card drops it.
-- Tern's tag stops at a dot, so `#giel.aichat.frontend` is the tag `giel` plus a
-- `.aichat.frontend` tail the native card leaves in the text; the tail goes too.
local function title_of(text: string, tags: { string }): string
	for _, tag in tags do
		text = string.gsub(text, "#" .. string.gsub(tag, "%p", "%%%0") .. "[%.%w_%-/]*", "")
	end
	return (string.gsub(string.gsub(text, "%s%s+", " "), "^%s*(.-)%s*$", "%1"))
end

local function due_chip(due: string): Node
	local y, m, d = string.match(due, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local month = if m then MONTHS[tonumber(m) or 0] else nil
	if not y or not d or not month then
		return box("span", "due", "kit-chip bd-chip bd-due", { text = due, title = "Due " .. due })
	end
	local today = tostring(os.date("%Y-%m-%d"))
	local tomorrow = tostring(os.date("%Y-%m-%d", os.time() + 86400))
	local state = if due < today then " late" elseif due == today then " today" elseif due == tomorrow then " soon" else ""
	local text = month .. " " .. tostring(tonumber(d))
	if y ~= string.sub(today, 1, 4) then text ..= " " .. y end
	return box("span", "due", "kit-chip bd-chip bd-due" .. state, { text = text, title = "Due " .. due })
end

-- The board's file as the native bar shows it: dim folder, then the file name.
local function location(path: string): (string, string)
	local shown = string.gsub(string.gsub(path, "^\\\\%?\\", ""), "^//%?/", "")
	local dir, name = string.match(shown, "^(.*[/\\])([^/\\]+)$")
	return dir or "", name or shown
end

local function card_node(card: Card, key: string, selected: boolean, acts: { select: string, check: string?, more: string? }): Node
	local text = title_of(card.text, card.tags)
	local meta: { Node } = {}
	for ti, tag in card.tags do
		table.insert(meta, box("span", "tag" .. ti, "kit-chip bd-chip bd-tag t" .. hue(tag), { text = tag, title = "#" .. tag }))
	end
	if card.due then table.insert(meta, due_chip(card.due)) end
	local class = "bd-card" .. (if #meta > 0 then " has-meta" else "") .. (if card.done then " done" else "") .. (if selected then " cur" else "")
	local body: { Node } = { box("div", "text", if text == "" then "bd-ct untitled" else "bd-ct", { text = if text == "" then "Untitled" else text }) }
	if #meta > 0 then table.insert(body, box("div", "meta", "bd-cmeta", nil, meta)) end
	local children: { Node } = {
		clicker("check", "bd-ck", acts.check, if card.done then "Mark open" else "Mark done", { icon("check") }),
		box("div", "body", "bd-cm", nil, body),
	}
	if selected then table.insert(children, clicker("more", "icon-btn bd-lb cr-more", acts.more, "Move, edit or open", { icon("more") })) end
	return box("div", key, class, { aria = text, actions = { click = acts.select } }, children)
end

local function skeleton(): Node
	local lanes: { Node } = {}
	for i = 1, 3 do
		table.insert(lanes, box("div", "l" .. i, "bd-skel-lane", nil, {
			box("div", "h", "bd-skel-h"),
			box("div", "c1", "bd-skel-card"),
			box("div", "c2", "bd-skel-card"),
		}))
	end
	return box("div", "loading", "cr-skel", { aria = "Reading boards" }, lanes)
end

local function empty(key: string, glyph: string, title: string, sub: string): Node
	return box("div", key, "cr-empty", nil, {
		box("div", "ring", "bd-ring", nil, { icon(glyph) }),
		box("div", "t", "bd-empty-t", { text = title }),
		box("div", "s", "bd-empty-s", { text = sub }),
	})
end

local function totals(report: Report?): (number, number)
	local open, done = 0, 0
	if report then
		for _, board in report.boards do open += board.open; done += board.done end
	end
	return open, done
end

local function render(report: Report?, o: Options): ({ Node }, { Entry })
	local entries: { Entry } = {}
	if report == nil then return { skeleton() }, entries end
	local result: { Node } = {}
	if os.time() - report.at > 45 then
		table.insert(result, ui.node("text", { key = "stale", spans = { ui.span("Stale · read " .. common.since(report.at) .. "; changes are paused until the next read", "warning") } }))
	end
	if report.error then table.insert(result, ui.node("text", { key = "error", spans = { ui.span(report.error, "warning") } })) end
	if #report.boards == 0 then
		table.insert(result, empty("empty", "kanban", "No boards in active projects", "A TODO.md at the root of a project open in Tern shows here, grouped by session."))
		return result, entries
	end
	local query = string.lower(o.query)
	local list = o.mode == "list"
	local room = o.room
	local sessions: { { id: string, name: string, boards: { { board: Board, index: number } } } } = {}
	local by_id: { [string]: number } = {}
	for i, board in report.boards do
		for _, session in board.sessions do
			local id = tostring(session.id)
			local at = by_id[id]
			if not at then table.insert(sessions, { id = id, name = session.name, boards = {} }); at = #sessions; by_id[id] = at end
			table.insert(sessions[at].boards, { board = board, index = i })
		end
	end
	local shown = 0
	for _, session in sessions do
		local hidden = o.collapsed[session.id] == true
		local projects: { Node } = {}
		for _, item in session.boards do
			local board, index = item.board, item.index
			local open_act = if o.enabled then action("board_open", { path = board.path, room = room }) else nil
			local project_match = matches(board.title .. " " .. board.path, query)
			local base = "main.boards.scroll.session" .. session.id .. ".b" .. index .. ".main.lanes"
			local lanes: { Node } = {}
			local board_visible = 0
			for li, lane in board.lanes do
				local cards: { Node } = {}
				local current = false
				for _, card in lane.cards do
					if (o.show_done or not card.done) and (project_match or matches(card.text, query)) then
						board_visible += 1
						local token = tern.base64.encode(tern.json.encode({ path = board.path, card = card.id, session = session.id }), { url = true })
						local card_key = "card_" .. tern.base64.encode(card.id, { url = true })
						local destinations: { Destination } = {}
						for _, dest in board.lanes do
							if dest.id ~= lane.id then table.insert(destinations, { label = if dest.title == "" then "Untitled" else dest.title, action = action("board_move", { path = board.path, card = card.id, lane = dest.id, room = room }) }) end
						end
						local check = action("board_check", { path = board.path, card = card.id, done = not card.done, room = room })
						local selected = o.selected == token
						current = current or selected
						if not hidden then
							local prev, after = board.lanes[li - 1], board.lanes[li + 1]
							table.insert(entries, {
								token = token,
								anchor = base .. ".lane" .. li .. ".cards." .. card_key,
								destinations = destinations,
								edit = action("board_edit", { path = board.path, card = card.id, room = room }),
								check = check,
								open = action("board_open", { path = board.path, room = room }),
								left = if prev then action("board_move", { path = board.path, card = card.id, lane = prev.id, room = room }) else nil,
								right = if after then action("board_move", { path = board.path, card = card.id, lane = after.id, room = room }) else nil,
							})
						end
						table.insert(cards, card_node(card, card_key, selected, {
							select = "board_select:" .. token,
							check = if o.enabled then check else nil,
							more = if o.enabled then "board_menu" else nil,
						}))
					end
				end
				local count = #cards
				if lane.more > 0 then
					table.insert(cards, clicker("more", "bd-add cr-lmore", open_act, "Open the board to see every card", { label("l", lane.more .. " more in the board") }))
				end
				local untitled = lane.title == ""
				local add = if o.enabled then action("board_add", { path = board.path, lane = lane.id, room = room }) else nil
				table.insert(lanes, box("div", "lane" .. li, "bd-lane" .. (if lane.complete then " done-lane" else "") .. (if current then " cur" else ""), { aria = if untitled then "Untitled" else lane.title }, {
					box("div", "head", "bd-lh", nil, {
						box("span", "title", if untitled then "bd-lt untitled" else "bd-lt", { text = if untitled then "Untitled" else lane.title }),
						box("span", "count", "bd-ln", { text = tostring(count) .. (if lane.more > 0 then "+" else "") }),
						box("span", "done", "bd-ldone", { title = "Done lane: cards moved here are marked done" }, { icon("check") }),
						box("span", "sp", "bd-sp"),
						clicker("plus", "icon-btn bd-lb bd-lplus", add, "New card in " .. (if untitled then "this lane" else lane.title), { icon("plus") }),
					}),
					box("div", "cards", "bd-cards", nil, cards),
					clicker("add", "bd-add", add, "Add a card to " .. (if untitled then "this lane" else lane.title), { icon("plus"), label("l", "Add card") }),
				}))
			end
			if project_match or board_visible > 0 or board.error then
				shown += 1
				local dir, name = location(board.path)
				local bar: { Node } = {
					box("span", "ic", "bd-ic", nil, { icon("kanban") }),
					box("div", "loc", "bd-loc", { title = board.path }, {
						box("span", "dir", "bd-dir", { text = dir }),
						box("span", "name", "bd-name", { text = name }),
					}),
				}
				for i, agent in board.agents do
					if agent.session == nil or tostring(agent.session) == session.id then
						-- omp titles read `<icon> CODE: what it does`: the pill shows the code, the tooltip all of it.
						local code = string.match(agent.title, "([%u%d][%u%d_%-]+):")
						table.insert(bar, clicker("agent" .. i, "bd-hint on cr-agent", "board_agent:" .. agent.pane, agent.title .. " · click to pin or unpin", { icon("terminal"), label("t", code or common.clip(agent.title, 18)) }))
					end
				end
				table.insert(bar, box("span", "sp", "bd-sp"))
				table.insert(bar, box("span", "count", "bd-count", { text = board.open .. " open · " .. board.done .. " done" }))
				table.insert(bar, clicker("open", "icon-btn bd-hb", open_act, "Open the native board", { icon("open") }))
				table.insert(bar, clicker("pin", "icon-btn bd-hb", if o.enabled then action("board_pin", { path = board.path, room = room }) else nil, "Pin the native board above Control Room", { icon("pin") }))
				local main: { Node } = {}
				if board.error then
					table.insert(main, box("div", "state", "cr-state", nil, { box("div", "err", "bd-state-err", { text = board.error }) }))
				else
					table.insert(main, box("div", "lanes", "bd-lanes", nil, lanes))
				end
				local body: { Node } = { box("div", "bar", "bd-bar", nil, bar), box("div", "main", "bd-main", nil, main) }
				if board.more > 0 then
					table.insert(body, clicker("more", "bd-add cr-bmore", open_act, "Open the board to see every card", { label("l", board.more .. " more cards in the board") }))
				end
				table.insert(projects, box("div", "b" .. index, if list then "tn-board list cr-board" else "tn-board cr-board", { aria = board.path }, body))
			end
		end
		if #projects > 0 then
			local children: { Node } = {
				clicker("head", if hidden then "cr-sess folded" else "cr-sess", "board_session:" .. session.id, if hidden then "Expand session" else "Collapse session", {
					icon("chev"),
					label("name", session.name),
					box("span", "n", "cr-sess-n", { text = tostring(#projects) }),
				}),
			}
			if not hidden then
				for _, node in projects do table.insert(children, node) end
			end
			table.insert(result, ui.node("col", { key = "session" .. session.id, gap = "sm" }, children))
		end
	end
	if shown == 0 and query ~= "" then
		table.insert(result, empty("nomatch", "search", "Nothing matches", "No project or card holds “" .. o.query .. "”."))
	end
	return result, entries
end

local function overlay(entry: Entry, cursor: number): Node
	local choices: { Node } = {}
	for i, dest in entry.destinations do
		table.insert(choices, ui.button(dest.label, { key = "dest" .. i, size = "sm", variant = if i == cursor then "default" else "quiet", icon = "arrow-right", title = "Move to " .. dest.label, actions = { click = dest.action } }))
	end
	if #choices > 0 then table.insert(choices, ui.node("rule", { key = "sep" })) end
	table.insert(choices, ui.button("Edit", { key = "edit", size = "sm", variant = "quiet", icon = "pen", actions = { click = entry.edit } }))
	table.insert(choices, ui.button("Open board", { key = "open", size = "sm", variant = "quiet", icon = "open", actions = { click = entry.open } }))
	return ui.node("overlay", { key = "board_move", role = "control-room.board-overlay", head = "Move to", anchor = { node = entry.anchor, side = "below" }, aria = "Card actions" }, choices)
end

return { render = render, overlay = overlay, totals = totals }
