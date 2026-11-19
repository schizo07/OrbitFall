-- All in-mission and ship HUD. Call HUD.init() once after Store/Input exist.
-- Store keys read: me, mission, objectives, squad, profile, holding, menuOpen (all optional).
-- Thin edge HUD (style kit: UI/HudStyle). Widgets:
--   top-left   UI/CallInList (UPLINK list, icons only on touch) (+ ship info on the ship)  reads me.callins, me.reinforceReadyAt
--   top-centre UI/Compass tape (+ markers) and UI/AlertBar stack (breach / notices)    reads camera, objectives, beacons, intensity
--   top-right  UI/TopRight timer + reinforce tokens + resource chips                   reads mission.endsAt / lives, objectives, kills
--   right      UI/ObjectiveList checklist (y 16 %), UI/PickupToast (y 55 %; touch: centre y 30 %) reads objectives; Notify pickup texts
--   left       UI/SquadCards (y 58-78 %), one card per other squad member              reads squad, me.reinforceReadyAt, mission.lives
--   bottom-left own card built here (weapon, mag segments, stim/grenade/mag counts, callsign + health)   reads me
--                health bar: long, ghost chunk for recent damage, red + pulsing under Config.Stims.Critical, green tint
--                while a stim heals; spare ammo amber when <= 1 magazine; "TAP [R] TO RELOAD" via UI/ContextPrompt
--                (screen-edge damage effects: client/Fx/VitalsFx)
--                + UI/SquadComms tiny radio line above it                               reads me, Fx Breach / HeavyContact / Beacon
--   bottom-right UI/EventFeed (5 lines, 8 s): DIED, streaks, objectives, call-in arrivals, chatter   reads Notify, Fx Death, objectives
--   bottom-centre UI/StaminaBar (inited by Movement)
-- On touch everything in the main gui is drawn at 0.8 x (Style.content); the event feed + resource summary sit behind a FEED button.
-- The above is the old HUD (UI STYLE D). Skins A-C (UI/HudSkin, Feel_UiStyle) build buildMainNew instead: positions from
-- UI/HudLayout, health in UI/Vitals, ammo in UI/WeaponBlock, crosshair satellites (CROSSHAIR INFO); HUD.rebuild() switches live.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Damage = require(Shared:WaitForChild("Damage"))
local Weapons = require(Shared:WaitForChild("Data"):WaitForChild("Weapons"))
local CallIns = require(Shared:WaitForChild("Data"):WaitForChild("CallIns"))
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local AlertBar = require(script.Parent.AlertBar)
local Compass = require(script.Parent.Compass)
local ObjectiveList = require(script.Parent.ObjectiveList)
local TopRight = require(script.Parent.TopRight)
local CallInList = require(script.Parent.CallInList)
local AreaInfo = require(script.Parent.AreaInfo)
local SquadCards = require(script.Parent.SquadCards)
local EventFeed = require(script.Parent.EventFeed)
local PickupToast = require(script.Parent.PickupToast)
local SquadComms = require(script.Parent.SquadComms)
local ContextPrompt = require(script.Parent.ContextPrompt)
local SquadTags = require(script.Parent.SquadTags) -- world squad tags + comms / ship feed lines
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)
local Vitals = require(script.Parent.Vitals)
local WeaponBlock = require(script.Parent.WeaponBlock)

local C = Theme.C
local player = Players.LocalPlayer

local HUD = {}

local inited = false
local touch = false
local ui: { [string]: any } = {}
-- UI STYLE (Studio A/B, Feel_UiStyle, UI/HudSkin): true while the main HUD is built in the new layout (skins A-C).
-- Option D ("old") builds exactly the old HUD. HUD.rebuild() switches live.
local newLayout = false
local overlayKeys: { [string]: boolean } = {} -- ui keys of the overlay gui (HUD.rebuild keeps them)

-- Studio A/B "PHONE HUD" (Feel_PhoneHud): nil = phone placements that keep the crosshair-layer widgets off the touch
-- buttons and the alert bar; "old" = the previous phone placements. PC never changes.
local function phoneNew(): boolean
	return touch and workspace:GetAttribute("Feel_PhoneHud") ~= "old"
end

-- state caches
local state = "Ship"
local prevState: string? = nil
local spreadDeg = 1
local gap = 8
local gapShown = -1 -- last gap written to the crosshair ticks
local segLit, segCol, segTable: any = -1, nil, nil -- last magazine-segment state written (step)
local reloadProgress: number? = nil
local flash = 0
local hitKick = 0 -- crosshair ticks fly outward on a hit and spring back (px)
local ammoLow = false -- magazine <= 25 %: the number pulses red (step)
local ammoLastId: string? = nil
local ammoLastMag = 0
local ammoFill: { from: number, to: number, t0: number }? = nil -- quick count-up after a reload
local lastHp: number? = nil
-- health bar: ghost chunk (recent damage) holds, then drains to the real value
local hpFrac = 1
local ghostFrac = 1
local ghostHold = 0 -- os.clock until the ghost starts draining
local ghostShown = -1
local markers: { [string]: any } = {}
local beacons: { [string]: { pos: Vector3, color: Color3, label: string } } = {}
local resultsShown: any = nil
local resultsToken = 0
local hmPool: { any } = {}
local hmIndex = 1
local countdownLast = -1
local altAcc = 0

local COMBAT = { Active = true, Extract = true }

-- barrel reticle (HUD.setBarrelReticle, fed every frame by WeaponController)
local BARREL_D = 46 -- circle diameter at zero spread (px)
local BARREL_BLOCKED = Color3.fromRGB(255, 112, 52)
local barrelTarget: Vector2? = nil
local barrelBlocked = false
local barrelCallT = -100
local barrelPos: Vector2? = nil
local barrelWarn = 0 -- 0 white .. 1 blocked colour (eased)
-- last values written to the ring (stepBarrel skips unchanged writes); reset when the ring is rebuilt
local barrelShownRing: Instance? = nil
local barrelShownPos: Vector2? = nil
local barrelShownD = -1
local barrelShownWarn = -1
local barrelShownStroke: Instance? = nil

local function missionState(): string
	local m = Store.get("mission")
	return m and m.state or "Ship"
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function tw(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	return Theme.tween(inst, t, props, style, dir)
end

-- Crosshair / hitmarkers / reload / beacon prompt ---------------------------------------------------------------
local function buildCrosshair()
	local gui = Theme.gui("OrbitCrosshair", { DisplayOrder = 12, Insets = "None" })
	ui.crossGui = gui

	local markerLayer = Instance.new("Frame")
	markerLayer.Name = "Markers"
	markerLayer.BackgroundTransparency = 1
	markerLayer.Size = UDim2.fromScale(1, 1)
	markerLayer.Parent = gui
	ui.markerLayer = markerLayer

	local cross = Instance.new("Frame")
	cross.Name = "Crosshair"
	cross.BackgroundTransparency = 1
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromOffset(0, 0)
	cross.Parent = gui
	ui.cross = cross

	ui.ticks = {}
	local defs = {
		{ dir = Vector2.new(0, -1), size = Vector2.new(3, 11) },
		{ dir = Vector2.new(0, 1), size = Vector2.new(3, 11) },
		{ dir = Vector2.new(-1, 0), size = Vector2.new(11, 3) },
		{ dir = Vector2.new(1, 0), size = Vector2.new(11, 3) },
	}
	for i, d in defs do
		local f = Instance.new("Frame")
		f.Name = "Tick" .. i
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundColor3 = C.White
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(d.size.X, d.size.Y)
		f.Parent = cross
		Theme.stroke(f, C.Black, 1, 0.1)
		ui.ticks[i] = { frame = f, dir = d.dir, half = (d.dir.X ~= 0 and d.size.X or d.size.Y) / 2 }
	end
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Size = UDim2.fromOffset(4, 4)
	dot.BackgroundColor3 = C.Accent
	dot.BorderSizePixel = 0
	dot.Parent = cross
	Theme.corner(dot, 2)
	Theme.stroke(dot, C.Black, 1, 0.1)
	ui.dot = dot

	-- barrel reticle (HUD.setBarrelReticle): bigger circle where the gun barrel really hits, white / orange when blocked.
	-- Lives on the gui (not in `cross`, which sits at the screen centre). The gui ignores the GUI inset, so the pixel
	-- positions of Camera:WorldToViewportPoint apply as they are.
	local barrel = Instance.new("Frame")
	barrel.Name = "BarrelReticle"
	barrel.BackgroundTransparency = 1
	barrel.AnchorPoint = Vector2.new(0.5, 0.5)
	barrel.Size = UDim2.fromOffset(BARREL_D, BARREL_D)
	barrel.Visible = false
	barrel.ZIndex = 2
	barrel.Parent = gui
	Theme.corner(barrel, 100)
	local bst = Instance.new("UIStroke")
	bst.Color = C.White
	bst.Thickness = 2
	bst.Transparency = 0.15
	bst.Parent = barrel
	local outline = Instance.new("Frame")
	outline.Name = "Outline"
	outline.BackgroundTransparency = 1
	outline.AnchorPoint = Vector2.new(0.5, 0.5)
	outline.Position = UDim2.fromScale(0.5, 0.5)
	outline.Size = UDim2.new(1, 4, 1, 4)
	outline.Parent = barrel
	Theme.corner(outline, 100)
	local ost = Instance.new("UIStroke")
	ost.Color = C.Black
	ost.Thickness = 1
	ost.Transparency = 0.55
	ost.Parent = outline
	ui.barrel = barrel
	ui.barrelStroke = bst
	-- phones: the ring is raw px, so on a 380 px tall screen it is ~3x larger relative to the screen than at 1080p;
	-- placePhone() sets this to 0.7 there (also scales the UIStroke; AnchorPoint 0.5 keeps the centre)
	local bscale = Instance.new("UIScale")
	bscale.Parent = barrel
	ui.barrelScale = bscale

	-- hitmarker pool (pen = crisp X, partial = reduced amber X + hollow diamond, deflect = shield diamond + slash + sparks + ping)
	local isTouch = Theme.isTouch()
	for i = 1, 5 do
		local hm = Instance.new("Frame")
		hm.Name = "Hitmarker" .. i
		hm.BackgroundTransparency = 1
		hm.AnchorPoint = Vector2.new(0.5, 0.5)
		hm.Size = UDim2.fromOffset(44, 44)
		hm.Visible = false
		hm.Parent = cross
		local sc = Instance.new("UIScale")
		sc.Parent = hm
		local bars = {}
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				local b = Instance.new("Frame")
				b.AnchorPoint = Vector2.new(0.5, 0.5)
				b.Size = UDim2.fromOffset(if isTouch then 4 else 3, if isTouch then 11 else 9)
				b.Position = UDim2.new(0.5, sx * 8, 0.5, sy * 8)
				b.Rotation = (sx * sy > 0) and 45 or -45
				b.BackgroundColor3 = C.White
				b.BorderSizePixel = 0
				b.Parent = hm
				local st = Theme.stroke(b, C.Black, 1, 0.1)
				table.insert(bars, { frame = b, stroke = st, sx = sx, sy = sy })
			end
		end
		-- outer dark backing for deflect shield diamond so light steel pops on bright desert terrain
		local diamondBg = Instance.new("Frame")
		diamondBg.Name = "DiamondBg"
		diamondBg.BackgroundTransparency = 1
		diamondBg.AnchorPoint = Vector2.new(0.5, 0.5)
		diamondBg.Position = UDim2.fromScale(0.5, 0.5)
		diamondBg.Size = UDim2.fromOffset(if isTouch then 25 else 21, if isTouch then 25 else 21)
		diamondBg.Rotation = 45
		diamondBg.Visible = false
		diamondBg.Parent = hm
		local diamondBgSt = Theme.stroke(diamondBg, C.Black, 3, 0.25)

		local diamond = Instance.new("Frame")
		diamond.Name = "Diamond"
		diamond.BackgroundTransparency = 1
		diamond.AnchorPoint = Vector2.new(0.5, 0.5)
		diamond.Position = UDim2.fromScale(0.5, 0.5)
		diamond.Size = UDim2.fromOffset(if isTouch then 16 else 14, if isTouch then 16 else 14)
		diamond.Rotation = 45
		diamond.Visible = false
		diamond.Parent = hm
		local diamondSt = Theme.stroke(diamond, Style.Amber, 2, 0)

		local slash = Instance.new("Frame")
		slash.Name = "DeflectSlash"
		slash.AnchorPoint = Vector2.new(0.5, 0.5)
		slash.Position = UDim2.fromScale(0.5, 0.5)
		slash.Size = UDim2.fromOffset(3, if isTouch then 24 else 20)
		slash.Rotation = -45
		slash.BackgroundColor3 = C.White
		slash.BorderSizePixel = 0
		slash.Visible = false
		slash.Parent = hm
		local slashSt = Theme.stroke(slash, C.Black, 1, 0.1)

		local ping = Instance.new("Frame")
		ping.Name = "DeflectPing"
		ping.BackgroundTransparency = 1
		ping.AnchorPoint = Vector2.new(0.5, 0.5)
		ping.Position = UDim2.fromScale(0.5, 0.5)
		ping.Size = UDim2.fromOffset(16, 16)
		ping.Visible = false
		ping.Parent = hm
		Theme.corner(ping, 100)
		local pingSt = Theme.stroke(ping, C.White, 2, 0.15)

		local sparks = {}
		local sparkDefs = {
			{ dx = 18, dy = -16, rot = 40 },
			{ dx = -15, dy = -13, rot = -48 },
			{ dx = 14, dy = 13, rot = -42 },
		}
		for _, sd in sparkDefs do
			local sp = Instance.new("Frame")
			sp.AnchorPoint = Vector2.new(0.5, 0.5)
			sp.Position = UDim2.fromScale(0.5, 0.5)
			sp.Size = UDim2.fromOffset(if isTouch then 3 else 2, if isTouch then 9 else 7)
			sp.Rotation = sd.rot
			sp.BackgroundColor3 = Color3.fromHex("ffe89e")
			sp.BorderSizePixel = 0
			sp.Visible = false
			sp.Parent = hm
			local spSt = Theme.stroke(sp, C.Black, 1, 0.25)
			table.insert(sparks, { frame = sp, stroke = spSt, dx = sd.dx, dy = sd.dy })
		end

		local tag = Theme.label({
			Text = "",
			Font = "Black",
			TextSize = if isTouch then 15 else 13,
			Size = UDim2.fromOffset(120, 18),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0, -20),
			Parent = hm,
		})
		table.insert(hmPool, {
			frame = hm,
			scale = sc,
			bars = bars,
			diamond = diamond,
			diamondStroke = diamondSt,
			diamondBg = diamondBg,
			diamondBgStroke = diamondBgSt,
			slash = slash,
			slashStroke = slashSt,
			ping = ping,
			pingStroke = pingSt,
			sparks = sparks,
			tag = tag,
			tweens = {},
		})
	end

	-- armour tier badge (HUD.hitmarker): high-contrast pill under the crosshair so tier names read clearly on phones
	local tierH = if isTouch then 22 else 20
	local tierPill = Instance.new("Frame")
	tierPill.Name = "ArmourTagPill"
	tierPill.AnchorPoint = Vector2.new(0.5, 0)
	tierPill.Position = UDim2.fromOffset(0, 22)
	tierPill.Size = UDim2.fromOffset(0, tierH)
	tierPill.AutomaticSize = Enum.AutomaticSize.X
	tierPill.BackgroundColor3 = Style.Black
	tierPill.BackgroundTransparency = 1
	tierPill.BorderSizePixel = 0
	tierPill.Parent = cross
	Theme.corner(tierPill, 4)
	local tierPad = Instance.new("UIPadding")
	tierPad.PaddingLeft = UDim.new(0, 7)
	tierPad.PaddingRight = UDim.new(0, 7)
	tierPad.Parent = tierPill
	local tierStroke = Theme.stroke(tierPill, C.White, 1.5, 1)

	local tierTag = Theme.label({
		Name = "ArmourTag",
		Text = "",
		Font = "Black",
		TextSize = if isTouch then 15 else 13,
		Size = UDim2.fromOffset(0, tierH),
		AutomaticSize = Enum.AutomaticSize.X,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Parent = tierPill,
	})
	ui.tierPill = tierPill
	ui.tierStroke = tierStroke
	ui.tierTag = tierTag
	ui.tierTweens = {} :: { Tween }
	ui.tierGen = 0

	-- reload bar under crosshair
	local rb = Style.panel({
		Name = "ReloadBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 44),
		Size = UDim2.fromOffset(120, 6),
		Visible = false,
		Parent = gui,
	})
	local rf = Style.rect({ Name = "Fill", Color = Style.Amber, Size = UDim2.fromScale(0, 1), Parent = rb })
	ui.reloadBar = rb
	ui.reloadFill = rf
	ui.reloadLabel = Style.label({
		Text = "RELOADING",
		TextSize = 12,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(140, 14),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 54),
		Visible = false,
		Parent = gui,
	})

	-- beacon prompt
	local prompt = Instance.new("Frame")
	prompt.Name = "BeaconPrompt"
	prompt.BackgroundTransparency = 1
	prompt.AnchorPoint = Vector2.new(0.5, 0)
	prompt.Position = UDim2.new(0.5, 0, 0.5, 80)
	prompt.Size = UDim2.fromOffset(320, 56)
	prompt.Visible = false
	prompt.Parent = gui
	local pscale = Instance.new("UIScale")
	pscale.Parent = prompt
	ui.promptScale = pscale
	ui.promptFrame = prompt
	ui.promptTitle = Theme.label({
		Text = "THROW BEACON",
		Font = "Header",
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = prompt,
	})
	ui.promptSub = Theme.label({
		Text = "",
		Font = "Body",
		TextSize = 14,
		Color = C.Muted,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 30),
		Parent = prompt,
	})

	-- crosshair satellites (new layout only; Studio A/B CROSSHAIR INFO, Feel_XhairInfo: nil = on low ammo / low hp,
	-- "always", "off"): the mag count right-below the crosshair, a health arc on its left. Raw px like the crosshair.
	if HudSkin.isNew() then
		local sat = HudLayout.get("satellites", touch)
		ui.satMag = HudSkin.label({
			Name = "SatMag",
			Role = "number",
			Text = "",
			TextSize = sat.TextSize,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromOffset(sat.MagOffset.X, sat.MagOffset.Y),
			Size = UDim2.fromOffset(sat.TextSize * 3, sat.TextSize + 4),
			Visible = false,
			Parent = cross,
		})
		ui.satMag:SetAttribute("NoTextFloor", true)
		local arc = Instance.new("Frame")
		arc.Name = "SatArc"
		arc.BackgroundTransparency = 1
		arc.Size = UDim2.fromOffset(0, 0)
		arc.Visible = false
		arc.Parent = cross
		ui.satArc = arc
		ui.satDots = {}
		local n = 12
		for i = 1, n do
			-- left 90 degrees, bottom (lowest health) to top
			local a = math.rad(225 - (i - 1) / (n - 1) * 90)
			local d = Instance.new("Frame")
			d.BorderSizePixel = 0
			d.AnchorPoint = Vector2.new(0.5, 0.5)
			d.Position = UDim2.fromOffset(math.cos(a) * sat.ArcRadius, -math.sin(a) * sat.ArcRadius)
			d.Size = UDim2.fromOffset(sat.ArcWidth, sat.ArcWidth + 1)
			d.Rotation = -math.deg(a)
			d.BackgroundColor3 = HudSkin.color("text")
			d.Parent = arc
			ui.satDots[i] = d
		end
		ui.satShown = ""
	end
end

-- Phone placement of the raw-px crosshair-layer widgets (beacon prompt, kill streak, barrel ring). Reference phone
-- 800 x 380, touch cluster at x 514-776 / y 86-364 (computed from MobileControls, not measured):
--   beacon prompt  old: 320 x 56 at y 270-326, x 240-560 (under UPLINK 514-586 and SIDE 458-506)
--                  new: 220 x 72 (hint on its own line) at y 258-330, x 290-510: under the RELOADING label (244-258),
--                       left of UPLINK; the centred text clears SIDE (458-506 from y 316); the pickup toast sits
--                       above the crosshair, so the prompt stays below it
--   kill streak    old: centre y 50, 24-76 (on the alert bar, which starts at y ~32)
--                  new: centre y 95, x0.65 -> 156 x 34 at y 78-112 (pop x1.25: 73-117)
local function placePhone()
	local new = phoneNew()
	local prompt = ui.promptFrame
	if prompt then
		prompt.Position = UDim2.new(0.5, 0, 0.5, if new then 68 else 80)
		prompt.Size = UDim2.fromOffset(if new then 220 else 320, if new then 72 else 56)
		if ui.promptSub then
			ui.promptSub.Size = UDim2.new(1, 0, 0, if new then 38 else 20) -- two lines: call-in name, then the hint
		end
	end
	if ui.streakFrame then
		ui.streakFrame.Position = UDim2.new(0.5, 0, 0.5, if new then -95 else -140)
	end
	if ui.barrelScale then
		ui.barrelScale.Scale = if new then 0.7 else 1
	end
end

local function streakK(): number -- kill streak pop size multiplier (phones, new layout)
	return if phoneNew() then 0.65 else 1
end

-- Main HUD ----------------------------------------------------------------------------------------------------------
local function buildShipPanel(parent: Instance)
	local p = Theme.panel({
		Name = "ShipInfo",
		Color = C.Navy,
		Transparency = 0.15,
		Accent = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 0,
		Visible = false,
		Parent = parent,
	})
	Theme.pad(p, 12, 10, 12, 12)
	Theme.list(p, Enum.FillDirection.Vertical, 6)
	Theme.label({
		Text = string.upper(Config.ShipName),
		Font = "Header",
		TextSize = 13,
		Color = C.Accent,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 1,
		Parent = p,
	})
	ui.shipRank = Theme.label({
		Text = "RANK 1",
		Font = "Black",
		TextSize = 24,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = 2,
		Parent = p,
	})
	ui.shipXpBar = Theme.bar({ Size = UDim2.new(1, 0, 0, 10), Color = C.Friendly, LayoutOrder = 3, Parent = p })
	ui.shipXpText = Theme.label({
		Text = "0 / 400 XP",
		Font = "Medium",
		TextSize = 12,
		Color = C.Muted,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 14),
		LayoutOrder = 4,
		Parent = p,
	})
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 26)
	row.LayoutOrder = 5
	row.Parent = p
	Theme.list(row, Enum.FillDirection.Horizontal, 14)
	ui.shipSalvage = Theme.label({
		Text = "SALVAGE 0",
		Font = "Black",
		TextSize = 15,
		Color = C.Accent,
		Rich = true,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.5, -7, 1, 0),
		Parent = row,
	})
	ui.shipTokens = Theme.label({
		Text = "TOKENS 0",
		Font = "Black",
		TextSize = 15,
		Color = C.Friendly,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.5, -7, 1, 0),
		Parent = row,
	})
	if not touch then
		Theme.label({
			Text = "Use the terminals on deck:\nLOADOUT  ARMORY  BONDS  SHOP  MISSION",
			Font = "Medium",
			TextSize = 12,
			Color = C.Muted,
			Wrap = true,
			XAlign = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 32),
			LayoutOrder = 6,
			Parent = p,
		})
	end
	ui.shipPanel = p
end

-- predicted ammo (WeaponController): its local magazine table and a per-shot "tick" on the counter
local localMags: { [number]: number }? = nil
local magShown = 1 -- displayed bar fraction (eased)
local magTarget = 1
local shotKick = 0 -- 1 right after a shot, decays to 0
local jitterRng = Random.new()

local MAG_SEGS = 20
local HP_BAR_W = 210

-- Bottom-left own card: weapon name + mag counter, segmented magazine bar, stim / grenade / mag counts, callsign + health bar.
local function buildOwnCard(parent: Instance)
	local card = Style.panel({
		Name = "OwnCard",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, Style.MARGIN, 1, -Style.MARGIN),
		Size = UDim2.fromOffset(HP_BAR_W + 66, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	ui.ownCard = card
	Style.applyBoost(card, touch)
	Theme.pad(card, 8, 6, 8, 7)
	Theme.list(card, Enum.FillDirection.Vertical, 4)

	-- weapon name (left) + magazine / spare (right)
	local top = Instance.new("Frame")
	top.Name = "Weapon"
	top.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, 32)
	top.LayoutOrder = 1
	top.Parent = card
	ui.ammoName = Style.label({
		Text = "",
		TextSize = 17,
		Color = Style.Amber,
		Size = UDim2.new(1, -96, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = top,
	})
	ui.ammoState = Style.label({
		Text = "",
		TextSize = 14,
		Color = Style.Red,
		Size = UDim2.new(1, -158, 0, 14),
		Position = UDim2.fromOffset(0, 17),
		Parent = top,
	})
	ui.ammoAp = Style.label({
		Text = "",
		TextSize = 12,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -158, 0, 18),
		Size = UDim2.fromOffset(78, 14),
		Parent = top,
	})
	ui.ammoMag = Style.label({
		Text = "0",
		TextSize = 32,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -42, 0, -1),
		Size = UDim2.fromOffset(54, 32),
		Parent = top,
	})
	ui.ammoSpare = Style.label({
		Text = "/ 0",
		TextSize = 17,
		Color = Style.Grey,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 9),
		Size = UDim2.fromOffset(40, 18),
		Parent = top,
	})
	ui.ammoMagPos = ui.ammoMag.Position
	-- fire mode (HUD.setFireMode from WeaponController) left of the counter; a button so touch can tap it to switch
	local fm = Instance.new("TextButton")
	fm.Name = "FireMode"
	fm.AutoButtonColor = false
	fm.BackgroundTransparency = 1
	fm.BorderSizePixel = 0
	fm.FontFace = Style.Font
	fm.TextSize = 13
	fm.TextColor3 = Style.Grey
	fm.TextStrokeColor3 = Style.Black
	fm.TextStrokeTransparency = 0.65
	fm.TextXAlignment = Enum.TextXAlignment.Right
	fm.AnchorPoint = Vector2.new(1, 0)
	-- touch: a taller hit box reaching up over the name line (text stays on the bottom line)
	fm.Position = UDim2.new(1, -98, 0, if touch then 2 else 17)
	fm.Size = UDim2.fromOffset(if touch then 64 else 56, if touch then 30 else 15)
	fm.TextYAlignment = Enum.TextYAlignment.Bottom
	fm.Text = ""
	fm.Parent = top
	fm.Activated:Connect(function()
		if (HUD :: any).fireModeTap then
			(HUD :: any).fireModeTap()
		end
	end)
	ui.fireMode = fm

	-- magazine segments
	local segs = Instance.new("Frame")
	segs.Name = "MagBar"
	segs.BackgroundTransparency = 1
	segs.Size = UDim2.new(1, 0, 0, 6)
	segs.LayoutOrder = 2
	segs.Parent = card
	Theme.list(segs, Enum.FillDirection.Horizontal, 1)
	ui.magSegs = {}
	for i = 1, MAG_SEGS do
		local s = Style.rect({
			Color = Style.White,
			Transparency = 0.8,
			Size = UDim2.new(1 / MAG_SEGS, -1, 1, 0),
			LayoutOrder = i,
			Parent = segs,
		})
		ui.magSegs[i] = s
	end

	-- counts: stims / grenades / spare magazines
	local counts = Instance.new("Frame")
	counts.Name = "Counts"
	counts.BackgroundTransparency = 1
	counts.Size = UDim2.new(1, 0, 0, 20)
	counts.LayoutOrder = 3
	counts.Parent = card
	Theme.list(counts, Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local function countCell(name: string, glyph: string, order: number): TextLabel
		local l = Style.label({
			Name = name,
			Text = glyph .. " 0",
			TextSize = 16,
			Color = Style.Amber,
			Size = UDim2.fromOffset(0, 20),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = order,
			Parent = counts,
		})
		return l
	end
	ui.cntStim = countCell("Stims", "STIM", 1)
	ui.cntNade = countCell("Grenades", "GREN", 2)
	ui.cntMags = countCell("Mags", "MAG", 3)
	ui.cntStim.Visible = false -- only shown when the server publishes me.stims

	-- callsign + health
	local hpRow = Instance.new("Frame")
	hpRow.Name = "Health"
	hpRow.BackgroundTransparency = 1
	hpRow.Size = UDim2.new(1, 0, 0, 22)
	hpRow.LayoutOrder = 4
	hpRow.Parent = card
	ui.callsign = Style.label({
		Text = "S1",
		TextSize = 17,
		Color = Style.Amber,
		Size = UDim2.fromOffset(32, 22),
		Parent = hpRow,
	})
	local track = Style.rect({
		Name = "HpTrack",
		Color = Style.Black,
		Transparency = 0.4,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 34, 0.5, 0),
		Size = UDim2.new(1, -34, 0, 12), -- long bar: the whole row after the callsign
		Parent = hpRow,
	})
	ui.hpPanel = track
	-- ghost chunk: the health just lost, light red, drains after a short hold (step)
	ui.hpGhost = Style.rect({ Name = "Ghost", Color = Color3.fromRGB(255, 150, 140), Transparency = 0.15, Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = track })
	ui.hpFill = Style.rect({ Name = "Fill", Color = Style.White, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = track })
	local st = Instance.new("UIStroke")
	st.Color = Style.White
	st.Transparency = 0.7
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = track
	ui.hpStroke = st
	ui.hpText = Style.label({
		Text = "",
		TextSize = 12,
		Color = Style.Grey,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = hpRow,
	})
	ui.hpText.Visible = false -- numbers live on the bar tooltip-free; kept for updateHealth()
end

-- Toasts: small flat lines low centre (the centre of the screen and the top alert stack stay clear)
local function buildToasts(root: Instance)
	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, if HudLayout.preset() == "frame" then 0.74 else 0.8, 0)
	holder.Size = UDim2.fromOffset(440, 0)
	if touch then
		-- between the left column and the touch buttons, above the SIDE chip / Frame bottom bar
		holder.Position = UDim2.new(0.44, 0, if HudLayout.preset() == "frame" then 0.66 else 0.74, 0)
		holder.Size = UDim2.fromOffset(380, 0)
	end
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Parent = root
	Theme.list(holder, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)
	ui.toasts = holder
end

-- New layout (UI STYLE skins A-C): no stacked panels. Health bottom-left (phone: top-left), weapon block bottom-right
-- (phone: top-left under the health), compass top centre; the information modules (goal line, mission sheet, timer,
-- call-in strip, squad strip, one event feed) place themselves from UI/HudLayout inside the same build calls the old
-- HUD makes. One scale (Theme.scaleFor("hud")), no 0.8 content frame, no boosts. The ship panel keeps the old column.
local function buildMainNew()
	local gui = Theme.gui("OrbitHUD", { DisplayOrder = 10, Insets = "CoreUISafeInsets" })
	ui.mainGui = gui
	local screen, screenScale = Theme.root(gui, "hud")
	ui.screen = screen
	ui.screenScale = screenScale
	ui.root = screen
	local root = screen

	-- Frame preset: solid high-contrast edge bars (top bar for compass + objective + timer, bottom bar for vitals + call-ins + weapon)
	if HudLayout.preset() == "frame" then
		local topCfg = HudLayout.get("topBar", touch)
		local botCfg = HudLayout.get("bottomBar", touch)
		local topH = topCfg.Height or 67
		local botH = botCfg.Height or 75
		local barColor = Color3.fromHex("06090F")
		local edgeColor = HudSkin.color("objective")

		local topBar = Instance.new("Frame")
		topBar.Name = "FrameTopBar"
		topBar.BackgroundColor3 = barColor
		topBar.BackgroundTransparency = 0.08
		topBar.BorderSizePixel = 0
		topBar.Position = UDim2.fromOffset(0, 0)
		topBar.Size = UDim2.new(1, 0, 0, topH)
		topBar.ZIndex = 0
		topBar.Parent = root
		local topLine = Instance.new("Frame")
		topLine.Name = "Edge"
		topLine.BorderSizePixel = 0
		topLine.BackgroundColor3 = edgeColor
		topLine.BackgroundTransparency = 0.25
		topLine.AnchorPoint = Vector2.new(0, 1)
		topLine.Position = UDim2.fromScale(0, 1)
		topLine.Size = UDim2.new(1, 0, 0, 2)
		topLine.Parent = topBar

		local botBar = Instance.new("Frame")
		botBar.Name = "FrameBottomBar"
		botBar.BackgroundColor3 = barColor
		botBar.BackgroundTransparency = 0.08
		botBar.BorderSizePixel = 0
		botBar.AnchorPoint = Vector2.new(0, 1)
		botBar.Position = UDim2.fromScale(0, 1)
		botBar.Size = if touch then UDim2.fromOffset(HudLayout.phoneBottomWidth(), botH) else UDim2.new(1, 0, 0, botH)
		botBar.ZIndex = 0
		botBar.Parent = root
		if touch then
			Theme.onScaleChanged(function()
				if botBar.Parent then
					botBar.Size = UDim2.fromOffset(HudLayout.phoneBottomWidth(), botH)
				end
			end)
		end
		local botLine = Instance.new("Frame")
		botLine.Name = "Edge"
		botLine.BorderSizePixel = 0
		botLine.BackgroundColor3 = edgeColor
		botLine.BackgroundTransparency = 0.25
		botLine.Position = UDim2.fromOffset(0, 0)
		botLine.Size = UDim2.new(1, 0, 0, 2)
		botLine.Parent = botBar
	end

	-- ship info (lobby only): the old top-left column, unchanged
	local legacy = Style.content(screen, touch)
	legacy.Name = "ShipContent"
	local left = Instance.new("Frame")
	left.Name = "LeftColumn"
	left.BackgroundTransparency = 1
	left.Position = UDim2.fromOffset(Style.MARGIN, Style.MARGIN)
	left.Size = UDim2.fromOffset(if touch then Style.LEFT_TOUCH_W else Style.LEFT_PC_W, 0)
	left.AutomaticSize = Enum.AutomaticSize.Y
	left.Parent = legacy
	Style.applyBoost(left, touch)
	Theme.list(left, Enum.FillDirection.Vertical, 8)
	ui.left = left
	buildShipPanel(left)

	-- information modules: each decides its own place in the new layout (UI/InfoLayer + UI/HudLayout)
	AreaInfo.build(root, touch, 1)
	ObjectiveList.build(root, touch, 2)
	CallInList.build(root, touch, 3)
	ui.compassMarkerLayer = Compass.build(root, touch)
	TopRight.build(root, touch)
	ui.objReady = true

	ui.vitals = Vitals.build(root, touch)
	local wb = WeaponBlock.build(root, touch, function()
		if (HUD :: any).fireModeTap then
			(HUD :: any).fireModeTap()
		end
	end)
	-- the ammo code writes the same label roles as on the old card
	ui.weaponBlock = wb.root
	ui.ammoName = wb.name
	ui.ammoAp = wb.ap
	ui.ammoState = wb.state
	ui.ammoMag = wb.mag
	ui.ammoSpare = wb.spare
	ui.ammoMagPos = wb.mag.Position
	ui.fireMode = wb.fireMode
	ui.cntNade = wb.nade
	ui.cntMags = wb.mags
	ui.cntStim = wb.stim

	SquadCards.build(root, touch)
	EventFeed.build(root, touch)
	PickupToast.build(root, touch)
	SquadComms.build(ui.vitals, touch)
	buildToasts(root)

	-- visor: thin brackets at the four outer screen corners (the "visor frame"); none on elements
	local skin = HudSkin.current()
	if skin and skin.id == "visor" then
		local frame = Instance.new("Frame")
		frame.Name = "VisorFrame"
		frame.BackgroundTransparency = 1
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		local m = if touch then 8 else 12
		frame.Size = UDim2.new(1, -2 * m, 1, -2 * m)
		frame.Parent = root
		local col = skin.colors.dim
		for _, c in { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) } do
			for _, horiz in { true, false } do
				local b = Instance.new("Frame")
				b.BorderSizePixel = 0
				b.BackgroundColor3 = col
				b.BackgroundTransparency = 0.35
				b.AnchorPoint = c
				b.Position = UDim2.fromScale(c.X, c.Y)
				b.Size = if horiz then UDim2.fromOffset(12, 1) else UDim2.fromOffset(1, 12)
				b.Parent = frame
			end
		end
	end
end

local function buildMain()
	newLayout = HudSkin.isNew()
	if newLayout then
		buildMainNew()
		return
	end
	local gui = Theme.gui("OrbitHUD", { DisplayOrder = 10, Insets = "CoreUISafeInsets" })
	ui.mainGui = gui
	local screen, screenScale = Theme.root(gui, "hud")
	ui.screen = screen
	ui.screenScale = screenScale
	local root = Style.content(screen, touch) -- 0.8 x on touch
	ui.root = root

	-- top-left column: ship info (lobby), area info, uplink list (squad cards sit above the own card, bottom-left).
	-- Touch: the right edge belongs to the touch buttons, so the objective block moves into this column and the uplink
	-- list becomes a second narrow column beside it (LEFT_TOUCH_W + 8 + CALLIN_TOUCH_W wide).
	local left = Instance.new("Frame")
	left.Name = "LeftColumn"
	left.BackgroundTransparency = 1
	left.Position = UDim2.fromOffset(Style.MARGIN, Style.MARGIN)
	left.Parent = root
	Style.applyBoost(left, touch) -- bigger text / rows (viewport scale comes from Theme.root + Style.content)
	ui.left = left

	local col1 = left
	local col2: Frame? = nil
	if touch then
		left.Size = UDim2.fromOffset(0, 0)
		left.AutomaticSize = Enum.AutomaticSize.XY
		Theme.list(left, Enum.FillDirection.Horizontal, 8)
		col1 = Instance.new("Frame")
		col1.Name = "Main"
		col1.BackgroundTransparency = 1
		col1.Size = UDim2.fromOffset(Style.LEFT_TOUCH_W, 0)
		col1.AutomaticSize = Enum.AutomaticSize.Y
		col1.LayoutOrder = 1
		col1.Parent = left
		local c2 = Instance.new("Frame")
		c2.Name = "Uplink"
		c2.BackgroundTransparency = 1
		c2.Size = UDim2.fromOffset(Style.CALLIN_TOUCH_W, 0)
		c2.AutomaticSize = Enum.AutomaticSize.Y
		c2.LayoutOrder = 2
		c2.Parent = left
		Theme.list(c2, Enum.FillDirection.Vertical, 8)
		col2 = c2
	else
		left.Size = UDim2.fromOffset(Style.LEFT_PC_W, 0)
		left.AutomaticSize = Enum.AutomaticSize.Y
	end
	Theme.list(col1, Enum.FillDirection.Vertical, 8)

	buildShipPanel(col1)
	AreaInfo.build(col1, touch, 1)
	if col2 then
		ObjectiveList.build(col1, touch, 2)
		CallInList.build(col2, touch, 1)
	else
		CallInList.build(col1, touch, 2)
	end

	ui.compassMarkerLayer = Compass.build(root, touch)
	TopRight.build(root, touch)
	if not col2 then
		ObjectiveList.build(root, touch)
	end
	ui.objReady = true
	buildOwnCard(root)
	SquadCards.build(root, touch)
	-- squad cards stack upward from just above the own card (+ its radio line), whatever the card's height
	local function placeSquad()
		local k = ui.screenScale.Scale * (if touch then 0.8 else 1)
		if k <= 0 or not ui.ownCard then
			return
		end
		local bottom = Style.MARGIN + ui.ownCard.AbsoluteSize.Y / k + 40
		SquadCards.setBottom(bottom)
		-- free height above the stack's bottom edge, under the objective column (A) and under the uplink column (B):
		-- phones with a full squad go compact, then slide under the uplink column, instead of covering the objective list
		local stackBottom = root.AbsoluteSize.Y / k - bottom
		local function colBottom(f: Frame): number
			return (f.AbsolutePosition.Y + f.AbsoluteSize.Y - root.AbsolutePosition.Y) / k
		end
		local roomB, xB = 0, 0
		if col2 then
			roomB = stackBottom - colBottom(col2) - 4
			xB = (col2.AbsolutePosition.X - root.AbsolutePosition.X) / k
		end
		SquadCards.setRoom(stackBottom - colBottom(col1) - 4, roomB, xB)
	end
	ui.ownCard:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeSquad)
	col1:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeSquad)
	if col2 then
		col2:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeSquad)
	end
	ui.screenScale:GetPropertyChangedSignal("Scale"):Connect(placeSquad)
	task.defer(placeSquad)
	EventFeed.build(root, touch)
	PickupToast.build(root, touch)
	SquadComms.build(ui.ownCard, touch)
	buildToasts(root)
end

-- The damage edge vignette, desaturation, heartbeat and big-hit overlay live in client/Fx/VitalsFx.luau (2026-11-14).

-- Toasts / banners ---------------------------------------------------------------------------------------------------
function HUD.toast(text: string, color: Color3?)
	if not ui.toasts then
		return
	end
	-- new layout: one place for event text (the event feed)
	if newLayout and COMBAT[state] then
		EventFeed.push(text, color or Style.White, "toast")
		return
	end
	local col = color or C.Text
	local kids = {}
	for _, k in ui.toasts:GetChildren() do
		if k:IsA("Frame") then
			table.insert(kids, k)
		end
	end
	if #kids >= 5 then
		kids[1]:Destroy()
	end
	local pill = Style.panel({
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = math.floor(os.clock() * 1000),
		Parent = ui.toasts,
	})
	Theme.pad(pill, 10, 0, 10, 0)
	local lbl = Style.label({
		Text = text,
		Color = col,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = pill,
	})
	pill.BackgroundTransparency = 1
	lbl.TextTransparency = 1
	lbl.TextStrokeTransparency = 1
	tw(pill, 0.18, { BackgroundTransparency = Style.PANEL_ALPHA })
	tw(lbl, 0.18, { TextTransparency = 0, TextStrokeTransparency = 0.65 })
	task.delay(3.6, function()
		if pill.Parent then
			tw(pill, 0.4, { BackgroundTransparency = 1 })
			tw(lbl, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
			task.delay(0.45, function()
				pill:Destroy()
			end)
		end
	end)
end

-- Big centre banners are gone: titles go to the alert stack under the compass (UI/AlertBar notice line).
function HUD.banner(title: string, subtitle: string?, color: Color3?)
	AlertBar.notice(title, subtitle, color, 2.4)
end

-- Hitmarkers ----------------------------------------------------------------------------------------------------------
-- Armour tier badge under the crosshair. Studio A/B (Variants group ARMOUR TAG, Feel_ArmourTag): nil = deflect + partial,
-- "all" = every hit, "off" = never. Bright steel on a deflect, amber on a partial hit, white on a full pen.
local TIER_TAG_HOLD = 0.45
local TIER_TAG_FADE = 0.35
local DEFLECT_STEEL = Color3.fromHex("d8e2f0")
local DEFLECT_STROKE = Color3.fromHex("9bb0cc")
local DEFLECT_SPARK = Color3.fromHex("ffe89e")
local function showTierTag(result: string, armor: number?)
	local lbl: TextLabel? = ui.tierTag
	local pill: Frame? = ui.tierPill
	local st: UIStroke? = ui.tierStroke
	if not lbl or not pill or not st or not armor then
		return
	end
	local mode = workspace:GetAttribute("Feel_ArmourTag")
	if mode == "off" or (mode ~= "all" and result == "pen") then
		return
	end
	local prev: { Tween }? = ui.tierTweens
	if prev then
		for _, t in prev do
			t:Cancel()
		end
		table.clear(prev)
	end
	local textCol = if result == "deflect" then DEFLECT_STEEL elseif result == "partial" then Style.Amber else C.White
	local edgeCol = if result == "deflect" then DEFLECT_STROKE elseif result == "partial" then Style.Amber else C.White
	lbl.Text = string.upper(Damage.tierName(armor))
	lbl.TextColor3 = textCol
	lbl.TextTransparency = 0
	lbl.TextStrokeTransparency = 0.35
	pill.BackgroundTransparency = 0.22
	st.Color = edgeCol
	st.Transparency = 0.2
	ui.tierGen += 1
	local gen = ui.tierGen
	task.delay(TIER_TAG_HOLD, function()
		if ui.tierGen ~= gen then
			return
		end
		local list = ui.tierTweens
		if list then
			table.insert(list, tw(lbl, TIER_TAG_FADE, { TextTransparency = 1, TextStrokeTransparency = 1 }))
			table.insert(list, tw(pill, TIER_TAG_FADE, { BackgroundTransparency = 1 }))
			table.insert(list, tw(st, TIER_TAG_FADE, { Transparency = 1 }))
		end
	end)
end

function HUD.hitmarker(result: string, weak: boolean?, killed: boolean?, armor: number?)
	showTierTag(result, armor)
	local hm = hmPool[hmIndex]
	if not hm then
		return
	end
	hmIndex = hmIndex % #hmPool + 1
	for _, t in hm.tweens do
		t:Cancel()
	end
	table.clear(hm.tweens)

	local isTouch = Theme.isTouch()
	local isDeflect = result == "deflect"
	local isPartial = result == "partial"

	local col = C.White
	if isDeflect then
		col = DEFLECT_STEEL
	elseif isPartial then
		col = Style.Amber
	end
	if weak and not isDeflect then
		col = C.Gold
	end
	if killed then
		col = weak and C.Gold or C.Danger
	end

	-- reset all sub-elements before applying this result's silhouette
	hm.diamond.Visible = false
	hm.diamondBg.Visible = false
	hm.slash.Visible = false
	hm.ping.Visible = false
	for _, sp in hm.sparks do
		sp.frame.Visible = false
	end

	if isDeflect then
		for _, b in hm.bars do
			b.frame.Visible = false
		end
		-- steel shield diamond + bold deflect slash + ricochet sparks + ping ring
		local dSize = if isTouch then 22 else 18
		hm.diamond.Size = UDim2.fromOffset(dSize, dSize)
		hm.diamond.Visible = true
		hm.diamondStroke.Color = DEFLECT_STEEL
		hm.diamondStroke.Thickness = 2.5
		hm.diamondStroke.Transparency = 0

		hm.diamondBg.Size = UDim2.fromOffset(dSize + 3, dSize + 3)
		hm.diamondBg.Visible = true
		hm.diamondBgStroke.Transparency = 0.25

		hm.slash.BackgroundColor3 = DEFLECT_STEEL
		hm.slash.BackgroundTransparency = 0
		hm.slash.Visible = true
		hm.slashStroke.Transparency = 0.1

		-- expanding ricochet ping ring
		local pStart = if isTouch then 18 else 14
		local pEnd = if isTouch then 44 else 36
		hm.ping.Size = UDim2.fromOffset(pStart, pStart)
		hm.ping.Visible = true
		hm.pingStroke.Color = DEFLECT_STEEL
		hm.pingStroke.Transparency = 0.15
		table.insert(hm.tweens, tw(hm.ping, 0.2, { Size = UDim2.fromOffset(pEnd, pEnd) }, Enum.EasingStyle.Quad))
		table.insert(hm.tweens, tw(hm.pingStroke, 0.2, { Transparency = 1 }, Enum.EasingStyle.Quad))

		-- small cartoon spark slivers darting off the crosshair
		for _, sp in hm.sparks do
			sp.frame.Position = UDim2.fromScale(0.5, 0.5)
			sp.frame.BackgroundColor3 = DEFLECT_SPARK
			sp.frame.BackgroundTransparency = 0
			sp.frame.Visible = true
			sp.stroke.Transparency = 0.25
			local mul = if isTouch then 1.2 else 1
			table.insert(
				hm.tweens,
				tw(
					sp.frame,
					0.19,
					{ Position = UDim2.new(0.5, math.round(sp.dx * mul), 0.5, math.round(sp.dy * mul)), BackgroundTransparency = 1 },
					Enum.EasingStyle.Quad
				)
			)
			table.insert(hm.tweens, tw(sp.stroke, 0.19, { Transparency = 1 }, Enum.EasingStyle.Quad))
		end

		hm.frame.Visible = true
		hitKick = math.max(hitKick, 1.5)
		hm.scale.Scale = 1.22
		table.insert(hm.tweens, tw(hm.scale, 0.12, { Scale = 1 }, Enum.EasingStyle.Back))
		hm.frame.Rotation = -16
		table.insert(hm.tweens, tw(hm.frame, 0.14, { Rotation = 0 }, Enum.EasingStyle.Back))
	else
		-- pen (full crisp X) vs partial (reduced compact amber X + hollow diamond)
		local bw = if isPartial then (if isTouch then 3 else 2) else (if isTouch then 4 else 3)
		local bh = if isPartial then (if isTouch then 7 else 6) else (if isTouch then 11 else 9)
		local off = if isPartial then 6 else 8
		for _, b in hm.bars do
			b.frame.Visible = true
			b.frame.Size = UDim2.fromOffset(bw, bh)
			b.frame.Position = UDim2.new(0.5, b.sx * off, 0.5, b.sy * off)
			b.frame.BackgroundColor3 = col
			b.frame.BackgroundTransparency = if isPartial then 0.1 else 0
			b.stroke.Transparency = 0.1
		end
		if isPartial then
			local pSize = if isTouch then 16 else 14
			hm.diamond.Size = UDim2.fromOffset(pSize, pSize)
			hm.diamond.Visible = true
			hm.diamondStroke.Color = col
			hm.diamondStroke.Thickness = 1.5
			hm.diamondStroke.Transparency = 0.15
		end
		hm.frame.Visible = true
		-- subtle pulses: reduced pop on partial so full pen feels noticeably punchier
		hitKick = math.max(hitKick, if killed then 8 elseif weak then 5 elseif isPartial then 1.6 else 2.5)
		local startScale = if killed then 1.7 elseif weak then 1.35 elseif isPartial then 0.96 else 1.17
		local endScale = if killed then 1.15 elseif isPartial then 0.85 else 1
		hm.scale.Scale = startScale
		table.insert(hm.tweens, tw(hm.scale, killed and 0.2 or 0.1, { Scale = endScale }, Enum.EasingStyle.Back))
		if killed then
			hm.frame.Rotation = 15
			table.insert(hm.tweens, tw(hm.frame, 0.15, { Rotation = 0 }, Enum.EasingStyle.Back))
			HUD.killRing(col)
		else
			hm.frame.Rotation = 0
		end
	end

	local text = ""
	if isDeflect then
		text = "DEFLECT"
	elseif killed and weak then
		text = "WEAK KILL"
	elseif killed then
		text = "KILL"
	elseif weak then
		text = "WEAK"
	end
	hm.tag.Text = text
	hm.tag.TextColor3 = col
	hm.tag.TextTransparency = 0
	hm.tag.TextStrokeTransparency = 0.35
	local hold = if killed then 0.3 elseif isDeflect then 0.22 elseif isPartial then 0.16 else 0.12
	local fade = if isDeflect then 0.18 else 0.16
	hm.gen = (hm.gen or 0) + 1
	local gen = hm.gen
	task.delay(hold, function()
		if hm.gen ~= gen then
			return
		end
		if isDeflect then
			table.insert(hm.tweens, tw(hm.diamondStroke, fade, { Transparency = 1 }))
			table.insert(hm.tweens, tw(hm.diamondBgStroke, fade, { Transparency = 1 }))
			table.insert(hm.tweens, tw(hm.slash, fade, { BackgroundTransparency = 1 }))
			table.insert(hm.tweens, tw(hm.slashStroke, fade, { Transparency = 1 }))
		else
			for _, b in hm.bars do
				table.insert(hm.tweens, tw(b.frame, fade, { BackgroundTransparency = 1 }))
				table.insert(hm.tweens, tw(b.stroke, fade, { Transparency = 1 }))
			end
			if isPartial then
				table.insert(hm.tweens, tw(hm.diamondStroke, fade, { Transparency = 1 }))
			end
		end
		table.insert(hm.tweens, tw(hm.tag, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }))
	end)
end

-- Kill ring + kill streak popup -----------------------------------------------------------------------------------
-- Fed by the Fx "Death" event (server tags it with the killer's userId), so bullet, grenade and call-in kills all count.
-- Streak = kills landed by the local player with < STREAK_WINDOW s between them. Original wording, no copied names.
local STREAK_WINDOW = 3.5
local STREAK_HOLD = 2.0
local MILESTONES = { [3] = true, [5] = true, [7] = true, [10] = true, [15] = true, [25] = true }
local streak = 0
local streakLast = -100
local missionKills = 0
local streakGen = 0
local streakTweens: { Tween } = {}
local audioMod: any = nil
local fxMod: any = nil

local function buildStreak()
	local gui = ui.crossGui
	if not gui then
		return
	end
	-- expanding ring on kills (centred on the crosshair)
	local ring = Instance.new("Frame")
	ring.Name = "KillRing"
	ring.BackgroundTransparency = 1
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(30, 30)
	ring.Visible = false
	ring.ZIndex = 2
	ring.Parent = gui
	Theme.corner(ring, 100)
	local rs = Instance.new("UIStroke")
	rs.Thickness = 3
	rs.Color = C.Danger
	rs.Parent = ring
	ui.killRing = ring
	ui.killRingStroke = rs

	local f = Instance.new("Frame")
	f.Name = "KillStreak"
	f.BackgroundTransparency = 1
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.new(0.5, 0, 0.5, -140)
	f.Size = UDim2.fromOffset(240, 52)
	f.Visible = false
	f.Parent = gui
	local sc = Instance.new("UIScale")
	sc.Parent = f
	ui.streakFrame = f
	ui.streakScale = sc
	-- kill streak = drawn skull icon + the number next to it (no text; the HUD font has no skull glyph)
	Theme.list(f, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	ui.streakSkull = Style.glyph("skull", { Size = 40, Color = C.White, Box = UDim2.fromOffset(40, 40), LayoutOrder = 1, Parent = f })
	ui.streakCount = Theme.label({
		Text = "",
		Font = "Black",
		TextSize = 42,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(0, 48),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = f,
	})
	ui.streakCount.TextStrokeTransparency = 0.2
	placePhone()
	if touch then
		workspace:GetAttributeChangedSignal("Feel_PhoneHud"):Connect(placePhone)
	end
end

-- skull parts (white / dark frames) fade together with the number
local function fadeSkull(alpha: number, time: number)
	local skull = ui.streakSkull
	if not skull then
		return
	end
	for _, d in skull:GetDescendants() do
		if d:IsA("Frame") then
			if time > 0 then
				table.insert(streakTweens, tw(d, time, { BackgroundTransparency = alpha }))
			else
				d.BackgroundTransparency = alpha
			end
		end
	end
end

function HUD.killRing(color: Color3?)
	local ring, stroke = ui.killRing, ui.killRingStroke
	if not ring then
		return
	end
	ring.Size = UDim2.fromOffset(20, 20)
	ring.Visible = true
	stroke.Color = color or C.Danger
	stroke.Transparency = 0.4
	stroke.Thickness = 2
	tw(ring, 0.22, { Size = UDim2.fromOffset(56, 56) }, Enum.EasingStyle.Quad)
	tw(stroke, 0.22, { Transparency = 1, Thickness = 1 }, Enum.EasingStyle.Quad)
end

local function showStreak(count: number, color: Color3, big: number)
	local f = ui.streakFrame
	if not f then
		return
	end
	for _, t in streakTweens do
		t:Cancel()
	end
	table.clear(streakTweens)
	streakGen += 1
	local gen = streakGen
	f.Visible = true
	ui.streakCount.Text = tostring(count)
	ui.streakCount.TextColor3 = color
	ui.streakCount.TextTransparency = 0
	ui.streakCount.TextStrokeTransparency = 0.2
	Style.tint(ui.streakSkull, color)
	fadeSkull(0, 0)
	local sk = streakK()
	ui.streakScale.Scale = 1.25 * big * sk
	table.insert(streakTweens, tw(ui.streakScale, 0.2, { Scale = big * sk }, Enum.EasingStyle.Back))
	task.delay(STREAK_HOLD, function()
		if gen ~= streakGen then
			return
		end
		table.insert(streakTweens, tw(ui.streakCount, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 }))
		fadeSkull(1, 0.4)
		task.delay(0.45, function()
			if gen == streakGen then
				f.Visible = false
			end
		end)
	end)
end

-- Fx "Death" handler: only kills the local player landed.
local function onKill(d: any)
	if type(d) ~= "table" or d.by ~= player.UserId or not COMBAT[state] then
		return
	end
	local t = os.clock()
	streak = if t - streakLast <= STREAK_WINDOW then streak + 1 else 1
	streakLast = t
	missionKills += 1
	TopRight.setResource("kills", missionKills)
	local class = d.class
	-- skull + number only (no streak names). Heavy / behemoth kills show it in gold even on a streak of 1.
	if class == "behemoth" then
		showStreak(streak, C.Gold, 1.2)
	elseif class == "heavy" then
		showStreak(streak, C.Gold, 1.05)
	elseif streak >= 2 then
		-- colour heats up with the streak: white -> gold -> orange -> red
		local col = if streak >= 10 then C.Danger elseif streak >= 5 then C.Accent elseif streak >= 3 then C.Gold else C.White
		showStreak(streak, col, math.min(0.9 + streak * 0.03, 1.3))
	end
	-- event feed: heavy kills and streak milestones (own kills = amber)
	if class == "behemoth" then
		EventFeed.push("BEHEMOTH DOWN", Style.Amber, "kill")
	elseif class == "heavy" then
		EventFeed.push("HEAVY DOWN", Style.Amber, "kill")
	elseif d.elite then -- elite affix kill (server/Enemies/Elites): the bonus grenade + stim toasts follow
		EventFeed.push("ELITE DOWN", Style.Amber, "kill")
	end
	if MILESTONES[streak] and audioMod and audioMod.play2D then
		pcall(audioMod.play2D, "KillWeak", { pitch = 0.9 + math.min(streak, 15) * 0.04, volume = 0.8, priority = 5 })
	end
end

function HUD.getKills(): number
	return missionKills
end

function HUD.getStreak(): number
	return if os.clock() - streakLast <= STREAK_WINDOW then streak else 0
end

function HUD.setSpread(deg: number)
	spreadDeg = deg
end

-- Two-reticle system. screenPos = viewport pixels (Camera:WorldToViewportPoint, no GUI inset) of the point the gun barrel
-- actually hits; nil hides the big circle. blocked = the barrel ray hits something before the camera's target (cover in
-- front of the muzzle): the circle turns orange. Call every frame while armed; while the calls keep coming the centre
-- crosshair shrinks to a small dot (= where the camera looks). ~0.35 s after the last call with a position the HUD falls
-- back to the classic spread crosshair.
function HUD.setBarrelReticle(screenPos: Vector2?, blocked: boolean)
	barrelTarget = screenPos
	barrelBlocked = blocked == true
	barrelCallT = os.clock()
end

local function stepBarrel(dt: number, combat: boolean)
	local ring = ui.barrel
	if not ring then
		return
	end
	local target = barrelTarget
	local dual = combat and target ~= nil and os.clock() - barrelCallT < 0.35 and ui.cross.Visible
	for _, t in ui.ticks do
		t.frame.Visible = not dual
	end
	local dotSize = if dual then 5 else 4
	if ui.dot.Size.X.Offset ~= dotSize then
		ui.dot.Size = UDim2.fromOffset(dotSize, dotSize)
	end
	if not dual or not target then
		if ring.Visible then
			ring.Visible = false
		end
		barrelPos = nil
		return
	end
	if not ring.Visible or not barrelPos then
		barrelPos = target -- first frame after being hidden: snap, no slide-in
		barrelWarn = if barrelBlocked then 1 else 0
		ring.Visible = true
	else
		barrelPos = barrelPos:Lerp(target, 1 - math.exp(-40 * dt)) -- fast lerp: removes jitter, adds no visible lag
	end
	local warnTarget = if barrelBlocked then 1 else 0
	barrelWarn += (warnTarget - barrelWarn) * (1 - math.exp(-20 * dt))
	if math.abs(barrelWarn - warnTarget) < 0.002 then
		barrelWarn = warnTarget -- settled: lets the stroke writes below stop
	end
	-- each GUI write below only happens when its value changed (a steady aim writes nothing)
	if ring ~= barrelShownRing then
		barrelShownRing, barrelShownPos, barrelShownD = ring, nil, -1
	end
	if barrelPos ~= barrelShownPos then
		barrelShownPos = barrelPos
		ring.Position = UDim2.fromOffset(barrelPos.X, barrelPos.Y)
	end
	-- diameter follows the weapon spread a little (the old tick gap), capped
	local d = BARREL_D + math.min(math.max(gap - 5, 0) * 0.4, 36)
	if d ~= barrelShownD then
		barrelShownD = d
		ring.Size = UDim2.fromOffset(d, d)
	end
	if barrelWarn ~= barrelShownWarn or ui.barrelStroke ~= barrelShownStroke then
		barrelShownWarn, barrelShownStroke = barrelWarn, ui.barrelStroke
		ui.barrelStroke.Color = C.White:Lerp(BARREL_BLOCKED, barrelWarn)
		ui.barrelStroke.Thickness = 2 + barrelWarn
		ui.barrelStroke.Transparency = 0.15 - 0.1 * barrelWarn
	end
end

-- Context prompt (UI/ContextPrompt): "TAP [R] TO RELOAD" while the magazine is empty and no reload runs;
-- "OUT OF AMMO - [1-3] SWITCH WEAPON" when the reserve is empty too.
local ammoLastSpare = 0
local ammoLastMax = 0
local function updateReloadPrompt()
	local me = Store.get("me")
	local combat = COMBAT[state] == true and me ~= nil and me.alive ~= false
	if combat and ammoLastId ~= nil and ammoLastMax > 0 and ammoLastMag <= 0 and reloadProgress == nil then
		if ammoLastSpare > 0 then
			ContextPrompt.hide("noammo")
			ContextPrompt.show("reload", "Tap {key} to reload", "Reload", nil, 3)
		else
			ContextPrompt.hide("reload")
			ContextPrompt.show("noammo", "Out of ammo - {key} switch weapon", "Swap", nil, 1)
		end
	else
		ContextPrompt.hide("reload")
		ContextPrompt.hide("noammo")
	end
end

function HUD.setReload(progress: number?)
	if progress ~= nil and reloadProgress == nil then
		SquadComms.onReload()
	end
	local changed = (progress == nil) ~= (reloadProgress == nil)
	reloadProgress = progress
	if changed then
		updateReloadPrompt()
	end
	if progress == nil then
		ui.reloadBar.Visible = false
		ui.reloadLabel.Visible = false
	else
		ui.reloadBar.Visible = true
		ui.reloadLabel.Visible = true
		ui.reloadFill.Size = UDim2.fromScale(Theme.clamp(progress, 0, 1), 1)
	end
end

-- Rail Lance charge (WeaponController): reuses the reload bar. nil = hide.
local charging = false
function HUD.setCharge(frac: number?)
	if not ui.reloadBar then
		return
	end
	if frac == nil then
		if charging then
			charging = false
			ui.reloadBar.Visible = false
			ui.reloadLabel.Visible = false
			ui.reloadLabel.Text = "RELOADING"
		end
		return
	end
	charging = true
	ui.reloadLabel.Text = frac >= 1 and "CHARGED" or "CHARGING"
	ui.reloadBar.Visible = true
	ui.reloadLabel.Visible = true
	ui.reloadFill.Size = UDim2.fromScale(Theme.clamp(frac, 0, 1), 1)
end

-- WeaponController, per predicted shot: tick the counter down immediately with a small kick + shake.
function HUD.ammoShot(slot: number, mag: number, maxMag: number)
	local me = Store.get("me")
	if not inited or not ui.ammoMag or not me or (me.weapon or 1) ~= slot then
		return
	end
	ui.ammoMag.Text = tostring(mag)
	ammoLastMag = mag
	ammoFill = nil
	magTarget = Theme.clamp(mag / math.max(maxMag, 1), 0, 1)
	ammoLow = maxMag > 1 and mag <= math.max(1, maxMag * 0.25)
	if mag <= 0 then
		ui.ammoMag.TextColor3 = Style.Red
		updateReloadPrompt()
	end
	shotKick = 1
end

-- kept for callers; the damage edge effects live in client/Fx/VitalsFx.luau (this only feeds the HP bar stroke flash)
function HUD.flashDamage(strength: number?)
	flash = math.max(flash, strength or 0.6)
	if newLayout then
		Vitals.flash(strength)
	end
end

-- Beacons (for compass + world markers). Call from the call-in FX when a beacon lands / expires.
function HUD.addBeacon(id: string, pos: Vector3, color: Color3?, label: string?)
	beacons[id] = { pos = pos, color = color or C.BeaconOffense, label = label or "BEACON" }
	HUD.refreshMarkers()
end

function HUD.removeBeacon(id: string)
	if beacons[id] then
		beacons[id] = nil
		HUD.refreshMarkers()
	end
end

-- Markers (compass + world) -----------------------------------------------------------------------------------------
function HUD.refreshMarkers()
	for _, m in markers do
		if m.world then
			m.world:Destroy()
		end
		if m.compass then
			m.compass:Destroy()
		end
	end
	table.clear(markers)
	if not ui.markerLayer then
		return
	end
	local list = {}
	local objs = Store.get("objectives")
	if objs then
		for _, o in objs do
			if o.marker and not o.done then
				table.insert(list, {
					key = "obj" .. tostring(o.id),
					pos = o.marker,
					color = o.main and Style.Cyan or Style.Green,
					label = o.title or "",
					glyph = o.main and "diamond" or "diamondHollow", -- Style.glyph shape
				})
			end
			if not o.done and type(o.markers) == "table" then
				for i, sub in o.markers do
					if sub and typeof(sub.pos) == "Vector3" then
						table.insert(list, {
							key = "sub_" .. tostring(o.id) .. "_" .. tostring(sub.key or i),
							pos = sub.pos,
							color = sub.color or (o.main and Style.Cyan or Style.Green),
							label = sub.label or "",
							glyph = sub.glyph or "diamondHollow",
						})
					end
				end
			end
		end
	end
	for id, b in beacons do
		table.insert(list, { key = "bc" .. id, pos = b.pos, color = b.color, label = b.label, glyph = "up" })
	end
	local s = Theme.scaleFor("hud")
	for _, d in list do
		local world = Instance.new("Frame")
		world.Name = d.key
		world.BackgroundTransparency = 1
		world.AnchorPoint = Vector2.new(0.5, 0.5)
		world.Size = UDim2.fromOffset(120, 60)
		local us = Theme.layoutScale(Instance.new("UIScale"))
		us.Scale = math.max(s, 0.8)
		us.Parent = world
		Style.label({
			Name = "Name",
			Text = string.upper(d.label),
			TextSize = 13,
			Color = d.color,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 14),
			Parent = world,
		})
		Style.glyph(d.glyph, {
			Name = "Glyph",
			Size = 18,
			Color = d.color,
			Box = UDim2.new(1, 0, 0, 28),
			Position = UDim2.fromOffset(0, 14),
			Parent = world,
		})
		Style.label({
			Name = "Dist",
			Text = "",
			TextSize = 13,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.fromOffset(0, 42),
			Parent = world,
		})
		world.Visible = false
		world.Parent = ui.markerLayer
		local comp = Compass.addPip(ui.compassMarkerLayer, d.key, d.glyph, d.color)
		markers[d.key] = { pos = d.pos, world = world, compass = comp }
	end
end

-- Objectives ----------------------------------------------------------------------------------------------------------
-- Right-side checklist (UI/ObjectiveList). Also feeds the green SAMPLES chip (parsed "(n/m)" from step texts).
local function updateObjectives()
	if not ui.objReady then
		return
	end
	local objs = Store.get("objectives")
	local newlyDone, newlyStep, any = ObjectiveList.render(objs)
	ObjectiveList.setVisible(any and (COMBAT[state] == true or state == "Drop"))
	for _, t in newlyDone do
		HUD.banner("OBJECTIVE COMPLETE", t, Style.Green)
		Theme.sfx("ObjectiveDone")
		EventFeed.push("OBJECTIVE: " .. t, Style.Cyan, "objective")
	end
	for _, t in newlyStep do
		EventFeed.push("DONE: " .. t, Style.Cyan, "objective")
	end
	local samples = ObjectiveList.sampleCount(objs)
	TopRight.setResource("samples", samples or 0)
	HUD.refreshMarkers()
end

-- Squad -------------------------------------------------------------------------------------------------------------------
-- Squad cards (UI/SquadCards, left edge y 58-78 %) + callsign colours + squad chatter edges
-- Studio-only layout aid: workspace attribute DebugFakeSquad (1-3) pads the squad the cards draw with fake teammates.
-- Client-side only, nothing is sent to the server.
local FAKE_SQUAD = {
	{ userId = -101, name = "Rook", hp = 100, maxHp = 100, alive = true },
	{ userId = -102, name = "Vesper", hp = 40, maxHp = 100, alive = true },
	{ userId = -103, name = "Tallow", hp = 0, maxHp = 100, alive = false },
}

local function withFakeSquad(squad: any): any
	if not RunService:IsStudio() then
		return squad
	end
	local n = workspace:GetAttribute("DebugFakeSquad")
	if type(n) ~= "number" or n < 1 then
		return squad
	end
	local out = {}
	if type(squad) == "table" then
		for _, m in squad do
			table.insert(out, m)
		end
	end
	for i = 1, math.min(math.floor(n), #FAKE_SQUAD) do
		table.insert(out, FAKE_SQUAD[i])
	end
	return out
end

local function updateSquad()
	if not ui.root then
		return
	end
	local realSquad = Store.get("squad")
	local squad = withFakeSquad(realSquad)
	Style.setSquad(squad, player.UserId)
	if ui.callsign then
		local me = Style.callsign(player.UserId)
		ui.callsign.Text = me.tag
		ui.callsign.TextColor3 = me.color
	end
	SquadCards.update(squad, Store.get("me"), Store.get("mission"), player.UserId, now())
	SquadCards.setVisible(COMBAT[state] == true or state == "Drop")
	SquadComms.onSquad(realSquad)
end

-- Call-in bar -------------------------------------------------------------------------------------------------------------
-- The top-left call-in list lives in UI/CallInList.
local function updateCallins()
	local me = Store.get("me")
	if me then
		CallInList.update(me, now())
	end
end

-- Area info panel (zone, objective + distance, threat, extraction): mission / objectives / intensity from the Store.
local function updateArea()
	local m = Store.get("mission")
	if m then
		AreaInfo.update(m, Store.get("objectives"), Store.get("intensity"), now())
	end
end

-- Ammo / health ------------------------------------------------------------------------------------------------------------
local function updateAmmo()
	local me = Store.get("me")
	if not me then
		return
	end
	local entry = me.weapons and me.weapons[me.weapon or 1]
	local def = entry and Weapons.get(entry.id)
	ui.ammoName.Text = def and string.upper(def.name) or ""
	if ui.ammoAp then
		local hasDmg = def and ((def.damage and def.damage > 0) or (def.splash and def.splash.damage and def.splash.damage > 0))
		if def and (hasDmg or (def.ap or 0) > 0) then
			ui.ammoAp.Text = Damage.apLabel(def.ap or 0)
			ui.ammoAp.Visible = true
		else
			ui.ammoAp.Text = ""
			ui.ammoAp.Visible = false
		end
	end
	if entry then
		local mag, spare = entry.mag or 0, entry.spare or 0
		local predicted = localMags and localMags[me.weapon or 1]
		if type(predicted) == "number" then
			mag = math.min(mag, predicted) -- the server publish lags the local shots
		end
		ui.ammoMag.Text = tostring(mag)
		ui.ammoSpare.Text = "/ " .. tostring(spare)
		local maxMag = def and def.mag or 1
		magTarget = Theme.clamp(mag / math.max(maxMag, 1), 0, 1)
		if entry.id ~= ammoLastId then
			magShown = magTarget
		end
		-- reload finished (same weapon, magazine jumped up): count the number up quickly
		if entry.id == ammoLastId and mag > ammoLastMag + 1 and maxMag > 1 then
			ammoFill = { from = ammoLastMag, to = mag, t0 = os.clock() }
		elseif entry.id ~= ammoLastId then
			ammoFill = nil
		end
		ammoLastId, ammoLastMag = entry.id, mag
		ammoLow = maxMag > 1 and mag <= math.max(1, maxMag * 0.25)
		if mag <= 0 then
			ui.ammoMag.TextColor3 = Style.Red
			ui.ammoState.Text = reloadProgress and "" or "RELOAD"
		elseif mag <= math.max(1, maxMag * 0.25) then
			ui.ammoMag.TextColor3 = Style.Amber
			ui.ammoState.Text = ""
		else
			ui.ammoMag.TextColor3 = Style.White
			ui.ammoState.Text = ""
		end
		-- reserve (server/WeaponService MAGS): `spare` = whole magazines left ("x6"); per-shell loaders count shells;
		-- MAGS "pool" shows rounds (+ the loose rounds in player attribute AmmoLoose<slot>); "keep" names the part-used
		-- magazines (AmmoParts<slot>). Low = one magazine or less left: amber; none: red.
		local slotN = me.weapon or 1
		local loose = player:GetAttribute("AmmoLoose" .. slotN)
		local parts = player:GetAttribute("AmmoParts" .. slotN)
		local empty, spareLow
		if def and def.perShellReload then
			ui.ammoSpare.Text = "/ " .. tostring(spare)
			ui.cntMags.Text = "SHELL " .. tostring(spare)
			empty, spareLow = spare <= 0, spare <= maxMag
		elseif type(loose) == "number" then
			local rounds = spare * maxMag + loose
			ui.ammoSpare.Text = "/ " .. tostring(rounds)
			ui.cntMags.Text = "MAG " .. tostring(math.ceil(rounds / math.max(maxMag, 1)))
			empty, spareLow = rounds <= 0, rounds <= maxMag
		else
			ui.ammoSpare.Text = "x" .. tostring(spare)
			ui.cntMags.Text = "MAG " .. tostring(spare) .. (if type(parts) == "number" and parts > 0 then string.format(" (%d PART)", parts) else "")
			empty, spareLow = spare <= 0, spare <= 1
		end
		ui.cntMags.TextColor3 = if empty then Style.Red elseif spareLow then Style.Amber else Style.White
		ui.ammoSpare.TextColor3 = if empty then Style.Red elseif spareLow then Style.Amber else Style.Grey
		ammoLastSpare, ammoLastMax = (if empty then 0 else 1), (def and def.mag or 0)
	else
		ammoLastId, ammoLastMax = nil, 0
	end
	updateReloadPrompt()
	local g = me.grenades or 0
	ui.cntNade.Text = "GREN " .. tostring(g)
	ui.cntNade.TextColor3 = if g <= 0 then Style.Grey else Style.Amber
	local stims = me.stims
	ui.cntStim.Visible = type(stims) == "number"
	if type(stims) == "number" then
		ui.cntStim.Text = string.format("STIM x%d/%d", stims, me.stimsMax or Config.Stims.Max)
		ui.cntStim.TextColor3 = if stims <= 0 then Style.Red else Style.Amber
	end
	if newLayout then
		WeaponBlock.setGrenades(g)
	end
end

-- WeaponController: its predicted magazine table (same table every call; read by reference).
function HUD.setLocalMag(t: { [number]: number })
	localMags = t
	if inited and ui.ammoMag then
		updateAmmo()
	end
end

-- magazine reserve attributes (server/WeaponService MAGS "pool" / "keep") change without a `me` publish
for i = 1, 3 do
	for _, a in { "AmmoLoose", "AmmoParts" } do
		player:GetAttributeChangedSignal(a .. i):Connect(function()
			if inited and ui.ammoMag then
				updateAmmo()
			end
		end)
	end
end

-- WeaponController: fire mode of the held weapon next to the ammo counter ("AUTO" / "BURST" / "SEMI"). Hidden when
-- the weapon has only one mode; `flash` = just switched (short white pop).
local FIRE_MODE_TEXT = { auto = "AUTO", burst = "BURST", semi = "SEMI" }
local fireModeShown: string? = nil
local fireModeLast: { mode: string?, switchable: boolean }? = nil -- re-shown after HUD.rebuild
function HUD.setFireMode(mode: string?, switchable: boolean, flash: boolean?)
	fireModeLast = { mode = mode, switchable = switchable }
	local fm = ui.fireMode
	if not fm then
		return
	end
	local text = if mode and switchable then (FIRE_MODE_TEXT[mode] or string.upper(mode)) else ""
	if text ~= fireModeShown then
		fireModeShown = text
		fm.Text = text
	end
	if flash then
		fm.TextColor3 = Style.White
		tw(fm, 0.35, { TextColor3 = Style.Grey })
	end
end

local function updateHealth()
	local me = Store.get("me")
	if not me then
		return
	end
	local hp, maxHp = me.hp or 0, math.max(me.maxHp or Config.PlayerHealth, 1)
	local frac = Theme.clamp(hp / maxHp, 0, 1)
	if newLayout then
		Vitals.set(me)
		hpFrac = frac
		lastHp = hp
		return
	end
	tw(ui.hpFill, 0.12, { Size = UDim2.fromScale(frac, 1) })
	-- colour (red when critical, pulsing; green tint while a stim heals) is set per frame in step()
	ui.hpText.Text = me.alive == false and "DOWN" or string.format("%d / %d", math.ceil(hp), maxHp)
	if lastHp and hp < lastHp - 0.5 then
		flash = math.max(flash, math.min(1, (lastHp - hp) / maxHp * 3 + 0.3))
	end
	-- ghost chunk: on damage it keeps the old value for a moment, then drains (step); on heal it snaps under the fill
	if frac < hpFrac - 0.001 then
		ghostFrac = math.max(ghostFrac, hpFrac)
		ghostHold = os.clock() + 0.45
	end
	hpFrac = frac
	if ghostFrac < frac then
		ghostFrac = frac
	end
	lastHp = hp
end

-- Ship HUD -------------------------------------------------------------------------------------------------------------------
local function updateShip()
	local p = Store.get("profile")
	if not p or not ui.shipRank then
		return
	end
	ui.shipRank.Text = "RANK " .. tostring(p.rank or 1)
	local need = math.max(p.xpNext or Config.xpForRank(p.rank or 1), 1)
	ui.shipXpBar:set((p.xp or 0) / need, true)
	ui.shipXpText.Text = string.format("%s / %s XP", Theme.formatNumber(p.xp or 0), Theme.formatNumber(need))
	ui.shipSalvage.Text = string.format('<font color="%s">SALV</font> %s', Theme.hex(C.Accent), Theme.formatNumber(p.salvage or 0))
	ui.shipTokens.Text = string.format('<font color="%s">TKN</font> %s', Theme.hex(C.Friendly), Theme.formatNumber(p.tokens or 0))
	ui.shipSalvage.RichText = true
	ui.shipTokens.RichText = true
end

-- Timer / lives ------------------------------------------------------------------------------------------------------------------
local function updateTimer()
	local m = Store.get("mission")
	if not m then
		return
	end
	local t = now()
	if state == "Active" or state == "Extract" then
		local left = math.max(0, (m.endsAt or t) - t)
		local col = Style.White
		if state == "Active" and left < 120 then
			col = if math.floor(t * 2) % 2 == 0 then Style.Red else Style.Amber
		elseif state == "Extract" then
			col = Style.Green
		end
		TopRight.setTimer((if newLayout then "" else "T-") .. Theme.formatTime(left), col)
		TopRight.setLives(m.lives or 0)
	end
end

-- Visibility by mission state --------------------------------------------------------------------------------------------------------------
local function applyVisibility()
	local combat = COMBAT[state] == true
	local drop = state == "Drop"
	local ship = state == "Ship" or state == "Countdown"
	local me = Store.get("me")
	local alive = not me or me.alive ~= false
	ui.cross.Visible = combat and alive and not Store.get("menuOpen")
	ui.markerLayer.Visible = combat
	Compass.setVisible(combat)
	TopRight.setVisible(combat)
	CallInList.setVisible(combat)
	AreaInfo.setVisible(combat)
	if newLayout then
		Vitals.setVisible(combat)
		WeaponBlock.setVisible(combat)
	else
		ui.ownCard.Visible = combat
	end
	EventFeed.setVisible(combat)
	PickupToast.setVisible(combat)
	ContextPrompt.setVisible(combat and alive and not Store.get("menuOpen"))
	updateReloadPrompt()
	SquadComms.setActive(combat)
	if not combat then
		EventFeed.clear()
		PickupToast.clear()
	end
	ui.shipPanel.Visible = ship
	ObjectiveList.setVisible((combat or drop) and #(Store.get("objectives") or {}) > 0)
	updateSquad()
	if not combat then
		ui.promptFrame.Visible = false
		ui.reloadBar.Visible = false
		ui.reloadLabel.Visible = false
	end
	ui.ovCountdown.Visible = state == "Countdown"
	ui.ovDrop.Visible = drop
	if not (state == "Results" or state == "Failed") then
		ui.ovResults.Visible = false
		resultsShown = nil
		resultsToken += 1
	end
end

-- Overlay: countdown / drop / results ---------------------------------------------------------------------------------------------------------------
local function buildOverlay()
	local gui = Theme.gui("OrbitOverlay", { DisplayOrder = 40, Insets = "DeviceSafeInsets" })
	ui.ovGui = gui
	local root = Theme.root(gui, "hud")

	-- countdown
	local cd = Instance.new("Frame")
	cd.Name = "Countdown"
	cd.BackgroundTransparency = 1
	cd.Size = UDim2.fromScale(1, 1)
	cd.Visible = false
	cd.Parent = root
	local dim = Instance.new("Frame")
	dim.BackgroundColor3 = C.Dark
	dim.BackgroundTransparency = 0.55
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = cd
	ui.cdTitle = Theme.label({
		Text = "DEPLOYING IN",
		Font = "Header",
		TextSize = touch and 18 or 24,
		Color = C.Accent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.34),
		Size = UDim2.fromOffset(500, 30),
		Parent = cd,
	})
	ui.cdNumber = Theme.label({
		Text = "10",
		Font = "Black",
		TextSize = touch and 110 or 170,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(400, 200),
		Parent = cd,
	})
	ui.cdNumberScale = Instance.new("UIScale")
	ui.cdNumberScale.Parent = ui.cdNumber
	ui.cdInfo = Theme.label({
		Text = "",
		Font = "Body",
		TextSize = touch and 14 or 20,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.68),
		Size = UDim2.fromOffset(700, 30),
		Parent = cd,
	})
	ui.ovCountdown = cd

	-- drop
	local drop = Instance.new("Frame")
	drop.Name = "Drop"
	drop.BackgroundTransparency = 1
	drop.Size = UDim2.fromScale(1, 1)
	drop.Visible = false
	drop.Parent = root
	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = C.Dark
		bar.BackgroundTransparency = 0.1
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, top and 0 or 1)
		bar.Position = UDim2.fromScale(0, top and 0 or 1)
		bar.Size = UDim2.new(1, 0, 0, touch and 50 or 90)
		bar.Parent = drop
		local line = Instance.new("Frame")
		line.BackgroundColor3 = C.Accent
		line.BorderSizePixel = 0
		line.AnchorPoint = Vector2.new(0, top and 1 or 0)
		line.Position = UDim2.fromScale(0, top and 1 or 0)
		line.Size = UDim2.new(1, 0, 0, 3)
		line.Parent = bar
	end
	ui.dropTitle = Theme.label({
		Text = "DROP CAPSULE ENGAGED",
		Font = "Header",
		TextSize = touch and 16 or 24,
		Color = C.Accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, touch and 14 or 28),
		Size = UDim2.fromOffset(700, 30),
		Parent = drop,
	})
	ui.dropAlt = Theme.label({
		Text = "",
		Font = "Black",
		TextSize = touch and 22 or 34,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, touch and -10 or -20),
		Size = UDim2.fromOffset(500, 46),
		Parent = drop,
	})
	ui.ovDrop = drop

	-- results
	local res = Instance.new("Frame")
	res.Name = "Results"
	res.BackgroundTransparency = 1
	res.Size = UDim2.fromScale(1, 1)
	res.Visible = false
	res.Parent = root
	ui.ovResults = res
end

local function countUp(label: TextLabel, target: number, duration: number, token: number, prefix: string?, delayT: number?)
	task.spawn(function()
		if delayT then
			task.wait(delayT)
		end
		local t0 = os.clock()
		while token == resultsToken and label.Parent do
			local a = Theme.clamp((os.clock() - t0) / duration, 0, 1)
			a = 1 - (1 - a) ^ 3
			label.Text = (prefix or "") .. Theme.formatNumber(target * a)
			if a >= 1 then
				break
			end
			task.wait()
		end
	end)
end

local function showResults()
	local m = Store.get("mission")
	if not m then
		return
	end
	local r = m.results
	local failedState = state == "Failed"
	local success = r and r.success == true and not failedState
	resultsToken += 1
	local token = resultsToken
	resultsShown = { r, state }
	local host = ui.ovResults
	for _, c in host:GetChildren() do
		c:Destroy()
	end
	host.Visible = true
	local dim = Instance.new("Frame")
	dim.BackgroundColor3 = C.Dark
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = host
	tw(dim, 0.5, { BackgroundTransparency = 0.35 })

	local col = success and C.Friendly or C.Danger
	local panel = Theme.panel({
		Color = C.Navy,
		Accent = col,
		Stroke = col,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(560, r and 380 or 230),
		Parent = host,
	})
	local scale = Instance.new("UIScale")
	scale.Scale = 0.85
	scale.Parent = panel
	tw(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	Theme.pad(panel, 20, 16, 20, 16)

	Theme.label({
		Text = success and "MISSION SUCCESS" or "MISSION FAILED",
		Font = "Header",
		TextSize = touch and 26 or 32,
		Color = col,
		Size = UDim2.new(1, 0, 0, 44),
		Parent = panel,
	})
	Theme.sfx(success and "MissionSuccess" or "MissionFail")

	local sub = (r and r.bonusText) or (success and "Excellent work, troopers. The Skiff is home." or "The squad was lost. Regroup on the ship.")
	if success and not (r and r.bonusText) then
		sub = "Squad extracted. Rewards secured."
	end
	if not success and not (r and r.bonusText) then
		sub = r and "Partial rewards recovered (" .. math.floor(Config.FailRewardScale * 100) .. "%)." or "The squad was lost. Regroup on the ship."
	end
	Theme.label({
		Text = sub,
		Font = "Medium",
		TextSize = touch and 13 or 16,
		Color = C.Muted,
		Wrap = true,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 46),
		Parent = panel,
	})

	if r then
		local grid = Instance.new("Frame")
		grid.BackgroundTransparency = 1
		grid.Position = UDim2.fromOffset(0, 80)
		grid.Size = UDim2.new(1, 0, 0, 150)
		grid.Parent = panel
		local gl = Instance.new("UIGridLayout")
		gl.CellSize = UDim2.new(0.5, -6, 0, 68)
		gl.CellPadding = UDim2.fromOffset(12, 12)
		gl.SortOrder = Enum.SortOrder.LayoutOrder
		gl.Parent = grid
		local stats = {
			{ "SALVAGE", r.salvage or 0, C.Accent, "cog" },
			{ "XP", r.xp or 0, C.Friendly, "star" },
			{ "BOND TOKENS", r.tokens or 0, C.Gold, "token" },
			{ "KILLS", r.kills or 0, C.Text, "cross" },
		}
		for i, s in stats do
			local tile = Theme.panel({ Color = C.Panel, Corner = 8, Stroke = s[3], StrokeTransparency = 0.5, LayoutOrder = i, Parent = grid })
			Style.glyph(s[4], { Size = 12, Color = s[3], Box = UDim2.fromOffset(14, 18), Position = UDim2.fromOffset(10, 6), Parent = tile })
			Theme.label({
				Text = s[1],
				Font = "Header",
				TextSize = 11,
				Color = s[3],
				XAlign = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -34, 0, 18),
				Position = UDim2.fromOffset(28, 6),
				Parent = tile,
			})
			local val = Theme.label({
				Text = "0",
				Font = "Black",
				TextSize = 30,
				XAlign = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -16, 0, 36),
				Position = UDim2.fromOffset(10, 26),
				Parent = tile,
			})
			countUp(val, s[2], 1.1, token, i < 4 and "+" or "", 0.25 + 0.15 * i)
		end
		if r.rankUp then
			local rk = Theme.panel({
				Color = C.Gold,
				Transparency = 0.1,
				Stroke = C.White,
				Size = UDim2.new(1, 0, 0, 36),
				Position = UDim2.fromOffset(0, 244),
				Parent = panel,
			})
			local newRank = (type(r.rankUp) == "number") and r.rankUp or ((Store.get("profile") or {}).rank or 0)
			Theme.label({
				Text = "RANK UP!  RANK " .. tostring(newRank),
				Font = "Header",
				TextSize = 16,
				Color = C.Dark,
				NoStroke = true,
				Size = UDim2.fromScale(1, 1),
				Parent = rk,
			})
			task.delay(1.0, function()
				if token == resultsToken then
					Theme.sfx("RankUp")
				end
			end)
		end
	end
	ui.resultsFooter = Theme.label({
		Text = "",
		Font = "Medium",
		TextSize = 14,
		Color = C.Muted,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = panel,
	})
end

local function updateOverlay()
	if state == "Countdown" then
		local m = Store.get("mission")
		local n = math.max(0, math.ceil((m.endsAt or now()) - now()))
		if n ~= countdownLast then
			countdownLast = n
			ui.cdNumber.Text = tostring(n)
			ui.cdNumberScale.Scale = 1.4
			tw(ui.cdNumberScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			ui.cdNumber.TextColor3 = n <= 3 and C.Accent or C.Text
			Theme.sfx("DialTick")
			local f = m.faction == "BROOD" and "Skitter Brood"
				or (m.faction == "COG" and "Cogwork Legion" or (m.faction == "LUMEN" and "Lumen Concord" or ""))
			ui.cdInfo.Text = string.format("%s   -   %s   -   Difficulty %s", m.objectiveName or "Mission", f, tostring(m.difficulty or 1))
		end
	elseif state == "Drop" then
		altAcc += 1
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { char }
			local hit = workspace:Raycast(root.Position, Vector3.new(0, -2500, 0), params)
			local alt = hit and (root.Position.Y - hit.Position.Y) or 0
			ui.dropAlt.Text = string.format("ALT  %d m", math.max(0, math.floor(alt * 0.28)))
			if alt < 70 then
				ui.dropTitle.Text = "BRACE FOR IMPACT"
				ui.dropTitle.TextColor3 = (math.floor(os.clock() * 4) % 2 == 0) and C.Danger or C.Gold
			else
				ui.dropTitle.Text = "DROP CAPSULE ENGAGED"
				ui.dropTitle.TextColor3 = C.Accent
			end
		end
	elseif state == "Results" or state == "Failed" then
		local m = Store.get("mission")
		if resultsShown == nil or resultsShown[1] ~= (m and m.results) or resultsShown[2] ~= state then
			showResults()
		end
		if ui.resultsFooter and ui.resultsFooter.Parent and m then
			local left = math.max(0, (m.endsAt or now()) - now())
			ui.resultsFooter.Text = left > 0 and string.format("Returning to %s in %d s", Config.ShipName, math.ceil(left)) or ""
		end
	end
end

-- Prompt (beacon holding) ------------------------------------------------------------------------------------------------------------
local function updatePrompt()
	local me = Store.get("me")
	local holding = (me and me.callins and me.callins.holding) or Store.get("holding")
	if holding and COMBAT[state] then
		local h = type(holding) == "table" and holding or {}
		local def = h.id and CallIns.get(h.id)
		local col = def and Theme.beaconColor(def.beacon) or C.Accent
		if h.perfect then
			col = C.Gold
		end
		ui.promptFrame.Visible = true
		ui.promptTitle.TextColor3 = col
		ui.promptTitle.Text = "THROW BEACON"
		local hint = touch and "Tap FIRE to throw" or (Store.get("throwHint") or "Left-click or [Q] to throw") -- throwHint: CallInController (arm method + PC/pad)
		-- phones (PHONE HUD A): the prompt is 220 px wide, so the hint gets its own line
		ui.promptSub.Text = (def and string.upper(def.name) or "") .. (h.perfect and "  -  PERFECT SYNC" or "") .. (if phoneNew() then "\n" else "   ") .. hint
	else
		ui.promptFrame.Visible = false
	end
end

-- Compass / world markers (per frame) ---------------------------------------------------------------------------------------------------
local function stepMarkers(cam: Camera)
	local vp = cam.ViewportSize
	local cx, cy = vp.X / 2, vp.Y / 2
	local margin = 56
	local camPos = cam.CFrame.Position
	for _, m in markers do
		local v = cam:WorldToViewportPoint(m.pos)
		local x, y = v.X, v.Y
		local front = v.Z > 0
		if not front then
			x = vp.X - x
			y = vp.Y - y
		end
		local onScreen = front and x > margin and x < vp.X - margin and y > margin and y < vp.Y - margin
		if not onScreen then
			local dx, dy = x - cx, y - cy
			if dx == 0 and dy == 0 then
				dy = 1
			end
			local t = math.min((cx - margin) / math.max(math.abs(dx), 1e-3), (cy - margin) / math.max(math.abs(dy), 1e-3))
			x = cx + dx * t
			y = cy + dy * t
		end
		m.world.Visible = true
		m.world.Position = UDim2.fromOffset(x, y)
		-- distance label: found once, rewritten only when the whole-metre value changes (a Text write re-lays out the label)
		local dl = m.distLabel
		if dl == nil or dl.Parent == nil then
			dl = m.world:FindFirstChild("Dist")
			m.distLabel = dl
			m.distShown = nil
		end
		if dl then
			local metres = math.floor((m.pos - camPos).Magnitude + 0.5)
			if metres ~= m.distShown then
				m.distShown = metres
				dl.Text = string.format("%d m", metres)
			end
		end
	end
end

-- crosshair satellites, per frame (new layout; writes only when something shown changes)
local function stepSatellites(combat: boolean)
	local magL, arc = ui.satMag, ui.satArc
	if not magL or not arc then
		return
	end
	local mode = workspace:GetAttribute("Feel_XhairInfo")
	local me = Store.get("me")
	local alive = me ~= nil and me.alive ~= false
	local on = combat and alive and mode ~= "off"
	local always = mode == "always"
	-- mag count: magazine at 30 % or less, or reloading
	local lowMag = ammoLastMax > 1 and ammoLastMag <= math.ceil(ammoLastMax * 0.3)
	local showMag = on and ammoLastId ~= nil and (always or lowMag or reloadProgress ~= nil)
	local magText = if reloadProgress ~= nil and not charging then "R" else tostring(ammoLastMag)
	local magDanger = ammoLastMag <= math.max(1, ammoLastMax * 0.25)
	-- health arc: under 50 %
	local f = Vitals.frac()
	local showArc = on and (always or f < 0.5)
	local n = #ui.satDots
	local lit = math.ceil(Theme.clamp(f, 0, 1) * n - 0.001)
	local crit = f < Config.Stims.Critical
	local sig = string.format("%s|%s|%s|%s|%d|%s", tostring(showMag), magText, tostring(magDanger), tostring(showArc), lit, tostring(crit))
	if sig == ui.satShown then
		return
	end
	ui.satShown = sig
	magL.Visible = showMag
	magL.Text = magText
	magL.TextColor3 = if magDanger then HudSkin.color("danger") else HudSkin.color("text")
	arc.Visible = showArc
	local col = if crit then HudSkin.color("danger") else HudSkin.color("text")
	for i, d in ui.satDots do
		d.BackgroundColor3 = col
		d.BackgroundTransparency = if i <= lit then 0.1 else 0.8
	end
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	local combat = COMBAT[state] == true
	if newLayout then
		Vitals.step(dt, now())
		stepSatellites(combat)
	end
	if combat and cam then
		local ppd = cam.ViewportSize.Y / math.max(cam.FieldOfView, 1)
		local target = Theme.clamp(spreadDeg * ppd + 5, 5, 170)
		hitKick *= math.exp(-16 * dt)
		gap += (target + hitKick - gap) * (1 - math.exp(-22 * dt))
		if gap ~= gapShown then
			gapShown = gap
			for _, t in ui.ticks do
				local off = gap + t.half
				t.frame.Position = UDim2.fromOffset(t.dir.X * off, t.dir.Y * off)
			end
		end
		Compass.step(cam, markers)
		stepMarkers(cam)
		AreaInfo.step(cam)
		ObjectiveList.step(cam)
		if ui.promptFrame.Visible then
			ui.promptScale.Scale = 1 + 0.06 * math.sin(os.clock() * 7)
		end
		if reloadProgress ~= nil then
			ui.reloadLabel.TextTransparency = 0.2 + 0.3 * math.abs(math.sin(os.clock() * 6))
		end
	end
	stepBarrel(dt, combat)
	-- ammo number: red pulse when the magazine is low, count-up + pop after a reload
	if combat and ui.ammoMag then
		local scale = ui.ammoScale
		if not scale then
			scale = Instance.new("UIScale")
			scale.Parent = ui.ammoMag
			ui.ammoScale = scale
		end
		local s = 1
		local fillT = ammoFill and (os.clock() - ammoFill.t0) / 0.3
		if ammoFill and fillT and fillT < 1 then
			local u = 1 - (1 - fillT) * (1 - fillT)
			ui.ammoMag.Text = tostring(math.floor(ammoFill.from + (ammoFill.to - ammoFill.from) * u + 0.5))
			s = 1 + 0.14 * math.sin(fillT * math.pi)
			ui.ammoMag.TextColor3 = C.Friendly:Lerp(C.Text, fillT)
		elseif ammoFill then
			ammoFill = nil
			updateAmmo()
		elseif ammoLow and ammoLastMag <= 0 then
			ui.ammoMag.TextColor3 = Style.Red -- empty: solid red (the reload prompt carries the call to action)
		elseif ammoLow then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
			ui.ammoMag.TextColor3 = C.Text:Lerp(C.Danger, 0.45 + 0.55 * pulse)
			s = 1 + 0.06 * pulse
		end
		-- per-shot tick: quick pop + a pixel of shake, decaying in ~0.12 s (halved from the first pass)
		shotKick = math.max(0, shotKick - dt * 8)
		s *= 1 + 0.045 * shotKick
		local base = ui.ammoMagPos
		if base then
			if shotKick > 0 then
				local j = 1.2 * shotKick
				ui.ammoMag.Position = base + UDim2.fromOffset(jitterRng:NextNumber(-j, j), jitterRng:NextNumber(-j, j) * 0.6)
			elseif ui.ammoMag.Position ~= base then
				ui.ammoMag.Position = base
			end
		end
		scale.Scale = s
		-- magazine segments: eased drain; while reloading they fill with the reload progress in amber
		if ui.magSegs then
			local target = magTarget
			local col = Style.White
			if reloadProgress ~= nil and not charging then
				target = Theme.clamp(reloadProgress, 0, 1)
				col = Style.Amber
			elseif ammoLow then
				col = Style.Red
			end
			magShown += (target - magShown) * (1 - math.exp(-18 * dt))
			local lit = math.ceil(Theme.clamp(magShown, 0, 1) * MAG_SEGS - 0.001)
			-- the 20 segments are only rewritten when the lit count or its colour changes (the bar is steady most of the time)
			if lit ~= segLit or col ~= segCol or ui.magSegs ~= segTable then
				segLit, segCol, segTable = lit, col, ui.magSegs
				for i, seg in ui.magSegs do
					if i <= lit then
						seg.BackgroundColor3 = col
						seg.BackgroundTransparency = 0.05
					else
						seg.BackgroundColor3 = Style.White
						seg.BackgroundTransparency = 0.8
					end
				end
			end
		end
	end
	-- health bar (the screen-edge damage effects live in Fx/VitalsFx): red + heartbeat pulse when critical, green tint
	-- while a stim heals, ghost chunk drain, a white stroke flash on each hit
	flash = math.max(0, flash - dt * 2.5)
	local me = Store.get("me")
	if combat and ui.hpFill then
		local crit = Config.Stims.Critical
		local alive = me and me.alive ~= false
		local col = Style.White
		local fillAlpha = 0
		local strokeCol = Style.White
		local strokeAlpha = 0.7 - 0.6 * math.min(flash, 1)
		if alive and hpFrac < crit then
			-- heartbeat: a strong "lub" then a softer "dub", faster the lower the health
			local beat = (os.clock() * (1.1 + (crit - hpFrac) / crit * 1.2)) % 1
			local pulse = math.max(math.exp(-((beat - 0.08) / 0.07) ^ 2), 0.65 * math.exp(-((beat - 0.32) / 0.08) ^ 2))
			col = Style.Red:Lerp(Color3.fromRGB(255, 120, 110), pulse * 0.6)
			fillAlpha = 0.25 * (1 - pulse)
			strokeCol = Style.Red
			strokeAlpha = math.min(strokeAlpha, 0.6 - 0.5 * pulse)
		end
		if alive and me and (me.stimEnd or 0) > now() then
			local k = 0.55 + 0.25 * math.sin(os.clock() * 14)
			col = col:Lerp(Style.Green, k)
		end
		ui.hpFill.BackgroundColor3 = col
		ui.hpFill.BackgroundTransparency = fillAlpha
		if ui.hpStroke then
			ui.hpStroke.Color = strokeCol
			ui.hpStroke.Transparency = strokeAlpha
		end
		-- ghost: hold, then ease down to the real value
		if os.clock() >= ghostHold and ghostFrac > hpFrac then
			ghostFrac = math.max(hpFrac, ghostFrac - dt * 0.9 - (ghostFrac - hpFrac) * (1 - math.exp(-6 * dt)))
		end
		if math.abs(ghostFrac - ghostShown) > 0.0005 and ui.hpGhost then
			ghostShown = ghostFrac
			ui.hpGhost.Size = UDim2.fromScale(Theme.clamp(ghostFrac, 0, 1), 1)
		end
	end
end

-- Init ------------------------------------------------------------------------------------------------------------------------------------------
local function onMission()
	local new = missionState()
	local m = Store.get("mission")
	if new ~= state then
		prevState = state
		state = new
		countdownLast = -1
		if new == "Active" and (prevState == "Drop" or prevState == "Countdown") then
			HUD.banner(string.upper((m and m.objectiveName) or "MISSION START"), touch and "Tap UPLINK to call the sky down" or (Store.get("dialHint") or "Hold [Q] for the Uplink Dial"), C.Accent) -- dialHint: CallInController (arm method + PC/pad)
		elseif new == "Extract" then
			HUD.banner("EXTRACTION INBOUND", "Reach the " .. Config.ShuttleName .. " before the window closes", C.Friendly)
		end
		if new ~= "Active" and new ~= "Extract" then
			ObjectiveList.reset()
		end
	end
	applyVisibility()
	updateObjectives()
	updateTimer()
	updateOverlay()
	updateArea()
end

function HUD.init()
	if inited then
		return
	end
	inited = true
	touch = Theme.isTouch()

	AlertBar.init()
	buildCrosshair()
	buildStreak()
	buildMain()
	-- keys the overlay gui owns (kept across HUD.rebuild)
	local before = {}
	for k in ui do
		before[k] = true
	end
	buildOverlay()
	for k in ui do
		if not before[k] then
			overlayKeys[k] = true
		end
	end

	state = missionState()

	-- kill streak: listen to the Fx core's Death event; Audio for the milestone chime. Both are already loaded by Main.
	local clientRoot = script.Parent.Parent
	local okFx, fx = pcall(function()
		return require(clientRoot:WaitForChild("Fx", 5))
	end)
	if okFx and type(fx) == "table" and fx.register then
		fxMod = fx
		fx.register("Death", onKill)
		SquadComms.init(fx)
	end
	local okA, am = pcall(function()
		return require(clientRoot:WaitForChild("Audio", 5))
	end)
	if okA then
		audioMod = am
	end
	Store.on("mission", function(m)
		local s = m and m.state
		if s ~= "Active" and s ~= "Extract" then
			missionKills, streak, streakLast = 0, 0, -100
			TopRight.setResource("kills", 0)
		end
	end)

	Store.on("mission", onMission)
	Store.on("me", function(me)
		updateAmmo()
		updateHealth()
		updateCallins()
		updatePrompt()
		applyVisibility()
		SquadComms.onMe(me)
	end)
	Store.on("holding", updatePrompt)
	Store.on("objectives", updateObjectives)
	Store.on("objectives", updateArea)
	Store.on("squad", updateSquad)
	if RunService:IsStudio() then
		workspace:GetAttributeChangedSignal("DebugFakeSquad"):Connect(updateSquad)
	end
	Store.on("profile", updateShip)
	Store.on("menuOpen", applyVisibility)

	Net.event("Notify").OnClientEvent:Connect(function(text: string, color: Color3?, kind: string?)
		if type(text) ~= "string" then
			return
		end
		if kind == "banner" then
			HUD.banner(text, nil, color)
		elseif (kind == "comms" or kind == "ship") and COMBAT[state] and SquadTags.feed(text, color) then
			-- haul callouts "<name>: <line>" + HALCYON drop-in announcements -> event feed (UI/SquadTags)
		elseif COMBAT[state] and PickupToast.route(text) then
			Theme.sfx("Notify") -- pickup: orange toast at the right edge
		elseif COMBAT[state] and EventFeed.route(text, color, kind) then
			-- DIED / reinforced lines live in the bottom-right event feed
		else
			HUD.toast(text, color)
			Theme.sfx("Notify")
		end
	end)

	RunService.RenderStepped:Connect(step)
	Theme.every(0.1, function()
		updateCallins()
		updateTimer()
		updateOverlay()
		updateArea()
		SquadCards.tick(Store.get("me"), Store.get("mission"), now())
		EventFeed.tick()
	end)

	onMission()
	updateAmmo()
	updateHealth()
	updateCallins()
	updateShip()
	updateSquad()
	updatePrompt()

	-- UI STYLE / HUD preset switch (Studio Variants): rebuild live
	workspace:GetAttributeChangedSignal(HudSkin.ATTR):Connect(function()
		task.defer(HUD.rebuild)
	end)
	workspace:GetAttributeChangedSignal(HudLayout.ATTR):Connect(function()
		task.defer(HUD.rebuild)
	end)
	HudSkin.fireRebuild({ skin = HudSkin.current(), id = HudSkin.id(), touch = touch, gui = ui.mainGui, root = ui.root, first = true })
end

-- Destroys the main HUD + crosshair layer and builds them again in the current UI STYLE skin (old HUD for option D),
-- then pushes the Store values again. The overlay gui (countdown / drop / results) stays. Other guis follow through
-- AlertBar.rebuild and HudSkin.onRebuild listeners (DownedFx, StaminaBar, the information modules).
local rebuilding = false
local function doRebuild()
	Style.refreshSkin()
	for _, g in { ui.mainGui, ui.crossGui } do
		if g then
			g:Destroy()
		end
	end
	for k in table.clone(ui) do
		if not overlayKeys[k] and k ~= "resultsFooter" then
			ui[k] = nil
		end
	end
	-- caches of what was written to the old widgets
	gapShown = -1
	segLit, segCol, segTable = -1, nil, nil
	ghostShown = -1
	barrelShownRing, barrelShownPos, barrelShownD, barrelShownWarn, barrelShownStroke = nil, nil, -1, -1, nil
	table.clear(hmPool)
	hmIndex = 1
	for _, t in streakTweens do
		t:Cancel()
	end
	table.clear(streakTweens)
	streakGen += 1
	fireModeShown = nil
	ammoLastId = nil
	ammoFill = nil

	AlertBar.rebuild()
	buildCrosshair()
	buildStreak()
	buildMain()

	applyVisibility()
	updateObjectives()
	updateTimer()
	updateArea()
	updateAmmo()
	updateHealth()
	updateCallins()
	updateShip()
	updateSquad()
	updatePrompt()
	HUD.refreshMarkers()
	if fireModeLast then
		HUD.setFireMode(fireModeLast.mode, fireModeLast.switchable)
	end
	if reloadProgress ~= nil then
		HUD.setReload(reloadProgress)
	end
	HudSkin.fireRebuild({ skin = HudSkin.current(), id = HudSkin.id(), touch = touch, gui = ui.mainGui, root = ui.root, first = false })
end

function HUD.rebuild()
	if not inited or rebuilding then
		return
	end
	rebuilding = true
	local ok, err = pcall(doRebuild)
	rebuilding = false
	if not ok then
		warn("HUD.rebuild: " .. tostring(err))
	end
end

function HUD.isCombat(): boolean
	return COMBAT[state] == true
end

return HUD
