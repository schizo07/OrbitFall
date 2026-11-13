-- XP/rank, mission rewards, loadout, Armory and Bond purchases (Request remote).
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Weapons = require(Shared.Data.Weapons)
local CallIns = require(Shared.Data.CallIns)
local Bonds = require(Shared.Data.Bonds)

local ProgressService = {}
local S
local handlers: { [string]: (Player, any) -> (boolean, any) } = {}

local function dayNumber()
	return math.floor(os.time() / 86400)
end

function ProgressService.addXp(p: Player, amount: number): boolean
	local d = S.Save.get(p)
	if not d then
		return false
	end
	local rankedUp = false
	d.xp += amount
	while d.rank < Config.MaxRank and d.xp >= Config.xpForRank(d.rank) do
		d.xp -= Config.xpForRank(d.rank)
		d.rank += 1
		rankedUp = true
	end
	if rankedUp and d.rank >= (Config.GamePasses.SquadColours.freeAtRank or 999) then
		d.unlocked.cosmetics.SQUAD_COLOURS = true
	end
	return rankedUp
end

-- Grants a bond item's reward.
local function grant(d, g)
	if g.kind == "weapon" then
		d.unlocked.weapons[g.id] = true
	elseif g.kind == "callin" then
		d.unlocked.callins[g.id] = true
	elseif g.kind == "cosmetic" then
		d.unlocked.cosmetics[g.id] = true
	elseif g.kind == "title" then
		d.unlocked.titles[g.id] = true
	elseif g.kind == "tokens" then
		d.tokens += tonumber(g.id) or 0
	end
end
ProgressService.grant = grant

-- Called by ShopService when a Bond game pass is owned: access + every item.
function ProgressService.grantBondPass(p: Player, bondId: string)
	local d = S.Save.get(p)
	local b = Bonds.get(bondId)
	if not d or not b then
		return
	end
	d.bonds[bondId] = d.bonds[bondId] or { access = false, items = {} }
	local bs = d.bonds[bondId]
	bs.access = true
	for _, it in b.items do
		if not bs.items[it.id] then
			bs.items[it.id] = true
			if it.grant.kind ~= "tokens" then
				grant(d, it.grant)
			end
		end
	end
	S.Save.markDirty(p)
end

-- Mission rewards. ctx = {success, mainSteps, sides, samples, kills}
function ProgressService.reward(p: Player, ctx)
	local d = S.Save.get(p)
	if not d then
		return nil
	end
	local R = Config.Rewards
	local scale = ctx.success and 1 or Config.FailRewardScale
	local xp = math.floor((R.XpBase + R.XpPerMainStep * ctx.mainSteps + R.XpPerSide * ctx.sides + R.XpPerKill * ctx.kills) * scale)
	local salvage = math.floor((R.SalvageBase + R.SalvagePerSide * ctx.sides + R.SalvagePerSample * ctx.samples) * scale)
	local tokens = math.floor((R.TokensBase + R.TokensPerSide * ctx.sides) * scale)
	local bonus = {}
	local day = dayNumber()
	if ctx.success then
		if d.daily.day ~= day then
			d.daily.day = day
			tokens += R.TokensFirstWinOfDay
			table.insert(bonus, "+" .. R.TokensFirstWinOfDay .. " BT first win today")
		end
		local week = math.floor(day / 7)
		if d.daily.week ~= week then
			d.daily.week = week
			d.daily.weekCount = 0
		end
		d.daily.weekCount += 1
		if d.daily.weekCount == R.WeeklyMissionGoal then
			tokens += R.WeeklyTokens
			table.insert(bonus, "+" .. R.WeeklyTokens .. " BT weekly goal")
		end
		d.stats.wins += 1
	end
	d.stats.missions += 1
	d.stats.kills += ctx.kills
	d.salvage += salvage
	d.tokens += tokens
	local rankUp = ProgressService.addXp(p, xp)
	S.Save.markDirty(p)
	task.spawn(S.Save.save, p)
	return {
		success = ctx.success,
		xp = xp,
		salvage = salvage,
		tokens = tokens,
		kills = ctx.kills,
		rankUp = rankUp and d.rank or nil,
		bonusText = table.concat(bonus, "  ·  "),
	}
end

-- REQUESTS -----------------------------------------------------------------------------
handlers.getProfile = function(p)
	return true, S.Save.view(p)
end

handlers.setLoadout = function(p, a)
	local d = S.Save.get(p)
	if not d or type(a) ~= "table" then
		return false, "No profile"
	end
	if S.Mission and S.Mission.state ~= "Ship" and S.Mission.state ~= "Countdown" then
		return false, "Change loadout on the ship"
	end
	local lo = table.clone(d.loadout)
	local function okWeapon(id, slot)
		local w = type(id) == "string" and Weapons.get(id)
		return w and w.slot == slot and d.unlocked.weapons[id]
	end
	if a.primary ~= nil then
		if not okWeapon(a.primary, "primary") then
			return false, "Primary locked"
		end
		lo.primary = a.primary
	end
	if a.secondary ~= nil then
		if not okWeapon(a.secondary, "secondary") then
			return false, "Secondary locked"
		end
		lo.secondary = a.secondary
	end
	if a.grenade ~= nil then
		if not okWeapon(a.grenade, "grenade") then
			return false, "Grenade locked"
		end
		lo.grenade = a.grenade
	end
	if a.callins ~= nil then
		if type(a.callins) ~= "table" or #a.callins > CallIns.SlotCount then
			return false, "Bad call-ins"
		end
		local seen = {}
		local list = {}
		for i = 1, CallIns.SlotCount do
			local id = a.callins[i]
			if id ~= nil then
				local c = type(id) == "string" and CallIns.get(id)
				if not c or not d.unlocked.callins[id] or seen[id] or c.unlock == "mission" then
					return false, "Call-in locked"
				end
				seen[id] = true
				table.insert(list, id)
			end
		end
		lo.callins = list
	end
	if a.skin ~= nil and (a.skin == "default" or d.unlocked.cosmetics[a.skin]) then
		lo.skin = a.skin
	end
	if a.title ~= nil and (a.title == "" or d.unlocked.titles[a.title]) then
		lo.title = a.title
	end
	d.loadout = lo
	S.Save.markDirty(p)
	if S.Mission == nil or S.Mission.state == "Ship" or S.Mission.state == "Countdown" then
		S.Players.applyLoadout(p)
	end
	return true, S.Save.view(p)
end

handlers.buyArmory = function(p, a)
	local d = S.Save.get(p)
	if not d or type(a) ~= "table" then
		return false, "No profile"
	end
	local item = a.kind == "weapon" and Weapons.get(a.id) or a.kind == "callin" and CallIns.get(a.id) or nil
	if not item or item.unlock ~= "armory" then
		return false, "Not sold in the Armory"
	end
	local bucket = a.kind == "weapon" and d.unlocked.weapons or d.unlocked.callins
	if bucket[a.id] then
		return false, "Already owned"
	end
	if d.rank < (item.rank or 1) then
		return false, "Requires rank " .. tostring(item.rank)
	end
	local price = item.salvage or 0
	if d.salvage < price then
		return false, "Not enough Salvage"
	end
	d.salvage -= price
	bucket[a.id] = true
	S.Save.markDirty(p)
	return true, S.Save.view(p)
end

handlers.bondAccess = function(p, a)
	local d = S.Save.get(p)
	local b = type(a) == "table" and Bonds.get(a.bond)
	if not d or not b then
		return false, "Unknown bond"
	end
	d.bonds[b.id] = d.bonds[b.id] or { access = false, items = {} }
	if d.bonds[b.id].access then
		return false, "Already unlocked"
	end
	if d.tokens < b.accessCost then
		return false, "Not enough Bond Tokens"
	end
	d.tokens -= b.accessCost
	d.bonds[b.id].access = true
	S.Save.markDirty(p)
	return true, S.Save.view(p)
end

handlers.bondBuy = function(p, a)
	local d = S.Save.get(p)
	if not d or type(a) ~= "table" then
		return false, "No profile"
	end
	local b, it = Bonds.findItem(a.item)
	if not b or not it then
		return false, "Unknown item"
	end
	local bs = d.bonds[b.id]
	if not b.premium and not bs then
		d.bonds[b.id] = { access = true, items = {} }
		bs = d.bonds[b.id]
	end
	if not bs or not bs.access then
		return false, "Unlock this Bond first"
	end
	if bs.items[it.id] then
		return false, "Already owned"
	end
	if it.page > 1 then
		local owned = 0
		for _, other in b.items do
			if other.page == it.page - 1 and bs.items[other.id] then
				owned += 1
			end
		end
		if owned < b.pageUnlock then
			return false, "Own " .. b.pageUnlock .. " items on page " .. (it.page - 1) .. " first"
		end
	end
	if d.tokens < it.cost then
		return false, "Not enough Bond Tokens"
	end
	d.tokens -= it.cost
	bs.items[it.id] = true
	grant(d, it.grant)
	S.Save.markDirty(p)
	return true, S.Save.view(p)
end

function ProgressService.on(cmd: string, fn: (Player, any) -> (boolean, any))
	handlers[cmd] = fn
end

function ProgressService.init(s)
	S = s
	Net.func("Request").OnServerInvoke = function(p, cmd, args)
		local h = type(cmd) == "string" and handlers[cmd]
		if not h then
			return false, "Unknown request"
		end
		if not S.Save.isLoaded(p) and cmd ~= "getProfile" then
			return false, "Profile still loading"
		end
		local ok, a, b = pcall(h, p, args)
		if not ok then
			warn("[Request]", cmd, a)
			return false, "Server error"
		end
		return a, b
	end
end

return ProgressService
