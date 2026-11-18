-- Client visuals for the Skiff while it holds over a hot extraction zone (server/Objectives/Extraction.luau):
--   Fx "SkiffHover" {on = true, root = BasePart, p = Vector3}   engine loop following the hull + rotor-wash dust on the
--                    pad below it until {on = false} (or the root is destroyed)
--   Fx "SkiffGun"   {a = Vector3, b = Vector3, m = "metal"|"goo"|"ground"}   one chin-gun round: muzzle flash, heavy
--                    tracer, impact puff (m = impact material)
--   Fx "SkiffBoard" {p = Vector3, foot = Vector3, m = Model}   (to the boarding trooper only) walk to the ramp's foot,
--                    then up it to p inside the bay; the server fades the character out once there
-- Studio only: mirrors the Feel_SkiffMode attribute (Variants group "SKIFF") to the server via Action "studioFeel".

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local SkiffFx = {}

local FxApi: any = nil
local Audio: any = nil

local TRACER = Color3.fromRGB(255, 196, 92)
local DUST = Color3.fromRGB(214, 184, 146)
local DUST2 = Color3.fromRGB(140, 120, 104)
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

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

local function startHover(root: BasePart, padPos: Vector3)
	stopHover()
	local base = Instance.new("Part")
	base.Name = "SkiffHoverWash"
	base.Anchored = true
	base.CanCollide = false
	base.CanQuery = false
	base.CanTouch = false
	base.CastShadow = false
	base.Transparency = 1
	base.Size = Vector3.new(1, 1, 1)
	base.Position = padPos + Vector3.new(0, 0.5, 0)
	base.Parent = Workspace
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = SMOKE
	dust.Rate = 0
	dust.Lifetime = NumberRange.new(2, 3.5)
	dust.Speed = NumberRange.new(22, 44)
	dust.SpreadAngle = Vector2.new(88, 88)
	dust.EmissionDirection = Enum.NormalId.Top
	dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(1, 18) })
	dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	dust.Color = ColorSequence.new(DUST, DUST2)
	dust.Drag = 3
	dust.RotSpeed = NumberRange.new(-60, 60)
	dust.Parent = base

	local engine: any = nil
	if Audio and Audio.loop then
		local ok, h = pcall(Audio.loop, "SkiffEngine", root)
		engine = if ok then h else nil
	end

	local t0 = os.clock()
	local dead = false
	local conn: RBXScriptConnection? = nil
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
		-- wash strength falls off with the hull's height over the pad
		local h = root.Position.Y - padPos.Y
		local k = math.clamp(1 - (h - 6) / 40, 0.15, 1) * math.clamp((os.clock() - t0) / 1.2, 0, 1)
		dust.Rate = 70 * quality() * k
	end)
	hover = { stop = stop }
end

-- door gun -----------------------------------------------------------------------------------------------------------------
local function onGun(d: any)
	if type(d) ~= "table" or typeof(d.a) ~= "Vector3" or typeof(d.b) ~= "Vector3" then
		return
	end
	local a: Vector3, b: Vector3 = d.a, d.b
	if FxApi then
		if FxApi.muzzleFlash then
			FxApi.muzzleFlash(a, TRACER)
		end
		if FxApi.tracer then
			FxApi.tracer(a, b, TRACER, 0.32)
		end
		if FxApi.impact then
			local n = (a - b)
			n = if n.Magnitude > 0.01 then n.Unit else Vector3.yAxis
			FxApi.impact(b, n, "pen", if type(d.m) == "string" then d.m else "ground")
		end
	end
	if Audio and Audio.play then
		pcall(Audio.play, "TurretFire", a)
	end
end

-- boarding -----------------------------------------------------------------------------------------------------------------
-- Walks the local trooper to the foot of the ramp, then up it into the bay (straight to the bay once they stand on the
-- Skiff). A short hop when blocked gets them onto a ramp end that hangs above uneven ground. Humanoid:MoveTo is cancelled
-- by the default controls' per-frame Move, so this steers right after them each frame (until there, boarded or 4 s).
local BOARD_STEP = "SkiffBoard"
local boardRay = RaycastParams.new()
boardRay.FilterType = Enum.RaycastFilterType.Include

local function onBoard(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" or typeof(d.foot) ~= "Vector3" then
		return
	end
	local bay: Vector3, foot: Vector3 = d.p, d.foot
	local skiff = if typeof(d.m) == "Instance" then d.m else nil
	local t0 = os.clock()
	local atFoot = false
	local lastPos: Vector3? = nil
	local lastCheck, lastHop = os.clock(), 0
	pcall(RunService.UnbindFromRenderStep, RunService, BOARD_STEP)
	RunService:BindToRenderStep(BOARD_STEP, Enum.RenderPriority.Input.Value + 1, function()
		local ch = Players.LocalPlayer.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not ch or not hum or not root or hum.Health <= 0 or os.clock() - t0 > 4 or ch:GetAttribute("Boarded") == true then
			RunService:UnbindFromRenderStep(BOARD_STEP)
			return
		end
		local pos = root.Position
		-- standing on the ramp / in the hull already: no need to go round by the foot
		if not atFoot and skiff and skiff.Parent then
			boardRay.FilterDescendantsInstances = { skiff }
			if workspace:Raycast(pos, Vector3.new(0, -5, 0), boardRay) then
				atFoot = true
			end
		end
		local target = if atFoot then bay else foot
		local to = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
		if to.Magnitude < 1 then
			if atFoot then
				RunService:UnbindFromRenderStep(BOARD_STEP)
				return
			end
			atFoot = true
			return
		end
		hum:Move(to.Unit, false)
		-- blocked (ramp edge, step): hop
		local c = os.clock()
		if c - lastCheck >= 0.3 then
			if lastPos and (Vector3.new(pos.X - lastPos.X, 0, pos.Z - lastPos.Z)).Magnitude < 0.6 and c - lastHop > 0.8 then
				hum.Jump = true
				lastHop = c
			end
			lastPos = pos
			lastCheck = c
		end
	end)
end

function SkiffFx.init(Fx: any, audio: any, _juice: any)
	FxApi = Fx
	Audio = audio
	Fx.register("SkiffGun", onGun)
	Fx.register("SkiffBoard", onBoard)
	Fx.register("SkiffHover", function(d: any)
		if type(d) ~= "table" then
			return
		end
		if d.on and typeof(d.root) == "Instance" and d.root:IsA("BasePart") and typeof(d.p) == "Vector3" then
			startHover(d.root, d.p)
		else
			stopHover()
		end
	end)
	-- A/B "SKIFF": the server reads Feel_SkiffMode (server/Objectives/Extraction.luau); Variants sets it on the client only
	if RunService:IsStudio() then
		local function mirror()
			Net.event("Action"):FireServer("studioFeel", "Feel_SkiffMode", workspace:GetAttribute("Feel_SkiffMode"))
		end
		workspace:GetAttributeChangedSignal("Feel_SkiffMode"):Connect(mirror)
		if workspace:GetAttribute("Feel_SkiffMode") ~= nil then
			task.spawn(mirror)
		end
	end
end

return SkiffFx
