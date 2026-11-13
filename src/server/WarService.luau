-- Cross-server galactic war (docs/spec.md §14).
--  * contributions (% per planet / defend op) live in a MemoryStore sorted map, batched per server
--  * permanent outcomes (op success/fail, free-play liberations) live in a DataStore key
--  * every server recomputes the war with Shared/War.luau and pushes state to clients:
--      "war"     {t, planets, ops, c = raw contributions, o = outcomes}  (clients recompute live decay from c/o)
--      "warLive" {d = {[planet] = divers in missions now}, n = total divers, m = missions won, k = enemies killed}
--      "warFeed" { {id, t, k, text, p, c} }  rolling activity feed (newest last)
--      "warHist" {step, t, v = {[planet] = {samples}}}  value history for the briefing sparkline
--  * outcomes are written once (UpdateAsync keeps the first writer); story text is broadcast in-game
-- Studio without API access falls back to in-memory state (single server).
--
-- SYNC + QUOTA MATHS (MemoryStore budget = 1000 + 100 x concurrent players request units / minute,
-- experience-wide; every call costs 1 unit except GetRangeAsync = 1 unit per returned item):
--   war map  OrbitfallWar_v1   keys P_<planet>, O_<op> (~13), G_stats (missions/kills), V (version stamp)
--     flush    every 10 s: UpdateAsync per changed key + G_stats + SetAsync V  (0 when idle, ~4 per flush busy)
--     version  every 10 s: GetAsync V = 6 units/min; a full GetRangeAsync (~15 items) only when V changed,
--              plus a safety full read every 60 s  -> 15..90 units/min
--   live map OrbitfallWarLive_v1  key H_<JobId> {t, d = divers per planet, e = recent squad events}, TTL 60 s
--     heartbeat every 15 s only while this server is in a mission / has fresh events  -> <= 4 units/min
--     read      every 20 s only while someone on this server has the war map open, max 50 items -> <= 150/min
--   Worst case ~270 units/min per server (busy war + map open), quiet ~25; that fits a server with 3+ players.
--   Any throttle/limit error doubles every interval (up to x4) for 2 minutes.
--   Cross-server latency: flush 10 s + version poll 10 s => ~10 s average, 20 s worst (was 15 + 20 s).
local MemoryStoreService = game:GetService("MemoryStoreService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local War = require(Shared.War)
local Campaign = require(Shared.Data.Campaign)
local Planets = require(Shared.Data.Planets)
local Enemies = require(Shared.Data.Enemies)

local WarService = {}
local S

local MAP_NAME = "OrbitfallWar_v1"
local LIVE_NAME = "OrbitfallWarLive_v1"
local OUTCOME_STORE = "OrbitfallWarOutcomes_v1"
local OUTCOME_KEY = "outcomes"
local STATS_KEY = "G_stats"
local VERSION_KEY = "V"
local MS_TTL = 60 * 60 * 24 * 30 -- 30 days (max 45)

local IS_STUDIO = RunService:IsStudio()
local FLUSH_EVERY = 10
local VERSION_EVERY = 10
local FULL_EVERY = 60
local OUTCOME_EVERY = 30
local HEART_EVERY = 15
local HEART_TTL = 60
local LIVE_EVERY = 20
local LIVE_STALE = 45
local LIVE_LIMIT = 50
local HIST_N = 30
local HIST_STEP = if IS_STUDIO then 20 else 120 -- Studio: 10-minute sparkline so testing shows movement quickly
local OPPOST_EVERY = if IS_STUDIO then 90 else 600
local FEED_MAX = 30

local JOB = if game.JobId ~= "" then game.JobId else "studio"
local JOB_SHORT = JOB:gsub("-", ""):sub(1, 8)

local map: MemoryStoreSortedMap? = nil
local liveMap: MemoryStoreSortedMap? = nil
local outcomeStore: DataStore? = nil
local contrib: { [string]: any } = {} -- last fetched entries {v, t} (see Shared/War.luau)
local pending: { [string]: number } = {} -- local, not yet flushed
local outcomes: { [string]: string } = {}
local stats = { m = 0, k = 0 } -- last fetched global totals
local pendStats = { m = 0, k = 0 } -- local, not yet flushed
local lastVersion: any = nil
local flushSeq = 0
local lastBroadcast = ""
local lastLiveSig = ""
local offline = false
local backoff = 1
local lastThrottle = 0
local watchUntil = 0
local remoteDivers: { [string]: number } = {}
local debugDivers: { [string]: number } = {}
local feed: { any } = {}
local feedDirty = false
local seen: { [string]: boolean } = {}
local seenCount = 0
local myRecent: { any } = {}
local evSeq = 0
local hist: { [string]: { number } } = {}
local prevPlanets: { [string]: any }? = nil
local prevOps: { [string]: string } = {}
local lastMissionState = "Ship"
local nextAt: { [string]: number } = {}

local function now(): number
	return os.time()
end

local function pname(id: string?): string
	local p = id and Planets.get(id)
	return p and p.name or tostring(id)
end

local function factionName(f: string): string
	local fac = Enemies.Factions[f]
	local n = fac and fac.name or f
	return (n:gsub("^The ", "the "))
end

local function squadText(n: number): string
	return if n <= 1 then "A lone diver" else string.format("Squad of %d", n)
end

local function fmtLeft(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d, h, m = sec // 86400, (sec % 86400) // 3600, (sec % 3600) // 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", m)
end

-- MemoryStore call with throttle detection (backs every interval off on quota errors)
local function msCall(fn: () -> any): (boolean, any)
	local ok, res = pcall(fn)
	if not ok then
		local s = tostring(res):lower()
		if s:find("throttl") or s:find("limit") or s:find("quota") or s:find("budget") then
			backoff = math.min(backoff * 2, 4)
			lastThrottle = os.clock()
		end
	end
	return ok, res
end

-- totals including what this server hasn't flushed yet
local function liveContrib(): { [string]: any }
	local c = table.clone(contrib)
	local t = now()
	for k, v in pending do
		c[k] = War.applyGain(k, c[k], v, t)
	end
	return c
end

function WarService.state()
	return War.compute(liveContrib(), outcomes, now())
end

-- FEED --------------------------------------------------------------------------------------------
local function pushEvent(ev: any, share: boolean)
	if seen[ev.id] then
		return
	end
	seen[ev.id] = true
	seenCount += 1
	table.insert(feed, ev)
	table.sort(feed, function(a, b)
		return a.t < b.t
	end)
	while #feed > FEED_MAX do
		table.remove(feed, 1)
	end
	if seenCount > 600 then -- keep the dedupe set bounded
		seen = {}
		seenCount = 0
		for _, e in feed do
			seen[e.id] = true
			seenCount += 1
		end
		for _, e in myRecent do
			seen[e.id] = true
		end
	end
	if share then
		table.insert(myRecent, ev)
		while #myRecent > 8 do
			table.remove(myRecent, 1)
		end
	end
	feedDirty = true
end

-- kind: "lib" | "drop" | "flip" | "op" | "status";  col: "friendly" | "accent" | "danger" | "gold" | "muted"
local function event(kind: string, text: string, planet: string?, col: string, share: boolean?)
	evSeq += 1
	pushEvent({ id = JOB_SHORT .. "_" .. evSeq, t = now(), k = kind, text = text, p = planet, c = col }, share == true)
end

local function broadcastFeed(force: boolean?)
	if feedDirty or force then
		feedDirty = false
		S.State.broadcast("warFeed", table.clone(feed))
	end
end

-- LIVE (divers per planet, global stats) -----------------------------------------------------------
local function localDivers(): { [string]: number }
	local d = {}
	local M = S.Mission
	if M and M.planet and M.state and M.state ~= "Ship" and M.state ~= "Results" and M.state ~= "Failed" then
		d[M.planet] = #Players:GetPlayers()
	end
	return d
end

local function liveSnapshot()
	local d: { [string]: number } = {}
	for _, src in { localDivers(), remoteDivers, debugDivers } do
		for pid, n in src do
			d[pid] = (d[pid] or 0) + n
		end
	end
	local total = 0
	for _, n in d do
		total += n
	end
	return { d = d, n = total, m = stats.m + pendStats.m, k = stats.k + pendStats.k }
end

local function broadcastLive(force: boolean?)
	local snap = liveSnapshot()
	local parts = { tostring(snap.m), tostring(snap.k) }
	for pid, n in snap.d do
		table.insert(parts, pid .. n)
	end
	table.sort(parts)
	local sig = table.concat(parts, ",")
	if force or sig ~= lastLiveSig then
		lastLiveSig = sig
		S.State.broadcast("warLive", snap)
	end
end

-- Returns (ok, faction | reason)
function WarService.canPlay(planetId: any): (boolean, string)
	if type(planetId) ~= "string" or not Planets.get(planetId) then
		return false, "Pick a planet on the war map"
	end
	local st = WarService.state()[planetId]
	if not st then
		return false, "Unknown planet"
	end
	if st.destroyed then
		return false, "That planet was destroyed"
	end
	if not st.playable or not st.faction then
		return false, "Nothing to fight there right now"
	end
	return true, st.faction
end

local function snapshot()
	local t = now()
	local c = liveContrib()
	local planets = War.compute(c, outcomes, t)
	local ops = {}
	for _, op in Campaign.Operations do
		ops[op.id] = { status = War.opStatus(op, outcomes, t), progress = War.opProgress(op, c, t) }
	end
	-- raw entries let clients tick the enemy decay down locally between pushes
	local raw = {}
	for k, v in c do
		local pre = k:sub(1, 2)
		if pre == "P_" or pre == "O_" then
			raw[k] = v
		end
	end
	return { t = t, planets = planets, ops = ops, c = raw, o = table.clone(outcomes) }
end

-- planet flips / operation status changes -> feed events (every server derives these itself)
local function diffEvents(snap)
	if prevPlanets then
		for id, st in snap.planets do
			local old = (prevPlanets :: any)[id]
			if old then
				if st.destroyed and not old.destroyed then
					event("flip", pname(id) .. " has been DESTROYED", id, "danger")
				elseif st.owner ~= old.owner then
					if st.owner == "FREE" then
						event("flip", pname(id) .. " has been LIBERATED", id, "gold")
					else
						event("flip", pname(id) .. " has fallen to " .. factionName(st.owner), id, "danger")
					end
				end
			end
		end
		for opId, info in snap.ops do
			local old = prevOps[opId]
			local op = Campaign.get(opId)
			if op and old and old ~= info.status then
				if info.status == "active" then
					event("op", "NEW OPERATION: " .. op.title .. " on " .. pname(op.planet), op.planet, "accent")
				elseif info.status == "success" then
					event("op", op.successText, op.planet, "gold")
				elseif info.status == "fail" then
					event("op", op.failText, op.planet, "danger")
				end
			end
		end
	end
	prevPlanets = snap.planets
	for opId, info in snap.ops do
		prevOps[opId] = info.status
	end
end

function WarService.broadcast(force: boolean?)
	local snap = snapshot()
	diffEvents(snap)
	-- only resend when something visible changed (rounded), or forced
	local sig = {}
	for id, st in snap.planets do
		table.insert(sig, string.format("%s%s%d%d%.2f%.2f%s", id, st.owner, st.destroyed and 1 or 0, st.playable and 1 or 0, st.lib, st.defense or -1, st.op or ""))
	end
	table.sort(sig)
	local s = table.concat(sig)
	if force or s ~= lastBroadcast then
		lastBroadcast = s
		S.State.broadcast("war", snap)
	end
	broadcastFeed()
end

-- Called by Mission on a successful mission.
function WarService.contribute(planetId: string, difficulty: number, participants: { Player })
	local st = WarService.state()[planetId]
	if not st or st.destroyed then
		return
	end
	local gain = War.missionGain(planetId, difficulty)
	local key
	if st.op and Campaign.get(st.op) and (Campaign.get(st.op) :: any).kind == "defend" then
		key = "O_" .. st.op
	elseif st.owner ~= "FREE" then
		key = "P_" .. planetId
	else
		return
	end
	pending[key] = (pending[key] or 0) + gain
	-- global stats (kills come from Mission's per-player kill counts, still set when contribute runs)
	local kills = 0
	local M = S.Mission
	if M and type(M.kills) == "table" then
		for _, k in M.kills do
			kills += tonumber(k) or 0
		end
	end
	pendStats.m += 1
	pendStats.k += kills
	-- remember participation for operation bonuses
	if st.op and S.Save then
		for _, p in participants do
			local d = S.Save.get(p)
			if d then
				d.war = d.war or { ops = {}, claimed = {} }
				d.war.ops[st.op] = true
				S.Save.markDirty(p)
			end
		end
	end
	local defending = key:sub(1, 2) == "O_"
	local name = pname(planetId)
	event(
		"lib",
		if defending
			then string.format("%s reinforced %s: +%.2f%% defence", squadText(#participants), name, gain)
			else string.format("%s liberated %.2f%% of %s", squadText(#participants), gain, name),
		planetId,
		"friendly",
		true
	)
	S.State.notify(nil, string.format("+%.2f%% %s for %s", gain, if defending then "defence" else "liberation", name), Config.Colors.Friendly)
	WarService.broadcast(true)
	broadcastLive(true)
end

-- Bond Token bonus for successful operations the player took part in (granted once, any server).
function WarService.claimBonuses(p: Player)
	local d = S.Save and S.Save.get(p)
	if not d or not d.war then
		return
	end
	for opId in d.war.ops do
		if outcomes[opId] == "success" and not d.war.claimed[opId] then
			local op = Campaign.get(opId)
			d.war.claimed[opId] = true
			if op and op.bonusTokens then
				d.tokens += op.bonusTokens
				S.State.notify(p, string.format("%s succeeded! +%d Bond Tokens", op.title, op.bonusTokens), Config.Colors.Gold)
			end
			S.Save.markDirty(p)
		end
	end
end

-- SYNC --------------------------------------------------------------------------------------------
local function flush()
	if offline or not map then
		for k, v in pending do
			contrib[k] = War.applyGain(k, contrib[k], v, now())
		end
		table.clear(pending)
		stats = { m = stats.m + pendStats.m, k = stats.k + pendStats.k }
		pendStats = { m = 0, k = 0 }
		return
	end
	local wrote = false
	-- iterate a snapshot: UpdateAsync yields and contribute() may add keys to `pending` meanwhile.
	-- The gain stays in `pending` until the write succeeds so the displayed value neither dips nor loses it.
	for k, v in table.clone(pending) do
		local result
		local ok, err = msCall(function()
			(map :: MemoryStoreSortedMap):UpdateAsync(k, function(old)
				result = War.applyGain(k, old, v, now())
				return result
			end, MS_TTL)
		end)
		if ok and result then
			local left = (pending[k] or 0) - v
			pending[k] = if left > 1e-9 then left else nil
			contrib[k] = result -- keep the display steady until the next fetch
			wrote = true
		else
			warn("[War] flush failed", k, err)
		end
	end
	if pendStats.m > 0 or pendStats.k > 0 then
		local dm, dk = pendStats.m, pendStats.k
		local result
		local ok = msCall(function()
			(map :: MemoryStoreSortedMap):UpdateAsync(STATS_KEY, function(old)
				old = type(old) == "table" and old or {}
				result = { m = (tonumber(old.m) or 0) + dm, k = (tonumber(old.k) or 0) + dk }
				return result
			end, MS_TTL)
		end)
		if ok and result then
			pendStats = { m = pendStats.m - dm, k = pendStats.k - dk }
			stats = result
			wrote = true
		end
	end
	if wrote then
		-- version stamp: other servers poll this single key and only re-read the whole map when it changes
		flushSeq += 1
		local v = string.format("%s:%d:%d", JOB_SHORT, now(), flushSeq)
		local ok = msCall(function()
			(map :: MemoryStoreSortedMap):SetAsync(VERSION_KEY, v, MS_TTL)
		end)
		if ok then
			lastVersion = v -- our own write: no need to re-read
		end
	end
end

local function fetchContrib()
	if offline or not map then
		return
	end
	local ok, items = msCall(function()
		return (map :: MemoryStoreSortedMap):GetRangeAsync(Enum.SortDirection.Ascending, 200)
	end)
	if ok and items then
		local fresh = {}
		for _, it in items do
			local pre = it.key:sub(1, 2)
			if pre == "P_" or pre == "O_" then
				fresh[it.key] = it.value
			elseif it.key == STATS_KEY and type(it.value) == "table" then
				stats = { m = tonumber(it.value.m) or 0, k = tonumber(it.value.k) or 0 }
			elseif it.key == VERSION_KEY then
				lastVersion = it.value
			end
		end
		contrib = fresh
		nextAt.full = os.clock() + FULL_EVERY * backoff
	elseif not ok then
		warn("[War] fetch failed", items)
	end
end

local function checkVersion()
	if offline or not map then
		return
	end
	local ok, v = msCall(function()
		return (map :: MemoryStoreSortedMap):GetAsync(VERSION_KEY)
	end)
	if ok and v ~= nil and v ~= lastVersion then
		fetchContrib()
	end
end

local function fetchOutcomes()
	if offline or not outcomeStore then
		return
	end
	local ok2, data = pcall(function()
		return (outcomeStore :: DataStore):GetAsync(OUTCOME_KEY)
	end)
	if ok2 and type(data) == "table" then
		outcomes = data
	elseif not ok2 and tostring(data):find("not allowed") then
		offline = true -- Studio without API access: keep the war in memory
	end
end

local function heartbeat()
	if offline or not liveMap then
		return
	end
	local d = localDivers()
	local fresh = {}
	for _, ev in myRecent do
		if now() - ev.t < 300 then
			table.insert(fresh, ev)
		end
	end
	if next(d) == nil and #fresh == 0 then
		return -- nothing to share; an older heartbeat expires on its own (TTL)
	end
	msCall(function()
		(liveMap :: MemoryStoreSortedMap):SetAsync("H_" .. JOB, { t = now(), d = d, e = fresh }, HEART_TTL)
	end)
end

local function readLive()
	if offline or not liveMap then
		return
	end
	local ok, items = msCall(function()
		return (liveMap :: MemoryStoreSortedMap):GetRangeAsync(Enum.SortDirection.Ascending, LIVE_LIMIT)
	end)
	if not ok or not items then
		return
	end
	local d: { [string]: number } = {}
	for _, it in items do
		local v = it.value
		if it.key ~= "H_" .. JOB and type(v) == "table" then
			if (tonumber(v.t) or 0) > now() - LIVE_STALE and type(v.d) == "table" then
				for pid, n in v.d do
					if type(pid) == "string" and Planets.get(pid) then
						d[pid] = (d[pid] or 0) + math.clamp(tonumber(n) or 0, 0, 50)
					end
				end
			end
			if type(v.e) == "table" then
				for _, ev in v.e do
					if type(ev) == "table" and type(ev.id) == "string" and type(ev.text) == "string" then
						pushEvent({
							id = ev.id,
							t = tonumber(ev.t) or now(),
							k = tostring(ev.k),
							text = ev.text:sub(1, 160),
							p = if type(ev.p) == "string" then ev.p else nil,
							c = if type(ev.c) == "string" then ev.c else "friendly",
						}, false)
					end
				end
			end
		end
	end
	remoteDivers = d
end

local function announce(entry)
	local op = entry.op
	if op then
		local good = entry.value == "success"
		S.State.notify(nil, if good then op.successText else op.failText, if good then Config.Colors.Gold else Config.Colors.Danger, "banner")
		S.Fx.play("Sound", { k = if good then "MissionSuccess" else "MissionFail" })
		if good then
			for _, p in Players:GetPlayers() do
				task.spawn(WarService.claimBonuses, p)
			end
		end
	else
		local pid = entry.key:sub(3)
		S.State.notify(nil, pname(pid) .. " has been LIBERATED by the community!", Config.Colors.Gold, "banner")
	end
end

local function decide()
	local list = War.pendingOutcomes(liveContrib(), outcomes, now())
	for _, entry in list do
		if outcomes[entry.key] == nil then
			if outcomeStore and not offline then
				local written
				local ok = pcall(function()
					(outcomeStore :: DataStore):UpdateAsync(OUTCOME_KEY, function(old)
						old = type(old) == "table" and old or {}
						if old[entry.key] == nil then
							old[entry.key] = entry.value
						end
						written = old
						return old
					end)
				end)
				if ok and written then
					outcomes = written
					-- first writer wins: announce what was actually stored
					announce({ key = entry.key, value = written[entry.key], op = entry.op })
				end
				-- write failed: nothing decided yet, retry (and announce) on the next tick
			else
				outcomes[entry.key] = entry.value
				announce(entry)
			end
		end
	end
end

-- value history per planet for the briefing sparkline
local function sampleHist()
	local st = WarService.state()
	for id in Planets.byId do
		local h = hist[id] or {}
		hist[id] = h
		table.insert(h, math.floor(War.display(st[id]) * 100 + 0.5) / 100)
		while #h > HIST_N do
			table.remove(h, 1)
		end
	end
	S.State.broadcast("warHist", { step = HIST_STEP, t = now(), v = hist })
end

-- periodic "Operation X: 62% - 2d 4h left" lines
local function postOps()
	local t = now()
	local c = liveContrib()
	for _, op in Campaign.Operations do
		if War.opStatus(op, outcomes, t) == "active" then
			local prog = War.opProgress(op, c, t)
			local what = if op.kind == "defend" then "defended" else "liberated"
			event("status", string.format("%s: %d%% %s - %s left", op.title, math.floor(prog), what, fmtLeft(op.ends - t)), op.planet, "accent")
		end
	end
end

-- squad launches on this server -> feed (shared with other servers through the heartbeat)
local function watchMission()
	local M = S.Mission
	local st = M and M.state or "Ship"
	if st ~= lastMissionState then
		if lastMissionState == "Ship" and st == "Countdown" and M.planet then
			event("drop", string.format("%s deploying to %s", squadText(#Players:GetPlayers()), pname(M.planet)), M.planet, "accent", true)
		end
		lastMissionState = st
		broadcastLive(false)
	end
end

-- DEBUG (DebugHook war(key, amount) / war("outcome", key, value)) ---------------------------------
-- key: "P_<planet>" / "O_<op>" / a plain planet id (resolved to its liberation or defence key) adds `amount` %
--      as if a test squad finished a mission there; "D_<planet>" sets simulated divers on that planet.
function WarService.debugAdd(key: string, amount: number)
	amount = tonumber(amount) or 10
	if type(key) ~= "string" then
		return
	end
	if key:sub(1, 2) == "D_" then
		local pid = key:sub(3)
		debugDivers[pid] = if amount > 0 then math.floor(amount) else nil
		broadcastLive(true)
		return
	end
	if Planets.get(key) then
		local st = WarService.state()[key]
		local op = st and st.op and Campaign.get(st.op)
		key = if op and op.kind == "defend" then "O_" .. op.id else "P_" .. key
	end
	local pid = key:sub(3)
	local defending = key:sub(1, 2) == "O_"
	if defending then
		local op = Campaign.get(pid)
		pid = op and op.planet or pid
	end
	pending[key] = (pending[key] or 0) + amount
	if amount > 0 then
		pendStats.m += 1
		pendStats.k += math.random(15, 60)
		local n = math.random(1, 4)
		event(
			"lib",
			if defending
				then string.format("Test %s reinforced %s: +%.2f%% defence", squadText(n):lower(), pname(pid), amount)
				else string.format("Test %s liberated %.2f%% of %s", squadText(n):lower(), amount, pname(pid)),
			pid,
			"friendly",
			true
		)
	end
	WarService.broadcast(true)
	broadcastLive(true)
end

function WarService.debugSetOutcome(key: string, value: string?)
	outcomes[key] = value
	WarService.broadcast(true)
	broadcastLive(true)
end

function WarService.init(s)
	S = s
	local ok, res = pcall(function()
		return MemoryStoreService:GetSortedMap(MAP_NAME)
	end)
	if ok then
		map = res
	end
	local okL, resL = pcall(function()
		return MemoryStoreService:GetSortedMap(LIVE_NAME)
	end)
	if okL then
		liveMap = resL
	end
	local ok2, res2 = pcall(function()
		return DataStoreService:GetDataStore(OUTCOME_STORE)
	end)
	if ok2 then
		outcomeStore = res2
	end
	-- probe once: Studio without API access -> offline mode
	task.spawn(function()
		local okProbe, err = pcall(function()
			if outcomeStore then
				(outcomeStore :: DataStore):GetAsync(OUTCOME_KEY)
			end
		end)
		if not okProbe and tostring(err):find("not allowed") then
			offline = true
			warn("[War] offline mode (enable Studio API access for the shared war)")
		end
	end)
	local function watch()
		local first = os.time() >= watchUntil
		watchUntil = os.time() + 45
		if first then
			nextAt.live = 0 -- read the other servers right away when someone starts looking
		end
	end
	S.Actions.on("warSync", function(p)
		watch()
		S.State.send(p, "war", snapshot())
		S.State.send(p, "warLive", liveSnapshot())
		S.State.send(p, "warFeed", table.clone(feed))
		S.State.send(p, "warHist", { step = HIST_STEP, t = now(), v = hist })
	end)
	-- the open war map pings this every ~20 s
	S.Actions.on("warWatch", function(_p)
		watch()
	end)
end

function WarService.start()
	pcall(fetchOutcomes)
	pcall(fetchContrib)
	pcall(WarService.broadcast, true)
	pcall(sampleHist)
	pcall(postOps)
	broadcastLive(true)
	Players.PlayerAdded:Connect(function(p)
		task.wait(2)
		S.State.send(p, "war", snapshot())
		task.wait(8)
		WarService.claimBonuses(p)
	end)
	local function step(name: string, every: number, fn: () -> (), scaled: boolean?)
		local t = os.clock()
		if t < (nextAt[name] or 0) then
			return
		end
		nextAt[name] = t + every * (if scaled == false then 1 else backoff)
		-- pcall: one error must not kill the war loop for the rest of the server's life
		local ok, err = pcall(fn)
		if not ok then
			warn("[War] " .. name .. " failed", err)
		end
	end
	-- stagger the first runs so servers started together don't all hit MemoryStore in the same second
	local jitter = math.random() * 5
	nextAt.flush = os.clock() + jitter
	nextAt.version = os.clock() + jitter + 5
	nextAt.full = os.clock() + FULL_EVERY
	nextAt.outcomes = os.clock() + OUTCOME_EVERY
	nextAt.hist = os.clock() + HIST_STEP
	nextAt.ops = os.clock() + OPPOST_EVERY
	while true do
		task.wait(1)
		if backoff > 1 and os.clock() - lastThrottle > 120 then
			backoff = 1
		end
		step("flush", FLUSH_EVERY, flush)
		step("version", VERSION_EVERY, checkVersion)
		step("full", FULL_EVERY, fetchContrib)
		step("outcomes", OUTCOME_EVERY, fetchOutcomes)
		step("heart", HEART_EVERY, heartbeat)
		if os.time() < watchUntil then
			step("live", LIVE_EVERY, readLive)
		end
		step("mission", 1, watchMission, false)
		step("decide", 5, decide, false)
		step("hist", HIST_STEP, sampleHist, false)
		step("ops", OPPOST_EVERY, postOps, false)
		step("broadcast", 2, function()
			WarService.broadcast(false)
			broadcastLive(false)
		end, false)
	end
end

return WarService
