-- Squad ping relay. A client looks at something and asks for a ping (Net "Ping": pos, enemyId?); the server checks it and
-- sends it to every player, who draw the marker (client/UI/Pings).
--   * 1 ping per MIN_GAP seconds per player (extra requests are dropped silently)
--   * the point (or the enemy) must be within MAX_DIST studs of the pinger
--   * an enemy id that no longer exists just becomes a ground ping at the sent point
-- Out to clients: { u = userId, p = Vector3, e = enemyId?, n = "BULWARK"? }   (n only with e)
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local PingService = {}

local MAX_DIST = 400
local MIN_GAP = 1.2

local S: { [string]: any } = {}
local remote: RemoteEvent
local lastPing: { [Player]: number } = {}

local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end

local function onPing(player: Player, pos: any, enemyId: any)
	if typeof(pos) ~= "Vector3" or not finite(pos) then
		return
	end
	local now = os.clock()
	if now - (lastPing[player] or -100) < MIN_GAP then
		return
	end
	local root = S.Players and S.Players.getRoot(player)
	if not root then
		return
	end
	local out: { [string]: any } = { u = player.UserId }
	if type(enemyId) == "number" and S.Enemies then
		local e = S.Enemies.getById(enemyId)
		if e and e.root and e.root.Parent then
			pos = e.root.Position
			out.e = enemyId
			out.n = string.upper(e.def and e.def.name or tostring(e.kind))
		end
	end
	if (pos - root.Position).Magnitude > MAX_DIST then
		return
	end
	lastPing[player] = now
	out.p = pos
	remote:FireAllClients(out)
end

function PingService.init(s: { [string]: any })
	S = s
	remote = Net.event("Ping")
	remote.OnServerEvent:Connect(onPing)
	Players.PlayerRemoving:Connect(function(p)
		lastPing[p] = nil
	end)
end

return PingService
