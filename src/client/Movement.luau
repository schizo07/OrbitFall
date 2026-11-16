-- Tactical movement (client, predicted; server/MovementService.luau is authoritative for stamina + stance).
--  * Stamina: sprint drains (Config.Move.SprintTime), refills after RegenDelay; at 0 you jog-limp until RecoverAt.
--    Stim sprint: after a stim the stamina stays full for Config.Stims.Sprint s (`me.sprintBoostEnd`, server time;
--    Studio A/B Feel_StimSprint, mirrored to the server). The stamina bar getter's 4th value is `boosted`.
--  * Stances: Crouch tap = crouch/stand, hold = prone; Prone key toggles prone; Jump stands you up.
--  * Dive: Crouch/Prone while sprinting -> forward dive, land prone, short recovery. Costs stamina, 1 s cooldown.
--  * Mantle: Jump into a 2.5-6 stud ledge -> smooth climb onto it.
--  * Knockdown: heavy server knocks ("Knockdown" Fx {v, t?}) tumble you on physics for t s (default KnockdownTime; explosions
--    send 0.9-1.8 s by launch strength), friction settles the body on the ground, then a short stand-up eases the root
--    upright. The camera keeps following the root, with a wider FOV while down.
--  * Poses: animation-free Motor6D C0 offsets + Humanoid.HipHeight, applied by every client to every character
--    (remote characters read the replicated `Stance` attribute the server sets).
--  * Prone / dive facing: legs (root) keep their heading, the upper body twists toward the camera (Waist joint, clamped
--    to ProneTwistLimit); beyond it the root turns; crawling turns the root toward the crawl direction.
--    Studio A/B attrs: ProneTwist=false (old: whole body follows the camera), ProneTwistLimit (deg), ProneTurnRate (1/s)
--    (client-side workspace attributes, read live).
-- Store keys written: stance ("stand"|"crouch"|"prone"), stamina ({v: number, exhausted: boolean}), moveMode.
-- Camera hooks (CameraController): Movement.cameraStep(dt, rawFocusY), Movement.allowFacing().
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Input = require(script.Parent.Input)
local Store = require(script.Parent.Store)
local BodyDebug = require(script.Parent.BodyDebug) -- Studio readout (DebugKeys N); mark() is a no-op while it is off

local M = Config.Move
local Movement = {}
local player = Players.LocalPlayer
local actionEv: RemoteEvent? = nil
local CARRY_SPEED = require(Shared.Carry).SPEED_MULT -- haul objective carrier speed factor

-- R15 joints are Motor6D on classic rigs and AnimationConstraint on the upgraded avatar joints (same C0/C1/Transform API)
local function isJoint(x: Instance?): boolean
	return x ~= nil and (x:IsA("Motor6D") or x:IsA("AnimationConstraint"))
end
-- C0 is read-only on AnimationConstraint: move its Attachment0 instead (same frame)
local function setC0(j: any, cf: CFrame)
	if j:IsA("AnimationConstraint") then
		local a = j.Attachment0
		if a then
			a.CFrame = cf
		end
	else
		j.C0 = cf
	end
end
local rad = math.rad
local UP = Vector3.new(0, 1, 0)
local IS_STUDIO = RunService:IsStudio()

-- Studio A/B (workspace attributes, read live; code defaults in release):
--   ProneTwist=false      old behaviour: the whole body turns with the camera while prone / diving
--   ProneTwistLimit (deg) how far the upper body may twist against the legs (default 75)
--   ProneTurnRate (1/s)   how fast the legs shuffle round toward the crawl direction (default 5)
--   KnockGetupTime (s)    explosion knockdown: length of the stand-up (default 0.45)
--   KnockCamFov (deg)     explosion knockdown: extra camera FOV while down (default 8)
local function proneTwistOn(): boolean
	return not (IS_STUDIO and workspace:GetAttribute("ProneTwist") == false)
end
local function tuneNum(name: string, default: number): number
	if IS_STUDIO then
		local v = workspace:GetAttribute(name)
		if typeof(v) == "number" then
			return v
		end
	end
	return default
end
local function twistLimit(): number
	return rad(math.clamp(tuneNum("ProneTwistLimit", 50), 0, 170))
end

local function wrapAngle(a: number): number
	return (a + math.pi) % (math.pi * 2) - math.pi
end
-- heading of a direction, same convention as CFrame.Angles(0, yaw, 0) looking down -Z
local function yawOf(v: Vector3): number
	return math.atan2(-v.X, -v.Z)
end

-- ── local state ────────────────────────────────────────────────────────────────────────────────────────────────
local stance = "stand" -- stand | crouch | prone
local mode = "none" -- none | dive | mantle | down | recover
local modeT = 0
local recoverFor = 0
-- knockdown (explosions): tumble on physics for downFor s, then a GETUP_TIME stand-up (root eased from where it lies to upright)
local downFor = 0.8
local getupFrom: CFrame? = nil
local getupT0 = 0
local downBlend = 0 -- camera: 0..1 while knocked down (wider FOV, lower focus)
local stamina, exhausted = 1, false
local lastDrain = -99
local lastDive = -99
local sprintApplied = false
local crouchDownAt: number? = nil
local crouchFreshCrouch = false -- this press is the one that crouched us (release must not stand back up)
local sentStance, sentSprint = "", false
local diveDir = Vector3.new(0, 0, -1)
local mantleFrom: Vector3 = Vector3.zero
local mantleTo: Vector3 = Vector3.zero
local mantleDir: Vector3 = Vector3.new(0, 0, -1)
local mantleDur = 0.35
local baseHip: number? = nil -- humanoid's own HipHeight (refreshed whenever we are not overriding it)
local hipCur: number? = nil -- what we last wrote (nil = not overriding)
local jumpEnabled = true
local jumpLock = false -- Jump was used to stand up / mantle: no real jump until it is released
local publishedStamina = -1
local publishedExhausted = false
-- stim sprint: server time until which stamina stays full (server MovementService.boost, sent in `me` as sprintBoostEnd)
local boostEnd = 0
local boosted = false

-- prone / dive body facing: the legs (root) keep their heading, the upper body twists toward the camera
local twistOn = false -- the body is currently in "legs fixed, torso follows the camera" mode (also while easing out)
local twistRaw = 0 -- radians, world yaw of the upper body relative to the root (clamped to the twist limit)
local twistGain = 0 -- 0..1 ramp so entering the mode does not pop
local sentTwist, sentTwistAt = 0, -99
local speedWanted: number? = nil -- WalkSpeed `step` computed last (re-applied after WeaponController's render-phase write)
local proneRest: number? = nil -- HipHeight at which the lying torso just rests on the floor (last settled measurement)
local poseSettled: (Model) -> boolean = function(_)
	return true
end -- replaced below, once the pose rigs exist

-- camera feel
local focusY: number? = nil
local camDrop = 0
local landDip, landVel = 0, 0
local minVy = 0
local sprintBlend = 0
local bobPhase, bobAmp, limpAmp = 0, 0, 0

-- ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────
local function chr(): (Model?, Humanoid?, BasePart?)
	local c = player.Character
	if not c then
		return nil, nil, nil
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	return c, hum, root
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshFilter()
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, n in { "Enemies", "ClientFx" } do
		local f = workspace:FindFirstChild(n)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
	overlapParams.FilterDescendantsInstances = list
end

local function cast(origin: Vector3, dir: Vector3): RaycastResult?
	return workspace:Raycast(origin, dir, rayParams)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function send(name: string, ...)
	if actionEv then
		actionEv:FireServer(name, ...)
	end
end

local function serverStance(): string
	if mode == "dive" or mode == "mantle" or mode == "down" then
		return mode
	end
	return stance
end

local function setStance(s: string)
	if stance == s then
		return
	end
	stance = s
	Store.set("stance", s)
end

local function setMode(m: string)
	mode = m
	modeT = os.clock()
	Store.set("moveMode", m)
end

local function legLengths(c: Model): (number, number)
	local thigh, shin = 1.1, 1.1
	local ul = c:FindFirstChild("LeftUpperLeg")
	local ll = c:FindFirstChild("LeftLowerLeg")
	local foot = c:FindFirstChild("LeftFoot")
	local hip = ul and ul:FindFirstChild("LeftHip") :: Motor6D?
	local knee = ll and ll:FindFirstChild("LeftKnee") :: Motor6D?
	local ankle = foot and foot:FindFirstChild("LeftAnkle") :: Motor6D?
	if hip and knee and isJoint(hip) and isJoint(knee) then
		thigh = (hip.C1.Position - knee.C0.Position).Magnitude
	end
	if knee and ankle and isJoint(knee) and isJoint(ankle) then
		shin = (knee.C1.Position - ankle.C0.Position).Magnitude
	end
	return math.clamp(thigh, 0.3, 4), math.clamp(shin, 0.3, 4)
end

-- crouch leg geometry (absolute angles from vertical; A = thigh forward, B = shin backward)
local CROUCH_A, CROUCH_B = rad(58), rad(-42)

-- Prone: the posed torso/head (CanCollide) lie on the floor, so the Humanoid's hover height must be the height at
-- which they just touch it. A fixed tiny HipHeight (0.1) made the Humanoid want the root 0.74 studs lower than the
-- torso could go: it never found the floor (Freefall), gravity pulled the character into its own torso collision
-- and the solver pushed it back up every few frames (the "negative force" while prone).
-- On a slope the torso / head reach ground that is higher (or lower) than the ground under the root, so the hover
-- height also has to follow the terrain under each colliding part's lowest corner (ray-cast), capped so crawling into
-- a wall or a crate cannot lift the body up it.
local LIE_PARTS = { "UpperTorso", "LowerTorso", "Head" }
local LIE_MAX_LIFT = 0.8 -- studs above the flat-ground rest height
local SIGNS = { -1, 1 }
local function measureRest(c: Model, root: BasePart): number?
	refreshFilter()
	local half = root.Size.Y * 0.5
	local ry = root.Position.Y
	local under = cast(root.Position, Vector3.new(0, -(half + 6), 0))
	if not under then
		return nil
	end
	local floorY = under.Position.Y
	local flatNeed, need = -math.huge, -math.huge -- root height above its ground so every part just touches (flat / real)
	for _, n in LIE_PARTS do
		local part = c:FindFirstChild(n)
		if part and part:IsA("BasePart") and part.CanCollide then
			local cf, h = part.CFrame, part.Size * 0.5
			-- every corner of the part's box: on a tilted plane the contact corner is not the lowest one
			for _, sx in SIGNS do
				for _, sy in SIGNS do
					for _, sz in SIGNS do
						local corner = cf * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)
						local drop = ry - corner.Y -- how far the corner hangs below the root centre
						flatNeed = math.max(flatNeed, drop)
						local hit = cast(corner + Vector3.new(0, 2.5, 0), Vector3.new(0, -9, 0))
						local gy = if hit then hit.Position.Y else floorY
						need = math.max(need, drop + (gy - floorY))
					end
				end
			end
		end
	end
	if flatNeed == -math.huge then
		return nil
	end
	need = math.min(need, flatNeed + LIE_MAX_LIFT)
	return need - half
end

local function hipTarget(c: Model, base: number, root: BasePart): number
	local s = serverStance()
	if s == "dive" then
		return 0.1 -- PlatformStand: the Humanoid does not hold any height
	elseif s == "prone" then
		-- measure only once the pose has finished pitching (before that the body is still upright); the Root / Waist
		-- walk-cycle lean is cancelled while lying (twistStep), so the geometry is steady while crawling too
		if poseSettled(c) then
			local m = measureRest(c, root)
			if m then
				proneRest = m
			end
		end
		-- 0.03 above contact: the Humanoid never presses the torso into the floor
		return math.clamp((proneRest or base * 0.42) + 0.03, 0.1, base)
	elseif s == "crouch" then
		local thigh, shin = legLengths(c)
		local drop = thigh * (1 - math.cos(CROUCH_A)) + shin * (1 - math.cos(CROUCH_B))
		return math.max(0.2, base - drop)
	end
	return base
end

-- Is there head room to stand up from the current stance?
local function canStand(): boolean
	local _, hum, root = chr()
	if not hum or not root then
		return true
	end
	refreshFilter()
	local need = ((baseHip or hum.HipHeight) - hum.HipHeight) + root.Size.Y * 0.5 + 2.4
	return cast(root.Position, UP * need) == nil
end

local function setJumpEnabled(hum: Humanoid, on: boolean)
	if jumpEnabled == on then
		return
	end
	jumpEnabled = on
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, on)
	if on then
		hum.Jump = false
	end
end

local function groundBelow(root: BasePart, extra: number): RaycastResult?
	return cast(root.Position, Vector3.new(0, -(root.Size.Y * 0.5 + extra), 0))
end

local function camYawCF(pos: Vector3): CFrame
	local look = flat(workspace.CurrentCamera.CFrame.LookVector)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + look.Unit)
end

-- ── actions ────────────────────────────────────────────────────────────────────────────────────────────────────
local function isSprinting(hum: Humanoid, root: BasePart): boolean
	return stance == "stand"
		and mode == "none"
		and Input.isDown("Sprint")
		and hum.FloorMaterial ~= Enum.Material.Air
		and flat(root.AssemblyLinearVelocity).Magnitude > Config.WalkSpeed + 1
end

local function tryDive(): boolean
	local _, hum, root = chr()
	if not hum or not root then
		return false
	end
	local t = os.clock()
	if not isSprinting(hum, root) or t - lastDive < M.DiveCooldown or stamina < M.DiveCost * 0.5 then
		return false
	end
	local v = flat(root.AssemblyLinearVelocity)
	diveDir = (v.Magnitude > 1 and v.Unit) or flat(root.CFrame.LookVector).Unit
	lastDive = t
	lastDrain = t
	stamina = math.max(0, stamina - M.DiveCost)
	setMode("dive")
	setJumpEnabled(hum, false)
	hum.PlatformStand = true
	root.AssemblyLinearVelocity = diveDir * M.DiveSpeed + UP * M.DiveUp
	root.AssemblyAngularVelocity = Vector3.zero
	send("dive")
	return true
end

local function tryMantle(): boolean
	local c, hum, root = chr()
	if not c or not hum or not root or mode ~= "none" or stance ~= "stand" or root.Anchored or hum.Sit then
		return false
	end
	refreshFilter()
	local half = root.Size.Y * 0.5
	local feetY = root.Position.Y - half - hum.HipHeight
	-- climb where we are heading, as long as that is roughly where we face (no backwards mantles)
	local look = flat(root.CFrame.LookVector).Unit
	local md = flat(hum.MoveDirection)
	local fwd = if md.Magnitude > 0.1 and md.Unit:Dot(look) > 0.2 then md.Unit else look
	local base = Vector3.new(root.Position.X, 0, root.Position.Z)
	-- 1. chest ray must hit a wall-ish surface close in front
	local chest = base + Vector3.new(0, feetY + 1.6, 0)
	local wall = cast(chest, fwd * 3.2)
	if not wall or math.abs(wall.Normal.Y) > 0.55 then
		return false
	end
	-- 2. above-head ray must be clear (ledge no taller than MantleMax)
	local headY = feetY + M.MantleMax + 0.6
	if cast(base + Vector3.new(0, headY, 0), fwd * (wall.Distance + 1.4)) then
		return false
	end
	-- 3. find the top surface just past the wall (thick ledge first, then thin wall top)
	local top: RaycastResult? = nil
	local probe = Vector3.zero
	for _, inset in { 1.1, 0.4 } do
		probe = flat(wall.Position) + fwd * inset
		local hit = cast(probe + Vector3.new(0, headY, 0), Vector3.new(0, -(headY - feetY - 0.4), 0))
		if hit and hit.Normal.Y > 0.7 then
			local h = hit.Position.Y - feetY
			if h >= M.MantleMin and h <= M.MantleMax then
				top = hit
				break
			end
		end
	end
	if not top then
		return false
	end
	local standHip = baseHip or hum.HipHeight
	local targetY = top.Position.Y + standHip + half + 0.05
	-- 4. room on top for a standing body, and nothing over our head on the way up
	local bodyH = standHip + root.Size.Y + 1.2
	local boxCf = CFrame.new(probe.X, top.Position.Y + 0.2 + bodyH * 0.5, probe.Z)
	for _, part in workspace:GetPartBoundsInBox(boxCf, Vector3.new(1.6, bodyH - 0.1, 1.2), overlapParams) do
		if part.CanCollide then
			return false
		end
	end
	if cast(root.Position, UP * (targetY - root.Position.Y + 2.2)) then
		return false
	end
	mantleFrom = root.Position
	mantleTo = Vector3.new(probe.X, targetY, probe.Z)
	mantleDir = fwd
	local h = top.Position.Y - feetY
	mantleDur = M.MantleTime * (0.8 + 0.2 * h / 4)
	setMode("mantle")
	setJumpEnabled(hum, false)
	hum.Jump = false
	hum.PlatformStand = true
	return true
end

local function standUp()
	if stance == "stand" then
		return
	end
	if canStand() then
		setStance("stand")
	elseif stance == "prone" then
		setStance("crouch")
	end
end

-- t = seconds on the ground before the stand-up (server/Explosions.luau scales it with the launch; default KnockdownTime)
function Movement.knockdown(v: Vector3, t: number?)
	local _, hum, root = chr()
	if not hum or not root or hum.Health <= 0 or root.Anchored then
		return
	end
	local dur = math.clamp(t or M.KnockdownTime, 0.4, 2.5)
	if mode == "down" and getupFrom == nil then
		-- already tumbling (cluster bomblets, two blasts at once): extra push, a little longer on the ground, capped
		root.AssemblyLinearVelocity += v * 0.5
		local e = os.clock() - modeT
		downFor = math.min(math.max(downFor, e + dur * 0.6), 3)
		return
	end
	setMode("down")
	downFor = dur
	getupFrom = nil
	setStance("stand")
	setJumpEnabled(hum, false)
	hum.PlatformStand = true
	root.AssemblyLinearVelocity = flat(root.AssemblyLinearVelocity) * 0.3 + v
	local f = flat(v)
	local axis = if f.Magnitude > 0.1 then f.Unit:Cross(UP) else Vector3.new(1, 0, 0)
	-- tumble away from the blast, cartoony spin (harder launches spin a little faster)
	local spin = 6 + math.min(v.Magnitude, 140) * 0.04 + math.random() * 3
	root.AssemblyAngularVelocity = -axis * spin + UP * (math.random() * 6 - 3)
end

-- ── input ──────────────────────────────────────────────────────────────────────────────────────────────────────
local function blockedInput(): boolean
	local _, hum = chr()
	return Store.get("menuOpen") == true or not hum or hum.Health <= 0
end

local function onCrouch(down: boolean)
	if not down then
		if crouchDownAt and stance == "crouch" and os.clock() - crouchDownAt < M.ProneHoldTime and not crouchFreshCrouch then
			standUp()
		end
		crouchDownAt = nil
		return
	end
	if blockedInput() or (mode ~= "none" and mode ~= "recover") then
		return
	end
	if mode == "none" and tryDive() then
		return
	end
	crouchDownAt = os.clock()
	crouchFreshCrouch = false
	if stance == "stand" then
		setStance("crouch")
		crouchFreshCrouch = true
	elseif stance == "prone" then
		setStance("crouch")
		crouchDownAt = nil
	end
end

local function onProne(down: boolean)
	if not down or blockedInput() or (mode ~= "none" and mode ~= "recover") then
		return
	end
	if mode == "none" and tryDive() then
		return
	end
	if stance == "prone" then
		standUp()
	else
		setStance("prone")
	end
end

local function onJump(down: boolean)
	if not down or blockedInput() or mode ~= "none" then
		return
	end
	if stance ~= "stand" then
		jumpLock = true
		standUp()
		return
	end
	if tryMantle() then
		jumpLock = true
	end
end

-- ── prone / dive body facing ────────────────────────────────────────────────────────────────────────────────────
-- While prone (and during the dive) the root (= legs, lower body) keeps its heading and the upper body yaws toward the
-- camera through the Waist joint (see twistStep), clamped to the twist limit. Beyond the limit the root turns, just
-- enough to keep the twist at the limit. While crawling the root turns toward the crawl direction instead (the camera
-- may be up to the limit off it; crawling backwards keeps the body facing the camera). CameraController stops rotating
-- the root meanwhile (Movement.allowFacing). Standing up eases the root round to the camera first, so the legs do not pop.
local CRAWL_BACK = rad(140) -- crawl directions further than this from the camera heading do not turn the body
local EASE_OUT_RATE = 14

local function setRootYaw(root: BasePart, yaw: number)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
end

local function bodyFacing(dt: number, hum: Humanoid, root: BasePart)
	local camLook = flat(workspace.CurrentCamera.CFrame.LookVector)
	if camLook.Magnitude < 0.05 then
		twistRaw = 0
		return
	end
	local camYaw = yawOf(camLook)
	local rootYaw = yawOf(flat(root.CFrame.LookVector))
	local lim = twistLimit()
	local free = not root.Anchored and (mode == "none" or mode == "recover")
	local wantOn = proneTwistOn() and ((stance == "prone" and free) or mode == "dive")
	if wantOn then
		twistOn = true
		if mode ~= "dive" then -- (the dive branch of step owns the root heading during a dive)
			local wantTwist = math.clamp(wrapAngle(camYaw - rootYaw), -lim, lim)
			local rate = 10 -- catching up when the camera went past the limit
			local md = flat(hum.MoveDirection)
			if mode == "none" and md.Magnitude > 0.1 then
				local dev = wrapAngle(camYaw - yawOf(md)) -- twist needed if the body faces the crawl direction
				wantTwist = if math.abs(dev) < CRAWL_BACK then math.clamp(dev, -lim, lim) else 0
				rate = tuneNum("ProneTurnRate", 5)
			end
			rootYaw += wrapAngle(camYaw - wantTwist - rootYaw) * (1 - math.exp(-dt * rate))
			setRootYaw(root, rootYaw)
		end
		twistRaw = math.clamp(wrapAngle(camYaw - rootYaw), -lim, lim)
	elseif twistOn and free then
		-- got up / left prone: swing the legs round to the camera heading, then hand the root back to CameraController
		local diff = wrapAngle(camYaw - rootYaw)
		if math.abs(diff) < 0.04 or not proneTwistOn() then
			twistOn = false
			twistRaw = 0
		else
			rootYaw += diff * (1 - math.exp(-dt * EASE_OUT_RATE))
			setRootYaw(root, rootYaw)
			twistRaw = math.clamp(wrapAngle(camYaw - rootYaw), -lim, lim)
		end
	else
		twistOn = false
		twistRaw = 0
	end
	if twistOn then
		twistGain += (1 - twistGain) * (1 - math.exp(-dt * 14))
	else
		twistGain = 0
	end
end

-- ── walk / run animation speed ─────────────────────────────────────────────────────────────────────────────────
-- Roblox's Animate script scales the walk / run track speed by HipHeight / starting HipHeight, but only re-evaluates
-- when the Humanoid's Running speed changes. Lying prone (HipHeight ~0.2 of 2) set the run track to ~10x; standing up
-- while still moving at the same speed never re-fired Running, so the legs kept cycling at 10x ("flicker after the
-- crawl until you stop and walk again", 2026-11-16). Re-apply Animate's own formula every frame with the current
-- HipHeight (same numbers it would pick, just not stale).
local animDamp: NumberValue? = nil
local function syncRunAnim(hum: Humanoid, root: BasePart, base: number)
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator or base <= 0 then
		return
	end
	local scale = hum.HipHeight / base
	local animate = hum.Parent and hum.Parent:FindFirstChild("Animate")
	if animate then
		animDamp = animDamp or animate:FindFirstChild("ScaleDampeningPercent") :: NumberValue?
		if animDamp then
			scale = 1 + (hum.HipHeight - base) * animDamp.Value / base
		end
	end
	if scale <= 0.01 then
		return
	end
	local speed = flat(root.AssemblyLinearVelocity).Magnitude
	if speed <= 0.75 * scale then
		return -- Animate plays idle here
	end
	local runSpeed = speed / 16 * 1.25 / scale -- onRunning: setAnimationSpeed(speed / 16) -> setRunSpeed -> x1.25 / scale
	local timeWarp = if runSpeed <= 0.5 then runSpeed / 0.5 elseif runSpeed < 1 then 1 else runSpeed
	for _, tr in animator:GetPlayingAnimationTracks() do
		local n = tr.Name
		if (n == "WalkAnim" or n == "RunAnim") and math.abs(tr.Speed - timeWarp) > 0.05 * timeWarp then
			tr:AdjustSpeed(timeWarp)
		end
	end
end

-- ── per-frame simulation ───────────────────────────────────────────────────────────────────────────────────────
-- Runs on PreSimulation: after WeaponController's RenderStepped WalkSpeed write, right before physics, so ours wins.
local function step(dt: number)
	local c, hum, root = chr()
	if not c or not hum or not root or hum.Health <= 0 then
		return
	end
	local t = os.clock()
	if root.Anchored or hum.Sit then
		-- drop capsule / seats / cutscenes: drop everything and stand
		if mode ~= "none" then
			hum.PlatformStand = false
			setMode("none")
		end
		crouchDownAt = nil
		setStance("stand")
	end
	if hipCur == nil then
		baseHip = hum.HipHeight
	end
	local base = baseHip or hum.HipHeight

	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local moving = hum.MoveDirection.Magnitude > 0.1
	local aiming = Input.isDown("Aim")
	local firing = Input.isDown("Fire")

	-- crouch held long enough -> prone
	if crouchDownAt and mode == "none" and t - crouchDownAt >= M.ProneHoldTime then
		crouchDownAt = nil
		setStance("prone")
	end

	-- special modes ------------------------------------------------------------------------------------------
	if mode == "dive" then
		refreshFilter()
		local e = t - modeT
		hum.PlatformStand = true
		-- 35 % of gravity cancelled for a floatier, readable arc
		local vy = root.AssemblyLinearVelocity.Y + workspace.Gravity * 0.35 * dt
		local horiz = diveDir * M.DiveSpeed * math.max(0.5, 1 - e * 0.7)
		root.AssemblyLinearVelocity = horiz + UP * vy
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = CFrame.lookAt(root.Position, root.Position + diveDir)
		if (e > 0.2 and vy <= 2 and groundBelow(root, 0.7) ~= nil) or e > 1.5 then
			hum.PlatformStand = false
			root.AssemblyLinearVelocity = horiz * 0.35 + UP * math.min(vy, 0)
			setStance("prone")
			setMode("recover")
			recoverFor = M.DiveRecover
			landVel -= 4
		end
	elseif mode == "mantle" then
		local e = math.clamp((t - modeT) / mantleDur, 0, 1)
		hum.PlatformStand = true
		local up = math.clamp(e / 0.6, 0, 1)
		up = 1 - (1 - up) * (1 - up) -- ease out
		local f = if e < 0.6 then 0.15 * (e / 0.6) else 0.15 + 0.85 * ((e - 0.6) / 0.4)
		f = f * f * (3 - 2 * f)
		local h = flat(mantleFrom):Lerp(flat(mantleTo), f)
		local pos = Vector3.new(h.X, mantleFrom.Y + (mantleTo.Y - mantleFrom.Y) * up, h.Z)
		root.CFrame = CFrame.lookAt(pos, pos + mantleDir)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		if e >= 1 then
			hum.PlatformStand = false
			root.AssemblyLinearVelocity = mantleDir * 8
			setMode("none")
			landVel -= 1.5
		end
	elseif mode == "down" then
		hum.PlatformStand = true
		local e = t - modeT
		if getupFrom then
			-- stand-up: ease the root from where the body lies to upright, facing the camera heading
			local u = math.clamp((t - getupT0) / tuneNum("KnockGetupTime", 0.45), 0, 1)
			u = u * u * (3 - 2 * u)
			refreshFilter()
			local g = groundBelow(root, 3)
			local gy = if g then g.Position.Y else root.Position.Y - root.Size.Y * 0.5
			local from = getupFrom :: CFrame
			local target = camYawCF(Vector3.new(from.Position.X, gy + base + root.Size.Y * 0.5, from.Position.Z))
			root.CFrame = from:Lerp(target, u)
			root.AssemblyAngularVelocity = Vector3.zero
			root.AssemblyLinearVelocity = Vector3.zero
			if u >= 1 then
				getupFrom = nil
				hum.PlatformStand = false
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
				setMode("recover")
				recoverFor = 0.15
				landVel -= 2
			end
		else
			refreshFilter()
			local g = groundBelow(root, 1.6)
			if g and e > 0.3 then
				-- on the ground: friction so the body slides to a stop and lies there instead of spinning on
				local k = math.exp(-dt * 4)
				local lv = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(lv.X * k, lv.Y, lv.Z * k)
				root.AssemblyAngularVelocity *= math.exp(-dt * 6)
			end
			if e >= downFor and (groundBelow(root, 3) or e > downFor + 2.2) then
				getupFrom = root.CFrame
				getupT0 = t
			end
		end
	elseif mode == "recover" then
		if t - modeT >= recoverFor then
			setMode("none")
		end
	end

	-- Studio test hook: workspace attribute DebugCamYawRate (rad/s, + = turn left) turns the camera through the normal
	-- look path (simulated mouse movement does not reach the locked mouse). Not read in live games.
	if IS_STUDIO then
		local rate = workspace:GetAttribute("DebugCamYawRate")
		if typeof(rate) == "number" and rate ~= 0 then
			Input.addLook(-rate * dt / 0.0065, 0) -- CameraController: yaw -= lookX * touchSens (0.0065)
		end
	end

	-- (body facing / twist: twistStep, which runs earlier in the frame than this handler)

	-- haul objective: a core-cell carrier walks at x0.8 and can't sprint (shared/Carry.luau; server mirrors the sprint)
	local carrying = player:GetAttribute("CarryCell") == true

	-- stamina (prediction; server reconciles through `me`) ---------------------------------------------------
	sprintApplied = mode == "none"
		and stance == "stand"
		and Input.isDown("Sprint")
		and moving
		and not aiming
		and not firing
		and not exhausted
		and not carrying
	boosted = boostEnd > 0 and workspace:GetServerTimeNow() < boostEnd
	if boosted then
		-- stim sprint: stamina pinned full, sprint never runs out (the server does the same)
		stamina, exhausted = 1, false
		if sprintApplied then
			lastDrain = t
		end
	elseif sprintApplied then
		stamina = math.max(0, stamina - dt / M.SprintTime)
		lastDrain = t
		if stamina <= 0 then
			exhausted = true
			sprintApplied = false
		end
	elseif t - lastDrain >= M.RegenDelay then
		stamina = math.min(1, stamina + dt / M.RegenTime)
	end
	if exhausted and stamina >= M.RecoverAt then
		exhausted = false
	end

	-- speed ----------------------------------------------------------------------------------------------------
	local speed
	if mode ~= "none" then
		speed = 0
	elseif stance == "prone" then
		speed = M.ProneSpeed
	elseif stance == "crouch" then
		speed = if aiming then M.CrouchAimSpeed else M.CrouchSpeed
	elseif aiming then
		speed = Config.AimSpeed
	elseif sprintApplied then
		speed = Config.SprintSpeed
	else
		speed = Config.WalkSpeed
	end
	if exhausted and stance == "stand" then
		speed = math.min(speed, M.LimpSpeed)
	end
	if carrying then
		speed *= CARRY_SPEED
	end
	hum.WalkSpeed = speed
	speedWanted = speed

	-- hip height (smoothed; only overridden while not standing) ----------------------------------------------
	local target = if root.Anchored then base else hipTarget(c, base, root)
	if hipCur ~= nil or math.abs(target - base) > 1e-3 then
		local cur = hipCur or hum.HipHeight
		cur += (target - cur) * (1 - math.exp(-dt * 14))
		if math.abs(target - base) <= 1e-3 and math.abs(cur - base) < 0.02 then
			hum.HipHeight = base
			hipCur = nil
		else
			hum.HipHeight = cur
			hipCur = cur
		end
	end
	syncRunAnim(hum, root, base)
	if jumpLock and not Input.isDown("Jump") then
		jumpLock = false
	end
	setJumpEnabled(hum, mode == "none" and stance == "stand" and not jumpLock)

	-- landing dip ----------------------------------------------------------------------------------------------
	local vy = root.AssemblyLinearVelocity.Y
	if mode == "down" or mode == "mantle" or root.Anchored then
		minVy = 0
	elseif not grounded then
		minVy = math.min(minVy, vy)
	else
		if minVy < -28 then
			landVel -= math.clamp((-minVy - 22) / 45, 0.15, 1) * 9
		end
		minVy = 0
	end

	-- replicate ------------------------------------------------------------------------------------------------
	local ss = serverStance()
	if ss ~= sentStance or sprintApplied ~= sentSprint then
		sentStance, sentSprint = ss, sprintApplied
		send("move", ss, sprintApplied)
	end
	-- upper-body twist for the other clients (~10 Hz while it changes, 0 when it ends)
	local tw = if twistOn then twistRaw * twistGain else 0
	if t - sentTwistAt > 0.1 and (math.abs(tw - sentTwist) > 0.03 or (tw == 0 and sentTwist ~= 0)) then
		sentTwist, sentTwistAt = tw, t
		send("twist", tw)
	end
	if math.abs(stamina - publishedStamina) > 0.01 or exhausted ~= publishedExhausted then
		publishedStamina, publishedExhausted = stamina, exhausted
		Store.set("stamina", { v = stamina, exhausted = exhausted })
	end
end

-- ── procedural poses (every character) ──────────────────────────────────────────────────────────────────────────
type Joint = { m: Motor6D, base: CFrame }
type Rig = { root: Joint, joints: { [string]: Joint }, p: number, d: number, b: number, active: boolean }
local rigs: { [Model]: Rig } = {}

-- Motor6D name -> part that holds it (R15). R6 gets the root tilt only.
local JOINTS = {
	LeftHip = "LeftUpperLeg",
	RightHip = "RightUpperLeg",
	LeftKnee = "LeftLowerLeg",
	RightKnee = "RightLowerLeg",
	LeftAnkle = "LeftFoot",
	RightAnkle = "RightFoot",
	LeftShoulder = "LeftUpperArm",
	RightShoulder = "RightUpperArm",
	Neck = "Head",
}
-- p = body pitch forward (rad), d = extra drop of the body (studs), b = knee bend 0..1
local POSES = {
	stand = { p = 0, d = 0, b = 0 },
	down = { p = 0, d = 0, b = 0.45 }, -- physics tumble does the work; knees half tucked while it flies
	crouch = { p = rad(16), d = 0, b = 1 },
	prone = { p = rad(84), d = -0.3, b = 0 },
	dive = { p = rad(70), d = 0, b = 0 },
	mantle = { p = rad(30), d = 0, b = 0.55 },
}

local function findMotor(c: Model, partName: string, name: string): Motor6D?
	local part = c:FindFirstChild(partName)
	local m = part and part:FindFirstChild(name)
	if m and isJoint(m) then
		return m
	end
	return nil
end

local function buildRig(c: Model): Rig?
	local rootM = findMotor(c, "LowerTorso", "Root") or findMotor(c, "HumanoidRootPart", "RootJoint")
	if not rootM then
		return nil
	end
	local rig: Rig = { root = { m = rootM, base = rootM.C0 }, joints = {}, p = 0, d = 0, b = 0, active = false }
	for name, part in JOINTS do
		local m = findMotor(c, part, name)
		if m then
			rig.joints[name] = { m = m, base = m.C0 }
		end
	end
	return rig
end

local function capture(rig: Rig)
	rig.root.base = rig.root.m.C0
	for _, j in rig.joints do
		j.base = j.m.C0
	end
end

local function restore(rig: Rig)
	setC0(rig.root.m, rig.root.base)
	for _, j in rig.joints do
		setC0(j.m, j.base)
	end
end

local function poseFor(c: Model): string
	if c == player.Character then
		if mode == "dive" or mode == "mantle" or mode == "down" then
			return mode
		end
		return stance
	end
	local s = c:GetAttribute("Stance")
	return if typeof(s) == "string" and POSES[s] then s else "stand"
end

local function setJ(rig: Rig, name: string, angle: number)
	local j = rig.joints[name]
	if j then
		setC0(j.m, j.base * CFrame.Angles(angle, 0, 0))
		if BodyDebug.on then
			BodyDebug.mark(j.m, "C0", "Pose")
		end
	end
end

local function poseStep(dt: number)
	for _, p in Players:GetPlayers() do
		local c = p.Character
		if not c then
			continue
		end
		local name = poseFor(c)
		local hum = c:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health <= 0 then
			name = "stand"
		end
		local rig = rigs[c]
		if rig and not rig.root.m.Parent then
			rigs[c] = nil
			rig = nil
		end
		if not rig then
			if name == "stand" then
				continue
			end
			rig = buildRig(c)
			if not rig then
				continue
			end
			rigs[c] = rig
		end
		local r = rig :: Rig
		local target = POSES[name]
		local k = 1 - math.exp(-dt * (if name == "dive" then 16 else 11))
		r.p += (target.p - r.p) * k
		r.d += (target.d - r.d) * k
		r.b += (target.b - r.b) * k
		if target.p == 0 and math.abs(r.p) < 0.003 and math.abs(r.d) < 0.003 and math.abs(r.b) < 0.003 then
			if r.active then
				restore(r)
				r.active = false
			end
			r.p, r.d, r.b = 0, 0, 0
			continue
		end
		if not r.active then
			capture(r)
			r.active = true
		end
		setC0(r.root.m, CFrame.new(0, r.d, 0) * CFrame.Angles(-r.p, 0, 0) * r.root.base)
		if BodyDebug.on then
			BodyDebug.mark(r.root.m, "C0", "Pose")
		end
		-- legs: thigh forward / shin back relative to the tilted pelvis, feet flat
		local hip = (CROUCH_A + r.p) * r.b
		local knee = (CROUCH_B - CROUCH_A) * r.b
		local ankle = -CROUCH_B * r.b
		setJ(r, "LeftHip", hip)
		setJ(r, "RightHip", hip)
		setJ(r, "LeftKnee", knee)
		setJ(r, "RightKnee", knee)
		setJ(r, "LeftAnkle", ankle)
		setJ(r, "RightAnkle", ankle)
		-- keep the gun and the face pointing forward while the body pitches
		setJ(r, "LeftShoulder", r.p * 0.9)
		setJ(r, "RightShoulder", r.p * 0.9)
		setJ(r, "Neck", r.p * 0.7)
	end
	for c, _ in rigs do
		if not c.Parent then
			rigs[c] = nil
		end
	end
end

poseSettled = function(c: Model): boolean
	local r = rigs[c]
	return r ~= nil and r.active and math.abs(r.p - POSES.prone.p) < 0.03
end

-- ── upper-body twist (every character) ──────────────────────────────────────────────────────────────────────────
-- Yaws the UpperTorso about the world vertical, at the Waist joint, relative to the (fixed-heading) lower body. Written
-- as Waist.Transform on PreSimulation, after the Animator and BEFORE CombatPose, so the arm / gun solver sees the
-- twisted chest. NOTE: Roblox runs the handlers of one signal in REVERSE connection order (last connected runs first;
-- measured in Studio), so this handler is connected late (Movement.init, delayed) to run ahead of CombatPose and
-- FootPlant, while `step` (connected first) runs last, right before physics.
-- Local character: bodyFacing (called from here, same frame) computes the value. Others: the replicated `Twist`
-- attribute (server, from the owner's "twist" action), smoothed.
-- While lying prone the walk animation's torso lean / bob on Root and Waist is cancelled (those joints' Transform is
-- replaced): the Animator leans the chest ~12 degrees into the floor while crawling, the collision then lifted the
-- root ~0.6 studs on every stride.
-- Lying pose = ONE owner for Root, Waist and all six leg joints: this handler. Before, nothing replaced the leg
-- Transforms while prone, so the legs showed whatever the Animate script was playing on a lying body: walk / idle
-- swapping at the walk-speed threshold, and the fall pose blending in and out whenever the Humanoid flipped between
-- Running and Freefall at the low prone hover height (each swap is a 0.1-0.2 s cross-fade of the whole leg pose), while
-- the Root lean was zeroed instantly. Now every joint is blended by one weight `lie` (0..1, eased) from the Animator's
-- value to the lying pose, so entering / leaving prone is smooth and, once down, no Animator track reaches the legs.
-- Studio A/B: Feel_ProneLegs = "kick" (default: small crawl flutter from the crawl speed) | "still" | "anim" (old:
-- the Animator keeps the legs).
type Own = { j: any, mine: CFrame?, raw: CFrame? }
type Twist = { waist: any, root: any, shown: number, lie: number, ph: number, kick: number, legs: { [string]: Own }?, ownW: Own, ownR: Own }
local twists: { [Model]: Twist } = {}
local LIE_RATE = 12 -- 1/s: lying-pose blend in / out
local LEG_JOINTS = {
	LeftHip = "LeftUpperLeg",
	RightHip = "RightUpperLeg",
	LeftKnee = "LeftLowerLeg",
	RightKnee = "RightLowerLeg",
	LeftAnkle = "LeftFoot",
	RightAnkle = "RightFoot",
	-- 2026-11-15: the head shook ~20 degrees frame to frame while crawling (walk / fall tracks cross-fading on the Neck);
	-- its Transform is owned too and held still (identity), the aim pitch stays on Neck.C0 (CombatPose / poseStep)
	Neck = "Head",
}

-- this frame's Animator value of a joint (our own write from last frame, if still there, does not count as theirs)
local function ownRead(o: Own): CFrame
	local cur = o.j.Transform
	if o.mine ~= nil and cur == o.mine then
		return o.raw :: CFrame
	end
	return cur
end
local function ownWrite(o: Own, raw: CFrame, v: CFrame, who: string)
	o.j.Transform = v
	o.mine, o.raw = o.j.Transform, raw
	if BodyDebug.on then
		BodyDebug.mark(o.j, "T", who)
	end
end
-- stop owning: hand the Animator's value back if nobody else wrote the joint since
local function ownDrop(o: Own)
	if o.mine ~= nil and o.j.Transform == o.mine then
		o.j.Transform = o.raw :: CFrame
	end
	o.mine, o.raw = nil, nil
end

local function proneLegsMode(): string
	local v = workspace:GetAttribute("Feel_ProneLegs")
	return if v == "still" or v == "anim" then v else "kick"
end

-- lying leg pose (Transform, joint space; X = bend forward / back, Z = sideways) at crawl phase `ph`, strength `k` 0..1
local function lyingLeg(name: string, ph: number, k: number): CFrame
	if k <= 0 or name == "Neck" then
		return CFrame.identity
	end
	local left = string.sub(name, 1, 4) == "Left"
	local s = math.sin(ph + (if left then 0 else math.pi))
	if string.find(name, "Hip", 1, true) then
		-- thigh swings out sideways and back (frog crawl); the pulling leg is the one swung out
		local out = math.max(0, s) * 0.2 * k -- 2026-11-15: was 0.32, "legs move a bit too much"
		return CFrame.Angles(-0.06 * k, 0, if left then -out else out)
	elseif string.find(name, "Knee", 1, true) then
		return CFrame.Angles(-(0.15 + 0.35 * math.max(0, s)) * k, 0, 0) -- shin lifts off the floor behind (was 0.55)
	end
	return CFrame.Angles(-0.25 * k, 0, 0) -- toes pointed back
end

local function c0Of(j: any): CFrame
	if j:IsA("AnimationConstraint") then
		return if j.Attachment0 then j.Attachment0.CFrame else CFrame.identity
	end
	return j.C0
end

local function twistStep(dt: number)
	local mine = player.Character
	do -- local body facing first (same frame as the arms below), see bodyFacing
		local _, lh, lr = chr()
		if lh and lr and lh.Health > 0 then
			bodyFacing(dt, lh, lr)
		end
	end
	for _, p in Players:GetPlayers() do
		local c = p.Character
		if not c then
			continue
		end
		local isLocal = c == mine
		local hum = c:FindFirstChildOfClass("Humanoid")
		local target = 0
		local lying = false
		if hum and hum.Health > 0 then
			if isLocal then
				target = if twistOn then twistRaw * twistGain else 0
				lying = stance == "prone" and (mode == "none" or mode == "recover")
			else
				local st = c:GetAttribute("Stance")
				local a = c:GetAttribute("Twist")
				if (st == "prone" or st == "dive") and typeof(a) == "number" then
					target = a
				end
				lying = st == "prone"
			end
			if not proneTwistOn() then
				target = 0
			end
		end
		local tw = twists[c]
		if tw and not tw.waist.Parent then
			twists[c] = nil
			tw = nil
		end
		if not tw then
			if math.abs(target) < 0.002 and not lying then
				continue
			end
			local waist = findMotor(c, "UpperTorso", "Waist")
			local rootJ = findMotor(c, "LowerTorso", "Root")
			if not waist or not rootJ then
				continue
			end
			tw = { waist = waist, root = rootJ, shown = 0, lie = 0, ph = 0, kick = 0, ownW = { j = waist }, ownR = { j = rootJ } }
			twists[c] = tw
		end
		local t = tw :: Twist
		t.shown = if isLocal then target else t.shown + (target - t.shown) * (1 - math.exp(-dt * 12))
		-- lying-pose weight: eased, snapped at the ends so a settled body is exactly the lying pose / exactly the Animator's
		t.lie += ((if lying then 1 else 0) - t.lie) * (1 - math.exp(-dt * LIE_RATE))
		if t.lie > 0.995 then
			t.lie = 1
		elseif t.lie < 0.005 then
			t.lie = 0
		end
		local lie = t.lie
		local hrp = c:FindFirstChild("HumanoidRootPart") :: BasePart?

		-- pelvis: no walk-cycle lean while lying
		if lie > 0 then
			local rawR = ownRead(t.ownR)
			ownWrite(t.ownR, rawR, if lie >= 1 then CFrame.identity else rawR:Lerp(CFrame.identity, lie), "Lie")
		else
			ownDrop(t.ownR)
		end

		-- legs: lying pose (optional crawl flutter), blended by `lie`
		local legMode = proneLegsMode()
		if lie > 0 and legMode ~= "anim" then
			if not t.legs then
				local legs = {}
				for name, part in LEG_JOINTS do
					local m = findMotor(c, part, name)
					if m then
						legs[name] = { j = m }
					end
				end
				t.legs = legs
			end
			local spd = 0
			if hrp and legMode == "kick" then
				local v = hrp.AssemblyLinearVelocity
				spd = Vector3.new(v.X, 0, v.Z).Magnitude
			end
			local kickT = if lying then math.clamp(spd / math.max(M.ProneSpeed, 0.1), 0, 1) else 0
			t.kick += (kickT - t.kick) * (1 - math.exp(-dt * 6))
			t.ph = (t.ph + dt * spd * 1.6) % (math.pi * 2)
			for name, o in t.legs :: { [string]: Own } do
				if not o.j.Parent then
					continue
				end
				local rawL = ownRead(o)
				local want = lyingLeg(name, t.ph, t.kick)
				ownWrite(o, rawL, if lie >= 1 then want else rawL:Lerp(want, lie), "Lie")
			end
		elseif t.legs then
			for _, o in t.legs :: { [string]: Own } do
				ownDrop(o)
			end
			t.legs = nil
		end

		-- waist: the Animator's value (identity while lying), twisted toward the camera
		local raw = ownRead(t.ownW)
		local base = if lie <= 0 then raw elseif lie >= 1 then CFrame.identity else raw:Lerp(CFrame.identity, lie)
		if math.abs(t.shown) < 0.002 then
			if lie > 0 then
				ownWrite(t.ownW, raw, base, "Lie")
			else
				ownDrop(t.ownW)
			end
			if math.abs(target) < 0.002 and not lying and lie <= 0 then
				twists[c] = nil
			end
			continue
		end
		if not hrp then
			continue
		end
		local rj = t.root
		local lower = hrp.CFrame * c0Of(rj) * rj.Transform * rj.C1:Inverse()
		local jr = (lower * c0Of(t.waist)).Rotation
		ownWrite(t.ownW, raw, (jr:Inverse() * CFrame.Angles(0, t.shown, 0) * jr) * base, "Twist")
	end
	for c, _ in twists do
		if not c.Parent then
			twists[c] = nil
		end
	end
end

-- ── camera hooks (CameraController, normal over-shoulder path only) ─────────────────────────────────────────────
-- Returns (focusYOffset, bobCFrame (camera-local), fovAdd).
function Movement.cameraStep(dt: number, rawFocusY: number): (number, CFrame, number)
	local _, hum, root = chr()
	-- smooth only small discontinuities (get-up pop, step-ups); follow exactly while falling / anchored
	local follow = not root
		or root.Anchored
		or (hum ~= nil and hum.FloorMaterial == Enum.Material.Air and mode == "none")
	if follow or not focusY then
		focusY = rawFocusY
	end
	local fy = focusY :: number
	fy += (rawFocusY - fy) * (1 - math.exp(-dt * 20))
	fy = math.clamp(fy, rawFocusY - 2.5, rawFocusY + 2.5)
	focusY = fy
	local s = serverStance()
	local dropT = if s == "prone" or s == "dive" then -0.9 elseif s == "crouch" then -0.35 else 0
	camDrop += (dropT - camDrop) * (1 - math.exp(-dt * 8))
	-- landing spring
	landVel += (-landDip * 150 - landVel * 17) * dt
	landDip = math.clamp(landDip + landVel * dt, -2, 1)
	-- sprint feel
	local speed = if root then flat(root.AssemblyLinearVelocity).Magnitude else 0
	local grounded = hum ~= nil and hum.FloorMaterial ~= Enum.Material.Air and mode == "none"
	local sT = if sprintApplied and grounded and speed > Config.WalkSpeed + 2 then 1 else 0
	sprintBlend += (sT - sprintBlend) * (1 - math.exp(-dt * 5))
	local lT = if exhausted and grounded and speed > 3 and stance == "stand" then 1 else 0
	limpAmp += (lT - limpAmp) * (1 - math.exp(-dt * 5))
	local mT = if grounded then math.clamp(speed / Config.SprintSpeed, 0, 1) else 0
	bobAmp += (mT - bobAmp) * (1 - math.exp(-dt * 6))
	bobPhase = (bobPhase + dt * speed * 0.75) % (math.pi * 2)
	local a = 0.11 * sprintBlend * bobAmp + 0.06 * limpAmp
	local bx = math.sin(bobPhase) * a * 0.8
	local by = -math.abs(math.sin(bobPhase)) * a * 1.1 - limpAmp * 0.06 * math.max(0, math.sin(bobPhase))
	local roll = math.sin(bobPhase) * 0.01 * (sprintBlend + limpAmp * 0.6)
	-- knocked down: the focus keeps following the tumbling root (above); widen the view and sit a little lower so the
	-- body stays in frame while it flies and lies there, then ease back during the stand-up
	local dT = if mode == "down" and getupFrom == nil then 1 else 0
	downBlend += (dT - downBlend) * (1 - math.exp(-dt * (if dT > downBlend then 9 else 4)))
	return fy - rawFocusY + camDrop + landDip - 0.5 * downBlend,
		CFrame.new(bx, by, 0) * CFrame.Angles(0, 0, roll),
		M.SprintFov * sprintBlend + tuneNum("KnockCamFov", 8) * downBlend
end

-- false while the body is driven by a dive / mantle / tumble, or while prone (legs keep their heading, the upper body
-- twists to the camera: Movement.bodyFacing owns the root yaw) -- the camera must not snap the root to the aim yaw
function Movement.allowFacing(): boolean
	if mode == "dive" or mode == "mantle" or mode == "down" then
		return false
	end
	return not twistOn
end

-- Upper-body twist (radians) currently shown on character `c`: world yaw of the chest relative to the root heading,
-- positive = counter-clockwise seen from above (same sense as CFrame.Angles(0, a, 0)); 0 when not prone / diving.
-- Aim direction of a twisted body = root yaw + this (CombatPose should use it instead of the plain root heading).
function Movement.getTwist(c: Model): number
	local t = twists[c]
	return if t then t.shown else 0
end

function Movement.getStance(): string
	return stance
end

function Movement.getStamina(): (number, boolean)
	return stamina, exhausted
end

function Movement.isBusy(): boolean
	return mode ~= "none"
end

function Movement.getMode(): (string, number)
	return mode, os.clock() - modeT
end

local function resetLocal()
	if mode ~= "none" then
		setMode("none")
	end
	setStance("stand")
	crouchDownAt = nil
	hipCur, baseHip = nil, nil
	jumpEnabled = true
	jumpLock = false
	sprintApplied = false
	stamina, exhausted = 1, false
	boostEnd, boosted = 0, false
	minVy, landDip, landVel = 0, 0, 0
	focusY = nil
	sentStance = ""
	twistOn, twistRaw, twistGain, sentTwist = false, 0, 0, 0
	getupFrom, downBlend, downFor = nil, 0, M.KnockdownTime
	proneRest = nil
	speedWanted = nil
end

function Movement.init()
	actionEv = Net.event("Action")
	Store.set("stance", stance)
	Store.set("moveMode", mode)
	Store.set("stamina", { v = stamina, exhausted = exhausted })
	Input.on("Crouch", onCrouch)
	Input.on("Prone", onProne)
	Input.on("Jump", onJump)
	Input.on("Sprint", function(d)
		-- sprint gets you up (edge-triggered so a toggled touch sprint doesn't fight crouch)
		if d and mode == "none" and stance ~= "stand" and not blockedInput() then
			standUp()
		end
	end)
	-- server reconcile
	Store.on("me", function(me)
		if type(me) ~= "table" or type(me.stamina) ~= "number" then
			return
		end
		if type(me.sprintBoostEnd) == "number" then
			boostEnd = me.sprintBoostEnd
		end
		if math.abs(me.stamina - stamina) > 0.2 then
			stamina = me.stamina
		end
		if me.exhausted == true and not exhausted and stamina < M.RecoverAt then
			exhausted = true
		end
	end)
	local okFx, Fx = pcall(require, script.Parent:FindFirstChild("Fx"))
	if okFx and type(Fx) == "table" and Fx.register then
		Fx.register("Knockdown", function(d)
			if type(d) == "table" and typeof(d.v) == "Vector3" then
				Movement.knockdown(d.v, if type(d.t) == "number" then d.t else nil)
			end
		end)
	else
		warn("[Movement] Fx unavailable; knockdowns disabled")
	end
	-- Studio: the server reads Feel_StimSprint (Variants group STIM SPRINT); mirror it like VitalsFx mirrors Feel_Regen
	if IS_STUDIO then
		local function mirror()
			send("studioFeel", "Feel_StimSprint", workspace:GetAttribute("Feel_StimSprint"))
		end
		workspace:GetAttributeChangedSignal("Feel_StimSprint"):Connect(mirror)
		if workspace:GetAttribute("Feel_StimSprint") ~= nil then
			mirror()
		end
	end
	player.CharacterAdded:Connect(resetLocal)
	RunService.PreSimulation:Connect(step)
	-- PreSimulation handlers run last-connected-first: connect this one after every module has finished init
	-- (CombatPose, FootPlant, ...) so it runs ahead of CombatPose and the arm solver sees this frame's twisted chest
	task.delay(1, function()
		RunService.PreSimulation:Connect(function(dt)
			local ok, err = pcall(twistStep, dt)
			if not ok then
				warn("[Movement] twist: " .. tostring(err))
			end
		end)
	end)
	RunService.RenderStepped:Connect(poseStep)
	-- WeaponController writes WalkSpeed = walk / aim / sprint speed in RenderStepped. The Humanoid applies its move
	-- speed before PreSimulation, so on many frames our stance speed (crawl 4.5, crouch 9, limp) was too late and the
	-- character moved at 16 (measured: prone crawl alternated 4.5 / 15.7). Re-assert ours last in the render phase.
	RunService:BindToRenderStep("MovementSpeed", Enum.RenderPriority.Last.Value, function()
		local _, hum = chr()
		if hum and speedWanted and hum.Health > 0 then
			hum.WalkSpeed = speedWanted
		end
	end)
	local ui = script.Parent:FindFirstChild("UI")
	local barMod = ui and ui:FindFirstChild("StaminaBar")
	if barMod then
		local okBar, Bar = pcall(require, barMod)
		if okBar and type(Bar) == "table" and Bar.init then
			Bar.init(function()
				return stamina, exhausted, sprintApplied, boosted
			end)
		end
	end
end

return Movement
