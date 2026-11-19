--!nonstrict
-- New-layout weapon block (UI STYLE skins only; the old HUD keeps HUD's own card). UI/HudLayout "weapon":
--   PC, bottom-right, right-aligned rows:   [grenade pips]  GREN 3   MAG 6   PACK 2
--                                           RELOAD  AR-12 VANGUARD  AUTO
--                                           24 / 180            (mag in the big number font)
--   phone, top-left under the health bar, one row:  24 / 180   GREN 3   MAG 6
-- HUD keeps writing the same label roles it wrote on the old card (ui.ammoMag, ammoSpare, ammoName, ammoState,
-- fireMode, cntNade, cntMags), so the ammo logic in HUD stays one code path.
--   WeaponBlock.build(parent, touch, onFireModeTap) -> labels { root, mag, spare, name, ap, state, fireMode, nade, mags, stim }
--   WeaponBlock.setGrenades(n)       grenade pips (PC)
--   WeaponBlock.addCount(name)       an extra count cell after MAG (AmmoPackCount: "PACK"); nil before the block exists
--   WeaponBlock.setVisible(on)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local WeaponBlock = {}

local ui: { [string]: any } = {}
local nadesShown = -1

local function row(parent: Instance, name: string, h: number, order: number, align: Enum.HorizontalAlignment, gap: number): Frame
	local r = Instance.new("Frame")
	r.Name = name
	r.BackgroundTransparency = 1
	r.Size = UDim2.new(1, 0, 0, h)
	r.LayoutOrder = order
	r.Parent = parent
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.HorizontalAlignment = align
	l.VerticalAlignment = Enum.VerticalAlignment.Bottom
	l.Padding = UDim.new(0, gap)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = r
	return r
end

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
	local holder = Instance.new("Frame")
	holder.Name = "WeaponBlock"
	holder.BackgroundTransparency = 1
	HudLayout.apply(holder, "weapon", touch)
	holder.Parent = parent
	ui.holder = holder
	local align = if compact then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Right
	local out: { [string]: any } = { root = holder }

	-- fire mode: a button so touch can tap it to switch (HUD.fireModeTap)
	local fm = Instance.new("TextButton")
	fm.Name = "FireMode"
	fm.AutoButtonColor = false
	fm.BackgroundTransparency = 1
	fm.BorderSizePixel = 0
	fm.TextSize = lay.ModeSize
	fm.TextColor3 = HudSkin.color("dim")
	fm.TextYAlignment = Enum.TextYAlignment.Bottom
	fm.Text = ""
	fm.Size = UDim2.fromOffset(0, if touch then 30 else lay.ModeSize + 4)
	fm.AutomaticSize = Enum.AutomaticSize.X
	HudSkin.styleText(fm, "label")
	fm.Activated:Connect(function()
		if onFireModeTap then
			onFireModeTap()
		end
	end)
	out.fireMode = fm

	if compact then
		-- one row: mag, spare, grenades, mags (+ pack), fire mode
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Horizontal
		list.HorizontalAlignment = Enum.HorizontalAlignment.Left
		list.VerticalAlignment = Enum.VerticalAlignment.Bottom
		list.Padding = UDim.new(0, 6)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = holder
		out.mag = text({ Role = "number", Text = "0", TextSize = lay.MagSize, H = lay.MagSize + 2, LayoutOrder = 1, Shadow = true, Parent = holder })
		out.spare = text({ Role = "number", Text = "/ 0", TextSize = lay.SpareSize, ColorRole = "dim", H = lay.SpareSize + 4, LayoutOrder = 2, Parent = holder })
		out.nade = text({ Role = "label", Text = "GREN 0", TextSize = lay.CountSize, ColorRole = "own", H = lay.CountSize + 4, LayoutOrder = 3, Parent = holder })
		out.mags = text({ Role = "label", Text = "MAG 0", TextSize = lay.CountSize, H = lay.CountSize + 4, LayoutOrder = 4, Parent = holder })
		out.mags.Name = "Mags"
		out.state = text({ Role = "label", Text = "", TextSize = lay.CountSize, ColorRole = "danger", H = lay.CountSize + 4, LayoutOrder = 6, Parent = holder })
		fm.LayoutOrder = 7
		fm.Parent = holder
		out.ap = text({ Role = "label", Text = "", TextSize = lay.CountSize, ColorRole = "own", H = lay.CountSize + 4, LayoutOrder = 8, Parent = holder })
		out.ap.Name = "ArmourPen"
		-- the name is not shown on phones; HUD still writes it
		out.name = HudSkin.label({ Text = "" })
		ui.countRow = holder
		ui.countOrder = 5
	else
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Vertical
		list.HorizontalAlignment = Enum.HorizontalAlignment.Right
		list.VerticalAlignment = Enum.VerticalAlignment.Bottom
		list.Padding = UDim.new(0, 2)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = holder

		local counts = row(holder, "Counts", lay.CountSize + 6, 1, align, 12)
		local nadePips = Instance.new("Frame")
		nadePips.Name = "NadePips"
		nadePips.BackgroundTransparency = 1
		nadePips.Size = UDim2.fromOffset(0, lay.CountSize + 4)
		nadePips.AutomaticSize = Enum.AutomaticSize.X
		nadePips.LayoutOrder = 1
		nadePips.Parent = counts
		local pl = Instance.new("UIListLayout")
		pl.FillDirection = Enum.FillDirection.Horizontal
		pl.VerticalAlignment = Enum.VerticalAlignment.Center
		pl.Padding = UDim.new(0, 3)
		pl.SortOrder = Enum.SortOrder.LayoutOrder
		pl.Parent = nadePips
		ui.nadePips = nadePips
		ui.glyphSize = lay.GlyphSize
		out.nade = text({ Role = "label", Text = "GREN 0", TextSize = lay.CountSize, ColorRole = "own", H = lay.CountSize + 4, LayoutOrder = 2, Parent = counts })
		out.mags = text({ Role = "label", Text = "MAG 0", TextSize = lay.CountSize, H = lay.CountSize + 4, LayoutOrder = 3, Parent = counts })
		out.mags.Name = "Mags"
		ui.countRow = counts
		ui.countOrder = 4

		local nameRow = row(holder, "Weapon", lay.NameSize + 6, 2, align, 10)
		out.state = text({ Role = "label", Text = "", TextSize = lay.ModeSize, ColorRole = "danger", H = lay.NameSize + 4, LayoutOrder = 1, Parent = nameRow })
		out.name = text({ Role = "label", Text = "", TextSize = lay.NameSize, ColorRole = "dim", H = lay.NameSize + 4, LayoutOrder = 2, Parent = nameRow })
		out.name.TextTruncate = Enum.TextTruncate.AtEnd
		fm.LayoutOrder = 3
		fm.Parent = nameRow
		out.ap = text({ Role = "label", Text = "", TextSize = lay.ModeSize, ColorRole = "own", H = lay.NameSize + 4, LayoutOrder = 4, Parent = nameRow })
		out.ap.Name = "ArmourPen"

		-- mag row: the mag number keeps a fixed box (HUD jitters / pops it per shot), the spare count sits right of it
		local magRow = Instance.new("Frame")
		magRow.Name = "Mag"
		magRow.BackgroundTransparency = 1
		magRow.Size = UDim2.new(1, 0, 0, lay.MagSize)
		magRow.LayoutOrder = 3
		magRow.Parent = holder
		local spareW = lay.SpareSize * 3.4
		out.spare = HudSkin.label({
			Role = "number",
			Text = "/ 0",
			TextSize = lay.SpareSize,
			ColorRole = "dim",
			XAlign = Enum.TextXAlignment.Left,
			YAlign = Enum.TextYAlignment.Bottom,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 0, 1, -math.round(lay.MagSize * 0.12)),
			Size = UDim2.fromOffset(spareW, lay.SpareSize + 4),
			Parent = magRow,
		})
		out.mag = HudSkin.label({
			Role = "number",
			Text = "0",
			TextSize = lay.MagSize,
			XAlign = Enum.TextXAlignment.Right,
			YAlign = Enum.TextYAlignment.Bottom,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -(spareW + 6), 1, 0),
			Size = UDim2.fromOffset(lay.MagSize * 2.6, lay.MagSize),
			Shadow = true,
			Parent = magRow,
		})
	end
	-- stims live in UI/Vitals on the new layout; HUD still writes this label (never parented)
	out.stim = HudSkin.label({ Text = "" })
	ui.labels = out
	return out
end

function WeaponBlock.setGrenades(n: number)
	if not ui.nadePips or n == nadesShown then
		return
	end
	nadesShown = n
	for _, c in ui.nadePips:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local skin = HudSkin.current()
	local shape = if skin and skin.glyphHollow then "diamondHollow" else "diamond"
	for i = 1, math.min(n, 6) do
		Style.glyph(shape, { Size = ui.glyphSize, Color = HudSkin.color("own"), LayoutOrder = i, Parent = ui.nadePips })
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
