-- Main objective "Recover Core Cells": load N core cells (5 / 6 / 7 / 8 / 9 by difficulty) into the cargo lifter.
-- The cells rest at four places (World/MapPlan): the spilled cell at the crashed drone, Signal Mesa, the Quarry and the
-- Walker Graveyard, MapPlan.cellCount(place, difficulty) of them each, on the spots the map's anchors give (a ring around
-- the place when an anchor is missing). Every place has its own twist (HaulTwists.luau). The cargo lifter stands on the
-- concrete apron of the silo site (the refinery): a cargo bed, an upright glowing blue terminal panel and a painted
-- Halcyon emblem, all built from parts. The refinery fights back as cells go in (probe, counter-attack); the last cell
-- starts a launch countdown with a big wave, and the lifter leaves when it runs out.
--   pick up : hold Interact 0.5 s on a cell (ProximityPrompt). The server welds the cell to the trooper's chest and sets
--             the Player + character attribute `CarryCell` (shared/Carry.luau: no fire / aim / grenades, speed x0.8).
--   drop    : Action "cellDrop" (client: Interact or Grenade while carrying), dying, being knocked down (stance "down")
--             or leaving the game drops it where the trooper stood; a dropped cell keeps a world marker.
--   deliver : a carrier entering the lifter zone (LIFT_RADIUS around the cargo bed) loads the cell: counter [k/N].
--   done    : N/N -> launch countdown (LAUNCH_SECONDS), then the step completes, the lifter launches, onComplete() (the
--             Mission goes to Extract).
-- Callouts go through the Notify remote with kind "comms" as "<name>: <line>".
-- Volatile core cells: 2-3 EXTRA amber cells (never part of the required N) rest on cradles along the approaches to the
-- cell places. A trooper can carry one like any cell and load it (counts toward [k/N], overcharge flare, shorter launch
-- hold), or shoot / blast it while it sits on its cradle or on the ground: 0.65 s overload strobe, then an improvised
-- EMP + heat blast. A carried (or loaded) volatile cell is never shootable, so nothing detonates in a trooper's hands.
-- Cargo lifter spectacle: every load plays clamp-down -> steam + escalating deck -> sky flare (see loadSequence).
-- Receives `ctx` from ObjectiveService; returns a controller { entry, stop, drop, stepsDone, debugSolve }.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Carry = require(Shared.Carry)
local Net = require(Shared.Net)
local SetPieces = require(script.Parent.SetPieces)
local HaulTwists = require(script.Parent.HaulTwists)
local HaulEncounters = require(script.Parent.HaulEncounters)
local MapPlan = require(script.Parent.Parent.World.MapPlan)

local HaulCells = {}

local PLACES = { "spilled", "mesa", "quarry", "graveyard" } -- cell places, in the order the cells are numbered
local PLACE_LABEL = { spilled = "DRONE WRECK", mesa = "SIGNAL MESA", quarry = "QUARRY", graveyard = "WALKER GRAVEYARD" }
local PICK_HOLD = 0.5
local PULL_TIME = 0.6 -- s "pull it out" beat when taking a cell from a cradle
local LIFT_RADIUS = 7.5 -- horizontal studs from the cargo bed centre that load a carried cell
local LIFT_DROP_RADIUS = LIFT_RADIUS + 2 -- dropping at or near the lifter still loads into the bed
local LIFT_DY = 9
local REPICK_LOCK = 0.6 -- s after a drop before that trooper can grab again (holding Interact to drop doesn't re-grab)
local LAUNCH_SECONDS = (MapPlan.haul and MapPlan.haul.launchSeconds) or 50 -- last cell loaded -> defend while lifter climbs
local DEBUG_LAUNCH_SECONDS = 5 -- same with the DebugFast attribute
local PAD_H = 0.36 -- height of the cradle plinth a resting cell sits on
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local STEP_FMT = "Load cells into the cargo lifter [%d/%d]"
local CHARGE_FMT = "LIFTER CHARGING %d/%d"
local LAUNCH_FMT = "Defend the cargo lifter: climbing %d s"
local LOG_AMBER = Color3.fromRGB(255, 190, 65)

-- cargo lifter load sequence timing (s): the cell slides into its slot, the clamps slam shut over it, then the climb waits
local LOAD_SLIDE = 0.45
local CLAMP_SECONDS = 0.14
local CLIMB_DELAY = 1.05 -- final cell: the climb tween starts after slide + clamp + settle, so no tween ever overlaps

-- volatile core cells
local VOLATILE = Color3.fromRGB(255, 140, 26) -- #FF8C1A
local VOLATILE_HOT = Color3.fromRGB(255, 232, 170)
local VOLATILE_HP = 40 -- two hits from any weapon (or one big one) set it off
local VOLATILE_OVERLOAD = 0.65 -- s of rising whine + strobe before the blast
local VOLATILE_BLAST = { radius = 22, core = 8, damage = 260, ap = 3, knock = 34 }
local VOLATILE_EMP_RADIUS = 32
local VOLATILE_STUN = 4.5 -- s COG are stunned
local VOLATILE_SLOW = 0.55 -- Brood (and behemoths) slow magnitude
local VOLATILE_SLOW_TIME = 6
local VOLATILE_LAUNCH_BONUS = 4 -- s shaved off the launch hold per volatile cell loaded
local VOLATILE_MAX_BONUS = 12
local THRUSTER = Color3.fromRGB(255, 150, 60)

local DARK = Color3.fromRGB(40, 44, 52)
local STEEL = Color3.fromRGB(112, 118, 128)
local HAZARD = Color3.fromRGB(230, 170, 40)
local PANEL_BLUE = Color3.fromRGB(70, 150, 255)
local PAINT = Color3.fromRGB(226, 196, 92)
local CONCRETE = Color3.fromRGB(122, 120, 116)
local CALLOUT = Color3.fromRGB(244, 246, 250)

type CradleArm = {
	part: Part,
	openCF: CFrame,
}

type Cradle = {
	pos: Vector3,
	arms: { CradleArm },
	ring: Part,
	steam: ParticleEmitter?,
	opened: boolean,
}

type Cell = {
	id: number,
	case: Part,
	parts: { BasePart },
	prompt: ProximityPrompt,
	state: string, -- "cache" | "picking" | "carried" | "dropped" | "loaded" | "locked"
	home: CFrame,
	cache: any,
	cradle: Cradle?,
	onBelt: boolean?,
	carrier: Player?,
	weld: Weld?,
	marker: BillboardGui?,
	above: BillboardGui?,
	everTaken: boolean,
	-- volatile core cells (extra amber cells that can be shot / blasted while resting)
	volatile: boolean?,
	hitbox: Part?,
	core: Part?,
	glow: PointLight?,
	sparks: ParticleEmitter?,
	tag: BillboardGui?,
	hp: number?,
	hits: number?,
	detonating: boolean?,
	igniter: Player?,
}

-- small world marker: a rotated-square "cell" glyph plus an optional caption
local function billboard(adornee: BasePart, name: string, caption: string?, offset: Vector3, maxDist: number, glyph: number, tint: Color3?): BillboardGui
	local bb = Instance.new("BillboardGui")
	bb.Name = name
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(if caption then 170 else glyph + 8, if caption then glyph + 22 else glyph + 8)
	bb.StudsOffsetWorldSpace = offset
	bb.MaxDistance = maxDist
	bb.Adornee = adornee
	local d = Instance.new("Frame")
	d.Name = "Glyph"
	d.AnchorPoint = Vector2.new(0.5, 0)
	d.Position = UDim2.new(0.5, 0, 0, 4)
	d.Size = UDim2.fromOffset(glyph, glyph)
	d.Rotation = 45
	d.BackgroundColor3 = tint or Carry.COLOR
	d.BorderSizePixel = 0
	local st = Instance.new("UIStroke")
	st.Color = Color3.new(0, 0, 0)
	st.Thickness = 1.5
	st.Transparency = 0.2
	st.Parent = d
	d.Parent = bb
	if caption then
		local l = Instance.new("TextLabel")
		l.Name = "Caption"
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 0)
		l.Position = UDim2.new(0.5, 0, 0, glyph + 6)
		l.Size = UDim2.new(1, 0, 0, 14)
		l.Font = Enum.Font.GothamBold
		l.TextSize = 12
		l.TextColor3 = tint or Carry.COLOR
		l.TextStrokeTransparency = 0.4
		l.Text = caption
		l.Parent = bb
	end
	bb.Parent = adornee
	return bb
end

function HaulCells.start(ctx: any, onComplete: () -> ()): any
	local S = ctx.S
	local map = ctx.map
	local hitConfirmEv = Net.event("HitConfirm")
	local root = Instance.new("Folder")
	root.Name = "Haul"
	root.Parent = ctx.folder

	-- cells per place (MapPlan: 5 / 6 / 7 / 8 / 9 in all by difficulty 1..5)
	local diff = math.clamp(math.floor(tonumber(ctx.difficulty) or 1), 1, 5)
	local counts: { [string]: number } = {}
	local total = 0
	local room = if Workspace:GetAttribute("DebugFast") then 2 else math.huge
	for _, name in PLACES do
		local n = math.min(MapPlan.cellCount(name, diff), room)
		counts[name] = n
		room -= n
		total += n
	end
	local entry = ctx.newEntry({ id = "HAUL", title = "Recover Core Cells", main = true, steps = { string.format(STEP_FMT, 0, total) } })
	local ctl: any = { entry = entry }
	local alive = true
	local finished = false
	local delivered = 0

	local cells: { Cell } = {}
	local volatiles: { Cell } = {} -- extra amber cells still in play (on a cradle, dropped or carried); never counted in `total`
	local launchBonus = 0 -- s shaved off the launch hold by loaded volatile cells
	local carriers: { [Player]: { Cell } } = {}
	local picking: { [Player]: number } = {}
	local lastPos: { [Player]: Vector3 } = {}
	local dropLock: { [Player]: number } = {}

	local function callout(p: Player, line: string)
		if S and S.State then
			S.State.notify(nil, p.DisplayName .. ": " .. line, CALLOUT, "comms")
		end
	end

	-- ============================================================ cargo lifter (silo site apron)
	local siteCF: CFrame = map.sites.silo or map.sites.console
	local base = SetPieces.groundCF(map, siteCF, 12)
	local gC = map.groundY and map.groundY(siteCF.Position.X, siteCF.Position.Z) or base.Position.Y
	local top = gC + 0.45 -- slab surface (the map's round apron tops out at ground + 0.15)
	local lowest = base.Position.Y
	local plaza = CFrame.new(siteCF.Position.X, top, siteCF.Position.Z) * siteCF.Rotation -- local -Z faces the map centre
	local slabH = math.clamp(top - lowest + 1, 1, 5)
	local lifter = Instance.new("Model")
	lifter.Name = "CargoLifter"
	lifter.Parent = root
	ctx.part(lifter, Vector3.new(26, slabH, 26), plaza * CFrame.new(0, -slabH / 2, 0), CONCRETE, Enum.Material.Concrete, { CastShadow = false })
	-- Anything of the map that stands in the slab's footprint and crosses its top surface pokes through it: the apron's hazard
	-- bollards (server/World/MapBuilder.luau) and any small prop or chunk on the plaza. Bollards go wherever they are near
	-- the slab; other parts only when they are small (the apron disc and walls are bigger than 9 studs and stay).
	if map.folder then
		for _, d in map.folder:GetDescendants() do
			if d:IsA("BasePart") then
				local lp = plaza:PointToObjectSpace(d.Position)
				if math.abs(lp.X) <= 15 and math.abs(lp.Z) <= 15 then
					if d.Name == "HazardBollard" then
						d:Destroy()
					elseif math.abs(lp.X) <= 14.5 and math.abs(lp.Z) <= 14.5 and math.max(d.Size.X, d.Size.Y, d.Size.Z) <= 9 then
						-- vertical half-extent of the part's (rotated) box
						local cf = d.CFrame
						local s = d.Size
						local half = 0.5 * (math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z)
						local y = d.Position.Y
						if y + half > top + 0.03 and y - half < top then
							d:Destroy()
						end
					end
				end
			end
		end
	end
	-- floor grates along the side edges
	for _, gx in { -10.5, 10.5 } do
		for _, gz in { -7, 0, 7 } do
			ctx.part(lifter, Vector3.new(3.2, 0.08, 5), plaza * CFrame.new(gx, 0.04, gz), Color3.fromRGB(58, 60, 64), Enum.Material.DiamondPlate, { CanCollide = false, CastShadow = false })
		end
	end
	-- painted emblem (front of the plaza): ring, cross bars and a centre diamond, flat paint on the slab
	do
		local e = plaza * CFrame.new(0, 0, -6.5)
		local paint = { CanCollide = false, CanQuery = false, CastShadow = false }
		ctx.cyl(lifter, 11, 0.04, e * CFrame.new(0, 0.02, 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.cyl(lifter, 9.6, 0.04, e * CFrame.new(0, 0.035, 0), CONCRETE, Enum.Material.Concrete, paint)
		ctx.part(lifter, Vector3.new(0.7, 0.04, 9.2), e * CFrame.new(0, 0.05, 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.part(lifter, Vector3.new(9.2, 0.04, 0.7), e * CFrame.new(0, 0.05, 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.part(lifter, Vector3.new(3.6, 0.04, 3.6), e * CFrame.new(0, 0.065, 0) * CFrame.Angles(0, math.rad(45), 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.part(lifter, Vector3.new(1.7, 0.04, 1.7), e * CFrame.new(0, 0.08, 0) * CFrame.Angles(0, math.rad(45), 0), CONCRETE, Enum.Material.Concrete, paint)
	end
	-- cargo bed (the delivery zone) with hazard edges and four guide posts
	local bedCF = plaza * CFrame.new(0, 0.15, 2.5)
	local bed = ctx.part(lifter, Vector3.new(8, 0.3, 8), bedCF, Color3.fromRGB(64, 68, 76), Enum.Material.DiamondPlate, { Name = "CargoBed" })
	local bedParts: { BasePart } = { bed }
	for _, s in { { 0, -3.85, 8, 0.3 }, { 0, 3.85, 8, 0.3 }, { -3.85, 0, 0.3, 8 }, { 3.85, 0, 0.3, 8 } } do
		local strip = ctx.part(lifter, Vector3.new(s[3], 0.32, s[4]), bedCF * CFrame.new(s[1], 0.02, s[2]), HAZARD, Enum.Material.SmoothPlastic, { CanCollide = false, CastShadow = false })
		table.insert(bedParts, strip)
	end
	local alarmCaps: { BasePart } = {}
	local alarmLights: { PointLight } = {}
	for i, c in { { -4.4, -4.4 }, { 4.4, -4.4 }, { -4.4, 4.4 }, { 4.4, 4.4 } } do
		ctx.part(lifter, Vector3.new(0.6, 7, 0.6), plaza * CFrame.new(c[1], 3.5, 2.5 + c[2]), DARK, Enum.Material.Metal)
		ctx.part(lifter, Vector3.new(0.66, 0.5, 0.66), plaza * CFrame.new(c[1], 6.6, 2.5 + c[2]), HAZARD, Enum.Material.Metal, { CanCollide = false })
		local cap = ctx.part(lifter, Vector3.new(0.55, 0.35, 0.55), plaza * CFrame.new(c[1], 7.15, 2.5 + c[2]), Color3.fromRGB(58, 30, 30), Enum.Material.SmoothPlastic, { CanCollide = false, CastShadow = false })
		table.insert(alarmCaps, cap)
		-- keep PointLights to 2 diagonal posts so phone frame budgets stay light
		if i == 1 or i == 4 then
			local al = Instance.new("PointLight")
			al.Name = "LaunchAlarmLight"
			al.Color = Color3.fromRGB(255, 45, 35)
			al.Range = 28
			al.Brightness = 2.6
			al.Shadows = false
			al.Enabled = false
			al.Parent = cap
			table.insert(alarmLights, al)
		end
	end
	local launchAlarmOn = false
	local function setLaunchAlarm(on: boolean)
		launchAlarmOn = on
		if not on then
			for _, cap in alarmCaps do
				if cap.Parent then
					cap.Color = Color3.fromRGB(58, 30, 30)
					cap.Material = Enum.Material.SmoothPlastic
				end
			end
			for _, al in alarmLights do
				if al.Parent then
					al.Enabled = false
				end
			end
			return
		end
		task.spawn(function()
			local lit = false
			local RED_ON = Color3.fromRGB(255, 45, 35)
			local RED_OFF = Color3.fromRGB(68, 22, 22)
			while launchAlarmOn and alive and ctx.alive() do
				lit = not lit
				for _, cap in alarmCaps do
					if cap.Parent then
						cap.Color = if lit then RED_ON else RED_OFF
						cap.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
					end
				end
				for _, al in alarmLights do
					if al.Parent then
						al.Enabled = lit
					end
				end
				task.wait(0.42)
			end
			for _, al in alarmLights do
				if al.Parent then
					al.Enabled = false
				end
			end
		end)
	end
	-- terminal: upright glowing blue panel behind the bed, facing the arrivals, with one load light per cell
	local panelCF = plaza * CFrame.new(0, 0, 8.6)
	ctx.part(lifter, Vector3.new(7.2, 9.4, 0.9), panelCF * CFrame.new(0, 4.7, 0), DARK, Enum.Material.Metal)
	ctx.part(lifter, Vector3.new(1, 3, 1), panelCF * CFrame.new(-2.6, 0.4, -0.9) * CFrame.Angles(math.rad(20), 0, 0), DARK, Enum.Material.Metal)
	ctx.part(lifter, Vector3.new(1, 3, 1), panelCF * CFrame.new(2.6, 0.4, -0.9) * CFrame.Angles(math.rad(20), 0, 0), DARK, Enum.Material.Metal)
	local screen = ctx.glow(lifter, Vector3.new(5.8, 5.6, 0.2), panelCF * CFrame.new(0, 5.6, -0.5), PANEL_BLUE, { Name = "LifterPanel", Transparency = 0.05 })
	ctx.light(screen, Color3.fromRGB(150, 190, 255), 14, 1.2)
	local slotLights: { BasePart } = {}
	local spacing = math.min(0.75, 5.6 / total)
	for i = 1, total do
		local x = (i - (total + 1) / 2) * spacing
		slotLights[i] = ctx.part(lifter, Vector3.new(spacing * 0.7, 0.55, 0.14), panelCF * CFrame.new(x, 2.1, -0.5), Color3.fromRGB(30, 34, 40), Enum.Material.SmoothPlastic, { CanCollide = false, CastShadow = false })
	end
	local liftPos = bedCF.Position
	-- where loaded cells sit on the bed (3 x 3 grid)
	local function bedSlot(i: number): CFrame
		local k = i - 1
		local col, row = k % 3, math.floor(k / 3)
		return bedCF * CFrame.new((col - 1) * 2.2, 0.15 + Carry.SIZE.Y / 2, (row - 1) * 2.2)
	end

	-- ============================================================ hydraulic cargo lifter spectacle
	-- Every part that moves goes through `glide`, which remembers the part's goal CFrame. Before the climb (and the final
	-- blast-off) `settleGlides` cancels whatever tween is still running and pins the part to its goal, so two tweens can
	-- never fight over one CFrame (a loaded cell would otherwise be left floating beside the climbing bed).
	local goalCF: { [BasePart]: CFrame } = {}
	local tweenOf: { [BasePart]: Tween } = {}
	local function glide(part: BasePart, secs: number, cf: CFrame, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
		local old = tweenOf[part]
		if old then
			old:Cancel()
		end
		goalCF[part] = cf
		local tw = ctx.tween(part, secs, { CFrame = cf }, style, dir)
		tweenOf[part] = tw
		tw.Completed:Connect(function()
			if tweenOf[part] == tw then
				tweenOf[part] = nil
			end
		end)
	end
	local function settleGlides()
		for part, tw in table.clone(tweenOf) do
			tw:Cancel()
			local g = goalCF[part]
			if g and part.Parent then
				part.CFrame = g
			end
		end
		table.clear(tweenOf)
	end

	local function newBurst(name: string, rate: number): ParticleEmitter
		local em = Instance.new("ParticleEmitter")
		em.Name = name
		em.Rate = rate
		em.Enabled = false
		return em
	end

	-- the bed's rim strips are bedParts[2..5] right now (the hazard edges); they climb from hazard yellow to cyan
	local rimStrips: { BasePart } = {}
	for i = 2, #bedParts do
		table.insert(rimStrips, bedParts[i])
	end
	local deckLight = ctx.light(bed, Carry.COLOR, 12, 0.35)
	deckLight.Name = "DeckGlow"

	-- four corner steam nozzles on the bed
	local steamJets: { ParticleEmitter } = {}
	for _, c in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local outward = plaza:VectorToWorldSpace(Vector3.new(c[1], 0, c[2]).Unit)
		local nz = ctx.part(lifter, Vector3.new(0.7, 0.6, 0.7), bedCF * CFrame.new(c[1] * 3.5, 0.42, c[2] * 3.5), DARK, Enum.Material.Metal, { Name = "SteamNozzle", CanCollide = false, CastShadow = false })
		local jet = newBurst("SteamJet", 0)
		jet.Texture = TEX_SMOKE
		jet.Lifetime = NumberRange.new(0.7, 1.2)
		jet.Speed = NumberRange.new(14, 22)
		jet.SpreadAngle = Vector2.new(20, 20)
		jet.EmissionDirection = Enum.NormalId.Top
		jet.Acceleration = outward * 7 + Vector3.new(0, 3, 0)
		jet.Drag = 3
		jet.Rotation = NumberRange.new(0, 360)
		jet.RotSpeed = NumberRange.new(-60, 60)
		jet.LightEmission = 0.15
		jet.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 3.4) })
		jet.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		jet.Color = ColorSequence.new(Color3.fromRGB(235, 244, 252))
		jet.Parent = nz
		table.insert(steamJets, jet)
		table.insert(bedParts, nz)
	end

	-- one pair of hydraulic clamp bars per bed slot, built when the slot is first used (open until a cell is loaded)
	type Clamp = { part: Part, open: CFrame, shut: CFrame, spark: ParticleEmitter }
	local clampSets: { [number]: { Clamp } } = {}
	local function ensureClamps(idx: number): { Clamp }
		local existing = clampSets[idx]
		if existing then
			return existing
		end
		local set: { Clamp } = {}
		local slot = bedSlot(idx)
		for _, sz in { -1, 1 } do
			local shut = slot * CFrame.new(0, Carry.SIZE.Y / 2 - 0.14, sz * (Carry.SIZE.Z / 2 + 0.2))
			local open = slot * CFrame.new(0, Carry.SIZE.Y / 2 + 1.25, sz * (Carry.SIZE.Z / 2 + 1.05)) * CFrame.Angles(sz * math.rad(28), 0, 0)
			local bar = ctx.part(lifter, Vector3.new(Carry.SIZE.X + 0.7, 0.62, 0.34), open, HAZARD, Enum.Material.Metal, { Name = "ClampBar", CanCollide = false, CastShadow = false })
			local spark = newBurst("ClampSparks", 0)
			spark.Lifetime = NumberRange.new(0.2, 0.45)
			spark.Speed = NumberRange.new(9, 18)
			spark.SpreadAngle = Vector2.new(70, 70)
			spark.EmissionDirection = Enum.NormalId.Top
			spark.Acceleration = Vector3.new(0, -26, 0)
			spark.LightEmission = 1
			spark.Color = ColorSequence.new(Color3.fromRGB(255, 226, 150), Color3.fromRGB(255, 120, 30))
			spark.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.28), NumberSequenceKeypoint.new(1, 0) })
			spark.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
			spark.Parent = bar
			goalCF[bar] = open
			table.insert(bedParts, bar)
			table.insert(set, { part = bar, open = open, shut = shut, spark = spark })
		end
		clampSets[idx] = set
		return set
	end

	-- deck state after `n` cells: rim strips, status beacons and the deck light all escalate with the count
	local function updateDeck(n: number)
		local frac = math.clamp(n / math.max(total, 1), 0, 1)
		local rim = HAZARD:Lerp(Carry.COLOR, frac)
		for _, strip in rimStrips do
			if strip.Parent then
				strip.Color = rim
				strip.Material = if frac >= 0.5 then Enum.Material.Neon else Enum.Material.SmoothPlastic
			end
		end
		if not launchAlarmOn then
			local lit = math.ceil(frac * #alarmCaps)
			for i, cap in alarmCaps do
				if cap.Parent then
					local on = i <= lit
					cap.Color = if on then Carry.COLOR else Color3.fromRGB(58, 30, 30)
					cap.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
				end
			end
		end
		deckLight.Range = 12 + 12 * frac
		deckLight.Brightness = 0.35 + 1.5 * frac
	end

	-- a crisp light pillar from the lifter toward orbit that fades out
	local function skyFlare(color: Color3, width: number, life: number, delaySecs: number?)
		task.delay(delaySecs or 0, function()
			if not alive or not ctx.alive() then
				return
			end
			local h = 340
			local f = ctx.glow(root, Vector3.new(width, h, width), CFrame.new(liftPos + Vector3.new(0, h / 2, 0)), color, { Name = "OrbitFlare", Transparency = 0.1, CastShadow = false })
			ctx.tween(f, life, { Transparency = 1, Size = Vector3.new(width * 0.2, h, width * 0.2) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			task.delay(life + 0.1, function()
				if f.Parent then
					f:Destroy()
				end
			end)
		end)
	end

	-- the 3-beat load sequence: 1 clamp-down (sparks, clank, camera thump), 2 steam jets + deck escalation, 3 sky flare
	local function loadSequence(idx: number, cell: Cell)
		local clamps = ensureClamps(idx)
		local volatile = cell.volatile == true
		local final = idx >= total
		task.delay(LOAD_SLIDE - 0.05, function()
			if not alive or not ctx.alive() then
				return
			end
			for _, c in clamps do
				if c.part.Parent then
					glide(c.part, CLAMP_SECONDS, c.shut, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				end
			end
			task.delay(CLAMP_SECONDS, function()
				if not alive or not ctx.alive() then
					return
				end
				-- beat 1: the clamps hit
				for _, c in clamps do
					if c.spark.Parent then
						c.spark:Emit(12)
					end
				end
				ctx.sound("HitMetal", liftPos)
				ctx.sound("PodImpact", liftPos)
				ctx.fx("Shake", { p = liftPos, mag = if final then 0.85 else 0.55, r = 60 })
				-- beat 2: pressurised steam, deck flashes up to its new level
				for _, jet in steamJets do
					if jet.Parent then
						jet:Emit(if final then 26 else 16)
					end
				end
				ctx.sound("GasHiss", liftPos)
				if idx >= 2 then
					ctx.sound("LanceHum", liftPos)
				end
				deckLight.Brightness = 3.4
				ctx.tween(deckLight, 0.7, { Brightness = 0.35 + 1.5 * math.clamp(idx / math.max(total, 1), 0, 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				-- beat 3: sky flare (the final cell's double-pulse ignition is fired by beginLaunch)
				task.delay(0.18, function()
					if not alive or not ctx.alive() or final then
						return
					end
					if volatile then
						skyFlare(VOLATILE, 3.6, 1.0)
						skyFlare(Carry.COLOR, 2.0, 1.1, 0.12)
						ctx.fx("Shockwave", { p = liftPos, r = 22 })
					else
						skyFlare(Carry.COLOR, 2.4, 0.8)
					end
					ctx.sound("ShieldUp", liftPos)
				end)
			end)
		end)
	end

	-- ============================================================ cells
	local function buildCell(cf: CFrame, id: number, volatile: boolean?): Cell
		local opts = { Name = "CoreCell", CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }
		local case = ctx.part(root, Carry.SIZE, cf, DARK, Enum.Material.Metal, opts)
		case.Massless = true
		local parts: { BasePart } = { case }
		local function add(p: BasePart)
			p.Anchored = false
			p.Massless = true
			p.CanTouch = false
			local w = Instance.new("Weld")
			w.Part0 = case
			w.Part1 = p
			w.C0 = case.CFrame:ToObjectSpace(p.CFrame)
			w.Parent = p
			table.insert(parts, p)
		end
		-- glowing core band through the middle + steel end caps + a carry handle on top
		local coreColor = if volatile then VOLATILE else Carry.COLOR
		local core = ctx.glow(root, Vector3.new(Carry.SIZE.X * 0.6, Carry.SIZE.Y * 0.62, Carry.SIZE.Z + 0.08), cf, coreColor, { Name = "Core" })
		add(core)
		for _, sx in { -1, 1 } do
			add(ctx.part(root, Vector3.new(0.16, Carry.SIZE.Y + 0.1, Carry.SIZE.Z + 0.1), cf * CFrame.new(sx * (Carry.SIZE.X / 2 - 0.05), 0, 0), STEEL, Enum.Material.Metal, { CanCollide = false, CanQuery = false, CastShadow = false }))
		end
		add(ctx.part(root, Vector3.new(0.9, 0.12, 0.14), cf * CFrame.new(0, Carry.SIZE.Y / 2 + 0.12, 0), STEEL, Enum.Material.Metal, { CanCollide = false, CanQuery = false, CastShadow = false }))
		-- lights the carrier up while the cell is in their arms (on in pickup, off in detach)
		local light = Instance.new("PointLight")
		light.Name = "CarryLight"
		light.Color = if volatile then VOLATILE else Carry.COLOR
		light.Range = 10
		light.Brightness = 1.6
		light.Shadows = false
		light.Enabled = false
		light.Parent = case
		local cell: Cell = {
			id = id,
			case = case,
			parts = parts,
			prompt = nil :: any,
			state = "cache",
			home = cf,
			cache = nil,
			carrier = nil,
			weld = nil,
			marker = nil,
			above = nil,
			everTaken = false,
		}
		if volatile then
			cell.volatile = true
			cell.core = core
			cell.hp = VOLATILE_HP
			cell.hits = 0
			-- pulsing warm light + crackling sparks around the unstable core
			local glow = Instance.new("PointLight")
			glow.Name = "VolatileGlow"
			glow.Color = VOLATILE
			glow.Range = 13
			glow.Brightness = 1.6
			glow.Shadows = false
			glow.Parent = core
			cell.glow = glow
			local sparks = Instance.new("ParticleEmitter")
			sparks.Name = "VolatileSparks"
			sparks.Rate = 8
			sparks.Lifetime = NumberRange.new(0.3, 0.7)
			sparks.Speed = NumberRange.new(3, 9)
			sparks.SpreadAngle = Vector2.new(180, 180)
			sparks.Acceleration = Vector3.new(0, -7, 0)
			sparks.LightEmission = 1
			sparks.Color = ColorSequence.new(VOLATILE_HOT, VOLATILE)
			sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.24), NumberSequenceKeypoint.new(1, 0) })
			sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
			sparks.Parent = core
			cell.sparks = sparks
			-- generous invisible hit volume (CanQuery only while the cell may be shot: see the pulse loop)
			local hb = ctx.part(root, Carry.SIZE + Vector3.new(1.4, 1.4, 1.4), cf, DARK, Enum.Material.SmoothPlastic, {
				Name = "VolatileHit",
				Transparency = 1,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				CastShadow = false,
			})
			add(hb)
			cell.hitbox = hb
		end
		return cell
	end

	-- ============================================================ caches
	local function groundAtXZ(x: number, z: number): number
		local y = if map.groundY then map.groundY(x, z) else top
		if type(y) ~= "number" or y ~= y then
			return top
		end
		return y
	end

	-- the centre of a place on the ground: the map's own number, else the plan's
	local function placeCentre(name: string): Vector3
		local p = if type(map.places) == "table" then map.places[name] else nil
		if typeof(p) == "Vector3" then
			return p
		end
		if name == "spilled" then
			local cr = if type(map.crash) == "table" then map.crash else nil
			local v2 = if cr and typeof(cr.spilled) == "Vector2" then cr.spilled else nil
			if v2 then
				return Vector3.new(v2.X, groundAtXZ(v2.X, v2.Y), v2.Y)
			end
			local cf = map.sites.codes
			if cf then
				return cf.Position
			end
		end
		local v = MapPlan.at(name)
		if v then
			return Vector3.new(v.X, groundAtXZ(v.X, v.Y), v.Y)
		end
		return plaza.Position
	end

	-- where the `n` cells of a place rest: the map's anchors (on the floor), the rest on a ring around the place centre
	local function restSpots(name: string, n: number): { CFrame }
		local out: { CFrame } = {}
		local list = if type(map.anchors) == "table" and type(map.anchors.cellSpots) == "table" then map.anchors.cellSpots[name] else nil
		if type(list) == "table" then
			for _, cf in list do
				if typeof(cf) == "CFrame" and #out < n then
					local p = cf.Position
					local g = groundAtXZ(p.X, p.Z)
					-- an anchor that sank into the ground comes up to it
					table.insert(out, if p.Y < g - 2 then CFrame.new(p.X, g, p.Z) * cf.Rotation else cf)
				end
			end
		end
		if #out < n then
			local c = placeCentre(name)
			for i = #out + 1, n do
				local a = (i - 1) / n * math.pi * 2 + 0.6
				local x, z = c.X + math.cos(a) * 5.5, c.Z + math.sin(a) * 5.5
				table.insert(out, CFrame.new(x, groundAtXZ(x, z), z) * CFrame.Angles(0, a + math.pi, 0))
			end
		end
		return out
	end

	local caches: { any } = {}
	local cacheSpots: { [string]: { CFrame } } = {}
	local placePositions: { [string]: Vector3 } = {}
	for _, name in PLACES do
		placePositions[name] = placeCentre(name)
		local n = counts[name]
		if n > 0 then
			local spots = restSpots(name, n)
			cacheSpots[name] = spots
			table.insert(caches, {
				name = name,
				pos = placePositions[name],
				spots = spots,
				cells = {},
				marker = nil,
				revealed = false,
				activated = false,
				encounter = nil,
				trackPos = nil,
			})
		end
	end

	-- Assign one unique encounter per cell site (never repeated in the same mission)
	HaulEncounters.assign(caches, ctx.rng)
	local encounterMap: { [string]: string } = {}
	for _, cache in caches do
		encounterMap[cache.name] = cache.encounter
	end

	local function cacheLeft(cache: any): number
		local n = 0
		for _, c in cache.cells do
			if c.state == "cache" or c.state == "locked" then
				n += 1
			end
		end
		return n
	end

	local function refreshCacheMarker(cache: any)
		local n = cacheLeft(cache)
		if n <= 0 or not cache.revealed then
			if cache.marker then
				cache.marker:Destroy()
				cache.marker = nil
			end
			return
		end
		local label = PLACE_LABEL[cache.name] or "CORE CELL"
		local cap = if n == 1 then label else (label .. " x" .. n)
		if cache.marker and cache.marker.Parent then
			local l = cache.marker:FindFirstChild("Caption") :: TextLabel?
			if l then
				l.Text = cap
			end
		elseif cache.anchor then
			cache.marker = billboard(cache.anchor, "CacheMarker", cap, Vector3.new(0, 2.6, 0), 1200, 12)
		end
	end

	local pickup: (Cell, Player) -> ()

	-- place twists: ambient crews, carrier draw, per-cell escalation, mid-mission surprise, finale
	local twists = HaulTwists.new(ctx, { liftPos = plaza.Position, places = placePositions, spots = cacheSpots, encounters = encounterMap })

	-- 5-part cradle (plinth, seat, faint glow ring, 2 clamp arms): cells rest in the cradle, not on the ground
	local function buildCradle(f: Instance, spot: CFrame, ringColor: Color3): (Cradle, CFrame)
		local floor = spot.Position
		local _, yaw = spot:ToOrientation()
		local at = CFrame.new(floor) * CFrame.Angles(0, yaw, 0)
		local cradleOpts = { CanCollide = false, CanQuery = false, CastShadow = false }
		local plinth = ctx.cyl(f, 3.3, 0.26, at * CFrame.new(0, 0.13, 0), DARK, Enum.Material.Metal, cradleOpts)
		ctx.part(f, Vector3.new(2.1, 0.12, 1.4), at * CFrame.new(0, 0.30, 0), STEEL, Enum.Material.Metal, cradleOpts)
		local ring = ctx.cyl(f, 2.75, 0.05, at * CFrame.new(0, 0.285, 0), ringColor, Enum.Material.Neon, { CanCollide = false, CanQuery = false, CastShadow = false, Transparency = 0.6 })
		local arms: { CradleArm } = {}
		for _, sz in { -1, 1 } do
			local closedCF = at * CFrame.new(0, PAD_H + 0.44, sz * (Carry.SIZE.Z / 2 + 0.14)) * CFrame.Angles(sz * math.rad(8), 0, 0)
			local openCF = at * CFrame.new(0, PAD_H + 0.38, sz * (Carry.SIZE.Z / 2 + 0.56)) * CFrame.Angles(sz * math.rad(-28), 0, 0)
			local arm = ctx.part(f, Vector3.new(0.46, 0.92, 0.22), closedCF, STEEL, Enum.Material.Metal, cradleOpts)
			table.insert(arms, { part = arm, openCF = openCF })
		end
		local steam = Instance.new("ParticleEmitter")
		steam.Name = "CradleSteam"
		steam.Texture = TEX_SMOKE
		steam.Rate = 0
		steam.Enabled = false
		steam.Lifetime = NumberRange.new(0.45, 0.75)
		steam.Speed = NumberRange.new(3, 6)
		steam.SpreadAngle = Vector2.new(38, 38)
		steam.EmissionDirection = Enum.NormalId.Top
		steam.Acceleration = Vector3.new(0, 2, 0)
		steam.Drag = 2.5
		steam.Rotation = NumberRange.new(0, 360)
		steam.RotSpeed = NumberRange.new(-45, 45)
		steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1.5) })
		steam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
		steam.Color = ColorSequence.new(Color3.fromRGB(220, 235, 245))
		steam.Parent = plinth
		local cradle: Cradle = {
			pos = floor,
			arms = arms,
			ring = ring,
			steam = steam,
			opened = false,
		}
		return cradle, at
	end

	for _, cache in caches do
		local f = Instance.new("Model")
		f.Name = "CellCache"
		f.Parent = root
		local spots: { CFrame } = cache.spots
		for k, spot in spots do
			local cradle, at = buildCradle(f, spot, Carry.COLOR)
			local cell = buildCell(at * CFrame.new(0, PAD_H + Carry.SIZE.Y / 2 + 0.03, 0), #cells + 1)
			cell.cache = cache
			cell.cradle = cradle
			table.insert(cache.cells, cell)
			table.insert(cells, cell)
			-- a short lamp post by the first cell carries the place's marker once revealed
			if k == 1 then
				local post = at * CFrame.new(2.6, 0, 0)
				ctx.cyl(f, 0.35, 3.2, post * CFrame.new(0, 1.6, 0), DARK, Enum.Material.Metal, { CanCollide = false })
				cache.anchor = ctx.ball(f, 0.7, post * CFrame.new(0, 3.4, 0), Carry.COLOR, Enum.Material.Neon, { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
			end
		end
		refreshCacheMarker(cache)
	end

	-- ============================================================ volatile core cells (extra spawns)
	-- 2-3 extra amber cells on cradles along the approaches to the cell places, sidestepped off the direct line to the
	-- lifter so they sit where squads patrol. They are never part of `total`: the required cyan cells stay indestructible.
	do
		local want = if Workspace:GetAttribute("DebugFast") or diff <= 2 then 2 else 3
		local order = table.clone(PLACES)
		for i = #order, 2, -1 do
			local j = ctx.rng:NextInteger(1, i)
			order[i], order[j] = order[j], order[i]
		end
		local lp = plaza.Position
		local floors: { Vector3 } = {}
		for _, name in order do
			if #floors >= want then
				break
			end
			local c = placePositions[name]
			local d = Vector3.new(lp.X - c.X, 0, lp.Z - c.Z)
			local dist = d.Magnitude
			if dist > 70 then
				local dir = d / dist
				local side = Vector3.new(-dir.Z, 0, dir.X) * (if #floors % 2 == 0 then 14 else -14)
				local out = math.min(math.max(dist * 0.42, 26), dist - 45)
				local p = Vector3.new(c.X, 0, c.Z) + dir * out + side
				table.insert(floors, Vector3.new(p.X, groundAtXZ(p.X, p.Z), p.Z))
			end
		end
		local k = 0
		while #floors < want do
			k += 1
			local a = (k / want) * math.pi * 2 + 0.9
			local x, z = lp.X + math.cos(a) * 62, lp.Z + math.sin(a) * 62
			table.insert(floors, Vector3.new(x, groundAtXZ(x, z), z))
		end
		local vf = Instance.new("Model")
		vf.Name = "VolatileCells"
		vf.Parent = root
		for _, floor in floors do
			local spot = CFrame.lookAt(floor, Vector3.new(lp.X, floor.Y, lp.Z))
			local cradle, at = buildCradle(vf, spot, VOLATILE)
			local cell = buildCell(at * CFrame.new(0, PAD_H + Carry.SIZE.Y / 2 + 0.03, 0), #cells + 1, true)
			cell.cradle = cradle
			cell.tag = billboard(cell.case, "VolatileTag", "[VOLATILE]", Vector3.new(0, 3.2, 0), 700, 12, VOLATILE)
			table.insert(cells, cell)
			table.insert(volatiles, cell)
		end
	end

	-- ============================================================ carry helpers
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.RespectCanCollide = true
	rayParams.IgnoreWater = true
	local function groundAt(pos: Vector3): Vector3?
		if pos.Y ~= pos.Y or pos.Y < -40 then
			return nil
		end
		local list: { Instance } = { Workspace.Terrain }
		if map.folder then
			table.insert(list, map.folder)
		end
		table.insert(list, lifter)
		rayParams.FilterDescendantsInstances = list
		local hit = Workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), rayParams)
		if hit then
			return hit.Position
		end
		if map.groundY then
			return Vector3.new(pos.X, map.groundY(pos.X, pos.Z), pos.Z)
		end
		return nil
	end

	local function isNearLifter(pos: Vector3, radius: number): boolean
		local d = pos - liftPos
		return Vector2.new(d.X, d.Z).Magnitude <= radius and math.abs(d.Y) <= LIFT_DY
	end

	local function carryCount(p: Player): number
		local list = carriers[p]
		return if list then #list else 0
	end

	local function setCarryAttr(p: Player, count: number)
		local onVal: boolean? = if count > 0 then true else nil
		local cntVal: number? = if count > 0 then count else nil
		if p.Parent then
			p:SetAttribute(Carry.ATTR, onVal)
			p:SetAttribute(Carry.COUNT_ATTR, cntVal)
		end
		local c = p.Character
		if c then
			c:SetAttribute(Carry.ATTR, onVal)
			c:SetAttribute(Carry.COUNT_ATTR, cntVal)
		end
	end

	local function syncCarrierWelds(p: Player)
		local list = carriers[p]
		if not list or #list == 0 then
			return
		end
		if #list == 1 then
			local c1 = list[1]
			if c1.weld then
				c1.weld.C0 = Carry.HOLD_ONE
			end
			if not c1.above and p.Parent then
				local above = billboard(c1.case, "CarrierIcon", nil, Vector3.new(0, 3.6, 0), 1000, 12)
				above.PlayerToHideFrom = p
				c1.above = above
			end
		else
			if list[1].weld then
				list[1].weld.C0 = Carry.HOLD_TWO_1
			end
			if list[2].weld then
				list[2].weld.C0 = Carry.HOLD_TWO_2
			end
			if list[2].above then
				list[2].above:Destroy()
				list[2].above = nil
			end
		end
	end

	-- unweld from the carrier and anchor at `cf` (the anchor comes AFTER the weld is gone: an anchored part welded to a
	-- character would pin the whole character)
	local function detach(cell: Cell, cf: CFrame)
		local p = cell.carrier
		if p then
			local list = carriers[p]
			if list then
				local idx = table.find(list, cell)
				if idx then
					table.remove(list, idx)
				end
				if #list == 0 then
					carriers[p] = nil
				end
			end
			setCarryAttr(p, carryCount(p))
			syncCarrierWelds(p)
		end
		cell.carrier = nil
		if cell.weld then
			cell.weld:Destroy()
			cell.weld = nil
		end
		local light = cell.case:FindFirstChild("CarryLight")
		if light and light:IsA("PointLight") then
			light.Enabled = false
		end
		if cell.above then
			cell.above:Destroy()
			cell.above = nil
		end
		cell.case.Anchored = true
		cell.case.CFrame = cf
	end

	local function setDroppedMarker(cell: Cell, on: boolean)
		if cell.volatile then
			return -- volatile cells carry their own [VOLATILE] tag
		end
		if on and not cell.marker then
			cell.marker = billboard(cell.case, "DroppedMarker", "CORE CELL", Vector3.new(0, 2.4, 0), 800, 10)
		elseif not on and cell.marker then
			cell.marker:Destroy()
			cell.marker = nil
		end
	end

	local load: (Cell, Player?) -> ()

	local function placeDroppedCell(cell: Cell, pos: Vector3, p: Player?, reason: string)
		if not finished and (isNearLifter(pos, LIFT_DROP_RADIUS) or isNearLifter(cell.case.Position, LIFT_DROP_RADIUS)) then
			load(cell, p)
			return
		end
		local g = groundAt(pos)
		if not g then
			-- fell out of the world: back to its cache slot
			detach(cell, cell.home)
			cell.state = "cache"
			cell.prompt.Enabled = true
			if cell.cache then
				refreshCacheMarker(cell.cache)
			end
		else
			local yaw = CFrame.Angles(0, ctx.rng:NextNumber(0, math.pi * 2), 0)
			detach(cell, CFrame.new(g + Vector3.new(0, Carry.SIZE.Y / 2 + 0.05, 0)) * yaw)
			cell.state = "dropped"
			cell.prompt.Enabled = true
			setDroppedMarker(cell, true)
		end
		if p and reason ~= "leave" then
			callout(p, "Cell down!")
		end
		ctx.sound("Swap", cell.case.Position)
	end

	-- drop carried cell(s) where the carrier stands ("drop" drops one cell at a time; "down"/"leave" drops all)
	local function drop(p: Player, reason: string)
		local list = carriers[p]
		if not list or #list == 0 then
			return
		end
		local r = ctx.getRoot(p)
		local basePos = if r and r.Parent then r.Position else (lastPos[p] or list[#list].case.Position)
		dropLock[p] = os.clock()
		if reason == "drop" then
			placeDroppedCell(list[#list], basePos, p, reason)
		else
			local n = 0
			while carriers[p] and #carriers[p] > 0 do
				local c = carriers[p][#carriers[p]]
				local offset = if n == 0 then Vector3.zero else Vector3.new(1.5, 0, 0)
				n += 1
				placeDroppedCell(c, basePos + offset, p, reason)
			end
		end
	end
	ctl.drop = drop

	-- ============================================================ clues, site reveals & encounters
	local flightLogRead = false
	local flightLogPos: Vector3? = nil
	local flightLogMarker: BillboardGui? = nil
	local flightLogPrompt: ProximityPrompt? = nil
	local encounters: any = nil

	local function syncSiteMarkers(urgent: boolean?)
		local outMarkers: { any } = {}
		local outSites: { any } = {}
		if not finished then
			if not flightLogRead and flightLogPos then
				table.insert(outMarkers, {
					key = "haul_flightlog",
					pos = flightLogPos + Vector3.new(0, 3, 0),
					label = "FLIGHT LOG",
					glyph = "diamondHollow",
					color = LOG_AMBER,
				})
				table.insert(outSites, {
					label = "Crashed drone flight log",
					detail = "REVEALS 2 SITES",
					done = false,
				})
			end
			local hiddenCount = 0
			for _, cache in caches do
				local left = cacheLeft(cache)
				if cache.revealed then
					local label = PLACE_LABEL[cache.name] or "CORE CELL"
					local encTag = HaulEncounters.LABELS[cache.encounter]
					table.insert(outSites, {
						label = label,
						detail = if left <= 0 then "CLEARED" else string.format("%d LEFT  (%s)", left, encTag or "SITE"),
						done = left <= 0,
					})
					if left > 0 then
						local p = cache.trackPos or cache.pos
						table.insert(outMarkers, {
							key = "haul_" .. cache.name,
							pos = p + Vector3.new(0, 4, 0),
							label = if left == 1 then label else (label .. " x" .. left),
							glyph = "diamond",
							color = Carry.COLOR,
						})
					end
				elseif left > 0 then
					hiddenCount += 1
				end
			end
			if hiddenCount > 0 then
				table.insert(outSites, {
					label = string.format("%d uncharted cell %s", hiddenCount, if hiddenCount == 1 then "site" else "sites"),
					detail = "EXPLORE / RADAR",
					done = false,
				})
			end
			-- bonus volatile cells (on a cradle or dropped; hidden while carried)
			for _, v in volatiles do
				if v.case.Parent and (v.state == "cache" or v.state == "dropped") then
					table.insert(outMarkers, {
						key = "haul_vol_" .. v.id,
						pos = v.case.Position + Vector3.new(0, 3.2, 0),
						label = "VOLATILE CELL",
						glyph = "diamondHollow",
						color = VOLATILE,
					})
				end
			end
		end
		entry.markers = outMarkers
		entry.sites = outSites
		ctx.changed(urgent)
	end

	local function revealCache(cache: any, source: string?): boolean
		if cache.revealed then
			return false
		end
		cache.revealed = true
		refreshCacheMarker(cache)
		syncSiteMarkers(true)
		if source == "los" then
			local label = PLACE_LABEL[cache.name] or "CORE CELL"
			if S and S.State then
				S.State.notify(nil, "Cell signal found: " .. label, Carry.COLOR)
			end
			ctx.sound("Pickup", cache.pos)
		end
		return true
	end

	local function revealAllFromRadar()
		if not alive or finished then
			return
		end
		local newly = 0
		for _, cache in caches do
			if not cache.revealed and cacheLeft(cache) > 0 then
				cache.revealed = true
				refreshCacheMarker(cache)
				newly += 1
			end
		end
		if newly > 0 then
			syncSiteMarkers(true)
			if S and S.State then
				S.State.notify(nil, "Cell signal found: ALL SITES (RADAR)", Carry.COLOR)
			end
		end
	end

	-- Crashed cargo drone "Flight Log" prompt: hold E to reveal 2 hidden cell sites
	do
		local anchors = if type(map.anchors) == "table" then map.anchors else nil
		local logPart: BasePart? = nil
		if anchors and typeof(anchors.flightLogPart) == "Instance" and anchors.flightLogPart:IsA("BasePart") then
			logPart = anchors.flightLogPart
		else
			local logCF: CFrame? = if anchors and typeof(anchors.flightLog) == "CFrame" then anchors.flightLog else nil
			if not logCF and typeof(map.insertion) == "CFrame" then
				local p = map.insertion.Position + Vector3.new(10, 0, 0)
				logCF = CFrame.new(p.X, groundAtXZ(p.X, p.Z) + 2.4, p.Z)
			end
			if logCF then
				logPart = ctx.part(root, Vector3.new(1.2, 1.2, 0.4), logCF, LOG_AMBER, Enum.Material.Neon, {
					Name = "FlightLogAnchor",
					Transparency = 0.85,
					CanCollide = false,
					CanQuery = false,
					CastShadow = false,
				})
			end
		end
		if logPart then
			flightLogPos = logPart.Position
			local bb = billboard(logPart, "FlightLogMarker", "FLIGHT LOG", Vector3.new(0, 2.4, 0), 220, 10)
			local g = bb:FindFirstChild("Glyph") :: Frame?
			if g then
				g.BackgroundColor3 = LOG_AMBER
			end
			local cap = bb:FindFirstChild("Caption") :: TextLabel?
			if cap then
				cap.TextColor3 = LOG_AMBER
			end
			flightLogMarker = bb
			flightLogPrompt = ctx.prompt(logPart, {
				action = "Read",
				object = "Flight Log",
				hold = 1.2,
				distance = 9,
				onTrigger = function(player: Player)
					if flightLogRead or not alive or finished then
						return
					end
					flightLogRead = true
					if flightLogPrompt then
						flightLogPrompt.Enabled = false
					end
					if flightLogMarker and flightLogMarker.Parent then
						flightLogMarker:Destroy()
						flightLogMarker = nil
					end
					-- Pick up to 2 unrevealed sites (shuffled)
					local hidden: { any } = {}
					for _, cache in caches do
						if not cache.revealed and cacheLeft(cache) > 0 then
							table.insert(hidden, cache)
						end
					end
					for i = #hidden, 2, -1 do
						local j = ctx.rng:NextInteger(1, i)
						hidden[i], hidden[j] = hidden[j], hidden[i]
					end
					local want = (MapPlan.haul and MapPlan.haul.flightLogReveals) or 2
					local names: { string } = {}
					for i = 1, math.min(want, #hidden) do
						local c = hidden[i]
						c.revealed = true
						refreshCacheMarker(c)
						table.insert(names, PLACE_LABEL[c.name] or c.name)
					end
					syncSiteMarkers(true)
					ctx.sound("ObjectiveDone", logPart.Position)
					if #names > 0 then
						callout(player, "Flight log decoded — marking " .. table.concat(names, " and ") .. "!")
						if S and S.State then
							S.State.notify(nil, "Cell signal found: " .. table.concat(names, " & "), Carry.COLOR)
						end
					else
						callout(player, "Flight log checked — all sites already marked.")
					end
				end,
			})
		else
			flightLogRead = true
		end
	end

	local function completeAttach(cell: Cell, p: Player, torso: BasePart, fromCache: boolean)
		if cell.weld then
			cell.weld:Destroy()
			cell.weld = nil
		end
		local list = carriers[p]
		if not list then
			list = {}
			carriers[p] = list
		end
		table.insert(list, cell)
		local holdCF = if #list >= Carry.MAX_CELLS then Carry.HOLD_TWO_2 else Carry.HOLD_ONE
		-- unanchor first, weld in the same thread (no physics step in between)
		cell.case.Anchored = false
		cell.case.CFrame = torso.CFrame * holdCF
		local w = Instance.new("Weld")
		w.Name = "CarryWeld"
		w.Part0 = torso
		w.Part1 = cell.case
		w.C0 = holdCF
		w.Parent = cell.case
		cell.weld = w
		cell.carrier = p
		cell.state = "carried"
		local light = cell.case:FindFirstChild("CarryLight")
		if light and light:IsA("PointLight") then
			light.Enabled = true
		end
		local r = ctx.getRoot(p)
		lastPos[p] = if r then r.Position else torso.Position
		syncCarrierWelds(p)
		setCarryAttr(p, #list)
		if cell.cache then
			if not cell.cache.revealed then
				revealCache(cell.cache, "los")
			else
				refreshCacheMarker(cell.cache)
				syncSiteMarkers(false)
			end
		end
		callout(p, if cell.volatile then "Volatile cell. Easy." elseif #list >= Carry.MAX_CELLS then "Got a second cell." else "Cell secured.")
		ctx.sound("Pickup", torso.Position)
		if fromCache and cell.cache then
			twists.onLift(cell.cache.name, p)
			if encounters then
				encounters.onCellLift(cell.cache, cell, p)
			end
		end
		if not cell.everTaken then
			cell.everTaken = true
			ctx.intensity("SAMPLE") -- lifting a cell draws attention (same as a sample pickup)
		end
	end

	pickup = function(cell: Cell, p: Player)
		if finished or not alive or carryCount(p) + (picking[p] or 0) >= Carry.MAX_CELLS then
			return
		end
		if cell.state ~= "cache" and cell.state ~= "dropped" then
			return
		end
		if os.clock() - (dropLock[p] or -99) < REPICK_LOCK then
			return
		end
		if S and S.Players and S.Players.getStance and S.Players.getStance(p) == "down" then
			return
		end
		local c = p.Character
		local torso = c and (c:FindFirstChild("UpperTorso") or c:FindFirstChild("HumanoidRootPart")) :: BasePart?
		if not torso then
			return
		end
		local fromCache = cell.state == "cache"
		local cradle = cell.cradle
		local fromCradle = fromCache and cradle ~= nil and not cell.onBelt and (cell.case.Position - cradle.pos).Magnitude < 2.5

		cell.prompt.Enabled = false
		setDroppedMarker(cell, false)

		if not fromCradle then
			completeAttach(cell, p, torso, fromCache)
			return
		end

		-- ~0.6 s "pull it out" beat: open cradle clamps, steam puff + hiss, lift cell into hands
		cell.state = "picking"
		picking[p] = (picking[p] or 0) + 1
		if cradle and not cradle.opened then
			cradle.opened = true
			for _, arm in cradle.arms do
				if arm.part.Parent then
					ctx.tween(arm.part, 0.28, { CFrame = arm.openCF }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
				end
			end
			if cradle.ring.Parent then
				ctx.tween(cradle.ring, 0.4, { Transparency = 0.85 })
			end
			if cradle.steam and cradle.steam.Parent then
				cradle.steam:Emit(14)
			end
			ctx.sound("GasHiss", cradle.pos)
		end

		local startCF = cell.case.CFrame
		local liftCF = startCF + Vector3.new(0, 1.35, 0)
		task.spawn(function()
			local t0 = os.clock()
			while alive and ctx.alive() do
				local elapsed = os.clock() - t0
				if not p.Parent or not ctx.isAlive(p) or p:GetAttribute("Downed") == true
					or (S and S.Players and S.Players.getStance and S.Players.getStance(p) == "down") then
					picking[p] = math.max(0, (picking[p] or 1) - 1)
					if picking[p] == 0 then
						picking[p] = nil
					end
					placeDroppedCell(cell, cell.case.Position, nil, "down")
					return
				end
				local curChar = p.Character
				local curTorso = curChar and (curChar:FindFirstChild("UpperTorso") or curChar:FindFirstChild("HumanoidRootPart")) :: BasePart?
				if not curTorso then
					picking[p] = math.max(0, (picking[p] or 1) - 1)
					if picking[p] == 0 then
						picking[p] = nil
					end
					placeDroppedCell(cell, cell.case.Position, nil, "down")
					return
				end
				if elapsed >= PULL_TIME then
					picking[p] = math.max(0, (picking[p] or 1) - 1)
					if picking[p] == 0 then
						picking[p] = nil
					end
					if finished or carryCount(p) >= Carry.MAX_CELLS then
						placeDroppedCell(cell, curTorso.Position, nil, "drop")
					else
						completeAttach(cell, p, curTorso, fromCache)
					end
					return
				end
				if elapsed < 0.24 then
					local a = elapsed / 0.24
					local ease = 1 - (1 - a) * (1 - a)
					cell.case.CFrame = startCF:Lerp(liftCF, ease)
				else
					local a = (elapsed - 0.24) / (PULL_TIME - 0.24)
					local ease = a * a * (3 - 2 * a)
					local targetHold = if carryCount(p) >= 1 then Carry.HOLD_TWO_2 else Carry.HOLD_ONE
					cell.case.CFrame = liftCF:Lerp(curTorso.CFrame * targetHold, ease)
				end
				RunService.Heartbeat:Wait()
			end
			if p.Parent and picking[p] then
				picking[p] = nil
			end
		end)
	end

	-- ============================================================ volatile core cells: shoot / blast / overload
	-- A volatile cell is only ever shootable or blastable while it rests on a cradle or on the ground ("cache" /
	-- "dropped"). Carried, picking, loaded and already-overloading cells ignore hits and blasts.
	local function volatileLive(cell: Cell): boolean
		return alive and not cell.detonating and cell.case.Parent ~= nil and (cell.state == "cache" or cell.state == "dropped")
	end

	-- out of play for good (loaded or gone): never shootable again, no tag, no sparks
	local function retireVolatile(cell: Cell)
		local i = table.find(volatiles, cell)
		if i then
			table.remove(volatiles, i)
		end
		if cell.hitbox then
			if encounters then
				encounters.removeShootable(cell.hitbox)
			end
			cell.hitbox.CanQuery = false
		end
		if cell.tag then
			cell.tag:Destroy()
			cell.tag = nil
		end
		if cell.sparks then
			cell.sparks.Enabled = false
		end
	end

	-- remove the whole cell (model, tag, prompt, shootable, list entries) before its blast runs
	local function removeVolatileCell(cell: Cell)
		retireVolatile(cell)
		cell.state = "gone"
		local i = table.find(cells, cell)
		if i then
			table.remove(cells, i)
		end
		if cell.above then
			cell.above:Destroy()
			cell.above = nil
		end
		local cr = cell.cradle
		if cr then
			for _, arm in cr.arms do
				if arm.part.Parent then
					ctx.tween(arm.part, 0.2, { CFrame = arm.openCF })
				end
			end
			if cr.ring.Parent then
				cr.ring.Color = Color3.fromRGB(40, 34, 30)
				cr.ring.Transparency = 0.8
			end
			if cr.steam and cr.steam.Parent then
				cr.steam:Emit(18)
			end
		end
		if cell.prompt then
			cell.prompt:Destroy()
		end
		for _, part in cell.parts do
			if part.Parent then
				part:Destroy()
			end
		end
		if cell.case.Parent then
			cell.case:Destroy()
		end
		syncSiteMarkers(false)
	end

	local function detonateVolatile(cell: Cell)
		local pos = cell.case.Position + Vector3.new(0, 1.2, 0)
		local shooter = cell.igniter
		removeVolatileCell(cell)
		if not alive or not ctx.alive() then
			return
		end
		local killed = 0
		if S and S.Explosions and S.Explosions.blast then
			local ok, res = pcall(S.Explosions.blast, pos, {
				radius = VOLATILE_BLAST.radius,
				core = VOLATILE_BLAST.core,
				damage = VOLATILE_BLAST.damage,
				ap = VOLATILE_BLAST.ap,
				knock = VOLATILE_BLAST.knock,
				size = "L",
				style = "emp",
				shake = 1.3,
				shakeRadius = 140,
			}, { player = shooter, kind = "explosion", id = "VOLATILE" })
			if ok and type(res) == "table" then
				killed = res.killed or 0
			end
		end
		-- scorching heat flash on top of the EMP look
		ctx.fx("Explosion", { p = pos, r = 14, size = "M", style = "fire" })
		ctx.fx("Shockwave", { p = pos, r = VOLATILE_EMP_RADIUS })
		ctx.fx("Debris", { p = pos, n = 22, c = VOLATILE, style = "scrap" })
		ctx.fx("Shake", { p = pos, mag = 1.3, r = 120 })
		ctx.sound("ExplosionHuge", pos)
		ctx.sound("EMPPulse", pos)
		-- EMP: robots (COG) are stunned with their shields offline, Brood and heavy behemoths are slowed
		if S and S.Enemies and S.Enemies.getInRadius and S.Enemies.applyStatus then
			local untilT = Workspace:GetServerTimeNow() + VOLATILE_STUN
			local ok, list = pcall(S.Enemies.getInRadius, pos, VOLATILE_EMP_RADIUS)
			if ok and type(list) == "table" then
				for _, e in list do
					if e and e.alive then
						if e.faction == "COG" and e.class ~= "behemoth" then
							S.Enemies.applyStatus(e, "stun", VOLATILE_STUN)
							if e.model then
								e.model:SetAttribute("EmpUntil", untilT)
							end
						else
							S.Enemies.applyStatus(e, "slow", VOLATILE_SLOW_TIME, VOLATILE_SLOW)
						end
					end
				end
			end
		end
		if killed > 0 and shooter and shooter.Parent then
			hitConfirmEv:FireClient(shooter, "pen", pos, true, false, 0)
			ctx.sound("Kill", pos)
		end
		ctx.notify(
			if killed > 0 then string.format("Volatile cell detonated: %d down, hostiles EMP'd!", killed) else "Volatile cell detonated: hostiles EMP'd!",
			VOLATILE
		)
	end

	-- 0.65 s rising whine + frantic strobe, then the blast
	local function igniteVolatile(cell: Cell, shooter: Player?)
		if not volatileLive(cell) then
			return
		end
		cell.detonating = true
		cell.state = "overload"
		cell.igniter = shooter
		cell.prompt.Enabled = false
		if cell.hitbox then
			cell.hitbox.CanQuery = false
		end
		local pos = cell.case.Position
		if cell.tag then
			local l = cell.tag:FindFirstChild("Caption") :: TextLabel?
			if l then
				l.Text = "[OVERLOAD]"
				l.TextColor3 = VOLATILE_HOT
			end
		end
		if cell.sparks then
			cell.sparks.Rate = 60
		end
		ctx.sound("LanceCharge", pos)
		ctx.sound("Telegraph", pos)
		task.spawn(function()
			local t0 = os.clock()
			local core = cell.core
			local baseSize = if core then core.Size else nil
			local lastOn = false
			local beeps = 0
			while alive and ctx.alive() do
				local a = (os.clock() - t0) / VOLATILE_OVERLOAD
				if a >= 1 or not cell.case.Parent then
					break
				end
				-- strobe frequency climbs as the overload builds
				local on = math.floor(a * (7 + 16 * a) * 2) % 2 == 0
				if core and core.Parent then
					core.Color = if on then VOLATILE_HOT else VOLATILE
					if baseSize then
						core.Size = baseSize * (1 + 0.45 * a)
					end
				end
				if cell.glow then
					cell.glow.Brightness = if on then 6 else 1.2
					cell.glow.Range = 14 + 12 * a
				end
				if on and not lastOn and beeps < 6 then
					beeps += 1
					ctx.sound("MineBeep", pos)
				end
				lastOn = on
				task.wait(0.04)
			end
			if not alive or not ctx.alive() or not cell.case.Parent then
				return
			end
			detonateVolatile(cell)
		end)
	end

	-- gunfire: first hit = confirm + sparks, second hit (or one big one) = overload. nil = ignored (carried / loaded).
	local function hitVolatile(cell: Cell, dmg: number, hitPos: Vector3, shooter: Player?): boolean?
		if not volatileLive(cell) then
			return nil
		end
		cell.hits = (cell.hits or 0) + 1
		cell.hp = (cell.hp or VOLATILE_HP) - dmg
		if cell.hp <= 0 or cell.hits >= 2 then
			igniteVolatile(cell, shooter)
			return true
		end
		if cell.sparks then
			cell.sparks:Emit(28)
		end
		if cell.glow then
			cell.glow.Brightness = 6
		end
		if cell.core then
			cell.core.Color = VOLATILE_HOT
		end
		if cell.tag then
			local l = cell.tag:FindFirstChild("Caption") :: TextLabel?
			if l then
				l.Text = "[VOLATILE] UNSTABLE"
			end
		end
		ctx.fx("Debris", { p = hitPos, n = 8, c = VOLATILE, style = "scrap" })
		ctx.sound("HitMetal", hitPos)
		return false
	end

	-- pulsing warm light, tag / hit-volume gating by state, and the compass markers
	task.spawn(function()
		local lastSig = ""
		while alive and ctx.alive() do
			local t = os.clock()
			local sig = ""
			for _, cell in table.clone(volatiles) do
				if cell.case.Parent and not cell.detonating then
					local live = cell.state == "cache" or cell.state == "dropped"
					sig ..= cell.id .. cell.state .. ","
					if cell.hitbox and cell.hitbox.CanQuery ~= live then
						cell.hitbox.CanQuery = live
					end
					if cell.tag and cell.tag.Enabled ~= live then
						cell.tag.Enabled = live
					end
					local pulse = 0.5 + 0.5 * math.sin(t * 5 + cell.id * 1.7)
					if cell.glow then
						cell.glow.Brightness = 1 + 1.6 * pulse
					end
					if cell.core then
						cell.core.Color = VOLATILE:Lerp(VOLATILE_HOT, pulse * 0.4)
					end
				end
			end
			if sig ~= lastSig then
				lastSig = sig
				syncSiteMarkers(false)
			end
			task.wait(0.12)
		end
	end)

	-- ============================================================ delivery + completion
	local launchBeam: BasePart? = nil
	local function collectMovers(): { BasePart }
		local movers: { BasePart } = table.clone(bedParts)
		for _, c in cells do
			if c.state == "loaded" then
				table.insert(movers, c.case)
			end
		end
		return movers
	end

	-- thruster plume + exhaust column under the bed, built by beginLaunch (parts ride along in bedParts)
	local thrusterLive = false
	local thrust: any = {}
	local function buildThrusters()
		if thrust.nozzle then
			return
		end
		local nozzle = ctx.part(lifter, Vector3.new(2.6, 0.3, 2.6), bedCF * CFrame.new(0, -0.35, 0), DARK, Enum.Material.Metal, { Name = "ThrusterNozzle", Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false })
		local plume = ctx.glow(lifter, Vector3.new(2.6, 5, 2.6), bedCF * CFrame.new(0, -2.9, 0), THRUSTER, { Name = "ThrusterPlume", Transparency = 1 })
		local light = Instance.new("PointLight")
		light.Name = "ThrusterLight"
		light.Color = THRUSTER
		light.Range = 30
		light.Brightness = 0
		light.Shadows = false
		light.Parent = nozzle
		local smoke = newBurst("ExhaustSmoke", 22)
		smoke.Texture = TEX_SMOKE
		smoke.Lifetime = NumberRange.new(2.4, 3.4)
		smoke.Speed = NumberRange.new(16, 24)
		smoke.SpreadAngle = Vector2.new(22, 22)
		smoke.EmissionDirection = Enum.NormalId.Bottom
		smoke.Drag = 1.5
		smoke.Rotation = NumberRange.new(0, 360)
		smoke.RotSpeed = NumberRange.new(-40, 40)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 14) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
		smoke.Color = ColorSequence.new(Color3.fromRGB(96, 92, 88), Color3.fromRGB(176, 170, 162))
		smoke.Parent = nozzle
		local fire = newBurst("ExhaustFire", 38)
		fire.Lifetime = NumberRange.new(0.35, 0.55)
		fire.Speed = NumberRange.new(22, 30)
		fire.SpreadAngle = Vector2.new(9, 9)
		fire.EmissionDirection = Enum.NormalId.Bottom
		fire.LightEmission = 1
		fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3.2), NumberSequenceKeypoint.new(1, 0.6) })
		fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
		fire.Color = ColorSequence.new(Color3.fromRGB(255, 230, 160), Color3.fromRGB(255, 90, 30))
		fire.Parent = nozzle
		-- ground blast of dust rolling out along the plaza while the bed is still low (stays on the ground)
		local gb = ctx.part(lifter, Vector3.new(1, 0.2, 1), plaza * CFrame.new(0, 0.6, 2.5), DARK, Enum.Material.SmoothPlastic, { Name = "ExhaustBillow", Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false })
		local dust = newBurst("ExhaustDust", 16)
		dust.Texture = TEX_SMOKE
		dust.Lifetime = NumberRange.new(1.8, 2.6)
		dust.Speed = NumberRange.new(10, 18)
		dust.SpreadAngle = Vector2.new(85, 85)
		dust.EmissionDirection = Enum.NormalId.Top
		dust.Drag = 2
		dust.Rotation = NumberRange.new(0, 360)
		dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 16) })
		dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
		dust.Color = ColorSequence.new(Color3.fromRGB(170, 150, 120), Color3.fromRGB(200, 190, 176))
		dust.Parent = gb
		goalCF[nozzle] = nozzle.CFrame
		goalCF[plume] = plume.CFrame
		table.insert(bedParts, nozzle)
		table.insert(bedParts, plume)
		thrust = { nozzle = nozzle, plume = plume, light = light, smoke = smoke, fire = fire, dust = dust }
	end

	local function blastOffLifter()
		ctx.sound("Generator", liftPos)
		-- the climb tweens are (all but) done: pin every mover to its goal so the blast-off tween starts from a clean CFrame
		settleGlides()
		local movers = collectMovers()
		for _, m in movers do
			if m.Parent then
				m.CanCollide = false
				glide(m, 5.5, m.CFrame + Vector3.new(0, 150, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end
		end
		-- the exhaust roars as the lifter leaves
		if thrust.smoke then
			thrust.smoke.Rate = 70
			thrust.fire.Rate = 90
			thrust.dust.Rate = 40
		end
		task.delay(5.7, function()
			thrusterLive = false
			if thrust.smoke then
				thrust.smoke.Enabled = false
				thrust.fire.Enabled = false
				thrust.dust.Enabled = false
				thrust.light.Enabled = false
			end
			for _, m in movers do
				if m.Parent and m ~= bed then
					m.Transparency = 1
				end
			end
			for _, c in cells do
				if c.state == "loaded" then
					for _, part in c.parts do
						part.Transparency = 1
					end
				end
			end
			bed.Transparency = 1
			if launchBeam and launchBeam.Parent then
				ctx.tween(launchBeam, 1.5, { Transparency = 1 })
			end
		end)
	end

	-- Finale: after the last cell, the lifter climbs for ~50 s while the bar fills and the toughest wave hits
	local function beginLaunch()
		local secs = if Workspace:GetAttribute("DebugFast") then DEBUG_LAUNCH_SECONDS else math.max(math.min(LAUNCH_SECONDS, 20), LAUNCH_SECONDS - launchBonus)
		local st = entry.steps[1]
		st.text = string.format(LAUNCH_FMT, secs)
		st.progress = 0
		syncSiteMarkers(true)
		ctx.setThreat(4)
		setLaunchAlarm(true)
		if S and S.Fx then
			S.Fx.play("HaulLaunchStart", { p = liftPos, dur = secs })
		end
		ctx.notify(string.format("All cells loaded! Defend the cargo lifter while it climbs (%d s)!", secs), Config.Colors.Danger)
		ctx.sound("Klaxon", liftPos)
		ctx.sound("Generator", liftPos)
		ctx.sound("Alarm", liftPos)

		-- Ignition: once the last cell has slid home and the clamps have slammed shut, a double-pulse flare lights the sky,
		-- the thruster plume roars and the exhaust column starts billowing. The climb tween starts CLIMB_DELAY in, after
		-- settleGlides has pinned every loaded cell and clamp to its goal: nothing else ever tweens a mover's CFrame.
		local beam = ctx.glow(lifter, Vector3.new(2.8, 600, 2.8), CFrame.new(liftPos + Vector3.new(0, 300, 0)), PANEL_BLUE, { Transparency = 1 })
		launchBeam = beam
		buildThrusters()
		local igniteAt = LOAD_SLIDE + CLAMP_SECONDS + 0.2
		task.delay(igniteAt, function()
			if not alive or not ctx.alive() then
				return
			end
			ctx.tween(beam, 0.8, { Transparency = 0.42 })
			thrusterLive = true
			ctx.tween(thrust.plume, 0.5, { Transparency = 0.3 })
			thrust.light.Brightness = 3.4
			thrust.smoke.Enabled = true
			thrust.fire.Enabled = true
			thrust.dust.Enabled = true
			ctx.sound("LanceCharge", liftPos)
			ctx.sound("WarnRumble", liftPos)
			ctx.fx("Shake", { p = liftPos, mag = 1.1, r = 120 })
			ctx.fx("Shockwave", { p = liftPos, r = 30 })
			task.spawn(function()
				local rng = ctx.rng
				task.wait(0.5) -- the plume's fade-in tween owns Transparency until then
				while thrusterLive and alive and ctx.alive() do
					if thrust.plume.Parent then
						thrust.plume.Transparency = 0.18 + rng:NextNumber() * 0.28
					end
					thrust.light.Brightness = 2.6 + rng:NextNumber() * 1.6
					task.wait(0.07)
				end
			end)
		end)
		skyFlare(VOLATILE:Lerp(Carry.COLOR, 0.5), 4.2, 0.9, igniteAt)
		skyFlare(Color3.fromRGB(255, 255, 255), 6.5, 1.2, igniteAt + 0.4)
		task.delay(igniteAt + 0.4, function()
			if alive and ctx.alive() then
				ctx.sound("ExplosionSmall", liftPos)
				ctx.fx("Shake", { p = liftPos, mag = 1.3, r = 140 })
			end
		end)
		task.delay(CLIMB_DELAY, function()
			if not alive or not ctx.alive() then
				return
			end
			settleGlides()
			local climbSecs = math.max(1, secs - CLIMB_DELAY)
			for _, m in collectMovers() do
				if m.Parent then
					m.CanCollide = false -- troopers standing on the bed stay on the plaza
					glide(m, climbSecs, m.CFrame + Vector3.new(0, 28, 0), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				end
			end
		end)

		twists.finalWave(secs)
		task.spawn(function()
			local t0 = os.clock()
			local shown = secs
			while alive and ctx.alive() do
				local left = secs - (os.clock() - t0)
				if left <= 0 then
					break
				end
				local whole = math.ceil(left)
				if whole ~= shown then
					shown = whole
					st.text = string.format(LAUNCH_FMT, whole)
					st.progress = math.clamp(1 - left / secs, 0, 1)
					ctx.changed()
				end
				task.wait(0.25)
			end
			if not alive or not ctx.alive() then
				return
			end
			setLaunchAlarm(false)
			ctx.clearWaveWarn()
			if S and S.Fx then
				S.Fx.play("HaulLaunchEnd", { p = liftPos })
			end
			st.text = string.format(STEP_FMT, total, total)
			st.progress = nil
			ctx.completeStep(entry, 1, "Cargo lifter launched! Extraction inbound!")
			blastOffLifter()
			onComplete()
		end)
	end

	local chargeGen = 0
	load = function(cell: Cell, by: Player?)
		if cell.state == "loaded" or cell.state == "overload" or cell.state == "gone" or finished then
			return
		end
		delivered += 1
		local idx = delivered
		local from = cell.case.CFrame
		if cell.carrier then
			detach(cell, from)
		else
			cell.case.Anchored = true
		end
		cell.state = "loaded"
		cell.prompt.Enabled = false
		setDroppedMarker(cell, false)
		if cell.cache then
			refreshCacheMarker(cell.cache)
		end
		-- slide into the slot, then the 3-beat sequence (clamp-down / steam + deck / sky flare); all moves go through glide
		glide(cell.case, LOAD_SLIDE, bedSlot(idx), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		updateDeck(idx)
		loadSequence(idx, cell)
		if cell.volatile then
			-- overcharged delivery: amber-cyan core, shorter launch hold, pulse out from the lifter
			retireVolatile(cell)
			if cell.core then
				cell.core.Color = VOLATILE:Lerp(Carry.COLOR, 0.5)
			end
			if cell.glow then
				cell.glow.Color = VOLATILE:Lerp(Carry.COLOR, 0.5)
				cell.glow.Brightness = 1.6
			end
			launchBonus = math.min(VOLATILE_MAX_BONUS, launchBonus + VOLATILE_LAUNCH_BONUS)
			if S and S.State then
				S.State.notify(nil, string.format("Volatile cell loaded: lifter OVERCHARGED (launch -%d s)", VOLATILE_LAUNCH_BONUS), VOLATILE)
			end
		end
		local light = slotLights[idx]
		if light then
			light.Color = Carry.COLOR
			light.Material = Enum.Material.Neon
		end
		if by then
			callout(by, "Loading cell.")
		end
		ctx.sound("CrateOpen", liftPos)
		ctx.sound("Generator", liftPos)
		local st = entry.steps[1]
		st.progress = delivered / total
		if delivered >= total then
			finished = true
			beginLaunch()
		else
			local threatLvl = if delivered >= 3 or (delivered / math.max(total, 1)) >= 0.65 then 3
				elseif delivered >= 2 then 2
				else 1
			ctx.setThreat(threatLvl)
			-- Short "LIFTER CHARGING x/N" beat + escalating reinforcement wave on every load
			chargeGen += 1
			local myGen = chargeGen
			st.text = string.format(CHARGE_FMT, delivered, total)
			screen.Color = Carry.COLOR
			task.delay(0.7, function()
				if alive and screen.Parent then
					screen.Color = PANEL_BLUE
				end
			end)
			if S and S.State then
				S.State.notify(nil, string.format("Lifter charging %d/%d", delivered, total), Carry.COLOR)
			end
			syncSiteMarkers(true)
			task.delay(3.2, function()
				if alive and not finished and chargeGen == myGen then
					st.text = string.format(STEP_FMT, delivered, total)
					ctx.changed(true)
				end
			end)
			twists.onDelivered(delivered, total)
			if delivered % 2 == 0 then
				ctx.intensity("MAIN_STEP")
			end
		end
	end

	function ctl.stepsDone(): number
		-- reward weight comparable to the other mains (5 steps for a full haul)
		return math.floor(5 * delivered / total)
	end

	-- test hook (DebugHook "solve"): load the next cell straight away
	function ctl.debugSolve(player: Player): boolean
		if finished then
			return false
		end
		local held = carriers[player]
		if held and #held > 0 then
			load(held[#held], player)
			return true
		end
		for _, c in cells do
			if c.state ~= "loaded" and c.state ~= "carried" and not c.volatile then
				if encounters then
					encounters.forceUnlockCell(c)
				end
				load(c, player)
				return true
			end
		end
		return false
	end

	function ctl.onExplosion(pos: Vector3, radius: number)
		if encounters then
			encounters.onExplosion(pos, radius)
		end
	end

	-- prompts (after `pickup` exists)
	for _, cell in cells do
		cell.prompt = ctx.prompt(cell.case, {
			action = "Pick Up",
			object = if cell.volatile then "Volatile Core Cell" else "Core Cell",
			hold = PICK_HOLD,
			distance = 8,
			onTrigger = function(p: Player)
				pickup(cell, p)
			end,
		})
	end

	-- Set up each site's unique encounter (courier / cradle / conveyor / guardian / buried)
	encounters = HaulEncounters.new(ctx, {
		root = root,
		liftPos = liftPos,
		groundAt = groundAt,
		groundAtXZ = function(x: number, z: number): Vector3
			return Vector3.new(x, groundAtXZ(x, z), z)
		end,
		onReveal = function(cache: any)
			revealCache(cache, "los")
		end,
		onSiteUpdated = function(cache: any)
			refreshCacheMarker(cache)
			syncSiteMarkers(true)
		end,
		setDroppedMarker = setDroppedMarker,
		spawnWave = twists.spawnSmallWave,
		wakeAlert = twists.wakeAlert,
	})
	for _, cache in caches do
		encounters.setupCache(cache)
	end

	-- volatile cells: gunfire and nearby blasts set them off (only while resting: see volatileLive)
	for _, cell in volatiles do
		if cell.hitbox then
			encounters.addShootable(cell.hitbox, function(dmg: number, hitPos: Vector3, shooter: Player?): boolean?
				return hitVolatile(cell, dmg, hitPos, shooter)
			end, function(_pos: Vector3)
				igniteVolatile(cell, nil)
			end)
		end
	end

	-- Line-of-sight helper for discovering hidden cell sites (~120 studs)
	local revealDist = (MapPlan.haul and MapPlan.haul.revealDist) or 120
	local closeRevealDist = (MapPlan.haul and MapPlan.haul.closeRevealDist) or 28
	local function hasSiteLOS(fromPos: Vector3, targetPos: Vector3): boolean
		local dir = targetPos - fromPos
		if dir.Magnitude < 2 then
			return true
		end
		local excl: { Instance } = {}
		local ef = Workspace:FindFirstChild("Enemies")
		if ef then
			table.insert(excl, ef)
		end
		for _, p in Players:GetPlayers() do
			if p.Character then
				table.insert(excl, p.Character)
			end
		end
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = excl
		rp.RespectCanCollide = true
		rp.IgnoreWater = true
		local hit = Workspace:Raycast(fromPos, dir, rp)
		if not hit then
			return true
		end
		return (hit.Position - targetPos).Magnitude <= 6
	end

	local radarConn = Workspace:GetAttributeChangedSignal("RadarOnline"):Connect(function()
		if Workspace:GetAttribute("RadarOnline") == true then
			revealAllFromRadar()
		end
	end)

	-- ============================================================ watch loop: carriers, reveals & encounters
	task.spawn(function()
		local revealAcc = 0
		local trackAcc = 0
		while alive and ctx.alive() do
			task.wait(0.1)
			if not alive or not ctx.alive() then
				break
			end
			for p, list in table.clone(carriers) do
				if not p.Parent then
					drop(p, "leave")
					continue
				end
				local r = ctx.getRoot(p)
				local stance = if S and S.Players and S.Players.getStance then S.Players.getStance(p) else "stand"
				local brokenWeld = false
				for _, cell in list do
					local w = cell.weld
					if not w or not w.Parent or not w.Part0 or not w.Part0:IsDescendantOf(Workspace) then
						brokenWeld = true
						break
					end
				end
				if not ctx.isAlive(p) or not r or brokenWeld or stance == "down" or p:GetAttribute("Downed") == true then
					drop(p, "down")
					continue
				end
				lastPos[p] = r.Position
				if isNearLifter(r.Position, LIFT_RADIUS) then
					for _, cell in table.clone(list) do
						load(cell, p)
					end
				end
			end
			if not finished then
				for _, cell in cells do
					if cell.state == "dropped" and isNearLifter(cell.case.Position, LIFT_DROP_RADIUS) then
						load(cell, nil)
					end
				end
			end

			-- Carrier tension: nearby COG drawn modestly toward active carriers
			twists.tickCarriers(carriers)

			-- Step per-site encounters + activate encounters on approach
			if encounters then
				for _, cache in caches do
					if not cache.activated and #ctx.playersNear(cache.pos, 150) > 0 then
						cache.activated = true
						encounters.onSiteActive(cache)
					end
				end
				encounters.step(0.1)
			end

			-- Refresh compass tracking pip when a courier is actively fleeing
			trackAcc += 0.1
			if trackAcc >= 0.8 then
				trackAcc = 0
				for _, cache in caches do
					if cache.revealed and cache.trackPos then
						syncSiteMarkers(false)
						break
					end
				end
			end

			-- Reveal hidden cell sites by LOS (~120 studs) or Radar online
			revealAcc += 0.1
			if not finished and revealAcc >= 0.35 then
				revealAcc = 0
				if Workspace:GetAttribute("RadarOnline") == true then
					revealAllFromRadar()
				else
					local plist = ctx.players()
					for _, cache in caches do
						if not cache.revealed and cacheLeft(cache) > 0 then
							local cPos = cache.pos
							for _, pl in plist do
								local r = ctx.getRoot(pl)
								if r then
									local d = (r.Position - cPos).Magnitude
									if d <= closeRevealDist or (d <= revealDist and hasSiteLOS(r.Position + Vector3.new(0, 3.5, 0), cPos + Vector3.new(0, 4.5, 0))) then
										revealCache(cache, "los")
										break
									end
								end
							end
						end
					end
				end
			end
		end
	end)

	local leaveConn = Players.PlayerRemoving:Connect(function(p)
		if carriers[p] then
			drop(p, "leave")
		end
		picking[p] = nil
		lastPos[p] = nil
		dropLock[p] = nil
	end)

	ctx.setThreat(0)
	ctx.setMarker(entry, liftPos)
	syncSiteMarkers(true)
	ctx.notify(string.format("Inspect the crashed drone's flight log or scout the basin to recover %d core cells.", total), Config.Colors.Friendly)
	twists.start()

	function ctl.stop()
		alive = false
		setLaunchAlarm(false)
		ctx.clearWaveWarn()
		if S and S.Fx then
			S.Fx.play("HaulLaunchEnd", { p = liftPos })
		end
		twists.stop()
		if encounters then
			encounters.stop()
		end
		if flightLogPrompt and flightLogPrompt.Parent then
			flightLogPrompt:Destroy()
			flightLogPrompt = nil
		end
		if flightLogMarker and flightLogMarker.Parent then
			flightLogMarker:Destroy()
			flightLogMarker = nil
		end
		radarConn:Disconnect()
		leaveConn:Disconnect()
		for p, list in carriers do
			setCarryAttr(p, 0)
			for _, cell in list do
				if cell.weld then
					cell.weld:Destroy()
					cell.weld = nil
				end
			end
		end
		table.clear(carriers)
		table.clear(picking)
		table.clear(volatiles)
		thrusterLive = false
	end

	return ctl
end

return HaulCells
