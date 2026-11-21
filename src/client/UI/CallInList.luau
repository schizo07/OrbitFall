-- Top-left collapsible call-in chip + reinforcement pill (clear of Roblox's top-left chrome).
--   Collapsed (idle):  [diamond] CALL-INS [Q]  +  reinforcement count pill (icon + count)
--   Dialing (UplinkDial): expands icon / code / cooldown drawer right beneath the chip
--   Dialing (UplinkCodes): header highlights active while UplinkCodes docks directly beneath it
--   Primed (holding armed beacon): shrinks to a single primed call-in chip in the beacon's accent colour
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallIns = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local TopRight = require(script.Parent.TopRight)
local UplinkCodes = require(script.Parent.UplinkCodes)
local Store = require(script.Parent.Parent.Store)
local Input = require(script.Parent.Parent.Input)

local uplinkDial: any = nil
local function dialOpen(): boolean
	if uplinkDial == nil then
		local m = script.Parent:FindFirstChild("UplinkDial")
		uplinkDial = if m and m:IsA("ModuleScript") then require(m) :: any else false
	end
	return uplinkDial ~= false and uplinkDial.isOpen() == true
end

local CallInList = {}

local DIR_SHAPE = { U = "up", D = "down", L = "left", R = "right" }

local touch = false
local ui: { [string]: any } = {}
local drawerRows: { any } = {}
local slotKey: string? = nil
local wantVisible = false
local lastLives: number? = nil
local lastPrimedId: string? = nil

local function makeDrawerRow(def: any, order: number, reinforce: boolean, slotIndex: number?): any
	local color = if reinforce then InfoLayer.col("heal") else Theme.beaconColor(def and def.beacon)
	local row = Instance.new("Frame")
	row.Name = "DrawerRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, if touch then 28 else 32)
	row.LayoutOrder = order
	row.Parent = ui.drawerList

	local glyph = Style.glyph(if def then Style.callinShape(def) else "dot", {
		Size = if touch then 12 else 14,
		Color = color,
		Box = UDim2.fromOffset(22, if touch then 28 else 32),
		Parent = row,
	})
	glyph.AnchorPoint = Vector2.zero

	local name = InfoLayer.label({
		Text = if reinforce then "REINFORCE" else (def and def.name or "?"),
		TextSize = if touch then 12 else 13,
		ColorRole = "text",
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -86, 0, 16),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})

	local status = InfoLayer.label({
		Text = "READY",
		Role = "number",
		TextSize = if touch then 11 else 12,
		ColorRole = "heal",
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(56, 16),
		Parent = row,
	})

	local codeHost = Instance.new("Frame")
	codeHost.Name = "Code"
	codeHost.BackgroundTransparency = 1
	codeHost.Position = UDim2.fromOffset(26, 16)
	codeHost.Size = UDim2.new(1, -30, 0, 12)
	codeHost.Parent = row
	Theme.list(codeHost, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	if def then
		for i, d in CallIns.codeOf(def) do
			Style.glyph(DIR_SHAPE[d] or "dot", { Size = 8, Color = color, LayoutOrder = i, Parent = codeHost })
		end
	end

	return {
		row = row,
		glyph = glyph,
		name = name,
		status = status,
		def = def,
		reinforce = reinforce,
		slotIndex = slotIndex,
		color = color,
	}
end

local function rebuildDrawer(me: any)
	for _, r in drawerRows do
		r.row:Destroy()
	end
	table.clear(drawerRows)
	local slots = me and me.callins and me.callins.slots or {}
	for i, s in slots do
		table.insert(drawerRows, makeDrawerRow(CallIns.get(s.id), i, false, i))
	end
	table.insert(drawerRows, makeDrawerRow(CallIns.get("REINFORCE"), 20, true, nil))
end

function CallInList.build(_parent: Instance, isTouch: boolean, _order: number?)
	touch = isTouch
	ui = {}
	table.clear(drawerRows)
	slotKey = nil
	lastLives = nil
	lastPrimedId = nil

	local E = InfoLayer.entry("callins", touch)
	local headerH: number = E.Size.Y.Offset
	local ts: number = E.TextSize or 14

	local holder = InfoLayer.fresh("CallInStrip")
	InfoLayer.place(holder, "callins", touch)
	holder.Size = UDim2.fromOffset(E.DrawerWidth or 300, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	Theme.list(holder, Enum.FillDirection.Vertical, 5, Enum.HorizontalAlignment.Left)
	ui.holder = holder

	-- Row 1: Collapsed CALL-INS header chip + keybind hint
	local header = HudSkin.panel("plate", {
		Name = "HeaderChip",
		Size = UDim2.fromOffset(0, headerH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Parent = holder,
	})
	Theme.pad(header, 8, 0, 8, 0)
	Theme.list(header, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	ui.header = header
	ui.headerEdge = header:FindFirstChild("SkinEdge")

	Style.glyph("diamond", {
		Size = math.max(9, math.floor(ts * 0.65)),
		Color = InfoLayer.col("own"),
		Box = UDim2.fromOffset(14, headerH),
		LayoutOrder = 1,
		Parent = header,
	})
	InfoLayer.label({
		Text = "CALL-INS",
		TextSize = ts,
		ColorRole = "text",
		Size = UDim2.fromOffset(0, headerH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = header,
	})
	if not touch then
		local keyBox = Instance.new("Frame")
		keyBox.Name = "KeyHint"
		keyBox.BackgroundColor3 = InfoLayer.col("own")
		keyBox.BackgroundTransparency = 0.85
		keyBox.BorderSizePixel = 0
		keyBox.Size = UDim2.fromOffset(0, headerH - 8)
		keyBox.AutomaticSize = Enum.AutomaticSize.X
		keyBox.LayoutOrder = 3
		keyBox.Parent = header
		local ks = Instance.new("UIStroke")
		ks.Color = InfoLayer.col("own")
		ks.Transparency = 0.35
		ks.Thickness = 1
		ks.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		ks.Parent = keyBox
		Theme.pad(keyBox, 5, 0, 5, 0)
		ui.keyLabel = InfoLayer.label({
			Text = if Input.isGamepad() then "LB" else "Q",
			Role = "number",
			TextSize = math.max(11, ts - 2),
			ColorRole = "own",
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(0, headerH - 8),
			AutomaticSize = Enum.AutomaticSize.X,
			Parent = keyBox,
		})
	end

	-- Row 2A (collapsed idle): compact reinforcement count pill
	local reinH = if touch then 24 else 28
	local rein = HudSkin.panel("plate", {
		Name = "ReinforcePill",
		Size = UDim2.fromOffset(0, reinH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = holder,
	})
	Theme.pad(rein, 7, 0, 9, 0)
	Theme.list(rein, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	ui.reinPill = rein

	ui.reinIcon = Style.glyph("down", {
		Size = if touch then 10 else 11,
		Color = InfoLayer.col("own"),
		Box = UDim2.fromOffset(14, reinH),
		LayoutOrder = 1,
		Parent = rein,
	})
	ui.reinCount = InfoLayer.label({
		Text = "0",
		Role = "number",
		TextSize = if touch then 14 else 16,
		ColorRole = "own",
		Size = UDim2.fromOffset(0, reinH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = rein,
	})
	ui.reinTag = InfoLayer.label({
		Text = "REINFORCE",
		TextSize = math.max(10, ts - 3),
		ColorRole = "dim",
		Size = UDim2.fromOffset(0, reinH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Parent = rein,
	})

	-- Row 2B (primed beacon): single compact primed call-in chip
	local primed = HudSkin.panel("plate", {
		Name = "PrimedChip",
		Size = UDim2.fromOffset(0, reinH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Visible = false,
		Parent = holder,
	})
	ui.primed = primed
	ui.primedEdge = primed:FindFirstChild("SkinEdge")
	local pDeco = Instance.new("Folder")
	pDeco.Name = "AccentHost"
	pDeco.Parent = primed
	ui.primedAccent = Style.rect({
		Name = "Accent",
		Color = InfoLayer.col("own"),
		Size = UDim2.new(0, 3, 1, 0),
		ZIndex = 2,
		Parent = pDeco,
	})
	local pInner = Instance.new("Frame")
	pInner.Name = "Inner"
	pInner.BackgroundTransparency = 1
	pInner.Size = UDim2.fromOffset(0, reinH)
	pInner.AutomaticSize = Enum.AutomaticSize.X
	pInner.Parent = primed
	Theme.pad(pInner, 9, 0, 9, 0)
	Theme.list(pInner, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	ui.primedGlyphHost = Instance.new("Frame")
	ui.primedGlyphHost.BackgroundTransparency = 1
	ui.primedGlyphHost.Size = UDim2.fromOffset(14, reinH)
	ui.primedGlyphHost.LayoutOrder = 1
	ui.primedGlyphHost.Parent = pInner
	ui.primedName = InfoLayer.label({
		Text = "",
		TextSize = ts,
		ColorRole = "text",
		Size = UDim2.fromOffset(0, reinH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = pInner,
	})
	ui.primedTag = InfoLayer.label({
		Text = "PRIMED",
		TextSize = math.max(10, ts - 3),
		ColorRole = "own",
		Size = UDim2.fromOffset(0, reinH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3,
		Parent = pInner,
	})

	-- Row 2C (expanded drawer while using radial UplinkDial; UplinkCodes docks its own interactive drawer here)
	local drawer = HudSkin.panel("plate", {
		Name = "Drawer",
		Size = UDim2.fromOffset(E.DrawerWidth or 280, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 4,
		Visible = false,
		Parent = holder,
	})
	local dList = Instance.new("Frame")
	dList.Name = "List"
	dList.BackgroundTransparency = 1
	dList.Size = UDim2.fromScale(1, 0)
	dList.AutomaticSize = Enum.AutomaticSize.Y
	dList.Parent = drawer
	Theme.pad(dList, 8, 6, 8, 6)
	Theme.list(dList, Enum.FillDirection.Vertical, 3)
	ui.drawer = drawer
	ui.drawerList = dList
end

function CallInList.setVisible(on: boolean)
	wantVisible = on
	if ui.holder then
		ui.holder.Visible = on
	end
end

local function updatePrimedChip(holding: any)
	local hid = if type(holding) == "table" and type(holding.id) == "string" then holding.id else nil
	if hid == lastPrimedId then
		return
	end
	lastPrimedId = hid
	if not hid or not ui.primed then
		return
	end
	local def = CallIns.get(hid)
	local col = if hid == "REINFORCE" then InfoLayer.col("heal") elseif def then Theme.beaconColor(def.beacon) else InfoLayer.col("own")
	if type(holding) == "table" and holding.perfect then
		col = InfoLayer.col("own")
	end
	ui.primedAccent.BackgroundColor3 = col
	if ui.primedEdge then
		ui.primedEdge.Color = col
		ui.primedEdge.Transparency = 0.45
	end
	ui.primedName.Text = InfoLayer.caseText(def and def.name or hid)
	ui.primedTag.TextColor3 = col
	for _, c in ui.primedGlyphHost:GetChildren() do
		c:Destroy()
	end
	Style.glyph(if def then Style.callinShape(def) else "diamond", {
		Size = 11,
		Color = col,
		Box = UDim2.fromScale(1, 1),
		Parent = ui.primedGlyphHost,
	})
end

function CallInList.update(me: any, t: number)
	if not ui.holder or type(me) ~= "table" or type(me.callins) ~= "table" or type(me.callins.slots) ~= "table" then
		return
	end
	local slots = me.callins.slots
	local ids = {}
	for _, s in slots do
		table.insert(ids, s.id)
	end
	local key = table.concat(ids, ",")
	if key ~= slotKey then
		slotKey = key
		rebuildDrawer(me)
	end

	ui.holder.Visible = wantVisible and #drawerRows > 0
	if not ui.holder.Visible then
		return
	end

	-- Update keybind hint (keyboard vs gamepad)
	if ui.keyLabel then
		local wantKey = if Input.isGamepad() then "LB" else "Q"
		if ui.keyLabel.Text ~= wantKey then
			ui.keyLabel.Text = wantKey
		end
	end

	-- Reinforcements count
	local m = Store.get("mission")
	local lives = if type(m) == "table" and type(m.lives) == "number" then m.lives else TopRight.getLives()
	if lives ~= lastLives then
		if lastLives ~= nil and lives ~= nil and ui.reinCount then
			HudSkin.bump(ui.reinCount)
		end
		lastLives = lives
		if ui.reinCount and lives ~= nil then
			local col = if lives <= 1 then InfoLayer.col("danger") else InfoLayer.col("own")
			ui.reinCount.Text = tostring(lives)
			ui.reinCount.TextColor3 = col
			Style.tint(ui.reinIcon, col)
		end
	end

	local codesOpen = UplinkCodes.isOpen()
	local radialOpen = dialOpen()
	local dialing = codesOpen or radialOpen
	local holding = me.callins.holding or Store.get("holding")
	local isPrimed = type(holding) == "table" and type(holding.id) == "string"

	if ui.headerEdge then
		ui.headerEdge.Color = if dialing then InfoLayer.col("own") else InfoLayer.col("line")
		ui.headerEdge.Transparency = if dialing then 0.35 else HudSkin.BORDER_ALPHA
	end

	-- Three crisp states:
	--   1) Dialing via UplinkCodes -> hide collapsed pill/primed/own drawer so UplinkCodes docks cleanly underneath header
	--   2) Dialing via UplinkDial -> expand own drawer right beneath header
	--   3) Primed (holding armed beacon) -> show single primed chip
	--   4) Idle -> show collapsed reinforcement pill only
	local showDrawer = radialOpen and not codesOpen
	local showPrimed = not dialing and isPrimed
	local showRein = not dialing and not isPrimed and lives ~= nil

	if ui.reinPill then
		ui.reinPill.Visible = showRein
	end
	if ui.primed then
		if showPrimed then
			updatePrimedChip(holding)
		end
		ui.primed.Visible = showPrimed
	end
	if ui.drawer then
		if ui.drawer.Visible ~= showDrawer then
			if showDrawer then
				HudSkin.enter(ui.drawer, "top")
			else
				ui.drawer.Visible = false
			end
		end
	end

	if not showDrawer then
		return
	end

	for _, r in drawerRows do
		local def = r.def
		if not def then
			continue
		end
		local available, remaining, reason
		local slot
		if r.reinforce then
			remaining = math.max(0, (me.reinforceReadyAt or 0) - t)
			available = remaining <= 0
			reason = if available then "READY" else "COOLDOWN"
		else
			slot = slots[r.slotIndex]
			if not slot then
				continue
			end
			available, remaining, reason = Theme.slotStatus(slot, def, t)
		end
		local status: string
		if reason == "NO USES" then
			status = "EMPTY"
		elseif remaining > 0 and not (slot and slot.charges ~= nil and slot.charges > 0) then
			status = tostring(math.ceil(remaining)) .. "S"
		elseif slot and slot.maxCharges and slot.maxCharges > 1 then
			status = "x" .. tostring(slot.charges or 0)
		elseif def.uses and slot then
			status = "x" .. tostring(slot.uses or def.uses)
		else
			status = "READY"
		end
		r.status.Text = status
		r.status.TextColor3 = if available then InfoLayer.col("heal") elseif reason == "NO USES" then InfoLayer.col("danger") else InfoLayer.col("dim")
		r.name.TextTransparency = if available then 0 else 0.45
		Style.glyphAlpha(r.glyph, if available then 0 else 0.5)
	end
end

return CallInList
