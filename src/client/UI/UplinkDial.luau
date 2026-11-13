-- The Uplink Dial: radial call-in picker with a sync needle (docs/spec.md §3.2).
--   open()                 show the dial (hold Q / hold UPLINK)
--   setPointer(Vector2?)   direction from the dial centre (screen space, +y down); nil / tiny = centre = cancel
--   close() -> (slotIndex: number | "REINFORCE" | nil, perfect: boolean)
--   isOpen() -> boolean
-- Reads Store "me" (callins.slots, reinforceReadyAt).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local CallIns = require(Shared:WaitForChild("Data"):WaitForChild("CallIns"))
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)

local C = Theme.C

local UplinkDial = {}

local SEGMENTS = 5
local SEG_ANGLE = 360 / SEGMENTS
local SWEEP_PERIOD = 0.9 -- seconds per needle revolution
local PERFECT_HALF = SEG_ANGLE / 2 -- needle inside the highlighted segment = perfect sync
local DEAD_ZONE = 0.2

local TICKS_PER_SEG = 12
local OUTER_R = 0.455
local INNER_R = 0.205
local CHIP_R = 0.325
local TRAIL = 7

local COL_NORMAL = Color3.fromHex("3a4a72")
local COL_DISABLED = Color3.fromHex("262c38")

local built = false
local gui: ScreenGui
local dim: Frame
local dial: Frame
local dialScale: UIScale
local needleParts: { Frame } = {}
local outerTicks: { { Frame } } = {}
local innerTicks: { { Frame } } = {}
local chips: { any } = {}
local hubShip: TextLabel
local hubName: TextLabel
local hubState: TextLabel
local hubDesc: TextLabel

local isOpenFlag = false
local openedAt = 0
local pointer: Vector2? = nil
local selected: number? = nil
local needleAngle = 0
local conn: RBXScriptConnection? = nil
local token = 0

local function wrap180(a: number): number
	return (a + 180) % 360 - 180
end

local function polar(radius: number, deg: number): UDim2
	local r = math.rad(deg)
	return UDim2.fromScale(0.5 + radius * math.sin(r), 0.5 - radius * math.cos(r))
end

local function sizeConstraint(label: TextLabel, maxSize: number)
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = maxSize
	c.MinTextSize = 6
	c.Parent = label
end

local function build()
	if built then
		return
	end
	built = true
	local touch = Theme.isTouch()
	gui = Theme.gui("OrbitUplink", { DisplayOrder = 70, Insets = "None", Enabled = false })

	dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = C.Dark
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Active = false
	dim.Parent = gui

	dial = Instance.new("Frame")
	dial.Name = "Dial"
	dial.BackgroundTransparency = 1
	dial.AnchorPoint = Vector2.new(0.5, 0.5)
	dial.Position = UDim2.fromScale(0.5, 0.5)
	dial.SizeConstraint = Enum.SizeConstraint.RelativeYY
	dial.Size = UDim2.fromScale(touch and 0.9 or 0.8, touch and 0.9 or 0.8)
	dial.Parent = gui
	dialScale = Instance.new("UIScale")
	dialScale.Parent = dial

	-- decorative circles
	local function circle(size: number, color: Color3, thickness: number, transparency: number)
		local f = Instance.new("Frame")
		f.BackgroundTransparency = 1
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromScale(size, size)
		f.Parent = dial
		Theme.corner(f, 9999)
		Theme.stroke(f, color, thickness, transparency)
		return f
	end
	local backdrop = circle(0.99, C.Accent, 2, 0.55)
	backdrop.BackgroundTransparency = 0.25
	backdrop.BackgroundColor3 = C.Navy
	circle(0.36, C.Accent, 2, 0.7)

	-- tick rings
	for i = 1, SEGMENTS do
		outerTicks[i] = {}
		innerTicks[i] = {}
		local centre = (i - 1) * SEG_ANGLE
		for k = 1, TICKS_PER_SEG do
			local a = centre - SEG_ANGLE / 2 + SEG_ANGLE * (k - 0.5) / TICKS_PER_SEG
			local t = Instance.new("Frame")
			t.AnchorPoint = Vector2.new(0.5, 0.5)
			t.Position = polar(OUTER_R, a)
			t.Rotation = a
			t.Size = UDim2.fromScale(0.02, 0.065)
			t.BackgroundColor3 = COL_NORMAL
			t.BorderSizePixel = 0
			t.Parent = dial
			outerTicks[i][k] = t
			if k % 2 == 1 then
				local u = Instance.new("Frame")
				u.AnchorPoint = Vector2.new(0.5, 0.5)
				u.Position = polar(INNER_R, a)
				u.Rotation = a
				u.Size = UDim2.fromScale(0.014, 0.03)
				u.BackgroundColor3 = COL_NORMAL
				u.BorderSizePixel = 0
				u.Parent = dial
				table.insert(innerTicks[i], u)
			end
		end
		-- divider at the segment boundary
		local b = centre + SEG_ANGLE / 2
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = polar(OUTER_R, b)
		d.Rotation = b
		d.Size = UDim2.fromScale(0.012, 0.1)
		d.BackgroundColor3 = C.Accent
		d.BorderSizePixel = 0
		d.Parent = dial
	end

	-- sync needle (full-size containers rotate around the dial centre)
	for i = 1, TRAIL do
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Position = UDim2.fromScale(0.5, 0.5)
		holder.Size = UDim2.fromScale(1, 1)
		holder.ZIndex = 8 - i
		holder.Parent = dial
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.185)
		bar.Size = UDim2.fromScale(i == 1 and 0.016 or 0.012, 0.37)
		bar.BackgroundColor3 = C.Friendly
		bar.BackgroundTransparency = i == 1 and 0 or (0.3 + i * 0.1)
		bar.BorderSizePixel = 0
		bar.Parent = holder
		table.insert(needleParts, holder)
	end

	-- chips
	for i = 1, SEGMENTS do
		local ang = (i - 1) * SEG_ANGLE
		local chip = Theme.panel({
			Name = "Chip" .. i,
			Color = C.Navy,
			Corner = 12,
			Stroke = i == SEGMENTS and C.Friendly or C.Accent,
			StrokeThickness = 2,
			StrokeTransparency = 0.35,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = polar(CHIP_R, ang),
			Size = UDim2.fromScale(0.175, 0.175),
			ZIndex = 10,
			Parent = dial,
		})
		local cscale = Instance.new("UIScale")
		cscale.Parent = chip
		local inner = Instance.new("Frame")
		inner.BackgroundTransparency = 1
		inner.Size = UDim2.fromScale(1, 1)
		inner.ClipsDescendants = true
		inner.ZIndex = 10
		inner.Parent = chip
		Theme.corner(inner, 12)
		local glyph = Theme.label({
			Text = "",
			Font = "Black",
			TextScaled = true,
			Size = UDim2.fromScale(0.7, 0.45),
			Position = UDim2.fromScale(0.15, 0.1),
			ZIndex = 11,
			Parent = inner,
		})
		sizeConstraint(glyph, 34)
		local name = Theme.label({
			Text = "",
			Font = "Black",
			TextScaled = true,
			Size = UDim2.fromScale(0.94, 0.2),
			Position = UDim2.fromScale(0.03, 0.6),
			ZIndex = 11,
			Parent = inner,
		})
		sizeConstraint(name, 13)
		local badge = Theme.label({
			Text = "",
			Font = "Black",
			TextScaled = true,
			Color = C.Gold,
			XAlign = Enum.TextXAlignment.Right,
			Size = UDim2.fromScale(0.5, 0.2),
			Position = UDim2.fromScale(0.46, 0.02),
			ZIndex = 12,
			Parent = inner,
		})
		sizeConstraint(badge, 13)
		local sub = Theme.label({
			Text = "",
			Font = "Black",
			TextScaled = true,
			Color = C.Muted,
			Size = UDim2.fromScale(0.94, 0.16),
			Position = UDim2.fromScale(0.03, 0.82),
			ZIndex = 11,
			Parent = inner,
		})
		sizeConstraint(sub, 11)
		local cd = Instance.new("Frame")
		cd.BackgroundColor3 = C.Dark
		cd.BackgroundTransparency = 0.2
		cd.BorderSizePixel = 0
		cd.AnchorPoint = Vector2.new(0, 1)
		cd.Position = UDim2.fromScale(0, 1)
		cd.Size = UDim2.fromScale(1, 0)
		cd.ZIndex = 13
		cd.Parent = inner
		local cdText = Theme.label({
			Text = "",
			Font = "Black",
			TextScaled = true,
			Size = UDim2.fromScale(0.7, 0.35),
			Position = UDim2.fromScale(0.15, 0.3),
			ZIndex = 14,
			Parent = inner,
		})
		sizeConstraint(cdText, 26)
		chips[i] = {
			frame = chip, scale = cscale, glyph = glyph, name = name, badge = badge, sub = sub, cd = cd, cdText = cdText,
			stroke = chip:FindFirstChildOfClass("UIStroke"), available = false, defName = "", desc = "", status = "",
		}
	end

	-- hub
	local hub = Theme.panel({
		Name = "Hub",
		Color = C.Dark,
		Corner = 9999,
		Stroke = C.Accent,
		StrokeTransparency = 0.3,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.3, 0.3),
		ZIndex = 12,
		Parent = dial,
	})
	hubShip = Theme.label({
		Text = string.upper(Config.ShipName),
		Font = "Header",
		TextScaled = true,
		Color = C.Accent,
		Size = UDim2.fromScale(0.7, 0.11),
		Position = UDim2.fromScale(0.15, 0.17),
		ZIndex = 13,
		Parent = hub,
	})
	sizeConstraint(hubShip, 12)
	hubName = Theme.label({
		Text = "UPLINK",
		Font = "Black",
		TextScaled = true,
		Size = UDim2.fromScale(0.74, 0.2),
		Position = UDim2.fromScale(0.13, 0.31),
		ZIndex = 13,
		Parent = hub,
	})
	sizeConstraint(hubName, 22)
	hubState = Theme.label({
		Text = "DRAG TO CHOOSE",
		Font = "Header",
		TextScaled = true,
		Color = C.Muted,
		Size = UDim2.fromScale(0.74, 0.1),
		Position = UDim2.fromScale(0.13, 0.54),
		ZIndex = 13,
		Parent = hub,
	})
	sizeConstraint(hubState, 12)
	hubDesc = Theme.label({
		Text = "Release in the centre to cancel",
		Font = "Medium",
		TextScaled = true,
		Color = C.Muted,
		Wrap = true,
		Size = UDim2.fromScale(0.72, 0.16),
		Position = UDim2.fromScale(0.14, 0.66),
		ZIndex = 13,
		Parent = hub,
	})
	sizeConstraint(hubDesc, 11)
end

local function segmentFor(dir: Vector2): number
	local ang = math.deg(math.atan2(dir.X, -dir.Y)) -- 0 = up, clockwise
	local idx = math.floor(((ang + SEG_ANGLE / 2) % 360) / SEG_ANGLE) + 1
	return math.clamp(idx, 1, SEGMENTS)
end

-- Per-chip availability + visuals ------------------------------------------------------------------------------------
local function refreshChips(t: number)
	local me = Store.get("me")
	local slots = me and me.callins and me.callins.slots or {}
	for i = 1, SEGMENTS do
		local ch = chips[i]
		local def, available, remaining, status, badge, sub
		local slot
		if i == SEGMENTS then
			def = CallIns.get("REINFORCE")
			remaining = math.max(0, ((me and me.reinforceReadyAt) or 0) - t)
			available = remaining <= 0
			status = available and "READY" or "COOLDOWN"
			badge = ""
			sub = "SQUAD"
		else
			slot = slots[i]
			if slot then
				def = CallIns.get(slot.id)
			end
			if slot and def then
				available, remaining, status = Theme.slotStatus(slot, def, t)
				if def.uses then
					badge = "x" .. tostring(slot.uses or def.uses)
				elseif slot.maxCharges and slot.maxCharges > 1 then
					badge = "x" .. tostring(slot.charges or 0)
				else
					badge = ""
				end
				sub = string.upper(def.category)
			else
				available, remaining, status, badge, sub = false, 0, "EMPTY", "", ""
			end
		end
		ch.available = available
		ch.status = status
		ch.defName = def and string.upper(def.name) or "EMPTY SLOT"
		ch.desc = def and def.desc or ""
		ch.def = def
		ch.remaining = remaining
		ch.glyph.Text = def and def.icon or "-"
		ch.name.Text = def and Theme.callinShort(def) or "EMPTY"
		ch.badge.Text = badge
		ch.sub.Text = sub
		ch.glyph.TextTransparency = available and 0 or 0.6
		local frac = 0
		if def and remaining > 0 and not (slot and slot.charges ~= nil and slot.charges > 0) then
			frac = Theme.clamp(remaining / math.max(def.cooldown, 1), 0, 1)
		end
		if status == "NO USES" or status == "EMPTY" then
			frac = 1
		end
		ch.cd.Size = UDim2.fromScale(1, frac)
		ch.cdText.Text = (remaining > 0 and frac > 0 and status == "COOLDOWN") and tostring(math.ceil(remaining)) or (status == "NO USES" and "0" or "")
		ch.cdText.TextColor3 = status == "NO USES" and C.Danger or C.Text
		local beacon = def and Theme.beaconColor(def.beacon) or C.Muted
		ch.beacon = i == SEGMENTS and C.Friendly or beacon
	end
end

local function paintSegments(inside: boolean)
	for i = 1, SEGMENTS do
		local ch = chips[i]
		local col = COL_NORMAL
		if not ch.available then
			col = COL_DISABLED
		end
		local isSel = selected == i
		if isSel then
			col = ch.available and (inside and C.Gold or C.Accent) or C.Danger
		end
		for _, tck in outerTicks[i] do
			tck.BackgroundColor3 = col
			tck.BackgroundTransparency = isSel and 0 or 0.1
		end
		for _, tck in innerTicks[i] do
			tck.BackgroundColor3 = col
			tck.BackgroundTransparency = isSel and 0 or 0.35
		end
		local target = isSel and 1.14 or 1
		if math.abs(ch.scale.Scale - target) > 0.01 then
			Theme.tween(ch.scale, 0.1, { Scale = target })
		end
		ch.stroke.Color = isSel and (ch.available and C.Gold or C.Danger) or ch.beacon or C.Accent
		ch.stroke.Transparency = isSel and 0 or 0.4
		ch.stroke.Thickness = isSel and 3 or 2
	end
end

local function updateHub(inside: boolean)
	if selected then
		local ch = chips[selected]
		hubName.Text = ch.defName
		hubName.TextColor3 = ch.available and C.Text or C.Muted
		if ch.status == "READY" then
			hubState.Text = inside and "PERFECT SYNC" or "RELEASE ON NEEDLE"
			hubState.TextColor3 = inside and C.Gold or C.Friendly
		elseif ch.status == "COOLDOWN" then
			hubState.Text = string.format("COOLDOWN %ds", math.ceil(ch.remaining or 0))
			hubState.TextColor3 = C.Danger
		else
			hubState.Text = ch.status
			hubState.TextColor3 = C.Danger
		end
		hubDesc.Text = ch.desc
	else
		hubName.Text = "UPLINK"
		hubName.TextColor3 = C.Text
		hubState.Text = Theme.isTouch() and "DRAG TO CHOOSE" or "MOVE MOUSE TO CHOOSE"
		hubState.TextColor3 = C.Muted
		hubDesc.Text = "Release in the centre to cancel"
	end
end

local lastSel: number? = nil
local function step()
	local t = workspace:GetServerTimeNow()
	local el = os.clock() - openedAt
	needleAngle = (el * 360 / SWEEP_PERIOD) % 360
	for i, holder in needleParts do
		holder.Rotation = needleAngle - (i - 1) * 4.5
	end
	-- selection
	local sel: number? = nil
	if pointer then
		sel = segmentFor(pointer)
	end
	selected = sel
	if sel ~= lastSel then
		lastSel = sel
		if sel then
			Theme.sfx("DialTick")
		end
	end
	refreshChips(t)
	local inside = false
	if sel then
		inside = math.abs(wrap180(needleAngle - (sel - 1) * SEG_ANGLE)) <= PERFECT_HALF
	end
	local nb = needleParts[1]:FindFirstChildOfClass("Frame")
	if nb then
		nb.BackgroundColor3 = inside and C.Gold or C.Friendly
	end
	paintSegments(inside)
	updateHub(inside)
end

-- Public API ----------------------------------------------------------------------------------------------------------------------
function UplinkDial.init()
	build()
end

function UplinkDial.isOpen(): boolean
	return isOpenFlag
end

function UplinkDial.setPointer(v: Vector2?)
	if v == nil or v.Magnitude < DEAD_ZONE then
		pointer = nil
	else
		pointer = v.Unit
	end
end

function UplinkDial.open()
	if isOpenFlag then
		return
	end
	build()
	isOpenFlag = true
	token += 1
	openedAt = os.clock()
	pointer = nil
	selected = nil
	lastSel = nil
	gui.Enabled = true
	dialScale.Scale = 0.8
	dim.BackgroundTransparency = 1
	Theme.tween(dialScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
	Theme.tween(dim, 0.2, { BackgroundTransparency = 0.55 })
	Theme.sfx("DialOpen")
	if conn then
		conn:Disconnect()
	end
	step()
	conn = RunService.RenderStepped:Connect(step)
end

function UplinkDial.close(): (any, boolean)
	if not isOpenFlag then
		return nil, false
	end
	isOpenFlag = false
	if conn then
		conn:Disconnect()
		conn = nil
	end
	step() -- final evaluation at the exact release moment (also sets needle state)
	local idx = selected
	local ch = idx and chips[idx]
	local perfect = false
	local result: any = nil
	if idx and ch then
		perfect = math.abs(wrap180(needleAngle - (idx - 1) * SEG_ANGLE)) <= PERFECT_HALF
		if ch.available then
			result = idx == SEGMENTS and "REINFORCE" or idx
		else
			result = nil
			perfect = false
			Theme.sfx("UIError")
			local ok, HUD = pcall(function()
				return require(script.Parent.HUD)
			end)
			if ok and HUD and HUD.toast then
				local why = ch.status == "COOLDOWN" and string.format("%s on cooldown (%ds)", ch.defName, math.ceil(ch.remaining or 0))
					or (ch.status == "NO USES" and (ch.defName .. ": no uses left") or "Nothing in that slot")
				HUD.toast(why, C.Danger)
			end
		end
	end
	-- exit animation
	local my = token
	if result ~= nil then
		Theme.sfx(perfect and "DialPerfect" or "DialSelect")
		if perfect then
			for i = 1, SEGMENTS do
				if i == idx then
					for _, tck in outerTicks[i] do
						tck.BackgroundColor3 = C.Gold
					end
				end
			end
			Theme.tween(dialScale, 0.2, { Scale = 1.18 })
		else
			Theme.tween(dialScale, 0.16, { Scale = 1.06 })
		end
	else
		Theme.tween(dialScale, 0.14, { Scale = 0.85 })
	end
	Theme.tween(dim, 0.18, { BackgroundTransparency = 1 })
	task.delay(perfect and 0.22 or 0.18, function()
		if token == my and not isOpenFlag then
			gui.Enabled = false
		end
	end)
	pointer = nil
	return result, perfect
end

return UplinkDial
