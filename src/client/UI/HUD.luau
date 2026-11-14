-- All in-mission and ship HUD. Call HUD.init() once after Store/Input exist.
-- Store keys read: me, mission, objectives, squad, profile, holding, menuOpen (all optional).
-- Thin edge HUD (style kit: UI/HudStyle). Widgets:
--   top-left   UI/CallInList (UPLINK list, icons only on touch) (+ ship info on the ship)  reads me.callins, me.reinforceReadyAt
--   top-centre UI/Compass tape (+ markers) and UI/AlertBar stack (breach / notices)    reads camera, objectives, beacons, intensity
--   top-right  UI/TopRight timer + reinforce tokens + resource chips                   reads mission.endsAt / lives, objectives, kills
--   right      UI/ObjectiveList checklist (y 16 %), UI/PickupToast (y 55 %)            reads objectives; Notify pickup texts
--   left       UI/SquadCards (y 58-78 %), one card per other squad member              reads squad, me.reinforceReadyAt, mission.lives
--   bottom-left own card built here (weapon, mag segments, stim/grenade/mag counts, callsign + health)   reads me
--                + UI/SquadComms tiny radio line above it                               reads me, Fx Breach / HeavyContact / Beacon
--   bottom-right UI/EventFeed (5 lines, 8 s): DIED, streaks, objectives, call-in arrivals, chatter   reads Notify, Fx Death, objectives
--   bottom-centre UI/StaminaBar (inited by Movement)
-- On touch everything in the main gui is drawn at 0.8 x (Style.content); the event feed + resource summary sit behind a FEED button.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
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
local SquadCards = require(script.Parent.SquadCards)
local EventFeed = require(script.Parent.EventFeed)
local PickupToast = require(script.Parent.PickupToast)
local SquadComms = require(script.Parent.SquadComms)

local C = Theme.C
local player = Players.LocalPlayer

local HUD = {}

local inited = false
local touch = false
local ui: { [string]: any } = {}

-- state caches
local state = "Ship"
local prevState: string? = nil
local spreadDeg = 1
local gap = 8
local reloadProgress: number? = nil
local flash = 0
local hitKick = 0 -- crosshair ticks fly outward on a hit and spring back (px)
local ammoLow = false -- magazine <= 25 %: the number pulses red (step)
local ammoLastId: string? = nil
local ammoLastMag = 0
local ammoFill: { from: number, to: number, t0: number }? = nil -- quick count-up after a reload
local lastHp: number? = nil
local markers: { [string]: any } = {}
local beacons: { [string]: { pos: Vector3, color: Color3, label: string } } = {}
local resultsShown: any = nil
local resultsToken = 0
local hmPool: { any } = {}
local hmIndex = 1
local countdownLast = -1
local altAcc = 0

local COMBAT = { Active = true, Extract = true }

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

	-- hitmarker pool
	for i = 1, 5 do
		local hm = Instance.new("Frame")
		hm.Name = "Hitmarker" .. i
		hm.BackgroundTransparency = 1
		hm.AnchorPoint = Vector2.new(0.5, 0.5)
		hm.Size = UDim2.fromOffset(40, 40)
		hm.Visible = false
		hm.Parent = cross
		local sc = Instance.new("UIScale")
		sc.Parent = hm
		local bars = {}
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				local b = Instance.new("Frame")
				b.AnchorPoint = Vector2.new(0.5, 0.5)
				b.Size = UDim2.fromOffset(4, 12)
				b.Position = UDim2.new(0.5, sx * 10, 0.5, sy * 10)
				b.Rotation = (sx * sy > 0) and 45 or -45
				b.BackgroundColor3 = C.White
				b.BorderSizePixel = 0
				b.Parent = hm
				Theme.stroke(b, C.Black, 1, 0.1)
				table.insert(bars, b)
			end
		end
		local tag = Theme.label({
			Text = "",
			Font = "Black",
			TextSize = 16,
			Size = UDim2.fromOffset(120, 20),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0, -22),
			Parent = hm,
		})
		table.insert(hmPool, { frame = hm, scale = sc, bars = bars, tag = tag, tweens = {} })
	end

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
local HP_BAR_W = 190

-- Bottom-left own card: weapon name + mag counter, segmented magazine bar, stim / grenade / mag counts, callsign + health bar.
local function buildOwnCard(parent: Instance)
	local card = Style.panel({
		Name = "OwnCard",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, Style.MARGIN, 1, -Style.MARGIN),
		Size = UDim2.fromOffset(HP_BAR_W + 62, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	ui.ownCard = card
	Theme.pad(card, 8, 6, 8, 7)
	Theme.list(card, Enum.FillDirection.Vertical, 4)

	-- weapon name (left) + magazine / spare (right)
	local top = Instance.new("Frame")
	top.Name = "Weapon"
	top.BackgroundTransparency = 1
	top.Size = UDim2.new(1, 0, 0, 24)
	top.LayoutOrder = 1
	top.Parent = card
	ui.ammoName = Style.label({
		Text = "",
		Color = Style.Amber,
		Size = UDim2.new(1, -78, 0, 14),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = top,
	})
	ui.ammoState = Style.label({
		Text = "",
		TextSize = 12,
		Color = Style.Red,
		Size = UDim2.new(1, -78, 0, 12),
		Position = UDim2.fromOffset(0, 12),
		Parent = top,
	})
	ui.ammoMag = Style.label({
		Text = "0",
		TextSize = 24,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -34, 0, -1),
		Size = UDim2.fromOffset(44, 24),
		Parent = top,
	})
	ui.ammoSpare = Style.label({
		Text = "/ 0",
		TextSize = 14,
		Color = Style.Grey,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 7),
		Size = UDim2.fromOffset(32, 14),
		Parent = top,
	})
	ui.ammoMagPos = ui.ammoMag.Position

	-- magazine segments
	local segs = Instance.new("Frame")
	segs.Name = "MagBar"
	segs.BackgroundTransparency = 1
	segs.Size = UDim2.new(1, 0, 0, 5)
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
	counts.Size = UDim2.new(1, 0, 0, 16)
	counts.LayoutOrder = 3
	counts.Parent = card
	Theme.list(counts, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local function countCell(name: string, glyph: string, order: number): TextLabel
		local l = Style.label({
			Name = name,
			Text = glyph .. " 0",
			Color = Style.Amber,
			Size = UDim2.fromOffset(0, 16),
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
	hpRow.Size = UDim2.new(1, 0, 0, 18)
	hpRow.LayoutOrder = 4
	hpRow.Parent = card
	ui.callsign = Style.label({
		Text = "A1",
		Color = Style.Amber,
		Size = UDim2.fromOffset(26, 18),
		Parent = hpRow,
	})
	local track = Style.rect({
		Name = "HpTrack",
		Color = Style.Black,
		Transparency = 0.4,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 28, 0.5, 0),
		Size = UDim2.fromOffset(HP_BAR_W, 8),
		Parent = hpRow,
	})
	ui.hpPanel = track
	ui.hpFill = Style.rect({ Name = "Fill", Color = Style.White, Size = UDim2.fromScale(1, 1), Parent = track })
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
	holder.Position = UDim2.new(0.5, 0, 0.8, 0)
	holder.Size = UDim2.fromOffset(440, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Parent = root
	Theme.list(holder, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)
	ui.toasts = holder
end

local function buildMain()
	local gui = Theme.gui("OrbitHUD", { DisplayOrder = 10, Insets = "CoreUISafeInsets" })
	ui.mainGui = gui
	local screen = Theme.root(gui, "hud")
	ui.screen = screen
	local root = Style.content(screen, touch) -- 0.8 x on touch
	ui.root = root

	-- top-left column: ship info (lobby), uplink list (squad cards live on the left edge at y 58-78 %)
	local left = Instance.new("Frame")
	left.Name = "LeftColumn"
	left.BackgroundTransparency = 1
	left.Position = UDim2.fromOffset(Style.MARGIN, Style.MARGIN)
	left.Size = UDim2.fromOffset(if touch then 190 else 230, 0)
	left.AutomaticSize = Enum.AutomaticSize.Y
	left.Parent = root
	Theme.list(left, Enum.FillDirection.Vertical, 8)
	ui.left = left

	buildShipPanel(left)
	CallInList.build(left, touch, 2)

	ui.compassMarkerLayer = Compass.build(root, touch)
	TopRight.build(root, touch)
	ObjectiveList.build(root, touch)
	ui.objReady = true
	buildOwnCard(root)
	SquadCards.build(root, touch)
	EventFeed.build(root, touch)
	PickupToast.build(root, touch)
	SquadComms.build(ui.ownCard, touch)
	buildToasts(root)
end

local function buildVignette()
	local gui = Theme.gui("OrbitVignette", { DisplayOrder = 5, Insets = "None" })
	ui.vigGui = gui
	ui.vig = {}
	local defs = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, 0.3), rot = 90 },
		{ pos = UDim2.fromScale(0, 0.7), size = UDim2.fromScale(1, 0.3), rot = 270 },
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(0.22, 1), rot = 0 },
		{ pos = UDim2.fromScale(0.78, 0), size = UDim2.fromScale(0.22, 1), rot = 180 },
	}
	for _, d in defs do
		local f = Instance.new("Frame")
		f.BackgroundColor3 = C.Danger
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Position = d.pos
		f.Size = d.size
		f.Active = false
		f.Parent = gui
		local g = Instance.new("UIGradient")
		g.Rotation = d.rot
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		table.insert(ui.vig, f)
	end
end

local function setVignette(alpha: number)
	local t = 1 - Theme.clamp(alpha, 0, 1)
	for _, f in ui.vig do
		f.BackgroundTransparency = t
	end
end

-- Toasts / banners ---------------------------------------------------------------------------------------------------
function HUD.toast(text: string, color: Color3?)
	if not ui.toasts then
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
function HUD.hitmarker(result: string, weak: boolean?, killed: boolean?)
	local hm = hmPool[hmIndex]
	if not hm then
		return
	end
	hmIndex = hmIndex % #hmPool + 1
	for _, t in hm.tweens do
		t:Cancel()
	end
	table.clear(hm.tweens)
	local col = C.White
	if result == "partial" then
		col = Color3.fromHex("a9b2c3")
	elseif result == "deflect" then
		col = C.Accent
	end
	if weak then
		col = C.Gold
	end
	if killed then
		col = weak and C.Gold or C.Danger
	end
	for _, b in hm.bars do
		b.BackgroundColor3 = col
		b.BackgroundTransparency = 0
		local st = b:FindFirstChildOfClass("UIStroke")
		if st then
			st.Transparency = 0.1
		end
	end
	hm.frame.Visible = true
	-- punchier: bigger overshoot, a crosshair tick kick, and kills snap in with a twist + an expanding ring
	hitKick = math.max(hitKick, if killed then 16 elseif weak then 10 else 5)
	hm.scale.Scale = killed and 2.5 or (weak and 1.7 or 1.35)
	table.insert(hm.tweens, tw(hm.scale, killed and 0.28 or 0.12, { Scale = killed and 1.35 or 1 }, Enum.EasingStyle.Back))
	if killed then
		hm.frame.Rotation = 30
		table.insert(hm.tweens, tw(hm.frame, 0.2, { Rotation = 0 }, Enum.EasingStyle.Back))
		HUD.killRing(col)
	else
		hm.frame.Rotation = 0
	end
	local text = ""
	if killed and weak then
		text = "WEAK KILL"
	elseif killed then
		text = "KILL"
	elseif weak then
		text = "WEAK"
	end
	hm.tag.Text = text
	hm.tag.TextColor3 = col
	hm.tag.TextTransparency = 0
	hm.tag.TextStrokeTransparency = 0.4
	local hold = killed and 0.45 or 0.18
	local fade = 0.22
	hm.gen = (hm.gen or 0) + 1
	local gen = hm.gen
	task.delay(hold, function()
		if hm.gen ~= gen then
			return
		end
		for _, b in hm.bars do
			local t = tw(b, fade, { BackgroundTransparency = 1 })
			table.insert(hm.tweens, t)
			local st = b:FindFirstChildOfClass("UIStroke")
			if st then
				tw(st, fade, { Transparency = 1 })
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
local STREAK_NAMES = {
	{ 2, "DOUBLE TAP" },
	{ 3, "TRIPLE THREAT" },
	{ 4, "FOUR ALARM" },
	{ 5, "CLEAN SWEEP" },
	{ 7, "SHOCK RUN" },
	{ 10, "UNSTOPPABLE" },
	{ 15, "ORBITAL WRATH" },
	{ 25, "LEGEND OF THE DROP" },
}
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
	f.Size = UDim2.fromOffset(320, 84)
	f.Visible = false
	f.Parent = gui
	local sc = Instance.new("UIScale")
	sc.Parent = f
	ui.streakFrame = f
	ui.streakScale = sc
	ui.streakCount = Theme.label({
		Text = "",
		Font = "Black",
		TextSize = 46,
		Size = UDim2.new(1, 0, 0, 52),
		Parent = f,
	})
	ui.streakCount.TextStrokeTransparency = 0.2
	ui.streakName = Theme.label({
		Text = "",
		Font = "Header",
		TextSize = 15,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 54),
		Parent = f,
	})
end

function HUD.killRing(color: Color3?)
	local ring, stroke = ui.killRing, ui.killRingStroke
	if not ring then
		return
	end
	ring.Size = UDim2.fromOffset(26, 26)
	ring.Visible = true
	stroke.Color = color or C.Danger
	stroke.Transparency = 0.05
	stroke.Thickness = 4
	tw(ring, 0.32, { Size = UDim2.fromOffset(104, 104) }, Enum.EasingStyle.Quad)
	tw(stroke, 0.32, { Transparency = 1, Thickness = 1 }, Enum.EasingStyle.Quad)
end

local function showStreak(text: string, sub: string?, color: Color3, big: number)
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
	ui.streakCount.Text = text
	ui.streakCount.TextColor3 = color
	ui.streakCount.TextTransparency = 0
	ui.streakCount.TextStrokeTransparency = 0.2
	ui.streakName.Text = sub or ""
	ui.streakName.TextColor3 = C.White
	ui.streakName.TextTransparency = 0
	ui.streakName.TextStrokeTransparency = 0.3
	ui.streakScale.Scale = 1.5 * big
	table.insert(streakTweens, tw(ui.streakScale, 0.2, { Scale = big }, Enum.EasingStyle.Back))
	task.delay(STREAK_HOLD, function()
		if gen ~= streakGen then
			return
		end
		table.insert(streakTweens, tw(ui.streakCount, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 }))
		table.insert(streakTweens, tw(ui.streakName, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 }))
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
	local name: string? = nil
	for _, e in STREAK_NAMES do
		if streak >= e[1] then
			name = e[2]
		end
	end
	if class == "behemoth" then
		showStreak("BEHEMOTH DOWN", if streak >= 2 then string.format("x%d  %s", streak, name or "") else nil, C.Gold, 1.2)
	elseif class == "heavy" then
		showStreak("HEAVY DOWN", if streak >= 2 then string.format("x%d  %s", streak, name or "") else nil, C.Gold, 1.05)
	elseif streak >= 2 then
		-- colour heats up with the streak: white -> gold -> orange -> red
		local col = if streak >= 10 then C.Danger elseif streak >= 5 then C.Accent elseif streak >= 3 then C.Gold else C.White
		showStreak(string.format("x%d", streak), name, col, math.min(0.9 + streak * 0.03, 1.3))
	end
	-- event feed: heavy kills and streak milestones (own kills = amber)
	if class == "behemoth" then
		EventFeed.push("BEHEMOTH DOWN", Style.Amber, "kill")
	elseif class == "heavy" then
		EventFeed.push("HEAVY DOWN", Style.Amber, "kill")
	end
	if MILESTONES[streak] then
		EventFeed.push(string.format("x%d STREAK", streak), Style.Amber, "streak")
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

function HUD.setReload(progress: number?)
	if progress ~= nil and reloadProgress == nil then
		SquadComms.onReload()
	end
	reloadProgress = progress
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
		ui.ammoMag.TextColor3 = C.Danger
	end
	shotKick = 1
end

function HUD.flashDamage(strength: number?)
	flash = math.max(flash, strength or 0.6)
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
		local us = Instance.new("UIScale")
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
local function updateSquad()
	if not ui.root then
		return
	end
	local squad = Store.get("squad")
	Style.setSquad(squad, player.UserId)
	if ui.callsign then
		local me = Style.callsign(player.UserId)
		ui.callsign.Text = me.tag
		ui.callsign.TextColor3 = me.color
	end
	SquadCards.update(squad, Store.get("me"), Store.get("mission"), player.UserId, now())
	SquadCards.setVisible(COMBAT[state] == true or state == "Drop")
	SquadComms.onSquad(squad)
end

-- Call-in bar -------------------------------------------------------------------------------------------------------------
-- The top-left call-in list lives in UI/CallInList.
local function updateCallins()
	local me = Store.get("me")
	if me then
		CallInList.update(me, now())
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
		-- spare magazines (whole mags left in reserve)
		local mags = if maxMag > 0 then math.ceil(spare / math.max(maxMag, 1)) else 0
		ui.cntMags.Text = "MAG " .. tostring(mags)
		ui.cntMags.TextColor3 = if spare <= 0 then Style.Red else Style.Amber
	end
	local g = me.grenades or 0
	ui.cntNade.Text = "GREN " .. tostring(g)
	ui.cntNade.TextColor3 = if g <= 0 then Style.Grey else Style.Amber
	local stims = me.stims
	ui.cntStim.Visible = type(stims) == "number"
	if type(stims) == "number" then
		ui.cntStim.Text = "STIM " .. tostring(stims)
		ui.cntStim.TextColor3 = if stims <= 0 then Style.Grey else Style.Amber
	end
end

-- WeaponController: its predicted magazine table (same table every call; read by reference).
function HUD.setLocalMag(t: { [number]: number })
	localMags = t
	if inited and ui.ammoMag then
		updateAmmo()
	end
end

local function updateHealth()
	local me = Store.get("me")
	if not me then
		return
	end
	local hp, maxHp = me.hp or 0, math.max(me.maxHp or Config.PlayerHealth, 1)
	local frac = Theme.clamp(hp / maxHp, 0, 1)
	tw(ui.hpFill, 0.12, { Size = UDim2.fromScale(frac, 1) })
	ui.hpFill.BackgroundColor3 = if frac < 0.3 then Style.Red else Style.White
	ui.hpText.Text = me.alive == false and "DOWN" or string.format("%d / %d", math.ceil(hp), maxHp)
	if lastHp and hp < lastHp - 0.5 then
		flash = math.max(flash, math.min(1, (lastHp - hp) / maxHp * 3 + 0.3))
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
		TopRight.setTimer("T-" .. Theme.formatTime(left), col)
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
	ui.ownCard.Visible = combat
	EventFeed.setVisible(combat)
	PickupToast.setVisible(combat)
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

	local sub = (r and r.bonusText) or (success and "Excellent work, Helldiver-class heroes." or "The squad was lost. Regroup on the ship.")
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
			local f = m.faction == "BROOD" and "Skitter Brood" or (m.faction == "COG" and "Cogwork Legion" or "")
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
		local hint = touch and "Tap FIRE to throw" or "Left-click or [Q] to throw"
		ui.promptSub.Text = (def and string.upper(def.name) or "") .. (h.perfect and "  -  PERFECT SYNC" or "") .. "   " .. hint
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
		local dist = (m.pos - camPos).Magnitude
		local dl = m.world:FindFirstChild("Dist") :: TextLabel
		if dl then
			dl.Text = string.format("%d m", math.floor(dist + 0.5))
		end
	end
end

local function step(dt: number)
	local cam = workspace.CurrentCamera
	local combat = COMBAT[state] == true
	if combat and cam then
		local ppd = cam.ViewportSize.Y / math.max(cam.FieldOfView, 1)
		local target = Theme.clamp(spreadDeg * ppd + 5, 5, 170)
		hitKick *= math.exp(-16 * dt)
		gap += (target + hitKick - gap) * (1 - math.exp(-22 * dt))
		for _, t in ui.ticks do
			local off = gap + t.half
			t.frame.Position = UDim2.fromOffset(t.dir.X * off, t.dir.Y * off)
		end
		Compass.step(cam, markers)
		stepMarkers(cam)
		if ui.promptFrame.Visible then
			ui.promptScale.Scale = 1 + 0.06 * math.sin(os.clock() * 7)
		end
		if reloadProgress ~= nil then
			ui.reloadLabel.TextTransparency = 0.2 + 0.3 * math.abs(math.sin(os.clock() * 6))
		end
	end
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
			s = 1 + 0.28 * math.sin(fillT * math.pi)
			ui.ammoMag.TextColor3 = C.Friendly:Lerp(C.Text, fillT)
		elseif ammoFill then
			ammoFill = nil
			updateAmmo()
		elseif ammoLow then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
			ui.ammoMag.TextColor3 = C.Text:Lerp(C.Danger, 0.45 + 0.55 * pulse)
			s = 1 + 0.12 * pulse
		end
		-- per-shot tick: quick pop + a couple of pixels of shake, decaying in ~0.12 s
		shotKick = math.max(0, shotKick - dt * 8)
		s *= 1 + 0.09 * shotKick
		local base = ui.ammoMagPos
		if base then
			if shotKick > 0 then
				local j = 2.5 * shotKick
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
	-- vignette (Main.client's Hurt handler already flashes Juice.vignette, so this one stays restrained)
	flash = math.max(0, flash - dt * 1.6)
	local me = Store.get("me")
	local low = 0
	local strokeLow = false
	if combat and me and me.alive ~= false and me.maxHp and me.maxHp > 0 then
		local frac = (me.hp or 0) / me.maxHp
		if frac < 0.4 then
			-- heartbeat: a strong "lub" then a softer "dub", faster the lower the health
			local beat = (os.clock() * (1.0 + (0.4 - frac) * 2.5)) % 1
			local pulse = math.max(math.exp(-((beat - 0.08) / 0.07) ^ 2), 0.65 * math.exp(-((beat - 0.32) / 0.08) ^ 2))
			low = (0.4 - frac) / 0.4 * (0.16 + 0.24 * pulse) -- peaks at 0.4 alpha on the very edges only
			strokeLow = true
			if ui.hpStroke then
				ui.hpStroke.Color = C.Danger
				ui.hpStroke.Transparency = 0.6 - 0.5 * pulse
			end
		end
	elseif me and me.alive == false and combat then
		low = 0.32
	end
	if not strokeLow and ui.hpStroke and ui.hpStroke.Color ~= Style.White then
		ui.hpStroke.Color = Style.White
		ui.hpStroke.Transparency = 0.7
	end
	setVignette(math.max(flash * 0.45, low))
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
			HUD.banner(string.upper((m and m.objectiveName) or "MISSION START"), touch and "Tap UPLINK to call the sky down" or "Hold [Q] for the Uplink Dial", C.Accent)
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
	buildVignette()
	buildOverlay()

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
	Store.on("squad", updateSquad)
	Store.on("profile", updateShip)
	Store.on("menuOpen", applyVisibility)

	Net.event("Notify").OnClientEvent:Connect(function(text: string, color: Color3?, kind: string?)
		if type(text) ~= "string" then
			return
		end
		if kind == "banner" then
			HUD.banner(text, nil, color)
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
end

function HUD.isCombat(): boolean
	return COMBAT[state] == true
end

return HUD
