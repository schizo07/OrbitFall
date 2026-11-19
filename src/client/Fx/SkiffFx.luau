-- Client visuals for the Skiff during extraction (server/Objectives/Extraction.luau):
--   Fx "SkiffHover"   {on = true, root = BasePart, p = Vector3, m = Model?}   engine loop + downward thruster plumes
--                      following the hull + rotor-wash dust on the pad until {on = false} (or root destroyed)
--   Fx "SkiffGun"     {a = Vector3, b = Vector3, m = "metal"|"goo"|"ground"}  one heavy door-gun bolt: readable muzzle
--                      bloom, glowing streaking bolt + lingering trail, impact burst on arrival
--   Fx "SkiffBoard"   {door = Vector3, foot = Vector3, m = Model?, dur = number?}  (to the boarding trooper only)
--                      walk cleanly up the ramp to the doorway threshold (no hopping); server fades and stows aboard
--   Fx "SkiffBoarded" {p = Vector3}  subtle friendly doorway glow pulse + chime when a trooper steps aboard
-- Studio only: mirrors the Feel_SkiffMode attribute to the server via Action "studioFeel".

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local V3 = Vector3.new
local V2 = Vector2.new
local CF = CFrame.new
local C3 = Color3.fromRGB
local NS = NumberSequence.new
local NSK = NumberSequenceKeypoint.new
local NR = NumberRange.new
local CS = ColorSequence.new
local INST = Instance.new
local EN = Enum
local WS = workspace
local TK = task

local SkiffFx = {}

local FxApi: any = nil
local Audio: any = nil

local TRACER = C3(255, 188, 72)
local TRACER_CORE = C3(255, 242, 200)
local BOARD_GLOW = C3(110, 245, 165)
local DUST = C3(214, 184, 146)
local DUST2 = C3(140, 120, 104)
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local FIRE = "rbxasset://textures/particles/fire_main.dds"

local function quality(): number
	return if FxApi and type(FxApi.quality) == "number" then FxApi.quality else 1
end

-- hover -----------------------------------------------------------------------------------------------------------------
local hover: { stop: () -> () }? = nil

local function stopHover()
	local h = hover
	hover = nil
	if h then
		h.stop()
	end
end

local function makeAnchor(name: string, cf: any): any
	local p = INST("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = V3(1, 1, 1)
	p.CFrame = cf
	p.Parent = Workspace
	return p
end

local function startHover(root: any, padPos: any, model: any)
	stopHover()
	local base = makeAnchor("SkiffHoverWash", CF(padPos + V3(0, 0.5, 0)))
	local dust = INST("ParticleEmitter")
	dust.Texture = SMOKE
	dust.Rate = 0
	dust.Lifetime = NR(2, 3.5)
	dust.Speed = NR(22, 44)
	dust.SpreadAngle = V2(88, 88)
	dust.EmissionDirection = EN.NormalId.Top
	dust.Size = NS({ NSK(0, 5), NSK(1, 18) })
	dust.Transparency = NS({ NSK(0, 0.55), NSK(1, 1) })
	dust.Color = CS(DUST, DUST2)
	dust.Drag = 3
	dust.RotSpeed = NR(-60, 60)
	dust.Parent = base

	-- Downward hover thruster plumes on the two engine pods (low part count: 2 invisible emitter anchors)
	local offs: { any } = {}
	local rootCF = root.CFrame
	if model and typeof(model) == "Instance" then
		for _, n in { "Engine_L", "Engine_R" } do
			local e = model:FindFirstChild(n, true)
			if e and e:IsA("BasePart") then
				offs[#offs + 1] = rootCF:PointToObjectSpace(e.Position) + V3(0, -1.0, 0)
			end
		end
	end
	if #offs < 2 then
		offs = { V3(-4.4, -2.2, 5.8), V3(4.4, -2.2, 5.8) }
	end
	local flameColor = CS(C3(255, 240, 210), C3(110, 180, 255))
	local flameTrans = NS({ NSK(0, 0.1), NSK(0.7, 0.45), NSK(1, 1) })
	local jets: { { part: any, off: any, plume: any, light: any } } = {}
	for _, off in offs do
		local jp = makeAnchor("SkiffHoverJet", rootCF * CF(off))
		local plume = INST("ParticleEmitter")
		plume.Texture = FIRE
		plume.Rate = 0
		plume.Lifetime = NR(0.22, 0.38)
		plume.Speed = NR(16, 26)
		plume.SpreadAngle = V2(10, 10)
		plume.EmissionDirection = EN.NormalId.Bottom
		plume.LightEmission = 1
		plume.LightInfluence = 0
		plume.Size = NS({ NSK(0, 3.0), NSK(1, 0.7) })
		plume.Transparency = flameTrans
		plume.Color = flameColor
		plume.Parent = jp
		local light = INST("PointLight")
		light.Color = C3(255, 210, 145)
		light.Range = 28
		light.Brightness = 0
		light.Shadows = false
		light.Parent = jp
		jets[#jets + 1] = { part = jp, off = off, plume = plume, light = light }
	end

	local engine: any = nil
	if Audio and Audio.loop then
		local ok, h = pcall(Audio.loop, "SkiffEngine", root)
		engine = if ok then h else nil
	end

	local t0 = os.clock()
	local dead = false
	local conn: any = nil
	local function stop()
		if dead then
			return
		end
		dead = true
		if conn then
			conn:Disconnect()
		end
		dust.Rate = 0
		Debris:AddItem(base, 4)
		for _, j in jets do
			j.plume.Rate = 0
			j.light.Brightness = 0
			Debris:AddItem(j.part, 1.5)
		end
		if engine and engine.stop then
			pcall(engine.stop, 1.2)
		end
	end
	conn = RunService.Heartbeat:Connect(function()
		if not root.Parent then
			stop()
			if hover and hover.stop == stop then
				hover = nil
			end
			return
		end
		local q = quality()
		local rampIn = math.clamp((os.clock() - t0) / 1.0, 0, 1)
		-- wash strength grows smoothly as the Skiff descends toward the pad
		local h = root.Position.Y - padPos.Y
		local k = math.clamp(1 - (h - 6) / 42, 0.25, 1) * rampIn
		dust.Rate = 75 * q * k
		local curCF = root.CFrame
		for _, j in jets do
			j.part.CFrame = curCF * CF(j.off)
			j.plume.Rate = 48 * q * rampIn
			j.light.Brightness = 2.0 * rampIn
		end
	end)
	hover = { stop = stop }
end

-- door gun -----------------------------------------------------------------------------------------------------------------
local function onGun(d: any)
	if type(d) ~= "table" or typeof(d.a) ~= "Vector3" or typeof(d.b) ~= "Vector3" then
		return
	end
	local a: any, b: any = d.a, d.b
	local v = b - a
	local len = v.Magnitude
	local dir = if len > 0.01 then v / len else V3(0, -1, 0)
	local travel = math.clamp(len / 240, 0.08, 0.26)
	local mat = if type(d.m) == "string" then d.m else "ground"
	if FxApi then
		-- bright muzzle bloom readable from the ground 30+ studs below
		if FxApi.muzzleFlash then
			FxApi.muzzleFlash(a, TRACER)
		end
		if FxApi.visual and FxApi.tween then
			local flare = FxApi.visual(V3(2.0, 2.0, 2.0), TRACER_CORE, CF(a), EN.PartType.Ball, EN.Material.Neon, 0.08, 0.12)
			if flare then
				FxApi.tween(flare, 0.11, { Size = V3(3.8, 3.8, 3.8), Transparency = 1 }, EN.EasingStyle.Quad, EN.EasingDirection.Out)
			end
		end
		-- crisp tracer + lingering sky streak + chunky glowing bolt traveling from Skiff to target
		if FxApi.tracer then
			FxApi.tracer(a, b, TRACER, 0.42)
		end
		if FxApi.beamTrail then
			FxApi.beamTrail(a, b, TRACER, 0.24)
		end
		if len >= 2 and FxApi.visual and FxApi.tween then
			local boltLen = math.min(7.5, len * 0.45)
			local startPos = a + dir * (boltLen * 0.5)
			local endPos = b - dir * (boltLen * 0.35)
			local bolt = FxApi.visual(
				V3(0.65, 0.65, boltLen),
				TRACER_CORE,
				CFrame.lookAt(startPos, startPos + dir),
				nil,
				EN.Material.Neon,
				0,
				travel + 0.06
			)
			if bolt then
				FxApi.tween(bolt, travel, { CFrame = CFrame.lookAt(endPos, endPos + dir) }, EN.EasingStyle.Linear, EN.EasingDirection.Out)
			end
		end
		-- impact burst right as the bolt hits
		TK.delay(travel, function()
			if FxApi.impact then
				FxApi.impact(b, -dir, "pen", mat)
			end
			if FxApi.shockwave and quality() >= 0.5 then
				FxApi.shockwave(b, 4.2, TRACER)
			end
		end)
	end
	if Audio and Audio.play then
		pcall(Audio.play, "TurretFire", a)
	end
end

-- boarding -----------------------------------------------------------------------------------------------------------------
-- Walks the local trooper cleanly up the ramp to the doorway threshold (no hopping, no backwards detour).
-- Humanoid:MoveTo is cancelled by the default controls' per-frame Move, so this steers right after them each frame.
local BOARD_STEP = "SkiffBoard"

local function onBoard(d: any)
	if type(d) ~= "table" then
		return
	end
	local door: any = if typeof(d.door) == "Vector3" then d.door elseif typeof(d.p) == "Vector3" then d.p else nil
	local foot: any = if typeof(d.foot) == "Vector3" then d.foot else nil
	if not door then
		return
	end
	local dur = if type(d.dur) == "number" then math.clamp(d.dur, 0.5, 4) else 1.5
	local t0 = os.clock()
	local atFoot = foot == nil
	-- Only detour to the foot of the ramp if starting far off to the side of the hull
	if not atFoot and foot then
		local ch = Players.LocalPlayer.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local axis = V3(foot.X - door.X, 0, foot.Z - door.Z)
			local axisLen = axis.Magnitude
			if axisLen > 0.5 then
				local unit = axis / axisLen
				local rel = V3(root.Position.X - door.X, 0, root.Position.Z - door.Z)
				local along = rel:Dot(unit)
				local lateral = (rel - unit * along).Magnitude
				if (along >= -1 and lateral <= 5.5) or rel.Magnitude <= 6 then
					atFoot = true
				end
			else
				atFoot = true
			end
		end
	end
	pcall(RunService.UnbindFromRenderStep, RunService, BOARD_STEP)
	RunService:BindToRenderStep(BOARD_STEP, EN.RenderPriority.Input.Value + 1, function()
		local ch = Players.LocalPlayer.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		if not ch or not hum or not (root and root:IsA("BasePart")) or hum.Health <= 0 or os.clock() - t0 > dur or ch:GetAttribute("Boarded") == true then
			if hum then
				hum:Move(V3(0, 0, 0), false)
			end
			RunService:UnbindFromRenderStep(BOARD_STEP)
			return
		end
		local pos = root.Position
		local target = if atFoot then door else foot
		local to = V3(target.X - pos.X, 0, target.Z - pos.Z)
		if to.Magnitude < 1.5 then
			if atFoot then
				hum:Move(V3(0, 0, 0), false)
				RunService:UnbindFromRenderStep(BOARD_STEP)
				return
			end
			atFoot = true
			return
		end
		hum:Move(to.Unit, false)
	end)
end

local function onBoarded(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" then
		return
	end
	if FxApi and FxApi.visual and FxApi.tween then
		local pop = FxApi.visual(V3(2.2, 2.2, 2.2), BOARD_GLOW, CF(d.p), EN.PartType.Ball, EN.Material.Neon, 0.35, 0.4)
		if pop then
			FxApi.tween(pop, 0.35, { Size = V3(5.5, 5.5, 5.5), Transparency = 1 }, EN.EasingStyle.Quad, EN.EasingDirection.Out)
		end
	end
	if Audio and Audio.play then
		pcall(Audio.play, "Pickup", d.p)
	end
end

function SkiffFx.init(Fx: any, audio: any, _juice: any)
	FxApi = Fx
	Audio = audio
	Fx.register("SkiffGun", onGun)
	Fx.register("SkiffBoard", onBoard)
	Fx.register("SkiffBoarded", onBoarded)
	Fx.register("SkiffHover", function(d: any)
		if type(d) ~= "table" then
			return
		end
		if d.on and typeof(d.root) == "Instance" and d.root:IsA("BasePart") and typeof(d.p) == "Vector3" then
			startHover(d.root, d.p, d.m)
		else
			stopHover()
		end
	end)
	-- Studio A/B: mirrors Feel_SkiffMode to the server
	if RunService:IsStudio() then
		local function mirror()
			Net.event("Action"):FireServer("studioFeel", "Feel_SkiffMode", WS:GetAttribute("Feel_SkiffMode"))
		end
		WS:GetAttributeChangedSignal("Feel_SkiffMode"):Connect(mirror)
		if WS:GetAttribute("Feel_SkiffMode") ~= nil then
			TK.spawn(mirror)
		end
	end
end

return SkiffFx
