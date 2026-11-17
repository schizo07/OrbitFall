-- Per-player numbers for one mission, sent to every client as the after-action report (client/UI/AfterAction.luau)
-- when the mission ends in Results (extracted) or Failed.
--
-- Everything is read from things that already happen, so no other service has to call in:
--   * mission lifecycle, objectives, and each player's "me" snapshot (stims, mags, grenades, call-in charges) come
--     through StateService.listen;
--   * kills: S.Mission.onKill is wrapped once at init (EnemyService calls it on every enemy death);
--   * deaths / damage taken: the Humanoid of each character; times downed: Player attribute `Downed`;
--   * revives given: Player attribute `ReviveBy` (the squadmate holding the revive prompt) right as `Downed` clears;
--   * extracted: Extraction calls MissionStats.setBoarded just before onDone.
-- Optional direct hooks (used instead of the guesses above once they are called):
--   MissionStats.revived(by, downedPlayer)  -- a squadmate revive
--   MissionStats.shot(player) / .hit(player) -- one round fired / one enemy hit (gives accuracy)
--
-- Remote: AfterAction (S->C), payload documented at buildReport().
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local MissionStats = {}
local S: any = nil
local ev: RemoteEvent

local BIG_CLASS = { heavy = true, behemoth = true }
local IN_MISSION = { Drop = true, Active = true, Extract = true }
local REVIVE_LINK = 0.25 -- s: ReviveBy cleared this close to Downed clearing = that squadmate got them up

type Rec = {
	u: number,
	n: string,
	kills: number,
	byFaction: { [string]: number },
	big: number,
	elites: number,
	deaths: number,
	downed: number,
	revives: number,
	stims: number,
	callins: number,
	grenades: number,
	shots: number,
	hits: number,
	dmg: number,
	left: boolean,
}

local recs: { [number]: Rec } = {}
local order: { number } = {} -- userIds in join order (card order)
local lastMe: { [Player]: any } = {}
local reviveClear: { [Player]: { by: number, t: number } } = {}
local conns: { [Player]: { RBXScriptConnection } } = {}

local missionState = "Ship"
local lastMission: any = nil -- the snapshot before the current one (Failed reason)
local curMission: any = nil
local lastObjectives: any = nil
local activeAt: number? = nil -- server time the mission went Active
local boarded: { [number]: boolean } = {}
local reviveHooked = false
local shotHooked = false

local function now(): number
	return workspace:GetServerTimeNow()
end

local function counting(): boolean
	return IN_MISSION[missionState] == true
end

local function rec(p: Player): Rec
	local r = recs[p.UserId]
	if not r then
		r = {
			u = p.UserId,
			n = p.DisplayName,
			kills = 0,
			byFaction = {},
			big = 0,
			elites = 0,
			deaths = 0,
			downed = 0,
			revives = 0,
			stims = 0,
			callins = 0,
			grenades = 0,
			shots = 0,
			hits = 0,
			dmg = 0,
			left = false,
		}
		recs[p.UserId] = r
		table.insert(order, p.UserId)
	end
	r.left = false
	return r
end

local function reset()
	table.clear(recs)
	table.clear(order)
	table.clear(lastMe)
	table.clear(reviveClear)
	table.clear(boarded)
	lastObjectives = nil
	activeAt = nil
	for _, p in Players:GetPlayers() do
		rec(p)
	end
end

-- ------------------------------------------------------------------ kills
local function onKill(e: any, source: any)
	if not counting() then
		return
	end
	local p = source and source.player
	if not (p and typeof(p) == "Instance" and p:IsA("Player")) then
		return
	end
	local r = rec(p)
	r.kills += 1
	local f = e and e.faction
	if type(f) == "string" then
		r.byFaction[f] = (r.byFaction[f] or 0) + 1
	end
	if e and (BIG_CLASS[e.class] or e.elite) then
		r.big += 1
	end
	if e and e.elite then
		r.elites += 1
	end
end

-- ------------------------------------------------------------------ "me" snapshot diffs
local function onMe(p: Player, me: any)
	if type(me) ~= "table" then
		return
	end
	local old = lastMe[p]
	lastMe[p] = me
	if not old or not counting() then
		return
	end
	local r = rec(p)
	if type(me.stims) == "number" and type(old.stims) == "number" and me.stims < old.stims then
		r.stims += old.stims - me.stims
	end
	if type(me.grenades) == "number" and type(old.grenades) == "number" and me.grenades < old.grenades then
		r.grenades += old.grenades - me.grenades
	end
	if not shotHooked and type(me.weapons) == "table" and type(old.weapons) == "table" then
		for i = 1, 3 do
			local a, b = old.weapons[i], me.weapons[i]
			if type(a) == "table" and type(b) == "table" and a.id == b.id and type(a.mag) == "number" and type(b.mag) == "number" and b.mag < a.mag then
				r.shots += a.mag - b.mag
			end
		end
	end
	local oc, nc = old.callins, me.callins
	if type(oc) == "table" and type(nc) == "table" and type(oc.slots) == "table" and type(nc.slots) == "table" then
		local before: { [string]: number } = {}
		for _, s in oc.slots do
			if type(s) == "table" and s.id then
				before[s.id] = s.charges or 0
			end
		end
		for _, s in nc.slots do
			if type(s) == "table" and s.id and before[s.id] and (s.charges or 0) < before[s.id] then
				r.callins += before[s.id] - (s.charges or 0)
			end
		end
	end
end

-- ------------------------------------------------------------------ per player: deaths, damage, downed, revives
local function watchCharacter(p: Player, c: Model)
	local h = c:WaitForChild("Humanoid", 10) :: Humanoid?
	if not h or c.Parent == nil then
		return
	end
	local hp = h.Health
	local list = conns[p]
	if not list then
		return
	end
	table.insert(list, h.HealthChanged:Connect(function(v)
		-- skip god mode (DevTools: huge MaxHealth) and the downed bleed-out
		if v < hp and counting() and h.MaxHealth < 1e5 and p:GetAttribute("Downed") ~= true then
			rec(p).dmg += hp - v
		end
		hp = v
	end))
	table.insert(list, h.Died:Connect(function()
		if counting() then
			rec(p).deaths += 1
		end
	end))
end

local function watchPlayer(p: Player)
	if conns[p] then
		return
	end
	conns[p] = {}
	if counting() then
		rec(p)
	end
	local list = conns[p]
	table.insert(list, p.CharacterAdded:Connect(function(c)
		watchCharacter(p, c)
	end))
	if p.Character then
		task.spawn(watchCharacter, p, p.Character)
	end
	local lastBy: number? = nil
	table.insert(list, p:GetAttributeChangedSignal("ReviveBy"):Connect(function()
		local v = p:GetAttribute("ReviveBy")
		if type(v) == "number" then
			lastBy = v
		elseif lastBy then
			reviveClear[p] = { by = lastBy, t = os.clock() }
			lastBy = nil
		end
	end))
	table.insert(list, p:GetAttributeChangedSignal("Downed"):Connect(function()
		if not counting() then
			return
		end
		if p:GetAttribute("Downed") == true then
			rec(p).downed += 1
			return
		end
		local rc = reviveClear[p]
		reviveClear[p] = nil
		if reviveHooked or not rc or os.clock() - rc.t > REVIVE_LINK then
			return
		end
		local h = S and S.Players and S.Players.getHumanoid(p)
		if not h or h.Health <= 0 then
			return
		end
		local by = Players:GetPlayerByUserId(rc.by)
		if by and by ~= p then
			rec(by).revives += 1
		end
	end))
end

local function unwatchPlayer(p: Player)
	local list = conns[p]
	conns[p] = nil
	if list then
		for _, c in list do
			c:Disconnect()
		end
	end
	lastMe[p] = nil
	reviveClear[p] = nil
	local r = recs[p.UserId]
	if r then
		r.left = true
	end
end

-- ------------------------------------------------------------------ report
-- payload = {
--   success: boolean, reason: string ("extracted" | "squad" | "time" | "failed"), time: seconds since Active,
--   objectiveName, planetName, factionName, difficulty,
--   mainSteps, sides, samples,
--   objectives = { {title, main, done, steps, stepsDone} },
--   players = { {u, n, kills, byFaction = {COG = n, ...}, big, elites, deaths, downed, revives, stims, callins, grenades,
--                shots, hits (nil = no accuracy data), dmg, extracted, left} },
-- }
local function buildReport(success: boolean): any
	local m = curMission or {}
	local prev = lastMission or {}
	local reason = "extracted"
	if not success then
		if type(prev.endsAt) == "number" and prev.endsAt > 0 and now() >= prev.endsAt - 1 then
			reason = "time"
		elseif type(prev.lives) == "number" and prev.lives <= 0 then
			reason = "squad"
		else
			reason = "failed"
		end
	end
	local objs = {}
	if type(lastObjectives) == "table" then
		for _, o in lastObjectives do
			if type(o) == "table" then
				local steps, done = 0, 0
				if type(o.steps) == "table" then
					for _, st in o.steps do
						steps += 1
						if type(st) == "table" and st.done then
							done += 1
						end
					end
				end
				table.insert(objs, { title = o.title, main = o.main == true, done = o.done == true, steps = steps, stepsDone = done })
			end
		end
	end
	local Obj = S and S.Objectives
	local function q(fn: string): number
		local f = Obj and Obj[fn]
		if type(f) ~= "function" then
			return 0
		end
		local ok, v = pcall(f)
		return if ok and type(v) == "number" then v else 0
	end
	local players = {}
	for _, u in order do
		local r = recs[u]
		if r then
			local p = Players:GetPlayerByUserId(u)
			table.insert(players, {
				u = r.u,
				n = if p then p.DisplayName else r.n,
				kills = r.kills,
				byFaction = table.clone(r.byFaction),
				big = r.big,
				elites = r.elites,
				deaths = r.deaths,
				downed = r.downed,
				revives = r.revives,
				stims = r.stims,
				callins = r.callins,
				grenades = r.grenades,
				shots = r.shots,
				hits = if shotHooked then r.hits else nil,
				dmg = math.floor(r.dmg + 0.5),
				extracted = boarded[u] == true,
				left = r.left or p == nil,
			})
		end
	end
	return {
		success = success,
		reason = reason,
		time = if activeAt then math.max(0, now() - activeAt) else 0,
		objectiveName = m.objectiveName,
		planetName = m.planetName,
		factionName = m.factionName,
		difficulty = m.difficulty,
		mainSteps = q("getMainSteps"),
		sides = q("getSidesDone"),
		samples = q("getSamples"),
		objectives = objs,
		players = players,
	}
end

local function onMission(m: any)
	local st = if type(m) == "table" and type(m.state) == "string" then m.state else "Ship"
	local prevState = missionState
	if st == prevState then
		lastMission, curMission = curMission, m
		return
	end
	lastMission, curMission = curMission, m
	missionState = st
	if prevState == "Ship" and st ~= "Ship" then
		reset()
	end
	if st == "Active" and not activeAt then
		activeAt = now()
	end
	if (st == "Results" or st == "Failed") and IN_MISSION[prevState] then
		local ok, report = pcall(buildReport, st == "Results")
		if ok then
			ev:FireAllClients(report)
		else
			warn("[MissionStats] report failed:", report)
		end
	end
end

-- ------------------------------------------------------------------ public
function MissionStats.setBoarded(list: { Player })
	for _, p in list do
		boarded[p.UserId] = true
	end
end

function MissionStats.revived(by: Player, _downed: Player)
	reviveHooked = true
	if counting() and by then
		rec(by).revives += 1
	end
end

-- WeaponService: shot() once per round fired (where the mag goes down), hit() once per reported enemy hit (HitConfirm)
function MissionStats.shot(p: Player)
	if not shotHooked then
		shotHooked = true
		for _, r in recs do -- drop the mag-diff guesses so shots and hits come from the same source
			r.shots = 0
		end
	end
	if counting() then
		rec(p).shots += 1
	end
end

function MissionStats.hit(p: Player)
	if counting() then
		rec(p).hits += 1
	end
end

function MissionStats.get(p: Player): Rec?
	return recs[p.UserId]
end

function MissionStats.init(registry: any)
	S = registry
	ev = Net.event("AfterAction")
	if S.State and S.State.listen then
		S.State.listen(function(player: Player?, key: string, value: any)
			if key == "mission" and player == nil then
				onMission(value)
			elseif key == "objectives" and player == nil then
				if type(value) == "table" and #value > 0 and counting() then
					lastObjectives = value
				end
			elseif key == "me" and player then
				onMe(player, value)
			end
		end)
	end
	-- kills: EnemyService calls S.Mission.onKill(enemy, source) on every death; count it here too
	local M = S.Mission
	if M and type(M.onKill) == "function" then
		local orig = M.onKill
		M.onKill = function(e, source)
			local ok, err = pcall(onKill, e, source)
			if not ok then
				warn("[MissionStats] onKill:", err)
			end
			return orig(e, source)
		end
	end
	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(unwatchPlayer)
end

return MissionStats
