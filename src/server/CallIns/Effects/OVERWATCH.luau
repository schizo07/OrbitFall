-- Overwatch Skiff: the extraction Skiff flies in, circles the beacon `altitude` studs up for `duration` s and shoots enemies near
-- the beacon with its door gun, then leaves. Clients draw the hull (Fx "OverwatchSkiff") along shared/OverwatchPath, the server
-- computes the same position at time t and fires from it. Same targeting rules as Extraction's door gun: nearest to the beacon
-- first, clear line from the gun, damage only through S.Enemies.damage (troopers can never be hit).
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local EnemyData = require(Shared.Data.Enemies)
local Path = require(Shared.OverwatchPath)

local GUN_RANGE = 120 -- studs from the gun
local MAX_CANDIDATES = 6
local GUN_OFFSET = Vector3.new(6.6, -2.2, -2) -- door gun on the hull; X is mirrored to the side the target is on

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local ground = ctx.groundAt(ctx.pos)
	local centre = ground + Vector3.new(0, prm.altitude, 0)
	local duration = prm.duration
	local interval = 60 / math.max(prm.rpm, 1)

	local id = ctx.nextId()
	local t0 = workspace:GetServerTimeNow()
	S.Fx.play("OverwatchSkiff", { id = id, c = centre, r = prm.radius, d = duration, t0 = t0 })
	local ended = false
	ctx.onStop(function()
		if not ended then
			S.Fx.play("OverwatchEnd", { id = id })
		end
	end)

	local function hostiles(): { any }
		local out = {}
		for _, e in S.Enemies.getInRadius(ground, prm.acquire) do
			if e.alive and e.root and e.root.Parent and not (e.def and e.def.static) then
				out[#out + 1] = e
			end
		end
		return out
	end

	-- one round; true when something was shot
	local function fire(hullCF: CFrame): boolean
		local list = hostiles()
		if #list == 0 then
			return false
		end
		local function flatDist(e: any): number
			local d = e.root.Position - ground
			return Vector3.new(d.X, 0, d.Z).Magnitude
		end
		table.sort(list, function(a, b)
			return flatDist(a) < flatDist(b)
		end)
		for i = 1, math.min(#list, MAX_CANDIDATES) do
			local e = list[i]
			local aim = e.root.Position + Vector3.new(0, (e.def.size or 2) * 0.6, 0)
			local side = if hullCF:PointToObjectSpace(aim).X < 0 then -1 else 1
			local gun = (hullCF * CFrame.new(GUN_OFFSET.X * side, GUN_OFFSET.Y, GUN_OFFSET.Z)).Position
			if (aim - gun).Magnitude <= GUN_RANGE and ctx.los(gun, aim) then
				local faction = EnemyData.Factions[e.faction]
				local mat = if faction and faction.deathStyle == "goo" then "goo" else "metal"
				S.Enemies.damage(e, prm.damage, prm.ap, ctx.source, "body")
				local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 1.2
				S.Fx.playU("SkiffGun", { a = gun, b = aim + jitter, m = mat })
				return true
			end
		end
		return false
	end

	local circleStart = Path.APPROACH_TIME
	local circleEnd = Path.APPROACH_TIME + duration
	while ctx.alive() do
		local tau = workspace:GetServerTimeNow() - t0
		if tau >= circleEnd then
			break
		end
		if tau >= circleStart then
			local hullCF = Path.cframe(centre, prm.radius, duration, tau)
			if not fire(hullCF) then
				task.wait(0.1) -- nothing to shoot: look again soon instead of waiting out a whole round
				continue
			end
		end
		task.wait(interval)
	end
	-- the Skiff leaves; the run ends once it is gone
	if ctx.alive() then
		task.wait(Path.LEAVE_TIME)
	end
	ended = true
end
