-- S.Extraction: landing pad + terminal at map.extraction. "Call the Skiff" (hold 3 s) starts the ETA
-- (Config.ExtractEta), raises enemy pressure, the Skiff descends onto the pad, players who stand in the
-- ramp zone board it, then it lifts off and onDone(boarded) fires.
--   S.Extraction.start(map, onDone(boarded: {Player}))
--   S.Extraction.stop()
--   S.Extraction.getState() -> {phase = "idle"|"called"|"landing"|"landed"|"leaving", eta = number?, windowEnd = number?}
-- Objects live in workspace.ExtractionObjects (separate from ObjectiveObjects so Objectives.stop() cannot delete them).
-- Mission state is pushed with S.Mission.setExtract({eta = serverTime, window = serverTime?}) when present,
-- otherwise S.State.broadcast("extract", {eta, window}).
-- If nobody boards before the window ends the Skiff leaves anyway and the terminal re-arms (onDone not called).

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local Extraction = {}

local S: any = nil
local runId = 0
local folder: Folder? = nil
local pressureSet = false
local boardedPlayers: { Player } = {}
local welds: { Instance } = {}
local state: any = { phase = "idle" }

local DARK = Color3.fromRGB(44, 48, 58)
local STEEL = Color3.fromRGB(112, 118, 130)
local AMBER = Color3.fromRGB(255, 170, 60)
local WARM_LIGHT = Color3.fromRGB(255, 215, 170) -- lights that reach the sand stay warm/neutral (teal tinted it green)
local LAND_TIME = 7
local LEAVE_TIME = 9 -- liftoff -> gone (client cinematic = RAMP_PRE + LEAVE_TIME, then fade to black and Results)
local RAMP_PRE = 1.5 -- ramp closes before the engines lift the Skiff
local HOVER_Y = 240

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

local function pushExtract(eta: number?, windowEnd: number?)
	local payload = if eta then { eta = eta, window = windowEnd } else nil
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
	local lamp = glow(m, Vector3.new(6, 0.3, 1), cf * CFrame.new(0, 2.5, 0), Color3.fromRGB(255, 246, 220))
	list[#list + 1] = lamp
	addLight(lamp, Color3.fromRGB(255, 246, 220), 22, 1.2)

	-- boarding ramp on a Weld (C0 tweened)
	local ramp = part(m, Vector3.new(10, 0.6, 12), cf * CFrame.new(0, -2.7, 17), STEEL, Enum.Material.DiamondPlate, { Name = "Ramp" })
	local function rampC0(angle: number): CFrame
		return CFrame.new(0, -2.7, 11.2) * CFrame.Angles(math.rad(angle), 0, 0) * CFrame.new(0, 0, 6)
	end
	-- everything but the ramp: welded to the anchored root
	for _, p in list do
		local w = Instance.new("WeldConstraint")
		w.Part0 = rootPart
		w.Part1 = p
		w.Parent = p
		p.Anchored = false
		p.Massless = true
	end
	local weld = Instance.new("Weld")
	weld.Part0 = rootPart
	weld.Part1 = ramp
	weld.C0 = rampC0(-78)
	weld.C1 = CFrame.new()
	weld.Parent = ramp
	ramp.Anchored = false
	ramp.Massless = true
	m.PrimaryPart = rootPart
	m.Parent = parent
	return {
		model = m,
		root = rootPart,
		floor = floor,
		glow = glowParts,
		setRamp = function(down: boolean)
			tween(weld, 1.4, { C0 = rampC0(if down then 12 else -78) })
		end,
	}
end

-- Blender skiff. `cf` = hover/landing reference (the old hull centre); the mesh origin (feet on the ground) sits 4.4 below it, so
-- landing at padTop + 5 puts the skids just above the pad slab. Mesh parts are welded to an invisible anchored Root (moved by the
-- caller's tween); the Ramp hangs on a Weld whose C0 is tweened (rest pose = lowered, closed = -111 deg about X at its hinge).
-- Boarded players are welded to an invisible Floor inside the hull (the hull is opaque, so they simply disappear aboard).
local function buildMeshSkiff(parent: Instance, cf: CFrame): any?
	local piece = SetPieces.spawn(S, "skiff", cf * CFrame.new(0, -4.4, 0), parent, { name = Config.ShuttleName })
	if not piece or not piece.parts.Body or not piece.parts.Ramp then
		if piece then
			piece.model:Destroy()
		end
		return nil
	end
	local m = piece.model
	local rootPart = part(m, Vector3.new(2, 2, 2), cf, DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, Name = "Root" })
	local floor = part(m, Vector3.new(6, 0.5, 14), cf * CFrame.new(0, -2.75, -1), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, Name = "Floor" })
	local ramp = piece.parts.Ramp
	local rampRest = ramp.CFrame
	local rampClosed = SetPieces.swing(piece, "Ramp", CFrame.Angles(math.rad(-111), 0, 0), rampRest)
	local glowParts: { Part } = {}
	for name, p in piece.parts do
		if p ~= ramp then
			local w = Instance.new("WeldConstraint")
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
	local fw = Instance.new("WeldConstraint")
	fw.Part0 = rootPart
	fw.Part1 = floor
	fw.Parent = floor
	floor.Anchored = false
	floor.Massless = true
	local function rampC0(down: boolean): CFrame
		return rootPart.CFrame:ToObjectSpace(if down then rampRest else rampClosed)
	end
	local weld = Instance.new("Weld")
	weld.Part0 = rootPart
	weld.Part1 = ramp
	weld.C0 = rampC0(false)
	weld.C1 = CFrame.new()
	weld.Parent = ramp
	ramp.Anchored = false
	ramp.Massless = true
	ramp.CanCollide = false
	m.PrimaryPart = rootPart
	return {
		model = m,
		root = rootPart,
		floor = floor,
		glow = glowParts,
		seatScale = 0.45,
		setRamp = function(down: boolean)
			if not down then
				ramp.CanCollide = false
			end
			local tw = tween(weld, 1.4, { C0 = rampC0(down) })
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

local function cleanupBoarded()
	for _, w in welds do
		if w.Parent then
			w:Destroy()
		end
	end
	table.clear(welds)
	for _, p in boardedPlayers do
		local ch = p.Character
		if ch then
			ch:SetAttribute("Boarded", nil)
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

	-- boarding zone (fixed, behind the landed Skiff)
	local landedPos = Vector3.new(P.X, padTop + 5, P.Z)
	local zoneCF = CFrame.new(Vector3.new(P.X, padTop + 3, P.Z)) * skiffRot * CFrame.new(0, 0, 16)
	local zoneSize = Vector3.new(16, 8, 18)
	local zonePlate = glow(f, Vector3.new(16, 0.2, 18), zoneCF * CFrame.new(0, -2.75, 0), Config.Colors.Friendly, { Transparency = 1 })
	zonePlate.Name = "BoardZone"
	local pulse = TweenService:Create(zonePlate, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.75 })

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
		local eta = workspace:GetServerTimeNow() + (if workspace:GetAttribute("DebugFast") then 10 else Config.ExtractEta)
		state = { phase = "called", eta = eta }
		pushExtract(eta, nil)
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

		-- hold-out phase: waves until the Skiff starts its descent
		local startDescent = eta - LAND_TIME
		local nextWave = os.clock() + 4
		local waveN = 0
		local told20, told10 = false, false
		while live() and workspace:GetServerTimeNow() < startDescent do
			task.wait(0.5)
			local left = eta - workspace:GetServerTimeNow()
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

		-- descent
		state = { phase = "landing", eta = eta }
		-- approach from the map-centre side: glide in facing the travel direction, then settle (turning onto the pad heading)
		local travelRot = CFrame.lookAt(Vector3.zero, -inward)
		local hoverPos = landedPos + Vector3.new(0, 25, 0)
		skiff = buildSkiff(f, CFrame.new(landedPos + inward * 90 + Vector3.new(0, 70, 0)) * travelRot)
		skiff.setRamp(false)
		if S and S.Fx then
			S.Fx.play("Skiff", { p = landedPos, t = LAND_TIME, phase = "land" })
		end
		sound("SkiffEngine", P)
		local land1 = tween(skiff.root, LAND_TIME * 0.6, { CFrame = CFrame.new(hoverPos) * travelRot }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local land2: Tween? = nil
		land1.Completed:Connect(function(st)
			if st == Enum.PlaybackState.Completed and live() then
				land2 = tween(skiff.root, LAND_TIME * 0.4, { CFrame = CFrame.new(landedPos) * skiffRot }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
			end
		end)
		local t0 = os.clock()
		while live() and os.clock() - t0 < LAND_TIME do
			task.wait(0.5)
			if os.clock() - t0 > 2 and math.floor((os.clock() - t0) * 2) % 4 == 0 then
				if S and S.Fx then
					S.Fx.play("Shake", { p = P, mag = 0.25, r = 120 })
				end
			end
		end
		if not live() then
			return
		end
		land1:Cancel()
		if land2 then
			land2:Cancel()
		end
		skiff.root.CFrame = CFrame.new(landedPos) * skiffRot
		for _, g in skiff.glow do
			g.Transparency = 0.4
		end

		-- boarding window
		local windowEnd = workspace:GetServerTimeNow() + Config.ExtractWindow
		state = { phase = "landed", eta = eta, windowEnd = windowEnd }
		pushExtract(eta, windowEnd)
		skiff.setRamp(true)
		zonePlate.Transparency = 0.6
		pulse:Play()
		sound("Klaxon", P)
		notify(string.format("The %s has landed! Board now - %d s!", Config.ShuttleName, Config.ExtractWindow), Config.Colors.Friendly)
		if S and S.Fx then
			S.Fx.play("Shake", { p = P, mag = 0.6, r = 150 })
		end

		local dwell: { [Player]: number } = {}
		local boarded: { [Player]: boolean } = {}
		local boardedList: { Player } = {}
		local seats = { { -3, -4 }, { 3, -4 }, { -3, 2 }, { 3, 2 }, { 0, -1 } }
		local nextWave2 = os.clock() + 5
		local earlyLeave: number? = nil
		while live() do
			task.wait(0.25)
			local now = workspace:GetServerTimeNow()
			local alive = alivePlayers()
			for _, pl in alive do
				if not boarded[pl] then
					local r = getRoot(pl)
					if r and inZone(r.Position) then
						dwell[pl] = (dwell[pl] or 0) + 0.25
						if dwell[pl] >= 1 then
							boarded[pl] = true
							boardedList[#boardedList + 1] = pl
							boardedPlayers = boardedList
							local seat = seats[math.min(#boardedList, #seats)]
							local seatCF = skiff.root.CFrame * CFrame.new(seat[1] * (skiff.seatScale or 1), -1.4, seat[2])
							local ch = pl.Character
							if ch then
								ch:SetAttribute("Boarded", true)
								-- aboard = safe: Humanoid:TakeDamage is ignored while a ForceField exists (the server keeps the
								-- hull on the pad during the client-animated takeoff, so enemies could still reach them)
								local ff = Instance.new("ForceField")
								ff.Name = "BoardedShield"
								ff.Visible = false
								ff.Parent = ch
								welds[#welds + 1] = ff
								local hum = ch:FindFirstChildOfClass("Humanoid")
								if hum then
									hum.PlatformStand = true
								end
								r.AssemblyLinearVelocity = Vector3.zero
								r.CFrame = seatCF
								local w = Instance.new("WeldConstraint")
								w.Part0 = r
								w.Part1 = skiff.floor
								w.Parent = r
								welds[#welds + 1] = w
							end
							if S and S.State then
								S.State.notify(pl, "Boarded the " .. Config.ShuttleName .. "!", Config.Colors.Friendly)
							end
						end
					else
						dwell[pl] = nil
					end
				end
			end
			-- everyone alive is aboard -> leave shortly
			local aliveCount, aboard = 0, 0
			for _, pl in alive do
				aliveCount += 1
				if boarded[pl] then
					aboard += 1
				end
			end
			if aliveCount > 0 and aboard == aliveCount and not earlyLeave then
				earlyLeave = now + 2.5
				if earlyLeave < windowEnd then
					windowEnd = earlyLeave
					pushExtract(eta, windowEnd)
					notify("Everyone aboard - lifting off!", Config.Colors.Friendly)
				end
			end
			if os.clock() >= nextWave2 and now < windowEnd - 4 and not directorHold then
				nextWave2 = os.clock() + 8
				wave(P, 6)
			end
			if now >= windowEnd then
				break
			end
		end
		if not live() then
			return
		end

		-- liftoff
		state = { phase = "leaving", eta = eta }
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
			local flat = Vector3.new(sun.X, 0, sun.Z)
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
		task.wait(RAMP_PRE)
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
			-- server copy jumps to where every client's local animation ended (boarded characters are welded inside)
			if leaveRoot.Parent then
				leaveRoot.CFrame = skiffPath(landedPos, skiffRot, fly, LEAVE_TIME, LEAVE_TIME)
			end
		end

		if #boardedList > 0 then
			-- full LEAVE_TIME: the boarded players' client takeoff cinematic (client/Fx/WorldFx.luau) fades to black right at the end
			task.wait(LEAVE_TIME)
			if not live() then
				return
			end
			snapToEnd()
			local cb = onDone
			local out = table.clone(boardedList)
			pcall(cb, out)
		else
			-- nobody made it: the Skiff leaves, the terminal re-arms
			notify("Nobody boarded! Call the " .. Config.ShuttleName .. " again.", Config.Colors.Danger)
			pushExtract(nil, nil)
			task.wait(LEAVE_TIME)
			if not live() then
				return
			end
			if skiff and skiff.model then
				skiff.model:Destroy()
			end
			skiff = nil
			state = { phase = "idle" }
			called = false
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
