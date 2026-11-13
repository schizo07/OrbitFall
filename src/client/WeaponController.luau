-- Local shooting with prediction (tracers, muzzle flash, recoil, sounds) + server Fire remote.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Weapons = require(Shared.Data.Weapons)
local Enemies = require(Shared.Data.Enemies)
local Damage = require(Shared.Damage)

local Store = require(script.Parent.Store)
local Input = require(script.Parent.Input)
local Fx = require(script.Parent.Fx)
local Audio = require(script.Parent.Audio)
local Juice = require(script.Parent.Juice)
local Cam = require(script.Parent.CameraController)
local GunFeel = require(script.Parent.Fx.GunFeel)

local WeaponController = {}
local player = Players.LocalPlayer
local fireEv: RemoteEvent
local actionEv: RemoteEvent
local HUD: any = nil

local localMag: { [number]: number } = {}
local lastFireAt = 0
local lastShotClock = 0
local seq = 0
local bloom = 0
local semiLatch = false
local charge = 0
local spin = 0
local sprinting = false
local reloadSeenUntil = 0
local reloadTotal = 1

function WeaponController.setHUD(h)
	HUD = h
end

local function me()
	return Store.get("me")
end

local function current()
	local m = me()
	if not m or not m.weapons then
		return nil, nil, nil
	end
	local slot = m.weapon or 1
	local ws = m.weapons[slot]
	if not ws then
		return nil, nil, nil
	end
	return Weapons.get(ws.id), ws, slot
end

local function isHolding(): boolean
	local m = me()
	if Store.get("holding") then
		return true
	end
	return m and m.callins and m.callins.holding ~= nil or false
end

local function blocked(): boolean
	if Store.get("menuOpen") or Store.get("dialOpen") then
		return true
	end
	local m = me()
	if not m or not m.alive or m.dropping then
		return true
	end
	return isHolding()
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function excludes(): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, n in { "ClientFx", "CallInObjects" } do
		local f = workspace:FindFirstChild(n)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

-- Crosshair ray -> world point (+ the RaycastResult if anything was hit)
function WeaponController.aimPoint(maxRange: number, spreadDeg: number?): (Vector3, RaycastResult?)
	local o, d = Cam.aimRay()
	if spreadDeg and spreadDeg > 0 then
		local s = math.rad(spreadDeg)
		local cf = CFrame.lookAt(Vector3.zero, d) * CFrame.Angles((math.random() - 0.5) * s, (math.random() - 0.5) * s, 0)
		d = cf.LookVector
	end
	-- light aim assist on touch: magnetise toward the nearest enemy within 2.5°
	if Input.isTouch() then
		local ef = workspace:FindFirstChild("Enemies")
		if ef then
			local best, bestDot = nil, math.cos(math.rad(2.5))
			for _, m in ef:GetChildren() do
				local pp = m:IsA("Model") and m.PrimaryPart
				if pp then
					local target = pp.Position + Vector3.new(0, 2, 0)
					local dot = (target - o).Unit:Dot(d)
					if dot > bestDot then
						best, bestDot = target, dot
					end
				end
			end
			if best then
				d = d:Lerp((best - o).Unit, 0.6).Unit
			end
		end
	end
	rayParams.FilterDescendantsInstances = excludes()
	local res = workspace:Raycast(o, d * (maxRange + 30), rayParams)
	if res then
		return res.Position, res
	end
	return o + d * (maxRange + 30), nil
end

local function muzzle(): (Vector3, Attachment?)
	local c = player.Character
	local gun = c and c:FindFirstChild("Gun")
	local handle = gun and gun:FindFirstChild("Handle")
	local att = handle and handle:FindFirstChild("Muzzle") :: Attachment?
	if att then
		return att.WorldPosition, att
	end
	local head = c and c:FindFirstChild("Head") :: BasePart?
	return head and head.Position or Cam.aimRay(), nil
end

local function predictResult(res: RaycastResult?, w): (string, string)
	if not res then
		return "pen", "ground"
	end
	local inst = res.Instance
	local zoneName = inst:GetAttribute("Zone")
	local model = inst:FindFirstAncestorOfClass("Model")
	local kind = model and model:GetAttribute("Kind")
	if zoneName and kind then
		local def = Enemies.get(kind)
		local zone = def and def.zones[zoneName]
		local mat = def and def.faction == "BROOD" and "goo" or "metal"
		if zone then
			local _, r = Damage.compute(w.damage, w.ap, zone.armor, zone.mult)
			return r, mat
		end
		return "pen", mat
	end
	return "pen", "ground"
end

local function shoot(w, slot: number)
	local aim = Input.isDown("Aim")
	local spread = (w.spread or 1) * (aim and 0.45 or 1) * (1 + bloom) * (sprinting and 1.6 or 1)
	local mPos, mAtt = muzzle()
	seq += 1
	if w.pellets then
		local centre = WeaponController.aimPoint(w.range or 120, 0)
		fireEv:FireServer(slot, centre, seq)
		for i = 1, math.min(w.pellets, 6) do
			local p, res = WeaponController.aimPoint(w.range or 120, w.spread * 1.0)
			Fx.tracer(mPos, p, w.tracer or Color3.new(1, 0.8, 0.4), 0.12)
			if res and i <= 3 then
				local r, m = predictResult(res, w)
				Fx.impact(p, res.Normal, r, m)
			end
		end
	else
		local p, res = WeaponController.aimPoint(w.range or 400, spread)
		fireEv:FireServer(slot, p, seq)
		Fx.tracer(mPos, p, w.tracer or Color3.new(1, 0.8, 0.4), w.kind == "rail" and 0.5 or w.kind == "rocket" and 0.6 or 0.14)
		if res then
			local r, m = predictResult(res, w)
			Fx.impact(p, res.Normal, r, m)
		end
	end
	GunFeel.shot(w, aim) -- grip recoil, star muzzle flash + light, casing, gatling heat (client/Fx/GunFeel.luau)
	Audio.play(w.sound, mAtt or mPos, { source = "local" })
	local kick = (w.recoil or 0.5) * (aim and 0.6 or 1)
	Juice.kick(kick, (math.random() - 0.5) * kick * 0.6)
	if w.kind == "rocket" or w.kind == "rail" then
		Juice.shake(0.35, 0.25)
	end
	bloom = math.min(bloom + (w.kind == "auto" and 0.08 or 0.3), 1.2)
	localMag[slot] = math.max(0, (localMag[slot] or 0) - 1)
	lastShotClock = os.clock()
	if HUD and HUD.ammoShot then
		HUD.ammoShot(slot, localMag[slot], w.mag or 1) -- predicted counter tick (server state catches up later)
	end
end

local function tryReload()
	local w, ws, slot = current()
	if not w or not ws or not slot then
		return
	end
	if ws.spare <= 0 or (localMag[slot] or ws.mag) >= (w.mag or 0) then
		return
	end
	actionEv:FireServer("reload")
	Audio.play("Reload", (muzzle()))
end

local function onMe(m)
	if not m or not m.weapons then
		return
	end
	for slot, ws in m.weapons do
		if ws then
			local recentlyFired = os.clock() - lastShotClock < 0.35
			if recentlyFired and localMag[slot] then
				localMag[slot] = math.min(localMag[slot], ws.mag)
			else
				localMag[slot] = ws.mag
			end
		end
	end
	local w = current()
	Cam.setZoom(w and w.zoom or 1)
	if HUD and HUD.setLocalMag then
		HUD.setLocalMag(localMag)
	end
end

function WeaponController.localMag(slot: number): number?
	return localMag[slot]
end

-- Gatling barrels: the mesh gun carries a Motor6D "BarrelSpin" (Handle -> Barrels, rotation about the gun's Z axis).
-- Local player spins with its own spin-up; other players spin while the server flags recent shots (Tool attribute FiredAt).
local barrelAngle: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local barrelSpeed: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local BARREL_MAX = 38 -- rad/s

local function stepBarrels(dt: number)
	local nowServer = workspace:GetServerTimeNow()
	for _, pl in Players:GetPlayers() do
		local tool = pl.Character and pl.Character:FindFirstChild("Gun")
		local handle = tool and tool:FindFirstChild("Handle")
		local motor = handle and handle:FindFirstChild("BarrelSpin") :: Motor6D?
		if motor then
			local target = 0
			if pl == player then
				local w = current()
				if w and w.spinUp then
					target = BARREL_MAX * math.clamp(spin / w.spinUp, 0, 1)
				end
			else
				local firedAt = tool and tool:GetAttribute("FiredAt")
				if type(firedAt) == "number" and nowServer - firedAt < 0.35 then
					target = BARREL_MAX
				end
			end
			local v = barrelSpeed[motor] or 0
			v += (target - v) * math.min(1, dt * (if target > v then 6 else 2.5))
			barrelSpeed[motor] = v
			if v > 0.05 then
				local a = ((barrelAngle[motor] or 0) + v * dt) % (math.pi * 2)
				barrelAngle[motor] = a
				motor.Transform = CFrame.Angles(0, 0, a)
			end
		end
	end
end

function WeaponController.init()
	RunService.RenderStepped:Connect(stepBarrels)
	fireEv = Net.event("Fire")
	actionEv = Net.event("Action")
	Store.on("me", onMe)

	Input.on("Reload", function(d)
		if d and not blocked() then
			tryReload()
		end
	end)
	for i = 1, 3 do
		Input.on("Swap" .. i, function(d)
			local m = me()
			if d and m and m.weapons and m.weapons[i] and m.weapon ~= i then
				actionEv:FireServer("swap", i)
				Audio.play2D("Swap")
				charge, spin = 0, 0
			end
		end)
	end
	Input.on("SwapNext", function(d)
		local m = me()
		if not d or not m or not m.weapons then
			return
		end
		local cur = m.weapon or 1
		for k = 1, 3 do
			local i = (cur + k - 1) % 3 + 1
			if m.weapons[i] then
				actionEv:FireServer("swap", i)
				Audio.play2D("Swap")
				return
			end
		end
	end)
	Input.on("Grenade", function(d)
		local m = me()
		if d and not blocked() and m and m.grenades > 0 then
			local p = WeaponController.aimPoint(60, 0)
			actionEv:FireServer("grenade", p)
		end
	end)
	Input.on("Sprint", function(d)
		sprinting = d
	end)
	Input.on("Fire", function(d)
		if not d then
			semiLatch = false
		end
	end)

	Net.event("HitConfirm").OnClientEvent:Connect(function(result, pos, killed, weak)
		if HUD and HUD.hitmarker then
			HUD.hitmarker(result, weak, killed)
		end
		if result == "deflect" then
			Audio.play2D("HitDeflect")
		elseif weak then
			Audio.play2D("HitWeak")
		elseif result == "partial" then
			Audio.play2D("HitPartial")
		else
			Audio.play2D("HitPen")
		end
		if weak and typeof(pos) == "Vector3" then
			Fx.critPop(pos, killed)
		end
		if killed then
			Audio.play2D(weak and "KillWeak" or "Kill")
			Juice.hitstop(weak and 0.05 or 0.03)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		bloom = math.max(0, bloom - dt * 2.2)
		local c = player.Character
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		if hum then
			local speed = Config.WalkSpeed
			if Input.isDown("Aim") then
				speed = Config.AimSpeed
			elseif sprinting and not Input.isDown("Fire") then
				speed = Config.SprintSpeed
			end
			hum.WalkSpeed = speed
		end
		local w, ws, slot = current()
		local m = me()
		if HUD and HUD.setReload then
			local serverNow = workspace:GetServerTimeNow()
			if m and m.reloadUntil and m.reloadUntil > serverNow and w then
				-- total = what was left when this reload was first seen (per-shell reloads only load the missing shells,
				-- so the catalogue value overestimates it and the bar would start half-full)
				if m.reloadUntil ~= reloadSeenUntil then
					reloadSeenUntil = m.reloadUntil
					local maxTotal = w.perShellReload and (w.reload or 0.5) * (w.mag or 1) or (w.reload or 2)
					reloadTotal = math.clamp(m.reloadUntil - serverNow, 0.05, math.max(0.05, maxTotal))
				end
				HUD.setReload(math.clamp(1 - (m.reloadUntil - serverNow) / reloadTotal, 0, 1))
			else
				HUD.setReload(nil)
			end
		end
		if HUD and HUD.setSpread and w then
			HUD.setSpread((w.spread or 1) * (Input.isDown("Aim") and 0.45 or 1) * (1 + bloom))
		end
		if not w or not ws or not slot then
			return
		end
		local firing = Input.isDown("Fire") and not blocked()
		local reloading = m and m.reloadUntil and m.reloadUntil > workspace:GetServerTimeNow()
		if w.spinUp then
			spin = firing and math.min(w.spinUp, spin + dt) or math.max(0, spin - dt * 2)
		end
		if w.kind == "rail" then
			if firing and not reloading and (localMag[slot] or 0) > 0 then
				local before = charge
				charge += dt
				if before == 0 then
					Audio.play("LanceCharge", (muzzle()))
				end
				if HUD and HUD.setCharge then
					HUD.setCharge(math.clamp(charge / (w.charge or 2), 0, 1))
				end
			elseif charge > 0 then
				local ready = charge >= (w.charge or 2)
				charge = 0
				if HUD and HUD.setCharge then
					HUD.setCharge(nil)
				end
				if ready and not blocked() then
					shoot(w, slot)
				end
			elseif firing and not reloading and (localMag[slot] or 0) <= 0 and not semiLatch then
				-- empty rail: auto-reload like the other weapons
				semiLatch = true
				Audio.play2D("DryFire")
				tryReload()
			end
			return
		end
		if not firing or reloading then
			return
		end
		if (localMag[slot] or 0) <= 0 then
			if not semiLatch then
				semiLatch = true
				Audio.play2D("DryFire")
				tryReload()
			end
			return
		end
		if w.spinUp and spin < w.spinUp then
			return
		end
		local interval = 60 / (w.rpm or 600)
		local t = os.clock()
		if t - lastFireAt < interval then
			return
		end
		if w.kind ~= "auto" then
			if semiLatch then
				return
			end
			semiLatch = true
		end
		lastFireAt = t
		shoot(w, slot)
	end)
end

return WeaponController
