--!nonstrict
-- Camera/screen juice: shake, recoil kick, hit-stop, flashes, vignettes.
--
--   Juice.shake(mag, dur, pos?, range?)  mag ~ peak degrees of camera rotation (0.3 subtle .. 4 huge);
--                                        with pos the magnitude falls off with distance to the camera
--   Juice.kick(pitchDeg, yawDeg)         instant recoil that springs back (positive pitch = camera up)
--   Juice.hitstop(t)                     freezes shake/kick progression and holds the camera for t seconds
--   Juice.flash(color, alpha, dur)       full-screen colour flash
--   Juice.vignette(color, alpha, dur)    edge vignette (damage)
--   Juice.step(dt) -> CFrame             combined offset: camera.CFrame = camera.CFrame * Juice.step(dt)
--   Juice.punchFov(deg)                  optional FOV punch; read the current offset with Juice.getFov()
--   Juice.intensity                      global multiplier (default 1; 0 disables shake/kick)
--   Juice.reset()

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Juice = {}
Juice.intensity = 1

local MAX_SHAKE_DEG = 7
local MAX_KICK_DEG = 12
local MAX_SHAKES = 24
local SHAKE_FREQ = 17

local rng = Random.new()

local shakes = {} -- {mag, dur, t, seed, freq}
local kickP, kickPV = 0, 0 -- pitch spring (degrees)
local kickY, kickYV = 0, 0
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

function Juice.kick(pitchDeg: number, yawDeg: number)
	local i = Juice.intensity
	if i <= 0 then
		return
	end
	kickP = math.clamp(kickP + pitchDeg * i, -MAX_KICK_DEG, MAX_KICK_DEG)
	kickY = math.clamp(kickY + yawDeg * i, -MAX_KICK_DEG, MAX_KICK_DEG)
	-- a little velocity so the snap feels springy, plus a tiny camera pushback
	kickPV += pitchDeg * i * 6
	kickYV += yawDeg * i * 6
	kickBack = math.clamp(kickBack + math.abs(pitchDeg) * 0.03 * i, 0, 0.6)
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
	kickP, kickPV, kickY, kickYV, kickBack, kickBackV = 0, 0, 0, 0, 0, 0
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
	-- springs
	kickP, kickPV = spring(kickP, kickPV, dt, 380, 26)
	kickY, kickYV = spring(kickY, kickYV, dt, 380, 26)
	kickBack, kickBackV = spring(kickBack, kickBackV, dt, 200, 20)
	fovOff, fovVel = spring(fovOff, fovVel, dt, 240, 18)

	-- shakes (perlin noise, quadratic decay)
	local sp, sy, sr, sx, sv = 0, 0, 0, 0, 0
	for i = #shakes, 1, -1 do
		local s = shakes[i]
		s.t += dt
		local e = 1 - s.t / s.dur
		if e <= 0 then
			table.remove(shakes, i)
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

	local cf = CFrame.new(sx, sv, kickBack)
		* CFrame.Angles(math.rad(sp + kickP), math.rad(sy + kickY), math.rad(sr))
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
