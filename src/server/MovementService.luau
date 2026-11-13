-- Server half of tactical movement: authoritative stamina + stance (client/Movement.luau predicts both).
-- Owned by PlayerService (required + driven from there; not in the Main ORDER list).
-- Actions (C->S): move(stance: string, sprinting: boolean), dive()
-- Writes rec.stamina / rec.exhausted / rec.stance (sent in `me`) and the character attribute `Stance`
-- (replicated so every client can pose other players: stand|crouch|prone|dive|mantle|down).
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

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
}
local moves: { [Player]: MoveRec } = {}

local function now()
	return workspace:GetServerTimeNow()
end

local function fresh(): MoveRec
	return { stamina = 1, exhausted = false, sprinting = false, stance = "stand", lastDrain = 0, lastDive = -99, sentStamina = 1 }
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

function MovementService.getStance(p: Player): string
	return get(p).stance
end

function MovementService.onCharacter(p: Player, c: Model)
	local m = get(p)
	m.stamina, m.exhausted, m.sprinting, m.stance = 1, false, false, "stand"
	c:SetAttribute("Stance", "stand")
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
		m.stance = stance
		m.sprinting = sprinting == true and stance == "stand" and not m.exhausted
		setAttr(p, stance)
		PS.publish(p)
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
	S.Actions.on("dive", function(p: Player)
		local m = get(p)
		local t = now()
		-- lenient (latency): 85 % of the cooldown, half the cost must be there
		if t - m.lastDive < M.DiveCooldown * 0.85 or m.stamina < M.DiveCost * 0.5 or not PS.isAlive(p) then
			return
		end
		m.lastDive = t
		m.lastDrain = t
		m.stamina = math.max(0, m.stamina - M.DiveCost)
		m.stance = "dive"
		m.sprinting = false
		setAttr(p, "dive")
		PS.publish(p)
	end)
	Players.PlayerRemoving:Connect(function(p)
		moves[p] = nil
	end)
end

-- Called by PlayerService's 10 Hz tick.
function MovementService.step(p: Player, dt: number)
	local m = get(p)
	local t = now()
	local before = m.exhausted
	local root = PS.getRoot(p)
	local moving = false
	if root then
		local v = root.AssemblyLinearVelocity
		moving = Vector3.new(v.X, 0, v.Z).Magnitude > 6
	end
	if m.sprinting and moving and not m.exhausted then
		m.stamina = math.max(0, m.stamina - dt / M.SprintTime)
		m.lastDrain = t
		if m.stamina <= 0 then
			m.exhausted = true
			m.sprinting = false
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
