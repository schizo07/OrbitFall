-- Server-authoritative shooting, reloads, swaps, grenades and gun models.
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Weapons = require(Shared.Data.Weapons)
local EnemiesData = require(Shared.Data.Enemies)

local WeaponService = {}
local S
local hitConfirm: RemoteEvent

local function now()
	return workspace:GetServerTimeNow()
end

-- GUN MODELS ---------------------------------------------------------------------------
local GUN_STYLE = {
	PR7 = { len = 3.0, h = 0.55, w = 0.35, c = Color3.fromHex("3a4150"), a = Color3.fromHex("ff8a2b") },
	SG4 = { len = 3.2, h = 0.6, w = 0.4, c = Color3.fromHex("5a3b2a"), a = Color3.fromHex("ffb36b") },
	SM2 = { len = 2.2, h = 0.5, w = 0.32, c = Color3.fromHex("2b3a4a"), a = Color3.fromHex("fff07a") },
	MR9 = { len = 3.8, h = 0.5, w = 0.32, c = Color3.fromHex("30343c"), a = Color3.fromHex("9fe8ff") },
	HS3 = { len = 3.3, h = 0.62, w = 0.42, c = Color3.fromHex("4a2a20"), a = Color3.fromHex("ff8a5b") },
	VR1 = { len = 3.0, h = 0.6, w = 0.4, c = Color3.fromHex("1f3550"), a = Color3.fromHex("7af0ff") },
	P3 = { len = 1.4, h = 0.45, w = 0.28, c = Color3.fromHex("3a4150"), a = Color3.fromHex("ff8a2b") },
	BP2 = { len = 1.6, h = 0.55, w = 0.32, c = Color3.fromHex("50301f"), a = Color3.fromHex("ff7a3b") },
	ROCKET = { len = 4.4, h = 0.9, w = 0.9, c = Color3.fromHex("4b5a3a"), a = Color3.fromHex("ffa040") },
	GATLING = { len = 3.6, h = 0.9, w = 0.8, c = Color3.fromHex("2e2e34"), a = Color3.fromHex("ffe07a") },
	RAIL = { len = 4.2, h = 0.6, w = 0.5, c = Color3.fromHex("20303a"), a = Color3.fromHex("8affff") },
}

local function part(parent: Instance, size: Vector3, color: Color3, mat: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Size = size
	p.Color = color
	p.Material = mat or Enum.Material.Metal
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

-- Blender meshes (Data/Meshes `wpn_*`, origin = right-hand grip, barrel along -Z). Weapon id -> mesh key + in-hand scale.
local GUN_MESH = {
	PR7 = "wpn_carbine", -- pulse carbine
	SG4 = "wpn_shotgun", -- breacher scatter
	SM2 = "wpn_smg",
	MR9 = "wpn_marksman",
	HS3 = "wpn_shotgun", -- slug shotgun
	VR1 = "wpn_carbine", -- volt repeater (closest rifle silhouette)
	P3 = "wpn_pistol",
	BP2 = "wpn_pistol", -- boomer pistol
	ROCKET = "wpn_rocket_tube",
	GATLING = "wpn_gatling",
	RAIL = "wpn_rail_lance",
}
-- chunky on purpose: the weapon must read clearly on the standard trooper body (Config.TrooperBody)
local GUN_MESH_SCALE = { wpn_marksman = 0.92, wpn_rail_lance = 0.9, wpn_rocket_tube = 0.88, wpn_gatling = 0.95, wpn_shotgun = 1.02, wpn_pistol = 1.0 }
local GUN_MESH_DEFAULT_SCALE = 1.08
local GRENADE_MESH = { FRAG = "wpn_frag_grenade", IMPACT = "wpn_impact_grenade", STUN = "wpn_stun_grenade" }

-- Gun built from its mesh: invisible Handle at the grip, mesh parts welded to it (Barrels on a Motor6D so the client can spin it),
-- Muzzle attachment at the manifest Muzzle object. Returns nil when the asset is not available (caller uses the part-built gun).
local function buildMeshGun(id: string): Model?
	local key = GUN_MESH[id]
	local assets = S and S.Assets
	if not key or not assets then
		return nil
	end
	local tpl = assets.get(key)
	if not tpl then
		return nil
	end
	local scale = GUN_MESH_SCALE[key] or GUN_MESH_DEFAULT_SCALE
	local ok = pcall(function()
		tpl:ScaleTo(scale)
	end)
	if not ok then
		scale = 1
	end
	tpl:PivotTo(CFrame.new()) -- Blender frame: grip at the origin, barrel along -Z
	local m = Instance.new("Model")
	m.Name = "Gun"
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.4, 0.4)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.CastShadow = false
	handle.CFrame = CFrame.new()
	handle.Parent = m
	m.PrimaryPart = handle
	for _, d in tpl:GetChildren() do
		if d:IsA("BasePart") then
			if d.Name == "Muzzle" then
				continue -- marker object only: the attachment below replaces it
			end
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.CastShadow = false
			if d:GetAttribute("Role") == "spin" then
				local pv = (assets.pivot(key, d.Name) or Vector3.zero) * scale
				local off = handle.CFrame:ToObjectSpace(d.CFrame)
				local motor = Instance.new("Motor6D")
				motor.Name = "BarrelSpin"
				motor.Part0 = handle
				motor.Part1 = d
				motor.C0 = CFrame.new(pv)
				motor.C1 = off:Inverse() * motor.C0
				motor.Parent = handle
			else
				local w = Instance.new("WeldConstraint")
				w.Part0 = handle
				w.Part1 = d
				w.Parent = d
			end
			d.Parent = m
		end
	end
	tpl:Destroy()
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = (assets.pivot(key, "Muzzle") or Vector3.new(0, 0.5, -3)) * scale
	muzzle.Parent = handle
	m:SetAttribute("Mesh", true)
	return m
end

-- Thrown grenade / projectile from a mesh: Body (root, collides) + welded extras (Glow...). nil -> caller builds the primitive ball.
local function buildMeshProjectile(key: string, cf: CFrame): Part?
	local assets = S and S.Assets
	local tpl = assets and assets.get(key)
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
		if d:IsA("BasePart") then
			if d.Name == "Muzzle" then
				d:Destroy()
			elseif d ~= body then
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
	body.Anchored = false
	body.CanCollide = true
	body.CanQuery = false
	body.CanTouch = true
	body.Massless = false
	body.Parent = nil
	tpl:Destroy()
	return body
end

function WeaponService.buildGun(id: string): Model
	local st = GUN_STYLE[id] or GUN_STYLE.PR7
	local m = Instance.new("Model")
	m.Name = "Gun"
	local body = part(m, Vector3.new(st.w, st.h, st.len), st.c)
	body.Name = "Body"
	m.PrimaryPart = body
	local barrel = part(m, Vector3.new(st.w * 0.45, st.w * 0.45, st.len * 0.45), Color3.fromHex("1b1d22"))
	barrel.CFrame = body.CFrame * CFrame.new(0, st.h * 0.12, -st.len * 0.6)
	weld(body, barrel)
	local stripe = part(m, Vector3.new(st.w * 1.05, st.h * 0.18, st.len * 0.5), st.a, Enum.Material.Neon)
	stripe.CFrame = body.CFrame * CFrame.new(0, st.h * 0.3, -st.len * 0.05)
	weld(body, stripe)
	local grip = part(m, Vector3.new(st.w * 0.8, st.h * 1.1, st.w * 0.9), st.c)
	grip.CFrame = body.CFrame * CFrame.new(0, -st.h * 0.75, st.len * 0.22) * CFrame.Angles(math.rad(-15), 0, 0)
	weld(body, grip)
	if id == "GATLING" then
		for i = 0, 2 do
			local b = part(m, Vector3.new(0.18, 0.18, st.len * 0.6), Color3.fromHex("1b1d22"))
			local a = i * math.pi * 2 / 3
			b.CFrame = body.CFrame * CFrame.new(math.cos(a) * 0.22, math.sin(a) * 0.22, -st.len * 0.65)
			weld(body, b)
		end
	elseif id == "ROCKET" then
		local cone = part(m, Vector3.new(st.w * 1.2, st.h * 1.2, 0.5), Color3.fromHex("1b1d22"))
		cone.CFrame = body.CFrame * CFrame.new(0, 0, st.len * 0.5)
		weld(body, cone)
	elseif id == "MR9" or id == "RAIL" then
		local scope = part(m, Vector3.new(0.22, 0.22, 0.9), Color3.fromHex("15171c"))
		scope.CFrame = body.CFrame * CFrame.new(0, st.h * 0.62, 0)
		weld(body, scope)
	end
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, st.h * 0.12, -st.len * 0.83)
	muzzle.Parent = body
	return m
end

function WeaponService.equipModel(p: Player)
	local c = p.Character
	local r = S.Players.get(p)
	if not c or not r then
		return
	end
	for _, ch in c:GetChildren() do
		if ch:IsA("Tool") and ch.Name == "Gun" then
			ch:Destroy()
		end
	end
	local w = r.weapons[r.slot]
	if not w then
		return
	end
	-- A Tool gives us the default "arm raised" hold pose and the RightGrip weld for free.
	local meshKey = GUN_MESH[w.id]
	local gun = buildMeshGun(w.id)
	local isMesh = gun ~= nil
	if not gun and meshKey and S.Assets and not S.Assets.ready(meshKey) and not S.Assets.failed(meshKey) then
		-- mesh still downloading: show the part-built gun now, swap to the mesh once it is in
		local weaponId = w.id
		task.spawn(function()
			if S.Assets.waitFor(meshKey, 40) and p.Character == c then
				local r2 = S.Players.get(p)
				local w2 = r2 and r2.weapons[r2.slot]
				if w2 and w2.id == weaponId then
					WeaponService.equipModel(p)
				end
			end
		end)
	end
	local tool = Instance.new("Tool")
	tool.Name = "Gun"
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true
	tool.RequiresHandle = true
	tool.ToolTip = ""
	if not gun then
		gun = WeaponService.buildGun(w.id)
		pcall(function()
			gun:ScaleTo(0.75)
		end)
	end
	local body = gun.PrimaryPart :: BasePart
	body.Name = "Handle"
	for _, ch in gun:GetChildren() do
		ch.Parent = tool
	end
	gun:Destroy()
	-- muzzle is the handle's -Z; with an identity rotation in Grip it points where the hand points (forward)
	if isMesh then
		tool.Grip = CFrame.new() -- mesh origin = the grip
	else
		local st = GUN_STYLE[w.id] or GUN_STYLE.PR7
		tool.Grip = CFrame.new(0, -st.h * 0.075, -st.len * 0.11)
	end
	tool:SetAttribute("WeaponId", w.id)
	tool.Parent = c
	c:SetAttribute("WeaponId", w.id)
end

-- SHOOTING -----------------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function excludeList(shooter: Player): { Instance }
	local list: { Instance } = {}
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	local f = workspace:FindFirstChild("CallInObjects")
	if f then
		table.insert(list, f)
	end
	local o = workspace:FindFirstChild("Ship")
	if o then
		table.insert(list, o)
	end
	return list
end

local function muzzleOrigin(p: Player): Vector3?
	local c = p.Character
	if not c then
		return nil
	end
	local head = c:FindFirstChild("Head") :: BasePart?
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local base = head and head.Position or root.Position + Vector3.new(0, 1.5, 0)
	return base + root.CFrame.RightVector * 1.0
end

local function materialFor(inst: Instance): string
	local enemyId = inst:GetAttribute("EnemyId")
	if enemyId then
		local model = inst:FindFirstAncestorOfClass("Model")
		local kind = model and model:GetAttribute("Kind")
		local def = kind and EnemiesData.get(kind)
		return def and def.faction == "BROOD" and "goo" or "metal"
	end
	return "ground"
end

local function explosionAt(p: Player?, pos: Vector3, sp, weaponId: string, size: string?)
	S.Enemies.explode(pos, sp.radius, sp.core, sp.damage, sp.ap, { player = p, kind = "explosion", id = weaponId })
	S.Fx.play("Explosion", { p = pos, r = sp.radius, size = size or "M", style = "fire" })
end

-- One ray (bullet / pellet). Returns end position.
local function traceShot(p: Player, w, origin: Vector3, dir: Vector3, pierceLeft: number, report: boolean): Vector3
	local excl = excludeList(p)
	rayParams.FilterDescendantsInstances = excl
	local range = w.range or 400
	local res = workspace:Raycast(origin, dir * range, rayParams)
	local endPos = origin + dir * range
	if not res then
		return endPos
	end
	endPos = res.Position
	local inst = res.Instance
	local mat = materialFor(inst)
	if inst:GetAttribute("EnemyId") then
		local delayT = 0
		if w.kind == "rocket" then
			delayT = (res.Position - origin).Magnitude / 260
		end
		local function apply()
			if not inst.Parent then
				-- target moved/died; rockets still explode at the point
				if w.splash then
					explosionAt(p, endPos, w.splash, w.id, "L")
				end
				return
			end
			local hr = S.Enemies.hit(inst, w.damage, w.ap, { player = p, kind = "bullet", id = w.id }, endPos)
			if hr then
				if report then
					hitConfirm:FireClient(p, hr.result, endPos, hr.killed, hr.weak)
				end
				S.Fx.except(p, "Impact", { p = endPos, n = res.Normal, r = hr.result, m = mat }, true)
				if w.arc and hr.result ~= "deflect" then
					local model = inst:FindFirstAncestorOfClass("Model")
					local hitId = inst:GetAttribute("EnemyId")
					local n = 0
					for _, e in S.Enemies.getInRadius(endPos, 12) do
						if e.id ~= hitId and e.alive and n < w.arc then
							n += 1
							S.Enemies.damage(e, w.damage * 0.5, w.ap, { player = p, kind = "bullet", id = w.id }, "body")
							S.Fx.playU("Arc", { a = endPos, b = e.root.Position })
						end
					end
					local _ = model
				end
			end
			if w.splash then
				explosionAt(p, endPos, w.splash, w.id, w.kind == "rocket" and "L" or "S")
			end
		end
		if delayT > 0.02 then
			task.delay(delayT, apply)
		else
			apply()
		end
		if pierceLeft > 0 then
			local model = inst:FindFirstAncestorOfClass("Model")
			if model then
				table.insert(excl, model)
				rayParams.FilterDescendantsInstances = excl
				return traceShot(p, w, endPos + dir * 0.1, dir, pierceLeft - 1, report)
			end
		end
	else
		S.Fx.except(p, "Impact", { p = endPos, n = res.Normal, r = "pen", m = mat }, true)
		if w.splash then
			local delayT = w.kind == "rocket" and (res.Position - origin).Magnitude / 260 or 0
			task.delay(delayT, explosionAt, p, endPos, w.splash, w.id, w.kind == "rocket" and "L" or "S")
		end
	end
	return endPos
end

local function onFire(p: Player, slot: any, aimPoint: any, _seq: any)
	if typeof(aimPoint) ~= "Vector3" or typeof(slot) ~= "number" then
		return
	end
	local r = S.Players.get(p)
	if not r or not S.Players.isAlive(p) then
		return
	end
	if slot ~= r.slot then
		return
	end
	local ws = r.weapons[r.slot]
	if not ws or ws.mag <= 0 then
		return
	end
	local t = now()
	if t < r.reloadUntil then
		return
	end
	local w = Weapons.get(ws.id)
	if not w then
		return
	end
	-- fire-rate leaky bucket (tolerant of latency jitter)
	local interval = 60 / (w.rpm or 600)
	r.shotBudget = math.min(3, r.shotBudget + (t - r.lastShot) / interval)
	r.lastShot = t
	if r.shotBudget < 0.7 then
		return
	end
	r.shotBudget -= 1
	ws.mag -= 1

	local origin = muzzleOrigin(p)
	if not origin then
		return
	end
	if w.spinUp and p.Character then
		-- other clients spin the Gatling barrels from this (the local player spins from its own input)
		local gunTool = p.Character:FindFirstChild("Gun")
		if gunTool then
			gunTool:SetAttribute("FiredAt", t)
		end
	end
	local toAim = aimPoint - origin
	if toAim.Magnitude < 0.5 then
		return
	end
	local dir = toAim.Unit
	local color = w.tracer or Color3.new(1, 0.85, 0.5)
	if w.pellets then
		local spread = math.rad(w.spread or 5)
		for i = 1, w.pellets do
			local rnd = CFrame.lookAt(Vector3.zero, dir)
				* CFrame.Angles((math.random() - 0.5) * spread, (math.random() - 0.5) * spread, 0)
			local d = rnd.LookVector
			local e = traceShot(p, w, origin, d, 0, true)
			if i <= 3 then
				S.Fx.except(p, "Tracer", { a = origin, b = e, c = color, w = w.id, u = p.UserId }, true)
			end
		end
	else
		local e = traceShot(p, w, origin, dir, w.pierce or 0, true)
		S.Fx.except(p, "Tracer", { a = origin, b = e, c = color, w = w.id, u = p.UserId }, true)
	end
	if ws.mag <= 0 and ws.spare > 0 then
		WeaponService.reload(p)
	end
	S.Players.publish(p)
end

function WeaponService.reload(p: Player)
	local r = S.Players.get(p)
	if not r or not S.Players.isAlive(p) then
		return
	end
	local ws = r.weapons[r.slot]
	if not ws then
		return
	end
	local w = Weapons.get(ws.id)
	if not w or not w.mag or ws.mag >= w.mag or ws.spare <= 0 then
		return
	end
	local t = now()
	if t < r.reloadUntil then
		return
	end
	local dur
	if w.perShellReload then
		local need = math.min(w.mag - ws.mag, ws.spare)
		dur = need * (w.reload or 0.5)
	else
		dur = w.reload or 2
	end
	r.reloadUntil = t + dur
	r.reloadSlot = r.slot
	local slot = r.slot
	S.Fx.except(p, "Sound", { k = "Reload", p = muzzleOrigin(p) })
	S.Players.publish(p)
	task.delay(dur, function()
		if r.reloadUntil ~= t + dur or r.slot ~= slot then
			return
		end
		local cur = r.weapons[slot]
		if not cur or cur ~= ws then
			return
		end
		if w.perShellReload then
			local need = math.min(w.mag - ws.mag, ws.spare)
			ws.mag += need
			ws.spare -= need
		else
			ws.spare -= 1
			ws.mag = w.mag
		end
		r.reloadUntil = 0
		S.Players.publish(p)
	end)
end

local function onSwap(p: Player, slot: any)
	local r = S.Players.get(p)
	if not r or typeof(slot) ~= "number" or not r.weapons[slot] or r.slot == slot then
		return
	end
	r.slot = slot
	r.reloadUntil = 0
	WeaponService.equipModel(p)
	S.Players.publish(p)
end

-- GRENADES -----------------------------------------------------------------------------
local function onGrenade(p: Player, aimPoint: any)
	if typeof(aimPoint) ~= "Vector3" then
		return
	end
	local r = S.Players.get(p)
	if not r or not S.Players.isAlive(p) or r.grenades <= 0 then
		return
	end
	local origin = muzzleOrigin(p)
	if not origin then
		return
	end
	local gw = Weapons.get(r.grenadeId) or Weapons.get("FRAG")
	assert(gw)
	r.grenades -= 1
	S.Players.publish(p)

	local folder = workspace:FindFirstChild("CallInObjects") or Instance.new("Folder")
	folder.Name = "CallInObjects"
	folder.Parent = workspace
	local startPos = origin + (aimPoint - origin).Unit * 2
	local g: Part? = GRENADE_MESH[gw.id] and buildMeshProjectile(GRENADE_MESH[gw.id], CFrame.new(startPos)) or nil
	local meshGrenade = g ~= nil
	if not g then
		g = Instance.new("Part")
		g.Shape = Enum.PartType.Ball
		g.Size = Vector3.new(0.9, 0.9, 0.9)
		g.Color = gw.id == "STUN" and Color3.fromHex("7af0ff") or Color3.fromHex("4b5a3a")
		g.Material = Enum.Material.SmoothPlastic
		g.CanQuery = false
		g.CanTouch = true
		g.CFrame = CFrame.new(startPos)
	end
	assert(g)
	g.CustomPhysicalProperties = PhysicalProperties.new(2, 0.6, 0.35)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromHex("ff5a2b")
	light.Range = 6
	light.Brightness = 2
	light.Parent = g
	local d = aimPoint - origin
	local flat = Vector3.new(d.X, 0, d.Z)
	local dist = math.clamp(flat.Magnitude, 4, 40)
	local speed = 55
	local tFlight = dist / speed
	local vy = (d.Y + 0.5 * workspace.Gravity * tFlight * tFlight) / tFlight
	vy = math.clamp(vy, -10, 60)
	local launchVel = (flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, -1)) * speed + Vector3.new(0, vy, 0)
	g.AssemblyLinearVelocity = launchVel
	g.Parent = folder
	if meshGrenade then
		g.AssemblyLinearVelocity = launchVel -- welded extras join the assembly on parenting
		g.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))
	end
	g:SetNetworkOwner(nil)
	S.Fx.play("Sound", { k = "Grenade", p = origin })

	local exploded = false
	local function boom()
		if exploded then
			return
		end
		exploded = true
		local pos = g.Position
		g:Destroy()
		if gw.id == "STUN" then
			for _, e in S.Enemies.getInRadius(pos, 9) do
				if e.class ~= "behemoth" then
					S.Enemies.applyStatus(e, "stun", 5)
				end
			end
			S.Fx.play("Explosion", { p = pos, r = 9, size = "M", style = "emp" })
		else
			explosionAt(p, pos, gw.splash, gw.id, "M")
		end
	end
	if gw.id == "IMPACT" then
		g.Touched:Connect(function(hit)
			local ch = p.Character
			if ch and hit:IsDescendantOf(ch) then
				return
			end
			boom()
		end)
	else
		local bounces = 0
		g.Touched:Connect(function(hit)
			local ch = p.Character
			if ch and hit:IsDescendantOf(ch) then
				return
			end
			bounces += 1
			if bounces < 4 then
				S.Fx.playU("Sound", { k = "GrenadeBounce", p = g.Position })
			end
		end)
	end
	task.delay(gw.id == "IMPACT" and 4 or 2.2, boom)
end

function WeaponService.init(s)
	S = s
	hitConfirm = Net.event("HitConfirm")
	Net.event("Fire").OnServerEvent:Connect(onFire)
	S.Actions.on("reload", WeaponService.reload)
	S.Actions.on("swap", onSwap)
	S.Actions.on("grenade", onGrenade)
	S.Actions.on("dropSupport", function(p)
		local r = S.Players.get(p)
		if r and r.weapons[3] then
			r.weapons[3] = nil
			if r.slot == 3 then
				r.slot = 1
			end
			WeaponService.equipModel(p)
			S.Players.publish(p)
		end
	end)
	local _ = Config
end

return WeaponService
