-- Player lifecycle: characters, health, loadout weapons/ammo, drop capsules, "me" state.
-- Health: Config.PlayerHealth, passive regen per Config.Regen (Studio A/B Feel_Regen), stims (Config.Stims, Action "stim",
-- Fx "Stim" to everyone / "StimDenied" to the user; refilled on respawn and by refill() = supply crates; a stim also
-- starts a stim sprint, Config.Stims.Sprint s of full stamina, MovementService.boost).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Weapons = require(Shared.Data.Weapons)
local TrooperArmor = require(script.Parent.TrooperArmor)
local Movement = require(script.Parent.MovementService) -- stamina + stance (does not require us back)

local PlayerService = {}
local S

export type WeaponState = { id: string, mag: number, spare: number }
export type Rec = {
	player: Player,
	alive: boolean,
	weapons: { [number]: WeaponState? }, -- 1 primary, 2 secondary, 3 support
	slot: number,
	grenades: number,
	grenadeId: string,
	reloadUntil: number,
	reloadSlot: number?,
	lastDamage: number,
	lastShot: number,
	shotBudget: number,
	dropping: boolean,
	kills: number,
	deaths: number,
	stims: number,
	stimLeft: number, -- hp still to heal from the running stim
	stimRate: number, -- hp / s
	stimStart: number, -- server time the heal starts
	stimEnd: number, -- server time the heal ends (no second stim before this)
	stimAsk: number, -- os.clock of the last stim request (spam guard)
}

local recs: { [Player]: Rec } = {}
local dirty: { [Player]: boolean } = {}
PlayerService.recs = recs
-- S.Players.getStance(p) -> "stand"|"crouch"|"prone"|"dive"|"mantle"|"down" (server-side spread etc.)
PlayerService.getStance = Movement.getStance

local function now()
	return workspace:GetServerTimeNow()
end

local IS_STUDIO = RunService:IsStudio()

-- Passive regen preset: Config.Regen.Mode, or the Studio A/B attribute Feel_Regen (mirrored from the client by the
-- "studioFeel" action, see PlayerService.init). "off" = no regen.
local function regenPreset(): { above: number, delay: number, rate: number, cap: number }?
	local mode = Config.Regen.Mode
	if IS_STUDIO then
		local a = workspace:GetAttribute("Feel_Regen")
		if type(a) == "string" then
			mode = a
		end
	end
	if mode == "slow" then
		return Config.Regen.Slow
	elseif mode == "current" then
		return Config.Regen.Current
	end
	return nil
end

local function clearStim(r: Rec)
	r.stimLeft = 0
	r.stimRate = 0
	r.stimStart = 0
	r.stimEnd = 0
end

-- Every trooper gets the same standard R15 body (Config.TrooperBody): consistent arm reach for the
-- two-handed weapon IK (client/CombatPose), armour fit (TrooperArmor) and squad silhouette.
local function trooperDescription(): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	d.HeightScale, d.WidthScale, d.DepthScale, d.HeadScale = 1, 1, 1, 1
	d.BodyTypeScale, d.ProportionScale = 0, 0
	local suit = Color3.fromRGB(84, 88, 92)
	local skin = Color3.fromRGB(196, 160, 132)
	d.HeadColor = skin
	d.TorsoColor, d.LeftArmColor, d.RightArmColor = suit, suit, suit
	d.LeftLegColor, d.RightLegColor = suit, suit
	return d
end

local function loadTrooper(p: Player)
	if Config.TrooperBody then
		local ok, err = pcall(function()
			p:LoadCharacterWithHumanoidDescription(trooperDescription())
		end)
		if ok then
			return
		end
		warn("[Players] trooper body failed, default avatar:", err)
	end
	p:LoadCharacter()
end

local function newWeapon(id: string): WeaponState?
	local w = Weapons.get(id)
	if not w then
		return nil
	end
	local mag = w.mag or 0
	local spare = (w.spareMags or 0)
	if w.perShellReload then
		spare = (w.spareMags or 0) * mag -- shells
	end
	return { id = id, mag = mag, spare = spare }
end

function PlayerService.get(p: Player): Rec?
	return recs[p]
end

function PlayerService.getRoot(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function PlayerService.getHumanoid(p: Player): Humanoid?
	local c = p.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

function PlayerService.isAlive(p: Player): boolean
	local r = recs[p]
	if not r or not r.alive or r.dropping then
		return false
	end
	local h = PlayerService.getHumanoid(p)
	return h ~= nil and h.Health > 0
end

function PlayerService.getAlive(): { Player }
	local out = {}
	for p, _ in recs do
		if PlayerService.isAlive(p) then
			table.insert(out, p)
		end
	end
	return out
end

function PlayerService.getDead(): { Player }
	local out = {}
	for p, r in recs do
		-- players still loading their profile (joined mid-mission) have alive=false but are not "fallen"
		if not r.alive and not r.dropping and (not S.Save or S.Save.isLoaded(p)) then
			table.insert(out, p)
		end
	end
	return out
end

-- Loadout from profile (S.Save) or defaults.
-- `override` (Studio test arena): use this loadout instead of the saved profile's.
function PlayerService.applyLoadout(p: Player, keepCallins: boolean?, override: any?)
	local r = recs[p]
	if not r then
		return
	end
	local lo = override or (S.Save and S.Save.getLoadout(p))
		or { primary = "PR7", secondary = "P3", grenade = "FRAG", callins = { "LANCE", "HALFTON", "STRAFE", "SUPPLY" } }
	r.weapons = { newWeapon(lo.primary) or newWeapon("PR7"), newWeapon(lo.secondary) or newWeapon("P3"), nil }
	r.slot = 1
	r.grenadeId = lo.grenade or "FRAG"
	r.grenades = Config.Grenades
	r.reloadUntil = 0
	r.stims = Config.Stims.Max
	clearStim(r)
	if S.CallIns and S.CallIns.reset then
		if not keepCallins then
			S.CallIns.reset(p, lo.callins)
		end
	end
	if S.Weapons and S.Weapons.equipModel then
		S.Weapons.equipModel(p)
	end
	PlayerService.publish(p)
end

function PlayerService.refill(p: Player, opts: { grenades: number? }?)
	local r = recs[p]
	if not r then
		return
	end
	local magsAdded = 0
	for i, w in r.weapons do
		if w then
			local fresh = newWeapon(w.id)
			if fresh then
				local rounds = (fresh.mag + fresh.spare) - (w.mag + w.spare)
				local def = Weapons.get(w.id)
				local per = math.max(def and def.mag or 1, 1)
				if rounds > 0 then
					magsAdded += math.ceil(rounds / per)
				end
				r.weapons[i] = fresh
			end
		end
	end
	local nadesBefore = r.grenades
	r.grenades = math.min(Config.Grenades, r.grenades + ((opts and opts.grenades) or Config.Grenades))
	local stimsBefore = r.stims or 0
	r.stims = Config.Stims.Max
	S.Fx.to(p, "Sound", { k = "Pickup" })
	-- one pickup toast per item (client/UI/PickupToast routes "Acquired <item> +N")
	local any = false
	if magsAdded > 0 then
		S.State.notify(p, "Acquired Ammo +" .. magsAdded, Config.Colors.Friendly)
		any = true
	end
	if r.grenades > nadesBefore then
		S.State.notify(p, "Acquired Grenades +" .. (r.grenades - nadesBefore), Config.Colors.Friendly)
		any = true
	end
	if r.stims > stimsBefore then
		S.State.notify(p, "Acquired Stims +" .. (r.stims - stimsBefore), Config.Colors.Friendly)
		any = true
	end
	if not any then
		S.State.notify(p, "Resupplied!", Config.Colors.Friendly)
	end
	PlayerService.publish(p)
end

-- Small pickup (elite kills, server/Enemies/Elites): + grenades and + stims, capped at Config.Grenades / Config.Stims.Max.
-- Returns what was actually added.
function PlayerService.topUp(p: Player, grenades: number, stims: number): (number, number)
	local r = recs[p]
	if not r then
		return 0, 0
	end
	local g0, s0 = r.grenades, r.stims or 0
	r.grenades = math.min(Config.Grenades, g0 + grenades)
	r.stims = math.min(Config.Stims.Max, s0 + stims)
	local g, s = r.grenades - g0, r.stims - s0
	if g > 0 or s > 0 then
		S.Fx.to(p, "Sound", { k = "Pickup" })
		if g > 0 then
			S.State.notify(p, "Acquired Grenades +" .. g, Config.Colors.Friendly)
		end
		if s > 0 then
			S.State.notify(p, "Acquired Stims +" .. s, Config.Colors.Friendly)
		end
		PlayerService.publish(p)
	end
	return g, s
end

-- Stim sprint length: Config.Stims.Sprint, or the Studio A/B attribute Feel_StimSprint (seconds, 0 = off; mirrored from
-- the client by the "studioFeel" action, sent by client/Movement.luau).
local function stimSprintTime(): number
	if IS_STUDIO then
		local a = workspace:GetAttribute("Feel_StimSprint")
		if type(a) == "number" then
			return math.clamp(a, 0, 30)
		end
	end
	return Config.Stims.Sprint or 0
end

-- Stim: server-validated quick heal (Config.Stims), plus a stim sprint (MovementService.boost).
-- Returns false + reason ("dead" | "busy" | "empty" | "full").
function PlayerService.useStim(p: Player): (boolean, string?)
	local r = recs[p]
	if not r or not PlayerService.isAlive(p) then
		return false, "dead"
	end
	local h = PlayerService.getHumanoid(p)
	if not h then
		return false, "dead"
	end
	local t = now()
	if t < (r.stimEnd or 0) then
		return false, "busy"
	end
	if (r.stims or 0) <= 0 then
		return false, "empty"
	end
	if h.Health >= h.MaxHealth - 0.5 then
		return false, "full"
	end
	local cfg = Config.Stims
	r.stims -= 1
	local heal = h.MaxHealth * cfg.Heal
	r.stimLeft = heal
	r.stimRate = heal / math.max(cfg.Duration, 0.05)
	r.stimStart = t + cfg.Delay
	r.stimEnd = r.stimStart + cfg.Duration
	local root = PlayerService.getRoot(p)
	S.Fx.play("Stim", { u = p.UserId, p = root and root.Position, t = cfg.Delay + cfg.Duration })
	Movement.boost(p, stimSprintTime()) -- stim sprint: unlimited stamina for a few seconds
	dirty[p] = true
	return true
end

function PlayerService.giveSupport(p: Player, weaponId: string)
	local r = recs[p]
	if not r then
		return
	end
	r.weapons[3] = newWeapon(weaponId)
	r.slot = 3
	r.reloadUntil = 0
	if S.Weapons and S.Weapons.equipModel then
		S.Weapons.equipModel(p)
	end
	S.Fx.to(p, "Sound", { k = "Pickup" })
	local w = Weapons.get(weaponId)
	S.State.notify(p, "Equipped " .. (w and w.name or weaponId), Config.Colors.Friendly)
	PlayerService.publish(p)
end

function PlayerService.damage(p: Player, amount: number, fromPos: Vector3?, opts: { knockback: number?, kind: string? }?)
	if not PlayerService.isAlive(p) then
		return
	end
	local h = PlayerService.getHumanoid(p)
	if not h then
		return
	end
	local r = recs[p] :: Rec
	r.lastDamage = now()
	h:TakeDamage(amount)
	-- feedback scales with the share of health lost (100 hp baseline), so debug god mode stays quiet
	S.Fx.to(p, "Hurt", { amount = amount * 100 / math.max(1, h.MaxHealth), from = fromPos })
	if fromPos and opts and opts.knockback and opts.knockback > 0 then
		PlayerService.knock(p, fromPos, opts.knockback)
	end
	dirty[p] = true
end

-- debug god mode (server/DevTools sets MaxHealth to 1e6): no shoves or knockdowns, so test screenshots keep their framing
function PlayerService.isGod(p: Player): boolean
	local hum = PlayerService.getHumanoid(p)
	return hum ~= nil and hum.MaxHealth >= 1e6
end

function PlayerService.knock(p: Player, fromPos: Vector3, force: number)
	local root = PlayerService.getRoot(p)
	if not root then
		return
	end
	if PlayerService.isGod(p) then
		return
	end
	local d = root.Position - fromPos
	local flat = Vector3.new(d.X, 0, d.Z)
	local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
	-- clients own their characters: ask the client to apply the impulse.
	-- Heavy knocks become a short tumble on the ground (client/Movement.luau "Knockdown"), light ones a shove.
	local v = dir * force + Vector3.new(0, force * 0.45, 0)
	S.Fx.to(p, v.Magnitude >= Config.Move.KnockdownSpeed and "Knockdown" or "Knock", { v = v })
end

-- Drop capsule: anchors the character in the sky above `pos` then tweens it down.
function PlayerService.dropTo(p: Player, pos: Vector3, fallTime: number?)
	local r = recs[p]
	if not r then
		return
	end
	local t = fallTime or 1.8
	r.dropping = true
	r.alive = true
	local function go()
		local c = p.Character
		if not c or not c.Parent then
			loadTrooper(p)
			c = p.Character or p.CharacterAdded:Wait()
		end
		local root = c:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		local h = c:FindFirstChildOfClass("Humanoid")
		if not root or not h then
			r.dropping = false
			return
		end
		local ground = pos
		local start = ground + Vector3.new(0, Config.DropHeight - ground.Y, 0)
		root.Anchored = true
		c:PivotTo(CFrame.new(start))
		S.Fx.play("DropPod", { p = ground, kind = "player", t = t, u = p.UserId })
		local t0 = os.clock()
		while os.clock() - t0 < t do
			local a = math.clamp((os.clock() - t0) / t, 0, 1)
			local y = start.Y + (ground.Y + 3 - start.Y) * (a * a)
			if c.Parent then
				c:PivotTo(CFrame.new(ground.X, y, ground.Z))
			end
			RunService.Heartbeat:Wait()
		end
		if c.Parent then
			c:PivotTo(CFrame.new(ground + Vector3.new(0, 3.2, 0)))
			root.Anchored = false
		end
		r.dropping = false
		-- impact shockwave hurts enemies and knocks nearby squadmates (shared blast path: server/Explosions.luau)
		if S.Explosions and S.Explosions.blast then
			S.Explosions.blast(ground, {
				radius = 7,
				core = 3,
				damage = 300,
				ap = 3,
				size = "M",
				style = "spark",
				knock = 70,
				skipPlayer = p,
			}, { player = p, kind = "explosion", id = "POD" })
		elseif S.Enemies then
			S.Enemies.explode(ground, 7, 3, 300, 3, { player = p, kind = "explosion", id = "POD" })
			S.Fx.play("Explosion", { p = ground, r = 7, size = "M", style = "spark" })
		end
		S.Fx.play("Shockwave", { p = ground, r = 14 })
		S.Fx.play("Shake", { p = ground, mag = 1.2, r = 60 })
		PlayerService.publish(p)
	end
	task.spawn(go)
end

function PlayerService.respawnAt(p: Player, pos: Vector3)
	local r = recs[p]
	if not r then
		return
	end
	r.alive = true
	loadTrooper(p)
	PlayerService.applyLoadout(p, true) -- call-in uses/cooldowns persist through death
	local jitter = Vector3.new(math.random(-6, 6), 0, math.random(-6, 6))
	local target = pos + jitter
	if S.Map and S.Map.current and S.Map.current.groundY then
		target = Vector3.new(target.X, S.Map.current.groundY(target.X, target.Z), target.Z)
	end
	PlayerService.dropTo(p, target)
end

-- Instant spawn (no drop capsule) at `cf` with an optional loadout override. Used by the Studio test arena.
function PlayerService.spawnAt(p: Player, cf: CFrame, loadout: any?)
	local r = recs[p]
	if not r then
		return
	end
	r.alive = true
	r.dropping = false
	loadTrooper(p)
	local c = p.Character
	if c then
		c:PivotTo(cf)
	end
	PlayerService.applyLoadout(p, false, loadout)
end

function PlayerService.spawnOnShip(p: Player)
	local r = recs[p]
	if not r then
		return
	end
	r.alive = true
	r.dropping = false
	loadTrooper(p)
	local c = p.Character
	if c and S.shipSpawn then
		local off = Vector3.new(math.random(-8, 8), 3, math.random(-6, 6))
		c:PivotTo(S.shipSpawn * CFrame.new(off))
	end
	PlayerService.applyLoadout(p)
end

function PlayerService.publish(p: Player)
	dirty[p] = true
end

local function buildMe(p: Player)
	local r = recs[p]
	if not r then
		return nil
	end
	local h = PlayerService.getHumanoid(p)
	local ws = {}
	for i = 1, 3 do
		local w = r.weapons[i]
		ws[i] = w and { id = w.id, mag = w.mag, spare = w.spare } or false
	end
	local ci = S.CallIns and S.CallIns.getState and S.CallIns.getState(p) or nil
	local stamina, exhausted, stance = Movement.state(p)
	return {
		stamina = stamina, -- 0..1
		exhausted = exhausted, -- true = jog-limp until stamina >= Config.Move.RecoverAt
		stance = stance, -- "stand"|"crouch"|"prone" (weapon spread reads this; client-local Store "stance" is faster)
		alive = PlayerService.isAlive(p),
		dropping = r.dropping,
		hp = h and h.Health or 0,
		maxHp = h and h.MaxHealth or Config.PlayerHealth,
		weapon = r.slot,
		weapons = ws,
		grenades = r.grenades,
		grenadeId = r.grenadeId,
		stims = r.stims, -- HUD "STIM x3/3"
		stimsMax = Config.Stims.Max,
		stimEnd = r.stimEnd, -- server time the running stim heal ends (0 = none)
		sprintBoostEnd = Movement.boostEnd(p), -- server time the stim sprint ends (client/Movement keeps stamina full until then)
		reloadUntil = r.reloadUntil,
		callins = ci,
		reinforceReadyAt = ci and ci.reinforceReadyAt or 0,
	}
end

local function squadState()
	local out = {}
	for p, r in recs do
		local h = PlayerService.getHumanoid(p)
		table.insert(out, {
			userId = p.UserId,
			name = p.DisplayName,
			hp = h and h.Health or 0,
			maxHp = h and h.MaxHealth or Config.PlayerHealth,
			alive = r.alive,
		})
	end
	return out
end

local function setupCharacter(p: Player, c: Model)
	local h = c:WaitForChild("Humanoid") :: Humanoid
	h.MaxHealth = Config.PlayerHealth
	h.Health = Config.PlayerHealth
	h.WalkSpeed = Config.WalkSpeed
	h.BreakJointsOnDeath = false
	local hs = c:FindFirstChild("Health")
	if hs then
		hs:Destroy() -- we do our own regen
	end
	h.HealthChanged:Connect(function()
		dirty[p] = true
	end)
	h.Died:Connect(function()
		local r = recs[p]
		if not r or not r.alive then
			return
		end
		r.alive = false
		r.deaths += 1
		clearStim(r)
		local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			S.Fx.play("Explosion", { p = root.Position, r = 4, size = "S", style = "spark" })
		end
		S.Fx.play("Sound", { k = "PlayerDown", p = root and root.Position })
		S.State.notify(nil, p.DisplayName .. " is down!", Config.Colors.Danger)
		if S.Mission and S.Mission.onPlayerDied then
			S.Mission.onPlayerDied(p)
		end
		dirty[p] = true
	end)
	if S.Weapons and S.Weapons.equipModel then
		task.defer(S.Weapons.equipModel, p)
	end
	-- trooper armour kit welded onto the avatar (no-op if the mesh kit is unavailable)
	local okA, errA = pcall(TrooperArmor.apply, S, p, c)
	if not okA then
		warn("[PlayerService] armour failed:", errA)
	end
	Movement.onCharacter(p, c)
end

function PlayerService.init(s)
	S = s
	Players.CharacterAutoLoads = false
	Movement.init(s, PlayerService)
	-- stim (client/Fx/VitalsFx: F, gamepad D-pad Left, touch STIM button). Denials go back so the client can say why.
	S.Actions.on("stim", function(p)
		local r = recs[p]
		if not r then
			return
		end
		local c = os.clock()
		if c - (r.stimAsk or 0) < 0.2 then
			return
		end
		r.stimAsk = c
		local ok, why = PlayerService.useStim(p)
		if not ok and why ~= "dead" then
			S.Fx.to(p, "StimDenied", { why = why })
		end
	end)
	-- Studio only: Variants (client) sets Feel_* workspace attributes locally; server-read ones (Feel_Regen) are
	-- mirrored here so the server sees them too.
	if IS_STUDIO then
		S.Actions.on("studioFeel", function(_p, key, value)
			if type(key) ~= "string" or #key > 48 or string.sub(key, 1, 5) ~= "Feel_" then
				return
			end
			local tv = typeof(value)
			if value ~= nil and tv ~= "string" and tv ~= "number" and tv ~= "boolean" then
				return
			end
			workspace:SetAttribute(key, value)
		end)
	end
	-- late-ready clients: resend everything they may have missed
	S.Actions.on("clientReady", function(p)
		dirty[p] = true
		if S.Save and S.Save.publish then
			S.Save.publish(p)
		end
		if S.Mission and S.Mission.broadcast then
			S.State.send(p, "mission", nil)
			S.Mission.broadcast()
		end
	end)
end

function PlayerService.start()
	local function added(p: Player)
		recs[p] = {
			player = p,
			alive = false,
			weapons = {},
			slot = 1,
			grenades = Config.Grenades,
			grenadeId = "FRAG",
			reloadUntil = 0,
			lastDamage = 0,
			lastShot = 0,
			shotBudget = 0,
			dropping = false,
			kills = 0,
			deaths = 0,
			stims = Config.Stims.Max,
			stimLeft = 0,
			stimRate = 0,
			stimStart = 0,
			stimEnd = 0,
			stimAsk = 0,
		}
		p.CharacterAdded:Connect(function(c)
			setupCharacter(p, c)
		end)
		if S.Save then
			S.Save.load(p)
		end
		if S.Mission and S.Mission.onPlayerJoined then
			S.Mission.onPlayerJoined(p)
		else
			PlayerService.spawnOnShip(p)
		end
	end
	Players.PlayerAdded:Connect(added)
	for _, p in Players:GetPlayers() do
		task.spawn(added, p)
	end
	Players.PlayerRemoving:Connect(function(p)
		recs[p] = nil
		dirty[p] = nil
	end)

	-- regen + state flush (10 Hz)
	local acc = 0
	local squadAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		squadAcc += dt
		-- stim heal runs every frame (smooth bar, starts at once); only players with a running stim do work
		local tf = now()
		for p, r in recs do
			if (r.stimLeft or 0) > 0 and tf >= r.stimStart then
				local h = PlayerService.getHumanoid(p)
				if not h or not PlayerService.isAlive(p) then
					clearStim(r)
				else
					local amt = math.min(r.stimLeft, r.stimRate * dt)
					r.stimLeft -= amt
					h.Health = math.min(h.MaxHealth, h.Health + amt)
					if h.Health >= h.MaxHealth then
						r.stimLeft = 0
					end
				end
			end
		end
		if acc < 0.1 then
			return
		end
		local step = acc
		acc = 0
		local t = now()
		local regen = regenPreset()
		for p, r in recs do
			Movement.step(p, step)
			if regen and PlayerService.isAlive(p) and t - r.lastDamage > regen.delay then
				local h = PlayerService.getHumanoid(p)
				if h and h.Health >= h.MaxHealth * regen.above and h.Health < h.MaxHealth * regen.cap then
					h.Health = math.min(h.MaxHealth * regen.cap, h.Health + regen.rate * step)
				end
			end
			if dirty[p] then
				dirty[p] = nil
				S.State.send(p, "me", buildMe(p))
			end
		end
		if squadAcc > 0.5 then
			squadAcc = 0
			S.State.broadcast("squad", squadState())
		end
	end)
end

return PlayerService
