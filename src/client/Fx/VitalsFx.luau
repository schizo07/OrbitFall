--!nonstrict
-- Health / stim presentation on the client. Loaded automatically by Fx.init (init(Fx, Audio, Juice)).
--
-- Damage feedback, scaled by missing health (cartoony, no blood):
--   * red edge vignette: grows as health drops (from 75 % down), plus a short pulse on each hit
--   * desaturation: a ColorCorrectionEffect in Lighting ("VitalsCC", client-only) drains colour and warms the tint,
--     stronger at low health, with a short extra dip on each hit
--   * heartbeat below 25 %: "Heartbeat" thump (Sounds) with the edge pulsing on the beat, faster the lower the health
--   * big hits: a short visor overlay that fades. Static smear (jittering horizontal bands) at >= 15 % of max hp in one
--     hit, plus visor cracks (white line bursts from the side the hit came from) at >= 28 %
--   Studio A/B (Variants group "DAMAGE FX"): Feel_DmgFx = intensity multiplier (default 1),
--   Feel_DmgOverlay = "auto" | "static" | "crack" | "none" (default auto = the thresholds above)
--
-- Stims (server: PlayerService.useStim, Config.Stims):
--   * input: Input action "Stim" (F; MobileControls STIM button) and gamepad D-pad Left, read here, only while the
--     Uplink dial (LB) is not held (A's dial types codes with the D-pad). Sends Action "stim".
--   * Fx "Stim" {u, p, t} (everyone): green burst at the trooper + injector sound; for yourself a green screen flash
--   * Fx "StimDenied" {why = "empty" | "full" | "busy"}: short prompt + error click
--
-- Context prompts (UI/ContextPrompt): "PRESS [F] TO USE STIM" while health is critical and you have stims;
-- "PRESS [Z] TO DIVE PRONE" the first 3 times you take heavy fire (>= 30 % hp or 4 hits within 2.5 s).
--
-- Studio only: mirrors the Feel_Regen attribute (Variants group "REGEN") to the server via Action "studioFeel".

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local CombatPose = require(script.Parent.Parent:WaitForChild("CombatPose"))

local VitalsFx = {}

local Fx: any
local Audio: any
local Juice: any
local Store: any
local Input: any
local Theme: any
local ContextPrompt: any

local player = Players.LocalPlayer
local IS_STUDIO = RunService:IsStudio()

local CRIT = Config.Stims.Critical -- HUD bar red + stim prompt
local HEART_AT = 0.25 -- heartbeat below this
local BIG_STATIC = 15 -- one hit >= this % of max hp -> static smear
local BIG_CRACK = 28 -- one hit >= this % -> visor cracks too
local HEAVY_WINDOW = 2.5
local HEAVY_DMG = 30
local HEAVY_HITS = 4
local PRONE_TIPS_MAX = 3

local gui: ScreenGui? = nil
local edges: { Frame } = {}
local cc: ColorCorrectionEffect? = nil
local staticBands: { Frame } = {}
local crackPool: { { Frame } } = {} -- each set: line frames
local crackNext = 1

local shownFrac = 1 -- eased health fraction for the screen effects
local hitPulse = 0 -- 0..1 decays after each hit
local hitDesat = 0
local staticT = 0
local staticJitter = 0
local beatT = 0 -- seconds until the next heartbeat
local beatPulse = 0 -- 0..1 edge pulse on the beat
local recentHits: { { t: number, a: number } } = {}
local proneTips = 0
local proneTipAt = -100
local dialHeld = false

local function now(): number
	return os.clock()
end

local function attr(name: string): any
	if IS_STUDIO then
		return workspace:GetAttribute(name)
	end
	return nil
end

local function intensity(): number
	local v = attr("Feel_DmgFx")
	if type(v) == "number" then
		return math.clamp(v, 0, 3)
	end
	return 1.2 -- 2026-11-15 pick: above x1, below x1.4
end

local function overlayMode(): string
	local v = attr("Feel_DmgOverlay")
	if type(v) == "string" then
		return v
	end
	return "auto"
end

local function inCombat(): boolean
	local m = Store.get("mission")
	local s = m and m.state
	return s == "Active" or s == "Extract"
end

local function meAlive(): (boolean, any)
	local me = Store.get("me")
	return me ~= nil and me.alive ~= false and me.dropping ~= true, me
end

local function hpFrac(me: any): number
	if not me or not me.maxHp or me.maxHp <= 0 then
		return 1
	end
	return math.clamp((me.hp or 0) / me.maxHp, 0, 1)
end

-- GUI ---------------------------------------------------------------------------------------------------------------
local function build()
	local g = Instance.new("ScreenGui")
	g.Name = "OrbitVitals"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 6 -- under the HUD (10), over the world
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		g.ScreenInsets = Enum.ScreenInsets.None
	end)

	-- edge vignette: four gradient bands
	local defs = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, 0.32), rot = 90 },
		{ pos = UDim2.fromScale(0, 0.68), size = UDim2.fromScale(1, 0.32), rot = 270 },
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(0.24, 1), rot = 0 },
		{ pos = UDim2.fromScale(0.76, 0), size = UDim2.fromScale(0.24, 1), rot = 180 },
	}
	for _, d in defs do
		local f = Instance.new("Frame")
		f.Name = "Edge"
		f.BackgroundColor3 = Color3.fromRGB(200, 24, 30)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Position = d.pos
		f.Size = d.size
		f.Active = false
		f.Parent = g
		local gr = Instance.new("UIGradient")
		gr.Rotation = d.rot
		gr.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.45, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		gr.Parent = f
		table.insert(edges, f)
	end

	-- static smear bands (pooled, re-randomised while active)
	for i = 1, 12 do
		local b = Instance.new("Frame")
		b.Name = "Static"
		b.BorderSizePixel = 0
		b.BackgroundColor3 = if i % 3 == 0 then Color3.fromRGB(140, 230, 255) else Color3.new(1, 1, 1)
		b.BackgroundTransparency = 1
		b.Size = UDim2.new(1, 0, 0, 4)
		b.Visible = false
		b.ZIndex = 3
		b.Parent = g
		table.insert(staticBands, b)
	end

	-- crack sets (pooled): 9 line segments each
	for _ = 1, 3 do
		local set = {}
		for _ = 1, 9 do
			local l = Instance.new("Frame")
			l.Name = "Crack"
			l.BorderSizePixel = 0
			l.BackgroundColor3 = Color3.fromRGB(235, 248, 255)
			l.BackgroundTransparency = 1
			l.AnchorPoint = Vector2.new(0.5, 0.5)
			l.Visible = false
			l.ZIndex = 4
			local st = Instance.new("UIStroke")
			st.Color = Color3.fromRGB(20, 30, 40)
			st.Transparency = 1
			st.Thickness = 1
			st.Parent = l
			l.Parent = g
			table.insert(set, l)
		end
		table.insert(crackPool, set)
	end

	g.Parent = player:WaitForChild("PlayerGui")
	gui = g
end

local function ensureCC(): ColorCorrectionEffect
	if cc and cc.Parent == Lighting then
		return cc
	end
	local e = Instance.new("ColorCorrectionEffect")
	e.Name = "VitalsCC"
	e.Parent = Lighting
	cc = e
	return e
end

-- Big-hit overlays ----------------------------------------------------------------------------------------------------
local function screenSize(): Vector2
	local cam = workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

-- direction (screen space, unit) toward the attacker; random edge when unknown
local function hitDir(from: Vector3?): Vector2
	local cam = workspace.CurrentCamera
	if cam and typeof(from) == "Vector3" then
		local rel = cam.CFrame:PointToObjectSpace(from)
		local v = Vector2.new(rel.X, -rel.Y * 0.5) -- left/right of the camera -> that side; above -> top
		if v.Magnitude > 0.01 then
			return v.Unit
		end
	end
	local a = math.random() * math.pi * 2
	return Vector2.new(math.cos(a), math.sin(a))
end

local function crack(from: Vector3?, strength: number)
	local set = crackPool[crackNext]
	crackNext = crackNext % #crackPool + 1
	if not set then
		return
	end
	local vp = screenSize()
	local d = hitDir(from)
	-- impact point on the visor: toward the attacker's side, inside the screen
	local c = vp / 2 + Vector2.new(d.X * vp.X * 0.32, d.Y * vp.Y * 0.3)
	local scale = math.clamp(vp.Y / 720, 0.6, 1.6) * (0.8 + 0.4 * strength)
	local k = 1
	local function seg(p0: Vector2, ang: number, len: number, w: number): Vector2
		local l = set[k]
		k += 1
		if not l then
			return p0
		end
		local dir = Vector2.new(math.cos(ang), math.sin(ang))
		local mid = p0 + dir * len / 2
		l.Position = UDim2.fromOffset(mid.X, mid.Y)
		l.Size = UDim2.fromOffset(len, w)
		l.Rotation = math.deg(ang)
		l.BackgroundTransparency = 0.15
		l.Visible = true
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			st.Transparency = 0.5
		end
		return p0 + dir * len
	end
	local base = math.random() * math.pi * 2
	for i = 1, 4 do
		local ang = base + (i - 1) * (math.pi * 2 / 4) + (math.random() - 0.5) * 0.9
		local len = (40 + math.random() * 70) * scale
		local tip = seg(c, ang, len, 2)
		if k <= #set then
			seg(tip, ang + (math.random() - 0.5) * 1.2, len * (0.4 + math.random() * 0.4), 1)
		end
	end
	-- fade out
	local life = 0.75
	for _, l in set do
		if l.Visible then
			Theme.tween(l, life, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local st = l:FindFirstChildOfClass("UIStroke")
			if st then
				Theme.tween(st, life, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end
		end
	end
	task.delay(life + 0.05, function()
		for _, l in set do
			if l.BackgroundTransparency >= 0.99 then
				l.Visible = false
			end
		end
	end)
end

local function stepStatic(dt: number)
	if staticT <= 0 then
		return
	end
	staticT -= dt
	staticJitter -= dt
	local vp = screenSize()
	local alive = staticT > 0
	local a = math.clamp(staticT / 0.35, 0, 1)
	if staticJitter <= 0 or not alive then
		staticJitter = 0.035
		local bandY = math.random() * 0.6 + 0.1
		for i, b in staticBands do
			if not alive then
				b.Visible = false
			else
				b.Visible = math.random() < 0.85
				local y = (bandY + (math.random() - 0.5) * 0.3) * vp.Y
				local h = 1 + math.random() * (if i % 4 == 0 then 10 else 4)
				b.Position = UDim2.fromOffset((math.random() - 0.5) * 60, y)
				b.Size = UDim2.new(1, 0, 0, h)
				b.BackgroundTransparency = 1 - a * (0.15 + math.random() * 0.3)
			end
		end
	end
end

local function hideOverlays()
	staticT = 0
	for _, b in staticBands do
		b.Visible = false
	end
end

-- Damage -------------------------------------------------------------------------------------------------------------
local function onHurt(d: any)
	if type(d) ~= "table" then
		return
	end
	local amount = tonumber(d.amount) or 10 -- % of max hp
	if amount < 0.5 then
		return -- debug god mode
	end
	local k = intensity()
	if k <= 0 then
		return
	end
	local t = now()
	-- edge + desaturation pulse, scaled up when health is already low
	local _, me = meAlive()
	local missing = 1 - hpFrac(me)
	hitPulse = math.max(hitPulse, math.clamp(amount / 30 + 0.2 + missing * 0.3, 0, 1))
	hitDesat = math.max(hitDesat, math.clamp(amount / 40, 0.1, 0.6))
	-- big-hit visor overlay
	local mode = overlayMode()
	if mode ~= "none" then
		local wantStatic = (mode == "static" and amount >= BIG_STATIC) or (mode == "auto" and amount >= BIG_STATIC)
		local wantCrack = (mode == "crack" and amount >= BIG_STATIC) or (mode == "auto" and amount >= BIG_CRACK)
		if wantStatic then
			staticT = math.max(staticT, 0.25 + 0.15 * math.min(k, 1.5))
			staticJitter = 0
		end
		if wantCrack and gui then
			crack(d.from, math.clamp(amount / 50, 0, 1))
		end
	end
	-- heavy fire bookkeeping (prone tip)
	table.insert(recentHits, { t = t, a = amount })
	local sum, n = 0, 0
	for i = #recentHits, 1, -1 do
		local h = recentHits[i]
		if t - h.t > HEAVY_WINDOW then
			table.remove(recentHits, i)
		else
			sum += h.a
			n += 1
		end
	end
	if (sum >= HEAVY_DMG or n >= HEAVY_HITS) and proneTips < PRONE_TIPS_MAX and t - proneTipAt > 20 then
		local st = Store.get("stance")
		if st ~= "prone" and st ~= "dive" then
			proneTips += 1
			proneTipAt = t
			ContextPrompt.show("prone", "Press {key} to dive prone", "Prone", 3.5, 2)
		end
	end
end

-- Stims --------------------------------------------------------------------------------------------------------------
local function requestStim()
	if dialHeld or Input.isDown("Dial") or Store.get("menuOpen") then
		return
	end
	local alive, me = meAlive()
	if not alive or not inCombat() then
		return
	end
	if type(me.stims) == "number" and me.stims <= 0 then
		ContextPrompt.show("stimdeny", "No stims left - call a supply drop", "", 1.6, 6)
		if Audio then
			Audio.play2D("UIError", { volume = 0.6 })
		end
		return
	end
	if hpFrac(me) >= 0.999 then
		ContextPrompt.show("stimdeny", "Health full", "", 1.2, 6)
		return
	end
	Net.event("Action"):FireServer("stim")
end

local function onStim(d: any)
	if type(d) ~= "table" then
		return
	end
	local mine = d.u == player.UserId
	CombatPose.stimPose(d.u) -- injection pose + prop for every client
	local who = Players:GetPlayerByUserId(tonumber(d.u) or 0)
	local char = who and who.Character
	local torso = char and (char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")) :: BasePart?
	local pos = if torso then torso.Position elseif typeof(d.p) == "Vector3" then d.p else nil
	if mine then
		ContextPrompt.hide("stim")
		if Audio then
			Audio.play2D("StimInject")
		end
		if Juice then
			Juice.flash(Color3.fromRGB(90, 255, 150), 0.22, 0.35)
		end
		hitPulse = 0
	elseif Audio and pos then
		Audio.play("StimInject", pos)
	end
	-- green burst at the trooper (everyone sees it; cheap: two parts, auto-cleaned)
	if pos and Fx and Fx.visual then
		local cf = CFrame.new(pos)
		local p = Fx.visual(Vector3.new(1.2, 1.2, 1.2), Color3.fromRGB(90, 255, 150), cf, Enum.PartType.Ball, Enum.Material.Neon, 0.25, 0.45)
		if p and Fx.tween then
			Fx.tween(p, 0.4, { Size = Vector3.new(5, 5, 5), Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
		local ring = Fx.visual(Vector3.new(0.2, 4, 4), Color3.fromRGB(170, 255, 200), cf * CFrame.Angles(0, 0, math.rad(90)), Enum.PartType.Cylinder, Enum.Material.Neon, 0.4, 0.5)
		if ring and Fx.tween then
			ring.CFrame = CFrame.new(pos - Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
			Fx.tween(ring, 0.5, { Size = Vector3.new(0.2, 9, 9), Transparency = 1, CFrame = ring.CFrame + Vector3.new(0, 3, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end
end

local function onStimDenied(d: any)
	local why = type(d) == "table" and d.why
	if why == "empty" then
		ContextPrompt.show("stimdeny", "No stims left - call a supply drop", "", 1.6, 6)
	elseif why == "full" then
		ContextPrompt.show("stimdeny", "Health full", "", 1.2, 6)
	elseif why == "busy" then
		ContextPrompt.show("stimdeny", "Stim already working", "", 1.0, 6)
	else
		return
	end
	if Audio then
		Audio.play2D("UIError", { volume = 0.5 })
	end
end

-- Per frame ------------------------------------------------------------------------------------------------------------
local function setEdges(alpha: number)
	local t = 1 - math.clamp(alpha, 0, 1)
	for _, f in edges do
		if math.abs(f.BackgroundTransparency - t) > 0.002 then
			f.BackgroundTransparency = t
		end
	end
end

local idle = false
local function step(dt: number)
	if not gui then
		return
	end
	local alive, me = meAlive()
	local active = alive and inCombat()
	if not active then
		if not idle then
			idle = true
			setEdges(0)
			hideOverlays()
			shownFrac, hitPulse, hitDesat, beatPulse = 1, 0, 0, 0
			if cc then
				cc.Saturation, cc.Contrast, cc.TintColor = 0, 0, Color3.new(1, 1, 1)
				cc.Enabled = false
			end
			ContextPrompt.hide("stim")
		end
		return
	end
	idle = false
	local k = intensity()
	local frac = hpFrac(me)
	shownFrac += (frac - shownFrac) * (1 - math.exp(-8 * dt))
	local missing = 1 - shownFrac

	-- heartbeat below 25 %: thump + edge pulse; interval 0.9 s at 25 % -> 0.5 s near 0
	if frac < HEART_AT and k > 0 then
		beatT -= dt
		if beatT <= 0 then
			beatT = 0.5 + 0.4 * (frac / HEART_AT)
			beatPulse = 1
			if Audio then
				Audio.play2D("Heartbeat", { volume = 0.6 + 0.5 * (1 - frac / HEART_AT) })
			end
		end
	else
		beatT = 0
	end
	beatPulse = math.max(0, beatPulse - dt * 4)
	hitPulse = math.max(0, hitPulse - dt * 2.2)
	hitDesat = math.max(0, hitDesat - dt * 1.5)

	-- edge vignette: shows from 75 % health down, peaks around 0.55 alpha at 0 hp (x intensity)
	local base = math.clamp((missing - 0.25) / 0.75, 0, 1) ^ 1.2 * 0.5
	local alpha = (base + 0.22 * beatPulse + 0.35 * hitPulse) * k
	setEdges(math.min(alpha, 0.85))

	-- desaturation / warm tint
	local e = ensureCC()
	local desat = (math.clamp((missing - 0.2) / 0.8, 0, 1) * 0.7 + hitDesat * 0.4) * k
	desat = math.min(desat, 0.95)
	-- at full health this is an identity grade: switch the effect off so it costs no full-screen pass (matters on phones)
	local grading = desat > 0.001
	if e.Enabled ~= grading then
		e.Enabled = grading
	end
	if grading then
		e.Saturation = -desat
		e.Contrast = 0.08 * desat
		e.TintColor = Color3.new(1, 1 - 0.12 * desat, 1 - 0.14 * desat)
	elseif e.Saturation ~= 0 then
		e.Saturation, e.Contrast, e.TintColor = 0, 0, Color3.new(1, 1, 1)
	end

	stepStatic(dt)

	-- stim prompt while critical and stims left
	local stims = type(me.stims) == "number" and me.stims or 0
	local healing = (me.stimEnd or 0) > workspace:GetServerTimeNow()
	local wantStim = frac < CRIT and stims > 0 and not healing
	if wantStim ~= ContextPrompt.isShowing("stim") then
		if wantStim then
			ContextPrompt.show("stim", "Press {key} to use stim", "Stim", nil, 5)
		else
			ContextPrompt.hide("stim")
		end
	end
	local st = Store.get("stance")
	if (st == "prone" or st == "dive") and ContextPrompt.isShowing("prone") then
		ContextPrompt.hide("prone")
	end
end

-- Init -----------------------------------------------------------------------------------------------------------------
local function findClientRoot(): Instance?
	local inst: Instance? = script.Parent
	for _ = 1, 4 do
		if inst and inst:FindFirstChild("Store") then
			return inst
		end
		inst = inst and inst.Parent
	end
	return nil
end

function VitalsFx.init(fx: any, audio: any, juice: any)
	Fx, Audio, Juice = fx, audio, juice
	local root = findClientRoot()
	if not root then
		warn("[VitalsFx] client root not found")
		return
	end
	Store = require(root.Store)
	Input = require(root.Input)
	Theme = require((root :: any).UI.Theme)
	ContextPrompt = require((root :: any).UI.ContextPrompt)

	Fx.register("Hurt", onHurt)
	Fx.register("Stim", onStim)
	Fx.register("StimDenied", onStimDenied)

	-- stim input: F (Input KEYS) + MobileControls STIM button -> Input action "Stim"
	Input.on("Stim", function(isDown)
		if isDown then
			requestStim()
		end
	end)
	-- gamepad D-pad Left, only while the Uplink dial (LB / "Dial") is not held
	Input.on("Dial", function(isDown)
		dialHeld = isDown
	end)
	UserInputService.InputBegan:Connect(function(io)
		if io.KeyCode == Enum.KeyCode.DPadLeft and not Input.isDown("Dial") then
			Input.set("Stim", true)
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if io.KeyCode == Enum.KeyCode.DPadLeft then
			Input.set("Stim", false)
		end
	end)

	-- Studio: mirror server-read Feel_* attributes (Variants sets them on the client only)
	if IS_STUDIO then
		local function mirror(name: string)
			Net.event("Action"):FireServer("studioFeel", name, workspace:GetAttribute(name))
		end
		workspace:GetAttributeChangedSignal("Feel_Regen"):Connect(function()
			mirror("Feel_Regen")
		end)
		if workspace:GetAttribute("Feel_Regen") ~= nil then
			mirror("Feel_Regen")
		end
	end

	task.spawn(function()
		build()
		RunService.RenderStepped:Connect(step)
	end)
end

return VitalsFx
