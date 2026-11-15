-- Side objective JAMMER: a jammer building (COG) / spore jammer mound (BROOD) on a spare site blocks call-ins inside its
-- radius (S.Jammers). Four stages:
--   1. hack the override console (hold 5 s; taking damage while holding breaks the hack)
--   2. the hack frees a one-off Sunbreaker charge: a pod drops on a marked spot beside the jammer (walk to it)
--   3. arm the charge (hold 3 s)
--   4. run: fuse countdown with an alarm, then a blast (S.Explosions.blast, radius 18) that wrecks the jammer and anyone near it
--   SideJammer.start(ctx, siteCF, index) -> controller { entry, stop, isDestroyed }
-- Studio: QuickStartSides=JAMMER. A/B group "JAMMER" (Variants): attribute Feel_Jammer = nil (A) | "B" | "C".

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local RunService = game:GetService("RunService")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)
local Jammers = require(script.Parent.Parent.Jammers)

local SideJammer = {}

local IS_STUDIO = RunService:IsStudio()

local HACK_HOLD = 5
local ARM_HOLD = 3
local BLAST_RADIUS = 18
local POD_FALL = 2.2

-- A 60 m / 10 s fuse, B 45 m / 8 s, C 80 m / 12 s
local TUNES = {
	A = { radius = 60, fuse = 10 },
	B = { radius = 45, fuse = 8 },
	C = { radius = 80, fuse = 12 },
}

local function tune(): { radius: number, fuse: number }
	local v = if IS_STUDIO then workspace:GetAttribute("Feel_Jammer") else nil
	return TUNES[if type(v) == "string" then v else "A"] or TUNES.A
end

local DARK = Color3.fromRGB(40, 44, 54)
local STEEL = Color3.fromRGB(100, 106, 118)
local RED = Color3.fromRGB(255, 60, 50)
local ORANGE = Color3.fromRGB(255, 150, 40)

function SideJammer.start(ctx: any, siteCF: CFrame, index: number): any
	local S = ctx.S
	local brood = ctx.faction == "BROOD"
	local base: CFrame = SetPieces.groundCF(ctx.map, siteCF, 10)
	local pos = base.Position
	local cfg = tune()

	local function groundAt(x: number, z: number): number
		return if ctx.map.groundY then ctx.map.groundY(x, z) else pos.Y
	end
	-- point on the ground at a local offset of the site
	local function spotAt(dx: number, dz: number): Vector3
		local w = base:PointToWorldSpace(Vector3.new(dx, 0, dz))
		return Vector3.new(w.X, groundAt(w.X, w.Z), w.Z)
	end

	local f = Instance.new("Model")
	f.Name = (if brood then "SporeJammer" else "UplinkJammer") .. index
	f.Parent = ctx.folder

	local entry = ctx.newEntry({
		id = if index > 1 then "JAMMER" .. index else "JAMMER",
		title = if brood then "Silence the Spore Jammer" else "Destroy the Uplink Jammer",
		main = false,
		steps = {
			if brood then "Override the spore node (hold 5 s)" else "Hack the override console (hold 5 s)",
			"Reach the Sunbreaker charge pod",
			"Arm the Sunbreaker charge (hold 3 s)",
			"Get clear! Detonation soon",
		},
	})
	local ctl: any = { entry = entry, isDestroyed = false }
	local alive = true
	local stage = 1
	local jamId = "SITE" .. index
	local jamPos = pos + Vector3.new(0, 6, 0)

	-- ------------------------------------------------------------ the jammer
	if brood then
		local mud = Color3.fromRGB(96, 58, 120)
		local flesh = Color3.fromRGB(130, 80, 126)
		ctx.ball(f, 18, base * CFrame.new(0, 3, 0), mud, Enum.Material.Mud)
		ctx.ball(f, 11, base * CFrame.new(6, 0, 4), flesh, Enum.Material.Mud)
		ctx.ball(f, 9, base * CFrame.new(-6, 0, -3), flesh, Enum.Material.Mud)
		for k = 1, 5 do
			local a = k / 5 * math.pi * 2
			local h = 9 + (k % 2) * 4
			ctx.part(f, Vector3.new(1.6, h, 1.6), base * CFrame.new(math.cos(a) * 6, h / 2 + 6, math.sin(a) * 6) * CFrame.Angles(math.sin(a) * 0.35, 0, -math.cos(a) * 0.35), Color3.fromRGB(70, 36, 96), Enum.Material.Slate, { CanCollide = false })
		end
		local core = ctx.ball(f, 5, base * CFrame.new(0, 14, 0), RED, Enum.Material.Neon, { CanCollide = false })
		ctx.light(core, Color3.fromRGB(255, 110, 90), 30, 1.8)
		ctx.cyl(f, 2, 10, base * CFrame.new(0, 12, 0), Color3.fromRGB(70, 36, 96), Enum.Material.Slate, { CanCollide = false })
	else
		ctx.part(f, Vector3.new(24, 1, 24), base * CFrame.new(0, 0.5, 0), DARK, Enum.Material.DiamondPlate)
		ctx.part(f, Vector3.new(9, 6, 9), base * CFrame.new(0, 4, 0), STEEL, Enum.Material.Metal)
		ctx.cyl(f, 4, 22, base * CFrame.new(0, 18, 0), STEEL, Enum.Material.Metal)
		for _, y in { 10, 17, 24 } do
			ctx.cyl(f, 5.6, 1, base * CFrame.new(0, y, 0), DARK, Enum.Material.Metal, { CanCollide = false })
		end
		for _, s in { -1, 1 } do
			ctx.cyl(f, 8, 0.8, base * CFrame.new(s * 5.5, 22, 0) * CFrame.Angles(0, 0, s * math.rad(35)), STEEL, Enum.Material.Metal, { CanCollide = false })
		end
		ctx.glow(f, Vector3.new(9.4, 0.6, 9.4), base * CFrame.new(0, 7.2, 0), RED, { Transparency = 0.2 })
		local core = ctx.ball(f, 4, base * CFrame.new(0, 31, 0), RED, Enum.Material.Neon, { CanCollide = false })
		ctx.light(core, Color3.fromRGB(255, 110, 90), 30, 1.8)
		for _, c in { { -9, -9 }, { 9, -9 }, { -9, 9 }, { 9, 9 } } do
			ctx.part(f, Vector3.new(3, 2, 3), base * CFrame.new(c[1], 2, c[2]), DARK, Enum.Material.Metal)
			ctx.glow(f, Vector3.new(2.6, 0.3, 2.6), base * CFrame.new(c[1], 3.1, c[2]), ORANGE)
		end
	end
	-- red column readable from far away (the objective beacon is warm / white; this one says "jammer")
	local beam = ctx.glow(f, Vector3.new(0.9, 80, 0.9), base * CFrame.new(0, 40, 0), RED, { Transparency = 0.55 })
	SetPieces.pulse(beam, "Transparency", 0.55, 0.85, 0.9)
	ctx.setMarker(entry, pos)

	Jammers.add(jamId, function()
		return if ctl.isDestroyed or not alive then nil else jamPos
	end, cfg.radius)

	-- ------------------------------------------------------------ stage 1: the override console
	local consolePos = spotAt(11, 10)
	local consoleBody: Part
	local screen: Part
	if brood then
		consoleBody = ctx.ball(f, 3.6, CFrame.new(consolePos + Vector3.new(0, 1.2, 0)), Color3.fromRGB(84, 50, 104), Enum.Material.Mud, { Name = "Console" })
		screen = ctx.ball(f, 1.6, CFrame.new(consolePos + Vector3.new(0, 3.2, 0)), RED, Enum.Material.Neon, { CanCollide = false })
	else
		consoleBody = ctx.part(f, Vector3.new(4, 3.4, 2.4), CFrame.new(consolePos + Vector3.new(0, 1.7, 0)) * base.Rotation, DARK, Enum.Material.Metal, { Name = "Console" })
		screen = ctx.glow(f, Vector3.new(3.2, 1.6, 0.2), consoleBody.CFrame * CFrame.new(0, 0.5, -1.25), RED)
	end
	ctx.light(screen, Color3.fromRGB(255, 120, 100), 14, 1)

	local holds: { [Player]: { t0: number, hurt: boolean, conn: RBXScriptConnection? } } = {}
	local hackPrompt: ProximityPrompt

	local function hackProgress()
		local best = 0
		for _, h in holds do
			best = math.max(best, (os.clock() - h.t0) / HACK_HOLD)
		end
		return best
	end

	local function endHold(player: Player)
		local h = holds[player]
		if not h then
			return
		end
		if h.conn then
			h.conn:Disconnect()
		end
		holds[player] = nil
		if stage == 1 and entry.steps[1] and not entry.steps[1].done then
			local p = hackProgress()
			entry.steps[1].progress = if p > 0 then math.min(p, 0.99) else nil
			ctx.changed()
		end
	end

	local function breakHack(player: Player)
		endHold(player)
		if S.State then
			S.State.notify(player, "Hack interrupted - you took damage", Config.Colors.Danger)
		end
		-- toggling the prompt cancels the hold on the client
		hackPrompt.Enabled = false
		task.delay(0.4, function()
			if alive and stage == 1 then
				hackPrompt.Enabled = true
			end
		end)
	end

	-- stage 2 + on
	local chargeBody: Part? = nil
	local armPrompt: ProximityPrompt? = nil
	local chargePos: Vector3 = spotAt(-10, 9)

	local function destroyJammer()
		if ctl.isDestroyed then
			return
		end
		ctl.isDestroyed = true
		Jammers.remove(jamId)
		local color = if brood then Color3.fromRGB(150, 255, 130) else Color3.fromRGB(255, 160, 60)
		ctx.fx("Shockwave", { p = pos, r = 34 })
		ctx.fx("Debris", { p = pos + Vector3.new(0, 5, 0), n = 48, c = color, style = if brood then "goo" else "scrap" })
		ctx.fx("Shake", { p = pos, mag = 1.8, r = 160 })
		f:Destroy()
		-- smoking wreck: torn chunks sunk into the ground
		local w = Instance.new("Model")
		w.Name = "JammerWreck"
		w.Parent = ctx.folder
		for k = 1, 7 do
			local a = k * 0.9 + ctx.rng:NextNumber(-0.3, 0.3)
			local rr = ctx.rng:NextNumber(2, 8)
			local px, pz = pos.X + math.cos(a) * rr, pos.Z + math.sin(a) * rr
			local sz = Vector3.new(ctx.rng:NextNumber(1.5, 4), ctx.rng:NextNumber(1.2, 3.2), ctx.rng:NextNumber(2, 4.5))
			local wp = Instance.new("WedgePart")
			wp.Anchored = true
			wp.CanCollide = false
			wp.CanQuery = false
			wp.CanTouch = false
			wp.Size = sz
			wp.CFrame = CFrame.new(px, groundAt(px, pz) + sz.Y * 0.2, pz) * CFrame.Angles(ctx.rng:NextNumber(-0.4, 0.4), a, ctx.rng:NextNumber(-0.4, 0.4))
			wp.Color = if brood then Color3.fromRGB(54, 36, 62) else Color3.fromRGB(46, 46, 52)
			wp.Material = if brood then Enum.Material.Mud else Enum.Material.CorrodedMetal
			wp.Parent = w
		end
		local anchor = ctx.part(w, Vector3.new(1, 1, 1), CFrame.new(pos + Vector3.new(0, 2, 0)), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
		smoke.Rate = 6
		smoke.Lifetime = NumberRange.new(3, 5)
		smoke.Speed = NumberRange.new(3, 5)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 10) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		smoke.Color = ColorSequence.new(Color3.fromRGB(50, 48, 50))
		smoke.EmissionDirection = Enum.NormalId.Top
		smoke.Parent = anchor
	end

	local function detonate()
		local at = chargePos + Vector3.new(0, 1.5, 0)
		local cm = if chargeBody then chargeBody.Parent else nil
		if cm then
			cm:Destroy()
		end
		-- the shared explosion entry point: enemies in range take the damage, troopers are knocked about
		local ex = S.Explosions
		if ex and ex.blast then
			pcall(ex.blast, at, {
				radius = BLAST_RADIUS,
				core = 7,
				damage = 900,
				ap = 6,
				size = "XL",
				style = "fire",
				knock = 90,
				shake = 1.6,
				shakeRadius = 170,
			}, { kind = "objective", id = "SunbreakerCharge" })
		else
			ctx.fx("Explosion", { p = at, r = BLAST_RADIUS, size = "L", style = "fire" })
			if S.Enemies and S.Enemies.explode then
				pcall(S.Enemies.explode, at, BLAST_RADIUS, 7, 900, 6, { kind = "objective", id = "SunbreakerCharge" })
			end
		end
		-- troopers caught inside: the blast hurts them (heavy near the core, 25 % at the edge)
		if S.Players and S.Players.damage then
			for _, p in ctx.playersNear(at, BLAST_RADIUS) do
				local root = ctx.getRoot(p)
				if root then
					local dist = (root.Position - at).Magnitude
					local share = if S.Explosions and S.Explosions.playerFalloff then S.Explosions.playerFalloff(dist, 7, BLAST_RADIUS) else 1 - dist / BLAST_RADIUS
					if share > 0 then
						pcall(S.Players.damage, p, 260 * share, at, { kind = "objective" })
					end
				end
			end
		end
		destroyJammer()
		if ctx.alive() and alive then
			ctx.completeStep(entry, 4, if brood then "Spore jammer destroyed - uplink restored!" else "Jammer destroyed - uplink restored!")
			ctx.setMarker(entry, nil)
		end
	end

	local function runFuse()
		stage = 4
		local st = entry.steps[4]
		ctx.setMarker(entry, pos)
		local cmodel = if chargeBody then chargeBody.Parent else nil
		local led = if cmodel then cmodel:FindFirstChild("Led") else nil
		for s = cfg.fuse, 1, -1 do
			if not alive or not ctx.alive() then
				return
			end
			st.text = string.format("Get clear! Detonation in %d s", s)
			st.progress = 1 - s / cfg.fuse
			ctx.changed(s == cfg.fuse)
			if s % 2 == 0 or s <= 3 then
				ctx.sound("Alarm", chargePos)
			end
			if led and led:IsA("BasePart") then
				led.Color = if s % 2 == 0 then Color3.fromRGB(255, 255, 80) else RED
			end
			task.wait(1)
		end
		if not alive or not ctx.alive() then
			return
		end
		detonate()
	end

	-- stage 3: the charge sits on its pad, arm it
	local function buildCharge()
		local m = Instance.new("Model")
		m.Name = "SunbreakerCharge"
		m.Parent = f
		local pad = ctx.part(m, Vector3.new(5, 0.6, 5), CFrame.new(chargePos + Vector3.new(0, 0.3, 0)), DARK, Enum.Material.DiamondPlate)
		local body = ctx.cyl(m, 3.2, 4.2, CFrame.new(chargePos + Vector3.new(0, 2.7, 0)), ORANGE, Enum.Material.Metal, { Name = "Body" })
		ctx.cyl(m, 3.4, 0.5, CFrame.new(chargePos + Vector3.new(0, 1.2, 0)), DARK, Enum.Material.Metal, { CanCollide = false })
		ctx.cyl(m, 3.4, 0.5, CFrame.new(chargePos + Vector3.new(0, 4.2, 0)), DARK, Enum.Material.Metal, { CanCollide = false })
		local led = ctx.glow(m, Vector3.new(1, 0.4, 1), CFrame.new(chargePos + Vector3.new(0, 4.95, 0)), Color3.fromRGB(255, 255, 80))
		led.Name = "Led"
		ctx.light(led, Color3.fromRGB(255, 190, 90), 14, 1.2)
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(170, 30)
		gui.StudsOffset = Vector3.new(0, 5, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 90
		gui.Parent = pad
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 18
		label.TextColor3 = Color3.fromRGB(255, 214, 140)
		label.TextStrokeTransparency = 0
		label.Text = "SUNBREAKER"
		label.Parent = gui
		chargeBody = body
		armPrompt = ctx.prompt(body, {
			action = "Arm Charge",
			object = "Sunbreaker",
			hold = ARM_HOLD,
			distance = 10,
			enabled = false,
			onTrigger = function()
				if stage ~= 3 or not armPrompt then
					return
				end
				stage = 4
				armPrompt.Enabled = false
				ctx.completeStep(entry, 3, "Charge armed - RUN!")
				task.spawn(runFuse)
			end,
		})
	end

	local function startStage2()
		stage = 2
		local spotRing = ctx.cyl(f, 9, 0.3, CFrame.new(chargePos + Vector3.new(0, 0.25, 0)), Color3.fromRGB(255, 211, 74), Enum.Material.Neon, { CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 0.45 })
		ctx.light(spotRing, Color3.fromRGB(255, 200, 120), 16, 1)
		ctx.tween(spotRing, 0.6, { Transparency = 0.8 }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		ctx.setMarker(entry, chargePos)
		ctx.fx("DropPod", { p = chargePos, kind = "weapon", t = POD_FALL })
		task.wait(POD_FALL)
		if not alive or not ctx.alive() then
			return
		end
		ctx.fx("Shake", { p = chargePos, mag = 1.2, r = 60 })
		spotRing:Destroy()
		buildCharge()
		-- stage 2 is done when somebody walks up to the pod
		while alive and ctx.alive() and #ctx.playersNear(chargePos, 12) == 0 do
			task.wait(0.4)
		end
		if not alive or not ctx.alive() then
			return
		end
		stage = 3
		ctx.completeStep(entry, 2, "Sunbreaker charge reached")
		if armPrompt then
			armPrompt.Enabled = true
		end
	end

	hackPrompt = ctx.prompt(consoleBody, {
		action = if brood then "Override" else "Hack",
		object = if brood then "Spore Node" else "Override Console",
		hold = HACK_HOLD,
		distance = 10,
		onTrigger = function(player: Player)
			if stage ~= 1 then
				return
			end
			local h = holds[player]
			if h and h.hurt then
				return
			end
			stage = 2
			for p in table.clone(holds) do
				endHold(p)
			end
			hackPrompt.Enabled = false
			screen.Color = Color3.fromRGB(110, 255, 150)
			ctx.completeStep(entry, 1, "Override accepted - Sunbreaker charge inbound!")
			task.spawn(startStage2)
		end,
	})

	hackPrompt.PromptButtonHoldBegan:Connect(function(player: Player)
		if stage ~= 1 then
			return
		end
		endHold(player)
		local ch = player.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if not hum then
			return
		end
		local h = { t0 = os.clock(), hurt = false, conn = nil :: RBXScriptConnection? }
		local last = hum.Health
		h.conn = hum.HealthChanged:Connect(function(hp: number)
			if hp < last - 0.01 and holds[player] == h then
				h.hurt = true
				breakHack(player)
			end
			last = hp
		end)
		holds[player] = h
		task.spawn(function()
			while holds[player] == h and alive and ctx.alive() and stage == 1 do
				entry.steps[1].progress = math.min(hackProgress(), 0.99)
				ctx.changed()
				task.wait(0.25)
			end
		end)
	end)
	hackPrompt.PromptButtonHoldEnded:Connect(endHold)

	-- the site calls defenders while players work on it
	task.spawn(function()
		local t = 0
		while alive and ctx.alive() and not ctl.isDestroyed do
			task.wait(1)
			if #ctx.playersNear(pos, 70) > 0 then
				t += 1
				if t >= 28 then
					t = 0
					ctx.wave(pos, 4)
				end
			end
		end
	end)

	function ctl.stop()
		alive = false
		Jammers.remove(jamId)
		for p in table.clone(holds) do
			endHold(p)
		end
	end

	return ctl
end

return SideJammer
