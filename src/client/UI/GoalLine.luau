-- Goal line (new HUD layouts): one line under the compass that says where to go and what to do.
--   caret (points at the objective marker, relative to the camera) + step text in the objective colour + "k/n" counter
--   + distance; a 2 px progress line under it while the step has progress (hold %, k/n)
--   GOAL LINES A/B (workspace attribute Feel_GoalLines): nil = current step only (the checklist is in the mission sheet);
--   "next" = also the next 2 steps, smaller, under the line
--   side line: a side objective within 120 m, or one that has been started
--   phones: main line + progress only (the alert bar sits right under it); next steps and sides are in the sheet
--   extraction: setExtract(text) replaces the step text with "BOARD THE SKIFF 0:18" / "SKIFF INBOUND 0:42"
--   intro: intro(text) shows a 4 s line (planet / faction / difficulty) at the drop
-- Touch: the line is the tap target for the mission sheet (a 44 px tall hit box around it).
-- Data comes from UI/ObjectiveList (ObjectiveList.goal); built and driven by ObjectiveList in the new layouts only.
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local MissionSheet = require(script.Parent.MissionSheet)

local GoalLine = {}

local SIDE_RANGE = 120
local INTRO_FOR = 4

local ui: { [string]: any } = {}
local touch = false
local want = false
local goal: any = nil
local extractText: string? = nil
local shownText = ""
local lastDist = -1
local lastSideDist = -1
local sideShown: any = nil
local introGen = 0

local function fmtDist(m: number): string
	if m >= 1000 then
		return string.format("%.1f km", m / 1000)
	end
	return string.format("%d m", m)
end

function GoalLine.destroy()
	InfoLayer.drop("GoalLine")
	ui = {}
	extractText = nil -- AreaInfo sets it again on its next update in a new layout
	goal = nil -- ObjectiveList.build hands it back from the current list
end

local function baseColor(): Color3
	if extractText or (goal and goal.done) then
		return InfoLayer.col("heal")
	end
	return InfoLayer.col("objective")
end

function GoalLine.build(isTouch: boolean)
	touch = isTouch
	ui = {}
	shownText = ""
	lastDist, lastSideDist = -1, -1
	sideShown = nil
	local E = InfoLayer.entry("goal", touch)
	local S = InfoLayer.entry("side", touch)
	local textSize: number = E.TextSize or 24
	local distSize: number = E.DistSize or 20
	local caretSize: number = E.CaretSize or 13
	local smallSize: number = S.TextSize or 15
	local maxW: number = E.MaxWidth or 670

	local holder = InfoLayer.fresh("GoalLine")
	InfoLayer.place(holder, "goal", touch)
	holder.Size = UDim2.fromOffset(maxW, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	Theme.list(holder, Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Center)
	ui.holder = holder

	-- main row: caret + text + counter + distance, centred, auto width
	local rowH = textSize + 6
	local row = Instance.new("Frame")
	row.Name = "Main"
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromOffset(0, rowH)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.LayoutOrder = 1
	row.Parent = holder
	Theme.list(row, Enum.FillDirection.Horizontal, if touch then 6 else 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	ui.row = row
	if InfoLayer.style() == "glass" then
		-- style B: one soft pill behind the line; the other styles draw no box on always-visible text
		Theme.pad(row, 14, 0, 14, 0)
		local b = InfoLayer.backing(row)
		local c = b:FindFirstChildOfClass("UICorner")
		if c then
			c.CornerRadius = UDim.new(0.5, 0)
		end
	end
	local caret = Style.glyph("up", {
		Size = caretSize,
		Color = InfoLayer.col("objective"),
		Box = UDim2.fromOffset(caretSize + 6, caretSize + 6),
		LayoutOrder = 1,
		Parent = row,
	})
	ui.caret = caret
	ui.text = InfoLayer.label({
		Text = "",
		TextSize = textSize,
		Role = "label",
		Color = InfoLayer.col("objective"),
		Shadow = true,
		Size = UDim2.fromOffset(0, rowH),
		AutomaticSize = Enum.AutomaticSize.X,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 2,
		Parent = row,
	})
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(maxW - 3 * distSize - 4 * caretSize, math.huge)
	cap.Parent = ui.text
	ui.counter = InfoLayer.label({
		Text = "",
		Role = "number",
		TextSize = distSize,
		Color = InfoLayer.col("objective"),
		Shadow = true,
		Size = UDim2.fromOffset(0, rowH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Visible = false,
		Parent = row,
	})
	ui.dist = InfoLayer.label({
		Text = "",
		Role = "number",
		TextSize = distSize,
		ColorRole = "text",
		TextTransparency = 0.3,
		Shadow = true,
		Size = UDim2.fromOffset(0, rowH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 4,
		Visible = false,
		Parent = row,
	})

	-- 2 px progress line, as wide as the main row
	local prog = Instance.new("Frame")
	prog.Name = "Progress"
	prog.BackgroundColor3 = InfoLayer.col("line")
	prog.BackgroundTransparency = 0.8
	prog.BorderSizePixel = 0
	prog.Size = UDim2.fromOffset(200, 2)
	prog.LayoutOrder = 2
	prog.Visible = false
	prog.ClipsDescendants = true
	prog.Parent = holder
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = InfoLayer.col("objective")
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = prog
	ui.prog, ui.fill = prog, fill
	if InfoLayer.style() == "glass" then
		for _, f in { prog, fill } do
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0.5, 0)
			c.Parent = f
		end
	end
	local function fitProg()
		if not row.Parent then
			return
		end
		local s = holder.AbsoluteSize.X / math.max(holder.Size.X.Offset, 1)
		if s > 0 then
			prog.Size = UDim2.fromOffset(math.max(40, row.AbsoluteSize.X / s), 2)
		end
	end
	row:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitProg)
	task.defer(fitProg)

	-- side line
	local side = Instance.new("Frame")
	side.Name = "Side"
	side.BackgroundTransparency = 1
	side.Size = UDim2.fromOffset(0, smallSize + 6)
	side.AutomaticSize = Enum.AutomaticSize.X
	side.LayoutOrder = 3
	side.Visible = false
	side.Parent = holder
	Theme.list(side, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	Style.glyph("diamondHollow", {
		Size = math.max(7, math.floor(smallSize * 0.6)),
		Color = InfoLayer.col("heal"),
		Box = UDim2.fromOffset(12, smallSize + 6),
		LayoutOrder = 1,
		Parent = side,
	})
	ui.sideText = InfoLayer.label({
		Text = "",
		TextSize = smallSize,
		ColorRole = "heal",
		Size = UDim2.fromOffset(0, smallSize + 6),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = side,
	})
	ui.side = side

	-- next steps (GOAL LINES B)
	ui.next = {}
	for i = 1, 2 do
		ui.next[i] = InfoLayer.label({
			Text = "",
			TextSize = smallSize,
			ColorRole = "dim",
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, smallSize + 3),
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 3 + i,
			Visible = false,
			Parent = holder,
		})
	end

	-- 4 s drop intro (planet / faction / difficulty)
	ui.intro = InfoLayer.label({
		Text = "",
		TextSize = smallSize,
		ColorRole = "dim",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, smallSize + 4),
		LayoutOrder = 7,
		Visible = false,
		Parent = holder,
	})

	-- touch: the line opens the mission sheet. The hit box sits in a Folder so the list layout ignores it; it is as
	-- tall as HudLayout's HitHeight (44 final px on the reference phone) and only as wide as the line's slot, so camera
	-- drags elsewhere keep working.
	if touch then
		local folder = Instance.new("Folder")
		folder.Name = "Hit"
		folder.Parent = holder
		local hitH: number = E.HitHeight or 54
		local hit = Instance.new("TextButton")
		hit.Name = "SheetHit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.AutoButtonColor = false
		hit.AnchorPoint = Vector2.new(0.5, 0.5)
		hit.Position = UDim2.new(0.5, 0, 0, rowH / 2)
		hit.Size = UDim2.new(0.8, 0, 0, hitH)
		hit.ZIndex = 5
		hit.Parent = folder
		hit.Activated:Connect(function()
			MissionSheet.toggle()
			Theme.sfx("UIClick")
		end)
	end

	if goal then
		GoalLine.set(goal)
	end
	holder.Visible = want and goal ~= nil
end

function GoalLine.setVisible(on: boolean)
	want = on
	if ui.holder then
		ui.holder.Visible = on and goal ~= nil
	end
end

-- Text change: the skin's goal-change transition (type-in / cross-fade / cursor rewrite) plus a one-off flash.
local function showText(text: string)
	if text == shownText or not ui.text then
		return
	end
	local first = shownText == ""
	shownText = text
	local label: TextLabel = ui.text
	label.TextColor3 = baseColor()
	if first then
		label.Text = InfoLayer.caseText(text)
		return
	end
	HudSkin.swapText(label, text)
	local base = label.TextColor3
	label.TextColor3 = InfoLayer.col("text")
	Theme.tween(label, 0.4, { TextColor3 = base })
end

local function refresh()
	if not ui.holder then
		return
	end
	local g = goal
	ui.holder.Visible = want and g ~= nil
	if not g then
		return
	end
	showText(extractText or g.text)
	ui.counter.Visible = g.counter ~= nil and not extractText
	if g.counter then
		if ui.counter.Text ~= g.counter and ui.counter.Text ~= "" then
			HudSkin.bump(ui.counter)
		end
		ui.counter.Text = g.counter
	end
	local hasMarker = g.marker ~= nil
	ui.caret.Visible = hasMarker
	ui.dist.Visible = hasMarker
	if not hasMarker then
		lastDist = -1
	end
	local frac = if extractText then nil else g.frac
	ui.prog.Visible = frac ~= nil
	if frac then
		Theme.tween(ui.fill, 0.15, { Size = UDim2.fromScale(frac, 1) })
	end
	-- phones: the alert bar sits right under the goal line (y 44), so the next steps and the side line live in the sheet
	local showNext = workspace:GetAttribute("Feel_GoalLines") == "next" and not extractText and not touch
	for i = 1, 2 do
		local s = g.nextSteps[i]
		ui.next[i].Visible = showNext and s ~= nil
		if s then
			ui.next[i].Text = InfoLayer.caseText(s)
		end
	end
end

-- g = ObjectiveList.goal(objs) (nil = nothing to do)
function GoalLine.set(g: any)
	goal = g
	refresh()
end

-- Extraction mode (AreaInfo): "BOARD THE SKIFF 0:18" / "SKIFF INBOUND 0:42" replaces the step text (nil = normal)
function GoalLine.setExtract(text: string?)
	if text == extractText then
		return
	end
	local modeChange = (extractText == nil) ~= (text == nil)
	extractText = text
	if ui.text and text and not modeChange then
		-- countdown tick: write straight through (the transition only runs when the line changes meaning)
		shownText = text
		ui.text.MaxVisibleGraphemes = -1
		ui.text.Text = InfoLayer.caseText(text)
	end
	refresh()
end

-- 4 s line under the goal at the drop
function GoalLine.intro(text: string)
	if not ui.intro then
		return
	end
	introGen += 1
	local gen = introGen
	ui.intro.Text = InfoLayer.caseText(text)
	ui.intro.TextTransparency = 0
	ui.intro.Visible = true
	task.delay(INTRO_FOR, function()
		if gen ~= introGen or not ui.intro then
			return
		end
		Theme.tween(ui.intro, 0.4, { TextTransparency = 1 })
		task.delay(0.45, function()
			if gen == introGen and ui.intro then
				ui.intro.Visible = false
			end
		end)
	end)
end

-- Per frame (HUD -> ObjectiveList.step): distance + caret, side line range check.
function GoalLine.step(cam: Camera)
	local g = goal
	if not g or not ui.holder or not ui.holder.Visible then
		return
	end
	local from = InfoLayer.localPos(cam)
	if g.marker then
		local d = g.marker - from
		local m = math.floor(Vector3.new(d.X, 0, d.Z).Magnitude + 0.5)
		if m ~= lastDist then
			lastDist = m
			ui.dist.Text = fmtDist(m)
		end
		ui.caret.Rotation = InfoLayer.bearing(cam, from, g.marker)
	end
	-- side line: a started side objective wins over one that is only near; among equals the nearest
	local best, bestD, bestStarted = nil, math.huge, false
	if not extractText and not touch then
		for _, s in g.sides do
			local dm = math.huge
			if s.marker then
				local d = s.marker - from
				dm = Vector3.new(d.X, 0, d.Z).Magnitude
			end
			if s.started or dm <= SIDE_RANGE then
				local better = if s.started ~= bestStarted then s.started else dm < bestD
				if best == nil or better then
					best, bestD, bestStarted = s, dm, s.started
				end
			end
		end
	end
	ui.side.Visible = best ~= nil
	if best then
		local m = if bestD < math.huge then math.floor(bestD + 0.5) else -1
		if best ~= sideShown or m ~= lastSideDist then
			sideShown, lastSideDist = best, m
			local t = best.title
			if best.started and best.text then
				t ..= " - " .. best.text
			end
			ui.sideText.Text = InfoLayer.caseText(t) .. (if m >= 0 then "   " .. fmtDist(m) else "")
		end
	else
		sideShown = nil
	end
end

-- GOAL LINES switches live
workspace:GetAttributeChangedSignal("Feel_GoalLines"):Connect(function()
	refresh()
end)

return GoalLine
