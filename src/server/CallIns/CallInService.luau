-- Call-in (orbital support) system. docs/spec.md §3, docs/architecture.md "S.CallIns".
--
-- Flow: callin_ready (dial result) -> holding a beacon -> callin_throw(aimPoint) -> beacon part flies,
-- sticks, Fx "Beacon" -> after delay (x0.7 on Perfect Sync) the effect module in Effects/<ID>.luau runs.
--
-- Effect modules are `return function(ctx)`; they run in their own thread and own the lifetime of
-- everything they create (when the function returns, ctx.onStop cleanups run). See `makeContext`.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local CallInData = require(Shared.Data.CallIns)

local CallIns = {}
local S: any = nil

local MAX_THROW_RANGE = 45
local BEACON_TIMEOUT = 2.5
local GRAVITY_SCALE = 0.35 -- beacons fly on a floaty arc (VectorForce cancels the rest)
local READY_COOLDOWN = 0.15
local THROW_COOLDOWN = 0.25
local HOLD_EXPIRE = 120

local BEACON_COLORS = {
	offense = Config.Colors.BeaconOffense,
	supply = Config.Colors.BeaconSupply,
	defense = Config.Colors.BeaconDefense,
}

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
type Slot = { id: string, def: any, chargeAt: { number }, uses: number? }
type Holding = { id: string, perfect: boolean, slot: any, since: number }
type PState = {
	slots: { Slot },
	loadout: { string },
	holding: Holding?,
	reinforceAt: number,
	lastReady: number,
	lastThrow: number,
}

local states: { [Player]: PState } = {}
local idCounter = 0

type Run = {
	cleanups: { () -> () },
	threads: { thread },
	pending: number,
	stopped: boolean,
	main: thread?,
	finished: boolean,
}
local runs: { [Run]: boolean } = {}
local flights: { [number]: { part: Part, conn: RBXScriptConnection?, thread: thread? } } = {}
local domes: { { pos: Vector3, r: number } } = {}
local smokes: { { cf: CFrame, halfL: number, halfW: number, height: number } } = {}
local structures: { [Instance]: { hp: number, maxHp: number, onDestroyed: (() -> ())?, dead: boolean } } = {}
local effectCache: { [string]: any } = {}

CallIns.lastBeaconPos = nil :: Vector3?

local function now(): number
	return workspace:GetServerTimeNow()
end

local function nextId(): number
	idCounter += 1
	return idCounter
end

local function publish(player: Player)
	if S and S.Players and S.Players.publish then
		S.Players.publish(player)
	end
end

local function notify(player: Player, text: string)
	if S and S.State and S.State.notify then
		S.State.notify(player, text, Config.Colors.Danger, "callin")
	end
end

local function getFolder(): Folder
	local f = workspace:FindFirstChild("CallInObjects")
	if not f then
		f = Instance.new("Folder")
		f.Name = "CallInObjects"
		f.Parent = workspace
	end
	return f :: Folder
end

local function isFinite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and v.Magnitude < 1e6
end

-- ---------------------------------------------------------------------------------------------
-- Raycast helpers
-- ---------------------------------------------------------------------------------------------
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.IgnoreWater = true
local worldDirty = true
local worldStamp = 0

-- Exclude enemies, call-in objects and every character (ground/LoS queries).
local function getWorldParams(): RaycastParams
	local t = os.clock()
	if worldDirty or t - worldStamp > 0.5 then
		local list: { Instance } = { getFolder() }
		local enemies = workspace:FindFirstChild("Enemies")
		if enemies then
			table.insert(list, enemies)
		end
		for _, p in Players:GetPlayers() do
			if p.Character then
				table.insert(list, p.Character)
			end
		end
		worldParams.FilterDescendantsInstances = list
		worldDirty = false
		worldStamp = t
	end
	return worldParams
end

local function getEnemyParams(): RaycastParams
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	local enemies = workspace:FindFirstChild("Enemies")
	rp.FilterDescendantsInstances = enemies and { enemies } or {}
	return rp
end

-- Snap a position to the ground below (cast from `up` above). Returns (position, normal).
local function groundAt(pos: Vector3, up: number?, down: number?): (Vector3, Vector3)
	local u = up or 40
	local r = workspace:Raycast(pos + Vector3.new(0, u, 0), Vector3.new(0, -(u + (down or 120)), 0), getWorldParams())
	if r then
		return r.Position, r.Normal
	end
	return pos, Vector3.yAxis
end

local function hasLineOfSight(a: Vector3, b: Vector3): boolean
	return workspace:Raycast(a, b - a, getWorldParams()) == nil
end

-- ---------------------------------------------------------------------------------------------
-- Slots / cooldowns
-- ---------------------------------------------------------------------------------------------
local function newState(loadout: { string }): PState
	local slots: { Slot } = {}
	local ids: { string } = {}
	for i = 1, CallInData.SlotCount do
		local id = loadout[i]
		local def = id and CallInData.get(id)
		if def and def.category ~= "mission" then
			local chargeAt = {}
			for c = 1, def.charges or 1 do
				chargeAt[c] = 0
			end
			table.insert(slots, { id = def.id, def = def, chargeAt = chargeAt, uses = def.uses })
			table.insert(ids, def.id)
		end
	end
	return {
		slots = slots,
		loadout = ids,
		holding = nil,
		reinforceAt = 0,
		lastReady = 0,
		lastThrow = 0,
	}
end

local function ensure(player: Player): PState
	local st = states[player]
	if not st then
		st = newState(CallInData.Starter)
		states[player] = st
	end
	return st
end

local function slotAvailable(slot: Slot, t: number): boolean
	if slot.uses ~= nil and slot.uses <= 0 then
		return false
	end
	for _, at in slot.chargeAt do
		if at <= t then
			return true
		end
	end
	return false
end

-- Spends a charge/use and starts its cooldown. Returns an undo closure.
local function consumeSlot(slot: Slot, t: number): () -> ()
	local idx: number? = nil
	for i, at in slot.chargeAt do
		if at <= t then
			idx = i
			break
		end
	end
	local prevAt = idx and slot.chargeAt[idx] or 0
	local prevUses = slot.uses
	if idx then
		slot.chargeAt[idx] = t + slot.def.cooldown
	end
	if slot.uses ~= nil then
		slot.uses -= 1
	end
	return function()
		if idx then
			slot.chargeAt[idx] = prevAt
		end
		slot.uses = prevUses
	end
end

-- ---------------------------------------------------------------------------------------------
-- Public state API
-- ---------------------------------------------------------------------------------------------
function CallIns.getState(player: Player)
	local st = ensure(player)
	if st.holding then
		local dead = S and S.Players and S.Players.isAlive and not S.Players.isAlive(player)
		if dead or os.clock() - st.holding.since > HOLD_EXPIRE then
			st.holding = nil
		end
	end
	local t = now()
	local slots = {}
	for _, slot in st.slots do
		local charges, nextAt = 0, math.huge
		for _, at in slot.chargeAt do
			if at <= t then
				charges += 1
			else
				nextAt = math.min(nextAt, at)
			end
		end
		table.insert(slots, {
			id = slot.id,
			readyAt = if charges > 0 then 0 else nextAt,
			uses = slot.uses,
			charges = charges,
			maxCharges = #slot.chargeAt,
			nextCharge = if nextAt ~= math.huge then nextAt else nil,
		})
	end
	return {
		slots = slots,
		holding = if st.holding then { id = st.holding.id, perfect = st.holding.perfect } else nil,
		reinforceReadyAt = st.reinforceAt,
	}
end

function CallIns.reset(player: Player, loadoutIds: { string }?)
	states[player] = newState(loadoutIds or CallInData.Starter)
	publish(player)
end

function CallIns.resetAll()
	CallIns.stopAll()
	for _, p in Players:GetPlayers() do
		local old = states[p]
		states[p] = newState(old and old.loadout or CallInData.Starter)
		publish(p)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Zones (Shield Dome / Smoke)
-- ---------------------------------------------------------------------------------------------
-- Segment a->b vs dome surface. Returns the first point where the segment crosses a dome surface
-- (enemy projectiles are blocked both entering and leaving a dome).
function CallIns.blocksProjectile(a: Vector3, b: Vector3): Vector3?
	if #domes == 0 then
		return nil
	end
	local d = b - a
	local len2 = d:Dot(d)
	if len2 < 1e-6 then
		return nil
	end
	for _, dome in domes do
		local oc = a - dome.pos
		local bq = oc:Dot(d) / len2
		local cq = (oc:Dot(oc) - dome.r * dome.r) / len2
		local disc = bq * bq - cq
		if disc > 0 then
			local sq = math.sqrt(disc)
			local t1, t2 = -bq - sq, -bq + sq
			if t1 >= 0 and t1 <= 1 then
				return a + d * t1
			elseif t1 < 0 and t2 >= 0 and t2 <= 1 then
				return a + d * t2
			end
		end
	end
	return nil
end

function CallIns.isInSmoke(pos: Vector3): boolean
	for _, s in smokes do
		local rel = s.cf:PointToObjectSpace(pos)
		if math.abs(rel.X) <= s.halfL and math.abs(rel.Z) <= s.halfW and rel.Y >= -3 and rel.Y <= s.height then
			return true
		end
	end
	return false
end

-- Optional: let enemy projectiles / explosions damage call-in structures (sentry turret).
-- `part` must belong to a registered structure. Returns true if the part was a structure.
function CallIns.damageStructure(part: Instance, amount: number): boolean
	local st = structures[part]
	if not st or st.dead then
		return st ~= nil
	end
	st.hp -= amount
	if st.hp <= 0 then
		st.dead = true
		if st.onDestroyed then
			task.spawn(st.onDestroyed)
		end
	end
	return true
end

-- ---------------------------------------------------------------------------------------------
-- Effect runs
-- ---------------------------------------------------------------------------------------------
local function loadEffect(id: string): any?
	local cached = effectCache[id]
	if cached ~= nil then
		return cached or nil
	end
	local folder = script.Parent:FindFirstChild("Effects")
	local mod = folder and folder:FindFirstChild(id)
	if not mod then
		warn("[CallIns] missing effect module for", id)
		effectCache[id] = false
		return nil
	end
	local ok, fn = pcall(require, mod)
	if not ok or type(fn) ~= "function" then
		warn("[CallIns] effect", id, "failed to load:", fn)
		effectCache[id] = false
		return nil
	end
	effectCache[id] = fn
	return fn
end

local function runCleanups(run: Run)
	local list = run.cleanups
	run.cleanups = {}
	for i = #list, 1, -1 do
		local ok, err = pcall(list[i])
		if not ok then
			warn("[CallIns] cleanup error:", err)
		end
	end
end

local function makeContext(run: Run, base: any)
	local ctx = base
	ctx.S = S
	ctx.params = base.def.params
	ctx.folder = getFolder()
	ctx.source = { player = base.owner, kind = "callin", id = base.def.id }

	ctx.alive = function()
		return not run.stopped
	end
	ctx.onStop = function(fn: () -> ())
		table.insert(run.cleanups, fn)
	end
	-- Tracked task.spawn: cancelled by stopAll; the run waits for these before cleanups.
	ctx.spawn = function(fn: (...any) -> (), ...: any)
		run.pending += 1
		local args = table.pack(...)
		local th = task.spawn(function()
			local ok, err = pcall(fn, table.unpack(args, 1, args.n))
			if not ok then
				warn("[CallIns] effect task error:", err)
			end
			run.pending -= 1
		end)
		table.insert(run.threads, th)
		return th
	end
	ctx.join = function()
		while run.pending > 0 and not run.stopped do
			task.wait(0.1)
		end
	end
	ctx.nextId = nextId
	ctx.groundAt = groundAt
	ctx.los = hasLineOfSight
	ctx.worldParams = getWorldParams
	ctx.enemyParams = getEnemyParams
	ctx.addDome = function(pos: Vector3, r: number)
		local entry = { pos = pos, r = r }
		table.insert(domes, entry)
		local removed = false
		return function()
			if removed then
				return
			end
			removed = true
			local i = table.find(domes, entry)
			if i then
				table.remove(domes, i)
			end
		end
	end
	-- Smoke wall: `cf` = CFrame.lookAt(center, center + dir); X axis = length (across), Z = width (depth).
	ctx.addSmoke = function(cf: CFrame, length: number, width: number, height: number)
		local entry = { cf = cf, halfL = length / 2, halfW = width / 2, height = height }
		table.insert(smokes, entry)
		local removed = false
		return function()
			if removed then
				return
			end
			removed = true
			local i = table.find(smokes, entry)
			if i then
				table.remove(smokes, i)
			end
		end
	end
	-- Makes parts damageable through CallIns.damageStructure (shared hp pool).
	ctx.registerStructure = function(parts: { Instance }, hp: number, onDestroyed: (() -> ())?)
		local entry = { hp = hp, maxHp = hp, onDestroyed = onDestroyed, dead = false }
		for _, p in parts do
			structures[p] = entry
		end
		table.insert(run.cleanups, function()
			for _, p in parts do
				structures[p] = nil
			end
		end)
		return entry
	end
	return ctx
end

local function stopRun(run: Run)
	if run.stopped then
		return
	end
	run.stopped = true
	local me = coroutine.running()
	if run.main and run.main ~= me then
		pcall(task.cancel, run.main)
	end
	for _, th in run.threads do
		if th ~= me then
			pcall(task.cancel, th)
		end
	end
	runCleanups(run)
	runs[run] = nil
end

-- Starts the effect (called when the beacon's delay has elapsed).
local function startEffect(base: any)
	local fn = loadEffect(base.def.id)
	if not fn then
		return
	end
	local run: Run = { cleanups = {}, threads = {}, pending = 0, stopped = false, main = nil, finished = false }
	runs[run] = true
	local ctx = makeContext(run, base)
	run.main = task.spawn(function()
		local ok, err = pcall(fn, ctx)
		if not ok then
			warn("[CallIns] effect", base.def.id, "error:", err)
		end
		if not run.stopped then
			ctx.join()
			run.finished = true
			runCleanups(run)
			runs[run] = nil
			run.stopped = true
		end
	end)
	table.insert(run.threads, run.main :: thread)
end

-- Debug/testing: run an effect immediately at a position (same ctx as a real beacon).
function CallIns.debugRun(owner: Player, id: string, pos: Vector3, dir: Vector3)
	local def = CallInData.get(id)
	if not def then
		return false
	end
	startEffect({ def = def, pos = pos, normal = Vector3.yAxis, dir = dir, owner = owner, perfect = false, beaconId = 0 })
	return true
end

-- ---------------------------------------------------------------------------------------------
-- Beacon throw
-- ---------------------------------------------------------------------------------------------
-- Beacon from the wpn_beacon mesh (Body + glowing Head welded on), nil when the asset is unavailable.
local function makeMeshBeacon(color: Color3, cf: CFrame): BasePart?
	local tpl = S and S.Assets and S.Assets.get("wpn_beacon")
	if not tpl then
		return nil
	end
	local body = tpl:FindFirstChild("Body") :: BasePart?
	if not body then
		tpl:Destroy()
		return nil
	end
	tpl:PivotTo(cf)
	for _, d in tpl:GetChildren() do
		if d:IsA("BasePart") and d ~= body then
			if d.Name == "Muzzle" then
				d:Destroy()
			else
				if d.Name == "Head" then
					d.Color = color
				end
				local w = Instance.new("WeldConstraint")
				w.Part0 = body
				w.Part1 = d
				w.Parent = d
				d.Anchored = false
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
				d.Parent = body
			end
		end
	end
	body.Name = "Beacon"
	body.Anchored = false
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Massless = false
	body.CastShadow = false
	body:SetAttribute("Mesh", true)
	body.Parent = nil
	tpl:Destroy()
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 12
	light.Brightness = 2
	light.Parent = body
	return body
end

local function makeBeaconPart(color: Color3, cf: CFrame): BasePart
	local mesh = makeMeshBeacon(color, cf)
	if mesh then
		return mesh
	end
	local part = Instance.new("Part")
	part.Name = "Beacon"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.8, 1.1, 1.1)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.CastShadow = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = cf
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 12
	light.Brightness = 2
	light.Parent = part
	return part
end

local function beaconCFrame(pos: Vector3, normal: Vector3): CFrame
	local ref = math.abs(normal.Y) > 0.9 and Vector3.xAxis or Vector3.yAxis
	local side = normal:Cross(ref)
	if side.Magnitude < 1e-3 then
		side = Vector3.zAxis
	end
	return CFrame.fromMatrix(pos + normal * 0.4, normal, side.Unit)
end

-- Mesh beacon: the glowing Head (+Z) points out of the surface.
local function meshBeaconCFrame(pos: Vector3, normal: Vector3): CFrame
	local ref = math.abs(normal.Y) > 0.9 and Vector3.xAxis or Vector3.yAxis
	local side = normal:Cross(ref)
	if side.Magnitude < 1e-3 then
		side = Vector3.zAxis
	end
	side = side.Unit
	return CFrame.fromMatrix(pos + normal * 1.3, side, normal:Cross(side), normal)
end

local function destroyFlight(id: number)
	local f = flights[id]
	if not f then
		return
	end
	flights[id] = nil
	if f.conn then
		f.conn:Disconnect()
	end
	if f.part then
		f.part:Destroy()
	end
end

-- Called when a beacon came to rest. Schedules the effect.
local function onBeaconLanded(player: Player, st: PState, holding: Holding, def: any, id: number, part: Part, pos: Vector3, normal: Vector3, dirFlat: Vector3)
	part.Anchored = true
	part.AssemblyLinearVelocity = Vector3.zero
	part.CanCollide = false
	part.CFrame = if part:GetAttribute("Mesh") then meshBeaconCFrame(pos, normal) else beaconCFrame(pos, normal)
	local lastPos = pos
	CallIns.lastBeaconPos = pos
	if S.Mission and S.Mission.onBeacon then
		pcall(S.Mission.onBeacon, pos)
	end

	local delay = def.delay * (holding.perfect and 0.7 or 1)
	local color = BEACON_COLORS[def.beacon] or Config.Colors.BeaconOffense
	S.Fx.play("Beacon", {
		id = id,
		p = pos,
		n = normal,
		color = color,
		perfect = holding.perfect,
		callin = def.id,
		t = delay,
	})

	local flight = flights[id]
	flight.thread = task.spawn(function()
		task.wait(delay)
		S.Fx.play("BeaconEnd", { id = id })
		destroyFlight(id)
		startEffect({
			pos = lastPos,
			normal = normal,
			dir = dirFlat,
			owner = player,
			def = def,
			perfect = holding.perfect,
			beaconId = id,
		})
	end)
end

local function throwBeacon(player: Player, aim: any)
	local st = ensure(player)
	local t = now()
	if os.clock() - st.lastThrow < THROW_COOLDOWN then
		return
	end
	st.lastThrow = os.clock()
	local holding = st.holding
	if not holding then
		return
	end
	if typeof(aim) ~= "Vector3" or not isFinite(aim) then
		return
	end
	if not (S.Players.isAlive(player)) then
		st.holding = nil
		publish(player)
		return
	end
	local root = S.Players.getRoot(player)
	if not root then
		return
	end
	local def = CallInData.get(holding.id)
	if not def then
		st.holding = nil
		publish(player)
		return
	end

	-- Re-validate availability and spend the use/charge now (refunded if the beacon never lands).
	local undo: () -> ()
	if holding.id == "REINFORCE" then
		if t < st.reinforceAt then
			notify(player, "Reinforce is recharging")
			st.holding = nil
			publish(player)
			return
		end
		local prev = st.reinforceAt
		st.reinforceAt = t + def.cooldown
		undo = function()
			st.reinforceAt = prev
		end
	else
		local slot = st.slots[holding.slot]
		if not slot or slot.id ~= holding.id or not slotAvailable(slot, t) then
			notify(player, def.name .. " is not ready")
			st.holding = nil
			publish(player)
			return
		end
		undo = consumeSlot(slot, t)
	end
	st.holding = nil

	-- Clamp the throw to MAX_THROW_RANGE around the player.
	local rootPos = root.Position
	local delta = aim - rootPos
	if delta.Magnitude > MAX_THROW_RANGE then
		delta = delta.Unit * MAX_THROW_RANGE
	end
	local target = rootPos + delta
	local dirFlat = Vector3.new(delta.X, 0, delta.Z)
	if dirFlat.Magnitude < 0.1 then
		local look = root.CFrame.LookVector
		dirFlat = Vector3.new(look.X, 0, look.Z)
		if dirFlat.Magnitude < 0.1 then
			dirFlat = Vector3.zAxis
		end
	end
	dirFlat = dirFlat.Unit

	-- Launch point: right hand, falling back to above the root.
	local char = player.Character
	local hand = char and (char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm"))
	local origin = (hand and hand:IsA("BasePart")) and hand.Position or (rootPos + Vector3.new(0, 2, 0))
	origin += dirFlat * 1.2

	local id = nextId()
	local color = BEACON_COLORS[def.beacon] or Config.Colors.BeaconOffense
	local part = makeBeaconPart(color, CFrame.new(origin))
	part.Parent = getFolder()

	-- Ballistic arc under reduced gravity so we hit `target` in time T.
	local g = workspace.Gravity * GRAVITY_SCALE
	local toTarget = target - origin
	local T = math.clamp(toTarget.Magnitude / math.max(Config.BeaconThrowSpeed, 1), 0.2, 1.2)
	local v0 = toTarget / T + Vector3.new(0, 0.5 * g * T, 0)

	local att = Instance.new("Attachment")
	att.Parent = part
	local force = Instance.new("VectorForce")
	force.Attachment0 = att
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.new(0, part.AssemblyMass * workspace.Gravity * (1 - GRAVITY_SCALE), 0)
	force.Parent = part

	part.Anchored = false
	part.AssemblyLinearVelocity = v0
	part.AssemblyAngularVelocity = Vector3.new(0, 12, 0)
	pcall(function()
		part:SetNetworkOwner(nil)
	end)
	task.delay(0.12, function()
		if part.Parent and not part.Anchored then
			part.CanCollide = true
		end
	end)

	S.Fx.play("Sound", { k = "BeaconThrow", p = origin })

	local flight = { part = part, conn = nil :: RBXScriptConnection?, thread = nil :: thread? }
	flights[id] = flight
	local started = os.clock()
	local prev = origin
	local landed = false

	local function land(pos: Vector3, normal: Vector3)
		if landed then
			return
		end
		landed = true
		if flight.conn then
			flight.conn:Disconnect()
			flight.conn = nil
		end
		onBeaconLanded(player, st, holding, def, id, part, pos, normal, dirFlat)
		publish(player)
	end
	local function fail()
		if landed then
			return
		end
		landed = true
		undo()
		destroyFlight(id)
		notify(player, "Beacon lost - throw again")
		publish(player)
	end

	flight.conn = RunService.Heartbeat:Connect(function()
		if landed then
			return
		end
		if not part.Parent then
			fail()
			return
		end
		local cur = part.Position
		local step = cur - prev
		if step.Magnitude > 0.01 then
			local r = workspace:Raycast(prev, step + step.Unit * 0.4, getWorldParams())
			if r then
				land(r.Position, r.Normal)
				return
			end
		end
		prev = cur
		local elapsed = os.clock() - started
		if elapsed > BEACON_TIMEOUT or (elapsed > 0.3 and part.AssemblyLinearVelocity.Magnitude < 1) then
			local r = workspace:Raycast(cur + Vector3.new(0, 2, 0), Vector3.new(0, -300, 0), getWorldParams())
			if r then
				land(r.Position, r.Normal)
			else
				fail()
			end
		end
	end)

	publish(player)
end

-- ---------------------------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------------------------
local function onReady(player: Player, slotIndex: any, perfect: any)
	local st = ensure(player)
	local clock = os.clock()
	if clock - st.lastReady < READY_COOLDOWN then
		return
	end
	st.lastReady = clock
	if not S.Players.isAlive(player) then
		return
	end
	local isPerfect = perfect == true
	local t = now()

	if slotIndex == "REINFORCE" then
		if t < st.reinforceAt then
			notify(player, "Reinforce is recharging")
			return
		end
		local dead = S.Players.getDead()
		if #dead == 0 then
			notify(player, "No fallen squadmates to reinforce")
			return
		end
		st.holding = { id = "REINFORCE", perfect = isPerfect, slot = "REINFORCE", since = clock }
	elseif type(slotIndex) == "number" and slotIndex == math.floor(slotIndex) then
		local slot = st.slots[slotIndex]
		if not slot then
			return
		end
		if not slotAvailable(slot, t) then
			if slot.uses ~= nil and slot.uses <= 0 then
				notify(player, slot.def.name .. " has no uses left")
			else
				notify(player, slot.def.name .. " is recharging")
			end
			return
		end
		st.holding = { id = slot.id, perfect = isPerfect, slot = slotIndex, since = clock }
	else
		return
	end
	publish(player)
end

local function onCancel(player: Player)
	local st = states[player]
	if st and st.holding then
		st.holding = nil
		publish(player)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------------------------
function CallIns.stopAll()
	-- beacons in flight / waiting for their delay
	for id in table.clone(flights) do
		local f = flights[id]
		if f and f.thread then
			pcall(task.cancel, f.thread)
		end
		if S and S.Fx then
			S.Fx.play("BeaconEnd", { id = id })
		end
		destroyFlight(id)
	end
	for run in table.clone(runs) do
		stopRun(run)
	end
	table.clear(domes)
	table.clear(smokes)
	table.clear(structures)
	local f = workspace:FindFirstChild("CallInObjects")
	if f then
		f:ClearAllChildren()
	end
	for p, st in states do
		if st.holding then
			st.holding = nil
			publish(p)
		end
	end
end

CallIns.stop = CallIns.stopAll

function CallIns.init(registry: any)
	S = registry
	getFolder()
	S.Actions.on("callin_ready", onReady)
	S.Actions.on("callin_throw", throwBeacon)
	S.Actions.on("callin_cancel", onCancel)

	Players.PlayerRemoving:Connect(function(p)
		states[p] = nil
		worldDirty = true
	end)
	local function watch(p: Player)
		p.CharacterAdded:Connect(function()
			worldDirty = true
		end)
	end
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
end

return CallIns
