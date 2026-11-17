--!nonstrict
-- Weapon sway (local player). A slow two-axis drift plus a breathing bob. Bigger after sprinting and on low stamina,
-- steadied crouched / prone.
--   Sway.step(dt)            once per frame (WeaponController's RenderStepped)
--   Sway.aim() -> (p, y)     radians added to the shot / barrel-reticle direction (WeaponController.aimPoint). Only
--                            while aiming: hip fire keeps its spread cone instead. The server still traces from what
--                            the client sends, as for every shot.
--   Sway.model() -> CFrame   gun-space offset for the held gun (GunFeel.offset, applied by CombatPose on either shoulder)
-- Studio A/B "SWAY" (workspace attribute Feel_Sway): nil = light, "strong" = x2.2, "off".
local Players = game:GetService("Players")
local Store = require(script.Parent.Store)
local Input = require(script.Parent.Input)

local Sway = {}

local player = Players.LocalPlayer
local DRIFT_DEG = 0.16 -- idle drift amplitude while aiming (light preset)
local BREATH_DEG = 0.11 -- breathing bob (pitch)
local BREATH_HZ = 0.27
local SPRINT_DEG = 0.7 -- extra right after a sprint, decays over SPRINT_DECAY s
local SPRINT_DECAY = 2.4
local LOW_STAMINA_DEG = 0.55 -- extra at empty stamina (from LOW_STAMINA_AT down)
local LOW_STAMINA_AT = 0.4
local STANCE_MULT = { stand = 1, crouch = 0.6, prone = 0.35 }
local SPRINT_SPEED = 19 -- horizontal speed counted as sprinting (same as CombatPose's low-ready)
local MODEL_SHARE = 0.8 -- gun model angle per aim-point angle
local HIP_MODEL_SHARE = 0.5 -- the gun model still sways a little at the hip

local t = 0
local sprintHeat = 0 -- 1 right after sprinting, decays to 0
local aimBlend = 0
local pitch, yaw = 0, 0 -- current sway (radians), full strength

local function strength(): number
	local v = workspace:GetAttribute("Feel_Sway")
	if v == "off" then
		return 0
	elseif v == "strong" then
		return 2.2
	end
	return 1
end

function Sway.step(dt: number)
	t += dt
	local c = player.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		local v = root.AssemblyLinearVelocity
		if Vector3.new(v.X, 0, v.Z).Magnitude > SPRINT_SPEED then
			sprintHeat = 1
		else
			sprintHeat = math.max(0, sprintHeat - dt / SPRINT_DECAY)
		end
	end
	local aiming = Input.isDown("Aim")
	aimBlend += ((if aiming then 1 else 0) - aimBlend) * (1 - math.exp(-dt * 10))

	local s = strength()
	if s <= 0 then
		pitch, yaw = 0, 0
		return
	end
	local st = Store.get("stamina")
	local stam = if type(st) == "table" and type(st.v) == "number" then st.v else 1
	local low = math.clamp(1 - stam / LOW_STAMINA_AT, 0, 1)
	local stanceMult = STANCE_MULT[Store.get("stance") or "stand"] or 1
	-- sprint / stamina extras grow the drift and speed the breathing up
	local extra = SPRINT_DEG * sprintHeat * sprintHeat + LOW_STAMINA_DEG * low
	local drift = (DRIFT_DEG + extra) * stanceMult * s
	local breath = (BREATH_DEG + extra * 0.6) * stanceMult * s
	local hz = BREATH_HZ * (1 + 1.2 * math.max(sprintHeat, low))
	local nt = t * (0.35 + 0.4 * math.max(sprintHeat, low))
	local dy = math.noise(nt, 3.1, 0) * 2 * drift
	local dp = math.noise(nt, 7.7, 0) * 2 * drift * 0.7 + math.sin(t * hz * math.pi * 2) * breath
	pitch, yaw = math.rad(dp), math.rad(dy)
end

function Sway.aim(): (number, number)
	return pitch * aimBlend, yaw * aimBlend
end

function Sway.model(): CFrame
	local k = HIP_MODEL_SHARE + (MODEL_SHARE - HIP_MODEL_SHARE) * aimBlend
	if pitch == 0 and yaw == 0 then
		return CFrame.identity
	end
	return CFrame.Angles(pitch * k, yaw * k, 0)
end

return Sway
