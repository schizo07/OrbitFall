-- Side objectives: NEST (bug hive / robot fabricator, destroyed by any explosion near it or a planted charge)
-- and SAMPLES (3 glowing pickups). Controllers are created by ObjectiveService.
--   SideObjectives.startNest(ctx, siteName, index) -> controller {entry, stop, isDestroyed}
--   SideObjectives.startSamples(ctx, index) -> controller {entry, stop, getCount}
--   SideObjectives.onExplosion(pos, radius)   (forwarded from S.Objectives.onExplosion)

local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local SideObjectives = {}

local activeNests: { [any]: boolean } = {}

local DARK = Color3.fromRGB(40, 44, 54)
local STEEL = Color3.fromRGB(100, 106, 118)

-- ============================================================ NEST
function SideObjectives.startNest(ctx: any, siteName: string, index: number): any
	local S = ctx.S
	local brood = ctx.faction == "BROOD"
	local cf: CFrame = ctx.map.sites[siteName]
	local pos = cf.Position
	local f = Instance.new("Model")
	f.Name = (if brood then "HiveNest" else "Fabricator") .. index
	f.Parent = ctx.folder

	local id = if index > 1 then "NEST" .. index else "NEST"
	local title = if brood then "Destroy the Hive Nest" else "Destroy the Fabricator"
	local entry = ctx.newEntry({
		id = id,
		title = title,
		main = false,
		steps = { if brood then "Blow up the nest (grenade the vent)" else "Blow up the fabricator (grenade the vent)" },
	})
	local ctl: any = { entry = entry, isDestroyed = false }
	local alive = true
	local ventPos: Vector3
	local chargeSpot: Part

	if brood then
		local mud = Color3.fromRGB(96, 58, 120)
		local flesh = Color3.fromRGB(130, 80, 126)
		ctx.ball(f, 24, cf * CFrame.new(0, 2, 0), mud, Enum.Material.Mud)
		ctx.ball(f, 15, cf * CFrame.new(11, 0, 6), flesh, Enum.Material.Mud)
		ctx.ball(f, 13, cf * CFrame.new(-10, 0, 7), flesh, Enum.Material.Mud)
		ctx.ball(f, 11, cf * CFrame.new(2, 0, -11), mud, Enum.Material.Mud)
		for k = 1, 9 do
			local a = k / 9 * math.pi * 2
			local h = 6 + (k % 3) * 2
			ctx.part(f, Vector3.new(1.4, h, 1.4), cf * CFrame.new(math.cos(a) * 12.5, h / 2 + 1, math.sin(a) * 12.5) * CFrame.Angles(math.sin(a) * 0.5, 0, -math.cos(a) * 0.5), Color3.fromRGB(70, 36, 96), Enum.Material.Slate, { CanCollide = false })
		end
		for k = 1, 4 do
			local a = k * 1.6 + 0.4
			local sac = ctx.ball(f, 4, cf * CFrame.new(math.cos(a) * 14, 1.6, math.sin(a) * 14), Color3.fromRGB(150, 255, 150), Enum.Material.Glass, { Transparency = 0.35, CanCollide = false })
			ctx.glow(f, Vector3.new(1.4, 1.4, 1.4), sac.CFrame, Color3.fromRGB(110, 255, 120), { Shape = Enum.PartType.Ball })
		end
		-- vent on the front slope
		local vcf = cf * CFrame.new(0, 7, -10.5) * CFrame.Angles(math.rad(-50), 0, 0)
		ventPos = vcf.Position
		ctx.cyl(f, 6, 1, vcf, Color3.fromRGB(20, 14, 26), Enum.Material.Slate, { Name = "Vent", CanCollide = false })
		local ring = ctx.cyl(f, 7, 0.5, vcf * CFrame.new(0, 0.3, 0), Color3.fromRGB(110, 255, 120), Enum.Material.Neon, { CanCollide = false })
		ctx.light(ring, Color3.fromRGB(255, 205, 160), 12, 0.7) -- warm, short: a green light turned the whole sand toxic
		local em = Instance.new("ParticleEmitter")
		em.Texture = "rbxasset://textures/particles/smoke_main.dds"
		em.Rate = 8
		em.Lifetime = NumberRange.new(2, 3)
		em.Speed = NumberRange.new(3, 6)
		em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 4) })
		em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		em.Color = ColorSequence.new(Color3.fromRGB(130, 255, 120))
		em.LightEmission = 0.8
		em.Parent = ring
		-- opaque organic lump (the old translucent glass box read as a ghost slab)
		chargeSpot = ctx.ball(f, 3, cf * CFrame.new(-6, 0.9, -13), Color3.fromRGB(84, 50, 104), Enum.Material.Mud, { CanCollide = false, Name = "ChargeSpot" })
		ctx.glow(f, Vector3.new(1.2, 1.2, 1.2), cf * CFrame.new(-6, 2.2, -13), Color3.fromRGB(255, 190, 60), { Shape = Enum.PartType.Ball })
	else
		local fab = SetPieces.spawn(S, "fabricator", SetPieces.groundCF(ctx.map, cf, 8), f, { name = "FabricatorMesh" })
		if fab and fab.parts.Vent then
			-- Blender fabricator: its glowing Vent is the grenade target
			local vent = fab.parts.Vent
			ventPos = SetPieces.pivot(fab, "Vent")
			ctl.reach = 6 -- the vent sits high on the building: explosions near its base count
			ctx.light(vent, Color3.fromRGB(255, 120, 40), 26, 1.6)
			local fume = ctx.part(fab.model, Vector3.new(1, 1, 1), CFrame.new(ventPos + Vector3.new(0, 1.2, 0)), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
			local em = Instance.new("ParticleEmitter")
			em.Texture = "rbxasset://textures/particles/smoke_main.dds"
			em.Rate = 12
			em.Lifetime = NumberRange.new(3, 5)
			em.Speed = NumberRange.new(5, 8)
			em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 8) })
			em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
			em.Color = ColorSequence.new(Color3.fromRGB(70, 68, 68))
			em.EmissionDirection = Enum.NormalId.Top
			em.Parent = fume
			chargeSpot = ctx.part(f, Vector3.new(3, 2, 3), cf * CFrame.new(-6, 1, -14), Color3.fromRGB(255, 190, 60), Enum.Material.Metal, { CanCollide = false, Name = "ChargeSpot" })
			ctx.glow(f, Vector3.new(2.4, 0.3, 2.4), chargeSpot.CFrame * CFrame.new(0, 1.1, 0), Color3.fromRGB(255, 190, 60), { Transparency = 0.3 })
		else
			if fab then
				fab.model:Destroy()
			end
			local rust = Color3.fromRGB(120, 84, 64)
			ctx.part(f, Vector3.new(20, 11, 16), cf * CFrame.new(0, 5.5, 0), STEEL, Enum.Material.Metal)
			ctx.part(f, Vector3.new(20.6, 1.2, 16.6), cf * CFrame.new(0, 11.4, 0), DARK, Enum.Material.DiamondPlate)
			ctx.part(f, Vector3.new(8, 5, 8), cf * CFrame.new(-4, 14.2, 2), rust, Enum.Material.CorrodedMetal)
			for _, x in { -7, 7 } do
				ctx.cyl(f, 3.2, 15, cf * CFrame.new(x, 15, 5), STEEL, Enum.Material.Metal)
				local tip = ctx.cyl(f, 3.4, 0.6, cf * CFrame.new(x, 22.5, 5), Color3.fromRGB(255, 120, 40), Enum.Material.Neon, { CanCollide = false })
				local em = Instance.new("ParticleEmitter")
				em.Texture = "rbxasset://textures/particles/smoke_main.dds"
				em.Rate = 12
				em.Lifetime = NumberRange.new(3, 5)
				em.Speed = NumberRange.new(5, 8)
				em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 8) })
				em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
				em.Color = ColorSequence.new(Color3.fromRGB(70, 68, 68))
				em.EmissionDirection = Enum.NormalId.Top
				em.Parent = tip
			end
			-- conveyor and claw arms
			ctx.part(f, Vector3.new(6, 1.2, 22), cf * CFrame.new(-14, 0.6, -6), DARK, Enum.Material.Metal)
			for k = 0, 2 do
				ctx.part(f, Vector3.new(2, 3, 2.4), cf * CFrame.new(-14, 2.4, -14 + k * 7), Color3.fromRGB(160, 160, 170), Enum.Material.Metal, { CanCollide = false })
			end
			for _, s in { -1, 1 } do
				ctx.part(f, Vector3.new(1, 1, 9), cf * CFrame.new(s * 11.5, 8, -8) * CFrame.Angles(math.rad(-30), 0, 0), STEEL, Enum.Material.Metal, { CanCollide = false })
				ctx.part(f, Vector3.new(3, 0.8, 1), cf * CFrame.new(s * 11.5, 4.2, -12), rust, Enum.Material.Metal, { CanCollide = false })
			end
			ctx.glow(f, Vector3.new(16, 0.7, 0.4), cf * CFrame.new(0, 9, -8.25), Color3.fromRGB(255, 60, 50))
			-- vent grate on the front
			local vcf = cf * CFrame.new(0, 4, -8.2)
			ventPos = vcf.Position
			ctx.part(f, Vector3.new(6, 4, 0.6), vcf, Color3.fromRGB(16, 16, 20), Enum.Material.Metal, { Name = "Vent", CanCollide = false })
			for k = -2, 2 do
				local slat = ctx.glow(f, Vector3.new(5.4, 0.3, 0.3), vcf * CFrame.new(0, k * 0.7, -0.4), Color3.fromRGB(255, 70, 50))
				if k == 0 then
					ctx.light(slat, Color3.fromRGB(255, 70, 50), 26, 1.6)
				end
			end
			chargeSpot = ctx.part(f, Vector3.new(3, 2, 3), cf * CFrame.new(-6, 1, -12), Color3.fromRGB(255, 190, 60), Enum.Material.Metal, { CanCollide = false, Name = "ChargeSpot" })
			ctx.glow(f, Vector3.new(2.4, 0.3, 2.4), chargeSpot.CFrame * CFrame.new(0, 1.1, 0), Color3.fromRGB(255, 190, 60), { Transparency = 0.3 })
		end
	end
	ctl.position = ventPos
	ctx.setMarker(entry, pos)

	local function destroyNest(byExplosion: boolean)
		if ctl.isDestroyed then
			return
		end
		ctl.isDestroyed = true
		activeNests[ctl] = nil
		local color = if brood then Color3.fromRGB(110, 255, 120) else Color3.fromRGB(255, 160, 60)
		ctx.fx("Shockwave", { p = pos, r = 26 })
		ctx.fx("Debris", { p = pos + Vector3.new(0, 4, 0), n = 36, c = color, style = if brood then "goo" else "scrap" })
		ctx.fx("Shake", { p = pos, mag = 1.4, r = 140 })
		f:Destroy()
		-- smoking wreck
		local w = Instance.new("Model")
		w.Name = "NestWreck"
		w.Parent = ctx.folder
		-- scorch painted into the terrain as ragged blobs (a flat black disc floated / clipped on slopes)
		local terrain = workspace.Terrain
		for k = 1, 5 do
			local a = k * 1.25 + ctx.rng:NextNumber(-0.3, 0.3)
			local off = if k == 1 then 0 else ctx.rng:NextNumber(4, 9)
			local sx, sz = pos.X + math.cos(a) * off, pos.Z + math.sin(a) * off
			local gy = if ctx.map.groundY then ctx.map.groundY(sx, sz) else pos.Y
			terrain:FillCylinder(CFrame.new(sx, gy - 1.1, sz), 2.4, if k == 1 then 9 else ctx.rng:NextNumber(4, 7), Enum.Material.Basalt)
		end
		-- torn chunks: wedges half sunk into the ground on their own footprint
		for k = 1, 6 do
			local a = k * 1.05 + ctx.rng:NextNumber(-0.3, 0.3)
			local rr = ctx.rng:NextNumber(3, 8)
			local px, pz = pos.X + math.cos(a) * rr, pos.Z + math.sin(a) * rr
			local gy = if ctx.map.groundY then ctx.map.groundY(px, pz) else pos.Y
			local sz = Vector3.new(ctx.rng:NextNumber(1.5, 4), ctx.rng:NextNumber(1.2, 3.2), ctx.rng:NextNumber(2, 4.5))
			local wp = Instance.new("WedgePart")
			wp.Anchored = true
			wp.CanCollide = false
			wp.CanQuery = false
			wp.CanTouch = false
			wp.Size = sz
			wp.CFrame = CFrame.new(px, gy + sz.Y * 0.2, pz) * CFrame.Angles(ctx.rng:NextNumber(-0.4, 0.4), a + ctx.rng:NextNumber(-1, 1), ctx.rng:NextNumber(-0.4, 0.4))
			wp.Color = if brood then Color3.fromRGB(54, 36, 62) else Color3.fromRGB(46, 46, 52)
			wp.Material = if brood then Enum.Material.Mud else Enum.Material.CorrodedMetal
			wp.Parent = w
		end
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
		smoke.Rate = 6
		smoke.Lifetime = NumberRange.new(3, 5)
		smoke.Speed = NumberRange.new(3, 5)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 10) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		smoke.Color = ColorSequence.new(Color3.fromRGB(50, 48, 50))
		smoke.EmissionDirection = Enum.NormalId.Top
		local anchor = ctx.part(w, Vector3.new(1, 1, 1), cf * CFrame.new(0, 2, 0), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false })
		smoke.Parent = anchor
		if ctx.alive() then
			ctx.completeStep(entry, 1, if brood then "Hive nest destroyed!" else "Fabricator destroyed!")
			ctx.setMarker(entry, nil)
		end
	end
	ctl.destroy = destroyNest
	activeNests[ctl] = true

	-- fallback: plant a charge (hold 3 s) -> 4 s fuse
	local planted = false
	local pp: ProximityPrompt
	pp = ctx.prompt(chargeSpot, {
		action = "Plant Charge",
		object = if brood then "Hive Nest" else "Fabricator",
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
				ctx.fx("Explosion", { p = ventPos, r = 16, size = "L", style = if brood then "goo" else "fire" })
				if S and S.Enemies and S.Enemies.explode then
					pcall(S.Enemies.explode, ventPos, 16, 6, 500, 5, { kind = "objective", id = "NestCharge" })
				end
				destroyNest(true)
			end)
		end,
	})

	-- the nest spawns defenders while players are around
	task.spawn(function()
		local t = 0
		while alive and ctx.alive() and not ctl.isDestroyed do
			task.wait(1)
			if #ctx.playersNear(pos, 85) > 0 then
				t += 1
				if t >= 24 then
					t = 0
					ctx.wave(pos, 4)
				end
			end
		end
	end)

	function ctl.stop()
		alive = false
		activeNests[ctl] = nil
	end

	return ctl
end

function SideObjectives.onExplosion(pos: Vector3, radius: number)
	for ctl in activeNests do
		if not ctl.isDestroyed and ctl.position then
			local d = (ctl.position - pos).Magnitude
			if d <= 8 + math.min(radius, 12) * 0.4 + (ctl.reach or 0) then
				ctl.destroy(true)
			end
		end
	end
end

-- ============================================================ SAMPLES
function SideObjectives.startSamples(ctx: any, index: number): any
	local f = Instance.new("Model")
	f.Name = "Samples"
	f.Parent = ctx.folder
	local TOTAL = 3
	local entry = ctx.newEntry({ id = if index > 1 then "SAMPLES" .. index else "SAMPLES", title = "Sample Run", main = false, steps = { "Collect the glowing samples (0/3)" } })
	local ctl: any = { entry = entry }
	local count = 0
	local remaining: { [number]: Vector3 } = {}
	local alive = true

	local function updateMarker()
		for i = 1, TOTAL do
			if remaining[i] then
				ctx.setMarker(entry, remaining[i])
				return
			end
		end
		ctx.setMarker(entry, nil)
	end

	for i = 1, TOTAL do
		local scf: CFrame? = ctx.map.sites["samples" .. i]
		if scf then
			local b = scf :: CFrame
			remaining[i] = b.Position
			local m = Instance.new("Model")
			m.Name = "Sample" .. i
			m.Parent = f
			local col = if i == 1 then Color3.fromRGB(90, 255, 220) elseif i == 2 then Color3.fromRGB(255, 200, 80) else Color3.fromRGB(190, 120, 255)
			local pod = SetPieces.spawn(ctx.S, "sample_pod", SetPieces.groundCF(ctx.map, b, 0), m, { name = "SamplePod", scale = 1.7 })
			local base: BasePart
			if pod and pod.parts.Casing and pod.parts.Glow then
				base = pod.parts.Casing
				local glowPart = pod.parts.Glow
				glowPart.Color = col
				ctx.light(glowPart, Color3.fromRGB(255, 225, 190), 12, 0.8) -- neutral: coloured pod lights tinted the sand
				TweenService:Create(glowPart, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.5 }):Play()
			else
				if pod then
					pod.model:Destroy()
				end
				ctx.cyl(m, 3.6, 0.8, b * CFrame.new(0, 0.4, 0), DARK, Enum.Material.Metal)
				ctx.cyl(m, 2.6, 3.2, b * CFrame.new(0, 2.4, 0), Color3.fromRGB(180, 230, 255), Enum.Material.Glass, { Transparency = 0.6, CanCollide = false })
				local orb = ctx.ball(m, 1.8, b * CFrame.new(0, 2.6, 0), col, Enum.Material.Neon, { CanCollide = false })
				ctx.light(orb, Color3.fromRGB(255, 225, 190), 12, 0.8)
				TweenService:Create(orb, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { CFrame = orb.CFrame * CFrame.new(0, 0.8, 0) }):Play()
				base = ctx.part(m, Vector3.new(3, 4, 3), b * CFrame.new(0, 2, 0), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false })
			end
			local hl = Instance.new("Highlight")
			hl.FillTransparency = 1
			hl.OutlineColor = col
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.Parent = m
			ctx.prompt(base, {
				action = "Collect",
				object = "Sample",
				hold = 0.6,
				distance = 10,
				onTrigger = function()
					if not remaining[i] then
						return
					end
					remaining[i] = nil
					count += 1
					m:Destroy()
					ctx.intensity("SAMPLE") -- the pickup makes noise: the next breach comes sooner
					local st = entry.steps[1]
					st.text = string.format("Collect the glowing samples (%d/%d)", count, TOTAL)
					st.progress = count / TOTAL
					ctx.sound("UIClick", b.Position)
					if count >= TOTAL then
						st.progress = nil
						ctx.completeStep(entry, 1, "All samples collected!")
						ctx.setMarker(entry, nil)
					else
						ctx.notify(string.format("Sample collected (%d/%d)", count, TOTAL), Config.Colors.Gold)
						updateMarker()
						ctx.changed(true)
					end
				end,
			})
		end
	end
	updateMarker()

	function ctl.getCount(): number
		return count
	end
	function ctl.stop()
		alive = false
	end
	return ctl
end

return SideObjectives
