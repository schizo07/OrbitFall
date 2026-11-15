-- Throw arc: while a call-in beacon is armed, or the grenade button is held, draws the predicted flight path (pooled
-- dots) and a landing ring that lies on the surface it hits. The path comes from shared/Throw, the same launch maths
-- the server uses (CallInService beacon throw, WeaponService grenades), so the arc shows where the throw really goes.
-- The ring's radius is the blast radius (Data/Blasts over the call-in params / grenade splash) when there is one.
--
-- Grenades: by default the grenade is thrown on RELEASE (hold to aim with the arc, a quick tap still throws at once).
-- WeaponController calls ThrowArc.grenadeEdge(down) from its Grenade handler to get "throw now".
--
-- 2026-11-15 playtest: the path is a solid line ending in an arrowhead, with a see-through "ghost" grenade / beacon where
-- it lands. The ring always lies flat on the ground: a hit on a wall or ledge side drops to the ground below it (it used
-- to stand up along the wall: "weird areas" at edges, grenades and 500KG alike).
-- Studio A/B (client/Variants):
--   Feel_ThrowArc     nil = arrow + ghost + ring, "dots" = old dots + ring, "ring" = ring only, "off" = nothing
--   Feel_GrenadeThrow nil = hold to aim, throw on release; "press" = throw on press (old)   (group GRENADE THROW)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Throw = require(Shared.Throw)
local Aim = require(Shared.Aim)
local CallIns = require(Shared.Data.CallIns)
local Blasts = require(Shared.Data.Blasts)
local Weapons = require(Shared.Data.Weapons)

local Store = require(script.Parent.Store)
local Input = require(script.Parent.Input)
local CombatPose = require(script.Parent.CombatPose)

local ThrowArc = {}

local player = Players.LocalPlayer
local PARK = CFrame.new(0, -5000, 0)
local DOT_DT = 0.055 -- seconds of flight between dots
local MAX_DOTS = 28
local STEP_DT = 0.06 -- seconds per raycast segment
local MAX_STEPS = 45
local RING_SEGS = 16
local GRENADE_COLOR = Color3.fromRGB(255, 160, 70)
local BEACON_COLORS = {
	offense = Config.Colors.BeaconOffense,
	supply = Config.Colors.BeaconSupply,
	defense = Config.Colors.BeaconDefense,
}

local aimPointFn: ((number, number?) -> Vector3)? = nil
local isHoldingFn: (() -> boolean)? = nil
local heldIdFn: (() -> string?)? = nil

local folder: Folder? = nil
local dots: { BasePart } = {}
local ringSegs: { BasePart } = {}
local disc: BasePart? = nil
local lines: { BasePart } = {}
local LINE_W = 0.13
local HEAD_LEN, HEAD_ANGLE = 0.9, math.rad(32)
local allParts: { BasePart } = {}
local parkCFs: { CFrame } = {}
local shown = false
local curColor: Color3? = nil
local curRadius = -1

local grenadeHeld = false
local beaconHiddenUntil = 0

local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.IgnoreWater = true
local filterAt = 0
local filterMode = ""

local function mkPart(shape: Enum.PartType, size: Vector3, transparency: number): BasePart
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.CFrame = PARK
	p.Parent = folder
	table.insert(allParts, p)
	table.insert(parkCFs, PARK)
	return p
end

local function build()
	local f = Instance.new("Folder")
	f.Name = "ThrowArc"
	f.Parent = workspace.CurrentCamera or workspace
	folder = f
	for i = 1, MAX_DOTS do
		dots[i] = mkPart(Enum.PartType.Ball, Vector3.new(0.32, 0.32, 0.32), 0.15)
	end
	for i = 1, RING_SEGS do
		ringSegs[i] = mkPart(Enum.PartType.Block, Vector3.new(1, 0.12, 0.22), 0.1)
	end
	disc = mkPart(Enum.PartType.Cylinder, Vector3.new(0.06, 2, 2), 0.75)
	-- arrow: line segments, two arrowhead arms, the ghost at the landing point (order = the cfs order in step)
	for i = 1, MAX_DOTS do
		lines[i] = mkPart(Enum.PartType.Block, Vector3.new(LINE_W, LINE_W, 1), 0.2)
	end
	mkPart(Enum.PartType.Block, Vector3.new(LINE_W * 1.6, LINE_W * 1.6, HEAD_LEN), 0.05)
	mkPart(Enum.PartType.Block, Vector3.new(LINE_W * 1.6, LINE_W * 1.6, HEAD_LEN), 0.05)
	local ghost = mkPart(Enum.PartType.Ball, Vector3.new(0.75, 0.75, 0.75), 0.55)
	ghost.Material = Enum.Material.ForceField
end

local function hide()
	if not shown then
		return
	end
	shown = false
	workspace:BulkMoveTo(allParts, parkCFs, Enum.BulkMoveMode.FireCFrameChanged)
end

local function setColor(c: Color3)
	if curColor == c then
		return
	end
	curColor = c
	for _, p in allParts do
		p.Color = c
	end
end

local function setRadius(r: number)
	if math.abs(curRadius - r) < 0.05 then
		return
	end
	curRadius = r
	local seg = 2 * math.pi * r / RING_SEGS * 1.08
	for _, p in ringSegs do
		p.Size = Vector3.new(seg, 0.12, math.clamp(r * 0.06, 0.18, 0.5))
	end
	if disc then
		disc.Size = Vector3.new(0.06, r * 2, r * 2)
	end
end

-- Beacons ignore enemies, characters and call-in objects (CallInService world params); grenades bounce off enemies.
local function params(mode: string): RaycastParams
	local t = os.clock()
	if mode ~= filterMode or t - filterAt > 0.5 then
		filterMode, filterAt = mode, t
		local list: { Instance } = {}
		if folder then
			table.insert(list, folder)
		end
		local cio = workspace:FindFirstChild("CallInObjects")
		if cio then
			table.insert(list, cio)
		end
		if mode == "beacon" then
			local en = workspace:FindFirstChild("Enemies")
			if en then
				table.insert(list, en)
			end
			for _, p in Players:GetPlayers() do
				if p.Character then
					table.insert(list, p.Character)
				end
			end
		elseif player.Character then
			table.insert(list, player.Character)
		end
		worldParams.FilterDescendantsInstances = list
	end
	return worldParams
end

-- CFrame on the surface point whose +Y follows the normal
local function surfaceCF(pos: Vector3, n: Vector3): CFrame
	local ref = if math.abs(n.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local x = ref:Cross(n).Unit
	local z = x:Cross(n)
	return CFrame.fromMatrix(pos + n * 0.08, x, n, z)
end

local function feel(): string
	local v = workspace:GetAttribute("Feel_ThrowArc")
	return if type(v) == "string" then v else "arrow"
end

local function grenadeOnRelease(): boolean
	return workspace:GetAttribute("Feel_GrenadeThrow") ~= "press"
end

local function blastRadius(id: string, base: { [string]: any }?): number
	local b = Blasts.merge(id, base)
	local r = b.radius or b.blast
	return if type(r) == "number" then r else 0
end

-- what is being thrown right now: mode, launch, colour, ring radius
local function current(): (string?, any, Color3?, number)
	local m = Store.get("me")
	if not m or not m.alive or m.dropping or Store.get("menuOpen") or not aimPointFn then
		return nil, nil, nil, 0
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil, nil, nil, 0
	end
	local holding = isHoldingFn and isHoldingFn()
	if holding and os.clock() >= beaconHiddenUntil then
		local id = heldIdFn and heldIdFn()
		local def = id and CallIns.get(id)
		local hand = char and (char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm"))
		local handPos = if hand and hand:IsA("BasePart") then hand.Position else nil
		local aim = aimPointFn(Throw.BEACON_MAX_RANGE, 0)
		local launch = Throw.beacon(root.Position, root.CFrame.LookVector, handPos, aim, workspace.Gravity)
		local r = def and blastRadius(def.id, def.params) or 0
		local color = def and BEACON_COLORS[def.beacon] or Config.Colors.BeaconOffense
		return "beacon", launch, color, math.clamp(if r > 0 then r else 2.5, 2.5, 30)
	end
	if grenadeHeld and not holding and not Store.get("dialOpen") and (m.grenades or 0) > 0 and not Input.isGated("Grenade") then
		local origin = Aim.origin(char, CombatPose.handSign())
		if not origin then
			return nil, nil, nil, 0
		end
		local aim = aimPointFn(60, 0)
		local gid = m.grenadeId or "FRAG"
		local gw = Weapons.get(gid)
		local r = blastRadius(gid, gw and gw.splash)
		return "grenade", Throw.grenade(origin, aim, workspace.Gravity), GRENADE_COLOR, math.clamp(if r > 0 then r else 3, 2, 30)
	end
	return nil, nil, nil, 0
end

local cfs: { CFrame } = {}
local function step()
	local look = feel()
	local mode, launch, color, radius = current()
	if look == "off" or not mode or not launch then
		hide()
		return
	end
	if not folder or not folder.Parent then
		table.clear(allParts)
		table.clear(parkCFs)
		build()
		curColor, curRadius = nil, -1
	end

	-- trace the path until it hits something
	local rp = params(mode)
	local prev = launch.origin
	local tHit = MAX_STEPS * STEP_DT
	local hitPos, hitN = nil, nil
	for i = 1, MAX_STEPS do
		local t = i * STEP_DT
		local cur = Throw.at(launch, t)
		local r = workspace:Raycast(prev, cur - prev, rp)
		if r then
			local seg = (cur - prev).Magnitude
			local frac = if seg > 1e-3 then (r.Position - prev).Magnitude / seg else 1
			tHit = (i - 1 + frac) * STEP_DT
			hitPos, hitN = r.Position, r.Normal
			break
		end
		prev = cur
	end

	setColor(color :: Color3)
	setRadius(radius)
	table.clear(cfs)
	-- dots: march along the path (phase scrolls with time); fewer on phones
	local spacing = if Input.isTouch() then DOT_DT * 1.5 else DOT_DT
	local phase = (os.clock() * 0.9) % 1
	for i = 1, MAX_DOTS do
		local t = (i - 1 + phase) * spacing + 0.04
		if look == "dots" and t < tHit - 0.02 then
			table.insert(cfs, CFrame.new(Throw.at(launch, t)))
		else
			table.insert(cfs, PARK)
		end
	end
	-- landing ring: flat on the ground. A hit on a wall / ledge side looks for the ground below it; a steep slope or no
	-- ground found keeps a level ring at the hit point.
	local ringPos, ringN = hitPos, hitN
	if hitPos and hitN and hitN.Y < 0.7 then
		local down = workspace:Raycast(hitPos + hitN * 0.6 + Vector3.new(0, 0.3, 0), Vector3.new(0, -80, 0), rp)
		if down and down.Normal.Y >= 0.7 then
			ringPos, ringN = down.Position, down.Normal
		else
			ringN = Vector3.yAxis
		end
	end
	if ringPos and ringN then
		local base = surfaceCF(ringPos, ringN)
		for i = 1, RING_SEGS do
			local a = (i - 0.5) / RING_SEGS * math.pi * 2
			local off = Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
			-- tangent along local X: rotate about the normal so the segment's length follows the circle
			table.insert(cfs, base * CFrame.new(off) * CFrame.Angles(0, -a - math.pi / 2, 0))
		end
		table.insert(cfs, base * CFrame.Angles(0, 0, math.pi / 2))
	else
		for _ = 1, RING_SEGS + 1 do
			table.insert(cfs, PARK)
		end
	end
	-- arrow: a solid line along the path to the hit, an arrowhead (V facing the camera) at its end, the ghost on the spot
	if look == "arrow" then
		local tEnd = tHit
		local segT = tEnd / MAX_DOTS
		local a = Throw.at(launch, 0.04)
		local lastDir = Vector3.zAxis
		for i = 1, MAX_DOTS do
			local b = Throw.at(launch, math.max(0.04, i * segT))
			local d = b - a
			local len = d.Magnitude
			if len > 0.02 then
				lastDir = d.Unit
				lines[i].Size = Vector3.new(LINE_W, LINE_W, len + LINE_W)
				table.insert(cfs, CFrame.lookAt((a + b) / 2, b))
			else
				table.insert(cfs, PARK)
			end
			a = b
		end
		local tip = Throw.at(launch, tEnd)
		local cam = workspace.CurrentCamera
		local side = lastDir:Cross(if cam then cam.CFrame.LookVector else Vector3.yAxis)
		side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
		for _, sgn in { 1, -1 } do
			local armDir = -lastDir * math.cos(HEAD_ANGLE) + side * sgn * math.sin(HEAD_ANGLE)
			local c = tip + armDir * HEAD_LEN / 2
			table.insert(cfs, CFrame.lookAt(c, c + armDir))
		end
		table.insert(cfs, if hitPos and hitN then CFrame.new(hitPos + hitN * 0.38) else PARK)
	else
		for _ = 1, MAX_DOTS + 3 do
			table.insert(cfs, PARK)
		end
	end
	shown = true
	workspace:BulkMoveTo(allParts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Grenade button edge -> true when the grenade should be thrown now.
function ThrowArc.grenadeEdge(down: boolean): boolean
	if not grenadeOnRelease() then
		grenadeHeld = false
		return down
	end
	if down then
		grenadeHeld = true
		return false
	end
	local was = grenadeHeld
	grenadeHeld = false
	return was
end

-- The beacon just left the hand: hide its arc until the server catches up.
function ThrowArc.thrown()
	beaconHiddenUntil = os.clock() + 0.6
end

function ThrowArc.init(aimPoint: (number, number?) -> Vector3, isHolding: () -> boolean, heldId: () -> string?)
	aimPointFn = aimPoint
	isHoldingFn = isHolding
	heldIdFn = heldId
	local warned = false
	RunService:BindToRenderStep("OrbitThrowArc", Enum.RenderPriority.Camera.Value + 2, function()
		local ok, err = pcall(step)
		if not ok then
			pcall(hide)
			if not warned then
				warned = true
				warn("[ThrowArc]", err)
			end
		end
	end)
	Store.on("me", function(m)
		if m and not m.alive then
			grenadeHeld = false
		end
	end)
end

return ThrowArc
