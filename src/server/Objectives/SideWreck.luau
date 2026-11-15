-- Side objective WRECK: a crashed Skiff-class hull (two broken halves, a scorched skid trench, small fires) on a spare site.
-- Interact with the sparking data core to start a download; it progresses only while a living trooper is within RADIUS of
-- the core. Waves come in from the wreck's edges at fixed progress marks. Nothing is carried.
--   SideWreck.start(ctx, siteCF, index) -> controller { entry, stop, done }
-- Studio A/B "WRECK DOWNLOAD" (client/Variants): workspace attribute Feel_WreckDownload = nil (A 45 s, 3 waves) | "B" (30 s, 2
-- waves) | "C" (60 s, 4 waves); read when the download starts. DebugFast shortens the download to 6 s.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local SideWreck = {}

local RADIUS = 12 -- studs (compass / marker metres are studs)
local STALL_AFTER = 10 -- seconds with nobody near before the download reports as stalled
local WAVE_R_MIN, WAVE_R_MAX, WAVE_MIN_DIST = 24, 42, 16

local PRESETS: { [string]: { dur: number, waves: number } } = {
	A = { dur = 45, waves = 3 },
	B = { dur = 30, waves = 2 },
	C = { dur = 60, waves = 4 },
}

local HULL = Color3.fromRGB(188, 194, 206)
local HULL_DARK = Color3.fromRGB(96, 102, 116)
local STRIPE = Color3.fromRGB(255, 138, 43)
local SCORCH = Color3.fromRGB(46, 42, 44)
local HOT = Color3.fromRGB(255, 112, 40)
local DATA = Color3.fromRGB(80, 220, 255)
local DONE = Color3.fromRGB(70, 255, 120)
local STALL = Color3.fromRGB(255, 190, 60)

local function preset(): { dur: number, waves: number }
	local v = workspace:GetAttribute("Feel_WreckDownload")
	return PRESETS[if type(v) == "string" then v else "A"] or PRESETS.A
end

-- horizontal cylinder along the local Z axis (Roblox cylinders run along X)
local function zcyl(ctx: any, parent: Instance, diameter: number, length: number, cf: CFrame, color: Color3, mat: Enum.Material?, opts: { [string]: any }?): Part
	local p = ctx.part(parent, Vector3.new(length, diameter, diameter), cf * CFrame.Angles(0, math.pi / 2, 0), color, mat, opts)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function wedge(parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material): WedgePart
	local w = Instance.new("WedgePart")
	w.Anchored = true
	w.Size = size
	w.CFrame = cf
	w.Color = color
	w.Material = mat
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Parent = parent
	return w
end

local function fireAt(ctx: any, parent: Instance, pos: Vector3, scale: number)
	local anchor = ctx.part(parent, Vector3.new(1, 1, 1), CFrame.new(pos), SCORCH, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local fire = Instance.new("ParticleEmitter")
	fire.Texture = "rbxasset://textures/particles/fire_main.dds"
	fire.Rate = 14
	fire.Lifetime = NumberRange.new(0.5, 0.9)
	fire.Speed = NumberRange.new(3, 6)
	fire.SpreadAngle = Vector2.new(14, 14)
	fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6 * scale), NumberSequenceKeypoint.new(1, 0.2) })
	fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 200, 90), Color3.fromRGB(255, 90, 30))
	fire.LightEmission = 0.9
	fire.EmissionDirection = Enum.NormalId.Top
	fire.Parent = anchor
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 4
	smoke.Lifetime = NumberRange.new(3, 5)
	smoke.Speed = NumberRange.new(4, 7)
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2 * scale), NumberSequenceKeypoint.new(1, 9 * scale) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	smoke.Color = ColorSequence.new(Color3.fromRGB(56, 52, 54))
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.Parent = anchor
	ctx.light(anchor, Color3.fromRGB(255, 150, 70), 10 * scale, 1.2)
end

function SideWreck.start(ctx: any, siteCF: CFrame, index: number): any
	local S = ctx.S
	local map = ctx.map
	local f = Instance.new("Model")
	f.Name = "CrashedSkiff" .. index
	f.Parent = ctx.folder

	local yaw = ctx.rng:NextNumber(0, math.pi * 2)
	local w = SetPieces.groundCF(map, CFrame.new(siteCF.Position) * CFrame.Angles(0, yaw, 0), 12)
	local function gy(x: number, z: number, fallback: number): number
		return if map.groundY then map.groundY(x, z) else fallback
	end

	local entry = ctx.newEntry({
		id = if index > 1 then "WRECK" .. index else "WRECK",
		title = "Crashed Skiff",
		main = false,
		steps = { "Start the data download at the wreck", "Hold the wreck while the data downloads" },
	})
	local ctl: any = { entry = entry, done = false }
	local alive = true

	-- ------------------------------------------------ skid trench (scorched terrain behind the rear half)
	local terrain = workspace.Terrain
	for k = 0, 6 do
		local lp = w:PointToWorldSpace(Vector3.new(ctx.rng:NextNumber(-1.5, 1.5), 0, 20 + k * 6))
		local r = 5.5 - k * 0.45
		terrain:FillCylinder(CFrame.new(lp.X, gy(lp.X, lp.Z, lp.Y) - 1.1, lp.Z), 2.4, r, Enum.Material.Basalt)
	end
	for k = 1, 4 do
		local a = k * 1.6 + ctx.rng:NextNumber(-0.3, 0.3)
		local lp = w:PointToWorldSpace(Vector3.new(math.cos(a) * 7, 0, math.sin(a) * 7))
		terrain:FillCylinder(CFrame.new(lp.X, gy(lp.X, lp.Z, lp.Y) - 1.1, lp.Z), 2.4, ctx.rng:NextNumber(4, 6), Enum.Material.Basalt)
	end

	-- ------------------------------------------------ rear half: engine section, rolled over and dug in
	local rear = w * CFrame.new(0, 3, 12) * CFrame.Angles(math.rad(4), 0, math.rad(9))
	ctx.part(f, Vector3.new(12, 8, 14), rear, HULL, Enum.Material.SmoothPlastic)
	ctx.part(f, Vector3.new(12.2, 1.2, 14.2), rear * CFrame.new(0, 1.2, 0), STRIPE, Enum.Material.SmoothPlastic, { CanCollide = false })
	ctx.part(f, Vector3.new(10, 1, 12), rear * CFrame.new(0, 4.4, 0.5), HULL_DARK, Enum.Material.DiamondPlate)
	for _, x in { -6.8, 6.8 } do
		local eng = zcyl(ctx, f, 5, 11, rear * CFrame.new(x, -1, 3), HULL_DARK, Enum.Material.Metal)
		zcyl(ctx, f, 4, 0.6, eng.CFrame * CFrame.Angles(0, -math.pi / 2, 0) * CFrame.new(0, 0, 5.6), SCORCH, Enum.Material.Slate, { CanCollide = false })
	end
	-- one fin snapped and leaning, one standing
	ctx.part(f, Vector3.new(1, 6, 5), rear * CFrame.new(-3, 7, 4), HULL, Enum.Material.SmoothPlastic)
	ctx.part(f, Vector3.new(1, 5, 4.5), rear * CFrame.new(3.5, 6, 5) * CFrame.Angles(0, 0, math.rad(-38)), HULL, Enum.Material.SmoothPlastic)
	-- torn front face: dark plate with glowing hot edges
	ctx.part(f, Vector3.new(11.4, 7.4, 0.6), rear * CFrame.new(0, 0, -7.1), SCORCH, Enum.Material.CorrodedMetal)
	ctx.glow(f, Vector3.new(11.6, 0.35, 0.35), rear * CFrame.new(0, 3.7, -7.3), HOT)
	ctx.glow(f, Vector3.new(0.35, 7.4, 0.35), rear * CFrame.new(-5.8, 0, -7.3), HOT)

	-- ------------------------------------------------ front half: nose and cockpit, twisted off the line, nose in the dirt
	local front = w * CFrame.new(-3, 2.4, -14) * CFrame.Angles(math.rad(-10), math.rad(28), math.rad(-6))
	ctx.part(f, Vector3.new(10, 7, 11), front, HULL, Enum.Material.SmoothPlastic)
	ctx.part(f, Vector3.new(10.2, 1.2, 11.2), front * CFrame.new(0, 1, 0), STRIPE, Enum.Material.SmoothPlastic, { CanCollide = false })
	-- WedgePart: tall face at +Z, slope down toward -Z (the nose points -Z)
	wedge(f, Vector3.new(10, 7, 8), front * CFrame.new(0, 0, -9.5), HULL, Enum.Material.SmoothPlastic)
	local canopy = wedge(f, Vector3.new(7, 3, 6), front * CFrame.new(0, 5, -2), Color3.fromRGB(70, 150, 200), Enum.Material.Glass)
	canopy.Transparency = 0.25
	canopy.CanCollide = false
	ctx.part(f, Vector3.new(9.4, 6.4, 0.6), front * CFrame.new(0, 0, 5.8), SCORCH, Enum.Material.CorrodedMetal)
	ctx.glow(f, Vector3.new(9.6, 0.35, 0.35), front * CFrame.new(0, -3, 6), HOT)

	-- ------------------------------------------------ debris
	for k = 1, 9 do
		local a = ctx.rng:NextNumber(0, math.pi * 2)
		local r = ctx.rng:NextNumber(9, 20)
		local lp = w:PointToWorldSpace(Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
		local sz = Vector3.new(ctx.rng:NextNumber(1.5, 3.5), ctx.rng:NextNumber(0.6, 1.6), ctx.rng:NextNumber(2, 4))
		local d = wedge(f, sz, CFrame.new(lp.X, gy(lp.X, lp.Z, lp.Y) + sz.Y * 0.25, lp.Z) * CFrame.Angles(ctx.rng:NextNumber(-0.4, 0.4), a, ctx.rng:NextNumber(-0.4, 0.4)), if k % 3 == 0 then STRIPE else HULL_DARK, Enum.Material.Metal)
		d.CanCollide = false
		d.CanQuery = false
	end

	-- ------------------------------------------------ fires + smoke column
	fireAt(ctx, f, (rear * CFrame.new(6.8, 1.5, 9)).Position, 1)
	fireAt(ctx, f, (rear * CFrame.new(-2, 4.8, -2)).Position, 0.8)
	fireAt(ctx, f, (front * CFrame.new(2, 3.6, 2)).Position, 0.8)
	local trail1 = w:PointToWorldSpace(Vector3.new(1, 0, 30))
	fireAt(ctx, f, Vector3.new(trail1.X, gy(trail1.X, trail1.Z, trail1.Y) + 0.5, trail1.Z), 0.6)
	do
		local anchor = ctx.part(f, Vector3.new(1, 1, 1), rear * CFrame.new(0, 5, 0), SCORCH, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
		local col = Instance.new("ParticleEmitter")
		col.Texture = "rbxasset://textures/particles/smoke_main.dds"
		col.Rate = 5
		col.Lifetime = NumberRange.new(6, 9)
		col.Speed = NumberRange.new(6, 9)
		col.SpreadAngle = Vector2.new(8, 8)
		col.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 16) })
		col.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		col.Color = ColorSequence.new(Color3.fromRGB(48, 46, 48))
		col.EmissionDirection = Enum.NormalId.Top
		col.Parent = anchor
	end

	-- ------------------------------------------------ data core: thrown clear into the gap between the halves
	local coreBase = w * CFrame.new(5, 0, -1)
	local coreGround = gy(coreBase.X, coreBase.Z, coreBase.Y)
	local coreCF = CFrame.new(coreBase.X, coreGround, coreBase.Z) * coreBase.Rotation * CFrame.Angles(0, math.rad(20), math.rad(6))
	local pedestal = ctx.part(f, Vector3.new(3.2, 2.6, 3.2), coreCF * CFrame.new(0, 1, 0), HULL_DARK, Enum.Material.DiamondPlate, { Name = "DataCore" })
	ctx.part(f, Vector3.new(3.4, 0.4, 3.4), coreCF * CFrame.new(0, 2.4, 0), STRIPE, Enum.Material.Metal, { CanCollide = false })
	local core = ctx.glow(f, Vector3.new(1.8, 1.8, 1.8), coreCF * CFrame.new(0, 3.6, 0) * CFrame.Angles(math.rad(45), math.rad(45), 0), DATA)
	local coreLight = ctx.light(core, DATA, 16, 1.4)
	local corePulse = SetPieces.pulse(core, "Transparency", 0, 0.45, 0.6)
	local corePos = core.Position
	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparks.Rate = 0
	sparks.Lifetime = NumberRange.new(0.3, 0.7)
	sparks.Speed = NumberRange.new(8, 16)
	sparks.SpreadAngle = Vector2.new(70, 70)
	sparks.Acceleration = Vector3.new(0, -40, 0)
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 230, 140))
	sparks.LightEmission = 1
	sparks.Parent = core

	-- progress ring around the pedestal (segments light as the download runs)
	local SEG = 16
	local ringSegs: { Part } = {}
	for i = 1, SEG do
		local a = (i - 0.5) / SEG * math.pi * 2
		local seg = ctx.glow(f, Vector3.new(1.1, 0.25, 0.5), CFrame.new(corePos.X, coreGround + 0.35, corePos.Z) * CFrame.Angles(0, -a, 0) * CFrame.new(0, 0, -3.2), DATA, { Transparency = 0.8 })
		ringSegs[i] = seg
	end
	-- the hold zone: dashed ground ring at RADIUS
	local ZSEG = 28
	local zoneSegs: { Part } = {}
	for i = 1, ZSEG do
		local a = (i - 0.5) / ZSEG * math.pi * 2
		local x, z = corePos.X + math.sin(a) * RADIUS, corePos.Z + math.cos(a) * RADIUS
		local seg = ctx.glow(f, Vector3.new(0.35, 0.2, 1.4), CFrame.new(x, gy(x, z, coreGround) + 0.2, z) * CFrame.Angles(0, a + math.pi / 2, 0), DATA, { Transparency = 1 })
		zoneSegs[i] = seg
	end

	local function setRing(p: number, color: Color3)
		local lit = math.floor(p * SEG + 1e-6)
		for i, seg in ringSegs do
			seg.Color = color
			seg.Transparency = if i <= lit then 0 else 0.8
		end
	end
	local function setZone(transp: number, color: Color3)
		for _, seg in zoneSegs do
			seg.Transparency = transp
			seg.Color = color
		end
	end

	ctx.setMarker(entry, corePos)

	-- idle sparks
	task.spawn(function()
		while alive and ctx.alive() and not ctl.done do
			task.wait(ctx.rng:NextNumber(0.8, 2.6))
			if not alive or ctl.done then
				break
			end
			sparks:Emit(ctx.rng:NextInteger(6, 14))
		end
	end)

	local function sendWave(n: number)
		ctx.notify(if n == 1 then "Hostiles inbound on the wreck - hold the core!" else "More hostiles closing on the wreck!", Config.Colors.Danger)
		local d = S and S.Director
		if not (d and d.spawnWave) then
			return
		end
		local players = math.max(1, #ctx.players())
		local budget = (5 + 1.5 * (ctx.difficulty or 1)) * (0.75 + 0.25 * players)
		local ok, err = pcall(d.spawnWave, corePos, math.floor(budget + 0.5), { rMin = WAVE_R_MIN, rMax = WAVE_R_MAX, minDist = WAVE_MIN_DIST })
		if not ok then
			warn("[SideWreck] spawnWave failed:", err)
		end
	end

	local function finish()
		ctl.done = true
		corePulse:Cancel()
		core.Transparency = 0
		core.Color = DONE
		coreLight.Color = DONE
		coreLight.Brightness = 2
		setRing(1, DONE)
		setZone(1, DONE)
		local st = entry.steps[2]
		st.progress = nil
		st.text = "Hold the wreck while the data downloads"
		ctx.sound("ObjectiveDone", corePos)
		ctx.completeStep(entry, 2, "Command: flight data received. Good work, troopers.")
		ctx.setMarker(entry, nil)
	end

	local started = false
	local pp: ProximityPrompt
	pp = ctx.prompt(pedestal, {
		action = "Download Data",
		object = "Ship Data Core",
		hold = 1.5,
		distance = 10,
		onTrigger = function()
			if started or ctl.done then
				return
			end
			started = true
			pp.Enabled = false
			local cfgP = preset()
			local dur = if workspace:GetAttribute("DebugFast") then 6 else cfgP.dur
			local marks: { number } = {}
			for i = 1, cfgP.waves do
				marks[i] = (i - 1) / cfgP.waves -- 0, 1/3, 2/3 for three waves
			end
			ctx.completeStep(entry, 1, string.format("Download started - stay within %d m of the core!", RADIUS))
			ctx.intensity("DEFEND_START")
			ctx.sound("Generator", corePos)
			corePulse:Cancel()
			corePulse = SetPieces.pulse(core, "Transparency", 0, 0.5, 0.25)
			setZone(0.35, DATA)
			local st = entry.steps[2]
			st.progress = 0
			ctx.changed(true)

			task.spawn(function()
				local t, away = 0, 0
				local nextWave = 1
				local stalled = false
				local soundT = 0
				while alive and ctx.alive() and not ctl.done do
					local dt = 0.2
					task.wait(dt)
					if not alive or not ctx.alive() then
						return
					end
					local near = #ctx.playersNear(corePos, RADIUS) > 0
					if near then
						away = 0
						t = math.min(dur, t + dt)
					else
						away += dt
					end
					local p = t / dur
					while nextWave <= #marks and p >= marks[nextWave] do
						sendWave(nextWave)
						nextWave += 1
					end
					local nowStalled = away > STALL_AFTER
					if nowStalled ~= stalled then
						stalled = nowStalled
						if stalled then
							ctx.notify("Wreck download stalled - get back to the core!", STALL)
							corePulse:Cancel()
							core.Transparency = 0.3
						else
							ctx.notify("Download resumed.", Config.Colors.Friendly)
							corePulse = SetPieces.pulse(core, "Transparency", 0, 0.5, 0.25)
						end
					end
					local col = if stalled then STALL else DATA
					core.Color = col
					coreLight.Color = col
					setRing(p, col)
					setZone(if near then 0.35 else 0.1, col)
					st.progress = p
					st.text = if stalled
						then string.format("Download stalled at %d %% - return to the core", math.floor(p * 100))
						elseif near then string.format("Hold the wreck while the data downloads (%d %%)", math.floor(p * 100))
						else "Stay near the core - download paused"
					ctx.changed()
					if near then
						soundT += dt
						if soundT >= 3 then
							soundT = 0
							sparks:Emit(8)
						end
					end
					if t >= dur then
						finish()
						return
					end
				end
			end)
		end,
	})

	function ctl.stop()
		alive = false
		pcall(function()
			corePulse:Cancel()
		end)
	end

	return ctl
end

return SideWreck
