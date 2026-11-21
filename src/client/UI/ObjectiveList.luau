-- Top-right compact objective checklist + active progress bar (clear of Roblox's top-right PlayerList/chrome).
-- Each checklist row shows: square checkbox + small objective glyph + short uppercase label (+ counter/distance).
-- Active objective progress bar sits directly underneath. Full breakdown also populates UI/MissionSheet (hold Tab).
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local GoalLine = require(script.Parent.GoalLine)
local MissionSheet = require(script.Parent.MissionSheet)

local ObjectiveList = {}

local ui: { [string]: any } = {}
local touch = false
local sheetHolder: Frame? = nil
local lastObjs: any = nil
local prevDone: { [string]: boolean }? = nil
local wantVisible = false
local extractText: string? = nil
local activeTarget: Vector3? = nil
local lastDist = -1

local MAX_ROWS_PC = 4

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

-- Mission sheet full checklist (Tab overlay)
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
		InfoLayer.label({ Text = "No objectives yet", TextSize = 16, ColorRole = "dim", Size = UDim2.new(1, 0, 0, 22), Parent = holder })
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
		local col = if isMain then InfoLayer.col("own") else InfoLayer.col("objective")
		local head = Instance.new("Frame")
		head.Name = "Head"
		head.BackgroundTransparency = 1
		head.Size = UDim2.new(1, 0, 0, 24)
		head.LayoutOrder = nextOrder()
		head.Parent = holder
		Theme.list(head, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		InfoLayer.mark(head, col, 0)
		InfoLayer.label({
			Text = (if isMain then "" else "SIDE: ") .. (o.title or "OBJECTIVE") .. (if o.done then "  -  DONE" else ""),
			TextSize = 18,
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
				row.Size = UDim2.new(1, 0, 0, 20)
				row.LayoutOrder = nextOrder()
				row.Parent = holder
				local box = Instance.new("Frame")
				box.Name = "Box"
				box.AnchorPoint = Vector2.new(0, 0.5)
				box.Position = UDim2.new(0, 16, 0.5, 0)
				box.Size = UDim2.fromOffset(10, 10)
				box.BackgroundColor3 = col
				box.BackgroundTransparency = if s.done then 0 else 1
				box.BorderSizePixel = 0
				box.Parent = row
				local st = Instance.new("UIStroke")
				st.Color = if s.done or s.active then col else InfoLayer.col("dim")
				st.Thickness = 1
				st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				st.Parent = box
				InfoLayer.label({
					Text = s.text or "",
					TextSize = 16,
					Color = if s.done then InfoLayer.col("dim") elseif s.active then InfoLayer.col("text") else InfoLayer.col("dim"),
					TextTransparency = if s.done then 0.35 else 0,
					Position = UDim2.fromOffset(34, 0),
					Size = UDim2.new(1, -34, 1, 0),
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
				row.Size = UDim2.new(1, 0, 0, 18)
				row.LayoutOrder = nextOrder()
				row.Parent = holder
				local line = tostring(site.label or "")
				if site.detail and site.detail ~= "" then
					line ..= "  -  " .. tostring(site.detail)
				end
				InfoLayer.label({
					Text = line,
					TextSize = 14,
					Color = if site.done then InfoLayer.col("dim") else col,
					TextTransparency = if site.done then 0.4 else 0.1,
					Position = UDim2.fromOffset(34, 0),
					Size = UDim2.new(1, -34, 1, 0),
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

-- Compact top-right perimeter card -----------------------------------------------------------------------------------
local function clearCard()
	if not ui.list then
		return
	end
	for _, c in ui.list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	ui.distLabel = nil
	lastDist = -1
end

local function addChecklistRow(
	parent: Instance,
	text: string,
	done: boolean,
	active: boolean,
	accent: Color3,
	shape: string,
	rightText: string?,
	order: number,
	textSize: number
): TextLabel?
	local rowH = textSize + 6
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, rowH)
	row.LayoutOrder = order
	row.Parent = parent

	-- Square checkbox
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.AnchorPoint = Vector2.new(0, 0.5)
	box.Position = UDim2.new(0, 0, 0.5, 0)
	box.Size = UDim2.fromOffset(10, 10)
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Parent = row
	local st = Instance.new("UIStroke")
	st.Color = if done then InfoLayer.col("heal") elseif active then accent else InfoLayer.col("dim")
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = box
	if done then
		Style.rect({
			Color = InfoLayer.col("heal"),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(6, 6),
			Parent = box,
		})
	end

	-- Small objective icon
	Style.glyph(shape, {
		Size = 9,
		Color = if done then InfoLayer.col("dim") else accent,
		Box = UDim2.fromOffset(14, rowH),
		Position = UDim2.fromOffset(14, 0),
		Parent = row,
	})

	local rightW = if rightText and rightText ~= "" then 46 else 0
	InfoLayer.label({
		Text = text,
		TextSize = textSize,
		Color = if done then InfoLayer.col("dim") elseif active then InfoLayer.col("text") else InfoLayer.col("dim"),
		TextTransparency = if done then 0.35 else 0,
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(1, -(34 + rightW), 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})

	local rightLbl: TextLabel? = nil
	if rightText ~= nil then
		rightLbl = InfoLayer.label({
			Text = rightText,
			Role = "number",
			TextSize = math.max(11, textSize - 1),
			Color = if done then InfoLayer.col("heal") else accent,
			XAlign = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 44, 1, 0),
			Parent = row,
		})
	end
	return rightLbl
end

local function renderCard()
	if not ui.holder or not ui.list then
		return
	end
	clearCard()
	local objs = lastObjs
	local g = ObjectiveList.goal(objs)
	if not g and not extractText then
		ui.holder.Visible = false
		activeTarget = nil
		return
	end

	local E = InfoLayer.entry("objectives", touch)
	local textSize: number = E.TextSize or 14
	local subSize: number = E.SubSize or 12
	local compact = E.Compact == true
	local accent = if extractText or (g and g.done) then InfoLayer.col("heal") else InfoLayer.col("own")
	if ui.accent then
		ui.accent.BackgroundColor3 = accent
	end

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- Extraction override row at top when Skiff is active
	if extractText then
		addChecklistRow(ui.list, extractText, false, true, InfoLayer.col("heal"), "up", "", nextOrder(), textSize)
	end

	if g then
		activeTarget = g.marker
		local primaryRight = g.counter or (if g.marker then "" else nil)
		local rightLbl = addChecklistRow(
			ui.list,
			g.title,
			g.done,
			not g.done,
			accent,
			"diamond",
			primaryRight,
			nextOrder(),
			textSize
		)
		if not g.counter and g.marker then
			ui.distLabel = rightLbl
		end

		-- Active sub-step instruction if it adds detail beyond the title
		if not g.done and g.text ~= "" and string.upper(g.text) ~= string.upper(g.title) then
			InfoLayer.label({
				Text = g.text,
				TextSize = subSize,
				ColorRole = "dim",
				Size = UDim2.new(1, 0, 0, subSize + 4),
				TextTruncate = Enum.TextTruncate.AtEnd,
				LayoutOrder = nextOrder(),
				Parent = ui.list,
			})
		end

		-- Active objective progress bar directly underneath
		local frac = g.frac
		if frac == nil and type(objs) == "table" then
			for _, o in objs do
				if o.main and type(o.steps) == "table" and #o.steps > 1 then
					local doneN = 0
					for _, s in o.steps do
						if s.done then
							doneN += 1
						end
					end
					if doneN > 0 or o.done then
						frac = if o.done then 1 else doneN / #o.steps
					end
					break
				end
			end
		end
		if frac ~= nil then
			local bar = HudSkin.bar({
				Name = "ActiveProgress",
				Size = UDim2.new(1, 0, 0, 3),
				Color = accent,
				LayoutOrder = nextOrder(),
				Parent = ui.list,
			})
			bar.set(frac, accent)
		end

		-- Remaining main & side checklist rows on PC (compact phone keeps 1 active row to stay above MobileControls)
		if not compact and type(objs) == "table" then
			local count = 1
			local firstMain = true
			for _, o in objs do
				if count >= MAX_ROWS_PC then
					break
				end
				if o.main and firstMain then
					firstMain = false
					continue
				end
				count += 1
				local col = if o.main then InfoLayer.col("own") else InfoLayer.col("objective")
				local shape = if o.main then "diamond" else "diamondHollow"
				local act = activeStep(o)
				local _, cnt = nil, nil
				if act and type(act.text) == "string" then
					_, cnt = string.match(act.text, "^(.-)%s*%[(%d+/%d+)%]$")
				end
				addChecklistRow(ui.list, o.title or "OBJECTIVE", o.done == true, not o.done, col, shape, cnt, nextOrder(), textSize - 1)
			end
		end
	else
		activeTarget = nil
	end

	ui.holder.Visible = wantVisible
end

function ObjectiveList.build(_parent: Instance, isTouch: boolean, _order: number?)
	touch = isTouch
	ui = {}
	GoalLine.build(isTouch)
	GoalLine.onExtract(function(text: string?)
		extractText = text
		renderCard()
	end)
	MissionSheet.build(isTouch)
	sheetHolder = MissionSheet.slot("objectives")

	local holder = InfoLayer.fresh("Objectives")
	InfoLayer.place(holder, "objectives", touch)
	holder.Size = UDim2.fromOffset(holder.Size.X.Offset, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	InfoLayer.backing(holder, "plate")
	ui.holder = holder

	-- Crisp 2 px left accent stripe (in Folder so UIListLayout ignores it)
	local deco = Instance.new("Folder")
	deco.Name = "AccentHost"
	deco.Parent = holder
	ui.accent = Style.rect({
		Name = "Accent",
		Color = InfoLayer.col("own"),
		Size = UDim2.new(0, 2, 1, 0),
		ZIndex = 2,
		Parent = deco,
	})

	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.Parent = holder
	Theme.pad(list, if touch then 8 else 10, if touch then 5 else 7, if touch then 8 else 10, if touch then 5 else 7)
	Theme.list(list, Enum.FillDirection.Vertical, if touch then 3 else 4)
	ui.list = list

	-- Touch: tapping the compact objective card toggles the full MissionSheet
	if touch then
		local hitFolder = Instance.new("Folder")
		hitFolder.Name = "Hit"
		hitFolder.Parent = holder
		local hit = Instance.new("TextButton")
		hit.Name = "SheetHit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.AutoButtonColor = false
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = 5
		hit.Parent = hitFolder
		hit.Activated:Connect(function()
			MissionSheet.toggle()
			Theme.sfx("UIClick")
		end)
	end

	if lastObjs ~= nil then
		ObjectiveList.render(lastObjs)
	end
end

function ObjectiveList.setVisible(on: boolean)
	wantVisible = on
	GoalLine.setVisible(on)
	MissionSheet.setAllowed(on)
	if ui.holder then
		ui.holder.Visible = on and (lastObjs ~= nil and #lastObjs > 0 or extractText ~= nil)
	end
end

function ObjectiveList.reset()
	prevDone = nil
	extractText = nil
end

function ObjectiveList.render(objs: any): ({ string }, { string }, boolean)
	lastObjs = objs
	local nd, ns = diffDone(objs)
	local g = ObjectiveList.goal(objs)
	renderCard()
	renderSheet(objs)
	return nd, ns, g ~= nil
end

function ObjectiveList.step(cam: Camera)
	local tgt = activeTarget
	local lbl = ui.distLabel
	if not tgt or not lbl or not ui.holder or not ui.holder.Visible then
		return
	end
	local from = InfoLayer.localPos(cam)
	local d = tgt - from
	local m = math.floor(Vector3.new(d.X, 0, d.Z).Magnitude + 0.5)
	if m ~= lastDist then
		lastDist = m
		lbl.Text = if m >= 1000 then string.format("%.1fKM", m / 1000) else string.format("%dM", m)
	end
end

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
