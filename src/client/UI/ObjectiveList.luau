-- Right-side objective checklist (y 16 % .. 36 % of the screen height). Dark panels, checkbox rows. The primary
-- (first main) objective shows a right-aligned cyan title, a 3 px cyan progress bar and a one-line instruction (the
-- active step). Checkbox rows follow for the remaining main steps and for side objectives.
-- render() returns the objectives / steps that turned done since the previous render so HUD can announce them.
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local ObjectiveList = {}

local ui: { [string]: any } = {}
local touch = false
local prevDone: { [string]: boolean }? = nil
local MAX_ROWS = 8

function ObjectiveList.build(parent: Instance, isTouch: boolean)
	touch = isTouch
	local holder = Instance.new("Frame")
	holder.Name = "Objectives"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -Style.MARGIN, 0.16, if isTouch then 0 else 0)
	holder.Size = UDim2.fromOffset(if isTouch then 210 else 270, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	holder.Parent = parent
	Theme.list(holder, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right)
	ui.holder = holder
end

function ObjectiveList.setVisible(on: boolean)
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

-- objs: Store "objectives" array. Returns (newlyDoneTitles, newlyDoneStepTexts, anyShown)
function ObjectiveList.render(objs: any): ({ string }, { string }, boolean)
	local newlyDone: { string } = {}
	local newlyStep: { string } = {}
	if not ui.holder then
		return newlyDone, newlyStep, false
	end
	clear()
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
		Theme.pad(p, 8, 6, 8, 7)
		Theme.list(p, Enum.FillDirection.Vertical, 4)
		Style.label({
			Text = (if primary.done then "DONE - " else "") .. (primary.title or "MISSION"),
			TextSize = Style.TEXT,
			Color = if primary.done then Style.Green else Style.Cyan,
			XAlign = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, 0, 0, 16),
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
		local bar = Style.bar({ Size = UDim2.new(1, 0, 0, 3), Color = Style.Cyan, LayoutOrder = 2, Parent = p })
		bar.set(frac)
		if act or primary.done then
			local text = if primary.done then "OBJECTIVE COMPLETE" else act.text
			-- a trailing "[k/n]" counter (haul: "Load cells into the cargo lifter [2/7]") gets its own right-aligned
			-- label so truncation never eats it
			local body, counter = nil, nil
			if not primary.done and type(text) == "string" then
				body, counter = string.match(text, "^(.-)%s*(%[%d+/%d+%])$")
			end
			local line = Style.label({
				Text = body or text,
				Color = if primary.done then Style.Green else Style.White,
				XAlign = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, if counter then -54 else 0, 0, 16),
				LayoutOrder = 3,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = p,
			})
			if counter then
				Style.label({
					Text = counter,
					Color = Style.Cyan,
					XAlign = Enum.TextXAlignment.Right,
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.new(1, 0, 0.5, 0),
					Size = UDim2.fromOffset(54, 16),
					Parent = line,
				})
			end
		end
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
	end
	for _, o in sides do
		local act = activeStep(o)
		local text = o.title or ""
		if act and not o.done and not touch then
			text ..= "  -  " .. act.text
		end
		addRow(text, o.done == true, true, Style.Green)
	end
	if #rows > MAX_ROWS then
		-- keep unfinished rows first, then trim
		table.sort(rows, function(a, b)
			if a.done ~= b.done then
				return not a.done
			end
			return false
		end)
		while #rows > MAX_ROWS do
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
