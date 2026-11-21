--!nonstrict
-- Compact weapon & ordnance strip docked inside the bottom-left Vitals panel (no separate bottom-right weapon box).
-- Layout:  [grenade icon + count]  [mag icon + reserve (+ PACK)]  |  [WEAPON NAME / MODE / AP]   [24 / 180]
-- Keeps the exact label contract HUD.luau and AmmoPackCount.luau write to.
local Style = require(script.Parent.HudStyle)
local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local WeaponBlock = {}

local ui: { [string]: any } = {}
local nadesShown = -1

local function text(p: { [string]: any }): TextLabel
	p.Size = UDim2.fromOffset(0, p.H or 18)
	p.H = nil
	p.AutomaticSize = Enum.AutomaticSize.X
	return HudSkin.label(p)
end

function WeaponBlock.build(parent: Instance, touch: boolean, onFireModeTap: (() -> ())?): { [string]: any }
	table.clear(ui)
	nadesShown = -1
	local lay = HudLayout.get("weapon", touch)
	local compact = lay.Compact == true
	local h = if compact then 20 else 24

	local holder = Instance.new("Frame")
	holder.Name = "WeaponBlock"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = parent
	ui.holder = holder

	local out: { [string]: any } = { root = holder }

	-- Left cluster: grenade icon/count, mag reserve count (+ optional PACK from AmmoPackCount), weapon name/mode/state
	local left = Instance.new("Frame")
	left.Name = "Left"
	left.BackgroundTransparency = 1
	left.Size = UDim2.new(1, if compact then -64 else -80, 1, 0)
	left.ClipsDescendants = true
	left.Parent = holder
	Theme.list(left, Enum.FillDirection.Horizontal, if compact then 4 else 5, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	ui.countRow = left
	ui.countOrder = 4

	-- Grenade glyph + count
	ui.nadeIcon = Style.glyph("dot", {
		Size = if compact then 7 else 8,
		Color = HudSkin.color("own"),
		Box = UDim2.fromOffset(if compact then 8 else 9, h),
		LayoutOrder = 1,
		Parent = left,
	})
	out.nade = text({
		Role = "number",
		Text = "0",
		TextSize = lay.CountSize,
		ColorRole = "own",
		H = h,
		LayoutOrder = 2,
		Parent = left,
	})

	-- Divider
	Style.rect({
		Color = HudSkin.color("line"),
		Transparency = 0.72,
		Size = UDim2.fromOffset(1, if compact then 10 else 12),
		LayoutOrder = 3,
		Parent = left,
	})

	-- Mag reserve count (+ AmmoPackCount inserts at LayoutOrder 4)
	out.mags = text({
		Role = "number",
		Text = "MAG 0",
		TextSize = lay.CountSize,
		ColorRole = "text",
		H = h,
		LayoutOrder = 3,
		Parent = left,
	})
	out.mags.Name = "Mags"

	-- Weapon name (PC) + reload state + fire mode tap button + AP tag
	if lay.NameSize > 0 then
		Style.rect({
			Color = HudSkin.color("line"),
			Transparency = 0.72,
			Size = UDim2.fromOffset(1, 12),
			LayoutOrder = 5,
			Parent = left,
		})
		out.name = text({
			Role = "label",
			Text = "",
			TextSize = lay.NameSize,
			ColorRole = "dim",
			H = h,
			LayoutOrder = 6,
			Parent = left,
		})
		out.name.TextTruncate = Enum.TextTruncate.AtEnd
		local nameCap = Instance.new("UISizeConstraint")
		nameCap.MaxSize = Vector2.new(72, h)
		nameCap.Parent = out.name
	else
		out.name = HudSkin.label({ Text = "" })
	end

	out.state = text({
		Role = "label",
		Text = "",
		TextSize = lay.ModeSize,
		ColorRole = "danger",
		H = h,
		LayoutOrder = 7,
		Parent = left,
	})

	local fm = Instance.new("TextButton")
	fm.Name = "FireMode"
	fm.AutoButtonColor = false
	fm.BackgroundTransparency = 1
	fm.BorderSizePixel = 0
	fm.TextSize = lay.ModeSize
	fm.TextColor3 = HudSkin.color("dim")
	fm.TextYAlignment = Enum.TextYAlignment.Center
	fm.Text = ""
	fm.Size = UDim2.fromOffset(0, if touch then 26 else h)
	fm.AutomaticSize = Enum.AutomaticSize.X
	fm.LayoutOrder = 8
	HudSkin.styleText(fm, "label")
	fm.Activated:Connect(function()
		if onFireModeTap then
			onFireModeTap()
		end
	end)
	fm.Parent = left
	out.fireMode = fm

	out.ap = text({
		Role = "label",
		Text = "",
		TextSize = math.max(10, lay.ModeSize - 1),
		ColorRole = "own",
		H = h,
		LayoutOrder = 9,
		Parent = left,
	})
	out.ap.Name = "ArmourPen"

	-- Right cluster: crisp mag + spare round count
	local right = Instance.new("Frame")
	right.Name = "Ammo"
	right.BackgroundTransparency = 1
	right.AnchorPoint = Vector2.new(1, 0.5)
	right.Position = UDim2.fromScale(1, 0.5)
	right.Size = UDim2.fromOffset(if compact then 62 else 78, h)
	right.Parent = holder

	local spareW = if compact then 28 else 36
	out.spare = HudSkin.label({
		Role = "number",
		Text = "/ 0",
		TextSize = lay.SpareSize,
		ColorRole = "dim",
		XAlign = Enum.TextXAlignment.Left,
		YAlign = Enum.TextYAlignment.Bottom,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -1),
		Size = UDim2.fromOffset(spareW, h),
		Parent = right,
	})
	out.mag = HudSkin.label({
		Role = "number",
		Text = "0",
		TextSize = lay.MagSize,
		XAlign = Enum.TextXAlignment.Right,
		YAlign = Enum.TextYAlignment.Bottom,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -(spareW + 2), 1, 1),
		Size = UDim2.fromOffset(if compact then 32 else 40, h),
		Parent = right,
	})

	-- Stims live in Vitals; unparented stub keeps HUD.luau writes safe
	out.stim = HudSkin.label({ Text = "" })
	ui.labels = out
	return out
end

function WeaponBlock.setGrenades(n: number)
	if n == nadesShown then
		return
	end
	nadesShown = n
	if ui.nadeIcon then
		Style.tint(ui.nadeIcon, if n <= 0 then HudSkin.color("dim") else HudSkin.color("own"))
	end
end

function WeaponBlock.addCount(name: string): TextLabel?
	local r = ui.countRow
	local mags = ui.labels and ui.labels.mags
	if not r or not mags or not r.Parent then
		return nil
	end
	local existing = r:FindFirstChild(name)
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local l = mags:Clone()
	l.Name = name
	l.LayoutOrder = ui.countOrder
	l.Text = ""
	l.Visible = false
	l.Parent = r
	return l
end

function WeaponBlock.setVisible(on: boolean)
	if ui.holder then
		ui.holder.Visible = on
	end
end

return WeaponBlock
