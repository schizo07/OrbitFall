--!nonstrict
-- Unified bottom-left self vitals + weapon strip:
--   Row 1: WeaponBlock slot (grenade icon/count, reserve mags, weapon name/mode, crisp round count)
--   Row 2: Slim segmented mag pip strip
--   Row 3: [Callsign] + crisp white HP bar (with ghost chunk + heartbeat + stim shimmer) + stim icon & count
--   Row 4: Hairline stamina bar (white / amber low / crimson exhausted with recovery tick / green boost)
-- API:
--   Vitals.build(parent, touch) -> Frame
--   Vitals.weaponSlot() -> Frame
--   Vitals.callsignLabel() -> TextLabel
--   Vitals.magSegs() -> { Frame }
--   Vitals.set(me)
--   Vitals.setStamina(frac, exhausted, sprinting, boosted)
--   Vitals.flash(strength)
--   Vitals.step(dt, now)
--   Vitals.setVisible(on)
--   Vitals.frac() -> number
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local Vitals = {}

local MAG_SEGS = 20

local ui: { [string]: any } = {}
local hpFrac = 1
local ghostFrac = 1
local ghostHold = 0
local flash = 0
local alive = true
local stimEnd = 0
local stimsShown = ""

function Vitals.build(parent: Instance, touch: boolean): Frame
	table.clear(ui)
	hpFrac, ghostFrac, ghostHold, flash, stimsShown = 1, 1, 0, 0, ""

	local lay = HudLayout.get("health", touch)
	local barH: number = lay.BarHeight or 9
	local stamH: number = lay.StaminaHeight or 3
	local ts: number = lay.TextSize or 14

	local holder = HudSkin.panel("plate", {
		Name = "Vitals",
		AnchorPoint = lay.AnchorPoint,
		Position = lay.Position,
		Size = UDim2.fromOffset(if touch then math.min(lay.Size.X.Offset, HudLayout.phoneBottomWidth() - 12) else lay.Size.X.Offset, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	Theme.pad(holder, if touch then 7 else 9, if touch then 5 else 6, if touch then 7 else 9, if touch then 5 else 6)
	Theme.list(holder, Enum.FillDirection.Vertical, if touch then 3 else 4)
	ui.holder = holder

	if touch then
		Theme.onScaleChanged(function()
			if holder.Parent then
				holder.Size = UDim2.fromOffset(math.min(lay.Size.X.Offset, HudLayout.phoneBottomWidth() - 12), 0)
			end
		end)
	end

	-- Row 1: WeaponBlock slot (docked cleanly at top of self strip)
	local wSlot = Instance.new("Frame")
	wSlot.Name = "WeaponSlot"
	wSlot.BackgroundTransparency = 1
	wSlot.Size = UDim2.new(1, 0, 0, if touch then 20 else 24)
	wSlot.LayoutOrder = 1
	wSlot.Parent = holder
	ui.weaponSlot = wSlot

	-- Row 2: Slim segmented mag pip bar
	local segsHost = Instance.new("Frame")
	segsHost.Name = "MagBar"
	segsHost.BackgroundTransparency = 1
	segsHost.Size = UDim2.new(1, 0, 0, 3)
	segsHost.LayoutOrder = 2
	segsHost.Parent = holder
	Theme.list(segsHost, Enum.FillDirection.Horizontal, 1)
	ui.magSegs = {}
	for i = 1, MAG_SEGS do
		local s = Style.rect({
			Color = HudSkin.color("text"),
			Transparency = 0.82,
			Size = UDim2.new(1 / MAG_SEGS, -1, 1, 0),
			LayoutOrder = i,
			Parent = segsHost,
		})
		ui.magSegs[i] = s
	end

	-- Row 3: Callsign badge + crisp white HP bar + stim icon/count
	local rowH = if touch then 18 else 20
	local hpRow = Instance.new("Frame")
	hpRow.Name = "HpRow"
	hpRow.BackgroundTransparency = 1
	hpRow.Size = UDim2.new(1, 0, 0, rowH)
	hpRow.LayoutOrder = 3
	hpRow.Parent = holder

	local tagW = if touch then 24 else 28
	local tagBox = Instance.new("Frame")
	tagBox.Name = "CallsignBox"
	tagBox.BackgroundColor3 = Color3.new(0, 0, 0)
	tagBox.BackgroundTransparency = 0.55
	tagBox.BorderSizePixel = 0
	tagBox.AnchorPoint = Vector2.new(0, 0.5)
	tagBox.Position = UDim2.fromScale(0, 0.5)
	tagBox.Size = UDim2.fromOffset(tagW, rowH - 2)
	tagBox.Parent = hpRow
	local tagStroke = Instance.new("UIStroke")
	tagStroke.Color = HudSkin.color("own")
	tagStroke.Thickness = 1
	tagStroke.Transparency = 0.25
	tagStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	tagStroke.Parent = tagBox
	ui.callsignStroke = tagStroke

	ui.callsign = HudSkin.label({
		Name = "Callsign",
		Text = "S1",
		Role = "number",
		TextSize = if touch then 11 else 13,
		ColorRole = "own",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = tagBox,
	})
	ui.callsign:GetPropertyChangedSignal("TextColor3"):Connect(function()
		if ui.callsignStroke then
			ui.callsignStroke.Color = ui.callsign.TextColor3
		end
	end)

	local stimW = if touch then 46 else 56
	local barLeft = tagW + 8
	local barRight = stimW + 8

	ui.bar = HudSkin.bar({
		Name = "Health",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, barLeft, 0.5, 0),
		Size = UDim2.new(1, -(barLeft + barRight), 0, barH),
		Color = HudSkin.color("text"),
		Ghost = true,
		Brackets = true,
		Parent = hpRow,
	})
	ui.bar.track(Color3.new(0, 0, 0), 0.5)
	ui.bar.set(1)
	ui.bar.ghost(1)

	-- Stim icon + count on right of HP bar
	local stimBox = Instance.new("Frame")
	stimBox.Name = "Stims"
	stimBox.BackgroundTransparency = 1
	stimBox.AnchorPoint = Vector2.new(1, 0.5)
	stimBox.Position = UDim2.fromScale(1, 0.5)
	stimBox.Size = UDim2.fromOffset(stimW, rowH)
	stimBox.Parent = hpRow
	Theme.list(stimBox, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)

	ui.stimIcon = Style.glyph("plus", {
		Size = if touch then 9 else 11,
		Color = HudSkin.color("heal"),
		Box = UDim2.fromOffset(12, rowH),
		LayoutOrder = 1,
		Parent = stimBox,
	})
	ui.stimText = HudSkin.label({
		Text = "0/4",
		Role = "number",
		TextSize = ts - 1,
		ColorRole = "heal",
		XAlign = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(0, rowH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = stimBox,
	})

	-- Row 4: Hairline stamina bar aligned with the HP bar
	local stamRow = Instance.new("Frame")
	stamRow.Name = "StaminaRow"
	stamRow.BackgroundTransparency = 1
	stamRow.Size = UDim2.new(1, 0, 0, stamH + 2)
	stamRow.LayoutOrder = 4
	stamRow.Parent = holder

	local stamTrack = Style.rect({
		Name = "StaminaTrack",
		Color = Color3.new(0, 0, 0),
		Transparency = 0.55,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, barLeft, 0.5, 0),
		Size = UDim2.new(1, -(barLeft + barRight), 0, stamH),
		ClipsDescendants = true,
		Parent = stamRow,
	})
	ui.stamFill = Style.rect({
		Name = "Fill",
		Color = HudSkin.color("text"),
		Transparency = 0.15,
		Size = UDim2.fromScale(1, 1),
		Parent = stamTrack,
	})
	ui.stamTick = Style.rect({
		Name = "Recover",
		Color = HudSkin.color("own"),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(Config.Move.RecoverAt, 0.5),
		Size = UDim2.fromOffset(1, stamH + 2),
		Visible = false,
		ZIndex = 3,
		Parent = stamTrack,
	})

	return holder
end

function Vitals.weaponSlot(): Frame?
	return ui.weaponSlot
end

function Vitals.callsignLabel(): TextLabel?
	return ui.callsign
end

function Vitals.magSegs(): { Frame }?
	return ui.magSegs
end

function Vitals.setStamina(v: number, exhausted: boolean, _sprinting: boolean, boosted: boolean)
	local fill = ui.stamFill
	if not fill or not fill.Parent then
		return
	end
	local f = Theme.clamp(v, 0, 1)
	fill.Size = UDim2.fromScale(f, 1)
	local col = HudSkin.color("text")
	if exhausted then
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
		col = HudSkin.color("danger"):Lerp(HudSkin.color("own"), pulse * 0.5)
	elseif f < Config.Move.RecoverAt then
		col = HudSkin.color("own")
	end
	if boosted then
		col = HudSkin.color("text"):Lerp(HudSkin.color("heal"), 0.55 + 0.15 * math.sin(os.clock() * 6))
	end
	fill.BackgroundColor3 = col
	fill.BackgroundTransparency = if f >= 0.999 and not boosted then 0.55 else 0.05
	if ui.stamTick then
		ui.stamTick.Visible = exhausted
	end
end

function Vitals.set(me: any)
	if not ui.bar or type(me) ~= "table" then
		return
	end
	local hp, maxHp = me.hp or 0, math.max(me.maxHp or Config.PlayerHealth, 1)
	local frac = Theme.clamp(hp / maxHp, 0, 1)
	alive = me.alive ~= false
	stimEnd = me.stimEnd or 0
	if frac < hpFrac - 0.001 then
		ghostFrac = math.max(ghostFrac, hpFrac)
		ghostHold = os.clock() + 0.45
		flash = math.max(flash, math.min(1, (hpFrac - frac) * 3 + 0.3))
	end
	hpFrac = frac
	if ghostFrac < frac then
		ghostFrac = frac
	end
	local stims = me.stims
	if type(stims) == "number" then
		local maxS = me.stimsMax or Config.Stims.Max
		local key = stims .. "/" .. maxS
		if key ~= stimsShown and ui.stimText then
			stimsShown = key
			ui.stimText.Text = key
			local col = if stims <= 0 then HudSkin.color("danger") else HudSkin.color("heal")
			ui.stimText.TextColor3 = col
			Style.tint(ui.stimIcon, col)
		end
	end
end

function Vitals.flash(strength: number?)
	flash = math.max(flash, strength or 0.6)
end

function Vitals.frac(): number
	return hpFrac
end

function Vitals.step(dt: number, now: number)
	local bar = ui.bar
	if not bar or not ui.holder or not ui.holder.Visible then
		return
	end
	local crit = Config.Stims.Critical
	local col = HudSkin.color("text")
	if alive and hpFrac < crit then
		local beat = (os.clock() * (1.1 + (crit - hpFrac) / crit * 1.2)) % 1
		local pulse = math.max(math.exp(-((beat - 0.08) / 0.07) ^ 2), 0.65 * math.exp(-((beat - 0.32) / 0.08) ^ 2))
		col = HudSkin.color("danger"):Lerp(Color3.fromRGB(255, 140, 130), pulse * 0.6)
	end
	if alive and stimEnd > now then
		col = col:Lerp(HudSkin.color("heal"), 0.55 + 0.25 * math.sin(os.clock() * 14))
	end
	if os.clock() >= ghostHold and ghostFrac > hpFrac then
		ghostFrac = math.max(hpFrac, ghostFrac - dt * 0.9 - (ghostFrac - hpFrac) * (1 - math.exp(-6 * dt)))
	end
	bar.set(hpFrac, col)
	bar.ghost(ghostFrac)
	if flash > 0 then
		flash = math.max(0, flash - dt * 2.5)
		bar.track(Color3.new(0, 0, 0):Lerp(Color3.new(1, 1, 1), 0.5 * flash), 0.5 - 0.3 * flash)
	end
end

function Vitals.setVisible(on: boolean)
	if ui.holder then
		ui.holder.Visible = on
	end
end

return Vitals
