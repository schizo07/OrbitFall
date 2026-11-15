-- Side objective FOUNDRY: a drone factory on a spare site keeps launching small flying drones (Data/Enemies DRONE_COG /
-- SPOREMITE, flown by server/Enemies/DroneAI.luau) that patrol the map and harass the squad. Destroying it stops them.
--   COG:   Drone Foundry   (steel block, launch hatch on a tower, two orange vents on the front)
--   BROOD: Spore Spire     (mud mound, tall spire with a glowing mouth on top, two green spore pustules)
-- Destroy: an explosion at EACH of the 2 vents (any explosive, like the NEST vent: Light armour, bullets do nothing),
-- or plant a charge (hold 3 s, 4 s fuse). When it dies, the drones it launched drop out of the sky.
-- Launch: one drone every RATE s while a trooper is within NEAR studs, every RATE x 25/12 s otherwise; at most CAP alive.
--   RATE = 12, Studio A/B Feel_FoundryRate (number, read live).
--
--   SideFoundry.start(ctx, siteCF, index) -> controller {entry, stop, isDestroyed, destroy}
--   SideFoundry.onExplosion(pos, radius)   (forwarded from ObjectiveService.onExplosion)

local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local SideFoundry = {}

local CAP = 6
local RATE = 12
local FAR_MULT = 25 / 12
local NEAR = 150

local DARK = Color3.fromRGB(40, 44, 54)
local STEEL = Color3.fromRGB(100, 106, 118)
local RUST = Color3.fromRGB(120, 84, 64)
local COG_GLOW = Color3.fromRGB(255, 130, 50)
local MUD = Color3.fromRGB(96, 58, 120)
local FLESH = Color3.fromRGB(130, 80, 126)
local SPORE = Color3.fromRGB(150, 255, 90)

local active: { [any]: boolean } = {}

local function smoke(parent: Instance, color: Color3, rate: number, size: number)
	local em = Instance.new("ParticleEmitter")
	em.Texture = "rbxasset://textures/particles/smoke_main.dds"
	em.Rate = rate
	em.Lifetime = NumberRange.new(2, 3.5)
	em.Speed = NumberRange.new(3, 6)
	em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * 0.4), NumberSequenceKeypoint.new(1, size) })
	em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	em.Color = ColorSequence.new(color)
	em.LightEmission = 0.4
	em.EmissionDirection = Enum.NormalId.Top
	em.Parent = parent
	return em
end

function SideFoundry.start(ctx: any, siteCF: CFrame, index: number): any
	local S = ctx.S
	local brood = ctx.faction == "BROOD"
	local droneKind = if brood then "SPOREMITE" else "DRONE_COG"
	local cf = SetPieces.groundCF(ctx.map, siteCF, 12)
	local pos = cf.Position
	local f = Instance.new("Model")
	f.Name = (if brood then "SporeSpire" else "DroneFoundry") .. index
	f.Parent = ctx.folder

	local id = if index > 1 then "FOUNDRY" .. index else "FOUNDRY"
	local entry = ctx.newEntry({
		id = id,
		title = if brood then "Destroy the Spore Spire" else "Destroy the Drone Foundry",
		main = false,
		steps = { "Blow up both vents (0/2)" },
	})
	local ctl: any = { entry = entry, isDestroyed = false }
	local alive = true
	local vents: { { pos: Vector3, parts: { BasePart }, light: PointLight?, fx: ParticleEmitter?, dead: boolean } } = {}
	local hatchPos: Vector3
	local hatchDoors: { { part: BasePart, open: CFrame, shut: CFrame } } = {}
	local chargeSpot: Part

	if brood then
		-- mound + tapering spire, glowing mouth on top (the "hatch"), two spore pustules low on the front
		ctx.ball(f, 22, cf * CFrame.new(0, 1, 0), MUD, Enum.Material.Mud)
		ctx.ball(f, 13, cf * CFrame.new(9, 0, 5), FLESH, Enum.Material.Mud)
		ctx.ball(f, 12, cf * CFrame.new(-9, 0, 6), FLESH, Enum.Material.Mud)
		local h = 8
		for k = 0, 4 do
			local d = 8 - k * 1.3
			ctx.cyl(f, d, 4.4, cf * CFrame.new(math.sin(k) * 0.6, h + 2, math.cos(k) * 0.6), if k % 2 == 0 then MUD else FLESH, Enum.Material.Mud)
			h += 4
		end
		for k = 1, 6 do
			local a = k / 6 * math.pi * 2
			ctx.part(f, Vector3.new(1.2, 7, 1.2), cf * CFrame.new(math.cos(a) * 4, h - 1, math.sin(a) * 4) * CFrame.Angles(math.sin(a) * 0.45, 0, -math.cos(a) * 0.45), Color3.fromRGB(70, 36, 96), Enum.Material.Slate, { CanCollide = false })
		end
		local mouth = ctx.cyl(f, 4.6, 0.6, cf * CFrame.new(0, h + 0.3, 0), SPORE, Enum.Material.Neon, { CanCollide = false })
		ctx.light(mouth, Color3.fromRGB(200, 255, 170), 22, 1.4)
		smoke(mouth, SPORE, 6, 5)
		hatchPos = (cf * CFrame.new(0, h + 2.5, 0)).Position
		for i, x in { -6, 6 } do
			local vcf = cf * CFrame.new(x, 4, -9) * CFrame.Angles(math.rad(-35), 0, 0)
			local rim = ctx.cyl(f, 5, 0.8, vcf, Color3.fromRGB(70, 36, 96), Enum.Material.Slate, { CanCollide = false, Name = "VentRim" .. i })
			local pod = ctx.ball(f, 3.6, vcf * CFrame.new(0, 0.9, 0), SPORE, Enum.Material.Neon, { CanCollide = false, Name = "Vent" .. i })
			local l = ctx.light(pod, Color3.fromRGB(210, 255, 170), 14, 1.2)
			local em = smoke(pod, SPORE, 5, 4)
			TweenService:Create(pod, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Size = Vector3.new(4.2, 4.2, 4.2) }):Play()
			vents[i] = { pos = pod.Position, parts = { pod, rim }, light = l, fx = em, dead = false }
		end
		chargeSpot = ctx.ball(f, 3, cf * CFrame.new(0, 0.9, -13), Color3.fromRGB(84, 50, 104), Enum.Material.Mud, { CanCollide = false, Name = "ChargeSpot" })
		ctx.glow(f, Vector3.new(1.2, 1.2, 1.2), cf * CFrame.new(0, 2.2, -13), Color3.fromRGB(255, 190, 60), { Shape = Enum.PartType.Ball })
	else
		-- factory block, tower with a two-door launch hatch, conveyor, two glowing vents on the front face
		ctx.part(f, Vector3.new(22, 10, 18), cf * CFrame.new(0, 5, 0), STEEL, Enum.Material.Metal)
		ctx.part(f, Vector3.new(22.6, 1.2, 18.6), cf * CFrame.new(0, 10.6, 0), DARK, Enum.Material.DiamondPlate)
		ctx.part(f, Vector3.new(10, 8, 10), cf * CFrame.new(0, 15, 2), RUST, Enum.Material.CorrodedMetal)
		ctx.part(f, Vector3.new(10.6, 0.6, 10.6), cf * CFrame.new(0, 19.2, 2), DARK, Enum.Material.Metal)
		local ring = ctx.cyl(f, 7.4, 0.3, cf * CFrame.new(0, 19.55, 2), COG_GLOW, Enum.Material.Neon, { CanCollide = false })
		ctx.light(ring, Color3.fromRGB(255, 190, 140), 24, 1.5)
		hatchPos = (cf * CFrame.new(0, 22, 2)).Position
		for _, sx in { -1, 1 } do
			local shut = cf * CFrame.new(sx * 1.6, 19.8, 2)
			local door = ctx.part(f, Vector3.new(3.2, 0.5, 6.4), shut, Color3.fromRGB(160, 160, 170), Enum.Material.DiamondPlate, { CanCollide = false })
			table.insert(hatchDoors, { part = door, shut = shut, open = shut * CFrame.new(sx * 2.4, 0.2, 0) })
		end
		for _, x in { -8, 8 } do
			ctx.cyl(f, 2.6, 6, cf * CFrame.new(x, 14, 6), STEEL, Enum.Material.Metal)
			local tip = ctx.cyl(f, 2.8, 0.5, cf * CFrame.new(x, 17.2, 6), Color3.fromRGB(70, 68, 68), Enum.Material.Metal, { CanCollide = false })
			smoke(tip, Color3.fromRGB(70, 68, 68), 6, 6)
		end
		ctx.part(f, Vector3.new(6, 1.2, 20), cf * CFrame.new(-15, 0.6, -4), DARK, Enum.Material.Metal)
		for k = 0, 2 do
			ctx.ball(f, 1.8, cf * CFrame.new(-15, 2.1, -11 + k * 6), Color3.fromRGB(72, 78, 90), Enum.Material.Metal, { CanCollide = false })
		end
		ctx.glow(f, Vector3.new(18, 0.6, 0.4), cf * CFrame.new(0, 9, -9.25), Color3.fromRGB(255, 60, 50))
		for i, x in { -6, 6 } do
			local vcf = cf * CFrame.new(x, 4.5, -9.2)
			local grate = ctx.part(f, Vector3.new(5, 4, 0.6), vcf, Color3.fromRGB(16, 16, 20), Enum.Material.Metal, { Name = "Vent" .. i, CanCollide = false })
			local parts: { BasePart } = { grate }
			local l: PointLight? = nil
			for k = -2, 2 do
				local slat = ctx.glow(f, Vector3.new(4.4, 0.3, 0.3), vcf * CFrame.new(0, k * 0.7, -0.4), COG_GLOW)
				table.insert(parts, slat)
				if k == 0 then
					l = ctx.light(slat, Color3.fromRGB(255, 150, 90), 16, 1.4)
				end
			end
			local em = smoke(grate, Color3.fromRGB(90, 80, 76), 5, 5)
			vents[i] = { pos = (vcf * CFrame.new(0, 0, -1)).Position, parts = parts, light = l, fx = em, dead = false }
		end
		chargeSpot = ctx.part(f, Vector3.new(3, 2, 3), cf * CFrame.new(13, 1, -11), Color3.fromRGB(255, 190, 60), Enum.Material.Metal, { CanCollide = false, Name = "ChargeSpot" })
		ctx.glow(f, Vector3.new(2.4, 0.3, 2.4), chargeSpot.CFrame * CFrame.new(0, 1.1, 0), Color3.fromRGB(255, 190, 60), { Transparency = 0.3 })
	end
	ctl.position = pos
	ctl.vents = vents
	ctx.setMarker(entry, pos)

	local launched: { any } = {}

	local function liveDrones(): number
		local n = 0
		for i = #launched, 1, -1 do
			if launched[i].alive then
				n += 1
			else
				table.remove(launched, i)
			end
		end
		return n
	end

	local function updateStep()
		local n = 0
		for _, v in vents do
			if v.dead then
				n += 1
			end
		end
		local st = entry.steps[1]
		st.text = string.format("Blow up both vents (%d/2)", n)
		st.progress = if n > 0 then n / 2 else nil
		ctx.changed(true)
	end

	local function destroyFoundry()
		if ctl.isDestroyed then
			return
		end
		ctl.isDestroyed = true
		active[ctl] = nil
		local color = if brood then SPORE else COG_GLOW
		ctx.fx("Explosion", { p = pos + Vector3.new(0, 8, 0), r = 18, size = "L", style = if brood then "goo" else "fire" })
		ctx.fx("Shockwave", { p = pos, r = 28 })
		ctx.fx("Debris", { p = pos + Vector3.new(0, 6, 0), n = 36, c = color, style = if brood then "goo" else "scrap" })
		ctx.fx("Shake", { p = pos, mag = 1.4, r = 140 })
		f:Destroy()
		-- smoking stump
		local w = Instance.new("Model")
		w.Name = "FoundryWreck"
		w.Parent = ctx.folder
		for k = 1, 6 do
			local a = k * 1.05 + ctx.rng:NextNumber(-0.3, 0.3)
			local rr = ctx.rng:NextNumber(3, 9)
			local px, pz = pos.X + math.cos(a) * rr, pos.Z + math.sin(a) * rr
			local gy = if ctx.map.groundY then ctx.map.groundY(px, pz) else pos.Y
			local sz = Vector3.new(ctx.rng:NextNumber(2, 5), ctx.rng:NextNumber(1.5, 4), ctx.rng:NextNumber(2, 5))
			ctx.part(w, sz, CFrame.new(px, gy + sz.Y * 0.2, pz) * CFrame.Angles(ctx.rng:NextNumber(-0.4, 0.4), a, ctx.rng:NextNumber(-0.4, 0.4)), if brood then Color3.fromRGB(54, 36, 62) else Color3.fromRGB(46, 46, 52), if brood then Enum.Material.Mud else Enum.Material.CorrodedMetal, { CanCollide = false, CanQuery = false })
		end
		local anchor = ctx.part(w, Vector3.new(1, 1, 1), cf * CFrame.new(0, 2, 0), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false })
		smoke(anchor, Color3.fromRGB(50, 48, 50), 6, 10)
		-- its drones lose the link and drop (staggered pops)
		local list = table.clone(launched)
		table.clear(launched)
		for k, e in list do
			task.delay(0.15 * k + ctx.rng:NextNumber(0, 0.2), function()
				if e.alive and S and S.Enemies and S.Enemies.damage then
					pcall(S.Enemies.damage, e, 1e5, 6, { kind = "objective", id = "FoundryDown" }, "body")
				end
			end)
		end
		if ctx.alive() then
			entry.steps[1].text = "Blow up both vents (2/2)"
			ctx.completeStep(entry, 1, if brood then "Spore Spire destroyed!" else "Drone Foundry destroyed!")
			ctx.setMarker(entry, nil)
		end
	end
	ctl.destroy = destroyFoundry

	function ctl.popVent(i: number)
		local v = vents[i]
		if not v or v.dead or ctl.isDestroyed then
			return
		end
		v.dead = true
		ctx.fx("Explosion", { p = v.pos, r = 8, size = "M", style = if brood then "goo" else "fire" })
		ctx.fx("Debris", { p = v.pos, n = 14, c = if brood then SPORE else COG_GLOW, style = if brood then "goo" else "scrap" })
		for _, p in v.parts do
			if p.Parent then
				p.Material = Enum.Material.Slate
				p.Color = Color3.fromRGB(28, 26, 30)
			end
		end
		if v.light then
			v.light.Enabled = false
		end
		if v.fx then
			v.fx.Color = ColorSequence.new(Color3.fromRGB(40, 38, 40))
			v.fx.Rate = 10
		end
		local all = true
		for _, o in vents do
			if not o.dead then
				all = false
			end
		end
		if all then
			destroyFoundry()
		else
			ctx.notify(if brood then "Spore pustule burst - one more!" else "Foundry vent blown - one more!", Config.Colors.Gold)
			updateStep()
		end
	end
	active[ctl] = true

	-- fallback: plant a charge (hold 3 s) -> 4 s fuse
	local planted = false
	local pp: ProximityPrompt
	pp = ctx.prompt(chargeSpot, {
		action = "Plant Charge",
		object = if brood then "Spore Spire" else "Drone Foundry",
		hold = 3,
		distance = 10,
		onTrigger = function()
			if planted or ctl.isDestroyed then
				return
			end
			planted = true
			pp.Enabled = false
			ctx.notify("Charge planted - get clear! 4 seconds!", Config.Colors.Danger)
			local bomb = ctx.part(f, Vector3.new(2, 1.2, 1.4), chargeSpot.CFrame * CFrame.new(0, 1.2, 0), Color3.fromRGB(180, 40, 30), Enum.Material.Metal, { CanCollide = false })
			local led = ctx.glow(f, Vector3.new(0.5, 0.3, 0.5), bomb.CFrame * CFrame.new(0, 0.7, 0), Color3.fromRGB(255, 255, 80))
			TweenService:Create(led, TweenInfo.new(0.25, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, true), { Transparency = 1 }):Play()
			ctx.sound("Alarm", pos)
			task.delay(4, function()
				if ctl.isDestroyed or not alive then
					return
				end
				local at = chargeSpot.Position
				ctx.fx("Explosion", { p = at, r = 16, size = "L", style = if brood then "goo" else "fire" })
				if S and S.Enemies and S.Enemies.explode then
					pcall(S.Enemies.explode, at, 16, 6, 500, 5, { kind = "objective", id = "FoundryCharge" })
				end
				destroyFoundry()
			end)
		end,
	})

	local function openHatch()
		for _, d in hatchDoors do
			ctx.tween(d.part, 0.35, { CFrame = d.open })
		end
		task.delay(1.4, function()
			if ctl.isDestroyed then
				return
			end
			for _, d in hatchDoors do
				if d.part.Parent then
					ctx.tween(d.part, 0.5, { CFrame = d.shut })
				end
			end
		end)
	end

	local function launch()
		if not (S and S.Enemies and S.Enemies.spawn) then
			return
		end
		openHatch()
		task.delay(0.4, function()
			if ctl.isDestroyed or not alive or not ctx.alive() then
				return
			end
			local yaw = ctx.rng:NextNumber(0, math.pi * 2)
			local ok, e = pcall(S.Enemies.spawn, droneKind, CFrame.new(hatchPos) * CFrame.Angles(0, yaw, 0), { home = pos })
			if ok and e then
				e.vel = Vector3.new(math.cos(yaw) * 6, 14, math.sin(yaw) * 6) -- pops up out of the hatch
				table.insert(launched, e)
				ctx.fx("Shockwave", { p = hatchPos, r = 5 })
			elseif not ok then
				warn("[SideFoundry] drone spawn failed:", e)
			end
		end)
	end

	-- launch loop
	task.spawn(function()
		local t = 0
		while alive and ctx.alive() and not ctl.isDestroyed do
			task.wait(1)
			local rate = tonumber(workspace:GetAttribute("Feel_FoundryRate")) or RATE
			local near = #ctx.playersNear(pos, NEAR) > 0
			t += 1
			if t >= (if near then rate else rate * FAR_MULT) and liveDrones() < CAP then
				t = 0
				launch()
			end
		end
	end)

	function ctl.stop()
		alive = false
		active[ctl] = nil
	end

	return ctl
end

-- Any explosion close enough to a live vent pops it (same reach rule as the NEST vent).
function SideFoundry.onExplosion(pos: Vector3, radius: number)
	for ctl in active do
		if not ctl.isDestroyed then
			for i, v in ctl.vents or {} do
				if not v.dead and (v.pos - pos).Magnitude <= 6 + math.min(radius, 12) * 0.4 then
					ctl.popVent(i)
				end
			end
		end
	end
end

return SideFoundry
