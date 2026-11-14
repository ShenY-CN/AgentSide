--!nonstrict
-- Agent Sidebar: every coding agent in the window, grouped by its Tern
-- session, with its live state; a click goes to it.
--
-- Nothing is configured. Tern already reports which blocks are agents, and a
-- terminal running a known agent CLI is recognised from the command line the
-- shell reported, so a row appears when an agent starts and goes when it
-- stops. The panel is a canvas kept at the left of the shown tab and follows
-- you between tabs.
--
-- Tern pauses a hook that runs over its budget (50 ms for events and commands),
-- so hooks here only note work in tables; timers of their own do the reading,
-- the moving and the drawing.

local ui = tern.ui

local OWNER = tern.plugin.id
local TITLE = "Agents"
local ABOUT = "Coding agents in this window, grouped by their session. Click a row to go to it."

-- The panel's share of the tab's width, and the range a drag may leave it in.
local DEFAULT_SHARE = 0.22
local MIN_SHARE, MAX_SHARE = 0.15, 0.6

-- Agent CLIs Tern leaves running in a plain terminal. Native blocks (omp, pi,
-- …) report themselves through `cx.agents`, so this only catches the rest.
local CLI_AGENTS = {
	omp = true, pi = true, claude = true, codex = true, opencode = true, gemini = true,
	aider = true, amp = true, ["cursor-agent"] = true, crush = true, goose = true,
	hermes = true, kimi = true,
}

-- The vendor a command name belongs to, so a row can carry its mark. Values
-- name a `agentSidebar.vendor<value>` rule in styles.css (the official
-- lobe-icons glyph on its brand square); an unknown name gets no icon.
local VENDOR = {
	claude = "anthropic", codex = "codex", omp = "omp", pi = "omp",
	gemini = "gemini", opencode = "opencode", aider = "aider", amp = "amp",
	["cursor-agent"] = "cursor", crush = "crush", goose = "block", hermes = "nous",
	kimi = "kimi",
}

-- How a row's state reads. styles.css draws the dot that goes with it.
local WORD = {
	blocked = "needs you", failed = "failed", done = "done",
	working = "working", idle = "idle", exited = "exited",
}

-- A session's head shows its worst agent by this order: the one that most
-- needs you first.
local RANK = { blocked = 6, failed = 5, done = 4, working = 3, idle = 2, exited = 1 }

-- agents[pane] = { pane, kind = "block"|"cli", state, label, title, vendor,
--   cwd, tab, session, message, updatedAt }. `label` is what the row shows:
-- the conversation title when Tern gives the pane one, else the command name.
-- Rebuilt from Tern's listings, never saved.
local agents = {}

-- finished[pane key] = "done" | "failed": turns that ended out of sight. Kept
-- in kv so a reload (and a window restart) doesn't forget them.
local pendingClear = {}
local finished = {}
do
	local stored = tern.kv.get("finished")
	if type(stored) == "table" then
		for key, value in stored do
			if (value == "done" or value == "failed") and tonumber(key) then finished[tostring(key)] = value end
		end
	end
end

-- The panel: its pane, the tab it was last pinned in, and whether you want it
-- shown at all (persisted, so it reopens with the window).
local panelPane, panelTab = nil, nil
local share = math.clamp(tonumber(tern.kv.get("panel-share")) or DEFAULT_SHARE, MIN_SHARE, MAX_SHARE)
local wantPanel = tern.kv.get("panel-open") == true

-- The last view each canvas pane was given, so an unchanged draw is no call.
local rendered = {}

-- One callback's view of the window, so a draw fetches each list once. A
-- callback gets a fresh `cx`, so keying by it scopes the snapshot to one.
local SNAPSHOT_MS = 100
local snapshots = setmetatable({}, { __mode = "k" })

local function snapshot(cx)
	local found = snapshots[cx]
	if not found or tern.now() - found.at > SNAPSHOT_MS then
		local panes = cx.session:panes()
		local byId = {}
		for _, pane in panes do byId[pane.pane] = pane end
		found = { panes = panes, byId = byId, tabs = cx.session:tabs(), sessions = cx.session:sessions(), at = tern.now() }
		snapshots[cx] = found
	end
	return found
end

local function basename(path)
	if not path or path == "" then return "" end
	return (string.match(path, "([^/]+)/*$")) or path
end

-- The program a launch command line names, as `/usr/local/bin/codex --x` gives
-- `codex`.
local function commandName(command)
	local first = string.match(command or "", "%S+")
	return first and basename(first) or nil
end

-- The agent CLI a shell command line runs, if any: `omp`, `cd x && claude`,
-- `FOO=1 /usr/local/bin/codex --resume`.
local function cliName(line)
	for segment in string.gmatch(line or "", "[^;&|]+") do
		for word in string.gmatch(segment, "%S+") do
			if not string.find(word, "=", 1, true) then
				local name = string.match(word, "([^/]+)$")
				if name and CLI_AGENTS[name] then return name end
				break
			end
		end
	end
	return nil
end

-- What a row is called and whose mark it carries. `title` (the pane's
-- conversation title) leads when it says more than the bare command; the
-- command name is the fallback and picks the vendor icon. `program` (the
-- block's program, always set for an agent block) backs the vendor up when
-- the launch command is missing, so a row never loses its mark over that.
local function identity(command, title, program)
	local name = commandName(command)
	local vendor = (name and VENDOR[name]) or (program and VENDOR[program]) or nil
	local label = name
	if title and title ~= "" then
		-- A title that only restates the command (Tern's default) adds nothing.
		local bare = name and title:lower():find(name:lower(), 1, true)
		if not bare or #title > #name + 2 then label = title end
	end
	if not label or label == "" then label = program end
	return label or "Agent", vendor
end

-- omp's working messages lead with a spinner: Braille frames (U+2800–28FF)
-- that turn over many times a second. Left in, every frame reads as a changed
-- row and the panel repaints at that rate; stripped, a working agent's row is
-- stable until the words actually change.
local function despinner(text)
	if not text then return nil end
	-- Braille bytes are 0xE2 0x80/0x81/0x82 0x80–0xBF in UTF-8; drop the run.
	return (string.gsub(text, "\226[\128-\130][\128-\191]+", ""))
end

-- The state a row shows: an unseen finished turn first (it is cleared the
-- moment the agent works or asks again), then the agent's own state.
local function shownState(record)
	local mark = finished[tostring(record.pane)]
	if mark then return mark end
	local state = record.state
	if state == "waiting_input" then return "blocked" end
	if state == "working" or state == "exited" then return state end
	return "idle"
end

-- tab id -> its session, session id -> its name, and the session shown now.
local function sessionIndex(snap)
	local tabSession, names, current = {}, {}, nil
	for _, session in snap.sessions do
		names[session.id] = session.name
		if session.current then current = session.id end
		for _, tab in session.tabs or {} do tabSession[tab] = session.id end
	end
	for _, tab in snap.tabs do
		if not tabSession[tab.id] and tab.session then tabSession[tab.id] = tab.session end
	end
	return tabSession, names, current
end

local function trim(text, limit)
	if #text <= limit then return text end
	local ok, cut = pcall(utf8.offset, text, limit)
	if ok and cut then return string.sub(text, 1, cut - 1) .. "…" end
	return ""
end

local function oneLine(text, limit)
	local flat = (string.gsub(string.gsub(text or "", "%s+", " "), "^ ", ""))
	return trim(flat, limit)
end

-- Text " and \ would end or escape the AppleScript string literal.
local function quoted(text)
	return (string.gsub(string.gsub(text or "", '[\\"]', ""), "[\r\n]", " "))
end

local function tooltip(record, word)
	local lines = { record.label .. " · " .. word }
	if record.cwd and record.cwd ~= "" then table.insert(lines, record.cwd) end
	if record.kind == "cli" then
		table.insert(lines, "Agent CLI in a terminal")
	elseif record.message and record.message ~= "" then
		local said = oneLine(record.message, 200)
		if said ~= "" then table.insert(lines, ""); table.insert(lines, said) end
	end
	return table.concat(lines, "\n")
end

-- --- drawing ---------------------------------------------------------------

-- The window's one sidebar: the canvas this plugin owns, adopting one a reload
-- left behind and closing any extra, so a window never shows two.
local function slot(cx)
	local canvases = cx.canvas:list()
	if panelPane and not cx.session:pane(panelPane) then panelPane = nil end
	local found = {}
	for _, canvas in canvases do
		if canvas.owner == OWNER and canvas.title == TITLE then table.insert(found, canvas.pane) end
	end
	if not panelPane then panelPane = found[1] end
	for _, pane in found do
		if pane ~= panelPane then
			cx.layout:close(pane)
			rendered[pane] = nil
		end
	end
	if panelPane and not cx.session:pane(panelPane) then panelPane = nil end
	return panelPane, canvases
end

-- A row's status mark is an empty div; styles.css rings, fills and pulses it
-- from the role alone, so the row keeps its shape as the state changes.
local DOT_ROLE = {
	blocked = "agentSidebar.dotBlocked", failed = "agentSidebar.dotFailed",
	done = "agentSidebar.dotDone", working = "agentSidebar.dotWorking",
	idle = "agentSidebar.dotIdle", exited = "agentSidebar.dotExited",
}

local function dotNode(state)
	return ui.el("div", { key = "dot", role = DOT_ROLE[state] or DOT_ROLE.idle })
end

-- The vendor's mark, drawn by styles.css from the role alone; no node when
-- the command maps to no vendor.
local function vendorNode(vendor)
	if not vendor then return nil end
	return ui.el("div", { key = "vendor", role = "agentSidebar.vendor" .. vendor, title = vendor })
end

local function rowNode(record, state)
	local word = WORD[state] or WORD.idle
	local where = basename(record.cwd)
	local meta = word .. (where ~= "" and (" · " .. where) or "")
	local label = { ui.span(record.label) }
	if record.kind == "cli" then table.insert(label, ui.span(" (cli)", "muted")) end
	local kids = { vendorNode(record.vendor), dotNode(state) }
	-- A missing vendor leaves a hole in the children array; compact it away.
	local compact = {}
	for _, kid in kids do if kid then table.insert(compact, kid) end end
	table.insert(compact, ui.node("text", { key = "label", role = "agentSidebar.label", spans = label }))
	table.insert(compact, ui.node("row", { key = "spacer", grow = 1 }, {}))
	table.insert(compact, ui.node("text", { key = "meta", role = "agentSidebar.meta", text = meta }))
	return ui.node("row", {
		key = "p" .. tostring(record.pane),
		role = "agentSidebar.row",
		title = tooltip(record, word),
		aria = record.label .. ", " .. word,
		actions = { click = "focus=" .. tostring(record.pane) },
	}, compact)
end

local function sessionNode(group)
	local children = {
		ui.node("row", { key = "head", role = "agentSidebar.sessionHead" }, {
			ui.el("div", { key = "mark", role = "agentSidebar.sessionMark", title = "Session" }),
			dotNode(group.worst),
			ui.node("text", {
				key = "name", role = "agentSidebar.sessionName", text = group.name, title = group.name,
			}),
			ui.badge(tostring(#group.rows) .. (if #group.rows == 1 then " agent" else " agents"), "muted"),
		}),
	}
	for _, row in group.rows do table.insert(children, rowNode(row.record, row.state)) end
	return ui.node("col", { key = "s" .. tostring(group.key), role = "agentSidebar.session" }, children)
end

local function emptyNode()
	return ui.node("col", { key = "empty", role = "agentSidebar.empty" }, {
		ui.card("No agents", {
			ui.node("text", {
				key = "hint", role = "agentSidebar.emptyText",
				text = "Start an agent in a tab or a terminal; it appears here automatically.",
			}),
		}, { key = "card", icon = "sparkle" }),
	})
end

-- A pure builder: the whole view from the state tables and one snapshot.
local function render(cx)
	local snap = snapshot(cx)
	local tabSession, names, current = sessionIndex(snap)
	local panes = {}
	for pane in agents do table.insert(panes, pane) end
	table.sort(panes)
	local groups, byKey = {}, {}
	for _, pane in panes do
		local record = agents[pane]
		if record then
			local key = (record.tab and tabSession[record.tab]) or record.session or 0
			local group = byKey[key]
			if not group then
				local name = names[key]
				if not name or name == "" then
					if key == 0 then
						name = "Other"
					else
						name = "Session " .. tostring(key)
					end
				end
				group = { key = key, name = name, rows = {}, worst = nil }
				byKey[key] = group
				table.insert(groups, group)
			end
			local state = shownState(record)
			table.insert(group.rows, { record = record, state = state })
			if not group.worst or (RANK[state] or 0) > (RANK[group.worst] or 0) then group.worst = state end
		end
	end
	-- The session you are in comes first; the rest by name.
	table.sort(groups, function(a, b)
		if a.key == current and b.key ~= current then return true end
		if b.key == current and a.key ~= current then return false end
		local left, right = a.name:lower(), b.name:lower()
		if left ~= right then return left < right end
		return a.key < b.key
	end)
	local children = {}
	table.insert(children, ui.node("row", { key = "head", role = "agentSidebar.header" }, {
		ui.node("text", { key = "title", role = "agentSidebar.title", text = "Agent" }),
	}))
	-- The draw's change key: every field a row's pixels depend on, none they
	-- don't. A message's words are left out (they only fill the tooltip), so a
	-- working agent's stream of text never repaints the panel.
	local fingerprint = {}
	for _, group in groups do
		table.insert(fingerprint, group.key .. ":" .. group.name .. ":" .. tostring(group.worst))
		for _, row in group.rows do
			local r = row.record
			table.insert(fingerprint, table.concat({ tostring(r.pane), row.state, tostring(r.label), tostring(r.vendor), r.kind }, "\1"))
		end
	end
	for _, group in groups do table.insert(children, sessionNode(group)) end
	if #groups == 0 then table.insert(children, emptyNode()) end
	return ui.node("col", { key = "root", role = "agentSidebar.root" }, children), table.concat(fingerprint, "\2")
end

local function draw(cx)
	local pane, canvases = slot(cx)
	if not pane then return end
	-- A just-opened canvas only takes updates once canvas:list() reports it.
	local ready = false
	for _, canvas in canvases do
		if canvas.pane == pane then ready = true end
	end
	if not ready then return end
	local tree, signature = render(cx)
	if rendered[pane] == signature then return end
	cx.canvas:set(pane, { view = tree })
	rendered[pane] = signature
end

-- Runs fn(cx) in a timer callback of its own, reporting (not raising) errors.
local function separately(fn)
	tern.timer(0, function(cx)
		if not cx then return end
		local ok, err = pcall(fn, cx)
		if not ok then tern.log.warn("Agent Sidebar: " .. tostring(err)) end
	end)
end

-- Asks for a draw soon; requests made before it runs share it.
local drawQueued = false
local function redraw()
	if drawQueued then return end
	drawQueued = true
	separately(function(cx)
		drawQueued = false
		draw(cx)
	end)
end

-- --- the panel's place -----------------------------------------------------

local function firstLeaf(tree, skip)
	if not tree then return nil end
	if tree.pane then
		if tree.pane == skip then return nil end
		return tree.pane
	end
	return firstLeaf(tree[1], skip) or firstLeaf(tree[2], skip)
end

local function hasPane(tree, pane)
	if not tree then return false end
	if tree.pane then return tree.pane == pane end
	return hasPane(tree[1], pane) or hasPane(tree[2], pane)
end

-- The panel's share of the tab's width while it is the leftmost pane, however
-- deeply the splits nest it. Each "right" split it sits left of multiplies the
-- share; a pane that isn't on the left edge returns nil, so pin moves it there.
local function leftShare(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local node = layout and layout.root
	local found = 1
	while node and not node.pane do
		if node.split == "right" then
			if not hasPane(node[1], pane) then return nil end
			found = found * node.ratio
			node = node[1]
		elseif hasPane(node[1], pane) then
			node = node[1]
		else
			node = node[2]
		end
	end
	if node and node.pane == pane then return found end
	return nil
end

-- Tern resizes in cells, and a hidden tab's cells differ from the shown one's,
-- so steer by the ratio: step, see how far it moved, correct.
local function sizeTo(cx, tab, pane, want)
	local at = leftShare(cx, tab, pane)
	local step = if at then math.floor((want - at) * 180 + 0.5) else 0
	for _ = 1, 8 do
		if not at or math.abs(at - want) < 0.005 or step == 0 then return end
		cx.layout:resize(pane, "right", step)
		local after = leftShare(cx, tab, pane)
		if not after or after == at then return end
		step = math.floor((want - after) * step / (after - at) + 0.5)
		at = after
	end
end

-- The leftmost leaf of `tree` that is a foreign canvas (another plugin's
-- pinned panel, e.g. Overseer's Projects), skipping our own pane. Such a panel
-- pins itself leftmost on its own tick, faster than ours: two panels claiming
-- the same edge move each other every tick and the tab bounces. So when one is
-- present we settle immediately to its right instead of taking the edge.
-- A canvas is known by cx.canvas:list(), not pane kind: a panel opened as a
-- float or glimpse reports no "canvas" pane kind.
local function foreignCanvases(cx, skip)
	local foreign = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner ~= OWNER and canvas.pane ~= skip then foreign[canvas.pane] = true end
	end
	return foreign
end

local function foreignLeftCanvas(tree, foreign, skip)
	if not tree then return nil end
	if tree.pane then
		if tree.pane ~= skip and foreign[tree.pane] then return tree.pane end
		return nil
	end
	return foreignLeftCanvas(tree[1], foreign, skip) or foreignLeftCanvas(tree[2], foreign, skip)
end

-- True when `pane` sits immediately right of `anchor` in `tree`: some
-- "right"-split has `pane` in its right child and the left child's leftmost
-- leaf is `anchor`. Nested splits above the pair still count.
local function restingBeside(tree, pane, anchor)
	if not tree or tree.pane then return false end
	if tree.split == "right" and hasPane(tree[2], pane) then
		local left = tree[1]
		while left and not left.pane do left = left[1] end
		if left and left.pane == anchor then return true end
	end
	return restingBeside(tree[1], pane, anchor) or restingBeside(tree[2], pane, anchor)
end

-- Moves the panel into `tab` at its resting place, unless it is already there.
local function pin(cx, tab)
	local pane = slot(cx)
	if not pane then return end
	local layout = cx.session:layout(tab)
	if not layout then return end
	local from = cx.session:tab_of(pane)
	-- The anchor we pin against: a foreign left canvas if one holds the edge,
	-- else the tab's leftmost leaf. We go right of the anchor, leftmost without.
	local foreign = foreignCanvases(cx, pane)
	local anchor = foreignLeftCanvas(layout.root, foreign, pane) or firstLeaf(layout.root, pane)
	if not anchor then return end
	local dir = if anchor ~= pane and foreign[anchor] then "right" else "left"
	-- Already at rest: leftmost with no foreign canvas, or sitting immediately
	-- right of the anchor. A tick that finds us here costs nothing.
	if from == tab then
		if dir == "left" and firstLeaf(layout.root) == pane then
			panelTab = tab
			return
		end
		if dir == "right" and restingBeside(layout.root, pane, anchor) then
			panelTab = tab
			return
		end
	end
	-- The width you left it at travels with it.
	if from then
		local current = leftShare(cx, from, pane)
		if current and math.abs(current - share) > 0.01 then
			share = math.clamp(current, MIN_SHARE, MAX_SHARE)
			tern.kv.set("panel-share", share)
		end
	end
	if from ~= tab then
		if from then
			cx.layout:move_to_tab(pane, tab, { focus = false })
		else
			cx.layout:unpark(pane, { focus = false })
		end
	end
	cx.layout:move(pane, anchor, dir, { focus = false })
	sizeTo(cx, tab, pane, share)
	panelTab = tab
end

local function shownTab(cx)
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

local function openPanel(cx, tab)
	local tree, signature = render(cx)
	local pane, err = cx.canvas:open({
		title = TITLE, about = ABOUT, view = tree, how = "beside", focus = false, ratio = share,
	})
	if not pane then
		tern.log.warn("Agent Sidebar: could not open the panel: " .. tostring(err))
		return nil
	end
	panelPane, panelTab = pane, tab
	rendered[pane] = signature
	if tab then pin(cx, tab) end
	return pane
end

local function setWantPanel(want)
	wantPanel = want
	tern.kv.set("panel-open", want)
end

-- Keeps the panel in the shown tab. Runs on every tab, pane and focus event and
-- each tick, so one missed event can't leave it behind.
local function follow(cx, tab)
	tab = tab or shownTab(cx)
	if not tab then return end
	local pane = slot(cx)
	if not pane then
		if not wantPanel then return end
		-- Gone while its tab remains: you closed it. Gone with its tab (a closed
		-- tab or session): bring it back here.
		local tabStillOpen = false
		if panelTab then
			for _, info in cx.session:tabs() do
				if info.id == panelTab then tabStillOpen = true end
			end
		end
		if tabStillOpen then
			setWantPanel(false)
			panelTab = nil
			return
		end
		openPanel(cx, tab)
		return
	end
	-- Alone in the shown tab: the last agent beside it closed. Park it so the
	-- tab closes as Tern would; the tab shown next takes the panel.
	local layout = if cx.session:tab_of(pane) == tab then cx.session:layout(tab) else nil
	if layout and not firstLeaf(layout.root, pane) then
		cx.layout:park(pane)
		return
	end
	-- A panel found open (a reload, or before an update) is one you want.
	if not wantPanel then setWantPanel(true) end
	pin(cx, tab)
end

local function hidePanel(cx)
	local pane = slot(cx)
	if not pane then return end
	local tab = cx.session:tab_of(pane)
	if tab then
		local current = leftShare(cx, tab, pane)
		if current then
			share = math.clamp(current, MIN_SHARE, MAX_SHARE)
			tern.kv.set("panel-share", share)
		end
	end
	setWantPanel(false)
	rendered[pane] = nil
	panelPane, panelTab = nil, nil
	cx.layout:close(pane)
end

-- --- discovery -------------------------------------------------------------

-- Brings the tables in line with Tern: every agent block it reports, every
-- terminal running a known CLI, and nothing else.
local function sync(cx)
	local snap = snapshot(cx)
	local tabSession = sessionIndex(snap)
	local seen = {}
	local ok, blocks = pcall(function() return cx.agents:list() end)
	if ok then
		for _, block in blocks do
			local info = snap.byId[block.pane]
			if info and info.kind == "agent" then
				seen[block.pane] = true
				local record = agents[block.pane]
				if not record or record.kind ~= "block" then
					record = { pane = block.pane, kind = "block" }
					agents[block.pane] = record
				end
				record.state = block.state
				record.command = block.command
				record.program = info.program
				record.title = if info.title and info.title ~= "" then info.title else nil
				record.label, record.vendor = identity(block.command, record.title, info.program)
				record.cwd = if block.cwd and block.cwd ~= "" then block.cwd else info.cwd
				record.message = despinner(block.last_message)
				record.tab = info.tab
				record.session = (info.tab and tabSession[info.tab]) or record.session
				record.updatedAt = tern.now()
			end
		end
	end
	local seenCli = {}
	for _, info in snap.panes do
		local line = info.running and info.running.line
		local name = if info.kind == "terminal" and line then cliName(line) else nil
		if name then
			seenCli[info.pane] = true
			local record = agents[info.pane]
			if not record or record.kind ~= "cli" then
				record = { pane = info.pane, kind = "cli" }
				agents[info.pane] = record
			end
			record.state = "working"
			record.title = if info.title and info.title ~= "" then info.title else nil
			record.command = name
			record.label = name
			record.vendor = VENDOR[name]
			record.cwd = info.cwd
			record.message = nil
			record.tab = info.tab
			record.session = (info.tab and tabSession[info.tab]) or record.session
			record.updatedAt = tern.now()
		end
	end
	for pane, record in agents do
		if record.kind == "cli" then
			if not seenCli[pane] then agents[pane] = nil end
		elseif not seen[pane] then
			agents[pane] = nil
		end
	end
	-- An agent that asks or works again has been seen: its mark goes.
	local cleared = false
	for pane in pendingClear do
		pendingClear[pane] = nil
		if finished[tostring(pane)] then
			finished[tostring(pane)] = nil
			cleared = true
		end
	end
	-- Marks for panes this window no longer has (closed elsewhere).
	for key in finished do
		local pane = tonumber(key)
		if not pane or not snap.byId[pane] then
			finished[key] = nil
			cleared = true
		end
	end
	if cleared then tern.kv.set("finished", finished) end
	redraw()
end

-- Two seconds is short enough that an agent appearing or ending shows at once,
-- and cheap enough to leave running: the lists are the only native work.
local TICK_MS = 2000
local tickGeneration = 0
local tick

local syncQueued = false
local function syncSoon()
	if syncQueued then return end
	syncQueued = true
	separately(function(cx)
		syncQueued = false
		sync(cx)
	end)
end

local followQueued = false
local function followSoon()
	if followQueued then return end
	followQueued = true
	separately(function(cx)
		followQueued = false
		follow(cx)
		redraw()
	end)
end

local function scheduleTick(generation)
	tern.timer(TICK_MS, function(cx) tick(generation, cx) end)
end

tick = function(generation, cx)
	-- A chain a restart replaced ends here, so two never run side by side.
	if generation ~= tickGeneration then return end
	scheduleTick(generation)
	if not cx then return end
	syncSoon()
	followSoon()
end

-- --- notices ---------------------------------------------------------------

-- A pane asks for you at most once every few seconds, and only one notice per
-- ask is worth interrupting for.
local NOTICE_COOLDOWN_MS = 5000
local noticed = {}
local noticeQueued = {}

local function notices(cx)
	for pane in noticeQueued do
		noticeQueued[pane] = nil
		local now = tern.now()
		if now - (noticed[pane] or -NOTICE_COOLDOWN_MS) >= NOTICE_COOLDOWN_MS then
			noticed[pane] = now
			local record = agents[pane]
			local label = if record then record.label else "An agent"
			cx:toast("info", "Agent needs you", label .. " is waiting for input")
			if tern.runtime.os == "macos" then
				local script = 'display notification "' .. quoted(label .. " is waiting for input")
					.. '" with title "Agent Sidebar" sound name "Glass"'
				tern.process.run({ "/usr/bin/osascript", "-e", script }, function() end)
			end
		end
	end
end

-- --- clicks ----------------------------------------------------------------

local function focusAgent(cx, pane)
	if not cx.session:pane(pane) then return end
	cx.layout:focus(pane)
	local key = tostring(pane)
	if finished[key] then
		finished[key] = nil
		tern.kv.set("finished", finished)
	end
	redraw()
end

local function markFinished(cx, pane, outcome)
	local info = cx.session:pane(pane)
	local tab = shownTab(cx)
	-- Seen as it ended: nothing to mark.
	if info and tab and info.tab == tab then return end
	local key = tostring(pane)
	if finished[key] == outcome then return end
	finished[key] = outcome
	tern.kv.set("finished", finished)
	redraw()
end

-- --- wiring ----------------------------------------------------------------

tern.command({
	id = "toggle",
	title = "Agent Sidebar",
	icon = "sparkle",
	keys = { "cmd+alt+shift+a" },
	run = function(cx)
		local pane = slot(cx)
		if pane then
			hidePanel(cx)
		else
			setWantPanel(true)
			openPanel(cx, shownTab(cx))
		end
	end,
})

tern.on("window_start", function(_cx)
	syncSoon()
	followSoon()
end)

for _, name in { "tab_created", "tab_closed", "pane_created", "session_ended" } do
	tern.on(name, function(_ev, _cx)
		followSoon()
	end)
end

-- A renamed conversation retitles its row in place; no rescan needed.
tern.on("title", function(ev, _cx)
	local record = agents[ev.pane]
	if not record then return end
	record.title = if ev.title and ev.title ~= "" then ev.title else nil
	if record.kind == "block" then
		record.label, record.vendor = identity(record.command, record.title, record.program)
	else
		record.label = if record.title then record.title else commandName(record.command) or record.label
	end
	redraw()
end)

-- The pane you look at is the one whose mark you have seen.
tern.on("focus", function(ev, _cx)
	followSoon()
	local key = tostring(ev.pane)
	if not finished[key] then return end
	separately(function(cx)
		if finished[key] then
			finished[key] = nil
			tern.kv.set("finished", finished)
			redraw()
		end
	end)
end)

-- A CLI whose command ended leaves its row now, not on the next tick.
tern.on("command_finished", function(ev, _cx)
	local record = agents[ev.pane]
	if record and record.kind == "cli" then syncSoon() end
end)

-- A closing pane takes its row with it, whatever it ran, and its mark too.
tern.on("pane_closed", function(ev, _cx)
	agents[ev.pane] = nil
	pendingClear[ev.pane] = nil
	noticeQueued[ev.pane] = nil
	local key = tostring(ev.pane)
	if finished[key] then
		separately(function(cx)
			if finished[key] then
				finished[key] = nil
				tern.kv.set("finished", finished)
				redraw()
			end
		end)
	end
	followSoon()
end)

-- A click on a row goes to its pane, and the mark it carried is now seen.
tern.on("canvas_action", function(ev, _cx)
	if ev.act ~= "focus" then return false end
	local pane = tonumber(ev.value)
	if not pane then return false end
	separately(function(cx) focusAgent(cx, pane) end)
	return true
end)

-- Tern reports an agent's state; the record notes it and the display follows.
-- A new agent is also where the label comes from, so a sync fills it in.
tern.on("agent_state", function(ev, _cx)
	local record = agents[ev.pane]
	if record then record.state = ev.new end
	local resumed = ev.new == "working" or ev.new == "waiting_input"
	if resumed then pendingClear[ev.pane] = true end
	if ev.new == "waiting_input" then noticeQueued[ev.pane] = true end
	if ev.old == nil or not record or resumed then
		syncSoon()
	else
		redraw()
	end
	if next(noticeQueued) ~= nil then separately(notices) end
end)

-- A turn that ends out of sight leaves a done or failed mark until you look;
-- an agent that has gone leaves nothing.
tern.on("agent_finished", function(ev, _cx)
	if ev.result == "done" or ev.result == "failed" then
		separately(function(cx) markFinished(cx, ev.pane, ev.result) end)
	else
		separately(function(cx)
			agents[ev.pane] = nil
			local key = tostring(ev.pane)
			if finished[key] then
				finished[key] = nil
				tern.kv.set("finished", finished)
			end
			redraw()
		end)
	end
	syncSoon()
end)

-- Tern pauses a hook whose callback ran over its budget; when it comes back,
-- the ticks and the panel catch up once.
tern.on("budget", function(ev, _cx)
	if ev.state == "resumed" then
		syncSoon()
		followSoon()
	end
end)

scheduleTick(tickGeneration)
