-- Top-left passive call-in list ("UPLINK"): one 36 px row per loadout slot plus the REINFORCE row.
--   row = "▸" tick, amber icon, caps name, uses pips (bottom right), charges badge (top right).
--   cooldown = the row dims, a dark wipe shrinks left-to-right as the cooldown runs out, remaining seconds on the right.
-- Pure display: the Uplink Dial (UI/UplinkDial + CallInController) still owns all input.
-- Data: Store "me".callins.slots[{id, readyAt, uses, charges, maxCharges}] and me.reinforceReadyAt (HUD forwards `me`).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- New layouts (UI STYLE A-C): a strip of call-in icons (bottom-left PC, top-left phone): glyph in the beacon colour,
-- a dark wipe that drains upward while it cools down, seconds under it, a uses / charges count in the corner, one pop
-- when it comes off cooldown. PC: while the Uplink is open (UplinkCodes / UplinkDial) the strip grows a list upward with
-- names and cooldowns. Phones never expand (the radial dial covers it).
local CallIns = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local UplinkCodes = require(script.Parent.UplinkCodes)
-- UplinkDial is looked up on first use: it reaches HUD (which builds this list), so a top-level require would loop
local uplinkDial: any = nil
local function dialOpen(): boolean
	if uplinkDial == nil then
		local m = script.Parent:FindFirstChild("UplinkDial")
		uplinkDial = if m and m:IsA("ModuleScript") then require(m) :: any else false
	end
	return uplinkDial ~= false and uplinkDial.isOpen() == true
end

local CallInList = {}

local newMode = false
local nu: { [string]: any } = {}
local icons: { any } = {}
local iconKey: string? = nil

local touch = false
local ui: { [string]: any } = {}
local rows: { any } = {}
local rowKey: string? = nil

local function rowHeight(): number
	return if touch then 30 else 38
end

local function makeRow(def: any, order: number, reinforce: boolean, slotIndex: number?): any
	local h = rowHeight()
	local row, tick = Style.listRow(ui.list, h, order, Style.Amber)
	tick.Position = UDim2.fromOffset(0, 0)
	local icon = Style.label({
		Text = Style.callinCode(def), -- ASCII code; the data icons are dingbats the HUD font lacks
		TextSize = if touch then 13 else 15,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 32, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Parent = row,
	})
	local name = Style.label({
		Text = if reinforce then "REINFORCE" else (def and def.name or "?"),
		TextSize = 16,
		Size = UDim2.new(1, -(if touch then 90 else 112), 1, 0),
		Position = UDim2.fromOffset(48, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = not touch, -- phones: icons only
		Parent = row,
	})
	local pips = Instance.new("Frame")
	pips.Name = "Pips"
	pips.BackgroundTransparency = 1
	pips.AnchorPoint = Vector2.new(1, 1)
	pips.Position = UDim2.new(1, -6, 1, -5)
	pips.Size = UDim2.fromOffset(60, 4)
	pips.Parent = row
	Theme.list(pips, Enum.FillDirection.Horizontal, 2, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local badge = Style.label({
		Text = "",
		TextSize = 14,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 2),
		Size = UDim2.fromOffset(40, 14),
		Parent = row,
	})
	-- cooldown wipe (dark block that shrinks towards the left) + seconds
	local wipe = Style.rect({
		Name = "Wipe",
		Color = Style.Black,
		Transparency = 0.35,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 3,
		Parent = row,
	})
	local secs = Style.label({
		Text = "",
		TextSize = if touch then 15 else 18,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(48, 22),
		XAlign = Enum.TextXAlignment.Right,
		ZIndex = 4,
		Parent = row,
	})
	return {
		row = row, tick = tick, icon = icon, name = name, pips = pips, badge = badge, wipe = wipe, secs = secs,
		def = def, reinforce = reinforce, slotIndex = slotIndex, pipCount = -1, pipMax = -1, ready = nil,
	}
end

local function rebuild(me: any)
	for _, r in rows do
		r.row:Destroy()
	end
	table.clear(rows)
	local slots = me and me.callins and me.callins.slots or {}
	for i, s in slots do
		local def = CallIns.get(s.id)
		local r = makeRow(def, i, false, i)
		if def then
			r.tick.TextColor3 = Theme.beaconColor(def.beacon)
		end
		table.insert(rows, r)
	end
	local rdef = CallIns.get("REINFORCE")
	local rr = makeRow(rdef, 20, true, nil)
	rr.icon.Text = Style.callinCode(rdef)
	rr.tick.TextColor3 = Style.Green
	table.insert(rows, rr)
end

-- New layouts ---------------------------------------------------------------------------------------------------------
local function buildNew()
	nu = {}
	table.clear(icons)
	iconKey = nil
	local E = InfoLayer.entry("callins", touch)
	local holder = InfoLayer.fresh("CallInStrip")
	InfoLayer.place(holder, "callins", touch)
	holder.Size = UDim2.fromOffset(0, E.Icon or 34)
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Visible = false
	nu.holder = holder
	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.BackgroundTransparency = 1
	strip.Size = UDim2.fromOffset(0, E.Icon or 34)
	strip.AutomaticSize = Enum.AutomaticSize.X
	strip.Parent = holder
	Theme.list(strip, Enum.FillDirection.Horizontal, E.Gap or 7, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	nu.strip = strip
	-- expanded list (PC): bottom-anchored just above the strip, grows upward
	if not touch and (E.ExpandedWidth or 0) > 0 then
		local ex = Instance.new("Frame")
		ex.Name = "Expanded"
		ex.BackgroundTransparency = 1
		ex.AnchorPoint = Vector2.new(0, 1)
		ex.Position = UDim2.fromOffset(0, if E.Docked then -20 else -8)
		ex.Size = UDim2.fromOffset(E.ExpandedWidth, 0)
		ex.AutomaticSize = Enum.AutomaticSize.Y
		ex.Visible = false
		ex.Parent = holder
		InfoLayer.backing(ex)
		Theme.pad(ex, 8, 6, 8, 6)
		Theme.list(ex, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom)
		nu.expanded = ex
	end
end

local function makeIcon(def: any, order: number, reinforce: boolean, slotIndex: number?): any
	local E = InfoLayer.entry("callins", touch)
	local size: number = E.Icon or 34
	local color = if reinforce then InfoLayer.col("heal") else Theme.beaconColor(def and def.beacon)
	local box = Instance.new("Frame")
	box.Name = "Icon"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Size = UDim2.fromOffset(size, size)
	box.LayoutOrder = order
	box.ClipsDescendants = false
	box.Parent = nu.strip
	local st = InfoLayer.style()
	local preset = InfoLayer.preset()
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.Thickness = if preset == "frame" then 2 elseif preset == "bold" then 1.5 else 1
	stroke.Transparency = if preset == "frame" then 0.15 elseif preset == "bold" then 0.2 else 0.35
	stroke.Parent = box
	if preset == "frame" then
		box.BackgroundColor3 = Color3.fromHex("0B111A")
		box.BackgroundTransparency = 0.2
	elseif preset == "bold" then
		box.BackgroundColor3 = Color3.new(0, 0, 0)
		box.BackgroundTransparency = 0.45
	end
	if st == "glass" or preset == "clean" then
		if preset == "clean" and st ~= "glass" then
			box.BackgroundColor3 = Color3.fromHex("0B111A")
			box.BackgroundTransparency = 0.25
		else
			box.BackgroundColor3 = color
			box.BackgroundTransparency = 0.7
			stroke.Color = Color3.new(1, 1, 1)
			stroke.Transparency = 0.75
		end
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = box
	elseif st == "visor" and preset ~= "frame" then
		stroke.Transparency = 0.4
	end
	-- cooldown wipe: a dark fill from the bottom that drains as the cooldown runs out
	local wipe = Instance.new("Frame")
	wipe.Name = "Wipe"
	wipe.BorderSizePixel = 0
	wipe.BackgroundColor3 = Color3.new(0, 0, 0)
	wipe.BackgroundTransparency = 0.35
	wipe.AnchorPoint = Vector2.new(0, 1)
	wipe.Position = UDim2.fromScale(0, 1)
	wipe.Size = UDim2.fromScale(1, 0)
	wipe.ZIndex = 2
	wipe.Parent = box
	if st == "glass" or preset == "clean" then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = wipe
	end
	local glyph = Style.glyph(if def then Style.callinShape(def) else "dot", {
		Size = math.floor(size * 0.44),
		Color = if st == "glass" then Color3.new(1, 1, 1) else color,
		Box = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = box,
	})
	glyph.AnchorPoint = Vector2.zero
	local secs = InfoLayer.label({
		Text = "",
		Role = "number",
		TextSize = math.max(15, math.floor(size * 0.42)),
		ColorRole = "text",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = box,
	})
	local badge = InfoLayer.label({
		Text = "",
		Role = "number",
		TextSize = math.max(14, math.floor(size * 0.35)),
		Color = color,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -5),
		Size = UDim2.fromOffset(size, math.floor(size * 0.4)),
		ZIndex = 5,
		Parent = box,
	})
	local row = nil
	if nu.expanded then
		local nameSize: number = E.NameSize or 14
		local r = Instance.new("Frame")
		r.Name = "Row"
		r.BackgroundTransparency = 1
		r.Size = UDim2.new(1, 0, 0, nameSize + 8)
		r.LayoutOrder = order
		r.Parent = nu.expanded
		local tick = Style.glyph(if def then Style.callinShape(def) else "dot", {
			Size = math.floor(nameSize * 0.6),
			Color = color,
			Box = UDim2.fromOffset(nameSize, nameSize + 8),
			Parent = r,
		})
		tick.AnchorPoint = Vector2.zero
		local name = InfoLayer.label({
			Text = if reinforce then "REINFORCE" else (def and def.name or "?"),
			TextSize = nameSize,
			ColorRole = "text",
			Position = UDim2.fromOffset(nameSize + 6, 0),
			Size = UDim2.new(1, -(nameSize + 6) - 56, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = r,
		})
		local status = InfoLayer.label({
			Text = "",
			Role = "number",
			TextSize = nameSize,
			ColorRole = "dim",
			XAlign = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 56, 1, 0),
			Parent = r,
		})
		row = { frame = r, name = name, status = status }
	end
	return {
		box = box, stroke = stroke, wipe = wipe, glyph = glyph, secs = secs, badge = badge, row = row, color = color,
		def = def, reinforce = reinforce, slotIndex = slotIndex, ready = nil,
	}
end

local function rebuildIcons(me: any)
	for _, ic in icons do
		ic.box:Destroy()
		if ic.row then
			ic.row.frame:Destroy()
		end
	end
	table.clear(icons)
	local slots = me and me.callins and me.callins.slots or {}
	for i, s in slots do
		table.insert(icons, makeIcon(CallIns.get(s.id), i, false, i))
	end
	table.insert(icons, makeIcon(CallIns.get("REINFORCE"), 20, true, nil))
end

local function uplinkOpen(): boolean
	return UplinkCodes.isOpen() or dialOpen()
end

local function updateNew(me: any, t: number)
	local slots = me.callins.slots
	local ids = {}
	for _, s in slots do
		table.insert(ids, s.id)
	end
	local key = table.concat(ids, ",")
	if key ~= iconKey then
		iconKey = key
		rebuildIcons(me)
	end
	nu.holder.Visible = nu.want == true and #icons > 0
	local expand = nu.expanded ~= nil and nu.holder.Visible and uplinkOpen()
	if nu.expanded and nu.expanded.Visible ~= expand then
		if expand then
			HudSkin.enter(nu.expanded, "bottom")
		else
			nu.expanded.Visible = false
		end
	end
	for _, ic in icons do
		local def = ic.def
		if not def then
			continue
		end
		local available, remaining, reason
		local slot
		if ic.reinforce then
			remaining = math.max(0, (me.reinforceReadyAt or 0) - t)
			available = remaining <= 0
			reason = if available then "READY" else "COOLDOWN"
		else
			slot = slots[ic.slotIndex]
			if not slot then
				continue
			end
			available, remaining, reason = Theme.slotStatus(slot, def, t)
		end
		local frac = 0
		if remaining > 0 and not (slot and slot.charges ~= nil and slot.charges > 0) then
			frac = Theme.clamp(remaining / math.max(def.cooldown, 1), 0, 1)
		end
		local status: string
		if reason == "NO USES" then
			ic.wipe.Size = UDim2.fromScale(1, 1)
			ic.secs.Text = "-"
			ic.secs.TextColor3 = InfoLayer.col("danger")
			status = "EMPTY"
		elseif frac > 0 then
			ic.wipe.Size = UDim2.fromScale(1, frac)
			ic.secs.Text = tostring(math.ceil(remaining))
			ic.secs.TextColor3 = InfoLayer.col("text")
			status = tostring(math.ceil(remaining)) .. "s"
		else
			ic.wipe.Size = UDim2.fromScale(1, 0)
			ic.secs.Text = ""
			status = "READY"
		end
		Style.glyphAlpha(ic.glyph, if available then 0 else 0.55)
		local count = ""
		if slot then
			if slot.maxCharges and slot.maxCharges > 1 then
				count = "x" .. tostring(slot.charges or 0)
			elseif def.uses then
				count = tostring(slot.uses or def.uses)
			end
		end
		ic.badge.Text = count
		if ic.row then
			ic.row.status.Text = InfoLayer.caseText(status)
			ic.row.status.TextColor3 = if available then InfoLayer.col("heal") elseif reason == "NO USES" then InfoLayer.col("danger") else InfoLayer.col("dim")
			ic.row.name.TextTransparency = if available then 0 else 0.4
		end
		if ic.ready ~= available then
			if available and ic.ready == false then
				-- off cooldown: one pop + the edge flashes
				HudSkin.bump(ic.box)
				ic.stroke.Transparency = 0
				Theme.tween(ic.stroke, 0.5, { Transparency = if InfoLayer.style() == "glass" then 0.82 else 0.35 })
			end
			ic.ready = available
		end
	end
end

function CallInList.build(parent: Instance, isTouch: boolean, order: number?)
	touch = isTouch
	newMode = InfoLayer.isNew()
	if newMode then
		ui = {}
		table.clear(rows)
		rowKey = nil
		buildNew()
		return
	end
	InfoLayer.drop("CallInStrip")
	local p = Style.panel({
		Name = "CallIns",
		Size = if isTouch then UDim2.fromOffset(112, 0) else UDim2.new(1, 0, 0, 0), -- phones: narrow icon column
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 1,
		Visible = false,
		Parent = parent,
	})
	Theme.pad(p, 6, 4, 6, 6)
	Theme.list(p, Enum.FillDirection.Vertical, 2)
	Style.label({
		Text = "UPLINK",
		TextSize = 14,
		Color = Style.Grey,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 0,
		Parent = p,
	})
	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.LayoutOrder = 1
	list.Parent = p
	Theme.list(list, Enum.FillDirection.Vertical, 2)
	ui.panel = p
	ui.list = list
end

function CallInList.setVisible(on: boolean)
	if newMode then
		nu.want = on
		if nu.holder then
			nu.holder.Visible = on and #icons > 0
		end
		return
	end
	if ui.panel then
		ui.panel.Visible = on and #rows > 0
		ui.want = on
	end
end

-- me = Store "me"; t = workspace:GetServerTimeNow()
function CallInList.update(me: any, t: number)
	if newMode then
		if nu.holder and type(me) == "table" and type(me.callins) == "table" and type(me.callins.slots) == "table" then
			updateNew(me, t)
		end
		return
	end
	if not ui.panel then
		return
	end
	if type(me) ~= "table" or type(me.callins) ~= "table" or type(me.callins.slots) ~= "table" then
		return
	end
	local slots = me.callins.slots
	local ids = {}
	for _, s in slots do
		table.insert(ids, s.id)
	end
	local key = table.concat(ids, ",")
	if key ~= rowKey then
		rowKey = key
		rebuild(me)
		ui.panel.Visible = ui.want == true and #rows > 0
	end
	for _, r in rows do
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
		local frac = 0
		if remaining > 0 and not (slot and slot.charges ~= nil and slot.charges > 0) then
			frac = Theme.clamp(remaining / math.max(def.cooldown, 1), 0, 1)
		end
		if reason == "NO USES" then
			r.wipe.Size = UDim2.fromScale(1, 1)
			r.secs.Text = "-"
			r.secs.TextColor3 = Style.Red
		elseif frac > 0 then
			r.wipe.Size = UDim2.fromScale(frac, 1)
			r.secs.Text = tostring(math.ceil(remaining)) .. "s"
			r.secs.TextColor3 = Style.White
		else
			r.wipe.Size = UDim2.fromScale(0, 1)
			r.secs.Text = ""
		end
		local dim = if available then 0 else 0.55
		r.icon.TextTransparency = dim
		r.name.TextTransparency = dim
		r.tick.TextTransparency = dim
		if slot then
			r.badge.Text = if slot.maxCharges and slot.maxCharges > 1 then ("x" .. tostring(slot.charges or 0)) else ""
			if def.uses then
				local have = slot.uses or def.uses
				if r.pipCount ~= have or r.pipMax ~= def.uses then
					for _, c in r.pips:GetChildren() do
						if c:IsA("Frame") then
							c:Destroy()
						end
					end
					for i = 1, def.uses do
						Style.rect({
							Color = if i <= have then Style.Amber else Style.Grey,
							Transparency = if i <= have then 0 else 0.55,
							Size = UDim2.fromOffset(10, 4),
							LayoutOrder = i,
							Parent = r.pips,
						})
					end
					r.pipCount, r.pipMax = have, def.uses
				end
			end
		end
		if r.ready ~= available then
			if available and r.ready == false then
				-- ready flash: the tick pops
				r.tick.TextColor3 = Style.White
				Theme.tween(r.tick, 0.4, { TextColor3 = if r.reinforce then Style.Green else Theme.beaconColor(def.beacon) })
			end
			r.ready = available
		end
	end
end

return CallInList
