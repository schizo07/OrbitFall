-- After-action report: shown to the whole squad when a mission ends (Results = extracted, Failed). Payload from
-- server/MissionStats via the AfterAction remote. A result banner, mission time and objectives, then one card per squad
-- member with their numbers and 1-2 titles. Stays up after the squad is back on the ship until CLOSE (B / Backspace /
-- Enter, or tap) or a timeout.
-- Studio A/B: Feel_AfterAction (Variants group "AFTER ACTION"): nil = full report, "compact" = banner + titles only,
-- "off" = no report (the HUD results panel only, as before).
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Enemies = require(Shared.Data.Enemies)
local Theme = require(script.Parent.Theme)

local C = Theme.C
local AfterAction = {}

local SHOW_DELAY = 1.2 -- s after the report arrives (the Skiff takeoff fade hands over to the Results view first)
local TIMEOUT_FULL = 30
local TIMEOUT_COMPACT = 15
local CARD_W = 228
local CLOSE_ACTION = "OrbitAfterActionClose"

local gui: ScreenGui
local root: Frame
local token = 0

local function mode(): string
	local v = workspace:GetAttribute("Feel_AfterAction")
	if v == "compact" or v == "off" then
		return v
	end
	return "full"
end

-- ------------------------------------------------------------------ titles
type Title = { key: string, min: number, text: (number) -> string }
local TITLES: { Title } = {
	{ key = "kills", min = 1, text = function(v) return "Top gun: " .. v .. " kills" end },
	{ key = "revives", min = 1, text = function(v) return "Medic: " .. v .. (if v == 1 then " revive" else " revives") end },
	{ key = "big", min = 1, text = function(v) return "Big game hunter: " .. v .. " big kills" end },
	{ key = "callins", min = 3, text = function(v) return "Call-in maniac: " .. v .. " call-ins" end },
	{ key = "hurt", min = 1, text = function(_) return "Took one for the team" end },
	{ key = "grenades", min = 3, text = function(v) return "Grenadier: " .. v .. " grenades" end },
	{ key = "stims", min = 3, text = function(v) return "Stim fiend: " .. v .. " stims" end },
	{ key = "shots", min = 150, text = function(v) return "Trigger happy: " .. v .. " rounds" end },
}

local function statOf(p: any, key: string): number
	if key == "hurt" then
		return (p.deaths or 0) + (p.downed or 0)
	end
	local v = p[key]
	return if type(v) == "number" then v else 0
end

local function assignTitles(report: any): { [number]: { string } }
	local out: { [number]: { string } } = {}
	local players = report.players or {}
	for i in players do
		out[i] = {}
	end
	-- not a "most" title: nobody laid a finger on you
	for i, p in players do
		if report.success and (p.kills or 0) > 0 and (p.deaths or 0) == 0 and (p.downed or 0) == 0 and (p.dmg or 0) == 0 then
			table.insert(out[i], "Untouchable")
		end
	end
	for _, t in TITLES do
		local best = 0
		for _, p in players do
			best = math.max(best, statOf(p, t.key))
		end
		if best >= t.min then
			for i, p in players do
				if statOf(p, t.key) == best and #out[i] < 2 then
					table.insert(out[i], t.text(best))
				end
			end
		end
	end
	for i, p in players do
		if #out[i] == 0 then
			table.insert(out[i], if p.extracted then "Along for the ride" else "Fought to the end")
		end
	end
	return out
end

-- ------------------------------------------------------------------ building blocks
local function clear()
	token += 1
	ContextActionService:UnbindAction(CLOSE_ACTION)
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(root) then
		GuiService.SelectedObject = nil
	end
	for _, c in root:GetChildren() do
		if not c:IsA("UIScale") then
			c:Destroy()
		end
	end
	gui.Enabled = false
end

local function reasonText(report: any): string
	if report.success then
		local n, out = 0, 0
		for _, p in report.players or {} do
			n += 1
			if p.extracted then
				out += 1
			end
		end
		return string.format("%d of %d troopers made it onto the Skiff", out, n)
	elseif report.reason == "time" then
		return "The mission clock ran out"
	elseif report.reason == "squad" then
		return "Squad lost: no reinforcements left"
	end
	return "The squad did not make it out"
end

local function factionLine(byFaction: any): string?
	if type(byFaction) ~= "table" then
		return nil
	end
	local parts = {}
	for id, n in byFaction do
		local f = Enemies.Factions[id]
		table.insert(parts, ((f and f.short) or id) .. " " .. n)
	end
	if #parts < 2 then
		return nil
	end
	table.sort(parts)
	return table.concat(parts, "  ")
end

local function statGrid(parent: Instance, rows: { { string } }, y: number): number
	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(0, y)
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.Parent = parent
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.new(0.5, -4, 0, 20)
	gl.CellPadding = UDim2.fromOffset(8, 2)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid
	for i, r in rows do
		local cell = Instance.new("Frame")
		cell.BackgroundTransparency = 1
		cell.LayoutOrder = i
		cell.Parent = grid
		Theme.label({
			Text = r[1],
			Font = "Medium",
			TextSize = 13,
			Color = C.Muted,
			XAlign = Enum.TextXAlignment.Left,
			Size = UDim2.fromScale(0.62, 1),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = cell,
		})
		Theme.label({
			Text = r[2],
			Font = "Black",
			TextSize = 14,
			XAlign = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(0.62, 0),
			Size = UDim2.fromScale(0.38, 1),
			Parent = cell,
		})
	end
	return math.ceil(#rows / 2) * 22
end

local function card(parent: Instance, p: any, titles: { string }, full: boolean, order: number, me: boolean)
	local col = if p.extracted then C.Friendly elseif p.left then C.Grey else C.Muted
	local f = Theme.panel({
		Color = if me then C.PanelLight else C.Panel,
		Stroke = if me then C.Accent else C.PanelHi,
		Size = UDim2.new(0, CARD_W, 1, -6),
		LayoutOrder = order,
		Parent = parent,
	})
	Theme.pad(f, 10, 8, 10, 8)
	Theme.label({
		Text = p.n or "?",
		Font = "Black",
		TextSize = 18,
		XAlign = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = f,
	})
	Theme.label({
		Text = if p.left then "LEFT" elseif p.extracted then "EXTRACTED" else "LEFT BEHIND",
		Font = "Black",
		TextSize = 11,
		Color = col,
		XAlign = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = f,
	})
	local y = 40
	for _, t in titles do
		Theme.label({
			Text = t,
			Font = "Black",
			TextSize = 14,
			Color = C.Gold,
			XAlign = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = f,
		})
		y += 19
	end
	if not full then
		Theme.label({
			Text = string.format("%d kills  ·  %d revives", p.kills or 0, p.revives or 0),
			Font = "Medium",
			TextSize = 13,
			Color = C.Muted,
			XAlign = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(0, y + 2),
			Size = UDim2.new(1, 0, 0, 18),
			Parent = f,
		})
		return
	end
	y += 4
	local fl = factionLine(p.byFaction)
	if fl then
		Theme.label({
			Text = fl,
			Font = "Medium",
			TextSize = 12,
			Color = C.Muted,
			XAlign = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 16),
			Parent = f,
		})
		y += 17
	end
	local rows = {
		{ "Kills", tostring(p.kills or 0) },
		{ "Big kills", tostring(p.big or 0) },
		{ "Deaths", tostring(p.deaths or 0) },
		{ "Downed", tostring(p.downed or 0) },
		{ "Revives", tostring(p.revives or 0) },
		{ "Stims", tostring(p.stims or 0) },
		{ "Call-ins", tostring(p.callins or 0) },
		{ "Grenades", tostring(p.grenades or 0) },
		{ "Shots", tostring(p.shots or 0) },
		{ "Damage taken", tostring(p.dmg or 0) },
	}
	if type(p.hits) == "number" and (p.shots or 0) > 0 then
		table.insert(rows, { "Accuracy", string.format("%d%%", math.floor(math.min(1, p.hits / p.shots) * 100 + 0.5)) })
	end
	statGrid(f, rows, y)
end

-- ------------------------------------------------------------------ show
local function show(report: any)
	local m = mode()
	if m == "off" or type(report) ~= "table" then
		return
	end
	clear()
	local my = token
	local full = m == "full"
	local touch = Theme.isTouch()
	local success = report.success == true
	local col = if success then C.Friendly else C.Danger
	gui.Enabled = true

	local dim = Instance.new("TextButton") -- swallows clicks so nothing behind the report reacts
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = C.Dark
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Selectable = false
	dim.Parent = root
	Theme.tween(dim, 0.4, { BackgroundTransparency = 0.3 })

	local panel = Theme.panel({
		Color = C.Navy,
		Accent = col,
		Stroke = col,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.96, 0.94),
		Parent = root,
	})
	local lim = Instance.new("UISizeConstraint")
	lim.MaxSize = Vector2.new(1040, if full then 600 else 400)
	lim.Parent = panel
	local pop = Instance.new("UIScale")
	pop.Scale = 0.9
	pop.Parent = panel
	Theme.tween(pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	Theme.pad(panel, 16, 10, 16, 10)

	-- banner
	Theme.label({
		Text = if success then "EXTRACTED" else "MISSION FAILED",
		Font = "Header",
		TextSize = if touch then 26 else 32,
		Color = col,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.6, 0, 0, 36),
		Parent = panel,
	})
	local where = {}
	if report.objectiveName then
		table.insert(where, report.objectiveName)
	end
	if report.planetName then
		table.insert(where, report.planetName)
	end
	table.insert(where, Theme.formatTime(report.time or 0))
	Theme.label({
		Text = table.concat(where, "  ·  "),
		Font = "Black",
		TextSize = 15,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.4, 0, 0, 36),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = panel,
	})
	Theme.label({
		Text = reasonText(report),
		Font = "Medium",
		TextSize = 14,
		Color = C.Muted,
		XAlign = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = panel,
	})
	local y = 58

	-- objectives (full only)
	if full then
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Position = UDim2.fromOffset(0, y)
		row.Size = UDim2.new(1, 0, 0, 24)
		row.Parent = panel
		Theme.list(row, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		local function chip(text: string, on: boolean, order: number)
			local c = Theme.panel({
				Color = if on then C.Friendly else C.Panel,
				Transparency = if on then 0.75 else 0.2,
				Stroke = if on then C.Friendly else C.PanelHi,
				StrokeThickness = 1,
				Corner = 6,
				Size = UDim2.fromOffset(0, 22),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = order,
				Parent = row,
			})
			Theme.pad(c, 8, 0, 8, 0)
			Theme.label({
				Text = text,
				Font = "Black",
				TextSize = 12,
				Color = if on then C.Friendly else C.Muted,
				Size = UDim2.fromOffset(0, 22),
				AutomaticSize = Enum.AutomaticSize.X,
				Parent = c,
			})
		end
		local n = 0
		for _, o in report.objectives or {} do
			n += 1
			local t = tostring(o.title or "Objective")
			if o.main and not o.done and (o.steps or 0) > 0 then
				t ..= string.format(" %d/%d", o.stepsDone or 0, o.steps)
			end
			chip((if o.done then "DONE  " else "") .. string.upper(t), o.done == true, n)
		end
		chip("SAMPLES " .. tostring(report.samples or 0), (report.samples or 0) > 0, n + 1)
		y += 30
	end

	-- squad cards
	local strip = Theme.scroll({ Horizontal = true, Thickness = 4 })
	strip.Position = UDim2.fromOffset(0, y)
	strip.Size = UDim2.new(1, 0, 1, -(y + 48))
	strip.Parent = panel
	local lay = Theme.list(strip, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	local titles = assignTitles(report)
	local meId = game:GetService("Players").LocalPlayer.UserId
	for i, p in report.players or {} do
		card(strip, p, titles[i] or {}, full, i, p.u == meId)
	end

	-- footer: close + countdown
	local timeout = if full then TIMEOUT_FULL else TIMEOUT_COMPACT
	local closeBtn = Theme.button({
		Text = "CLOSE",
		Variant = "primary",
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(if touch then 150 else 130, 40),
		OnClick = function()
			if token == my then
				clear()
			end
		end,
		Parent = panel,
	})
	local hint = Theme.label({
		Text = "",
		Font = "Medium",
		TextSize = 13,
		Color = C.Muted,
		XAlign = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, -150, 0, 40),
		Parent = panel,
	})
	if UserInputService.GamepadEnabled then
		GuiService.SelectedObject = closeBtn
	end
	ContextActionService:BindActionAtPriority(CLOSE_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin and token == my then
			clear()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB, Enum.KeyCode.Backspace, Enum.KeyCode.Return)

	task.spawn(function()
		local t0 = os.clock()
		while token == my do
			local left = timeout - (os.clock() - t0)
			if left <= 0 then
				clear()
				return
			end
			hint.Text = string.format("Closes in %d s", math.ceil(left))
			task.wait(0.25)
		end
	end)
end

function AfterAction.init()
	gui = Theme.gui("OrbitAfterAction", { DisplayOrder = 62, Insets = "DeviceSafeInsets", Enabled = false })
	root = Theme.root(gui, "menu")
	Net.event("AfterAction").OnClientEvent:Connect(function(report)
		token += 1
		local my = token
		task.delay(SHOW_DELAY, function()
			if token == my then
				show(report)
			end
		end)
	end)
end

-- Studio check without a mission: AfterAction.preview(true|false) shows a made-up two-trooper report
function AfterAction.preview(success: boolean?)
	local me = game:GetService("Players").LocalPlayer
	show({
		success = success ~= false,
		reason = if success == false then "squad" else "extracted",
		time = 754,
		objectiveName = "Missile Launch",
		planetName = "Test",
		samples = 4,
		objectives = {
			{ title = "Missile Launch", main = true, done = success ~= false, steps = 4, stepsDone = if success == false then 2 else 4 },
			{ title = "Destroy the Nest", main = false, done = true, steps = 1, stepsDone = 1 },
			{ title = "Radar", main = false, done = false, steps = 2, stepsDone = 1 },
		},
		players = {
			{ u = me.UserId, n = me.DisplayName, kills = 41, byFaction = { COG = 38, BROOD = 3 }, big = 2, elites = 1, deaths = 1, downed = 2, revives = 0, stims = 4, callins = 5, grenades = 3, shots = 612, dmg = 840, extracted = success ~= false },
			{ u = 1, n = "Squadmate", kills = 27, big = 4, elites = 0, deaths = 0, downed = 1, revives = 3, stims = 1, callins = 2, grenades = 1, shots = 300, dmg = 220, extracted = false },
		},
	})
end

return AfterAction
