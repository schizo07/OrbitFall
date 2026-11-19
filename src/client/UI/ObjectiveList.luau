-- Objective block + checklist. PC: right side from y 16 %. Touch: inside the top-left column (HUD), under the area info,
-- because the touch buttons own the right edge. The primary (first main) objective is the big block: cyan title,
-- the active step in larger wrapping text with its "[k/n]" counter on the right, a 5 px progress bar, and an arrow +
-- distance to its marker. Checkbox rows follow for the remaining main steps and for side objectives.
-- render() returns the objectives / steps that turned done since the previous render so HUD can announce them.
-- step(cam) runs per frame (HUD) for the distance / arrow.
local Players = game:GetService("Players")

-- New layouts (UI STYLE A-C, UI/InfoLayer.isNew() at build time): the HUD block is replaced by UI/GoalLine (one line
-- under the compass) and the full checklist moves into UI/MissionSheet. build / render / step / setVisible keep their
-- signatures, so HUD calls them the same way for every style.
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local InfoLayer = require(script.Parent.InfoLayer)
local GoalLine = require(script.Parent.GoalLine)
local MissionSheet = require(script.Parent.MissionSheet)

local ObjectiveList = {}

local ui: { [string]: any } = {}
local touch = false
local newMode = false
local sheetHolder: Frame? = nil
local lastObjs: any = nil
local prevDone: { [string]: boolean }? = nil
local MAX_ROWS = 8
local MAX_ROWS_TOUCH = 2
local target: Vector3? = nil
local lastDist = -1

local TITLE_SIZE = 18
local STEP_SIZE = 16
local COUNTER_SIZE = 18
local COUNTER_W = 62

-- order: when given, the block is a child of a vertical list (touch left column) instead of a right-anchored holder
function ObjectiveList.build(parent: Instance, isTouch: boolean, order: number?)
	touch = isTouch
	newMode = InfoLayer.isNew()
	if newMode then
		ui = {}
		GoalLine.build(isTouch)
		MissionSheet.build(isTouch)
		sheetHolder = MissionSheet.slot("objectives")
		if lastObjs ~= nil then
			ObjectiveList.render(lastObjs)
		end
		return
	end
	sheetHolder = nil
	GoalLine.destroy()
	MissionSheet.destroy()
	local holder = Instance.new("Frame")
	holder.Name = "Objectives"
	holder.BackgroundTransparency = 1
	if order then
		holder.LayoutOrder = order
		holder.Size = UDim2.new(1, 0, 0, 0)
	else
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.new(1, -Style.MARGIN, 0.16, 0)
		holder.Size = UDim2.fromOffset(if isTouch then 210 else 300, 0)
	end
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	holder.Parent = parent
	Theme.list(holder, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right)
	ui.holder = holder
end

function ObjectiveList.setVisible(on: boolean)
	if newMode then
		GoalLine.setVisible(on)
		MissionSheet.setAllowed(on)
		return
	end
	if ui.holder then
		ui.holder.Visible = on
	end
end

function ObjectiveList.reset()
	prevDone = nil
end

local function clear()
	for _, c in ui.holder:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function checkRow(parent: Instance, text: string, done: boolean, active: boolean, order: number, color: Color3): Frame
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = order
	row.Parent = parent
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.AnchorPoint = Vector2.new(0, 0.5)
	box.Position = UDim2.new(0, 0, 0.5, 0)
	box.Size = UDim2.fromOffset(11, 11)
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Parent = row
	local st = Instance.new("UIStroke")
	st.Color = if done then color else Style.White
	st.Transparency = if done or active then 0 else 0.5
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = box
	if done then
		Style.rect({
			Color = color,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(5, 5),
			Parent = box,
		})
	end
	Style.label({
		Text = text,
		Rich = false,
		Color = if done then Style.Grey elseif active then Style.White else Style.Grey,
		TextTransparency = if done then 0.3 else 0,
		Position = UDim2.fromOffset(17, 0),
		Size = UDim2.new(1, -17, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	return row
end

local function activeStep(o: any): any?
	if o.steps then
		for _, s in o.steps do
			if s.active then
				return s
			end
		end
	end
	return nil
end

-- What the player should do now, shared by the goal line and the mission sheet (one source for "active step + marker").
--   text      active step of the primary (first main) objective, without a trailing "[k/n]"; "OBJECTIVE COMPLETE" when done
--   counter   "2/7" from a trailing "[2/7]", or nil
--   frac      0..1 progress of the active step (hold %, k/n), nil when the step has no progress to show
--   marker    the primary's marker, else the first unfinished objective's that has one
--   nextSteps up to 2 unfinished step texts after the active one
--   sides     unfinished side objectives { title, text, marker, started }
export type Goal = {
	title: string,
	text: string,
	counter: string?,
	frac: number?,
	marker: Vector3?,
	done: boolean,
	nextSteps: { string },
	sides: { { title: string, text: string?, marker: Vector3?, started: boolean } },
}

function ObjectiveList.goal(objs: any): Goal?
	if type(objs) ~= "table" or #objs == 0 then
		return nil
	end
	local primary: any = nil
	for _, o in objs do
		if o.main then
			primary = o
			break
		end
	end
	primary = primary or objs[1]
	local act = activeStep(primary)
	local g: Goal = {
		title = primary.title or "MISSION",
		text = "",
		counter = nil,
		frac = nil,
		marker = nil,
		done = primary.done == true,
		nextSteps = {},
		sides = {},
	}
	if primary.done then
		g.text = "OBJECTIVE COMPLETE"
	else
		local text = act and act.text or primary.title or "OBJECTIVE"
		local body, counter = string.match(text, "^(.-)%s*%[(%d+/%d+)%]$")
		g.text = body or text
		g.counter = counter
		if act and act.progress ~= nil then
			g.frac = math.clamp(act.progress, 0, 1)
		elseif counter then
			local k, n = string.match(counter, "(%d+)/(%d+)")
			local kn, nn = tonumber(k), tonumber(n)
			if kn and nn and nn > 0 then
				g.frac = math.clamp(kn / nn, 0, 1)
			end
		end
		local sk, sn = string.match(g.text, "%((%d+)/(%d+)%)")
		if not g.frac and sk then
			local kn, nn = tonumber(sk), tonumber(sn)
			if kn and nn and nn > 0 then
				g.frac = math.clamp(kn / nn, 0, 1)
			end
		end
		if primary.steps then
			local after = false
			for _, s in primary.steps do
				if after and not s.done and #g.nextSteps < 2 then
					table.insert(g.nextSteps, (string.gsub(s.text or "", "%s*%[%d+/%d+%]$", "")))
				end
				if s == act then
					after = true
				end
			end
		end
	end
	if not primary.done and typeof(primary.marker) == "Vector3" then
		g.marker = primary.marker
	else
		for _, o in objs do
			if not o.done and typeof(o.marker) == "Vector3" then
				g.marker = o.marker
				break
			end
		end
	end
	for _, o in objs do
		if o ~= primary and not o.main and not o.done then
			local sa = activeStep(o)
			local started = false
			if o.steps then
				for i, s in o.steps do
					if s.done or (s.active and i > 1) or (s.active and s.progress ~= nil and s.progress > 0) then
						started = true
					end
				end
			end
			table.insert(g.sides, {
				title = o.title or "SIDE OBJECTIVE",
				text = sa and sa.text or nil,
				marker = if typeof(o.marker) == "Vector3" then o.marker else nil,
				started = started,
			})
		end
	end
	return g
end

-- newly finished objectives / steps since the previous call (new layouts; the old path keeps its inline copy)
local function diffDone(objs: any): ({ string }, { string })
	local newlyDone: { string } = {}
	local newlyStep: { string } = {}
	if type(objs) ~= "table" or #objs == 0 then
		prevDone = nil
		return newlyDone, newlyStep
	end
	local doneNow: { [string]: boolean } = {}
	for _, o in objs do
		local key = tostring(o.id)
		doneNow[key] = o.done == true
		if prevDone and o.done and not prevDone[key] then
			table.insert(newlyDone, o.title or "Objective")
		end
		if o.steps then
			for i, s in o.steps do
				local k = key .. ":" .. i
				doneNow[k] = s.done == true
				if prevDone and s.done and not prevDone[k] and not o.done then
					table.insert(newlyStep, s.text)
				end
			end
		end
	end
	prevDone = doneNow
	return newlyDone, newlyStep
end

-- Mission sheet checklist (new layouts): every objective with all its steps, in the skin.
local function renderSheet(objs: any)
	local holder = sheetHolder
	if not holder or not holder.Parent then
		return
	end
	for _, c in holder:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	if type(objs) ~= "table" or #objs == 0 then
		InfoLayer.label({ Text = "No objectives yet", TextSize = 18, Color = InfoLayer.col("dim"), Size = UDim2.new(1, 0, 0, 24), Parent = holder })
		return
	end
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	local mains, sides = {}, {}
	for _, o in objs do
		table.insert(o.main and mains or sides, o)
	end
	local function block(o: any, isMain: boolean)
		local col = if isMain then InfoLayer.col("objective") else InfoLayer.col("heal")
		local head = Instance.new("Frame")
		head.Name = "Head"
		head.BackgroundTransparency = 1
		head.Size = UDim2.new(1, 0, 0, 26)
		head.LayoutOrder = nextOrder()
		head.Parent = holder
		Theme.list(head, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		InfoLayer.mark(head, col, 0)
		InfoLayer.label({
			Text = (if isMain then "" else "SIDE: ") .. (o.title or "OBJECTIVE") .. (if o.done then "  -  DONE" else ""),
			TextSize = 20,
			Color = if o.done then InfoLayer.col("dim") else col,
			Size = UDim2.new(1, -16, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 1,
			Parent = head,
		})
		if o.steps then
			for _, s in o.steps do
				local row = Instance.new("Frame")
				row.Name = "Step"
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0, 22)
				row.LayoutOrder = nextOrder()
				row.Parent = holder
				local box = Instance.new("Frame")
				box.Name = "Box"
				box.AnchorPoint = Vector2.new(0, 0.5)
				box.Position = UDim2.new(0, 18, 0.5, 0)
				box.Size = UDim2.fromOffset(10, 10)
				box.BackgroundColor3 = col
				box.BackgroundTransparency = if s.done then 0 else 1
				box.BorderSizePixel = 0
				box.Parent = row
				if InfoLayer.style() == "glass" then
					local c = Instance.new("UICorner")
					c.CornerRadius = UDim.new(0.5, 0)
					c.Parent = box
				end
				local st = Instance.new("UIStroke")
				st.Color = if s.done or s.active then col else InfoLayer.col("dim")
				st.Thickness = 1
				st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				st.Parent = box
				InfoLayer.label({
					Text = s.text or "",
					TextSize = 18,
					Color = if s.done then InfoLayer.col("dim") elseif s.active then InfoLayer.col("text") else InfoLayer.col("dim"),
					TextTransparency = if s.done then 0.35 else 0,
					Position = UDim2.fromOffset(38, 0),
					Size = UDim2.new(1, -38, 1, 0),
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
			end
		end
		if type(o.sites) == "table" then
			for _, site in o.sites do
				local row = Instance.new("Frame")
				row.Name = "Site"
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0, 20)
				row.LayoutOrder = nextOrder()
				row.Parent = holder
				local line = tostring(site.label or "")
				if site.detail and site.detail ~= "" then
					line ..= "  -  " .. tostring(site.detail)
				end
				InfoLayer.label({
					Text = line,
					TextSize = 15,
					Color = if site.done then InfoLayer.col("dim") else col,
					TextTransparency = if site.done then 0.4 else 0.1,
					Position = UDim2.fromOffset(38, 0),
					Size = UDim2.new(1, -38, 1, 0),
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
			end
		end
	end
	for _, o in mains do
		block(o, true)
	end
	for _, o in sides do
		block(o, false)
	end
end

-- objs: Store "objectives" array. Returns (newlyDoneTitles, newlyDoneStepTexts, anyShown)
function ObjectiveList.render(objs: any): ({ string }, { string }, boolean)
	lastObjs = objs -- kept in every style, so a switch back to a new layout starts from the current list
	if newMode then
		local nd, ns = diffDone(objs)
		local g = ObjectiveList.goal(objs)
		GoalLine.set(g)
		renderSheet(objs)
		return nd, ns, g ~= nil
	end
	local newlyDone: { string } = {}
	local newlyStep: { string } = {}
	if not ui.holder then
		return newlyDone, newlyStep, false
	end
	clear()
	target = nil
	ui.distRow, ui.dist, ui.arrow = nil, nil, nil
	if type(objs) ~= "table" or #objs == 0 then
		prevDone = nil
		return newlyDone, newlyStep, false
	end
	local doneNow: { [string]: boolean } = {}
	local mains, sides = {}, {}
	for _, o in objs do
		table.insert(o.main and mains or sides, o)
		local key = tostring(o.id)
		doneNow[key] = o.done == true
		if prevDone and o.done and not prevDone[key] then
			table.insert(newlyDone, o.title or "Objective")
		end
		if o.steps then
			for i, s in o.steps do
				local k = key .. ":" .. i
				doneNow[k] = s.done == true
				if prevDone and s.done and not prevDone[k] and not o.done then
					table.insert(newlyStep, s.text)
				end
			end
		end
	end
	prevDone = doneNow

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- primary objective block
	local primary = mains[1]
	if primary then
		local p = Style.panel({
			Name = "Primary",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(),
			Parent = ui.holder,
		})
		Theme.pad(p, 10, 8, 10, 9)
		Theme.list(p, Enum.FillDirection.Vertical, 5)
		Style.label({
			Text = (if primary.done then "DONE - " else "") .. (primary.title or "MISSION"),
			TextSize = TITLE_SIZE,
			Color = if primary.done then Style.Green else Style.Cyan,
			XAlign = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 22),
			LayoutOrder = 1,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = p,
		})
		local act = activeStep(primary)
		local frac = 0
		if primary.steps and #primary.steps > 0 then
			local doneCount = 0
			for _, s in primary.steps do
				if s.done then
					doneCount += 1
				end
			end
			frac = doneCount / #primary.steps
			if act and act.progress ~= nil then
				frac = (doneCount + math.clamp(act.progress, 0, 1)) / #primary.steps
			end
		end
		if primary.done then
			frac = 1
		end
		if act or primary.done then
			local text = if primary.done then "OBJECTIVE COMPLETE" else act.text
			-- a trailing "[k/n]" counter (haul: "Load cells into the cargo lifter [2/7]") gets its own big right-aligned
			-- label; the step text wraps onto a second line instead of being cut
			local body, counter = nil, nil
			if not primary.done and type(text) == "string" then
				body, counter = string.match(text, "^(.-)%s*(%[%d+/%d+%])$")
			end
			local line = Instance.new("Frame")
			line.Name = "Step"
			line.BackgroundTransparency = 1
			line.Size = UDim2.new(1, 0, 0, 0)
			line.AutomaticSize = Enum.AutomaticSize.Y
			line.LayoutOrder = 2
			line.Parent = p
			local stepLabel = Style.label({
				Text = body or text,
				TextSize = STEP_SIZE,
				Color = if primary.done then Style.Green else Style.White,
				XAlign = Enum.TextXAlignment.Left,
				YAlign = Enum.TextYAlignment.Top,
				Wrap = true,
				Size = UDim2.new(1, if counter then -COUNTER_W else 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Parent = line,
			})
			stepLabel.Name = "StepText"
			if counter then
				local cl = Style.label({
					Text = string.sub(counter, 2, -2), -- "2/7"
					TextSize = COUNTER_SIZE,
					Color = Style.Cyan,
					XAlign = Enum.TextXAlignment.Right,
					YAlign = Enum.TextYAlignment.Top,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, 0, 0, -1),
					Size = UDim2.fromOffset(COUNTER_W, 22),
					Parent = line,
				})
				cl.Name = "Counter"
			end
		end
		local bar = Style.bar({ Size = UDim2.new(1, 0, 0, 5), Color = Style.Cyan, LayoutOrder = 3, Parent = p })
		bar.set(frac)

		-- arrow + distance to the objective marker (filled per frame by step)
		local marker: Vector3? = nil
		if not primary.done and typeof(primary.marker) == "Vector3" then
			marker = primary.marker
		end
		target = marker
		lastDist = -1
		ui.distRow, ui.dist, ui.arrow = nil, nil, nil
		if marker then
			local row = Instance.new("Frame")
			row.Name = "Distance"
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 22)
			row.LayoutOrder = 4
			row.Parent = p
			local arrow = Style.glyph("up", {
				Size = 14,
				Color = Style.Cyan,
				Box = UDim2.fromOffset(22, 22),
				Parent = row,
			})
			arrow.AnchorPoint = Vector2.new(0, 0)
			local dist = Style.label({
				Text = "",
				TextSize = COUNTER_SIZE,
				Color = Style.Cyan,
				Size = UDim2.new(1, -28, 1, 0),
				Position = UDim2.fromOffset(28, 0),
				Parent = row,
			})
			ui.distRow, ui.dist, ui.arrow = row, dist, arrow
		end
	else
		target = nil
		ui.distRow, ui.dist, ui.arrow = nil, nil, nil
	end

	-- checklist panel: remaining main steps + side objectives
	local rows = {}
	local function addRow(text: string, done: boolean, active: boolean, color: Color3)
		table.insert(rows, { text = text, done = done, active = active, color = color })
	end
	for mi, o in mains do
		if mi > 1 then
			addRow(o.title or "OBJECTIVE", o.done == true, true, Style.Cyan)
		end
		if o.steps and (mi == 1 or not touch) then
			for _, s in o.steps do
				if touch and not s.active then
					continue
				end
				if mi == 1 and s.active then
					continue -- shown as the instruction line above
				end
				addRow(s.text, s.done == true, s.active == true, Style.Cyan)
			end
		end
		if type(o.sites) == "table" then
			for _, site in o.sites do
				local txt = tostring(site.label or "")
				if site.detail and site.detail ~= "" and not touch then
					txt ..= "  -  " .. tostring(site.detail)
				end
				addRow(txt, site.done == true, site.done ~= true, Style.Cyan)
			end
		end
	end
	for _, o in sides do
		local act = activeStep(o)
		local text = o.title or ""
		if act and not o.done and not touch then
			text ..= "  -  " .. act.text
		end
		addRow(text, o.done == true, true, Style.Green)
	end
	-- touch: the block shares the left column with the uplink list and must end above the FEED button (y 50 %)
	local maxRows = if touch then MAX_ROWS_TOUCH else MAX_ROWS
	if #rows > maxRows then
		-- keep unfinished rows first, then trim
		table.sort(rows, function(a, b)
			if a.done ~= b.done then
				return not a.done
			end
			return false
		end)
		while #rows > maxRows do
			table.remove(rows)
		end
	end
	if #rows > 0 then
		local p = Style.panel({
			Name = "Checklist",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(),
			Parent = ui.holder,
		})
		Theme.pad(p, 8, 6, 8, 6)
		Theme.list(p, Enum.FillDirection.Vertical, 2)
		for i, r in rows do
			checkRow(p, r.text, r.done, r.active, i, r.color)
		end
	end
	return newlyDone, newlyStep, true
end

-- Per frame: distance + arrow towards the primary objective's marker, relative to the camera heading.
function ObjectiveList.step(cam: Camera)
	if newMode then
		GoalLine.step(cam)
		return
	end
	local tgt = target
	local dist, arrow = ui.dist, ui.arrow
	if not tgt or not dist or not arrow or not ui.holder or not ui.holder.Visible then
		return
	end
	local char = Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local from = if root then root.Position else cam.CFrame.Position
	local d = tgt - from
	local m = math.floor(Vector3.new(d.X, 0, d.Z).Magnitude + 0.5)
	if m ~= lastDist then
		lastDist = m
		dist.Text = string.format("%d M", m)
	end
	local look = cam.CFrame.LookVector
	local camAng = math.deg(math.atan2(look.X, -look.Z))
	local bearing = math.deg(math.atan2(d.X, -d.Z))
	arrow.Rotation = (bearing - camAng + 180) % 360 - 180
end

-- Sample counter parsed from objective texts like "Collect the glowing samples (2/5)"
function ObjectiveList.sampleCount(objs: any): number?
	if type(objs) ~= "table" then
		return nil
	end
	local best: number? = nil
	for _, o in objs do
		if o.steps then
			for _, s in o.steps do
				if type(s.text) == "string" and string.find(string.lower(s.text), "sample", 1, true) then
					local n = string.match(s.text, "%((%d+)/%d+%)")
					if n then
						best = math.max(best or 0, tonumber(n) or 0)
					end
				end
			end
		end
	end
	return best
end

return ObjectiveList
