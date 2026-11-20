--!nonstrict
-- Camera/screen juice: shake, recoil kick, hit-stop, flashes, vignettes.
--
--   Juice.shake(mag, dur, pos?, range?)  mag ~ peak degrees of camera rotation (0.3 subtle .. 4 huge);
--                                        with pos the magnitude falls off with distance to the camera
--   Juice.trauma(mag, dur, pos, range?)  shake with ~1/dist falloff out to `range` (default 120): orbital strikes / eruptions
--   Juice.flashAt(color, alpha, dur, pos, farRange?)  flash scaled by distance and by how much the camera faces `pos`
--   Juice.kick(pitchDeg, yawDeg)         instant recoil that springs back (positive pitch = camera up)
--   Juice.hitstop(t)                     freezes shake/kick progression and holds the camera for t seconds
--   Juice.flash(color, alpha, dur)       full-screen colour flash
--   Juice.vignette(color, alpha, dur)    edge vignette (damage)
--   Juice.colorPunch(tint, s, dur, sat?) short colour-grade hit (tint + contrast + saturation) easing back to neutral
--   Juice.step(dt) -> CFrame             combined offset: camera.CFrame = camera.CFrame * Juice.step(dt)
--   Juice.punchFov(deg)                  optional FOV punch; read the current offset with Juice.getFov()
--   Juice.intensity                      global multiplier (default 1; 0 disables shake/kick)
--   Juice.reset()

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Juice = {}
Juice.intensity = 1

local MAX_SHAKE_DEG = 9.5
local MAX_KICK_DEG = 10
local MAX_FLINCH_DEG = 7.5
local MAX_SHAKES = 24
local SHAKE_FREQ = 19

local rng = Random.new()

local shakes = {} -- {mag, dur, t, seed, freq, kind}
local kickP, kickPV = 0, 0 -- weapon recoil pitch spring (degrees)
local kickY, kickYV = 0, 0
local kickR, kickRV = 0, 0 -- brief roll jitter on shots
local flinchP, flinchPV = 0, 0 -- direct hit flinch spring (4-7 deg, 120-180 ms)
local flinchY, flinchYV = 0, 0
local flinchR, flinchRV = 0, 0
local kickBack, kickBackV = 0, 0 -- camera pushback in studs
local fovOff, fovVel = 0, 0
local holdUntil = 0
local heldCF = CFrame.identity
local lastCF = CFrame.identity
local clock = 0 -- accumulated unfrozen time

-- critically-damped-ish spring integration (semi-implicit Euler, sub-stepped for stability)
local function spring(x: number, v: number, dt: number, k: number, c: number): (number, number)
	local steps = math.max(1, math.ceil(dt / 0.008))
	local h = dt / steps
	for _ = 1, steps do
		v += (-k * x - c * v) * h
		x += v * h
	end
	return x, v
end

-- SHAKE / KICK ----------------------------------------------------------------------

function Juice.shake(mag: number, dur: number, pos: Vector3?, range: number?)
	if Juice.intensity <= 0 or mag <= 0 then
		return
	end
	if pos then
		local cam = workspace.CurrentCamera
		if cam then
			local d = (cam.CFrame.Position - pos).Magnitude
			local r = range or 100
			if d >= r then
				return
			end
			local f = 1 - d / r
			mag *= f * f
		end
	end
	mag *= Juice.intensity
	if mag < 0.02 then
		return
	end
	if #shakes >= MAX_SHAKES then
		table.remove(shakes, 1)
	end
	table.insert(shakes, {
		mag = mag,
		dur = math.max(dur, 0.05),
		t = 0,
		seed = rng:NextNumber() * 1000,
		freq = SHAKE_FREQ * (0.8 + rng:NextNumber() * 0.5),
	})
end

-- Explosion-style trauma: distance-scaled exponential decay (0.35-0.50 s) with a hard initial 100 ms snap
-- and a low-frequency settle tail. Full strength inside 22 studs, fading smoothly to `range` (default 140).
function Juice.trauma(mag: number, dur: number, pos: Vector3?, range: number?)
	if Juice.intensity <= 0 or mag <= 0 then
		return
	end
	if pos then
		local cam = workspace.CurrentCamera
		if cam then
			local r = range or 140
			local d = (cam.CFrame.Position - pos).Magnitude
			if d >= r then
				return
			end
			local u = d / r
			mag *= math.min(1, 22 / math.max(d, 1)) * (1 - u * u)
		end
	end
	mag *= Juice.intensity
	if mag < 0.04 then
		return
	end
	if #shakes >= MAX_SHAKES then
		table.remove(shakes, 1)
	end
	table.insert(shakes, {
		kind = "trauma",
		mag = mag,
		dur = math.clamp(dur, 0.35, 0.65),
		t = 0,
		seed = rng:NextNumber() * 1000,
		freq = 28 + rng:NextNumber() * 6,
		lowFreq = 7.5 + rng:NextNumber() * 2.5,
	})
end

-- Low-frequency ground thump (heavy walker footsteps, distant subterranean rumbles): slower oscillation than gunfire shake.
function Juice.thump(mag: number, dur: number, pos: Vector3?, range: number?)
	if Juice.intensity <= 0 or mag <= 0 then
		return
	end
	if pos then
		local cam = workspace.CurrentCamera
		if cam then
			local d = (cam.CFrame.Position - pos).Magnitude
			local r = range or 85
			if d >= r then
				return
			end
			local f = 1 - d / r
			mag *= f * f
		end
	end
	mag *= Juice.intensity
	if mag < 0.02 then
		return
	end
	if #shakes >= MAX_SHAKES then
		table.remove(shakes, 1)
	end
	table.insert(shakes, {
		mag = mag,
		dur = math.max(dur, 0.08),
		t = 0,
		seed = rng:NextNumber() * 1000,
		freq = 7.5 + rng:NextNumber() * 2.5,
	})
end

function Juice.kick(pitchDeg: number, yawDeg: number, rollDeg: number?)
	local i = Juice.intensity
	if i <= 0 then
		return
	end
	local p = pitchDeg
	-- Snappier weapon recoil floor (+1.5-2.5 deg feel across standard & heavy weapons; negative landing dips untouched)
	if p > 0.25 and p < 2.2 then
		p = 1.35 + (p - 0.25) * 0.62
	end
	p *= i
	local y = yawDeg * i
	local r = if type(rollDeg) == "number"
		then rollDeg * i
		else (if rng:NextNumber() < 0.5 then -1 else 1) * rng:NextNumber(0.45, 0.68) * math.clamp(math.abs(p) / 1.6, 0.6, 1.3)
	kickP = math.clamp(kickP + p * 0.65, -MAX_KICK_DEG, MAX_KICK_DEG)
	kickY = math.clamp(kickY + y * 0.65, -MAX_KICK_DEG, MAX_KICK_DEG)
	kickR = math.clamp(kickR + r * 0.7, -4.5, 4.5)
	-- crisp upward snap velocity so the peak hits immediately and settles in 180-240 ms
	kickPV += p * 14
	kickYV += y * 11
	kickRV += r * 14
	kickBack = math.clamp(kickBack + math.abs(p) * 0.045, 0, 0.65)
end

-- Direct hit flinch kick: unmistakable 4-7 deg pitch/roll punch over 120-180 ms, capped so aim stays recoverable.
function Juice.flinch(pitchDeg: number, yawDeg: number, rollDeg: number?)
	local i = Juice.intensity
	if i <= 0 then
		return
	end
	local p = math.clamp(pitchDeg * i, -MAX_FLINCH_DEG, MAX_FLINCH_DEG)
	local y = math.clamp(yawDeg * i, -MAX_FLINCH_DEG, MAX_FLINCH_DEG)
	local r = math.clamp((rollDeg or (if yawDeg >= 0 then -1 else 1) * math.abs(pitchDeg) * 0.85) * i, -MAX_FLINCH_DEG, MAX_FLINCH_DEG)
	flinchP = math.clamp(flinchP + p * 0.72, -MAX_FLINCH_DEG, MAX_FLINCH_DEG)
	flinchY = math.clamp(flinchY + y * 0.65, -MAX_FLINCH_DEG, MAX_FLINCH_DEG)
	flinchR = math.clamp(flinchR + r * 0.78, -MAX_FLINCH_DEG, MAX_FLINCH_DEG)
	flinchPV += p * 18
	flinchYV += y * 14
	flinchRV += r * 18
	kickBack = math.clamp(kickBack + 0.16 * i, 0, 0.7)
end

function Juice.hitstop(t: number)
	if Juice.intensity <= 0 then
		return
	end
	t = math.clamp(t, 0, 0.15)
	local untilT = os.clock() + t
	if untilT > holdUntil then
		if os.clock() >= holdUntil then
			heldCF = lastCF
		end
		holdUntil = untilT
	end
	-- impact feel: tiny FOV pinch that releases when the freeze ends
	fovVel -= 40 * Juice.intensity
end

-- Kill juice for medium+ enemies. weight: 1 medium, 2 heavy, 3 behemoth. `mine` = the local player landed the kill (only
-- then does the camera freeze); `pos` scales the shake by distance. The freeze is rate limited (one per 0.25 s) so a horde
-- cannot chain-stutter the view.
local KILL_STOP = { 0.03, 0.05, 0.075 }
local lastKillStop = 0
function Juice.kill(weight: number, mine: boolean?, pos: Vector3?)
	if Juice.intensity <= 0 then
		return
	end
	weight = math.clamp(math.floor(weight), 1, 3)
	local t = os.clock()
	if mine and t - lastKillStop > 0.25 then
		lastKillStop = t
		Juice.hitstop(KILL_STOP[weight])
	end
	Juice.shake(0.35 + 0.45 * weight, 0.22 + 0.12 * weight, pos, 40 + 25 * weight)
	if weight >= 3 then
		Juice.punchFov(2)
	end
end

function Juice.punchFov(deg: number)
	fovVel += deg * 25 * Juice.intensity
end

function Juice.getFov(): number
	return fovOff
end

function Juice.reset()
	table.clear(shakes)
	kickP, kickPV, kickY, kickYV, kickR, kickRV = 0, 0, 0, 0, 0, 0
	flinchP, flinchPV, flinchY, flinchYV, flinchR, flinchRV = 0, 0, 0, 0, 0, 0
	kickBack, kickBackV = 0, 0
	fovOff, fovVel = 0, 0
	holdUntil = 0
	lastCF = CFrame.identity
end

function Juice.step(dt: number): CFrame
	dt = math.min(dt, 0.1)
	if os.clock() < holdUntil then
		return heldCF -- hit-stop: camera and springs frozen
	end

	clock += dt
	-- weapon recoil spring (~180-240 ms crisp recovery)
	kickP, kickPV = spring(kickP, kickPV, dt, 520, 38)
	kickY, kickYV = spring(kickY, kickYV, dt, 520, 38)
	kickR, kickRV = spring(kickR, kickRV, dt, 580, 40)
	-- direct hit flinch spring (~120-180 ms punchy snap back)
	flinchP, flinchPV = spring(flinchP, flinchPV, dt, 860, 48)
	flinchY, flinchYV = spring(flinchY, flinchYV, dt, 860, 48)
	flinchR, flinchRV = spring(flinchR, flinchRV, dt, 860, 48)
	kickBack, kickBackV = spring(kickBack, kickBackV, dt, 260, 24)
	fovOff, fovVel = spring(fovOff, fovVel, dt, 260, 19)

	-- shakes + two-stage blast trauma (hard 100 ms initial snap + low-frequency exponential settle tail)
	local sp, sy, sr, sx, sv = 0, 0, 0, 0, 0
	for i = #shakes, 1, -1 do
		local s = shakes[i]
		s.t += dt
		local e = 1 - s.t / s.dur
		if e <= 0 then
			table.remove(shakes, i)
		elseif s.kind == "trauma" then
			local snap = math.exp(-s.t / 0.055)
			local tail = math.exp(-s.t / math.max(s.dur * 0.42, 0.08)) * e
			local nh = s.t * s.freq
			local nl = s.t * (s.lowFreq or 8.5)
			local aH = s.mag * 0.72 * snap
			local aL = s.mag * 0.58 * tail
			sp += math.noise(nh, s.seed, 0.5) * 2.2 * aH + math.noise(nl, s.seed, 5.5) * 1.9 * aL
			sy += math.noise(nh, s.seed, 1.5) * 2.0 * aH + math.noise(nl, s.seed, 6.5) * 1.7 * aL
			sr += math.noise(nh, s.seed, 2.5) * 1.8 * aH + math.noise(nl, s.seed, 7.5) * 1.5 * aL
			sx += (math.noise(nh, s.seed, 3.5) * aH + math.noise(nl, s.seed, 8.5) * aL) * 0.1
			sv += (math.noise(nh, s.seed, 4.5) * aH + math.noise(nl, s.seed, 9.5) * aL) * 0.1
		else
			local amp = s.mag * e * e
			local n = s.t * s.freq
			sp += math.noise(n, s.seed, 0.5) * 2 * amp
			sy += math.noise(n, s.seed, 1.5) * 2 * amp
			sr += math.noise(n, s.seed, 2.5) * 1.4 * amp
			sx += math.noise(n, s.seed, 3.5) * 0.06 * amp
			sv += math.noise(n, s.seed, 4.5) * 0.06 * amp
		end
	end
	sp = math.clamp(sp, -MAX_SHAKE_DEG, MAX_SHAKE_DEG)
	sy = math.clamp(sy, -MAX_SHAKE_DEG, MAX_SHAKE_DEG)
	sr = math.clamp(sr, -MAX_SHAKE_DEG, MAX_SHAKE_DEG)

	local totalP = sp + kickP + flinchP
	local totalY = sy + kickY + flinchY
	local totalR = sr + kickR + flinchR
	local cf = CFrame.new(sx, sv, kickBack)
		* CFrame.Angles(math.rad(totalP), math.rad(totalY), math.rad(totalR))
	lastCF = cf
	return cf
end

-- SCREEN OVERLAYS -------------------------------------------------------------------

local gui: ScreenGui? = nil
local flashFrame: Frame? = nil
local flashTween: Tween? = nil
local edges: { Frame } = {}
local vigTweens: { Tween } = {}

local function ensureGui(): boolean
	if gui and gui.Parent then
		return true
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return false
	end
	local g = Instance.new("ScreenGui")
	g.Name = "JuiceFx"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.DisplayOrder = 50
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local f = Instance.new("Frame")
	f.Name = "Flash"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Active = false
	f.ZIndex = 2
	f.Parent = g
	flashFrame = f

	-- four edge frames with transparency gradients pointing inwards
	table.clear(edges)
	local defs = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, 0.28), rot = 90 }, -- top
		{ pos = UDim2.fromScale(0, 0.72), size = UDim2.fromScale(1, 0.28), rot = 270 }, -- bottom
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(0.22, 1), rot = 0 }, -- left
		{ pos = UDim2.fromScale(0.78, 0), size = UDim2.fromScale(0.22, 1), rot = 180 }, -- right
	}
	for i, d in defs do
		local e = Instance.new("Frame")
		e.Name = "Vignette" .. i
		e.Position = d.pos
		e.Size = d.size
		e.BackgroundColor3 = Color3.new(1, 0, 0)
		e.BackgroundTransparency = 1
		e.BorderSizePixel = 0
		e.Active = false
		e.ZIndex = 1
		local gr = Instance.new("UIGradient")
		gr.Rotation = d.rot
		gr.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.4, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		gr.Parent = e
		e.Parent = g
		edges[i] = e
	end

	g.Parent = pg
	gui = g
	return true
end

function Juice.flash(color: Color3, alpha: number, dur: number)
	if Juice.intensity <= 0 or not ensureGui() then
		return
	end
	local f = flashFrame
	local startT = 1 - math.clamp(alpha * Juice.intensity, 0, 1)
	if flashTween then
		flashTween:Cancel()
		if f.BackgroundTransparency < startT then
			startT = f.BackgroundTransparency -- keep the stronger flash
		end
	end
	f.BackgroundColor3 = color
	f.BackgroundTransparency = startT
	flashTween = TweenService:Create(f, TweenInfo.new(math.max(dur, 0.05), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	flashTween:Play()
end

-- Flash scaled by how far away the event is and how directly the camera faces it (full alpha close and in view, a
-- faint wash far away or behind the player). Used by the orbital strikes.
function Juice.flashAt(color: Color3, alpha: number, dur: number, pos: Vector3, farRange: number?)
	local cam = workspace.CurrentCamera
	if not cam then
		Juice.flash(color, alpha, dur)
		return
	end
	local off = pos - cam.CFrame.Position
	local d = off.Magnitude
	local far = farRange or 700
	local distK = math.clamp(1.1 - d / far, 0.1, 1)
	local facing = if d > 1 then math.max(cam.CFrame.LookVector:Dot(off / d), 0) else 1
	local a = alpha * distK * (0.5 + 0.5 * facing)
	if a >= 0.03 then
		Juice.flash(color, a, dur)
	end
end

-- Colour punch: a short ColorCorrection hit (tint toward `tint`, contrast up, saturation by `sat`, default +0.4) that
-- eases back to neutral over `dur`. strength 1 = a strong call-in moment. One shared effect in Lighting (client only).
local punchCC: ColorCorrectionEffect? = nil
local punchTween: Tween? = nil
function Juice.colorPunch(tint: Color3, strength: number, dur: number, sat: number?)
	local s = math.clamp(strength * Juice.intensity, 0, 1.5)
	if s <= 0.01 then
		return
	end
	local cc = punchCC
	if not cc or not cc.Parent then
		local e = Instance.new("ColorCorrectionEffect")
		e.Name = "JuicePunch"
		e.Parent = game:GetService("Lighting")
		punchCC = e
		cc = e
	end
	if not cc then
		return
	end
	if punchTween then
		punchTween:Cancel()
	end
	cc.Enabled = true
	cc.TintColor = Color3.new(1, 1, 1):Lerp(tint, math.clamp(0.45 * s, 0, 0.7))
	cc.Contrast = 0.3 * s
	cc.Saturation = (sat or 0.4) * s
	cc.Brightness = 0.06 * s
	punchTween = TweenService:Create(cc, TweenInfo.new(math.max(dur, 0.1), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TintColor = Color3.new(1, 1, 1),
		Contrast = 0,
		Saturation = 0,
		Brightness = 0,
	})
	punchTween:Play()
end

function Juice.vignette(color: Color3, alpha: number, dur: number)
	if Juice.intensity <= 0 or not ensureGui() then
		return
	end
	for _, tw in vigTweens do
		tw:Cancel()
	end
	table.clear(vigTweens)
	local startT = 1 - math.clamp(alpha * Juice.intensity, 0, 1)
	for _, e in edges do
		e.BackgroundColor3 = color
		e.BackgroundTransparency = startT
		local tw = TweenService:Create(e, TweenInfo.new(math.max(dur, 0.1), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		})
		tw:Play()
		table.insert(vigTweens, tw)
	end
end

return Juice
