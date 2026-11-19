--!nonstrict
-- New-layout health (UI STYLE skins only; the old HUD keeps HUD's own card). Bottom-left on PC, top-left on phones
-- (UI/HudLayout "health"): one skin bar (hairline: angled ends + gaps every 25 %; glass: pill; visor: ticks), the
-- ghost chunk of health just lost, stim pips to the right of it. No callsign, no hp number.
--   Vitals.build(parent, touch) -> Frame
--   Vitals.set(me)                 hp / maxHp / alive / stims / stimsMax from the Store "me" table
--   Vitals.flash(strength)         hit flash on the bar track
--   Vitals.step(dt, now)           per frame: critical heartbeat pulse, stim-heal tint, ghost drain
--   Vitals.setVisible(on)
--   Vitals.frac()                  last health fraction (crosshair satellites)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local Vitals = {}

local ui: { [string]: any } = {}
local hpFrac = 1
local ghostFrac = 1
local ghostHold = 0
local flash = 0
local alive = true
local stimEnd = 0
local pipsShown = ""

function Vitals.build(parent: Instance, touch: boolean): Frame
	table.clear(ui)
	hpFrac, ghostFrac, ghostHold, flash, pipsShown = 1, 1, 0, 0, ""
	local preset = HudLayout.preset()
	local lay = HudLayout.get("health", touch)
	local holder = Instance.new("Frame")
	holder.Name = "Vitals"
	holder.BackgroundTransparency = 1
	HudLayout.apply(holder, "health", touch)
	holder.Parent = parent
	ui.holder = holder
	ui.showChip = lay.ShowChip == true

	ui.bar = HudSkin.bar({
		Name = "Health",
		Size = UDim2.fromScale(1, 1),
		Color = HudSkin.color("text"),
		Ghost = true,
		Segments = true,
		Ticks = if touch then 20 else 36,
		Parent = holder,
	})
	if preset == "bold" or preset == "frame" then
		ui.bar.track(Color3.new(0, 0, 0), if preset == "frame" then 0.15 else 0.25)
	end
	ui.bar.set(1)
	ui.bar.ghost(1)

	-- stim pips (or compact [icon + number] chip in Clean preset) right of the bar
	local pips = Instance.new("Frame")
	pips.Name = "Stims"
	pips.BackgroundTransparency = 1
	pips.AnchorPoint = Vector2.new(0, 0.5)
	pips.Position = UDim2.new(0, lay.PipsX, 0.5, 0)
	pips.Size = UDim2.fromOffset(0, math.max(lay.PipSize, if ui.showChip then 28 else 0))
	pips.AutomaticSize = Enum.AutomaticSize.X
	pips.Parent = holder
	if ui.showChip then
		Theme.pad(pips, 8, 0, 8, 0)
		local folder = Instance.new("Folder")
		folder.Name = "BackingHost"
		folder.Parent = pips
		HudSkin.panel("chip", { Name = "Backing", Size = UDim2.fromScale(1, 1), ZIndex = 0, Parent = folder })
	end
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, lay.PipGap)
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = pips
	ui.pips = pips
	ui.pipSize = lay.PipSize
	return holder
end

local function drawPips(n: number, max: number)
	local key = n .. "/" .. max
	if key == pipsShown or not ui.pips then
		return
	end
	pipsShown = key
	for _, c in ui.pips:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local skin = HudSkin.current()
	local heal = HudSkin.color("heal")
	if ui.showChip then
		local have = n > 0
		local col = if have then heal else HudSkin.color("dim")
		Style.glyph("plus", {
			Size = math.max(10, math.floor(ui.pipSize * 0.65)),
			Color = col,
			Box = UDim2.fromOffset(ui.pipSize, ui.pipSize + 4),
			LayoutOrder = 1,
			Parent = ui.pips,
		})
		HudSkin.label({
			Text = tostring(n),
			Role = "number",
			TextSize = ui.pipSize,
			Color = col,
			Size = UDim2.fromOffset(0, ui.pipSize + 4),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			Parent = ui.pips,
		})
		return
	end
	for i = 1, max do
		local have = i <= n
		local g = Style.glyph("plus", {
			Size = ui.pipSize,
			Color = if have then heal else HudSkin.color("dim"),
			LayoutOrder = i,
			Parent = ui.pips,
		})
		if not have then
			Style.glyphAlpha(g, if skin and skin.id == "visor" then 0.6 else 0.55)
		end
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
		drawPips(stims, me.stimsMax or Config.Stims.Max)
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
	if not bar or not ui.holder.Visible then
		return
	end
	local crit = Config.Stims.Critical
	local col = HudSkin.color("text")
	if alive and hpFrac < crit then
		-- heartbeat: a strong "lub" then a softer "dub", faster the lower the health
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
	-- hit flash: the track brightens for a moment
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
