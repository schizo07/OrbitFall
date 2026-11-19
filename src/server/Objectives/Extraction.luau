-- S.Extraction: landing pad + terminal at map.extraction. "Call the Skiff" (hold 3 s) starts the ETA
-- (Config.ExtractEta), raises enemy pressure, the Skiff arrives and hovers over the pad until the LZ is clear,
-- lands smoothly and stays down, players board via the lit ramp (or hold-E fallback), then it lifts off and
-- onDone(boarded) fires.
--   S.Extraction.start(map, onDone(boarded: {Player}))
--   S.Extraction.stop()
--   S.Extraction.getState() -> {phase = "idle"|"called"|"hovering"|"landing"|"landed"|"leaving", eta = number?, windowEnd = number?}
-- Hot zone: after the ETA the Skiff HOVERS 25-35 studs over the pad and only lands once no live enemy has been within
-- SK.clearRadius (40 studs) for SK.clearHold (3 s) in a row; its door gun shoots enemies near the pad while it hovers,
-- settles and waits landed (server picks targets + damage; clients draw Fx "SkiffGun" / "SkiffHover" in
-- client/Fx/SkiffFx.luau). Once down it stays down until liftoff. Boarding: troopers walk onto the lit ramp (or hold E)
-- to step into the doorway, fade out cleanly and stow inside the hull with no ragdoll or hull clipping.
-- Extract payload extras for the HUD: `label` (status + hostile count), `hold` (true while hovering), `hostiles` (count).
-- Objects live in workspace.ExtractionObjects (separate from ObjectiveObjects so Objectives.stop() cannot delete them).
-- Mission state is pushed with S.Mission.setExtract({eta = serverTime, window = serverTime?}) when present,
-- otherwise S.State.broadcast("extract", {eta, window}).
-- If nobody boards before the window ends the Skiff leaves anyway and the terminal re-arms (onDone not called).

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local EnemyData = require(Shared.Data.Enemies)
local SetPieces = require(script.Parent.SetPieces)

local V3 = Vector3.new
local CF = CFrame.new
local CFA = CFrame.Angles
local C3 = Color3.fromRGB
local INST = Instance.new
local EN = Enum
local WS = workspace
local TK = task

local Extraction = {}

local S: any = nil
local runId = 0
local folder: Folder? = nil
local pressureSet = false
local boardedPlayers: { Player } = {}
local cleanupInsts: { Instance } = {}
local state: any = { phase = "idle" }

local DARK = C3(44, 48, 58)
local STEEL = C3(112, 118, 130)
local AMBER = C3(255, 170, 60)
local WARM_LIGHT = C3(255, 215, 170) -- lights that reach the sand stay warm/neutral (teal tinted it green)
local LEAVE_TIME = 9 -- liftoff -> gone (client cinematic = RAMP_PRE + LEAVE_TIME, then fade to black and Results)
local RAMP_PRE = 1.5 -- ramp closes before the engines lift the Skiff

-- Hot-zone hold (tuning). Distances in studs, times in seconds.
local SK = {
	clearRadius = 40, -- no live enemy within this of the pad centre ...
	clearHold = 3.0, -- ... for this long in a row -> the Skiff lands (and then stays down)
	hoverUp = 26, -- hover height above landedPos (root at padTop + 31, skids ~27 studs above pad)
	hoverMax = 120, -- safety failsafe if an enemy gets stuck out of reach
	approach = 5.0, -- arrival -> hover point
	settle = 3.2, -- hover -> pad (smooth eased descent)
	gunAcquire = 65, -- door gun targets enemies within this of the pad centre (nearest to pad first)
	gunRange = 115, -- max line-of-sight range from the gun muzzle
	gunInterval = 0.38, -- s between heavy bolts (steady fire that helps clear without soloing)
	gunDamage = 65,
	gunAp = 3, -- Medium armour piercing
}

-- Boarding: a trooper on the lit ramp for BOARD_DWELL s (or using the hold-E fallback prompt) steps smoothly to the
-- doorway threshold, fades out cleanly over BOARD_FADE s and is stowed invisible & anchored inside the bay.
local BOARD_DWELL = 0.25
local BOARD_WALK_MAX = 1.4
local BOARD_FADE = 0.45
local DEFAULT_DOOR = CF(0, -1.5, 11.4)
local DEFAULT_FOOT = CF(0, -2.8, 22.4)

-- Studio-only workspace attribute Feel_SkiffMode (mirrored by client/Fx/SkiffFx): "gun" (default) or "nogun".
local function skiffMode(): string
	if not RunService:IsStudio() then
		return "gun"
	end
	local v = WS:GetAttribute("Feel_SkiffMode")
	return if v == "nogun" then "nogun" else "gun"
end

-- Takeoff flight path. MUST stay identical to skiffPath in client/Fx/WorldFx.luau: every client animates the replicated Skiff
-- locally along it (smooth, in sync with the engine Fx and the cinematic camera); the server only snaps it to the end pose.
-- rise HOVER studs while yawing from the pad heading onto the flight heading, then accelerate along `fly` and climb, nose up.
local PATH_HOVER, PATH_DIST, PATH_CLIMB, PATH_RISE = 16, 340, 190, 0.32
local function skiffPath(landed: Vector3, rot: CFrame, fly: Vector3, T: number, tau: number): CFrame
	local flyRot = CFrame.lookAt(Vector3.zero, fly)
	local riseT = T * PATH_RISE
	if tau <= riseT then
		local u = math.clamp(tau / riseT, 0, 1)
		local e = u * u * (3 - 2 * u)
		return CFrame.new(landed + Vector3.new(0, PATH_HOVER * e, 0)) * rot:Lerp(flyRot, e)
	end
	local u = math.clamp((tau - riseT) / (T - riseT), 0, 1)
	local e = u * u
	local pos = landed + Vector3.new(0, PATH_HOVER, 0) + fly * PATH_DIST * e + Vector3.new(0, PATH_CLIMB * e, 0)
	return CFrame.new(pos) * flyRot * CFrame.Angles(math.rad(14) * math.min(1, u * 3), 0, 0)
end

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or Enum.Material.Metal
	p.CastShadow = size.Magnitude > 14
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function glow(parent: Instance, size: Vector3, cf: CFrame, color: Color3, opts: { [string]: any }?): Part
	local o: { [string]: any } = { CanCollide = false, CanQuery = false, CanTouch = false }
	if opts then
		for k, v in opts do
			o[k] = v
		end
	end
	return part(parent, size, cf, color, Enum.Material.Neon, o)
end

local function cyl(parent: Instance, diameter: number, height: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(height, diameter, diameter), cf * CFrame.Angles(0, 0, math.pi / 2), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function zcyl(parent: Instance, diameter: number, length: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = part(parent, Vector3.new(length, diameter, diameter), cf * CFrame.Angles(0, math.pi / 2, 0), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function addLight(p: BasePart, color: Color3, range: number, brightness: number): PointLight
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
	return l
end

local function tween(inst: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.InOut), goal)
	tw:Play()
	return tw
end

-- ---------------------------------------------------------------- player helpers
local function getRoot(player: Player): BasePart?
	if S and S.Players and S.Players.getRoot then
		local ok, r = pcall(S.Players.getRoot, player)
		return if ok then r else nil
	end
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isAlive(player: Player): boolean
	if S and S.Players and S.Players.isAlive then
		return S.Players.isAlive(player) and true or false
	end
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function alivePlayers(): { Player }
	if S and S.Players and S.Players.getAlive then
		return S.Players.getAlive()
	end
	local out = {}
	for _, p in Players:GetPlayers() do
		if isAlive(p) then
			out[#out + 1] = p
		end
	end
	return out
end

local function notify(text: string, color: Color3?)
	if S and S.State then
		S.State.notify(nil, text, color or Config.Colors.Friendly)
	end
end

local function sound(key: string, pos: Vector3?)
	if S and S.Fx then
		S.Fx.play("Sound", { k = key, p = pos })
	end
end

local function pushExtract(eta: number?, windowEnd: number?, extra: { [string]: any }?)
	local payload: any = if eta then { eta = eta, window = windowEnd } else nil
	if payload and extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	if S and S.Mission and S.Mission.setExtract then
		local ok, err = pcall(S.Mission.setExtract, payload)
		if not ok then
			warn("[Extraction] setExtract failed:", err)
		end
	elseif S and S.State then
		S.State.broadcast("extract", payload or {})
	end
end

local function wave(center: Vector3, budget: number)
	local d = S and S.Director
	if d and d.spawnWave then
		local n = math.max(1, #alivePlayers())
		pcall(d.spawnWave, center, math.floor(budget * (0.75 + 0.25 * n) + 0.5))
	end
end

-- ---------------------------------------------------------------- hot zone
local function hostilesNear(center: Vector3, r: number): { any }
	local E = S and S.Enemies
	local out = {}
	if not (E and E.getInRadius) then
		return out
	end
	for _, e in E.getInRadius(center, r) do
		if e.alive and e.root and e.root.Parent and not (e.def and e.def.static) then
			out[#out + 1] = e
		end
	end
	return out
end

-- the mission clock must not run out while the Skiff holds over a hot pad (Mission.setExtract only extends it from the
-- ETA / boarding window); kept at least 45 s ahead, raised in 30 s steps so the HUD clock isn't rebroadcast constantly
local function holdClock()
	local M = S and S.Mission
	if M and M.state == "Extract" and type(M.endsAt) == "number" then
		local now = WS:GetServerTimeNow()
		if M.endsAt < now + 45 then
			M.endsAt = now + 75
			if M.broadcast then
				pcall(M.broadcast)
			end
		end
	end
end

local gunParams = RaycastParams.new()
gunParams.FilterType = EN.RaycastFilterType.Exclude
gunParams.IgnoreWater = true

-- Fallback nose gun position in Root space; side door mounts cover rear/flank targets so bolts never clip the hull.
local NOSE_GUN = CF(0, -3.4, -13.5)

local function gunOrigin(skiff: any, aim: Vector3): Vector3
	local rootCF = skiff.root.CFrame
	local localAim = rootCF:PointToObjectSpace(aim)
	if localAim.Z <= 4 then
		local m = skiff.muzzle
		if m and m.Parent then
			return m.WorldPosition
		end
		local g = skiff.gun
		if g and g.Parent then
			return (g.CFrame * CF(0, -0.3, -math.min(g.Size.Z * 0.5, 2.5))).Position
		end
		return (rootCF * NOSE_GUN).Position
	end
	local side = if localAim.X < 0 then -1 else 1
	return (rootCF * CF(side * 5.6, -1.3, 2.5)).Position
end

-- One door-gun round: nearest enemy to the pad with a clear line from the muzzle. Damage goes through S.Enemies.damage
-- only, so troopers can never be hit. -> true when a round was fired.
local function doorGun(skiff: any, center: Vector3): boolean
	local E = S and S.Enemies
	if not (E and E.damage) or not skiff.root.Parent then
		return false
	end
	local list = hostilesNear(center, SK.gunAcquire)
	if #list == 0 then
		return false
	end
	local function flatDist(e: any): number
		local d = e.root.Position - center
		return V3(d.X, 0, d.Z).Magnitude
	end
	table.sort(list, function(a, b)
		return flatDist(a) < flatDist(b)
	end)
	local exclude: { Instance } = { folder :: any }
	local ef = Workspace:FindFirstChild("Enemies")
	if ef then
		exclude[#exclude + 1] = ef
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			exclude[#exclude + 1] = p.Character
		end
	end
	gunParams.FilterDescendantsInstances = exclude
	for i = 1, math.min(#list, 8) do
		local e = list[i]
		local aim = e.root.Position + V3(0, (e.def.size or 2) * 0.6, 0)
		local gun = gunOrigin(skiff, aim)
		local v = aim - gun
		if v.Magnitude <= SK.gunRange and WS:Raycast(gun, v, gunParams) == nil then
			local faction = EnemyData.Factions[e.faction]
			local mat = if faction and faction.deathStyle == "goo" then "goo" else "metal"
			S.Enemies.damage(e, SK.gunDamage, SK.gunAp, { kind = "skiff" }, "body")
			if S.Fx then
				local jitter = V3(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 1.1
				S.Fx.play("SkiffGun", { a = gun, b = aim + jitter, m = mat })
			end
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------- the Skiff
local function buildPrimitiveSkiff(parent: Instance, cf: CFrame): any
	local m = Instance.new("Model")
	m.Name = Config.ShuttleName
	local rootPart = part(m, Vector3.new(2, 2, 2), cf, DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, Name = "Root" })
	local list: { Part } = {}
	local function add(size: Vector3, off: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
		local p = part(m, size, cf * off, color, mat, opts)
		list[#list + 1] = p
		return p
	end
	local white = Color3.fromRGB(226, 228, 236)
	local orange = Color3.fromRGB(235, 120, 40)
	-- cabin shell (hollow so players can stand inside)
	local floor = add(Vector3.new(12, 0.5, 22), CFrame.new(0, -2.75, 0), Color3.fromRGB(70, 76, 88), Enum.Material.DiamondPlate, { Name = "Floor" })
	add(Vector3.new(0.8, 5.6, 22), CFrame.new(-5.6, 0, 0), white, Enum.Material.SmoothPlastic)
	add(Vector3.new(0.8, 5.6, 22), CFrame.new(5.6, 0, 0), white, Enum.Material.SmoothPlastic)
	add(Vector3.new(12, 0.8, 22), CFrame.new(0, 3, 0), white, Enum.Material.SmoothPlastic)
	add(Vector3.new(12, 5.6, 0.8), CFrame.new(0, 0, -10.8), white, Enum.Material.SmoothPlastic)
	-- nose + cockpit
	add(Vector3.new(10, 4, 7), CFrame.new(0, -0.6, -14) * CFrame.Angles(math.rad(10), 0, 0), white, Enum.Material.SmoothPlastic)
	add(Vector3.new(8, 2.6, 5), CFrame.new(0, 2.6, -11.5) * CFrame.Angles(math.rad(-24), 0, 0), Color3.fromRGB(110, 200, 255), Enum.Material.Glass, { Transparency = 0.25, CanCollide = false })
	-- stripes
	add(Vector3.new(0.3, 1.4, 22), CFrame.new(-6.05, 0.4, 0), orange, Enum.Material.SmoothPlastic, { CanCollide = false })
	add(Vector3.new(0.3, 1.4, 22), CFrame.new(6.05, 0.4, 0), orange, Enum.Material.SmoothPlastic, { CanCollide = false })
	-- wings + engine pods
	local glowParts: { Part } = {}
	for _, s in { -1, 1 } do
		add(Vector3.new(11, 0.8, 9), CFrame.new(s * 11, -0.6, 3) * CFrame.Angles(0, s * math.rad(-12), s * math.rad(5)), Color3.fromRGB(180, 184, 196), Enum.Material.Metal)
		list[#list + 1] = zcyl(m, 5, 12, cf * CFrame.new(s * 14, 0.4, 4), Color3.fromRGB(88, 94, 108), Enum.Material.Metal, { CanCollide = false })
		local n = zcyl(m, 4.2, 0.6, cf * CFrame.new(s * 14, 0.4, 10.3), Color3.fromRGB(120, 200, 255), Enum.Material.Neon, { CanCollide = false, CanQuery = false })
		list[#list + 1] = n
		glowParts[#glowParts + 1] = n
		addLight(n, WARM_LIGHT, 26, 1.4)
		-- landing thrusters (downward)
		local t = cyl(m, 3.6, 0.5, cf * CFrame.new(s * 14, -2.4, 3), AMBER, Enum.Material.Neon, { CanCollide = false, CanQuery = false })
		list[#list + 1] = t
		glowParts[#glowParts + 1] = t
		addLight(t, AMBER, 34, 1.8)
		-- nav lights
		local nav = glow(m, Vector3.new(1.2, 1.2, 1.2), cf * CFrame.new(s * 17, -0.2, 0), if s < 0 then Color3.fromRGB(255, 50, 50) else Color3.fromRGB(70, 255, 120), { Shape = Enum.PartType.Ball })
		list[#list + 1] = nav
		TweenService:Create(nav, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.85 }):Play()
	end
	-- landing legs
	for _, o in { { -4.5, -8 }, { 4.5, -8 }, { -4.5, 8 }, { 4.5, 8 } } do
		list[#list + 1] = cyl(m, 1.2, 2.4, cf * CFrame.new(o[1], -3.9, o[2]), STEEL, Enum.Material.Metal, { CanCollide = false })
		list[#list + 1] = cyl(m, 3.2, 0.4, cf * CFrame.new(o[1], -4.8, o[2]), DARK, Enum.Material.Metal, { CanCollide = false })
	end
	-- name plate
	local plate = part(m, Vector3.new(0.3, 2, 8), cf * CFrame.new(6.08, 1.4, -4), DARK, Enum.Material.SmoothPlastic, { CanCollide = false })
	list[#list + 1] = plate
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Right
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = Vector2.new(400, 100)
	sg.LightInfluence = 0
	sg.Parent = plate
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.Michroma
	tl.Text = string.upper(Config.ShuttleName)
	tl.TextColor3 = AMBER
	tl.TextScaled = true
	tl.Parent = sg
	-- interior light
	local lamp = glow(m, V3(6, 0.3, 1), cf * CF(0, 2.5, 0), C3(255, 246, 220))
	list[#list + 1] = lamp
	addLight(lamp, C3(255, 246, 220), 22, 1.2)
	-- mounted chin autocannon (low part count: mount + barrel + Muzzle attachment)
	add(V3(1.4, 1.0, 2.2), CF(0, -3.1, -11.2), DARK, EN.Material.Metal, { CanCollide = false })
	local gunBarrel = zcyl(m, 0.7, 3.6, cf * CF(0, -3.3, -13.2), STEEL, EN.Material.Metal, { CanCollide = false, Name = "Gun" })
	list[#list + 1] = gunBarrel
	local muzzle = INST("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = V3(1.9, 0, 0) -- zcyl is rotated +90 deg about Y, so +X points along -Z (forward)
	muzzle.Parent = gunBarrel
	-- lit doorway header bar + ramp guide strips (bright friendly glow when the ramp is down)
	local doorCol = Config.Colors.Friendly
	local doorBar = glow(m, V3(8.6, 0.35, 0.45), cf * CF(0, 2.2, 11.1), doorCol, { Transparency = 0.88 })
	list[#list + 1] = doorBar
	local doorLight = addLight(doorBar, doorCol, 28, 0)

	-- boarding ramp on a Weld (C0 tweened)
	local ramp = part(m, V3(10, 0.6, 12), cf * CF(0, -2.7, 17), STEEL, EN.Material.DiamondPlate, { Name = "Ramp" })
	local rampRails: { Part } = {}
	for _, s in { -1, 1 } do
		local rail = glow(m, V3(0.28, 0.2, 11.2), ramp.CFrame * CF(s * 4.65, 0.38, 0), doorCol, { Transparency = 0.88 })
		local rw = INST("WeldConstraint")
		rw.Part0 = ramp
		rw.Part1 = rail
		rw.Parent = rail
		rail.Anchored = false
		rail.Massless = true
		rampRails[#rampRails + 1] = rail
	end
	local function rampC0(angle: number): CFrame
		return CF(0, -2.7, 11.2) * CFA(math.rad(angle), 0, 0) * CF(0, 0, 6)
	end
	-- everything but the ramp: welded to the anchored root
	for _, p in list do
		local w = INST("WeldConstraint")
		w.Part0 = rootPart
		w.Part1 = p
		w.Parent = p
		p.Anchored = false
		p.Massless = true
	end
	local weld = INST("Weld")
	weld.Part0 = rootPart
	weld.Part1 = ramp
	weld.C0 = rampC0(-78)
	weld.C1 = CF()
	weld.Parent = ramp
	ramp.Anchored = false
	ramp.Massless = true
	m.PrimaryPart = rootPart
	m.Parent = parent
	local function setDoorLights(on: boolean)
		local tr = if on then 0.05 else 0.88
		doorBar.Transparency = tr
		doorLight.Brightness = if on then 2.6 else 0
		for _, r in rampRails do
			r.Transparency = tr
		end
	end
	return {
		model = m,
		root = rootPart,
		floor = floor,
		glow = glowParts,
		gun = gunBarrel,
		muzzle = muzzle,
		doorOffset = DEFAULT_DOOR,
		footOffset = DEFAULT_FOOT,
		setRamp = function(down: boolean)
			setDoorLights(down)
			tween(weld, 1.2, { C0 = rampC0(if down then 12 else -78) })
		end,
	}
end

-- Blender skiff. `cf` = hover/landing reference (the old hull centre); the mesh origin (feet on the ground) sits 4.4 below it, so
-- landing at padTop + 5 puts the skids just above the pad slab. Mesh parts are welded to an invisible anchored Root (moved by the
-- caller's tween); the Ramp hangs on a Weld whose C0 is tweened (rest pose = lowered, closed = -111 deg about X at its hinge).
-- Boarded players fade out at the lit doorway and stow invisible & anchored inside the bay.
local function buildMeshSkiff(parent: Instance, cf: CFrame): any?
	local piece = SetPieces.spawn(S, "skiff", cf * CF(0, -4.4, 0), parent, { name = Config.ShuttleName })
	if not piece or not piece.parts.Body or not piece.parts.Ramp then
		if piece then
			piece.model:Destroy()
		end
		return nil
	end
	local m = piece.model
	local rootPart = part(m, V3(2, 2, 2), cf, DARK, EN.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, Name = "Root" })
	local floor = part(m, V3(6, 0.5, 14), cf * CF(0, -2.75, -1), DARK, EN.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, Name = "Floor" })
	local ramp = piece.parts.Ramp
	local gunPart = piece.parts.Gun
	local muzzle = gunPart and gunPart:FindFirstChild("Muzzle", true)
	local rampRest = ramp.CFrame
	local rampClosed = SetPieces.swing(piece, "Ramp", CFA(math.rad(-111), 0, 0), rampRest)
	local glowParts: { Part } = {}
	for name, p in piece.parts do
		if p ~= ramp then
			local w = INST("WeldConstraint")
			w.Part0 = rootPart
			w.Part1 = p
			w.Parent = p
			p.Anchored = false
			p.Massless = true
			if name == "Engine_L" or name == "Engine_R" then
				glowParts[#glowParts + 1] = p :: any
				addLight(p, WARM_LIGHT, 26, 1.4)
			end
		end
	end
	local fw = INST("WeldConstraint")
	fw.Part0 = rootPart
	fw.Part1 = floor
	fw.Parent = floor
	floor.Anchored = false
	floor.Massless = true

	-- Lit ramp rails (welded to the ramp in its lowered pose before closing) + doorway header beacon
	local doorCol = Config.Colors.Friendly
	local hingeWorld = SetPieces.pivot(piece, "Ramp")
	local rampVec = rampRest.Position - hingeWorld
	local doorOffset = DEFAULT_DOOR
	local footOffset = DEFAULT_FOOT
	local rampRails: { Part } = {}
	local doorBarCF = cf * CF(0, 0.4, 10.6)
	if rampVec.Magnitude > 0.5 then
		local rampLen = math.clamp(rampVec.Magnitude * 1.85, 5, 11)
		local halfW = math.clamp(ramp.Size.X * 0.44, 2.2, 4.0)
		local stripCF = CFrame.lookAt(rampRest.Position, rampRest.Position + rampVec.Unit, cf.UpVector)
		for _, s in { -1, 1 } do
			local rail = glow(m, V3(0.26, 0.18, rampLen), stripCF * CF(s * halfW, 0.25, 0), doorCol, { Transparency = 0.88 })
			local rw = INST("WeldConstraint")
			rw.Part0 = ramp
			rw.Part1 = rail
			rw.Parent = rail
			rail.Anchored = false
			rail.Massless = true
			rampRails[#rampRails + 1] = rail
		end
		doorOffset = cf:ToObjectSpace(CF(hingeWorld + V3(0, 1.3, 0)) * cf.Rotation)
		footOffset = cf:ToObjectSpace(CF(hingeWorld + rampVec * 2.15) * cf.Rotation)
		doorBarCF = CF(hingeWorld + V3(0, 3.1, 0)) * cf.Rotation
	end
	local doorBar = glow(m, V3(5.6, 0.32, 0.42), doorBarCF, doorCol, { Transparency = 0.88 })
	local dw = INST("WeldConstraint")
	dw.Part0 = rootPart
	dw.Part1 = doorBar
	dw.Parent = doorBar
	doorBar.Anchored = false
	doorBar.Massless = true
	local doorLight = addLight(doorBar, doorCol, 28, 0)

	local function rampC0(down: boolean): CFrame
		return rootPart.CFrame:ToObjectSpace(if down then rampRest else rampClosed)
	end
	local weld = INST("Weld")
	weld.Part0 = rootPart
	weld.Part1 = ramp
	weld.C0 = rampC0(false)
	weld.C1 = CF()
	weld.Parent = ramp
	ramp.Anchored = false
	ramp.Massless = true
	ramp.CanCollide = false
	m.PrimaryPart = rootPart
	local function setDoorLights(on: boolean)
		local tr = if on then 0.05 else 0.88
		doorBar.Transparency = tr
		doorLight.Brightness = if on then 2.6 else 0
		for _, r in rampRails do
			r.Transparency = tr
		end
	end
	return {
		model = m,
		root = rootPart,
		floor = floor,
		glow = glowParts,
		gun = gunPart,
		muzzle = if muzzle and muzzle:IsA("Attachment") then muzzle else nil,
		doorOffset = doorOffset,
		footOffset = footOffset,
		seatScale = 0.45,
		setRamp = function(down: boolean)
			setDoorLights(down)
			if not down then
				ramp.CanCollide = false
			end
			local tw = tween(weld, 1.2, { C0 = rampC0(down) })
			if down then
				tw.Completed:Once(function()
					if ramp.Parent then
						ramp.CanCollide = true
					end
				end)
			end
		end,
	}
end

local function buildSkiff(parent: Instance, cf: CFrame): any
	return buildMeshSkiff(parent, cf) or buildPrimitiveSkiff(parent, cf)
end

-- ---------------------------------------------------------------- public API
function Extraction.init(registry: any)
	S = registry
end

function Extraction.getState(): any
	return state
end

-- Character properties modified on boarding, saved to restore cleanly in cleanupBoarded.
local faded: { { inst: Instance, t: number } } = {}
local hiddenFx: { { inst: Instance, on: boolean } } = {}
local noCollide: { { part: BasePart, on: boolean } } = {}
local savedRotate: { { hum: Humanoid, on: boolean } } = {}

local function fadeOut(ch: Model, seconds: number)
	for _, d in ch:GetDescendants() do
		if (d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture")) and (d :: any).Transparency < 1 then
			faded[#faded + 1] = { inst = d, t = (d :: any).Transparency }
			tween(d, seconds, { Transparency = 1 }, EN.EasingStyle.Quad, EN.EasingDirection.In)
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			if (d :: any).Enabled then
				hiddenFx[#hiddenFx + 1] = { inst = d, on = true }
				;(d :: any).Enabled = false
			end
		end
	end
end

local function cleanupBoarded()
	for _, w in cleanupInsts do
		if w.Parent then
			w:Destroy()
		end
	end
	table.clear(cleanupInsts)
	for _, f in faded do
		if f.inst.Parent then
			(f.inst :: any).Transparency = f.t
		end
	end
	table.clear(faded)
	for _, h in hiddenFx do
		if h.inst.Parent then
			(h.inst :: any).Enabled = h.on
		end
	end
	table.clear(hiddenFx)
	for _, nc in noCollide do
		if nc.part.Parent then
			nc.part.CanCollide = nc.on
		end
	end
	table.clear(noCollide)
	for _, sr in savedRotate do
		if sr.hum.Parent then
			sr.hum.AutoRotate = sr.on
		end
	end
	table.clear(savedRotate)
	for _, p in boardedPlayers do
		local ch = p.Character
		if ch then
			ch:SetAttribute("Boarded", nil)
			local r = ch:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				r.Anchored = false
			end
			local hum = ch:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.PlatformStand = false
			end
		end
	end
	table.clear(boardedPlayers)
end

function Extraction.stop()
	runId += 1
	state = { phase = "idle" }
	if folder then
		folder:Destroy()
		folder = nil
	end
	local old = Workspace:FindFirstChild("ExtractionObjects")
	if old then
		old:Destroy()
	end
	cleanupBoarded()
	if pressureSet and S and S.Director and S.Director.setPressure then
		pcall(S.Director.setPressure, 1)
	end
	pressureSet = false
end

function Extraction.start(map: any, onDone: (boarded: { Player }) -> ())
	Extraction.stop()
	local myRun = runId
	local function live(): boolean
		return runId == myRun
	end

	local f = Instance.new("Folder")
	f.Name = "ExtractionObjects"
	f.Parent = Workspace
	folder = f

	local P: Vector3 = map.extraction
	local inward = Vector3.new(-P.X, 0, -P.Z)
	inward = if inward.Magnitude > 1 then inward.Unit else Vector3.new(0, 0, -1)
	local skiffRot = CFrame.lookAt(Vector3.zero, inward)
	local padTop = P.Y + 0.6
	local function groundAt(x: number, z: number): number
		return map.groundY(x, z)
	end

	-- landing pad
	local CONCRETE = Color3.fromRGB(70, 72, 78)
	cyl(f, 30, 0.6, CFrame.new(P.X, P.Y + 0.15 - 0.3, P.Z), CONCRETE, Enum.Material.Concrete)
	-- broken concrete chunks break the round edge
	local padRng = Random.new(math.floor(P.X * 31 + P.Z * 17))
	for i = 1, 7 do
		local a = (i / 7) * math.pi * 2 + padRng:NextNumber(-0.25, 0.25)
		local d = padRng:NextNumber(15, 22)
		local cx, cz = P.X + math.cos(a) * d, P.Z + math.sin(a) * d
		local shade = padRng:NextNumber(-6, 6)
		part(
			f,
			Vector3.new(padRng:NextNumber(3, 7), 0.5, padRng:NextNumber(3, 7)),
			CFrame.new(cx, groundAt(cx, cz), cz) * CFrame.Angles(math.rad(padRng:NextNumber(-8, 8)), padRng:NextNumber(0, math.pi), math.rad(padRng:NextNumber(-8, 8))),
			Color3.fromRGB(70 + shade, 72 + shade, 78 + shade),
			Enum.Material.Concrete,
			{ CanCollide = false, CanQuery = false, CanTouch = false }
		)
	end
	-- hazard bollards
	for k = 0, 3 do
		local a = math.pi / 4 + k * math.pi / 2
		local bx, bz = P.X + math.cos(a) * 16, P.Z + math.sin(a) * 16
		local by = groundAt(bx, bz)
		local opts = { CanCollide = false, CanQuery = false, CanTouch = false }
		part(f, Vector3.new(0.8, 2.2, 0.8), CFrame.new(bx, by + 1.1, bz), Color3.fromRGB(230, 170, 40), Enum.Material.Metal, opts)
		part(f, Vector3.new(0.86, 0.4, 0.86), CFrame.new(bx, by + 1.3, bz), Color3.fromRGB(20, 20, 24), Enum.Material.Metal, opts)
	end
	-- Blender pad (4 Light_n glows) on the concrete apron; the old amber ring/cross/lamps stay as the fallback
	local padPiece = SetPieces.spawn(S, "extraction_pad", CFrame.new(P.X, padTop, P.Z) * skiffRot, f, { name = "ExtractionPad" })
	if padPiece then
		local n = 0
		for name, lp in padPiece.parts do
			if string.sub(name, 1, 6) == "Light_" then
				n += 1
				addLight(lp, AMBER, 22, 1.2)
				local tw = TweenService:Create(lp, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, (n % 4) * 0.15), { Transparency = 0.7 })
				tw:Play()
			end
		end
	else
		cyl(f, 52, 0.2, CFrame.new(P.X, padTop + 0.05, P.Z), AMBER, Enum.Material.Neon, { CanCollide = false, Transparency = 0.2 })
		cyl(f, 50.4, 0.3, CFrame.new(P.X, padTop + 0.08, P.Z), Color3.fromRGB(54, 58, 68), Enum.Material.Metal, { CanCollide = false })
		for k = 0, 1 do
			glow(f, Vector3.new(24, 0.1, 1.6), CFrame.new(P.X, padTop + 0.16, P.Z) * skiffRot * CFrame.Angles(0, k * math.pi / 2, 0), AMBER, { Transparency = 0.1 })
		end
		for i = 1, 12 do
			local a = i / 12 * math.pi * 2
			local l = glow(f, Vector3.new(1.6, 0.8, 1.6), CFrame.new(P.X + math.cos(a) * 27, padTop + 0.4, P.Z + math.sin(a) * 27), AMBER)
			TweenService:Create(l, TweenInfo.new(0.6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, true, (i % 4) * 0.15), { Transparency = 0.8 }):Play()
		end
	end

	-- terminal (towards the map centre from the pad)
	local side = Vector3.new(-inward.Z, 0, inward.X)
	local tx, tz = P.X + inward.X * 33 + side.X * 10, P.Z + inward.Z * 33 + side.Z * 10
	local tcf = CFrame.lookAt(Vector3.new(tx, groundAt(tx, tz), tz), Vector3.new(P.X, groundAt(tx, tz), P.Z))
	part(f, Vector3.new(7, 1, 4.4), tcf * CFrame.new(0, 0.5, 0), DARK, Enum.Material.Metal)
	part(f, Vector3.new(5, 4, 3), tcf * CFrame.new(0, 3, 0), STEEL, Enum.Material.Metal)
	local screen = part(f, Vector3.new(4.6, 3, 0.4), tcf * CFrame.new(0, 5.6, -0.7) * CFrame.Angles(math.rad(-16), 0, 0), Color3.fromRGB(12, 18, 28), Enum.Material.SmoothPlastic, { Name = "Screen" })
	part(f, Vector3.new(5.2, 0.4, 3.2), tcf * CFrame.new(0, 5.1, 0), Color3.fromRGB(230, 170, 40), Enum.Material.Metal, { CanCollide = false, CanQuery = false, CanTouch = false })
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = Vector2.new(460, 300)
	sg.LightInfluence = 0
	sg.Brightness = 1.5
	sg.Parent = screen
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(10, 16, 26)
	bg.BorderSizePixel = 0
	bg.Parent = sg
	local t1 = Instance.new("TextLabel")
	t1.BackgroundTransparency = 1
	t1.Size = UDim2.fromScale(0.94, 0.34)
	t1.Position = UDim2.fromScale(0.03, 0.08)
	t1.Font = Enum.Font.Michroma
	t1.Text = "EXTRACTION"
	t1.TextColor3 = AMBER
	t1.TextScaled = true
	t1.Parent = bg
	local t2 = Instance.new("TextLabel")
	t2.BackgroundTransparency = 1
	t2.Size = UDim2.fromScale(0.9, 0.3)
	t2.Position = UDim2.fromScale(0.05, 0.5)
	t2.Font = Enum.Font.GothamBold
	t2.Text = "CALL THE " .. string.upper(Config.ShuttleName)
	t2.TextColor3 = Config.Colors.Text
	t2.TextScaled = true
	t2.Parent = bg
	addLight(screen, WARM_LIGHT, 10, 0.6)
	local screenLight = Instance.new("SurfaceLight")
	screenLight.Face = Enum.NormalId.Front
	screenLight.Color = WARM_LIGHT
	screenLight.Range = 12
	screenLight.Brightness = 1.5
	screenLight.Angle = 120
	screenLight.Shadows = false
	screenLight.Parent = screen
	for _, dx in { -2.2, 2.2 } do
		part(f, Vector3.new(0.5, 9, 0.5), tcf * CFrame.new(dx, 4.5, 1.2), STEEL, Enum.Material.Metal, { CanCollide = false })
	end
	-- tall beacon so the pad can be found from afar
	local beam = glow(f, Vector3.new(1.4, 90, 1.4), CFrame.new(P.X, padTop + 45, P.Z), AMBER, { Transparency = 0.55 })

	-- boarding zone (aligned to the lowered ramp once the Skiff lands)
	local landedPos = V3(P.X, padTop + 5, P.Z)
	local zoneCF = CF(V3(P.X, padTop + 3, P.Z)) * skiffRot * CF(0, 0, 16)
	local zoneSize = V3(12, 8, 14)
	local zonePlate = glow(f, V3(10, 0.16, 12), zoneCF * CF(0, -2.85, 0), Config.Colors.Friendly, { Transparency = 1 })
	zonePlate.Name = "BoardZone"
	local pulse = TweenService:Create(zonePlate, TweenInfo.new(0.7, EN.EasingStyle.Sine, EN.EasingDirection.InOut, -1, true), { Transparency = 0.72 })

	local function inZone(pos: Vector3): boolean
		local lp = zoneCF:PointToObjectSpace(pos)
		return math.abs(lp.X) <= zoneSize.X / 2 and math.abs(lp.Z) <= zoneSize.Z / 2 and math.abs(lp.Y) <= zoneSize.Y / 2 + 2
	end

	local called = false
	local prompt: ProximityPrompt
	local skiff: any = nil

	local function runSequence()
		called = true
		prompt.Enabled = false
		boardedPlayers = {}
		local etaDur = if WS:GetAttribute("DebugFast") then 10 else Config.ExtractEta
		local eta = WS:GetServerTimeNow() + etaDur
		state = { phase = "called", eta = eta }
		pushExtract(eta, nil)
		t2.Text = string.upper(Config.ShuttleName) .. " INBOUND"
		if S and S.Director and S.Director.setPressure then
			pcall(S.Director.setPressure, 1.6)
			pressureSet = true
		end
		sound("Klaxon", P)
		sound("Alarm", P)
		notify(string.format("%s inbound! ETA %d s - hold the pad!", Config.ShuttleName, Config.ExtractEta), Config.Colors.Accent)
		beam.Color = Config.Colors.Friendly
		-- pacing climax: the Director runs continuous, escalating breach waves until liftoff (it replaces the fixed waves below)
		local directorHold = false
		if S and S.Director and S.Director.beginExtractHold then
			local okH, res = pcall(S.Director.beginExtractHold)
			directorHold = okH and res == true
		end

		-- hold-out phase: waves until the Skiff starts its approach (arrives on hover right at ETA)
		local startApproach = eta - SK.approach
		local nextWave = os.clock() + 4
		local waveN = 0
		local told20, told10 = false, false
		while live() and WS:GetServerTimeNow() < startApproach do
			TK.wait(0.5)
			local left = eta - WS:GetServerTimeNow()
			if not told20 and left <= 20 then
				told20 = true
				notify(string.format("%s arrives in 20 seconds!", Config.ShuttleName), Config.Colors.Accent)
			elseif not told10 and left <= 10 then
				told10 = true
				notify("10 seconds - get to the pad!", Config.Colors.Accent)
			end
			if os.clock() >= nextWave and not directorHold then
				waveN += 1
				nextWave = os.clock() + 11
				wave(P, 7 + math.min(waveN, 6))
			end
		end
		if not live() then
			return
		end

		-- approach -> hover over the pad (25-35 studs up)
		local mode = skiffMode()
		local travelRot = CFrame.lookAt(Vector3.zero, -inward)
		skiff = buildSkiff(f, CF(landedPos + inward * 95 + V3(0, 76, 0)) * travelRot)
		skiff.setRamp(false)
		local holdCF = CF(landedPos + V3(0, SK.hoverUp, 0)) * skiffRot
		local landedCF = CF(landedPos) * skiffRot
		local padPos = V3(P.X, padTop, P.Z)

		local hoverFxOn = false
		local function setHoverFx(on: boolean)
			if on == hoverFxOn then
				return
			end
			hoverFxOn = on
			if S and S.Fx then
				S.Fx.play("SkiffHover", if on then { on = true, root = skiff.root, p = padPos, m = skiff.model } else { on = false })
			end
		end
		local nextShot = 0
		local function fireGun()
			if mode == "gun" and os.clock() >= nextShot and doorGun(skiff, P) then
				nextShot = os.clock() + SK.gunInterval
			end
		end
		-- Wait for a CFrame tween to finish naturally (no early Cancel snap) while ticking a step callback.
		local function waitTween(tw: Tween, maxDur: number, stepFn: ((number) -> ())?): boolean
			local done = false
			tw.Completed:Once(function()
				done = true
			end)
			local t0 = os.clock()
			local prev = t0
			while live() and not done and os.clock() - t0 < maxDur + 0.6 do
				TK.wait(0.1)
				local nowC = os.clock()
				local dt = nowC - prev
				prev = nowC
				if stepFn then
					stepFn(dt)
				end
			end
			if not live() then
				tw:Cancel()
				return false
			end
			return true
		end

		sound("SkiffEngine", P)
		local approachTw = tween(skiff.root, SK.approach, { CFrame = holdCF }, EN.EasingStyle.Sine, EN.EasingDirection.Out)
		local approachT0 = os.clock()
		if not waitTween(approachTw, SK.approach, function()
			holdClock()
			local elapsed = os.clock() - approachT0
			if elapsed >= SK.approach - 1.5 then
				setHoverFx(true)
				fireGun()
			end
		end) then
			return
		end

		-- Hover phase: hold 25-35 studs above the LZ until no live hostiles remain within SK.clearRadius (40 studs)
		-- for SK.clearHold (3 s) in a row. Door gun fires steady readable bolts at nearby hostiles.
		local hoverTotal = 0
		local hoverEta = math.min(eta, WS:GetServerTimeNow())
		local function forced(): boolean
			return hoverTotal >= SK.hoverMax
		end
		local function holdUntilClear(): boolean
			state = { phase = "hovering", eta = hoverEta }
			setHoverFx(true)
			t2.Text = "CLEAR THE LZ"
			local initialNear = #hostilesNear(P, SK.clearRadius)
			local lastLabel = ""
			local function publishHover(nearCount: number, clearFor: number)
				local label: string
				if nearCount > 0 then
					label = string.format("CLEAR THE LZ - %d %s", nearCount, if nearCount == 1 then "HOSTILE" else "HOSTILES")
				else
					local rem = math.max(1, math.ceil(SK.clearHold - clearFor))
					label = string.format("LZ CLEAR - LANDING IN %dS", rem)
				end
				if label ~= lastLabel then
					lastLabel = label
					pushExtract(hoverEta, nil, { label = label, hold = true, hostiles = nearCount })
				end
			end
			publishHover(initialNear, 0)
			if initialNear > 0 then
				notify(string.format("%s holding overhead - clear the LZ!", Config.ShuttleName), Config.Colors.Accent)
			end
			local clearFor, last = 0, os.clock()
			while live() do
				TK.wait(0.1)
				local c = os.clock()
				local dt = c - last
				last = c
				hoverTotal += dt
				holdClock()
				local nearCount = #hostilesNear(P, SK.clearRadius)
				if nearCount > 0 then
					clearFor = 0
				else
					clearFor += dt
				end
				publishHover(nearCount, clearFor)
				fireGun()
				if clearFor >= SK.clearHold then
					return true
				end
				if forced() then
					notify(string.format("The %s is coming down under fire!", Config.ShuttleName), Config.Colors.Danger)
					return true
				end
			end
			return false
		end

		-- Smooth eased landing from hover -> pad. Once committed it stays down (never lifts off for new enemies),
		-- and the door gun keeps firing throughout the descent and while landed.
		local function settle(): boolean
			state = { phase = "landing", eta = hoverEta }
			t2.Text = "LANDING..."
			pushExtract(hoverEta, nil, { label = string.upper(Config.ShuttleName) .. " LANDING" })
			if not forced() then
				notify(string.format("LZ clear - the %s is landing!", Config.ShuttleName), Config.Colors.Friendly)
			end
			if S and S.Fx then
				S.Fx.play("Skiff", { p = landedPos, t = SK.settle, phase = "land" })
			end
			local settleTw = tween(skiff.root, SK.settle, { CFrame = landedCF }, EN.EasingStyle.Sine, EN.EasingDirection.InOut)
			if not waitTween(settleTw, SK.settle, function()
				holdClock()
				fireGun()
			end) then
				return false
			end
			setHoverFx(false)
			return true
		end

		if not holdUntilClear() or not settle() then
			return
		end
		for _, g in skiff.glow do
			g.Transparency = 0.4
		end

		-- Align boarding zone + lit ground guide + hold-E fallback prompt to the landed ramp
		local doorOffset = skiff.doorOffset or DEFAULT_DOOR
		local footOffset = skiff.footOffset or DEFAULT_FOOT
		local doorPos = (landedCF * doorOffset).Position
		local footPos = (landedCF * footOffset).Position
		local rampMid = (doorPos + footPos) * 0.5
		local rampSpan = V3(footPos.X - doorPos.X, 0, footPos.Z - doorPos.Z).Magnitude
		zoneCF = CF(rampMid.X, padTop + 3, rampMid.Z) * skiffRot
		zoneSize = V3(12, 8, math.max(rampSpan + 4, 12))
		zonePlate.Size = V3(10, 0.16, math.max(rampSpan + 1, 9))
		zonePlate.CFrame = CF(rampMid.X, padTop + 0.12, rampMid.Z) * skiffRot

		local boardAnchor = part(f, V3(1, 1, 1), CF(doorPos.X, padTop + 2.4, doorPos.Z), DARK, EN.Material.Metal, {
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Name = "BoardPromptAnchor",
		})
		local boardPrompt = INST("ProximityPrompt")
		boardPrompt.ActionText = "Board " .. Config.ShuttleName
		boardPrompt.ObjectText = "Boarding Ramp"
		boardPrompt.HoldDuration = 0.6
		boardPrompt.MaxActivationDistance = 12
		boardPrompt.RequiresLineOfSight = false
		boardPrompt.KeyboardKeyCode = EN.KeyCode.E
		boardPrompt.Enabled = true
		boardPrompt.Parent = boardAnchor

		-- boarding window
		local windowEnd = WS:GetServerTimeNow() + Config.ExtractWindow
		state = { phase = "landed", eta = hoverEta, windowEnd = windowEnd }
		t2.Text = "BOARD NOW"
		pushExtract(hoverEta, windowEnd, { label = "BOARDING" })
		skiff.setRamp(true)
		zonePlate.Transparency = 0.55
		pulse:Play()
		sound("Klaxon", P)
		notify(string.format("The %s has landed! Walk onto the ramp to board - %d s!", Config.ShuttleName, Config.ExtractWindow), Config.Colors.Friendly)
		if S and S.Fx then
			S.Fx.play("Shake", { p = P, mag = 0.6, r = 150 })
		end

		local dwell: { [Player]: number } = {}
		local boarding: { [Player]: boolean } = {} -- stepping into the bay, or aboard
		local boarded: { [Player]: boolean } = {}
		local boardedList: { Player } = {}
		local pending = 0
		local seats = { { -3, -4 }, { 3, -4 }, { -3, 2 }, { 3, 2 }, { 0, -1 } }
		local nextWave2 = os.clock() + 5
		local earlyLeave: number? = nil

		-- One trooper: smoothly walk up the ramp to the lit doorway threshold, fade out cleanly there, then stow
		-- invisible & anchored inside the bay (no ragdoll, no hull clipping).
		-- -> false when cut short (died, respawned, run ended) so they can try again.
		local function boardPlayer(pl: Player): boolean
			local ch = pl.Character
			if not ch or not getRoot(pl) then
				return false
			end
			-- aboard = safe: Humanoid:TakeDamage is ignored while a ForceField exists
			local ff = INST("ForceField")
			ff.Name = "BoardedShield"
			ff.Visible = false
			ff.Parent = ch
			cleanupInsts[#cleanupInsts + 1] = ff
			-- clients own their characters: smooth step to the doorway runs there (client/Fx/SkiffFx "SkiffBoard")
			if S and S.Fx then
				S.Fx.to(pl, "SkiffBoard", { door = doorPos, foot = footPos, m = skiff.model, dur = BOARD_WALK_MAX })
			end
			local function still(): boolean
				return live() and isAlive(pl) and pl.Character == ch
			end
			local t0 = os.clock()
			while still() and os.clock() - t0 < BOARD_WALK_MAX do
				local r = getRoot(pl)
				if r and V3(r.Position.X - doorPos.X, 0, r.Position.Z - doorPos.Z).Magnitude < 2.6 then
					break
				end
				TK.wait(0.08)
			end
			if still() then
				fadeOut(ch, BOARD_FADE)
				if S and S.Fx then
					S.Fx.play("SkiffBoarded", { p = doorPos })
				end
				TK.wait(BOARD_FADE)
			end
			local r = getRoot(pl)
			if not still() or not r then
				if ff.Parent then
					ff:Destroy()
				end
				return false
			end
			boarded[pl] = true
			boardedList[#boardedList + 1] = pl
			boardedPlayers = boardedList
			local seat = seats[math.min(#boardedList, #seats)]
			local seatCF = landedCF * CF(seat[1] * (skiff.seatScale or 1), -1.4, seat[2])
			-- Disable character collisions and anchor root cleanly inside the bay (never PlatformStand / ragdoll)
			for _, d in ch:GetDescendants() do
				if d:IsA("BasePart") and d.CanCollide then
					noCollide[#noCollide + 1] = { part = d, on = true }
					d.CanCollide = false
				end
			end
			local hum = ch:FindFirstChildOfClass("Humanoid")
			if hum then
				savedRotate[#savedRotate + 1] = { hum = hum, on = hum.AutoRotate }
				hum.AutoRotate = false
			end
			ch:SetAttribute("Boarded", true)
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
			r.Anchored = true
			r.CFrame = seatCF -- already 100% faded out: clean stow inside the hull with zero clipping
			if S and S.State then
				S.State.notify(pl, "Boarded the " .. Config.ShuttleName .. "!", Config.Colors.Friendly)
			end
			return true
		end

		local function beginBoard(pl: Player)
			if not live() or state.phase ~= "landed" or boarding[pl] or not isAlive(pl) then
				return
			end
			boarding[pl] = true
			dwell[pl] = nil
			pending += 1
			TK.spawn(function()
				local ok, res = pcall(boardPlayer, pl)
				if not ok then
					warn("[Extraction] boarding failed:", res)
				end
				if not (ok and res) then
					boarding[pl] = nil
				end
				pending -= 1
			end)
		end

		local boardPromptConn = boardPrompt.Triggered:Connect(function(pl: Player)
			local r = getRoot(pl)
			if r and (r.Position - doorPos).Magnitude <= 20 then
				beginBoard(pl)
			end
		end)

		local lastTick = os.clock()
		while live() do
			TK.wait(0.1)
			local c = os.clock()
			local dt = c - lastTick
			lastTick = c
			local now = WS:GetServerTimeNow()
			holdClock()
			local alive = alivePlayers()
			for _, pl in alive do
				if not boarding[pl] then
					local r = getRoot(pl)
					if r and inZone(r.Position) then
						dwell[pl] = (dwell[pl] or 0) + dt
						if dwell[pl] >= BOARD_DWELL then
							beginBoard(pl)
						end
					else
						dwell[pl] = nil
					end
				end
			end
			-- everyone alive is aboard -> leave shortly (keeps existing rules for downed / dead players)
			local aliveCount, aboard = 0, 0
			for _, pl in alive do
				aliveCount += 1
				if boarded[pl] then
					aboard += 1
				end
			end
			if aliveCount > 0 and aboard == aliveCount and not earlyLeave then
				earlyLeave = now + 2.0
				if earlyLeave < windowEnd then
					windowEnd = earlyLeave
					pushExtract(hoverEta, windowEnd, { label = "LIFTING OFF" })
					notify("Everyone aboard - lifting off!", Config.Colors.Friendly)
				end
			end
			if c >= nextWave2 and now < windowEnd - 4 and not directorHold then
				nextWave2 = c + 8
				wave(P, 6)
			end
			-- the door gun keeps firing while landed to cover boarding
			fireGun()
			if now >= windowEnd then
				break
			end
		end
		boardPrompt.Enabled = false
		boardPromptConn:Disconnect()
		if boardAnchor.Parent then
			boardAnchor:Destroy()
		end
		-- troopers already stepping onto the ramp get aboard before it closes
		local waitFrom = os.clock()
		while live() and pending > 0 and os.clock() - waitFrom < BOARD_WALK_MAX + BOARD_FADE + 0.6 do
			TK.wait(0.1)
			fireGun()
		end
		if not live() then
			return
		end
		setHoverFx(false)

		-- liftoff
		state = { phase = "leaving", eta = hoverEta }
		t2.Text = "DEPARTING"
		if directorHold and S.Director and S.Director.endExtractHold then
			pcall(S.Director.endExtractHold) -- the hold-out is over (RELAX; the Director keeps running if nobody boarded)
		end
		pulse:Cancel()
		zonePlate.Transparency = 1
		skiff.setRamp(false)
		-- flight heading: toward the map centre, bent toward the low sun when it is roughly ahead (backlit climb-out shot)
		local fly = inward
		pcall(function()
			local sun = game:GetService("Lighting"):GetSunDirection()
			local flat = V3(sun.X, 0, sun.Z)
			if sun.Y > -0.05 and flat.Magnitude > 0.05 and flat.Unit:Dot(inward) > -0.3 then
				fly = (inward + flat.Unit * 1.3).Unit
			end
		end)
		-- every client runs the takeoff show (and the cinematic for boarded players) starting with the ramp closing;
		-- the Skiff itself is moved locally on each client along skiffPath (see the comment there)
		if S and S.Fx then
			S.Fx.play("Skiff", {
				p = landedPos,
				t = LEAVE_TIME,
				pre = RAMP_PRE,
				phase = "leave",
				fly = fly,
				inward = inward,
				root = skiff.root,
				m = skiff.model,
			})
		end
		TK.wait(RAMP_PRE)
		if not live() then
			return
		end
		if S and S.Fx then
			S.Fx.play("Shake", { p = P, mag = 0.9, r = 160 })
		end
		sound("SkiffEngine", P)
		for _, g in skiff.glow do
			g.Transparency = 0
		end
		local leaveRoot = skiff.root
		local function snapToEnd()
			-- server copy jumps to where every client's local animation ended
			local endCF = skiffPath(landedPos, skiffRot, fly, LEAVE_TIME, LEAVE_TIME)
			if leaveRoot.Parent then
				leaveRoot.CFrame = endCF
			end
			for _, pl in boardedList do
				local r = getRoot(pl)
				if r and r.Parent then
					r.CFrame = endCF * CF(0, -1.4, 0)
				end
			end
		end

		if #boardedList > 0 then
			-- full LEAVE_TIME: the boarded players' client takeoff cinematic (client/Fx/WorldFx.luau) fades to black right at the end
			TK.wait(LEAVE_TIME)
			if not live() then
				return
			end
			snapToEnd()
			local cb = onDone
			local out = table.clone(boardedList)
			if S.MissionStats then
				pcall(S.MissionStats.setBoarded, out) -- after-action report: who made it out
			end
			pcall(cb, out)
		else
			-- nobody made it: the Skiff leaves, the terminal re-arms
			notify("Nobody boarded! Call the " .. Config.ShuttleName .. " again.", Config.Colors.Danger)
			pushExtract(nil, nil)
			TK.wait(LEAVE_TIME)
			if not live() then
				return
			end
			if skiff and skiff.model then
				skiff.model:Destroy()
			end
			skiff = nil
			state = { phase = "idle" }
			called = false
			t2.Text = "CALL THE " .. string.upper(Config.ShuttleName)
			beam.Color = AMBER
			prompt.Enabled = true
			if pressureSet and S and S.Director and S.Director.setPressure then
				pcall(S.Director.setPressure, 1)
				pressureSet = false
			end
		end
	end

	prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Call the " .. Config.ShuttleName
	prompt.ObjectText = "Extraction Terminal"
	prompt.HoldDuration = 3
	prompt.MaxActivationDistance = 11
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	local function onCall(player: Player, force: boolean?)
		if not live() or called or not prompt.Enabled then
			return
		end
		if not isAlive(player) then
			return
		end
		local r = getRoot(player)
		if not force and (not r or (r.Position - screen.Position).Magnitude > 20) then
			return
		end
		task.spawn(runSequence)
	end
	prompt.Triggered:Connect(onCall)
	local dbg = Instance.new("BindableEvent")
	dbg.Name = "DebugTrigger"
	dbg.Event:Connect(function(player)
		onCall(player, true)
	end)
	dbg.Parent = prompt
	prompt.Parent = screen
end

return Extraction
