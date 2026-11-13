-- DataStore-backed profiles (docs/spec.md §8.4). Falls back to memory when API access is off.
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local CallIns = require(Shared.Data.CallIns)
local Weapons = require(Shared.Data.Weapons)

local SaveService = {}
local S
local store: DataStore? = nil
local profiles: { [Player]: any } = {}
local loaded: { [Player]: boolean } = {}
local dirtyAt: { [Player]: number } = {}

local function defaultProfile()
	local unlockedW = {}
	for _, w in Weapons.list() do
		if w.unlock == "starter" then
			unlockedW[w.id] = true
		end
	end
	local unlockedC = {}
	for _, id in CallIns.Starter do
		unlockedC[id] = true
	end
	return {
		v = 1,
		xp = 0,
		rank = 1,
		salvage = 0,
		tokens = 0,
		unlocked = { weapons = unlockedW, callins = unlockedC, cosmetics = {}, titles = {} },
		bonds = { FIELDKIT = { access = true, items = {} } },
		loadout = {
			primary = "PR7",
			secondary = "P3",
			grenade = "FRAG",
			callins = table.clone(CallIns.Starter),
			skin = "default",
			title = "",
		},
		stats = { missions = 0, wins = 0, kills = 0, deaths = 0 },
		daily = { day = 0, week = 0, weekCount = 0 },
		receipts = {},
		receiptOrder = {},
	}
end

-- Fill missing keys after schema growth.
local function reconcile(data: any, template: any)
	for k, v in template do
		if data[k] == nil then
			data[k] = if type(v) == "table" then table.clone(v) else v
		elseif type(v) == "table" and type(data[k]) == "table" and k ~= "receipts" and k ~= "callins" then
			reconcile(data[k], v)
		end
	end
	return data
end

function SaveService.get(p: Player)
	return profiles[p]
end

function SaveService.isLoaded(p: Player): boolean
	return loaded[p] == true
end

function SaveService.getLoadout(p: Player)
	local d = profiles[p]
	return d and d.loadout or nil
end

function SaveService.markDirty(p: Player)
	dirtyAt[p] = os.clock()
	SaveService.publish(p)
end

function SaveService.publish(p: Player)
	local d = profiles[p]
	if not d then
		return
	end
	S.State.send(p, "profile", SaveService.view(p))
end

-- Client-facing profile view (no receipts).
function SaveService.view(p: Player)
	local d = profiles[p]
	if not d then
		return nil
	end
	local passes = S.Shop and S.Shop.getPasses(p) or {}
	return {
		rank = d.rank,
		xp = d.xp,
		xpNext = Config.xpForRank(d.rank),
		salvage = d.salvage,
		tokens = d.tokens,
		unlocked = d.unlocked,
		bonds = d.bonds,
		loadout = d.loadout,
		stats = d.stats,
		passes = passes,
	}
end

local function key(p: Player)
	return "u_" .. p.UserId
end

function SaveService.load(p: Player)
	local data
	if store then
		for attempt = 1, 3 do
			local ok, res = pcall(function()
				return (store :: DataStore):GetAsync(key(p))
			end)
			if ok then
				data = res
				break
			end
			warn("[Save] load failed", attempt, res)
			if tostring(res):find("not allowed") then
				store = nil -- Studio without API access: play from memory
				break
			end
			task.wait(attempt)
		end
	end
	if p.Parent == nil then
		return
	end
	profiles[p] = reconcile(type(data) == "table" and data or defaultProfile(), defaultProfile())
	loaded[p] = true
	SaveService.publish(p)
end

function SaveService.save(p: Player)
	local d = profiles[p]
	if not d or not store or not loaded[p] then
		return
	end
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync(key(p), function(_old)
			return d
		end)
	end)
	if not ok then
		warn("[Save] save failed", err)
	else
		dirtyAt[p] = nil
	end
end

-- Idempotent receipt bookkeeping (keeps last 50).
function SaveService.hasReceipt(p: Player, purchaseId: string): boolean
	local d = profiles[p]
	return d ~= nil and d.receipts[purchaseId] == true
end

function SaveService.addReceipt(p: Player, purchaseId: string)
	local d = profiles[p]
	if not d then
		return
	end
	d.receipts[purchaseId] = true
	table.insert(d.receiptOrder, purchaseId)
	while #d.receiptOrder > 50 do
		local old = table.remove(d.receiptOrder, 1)
		d.receipts[old] = nil
	end
end

function SaveService.init(s)
	S = s
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName)
	end)
	if ok then
		store = res
	else
		warn("[Save] DataStore unavailable (enable Studio API access to persist):", res)
	end
end

function SaveService.start()
	Players.PlayerRemoving:Connect(function(p)
		SaveService.save(p)
		profiles[p] = nil
		loaded[p] = nil
		dirtyAt[p] = nil
	end)
	game:BindToClose(function()
		if RunService:IsStudio() and not store then
			return
		end
		local threads = {}
		for _, p in Players:GetPlayers() do
			table.insert(threads, task.spawn(SaveService.save, p))
		end
		task.wait(2)
	end)
	task.spawn(function()
		while true do
			task.wait(Config.AutosaveInterval)
			for p, _ in dirtyAt do
				SaveService.save(p)
			end
		end
	end)
end

return SaveService
