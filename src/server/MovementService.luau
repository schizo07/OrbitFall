-- Server half of tactical movement: authoritative stamina + stance (client/Movement.luau predicts both).
-- Owned by PlayerService (required + driven from there; not in the Main ORDER list).
-- Actions (C->S): move(stance: string, sprinting: boolean), dive(), aim(pitch), twist(radians; prone/dive upper-body yaw
-- against the legs, replicated as character attribute `Twist`)
-- Writes rec.stamina / rec.exhausted / rec.stance (sent in `me`) and the character attribute `Stance`
-- (replicated so every client can pose other players: stand|crouch|prone|dive|mantle|down).
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Carry = require(Shared.Carry)

local M = Config.Move
local MovementService = {}
local S
local PS -- PlayerService

local VALID = { stand = true, crouch = true, prone = true, dive = true, mantle = true, down = true }

type MoveRec = {
	stamina: number,
	exhausted: boolean,
	sprinting: boolean,
	stance: string,
	lastDrain: number,
	lastDive: number,
	sentStamina: number,
	boostEnd: number, -- stim sprint: server time until which stamina stays full (0 = none)
}
local moves: { [Player]: MoveRec } = {}

local function now()
	return workspace:GetServerTimeNow()
end

local function fresh(): MoveRec
	return { stamina = 1, exhausted = false, sprinting = false, stance = "stand", lastDrain = 0, lastDive = -99, sentStamina = 1, boostEnd = 0 }
end

local function get(p: Player): MoveRec
	local m = moves[p]
	if not m then
		m = fresh()
		moves[p] = m
	end
	return m
end

local function setAttr(p: Player, stance: string)
	local c = p.Character
	if c and c:GetAttribute("Stance") ~= stance then
		c:SetAttribute("Stance", stance)
	end
end

local function setSprintAttr(p: Player, on: boolean)
	local c = p.Character
	local v: boolean? = if on then true else nil
	if c and c:GetAttribute("Sprinting") ~= v then
		c:SetAttribute("Sprinting", v)
	end
end

-- The upper-body twist only exists while prone / diving: any other stance zeroes the replicated value.
local function clearTwist(p: Player, stance: string)
	local c = p.Character
	if c and stance ~= "prone" and stance ~= "dive" and c:GetAttribute("Twist") ~= nil and c:GetAttribute("Twist") ~= 0 then
		c:SetAttribute("Twist", 0)
	end
end

-- Merged into `me` by PlayerService.buildMe.
function MovementService.state(p: Player): (number, boolean, string)
	local m = get(p)
	local st = m.stance
	-- weapons only care about the three real stances
	if st ~= "crouch" and st ~= "prone" then
		st = if st == "dive" or st == "down" then "prone" else "stand"
	end
	return m.stamina, m.exhausted, st
end

-- Stim sprint: stamina stays full (no drain, never exhausted) for `seconds` from now. Sent in `me` as sprintBoostEnd.
function MovementService.boost(p: Player, seconds: number)
	if seconds <= 0 then
		return
	end
	local m = get(p)
	m.boostEnd = now() + seconds
	m.stamina, m.exhausted = 1, false
end

-- Server time the running stim sprint ends (0 = none); merged into `me` by PlayerService.buildMe.
function MovementService.boostEnd(p: Player): number
	return get(p).boostEnd
end

function MovementService.getStance(p: Player): string
	return get(p).stance
end

function MovementService.onCharacter(p: Player, c: Model)
	local m = get(p)
	m.stamina, m.exhausted, m.sprinting, m.stance = 1, false, false, "stand"
	m.boostEnd = 0
	c:SetAttribute("Stance", "stand")
	c:SetAttribute("Sprinting", nil)
	c:SetAttribute("Twist", 0)
	PS.publish(p)
end

function MovementService.init(s, playerService)
	S = s
	PS = playerService
	S.Actions.on("move", function(p: Player, stance: any, sprinting: any)
		if typeof(stance) ~= "string" or not VALID[stance] then
			return
		end
		local m = get(p)
		if stance == "prone" and Carry.isCarrying(p) then
			stance = if m.stance == "crouch" then "crouch" else "stand"
		end
		m.stance = stance
		-- (1 cell can sprint slower; 2 cells blocks sprint: shared/Carry.luau)
		m.sprinting = sprinting == true and stance == "stand" and not m.exhausted and Carry.canSprint(p)
		setAttr(p, stance)
		setSprintAttr(p, m.sprinting)
		clearTwist(p, stance)
		PS.publish(p)
	end)
	-- upper-body twist (radians) while prone / diving, for the other clients' pose (Movement.twistStep); ~10 Hz
	local lastTwist: { [Player]: number } = {}
	S.Actions.on("twist", function(p: Player, v: any)
		if typeof(v) ~= "number" or v ~= v then
			return
		end
		local m = get(p)
		if m.stance ~= "prone" and m.stance ~= "dive" and v ~= 0 then
			return
		end
		local t = os.clock()
		if t - (lastTwist[p] or 0) < 0.08 and v ~= 0 then
			return
		end
		lastTwist[p] = t
		local c = p.Character
		if c then
			c:SetAttribute("Twist", math.floor(math.clamp(v, -3.1, 3.1) * 100 + 0.5) / 100)
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastTwist[p] = nil
	end)
	-- aim pitch (radians) for the other clients' CombatPose; the owner sends it ~8x/s when it changes
	local lastAim: { [Player]: number } = {}
	S.Actions.on("aim", function(p: Player, pitch: any)
		if typeof(pitch) ~= "number" or pitch ~= pitch then
			return
		end
		local t = os.clock()
		if t - (lastAim[p] or 0) < 0.08 then
			return
		end
		lastAim[p] = t
		local c = p.Character
		if c then
			c:SetAttribute("AimPitch", math.floor(math.clamp(pitch, -1.4, 1.4) * 100 + 0.5) / 100)
		end
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(p)
		lastAim[p] = nil
	end)
	-- which shoulder the gun is on (+1 right, -1 left): other clients' CombatPose and the bullet / grenade origin
	-- (shared/Aim.origin) read the character attribute Hand; missing = +1
	-- rate-limited (V spam): a dropped change is re-sent by the client 0.5 s later while the attribute disagrees
	local lastHand: { [Player]: number } = {}
	game:GetService("Players").PlayerRemoving:Connect(function(p)
		lastHand[p] = nil
	end)
	S.Actions.on("hand", function(p: Player, hand: any)
		if typeof(hand) ~= "number" or hand ~= hand then
			return
		end
		local t = os.clock()
		if t - (lastHand[p] or 0) < 0.1 then
			return
		end
		lastHand[p] = t
		local c = p.Character
		if c then
			c:SetAttribute("Hand", if hand < 0 then -1 else 1)
		end
	end)
	S.Actions.on("dive", function(p: Player)
		local m = get(p)
		local t = now()
		-- lenient (latency): 85 % of the cooldown, half the cost must be there
		if t - m.lastDive < M.DiveCooldown * 0.85 or m.stamina < M.DiveCost * 0.5 or not PS.isAlive(p) or p:GetAttribute("CarryCell") == true then
			return
		end
		m.lastDive = t
		m.lastDrain = t
		m.stamina = math.max(0, m.stamina - M.DiveCost)
		m.stance = "dive"
		m.sprinting = false
		setAttr(p, "dive")
		setSprintAttr(p, false)
		PS.publish(p)
	end)
	Players.PlayerRemoving:Connect(function(p)
		moves[p] = nil
	end)
end

-- Called by PlayerService's 10 Hz tick.
function MovementService.step(p: Player, dt: number)
	local m = get(p)
	if m.stance == "prone" and Carry.isCarrying(p) and p:GetAttribute("Downed") ~= true then
		m.stance = "stand"
		setAttr(p, "stand")
		clearTwist(p, "stand")
	end
	if m.sprinting and not Carry.canSprint(p) then
		m.sprinting = false
		setSprintAttr(p, false)
	end
	local t = now()
	local before = m.exhausted
	local root = PS.getRoot(p)
	local moving = false
	if root then
		local v = root.AssemblyLinearVelocity
		moving = Vector3.new(v.X, 0, v.Z).Magnitude > 6
	end
	if t < m.boostEnd then
		-- stim sprint: pinned full
		m.stamina, m.exhausted = 1, false
		if m.sprinting and moving then
			m.lastDrain = t
		end
	elseif m.sprinting and moving and not m.exhausted then
		m.stamina = math.max(0, m.stamina - dt / M.SprintTime)
		m.lastDrain = t
		if m.stamina <= 0 then
			m.exhausted = true
			m.sprinting = false
			setSprintAttr(p, false)
		end
	elseif t - m.lastDrain >= M.RegenDelay and m.stamina < 1 then
		m.stamina = math.min(1, m.stamina + dt / M.RegenTime)
	end
	if m.exhausted and m.stamina >= M.RecoverAt then
		m.exhausted = false
	end
	if before ~= m.exhausted or math.abs(m.stamina - m.sentStamina) >= 0.08 or (m.stamina >= 1 and m.sentStamina < 1) then
		m.sentStamina = m.stamina
		PS.publish(p)
	end
end

return MovementService
