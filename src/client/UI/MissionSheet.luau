-- Mission sheet (new HUD layouts): the whole plan on one overlay, so the HUD itself can stay down to one goal line.
--   open: hold Tab (keyboard) / hold View (gamepad Select) while it is held; touch: tap the goal line (tap again or the
--   X button to close)
--   left:  full objective checklist (filled by UI/ObjectiveList into slot "objectives")
--   right: where we are (planet, sector, faction, difficulty, threat, extraction; UI/AreaInfo fills slot "area"),
--          resources so far (UI/TopRight counts), reinforcements left
-- Only while setAllowed(true) (combat, objectives known) and no menu is open. Built by ObjectiveList in the new layouts.
-- API: build(touch) / destroy() / slot(name) -> Frame / setAllowed(on) / open() / close() / toggle() / isOpen()
local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local TopRight = require(script.Parent.TopRight)
local Store = require(script.Parent.Parent.Store)
local Input = require(script.Parent.Parent.Input)

local MissionSheet = {}

local ui: { [string]: any } = {}
local touch = false
local allowed = false
local isOpenFlag = false
local holdDown = false
local refreshGen = 0
local wired = false

function MissionSheet.destroy()
	isOpenFlag = false
	if ui.gui then
		ui.gui:Destroy()
	end
	ui = {}
end

local function section(parent: Instance, title: string, order: number): Frame
	local f = Instance.new("Frame")
	f.Name = title
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder = order
	f.Parent = parent
	Theme.list(f, Enum.FillDirection.Vertical, 3)
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 20)
	head.LayoutOrder = 0
	head.Parent = f
	Theme.list(head, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	InfoLayer.mark(head, InfoLayer.col("dim"), 0)
	InfoLayer.label({
		Text = title,
		TextSize = 14,
		ColorRole = "dim",
		Size = UDim2.new(1, -16, 1, 0),
		LayoutOrder = 1,
		Parent = head,
	})
	return f
end

function MissionSheet.build(isTouch: boolean)
	MissionSheet.destroy()
	touch = isTouch
	local E = InfoLayer.entry("sheet", touch)
	local rowSize: number = E.RowSize or 17
	local titleSize: number = E.TitleSize or 26
	local gui = Theme.gui("OrbitMissionSheet", { DisplayOrder = 13, Insets = "CoreUISafeInsets", Enabled = false })
	ui.gui = gui
	local root = Theme.root(gui, "hud")

	local sheet = Instance.new("CanvasGroup")
	sheet.Name = "Sheet"
	sheet.BackgroundTransparency = 1
	sheet.BorderSizePixel = 0
	InfoLayer.place(sheet, "sheet", touch)
	sheet.Parent = root
	ui.sheet = sheet
	HudSkin.panel("plate", { Name = "Backing", Size = UDim2.fromScale(1, 1), ZIndex = 0, Parent = sheet })
	for _, y in { 0, 1 } do
		local l = Instance.new("Frame")
		l.BorderSizePixel = 0
		l.BackgroundColor3 = InfoLayer.col("own")
		l.BackgroundTransparency = 0.45
		l.AnchorPoint = Vector2.new(0, y)
		l.Position = UDim2.fromScale(0, y)
		l.Size = UDim2.new(1, 0, 0, 2)
		l.Parent = sheet
	end
	local pad = if touch then 12 else 22

	-- title row: mission name + hint / close button
	local title = InfoLayer.label({
		Text = "MISSION",
		TextSize = titleSize,
		ColorRole = "objective",
		Position = UDim2.fromOffset(pad, pad - 4),
		Size = UDim2.new(1, -pad * 2 - 120, 0, titleSize + 6),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = sheet,
	})
	ui.title = title
	ui.sub = InfoLayer.label({
		Text = "",
		TextSize = rowSize - 2,
		ColorRole = "dim",
		Position = UDim2.fromOffset(pad, pad + titleSize + 2),
		Size = UDim2.new(1, -pad * 2, 0, rowSize + 2),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = sheet,
	})
	if touch then
		local closeSize: number = E.CloseSize or 54
		local btn = Instance.new("TextButton")
		btn.Name = "Close"
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.BackgroundTransparency = 1
		btn.AnchorPoint = Vector2.new(1, 0)
		btn.Position = UDim2.new(1, -4, 0, 4)
		btn.Size = UDim2.fromOffset(closeSize, closeSize)
		btn.ZIndex = 5
		btn.Parent = sheet
		InfoLayer.label({
			Text = "X",
			Role = "number",
			TextSize = titleSize,
			ColorRole = "text",
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 5,
			Parent = btn,
		})
		btn.Activated:Connect(function()
			MissionSheet.close()
			Theme.sfx("UIClick")
		end)
	else
		InfoLayer.label({
			Text = "HOLD TAB",
			TextSize = 13,
			ColorRole = "dim",
			XAlign = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -pad, 0, pad),
			Size = UDim2.fromOffset(120, 18),
			Parent = sheet,
		})
	end

	local top = pad + titleSize + rowSize + 14
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(pad, top)
	body.Size = UDim2.new(1, -pad * 2, 1, -top - pad)
	body.Parent = sheet

	-- left: objectives (scrolls when long)
	local left = Instance.new("ScrollingFrame")
	left.Name = "Objectives"
	left.BackgroundTransparency = 1
	left.BorderSizePixel = 0
	left.Size = UDim2.new(0.58, -10, 1, 0)
	left.CanvasSize = UDim2.fromOffset(0, 0)
	left.AutomaticCanvasSize = Enum.AutomaticSize.Y
	left.ScrollBarThickness = 3
	left.ScrollBarImageColor3 = InfoLayer.col("line")
	left.ScrollBarImageTransparency = 0.6
	left.ScrollingDirection = Enum.ScrollingDirection.Y
	left.Parent = body
	Theme.list(left, Enum.FillDirection.Vertical, 2)
	ui.objectives = left

	-- right: area, resources, reinforcements
	local right = Instance.new("ScrollingFrame")
	right.Name = "Info"
	right.BackgroundTransparency = 1
	right.BorderSizePixel = 0
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.fromScale(1, 0)
	right.Size = UDim2.new(0.42, -10, 1, 0)
	right.CanvasSize = UDim2.fromOffset(0, 0)
	right.AutomaticCanvasSize = Enum.AutomaticSize.Y
	right.ScrollBarThickness = 3
	right.ScrollBarImageColor3 = InfoLayer.col("line")
	right.ScrollBarImageTransparency = 0.6
	right.Parent = body
	Theme.list(right, Enum.FillDirection.Vertical, 12)
	-- a thin divider between the columns
	local div = Instance.new("Frame")
	div.Name = "Divider"
	div.BorderSizePixel = 0
	div.BackgroundColor3 = InfoLayer.col("line")
	div.BackgroundTransparency = 0.85
	div.Position = UDim2.fromScale(0.58, 0)
	div.Size = UDim2.new(0, 1, 1, 0)
	div.Parent = body

	local area = section(right, "AREA", 1)
	ui.area = area
	local res = section(right, "COLLECTED", 2)
	ui.resList = Instance.new("Frame")
	ui.resList.Name = "List"
	ui.resList.BackgroundTransparency = 1
	ui.resList.Size = UDim2.fromScale(1, 0)
	ui.resList.AutomaticSize = Enum.AutomaticSize.Y
	ui.resList.LayoutOrder = 1
	ui.resList.Parent = res
	Theme.list(ui.resList, Enum.FillDirection.Vertical, 2)
	local rein = section(right, "REINFORCEMENTS", 3)
	ui.lives = InfoLayer.label({
		Text = "",
		Role = "number",
		TextSize = rowSize + 2,
		ColorRole = "own",
		Size = UDim2.new(1, 0, 0, rowSize + 6),
		LayoutOrder = 1,
		Parent = rein,
	})
	ui.rowSize = rowSize

	if not wired then
		wired = true
		Input.on("MissionSheet", function(down: boolean)
			holdDown = down
			if down then
				MissionSheet.open()
			else
				MissionSheet.close()
			end
		end)
		Store.on("menuOpen", function(v: any)
			if v then
				MissionSheet.close()
			end
		end)
	end
	if isOpenFlag then
		MissionSheet.open()
	end
end

-- Named content areas other modules fill: "objectives" (ObjectiveList), "area" (AreaInfo)
function MissionSheet.slot(name: string): Frame?
	return ui[name]
end

local function refresh()
	if not ui.gui then
		return
	end
	local m = Store.get("mission")
	if type(m) == "table" then
		ui.title.Text = InfoLayer.caseText(m.objectiveName or "MISSION")
		local bits = {}
		if type(m.planetName) == "string" then
			table.insert(bits, m.planetName)
		end
		if type(m.factionName) == "string" and m.factionName ~= "" then
			table.insert(bits, m.factionName)
		end
		if m.difficulty then
			table.insert(bits, "Difficulty " .. tostring(m.difficulty))
		end
		ui.sub.Text = InfoLayer.caseText(table.concat(bits, "  /  "))
		local lives = m.lives
		ui.lives.Text = if type(lives) == "number" then tostring(lives) .. " left" else "-"
		ui.lives.Text = InfoLayer.caseText(ui.lives.Text)
		ui.lives.TextColor3 = if type(lives) == "number" and lives <= 1 then InfoLayer.col("danger") else InfoLayer.col("own")
	end
	-- resources
	for _, c in ui.resList:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local list = TopRight.summary()
	if #list == 0 then
		InfoLayer.label({
			Text = "Nothing yet",
			TextSize = ui.rowSize,
			ColorRole = "dim",
			Size = UDim2.new(1, 0, 0, ui.rowSize + 4),
			Parent = ui.resList,
		})
	end
	for i, r in list do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, ui.rowSize + 4)
		row.LayoutOrder = i
		row.Parent = ui.resList
		InfoLayer.label({
			Text = r.label,
			TextSize = ui.rowSize,
			Color = r.color,
			Size = UDim2.new(1, -60, 1, 0),
			Parent = row,
		})
		InfoLayer.label({
			Text = tostring(r.count),
			Role = "number",
			TextSize = ui.rowSize,
			ColorRole = "text",
			XAlign = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 60, 1, 0),
			Parent = row,
		})
	end
end

function MissionSheet.open()
	if not ui.gui or not allowed or Store.get("menuOpen") then
		return
	end
	local was = isOpenFlag
	isOpenFlag = true
	refresh()
	ui.gui.Enabled = true
	if not was then
		HudSkin.enter(ui.sheet, "top")
	end
	refreshGen += 1
	local gen = refreshGen
	task.spawn(function()
		while gen == refreshGen and isOpenFlag do
			task.wait(0.5)
			if gen == refreshGen and isOpenFlag then
				refresh()
			end
		end
	end)
end

function MissionSheet.close()
	if not isOpenFlag then
		return
	end
	isOpenFlag = false
	refreshGen += 1
	if ui.gui then
		ui.gui.Enabled = false
	end
end

function MissionSheet.toggle()
	if isOpenFlag then
		MissionSheet.close()
	else
		MissionSheet.open()
	end
end

function MissionSheet.isOpen(): boolean
	return isOpenFlag
end

-- combat + objectives known (ObjectiveList.setVisible)
function MissionSheet.setAllowed(on: boolean)
	allowed = on
	if not on then
		MissionSheet.close()
	elseif holdDown and not isOpenFlag then
		MissionSheet.open()
	end
end

return MissionSheet
