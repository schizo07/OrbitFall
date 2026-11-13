--!nonstrict
-- Client presentation of the Director's pacing layer (server: src/server/Enemies/Director.luau, tunables:
-- src/shared/Data/Intensity.luau). Loaded automatically by Fx.init (init(Fx, Audio, Juice)).
--
-- Inputs
--   Store "intensity"  {state = "off"|"calm"|"build"|"breach"|"relax", t0, endsAt, dir (bearing deg, 0 = N, 90 = E), wave, breach,
--                       extract (bool), faction}     (S.State.broadcast from the Director)
--   Fx "HeavyContact"  {p, kind, name, class}       (S.Fx.to: only players within ~120 studs)
--   Store "mission".extract {eta, window?}          (Mission.setExtract) -> extraction countdown panel
--
-- What it shows (own ScreenGui "OrbitIntensity", HUD style, virtual pixels like HUD.luau)
--   * threat strip under the compass: BUILD amber "SEISMIC ACTIVITY"/"SIGNAL SPIKE"; BREACH red "BREACH INBOUND" + rotating
--     direction arrow + compass name + time left bar; extraction "HOLD THE PAD  WAVE n"; RELAX green "BREACH REPELLED"
--   * big red banner "BREACH INBOUND  <arrow>  FROM THE NORTH-EAST" (arrow rotates with the camera) + siren + shake + flash
--   * orange "HEAVY CONTACT  <arrow> name . NE . 84 m" callout
--   * top-right extraction countdown ("SKIFF ETA 0:42" -> "BOARD NOW 0:18") with tick sounds in the last 10 s
--   * audio: BUILD = rising positional rumble / machinery from the breach side + growing shake; BREACH = horn; music swell via
--     Audio.setMusicIntensity

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local IT = require(Shared:WaitForChild("Data"):WaitForChild("Intensity"))

local IntensityFx = {}

local Fx: any
local Audio: any
local Juice: any
local Store: any
local Theme: any
local C: any

local ui: { [string]: any } = {}
local built = false
local touch = false
local cur: any = nil -- latest "intensity" snapshot
local buildLoopToken = 0
local relaxToken = 0
local lastTick = -1
local heavy = { bearing = 0, p = Vector3.zero, active = false }
local bannerBearing = 0

local MUSIC = { off = 0.5, calm = 0.3, build = 0.6, breach = 0.95, relax = 0.4, extract = 1.0 }

local function now(): number
	return workspace:GetServerTimeNow()
end

local function camYaw(): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 0
	end
	local look = cam.CFrame.LookVector
	return math.deg(math.atan2(look.X, -look.Z))
end

local function relDeg(bearing: number, yaw: number): number
	return (bearing - yaw + 180) % 360 - 180
end

local function fmtTime(s: number): string
	s = math.max(0, math.ceil(s))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function music(level: number, fade: number?)
	if Audio and Audio.setMusicIntensity then
		Audio.setMusicIntensity(level, fade)
	end
end

local function farPos(bearing: number, dist: number): Vector3?
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	return cam.CFrame.Position + IT.bearingVector(bearing) * dist + Vector3.new(0, -8, 0)
end

-- UI --------------------------------------------------------------------------------------------------------------
local function popGroup(parent: Instance, name: string, pos: UDim2, size: UDim2): any
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = pos
	frame.Size = size
	frame.Visible = false
	frame.Parent = parent
	local sc = Instance.new("UIScale")
	sc.Parent = frame
	return { frame = frame, scale = sc, texts = {}, token = 0 }
end

local function showPop(g: any, hold: number)
	g.token += 1
	local my = g.token
	g.frame.Visible = true
	g.scale.Scale = 1.45
	for _, l in g.texts do
		l.TextTransparency = 1
		l.TextStrokeTransparency = 1
	end
	Theme.tween(g.scale, 0.26, { Scale = 1 }, Enum.EasingStyle.Back)
	for _, l in g.texts do
		Theme.tween(l, 0.14, { TextTransparency = 0, TextStrokeTransparency = 0.35 })
	end
	task.delay(hold, function()
		if g.token ~= my then
			return
		end
		for _, l in g.texts do
			Theme.tween(l, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
		task.delay(0.45, function()
			if g.token == my then
				g.frame.Visible = false
			end
		end)
	end)
end

local function build()
	if built then
		return
	end
	built = true
	touch = Theme.isTouch()
	local gui = Theme.gui("OrbitIntensity", { DisplayOrder = 11, Insets = "CoreUISafeInsets" })
	ui.gui = gui
	local root = Theme.root(gui, "hud")
	ui.root = root

	-- threat strip (under the compass + timer pill; toasts start at y = 100)
	local strip = Theme.panel({
		Name = "ThreatStrip",
		Color = C.Navy,
		Transparency = 0.2,
		Corner = 6,
		Stroke = C.Accent,
		StrokeTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.fromOffset(touch and 330 or 440, 32),
		Visible = false,
		ClipsDescendants = true,
		Parent = root,
	})
	ui.strip = strip
	ui.stripStroke = strip:FindFirstChildOfClass("UIStroke")
	ui.stripArrow = Theme.label({
		Text = "!",
		Font = "Black",
		TextSize = 22,
		Color = C.Accent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 22, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		Parent = strip,
	})
	ui.stripText = Theme.label({
		Text = "",
		Font = "Black",
		TextSize = touch and 14 or 17,
		Rich = true,
		XAlign = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(42, 0),
		Size = UDim2.new(1, -100, 1, 0),
		Parent = strip,
	})
	ui.stripTime = Theme.label({
		Text = "",
		Font = "Black",
		TextSize = 17,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(56, 24),
		Parent = strip,
	})
	local barBg = Instance.new("Frame")
	barBg.BackgroundColor3 = C.Black
	barBg.BackgroundTransparency = 0.5
	barBg.BorderSizePixel = 0
	barBg.AnchorPoint = Vector2.new(0, 1)
	barBg.Position = UDim2.fromScale(0, 1)
	barBg.Size = UDim2.new(1, 0, 0, 4)
	barBg.Parent = strip
	ui.stripBar = Instance.new("Frame")
	ui.stripBar.BorderSizePixel = 0
	ui.stripBar.BackgroundColor3 = C.Accent
	ui.stripBar.Size = UDim2.fromScale(0, 1)
	ui.stripBar.Parent = barBg

	-- BREACH INBOUND banner
	local bg = popGroup(root, "BreachBanner", UDim2.fromScale(0.5, 0.38), UDim2.fromOffset(820, 170))
	ui.bannerG = bg
	ui.bannerTitle = Theme.label({
		Text = "BREACH INBOUND",
		Font = "Header",
		TextSize = touch and 32 or 52,
		Color = C.Danger,
		Size = UDim2.new(1, 0, 0, 64),
		Parent = bg.frame,
	})
	ui.bannerArrow = Theme.label({
		Text = "▲",
		Font = "Black",
		TextSize = touch and 34 or 44,
		Color = C.Danger,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 66),
		Size = UDim2.fromOffset(60, 50),
		Parent = bg.frame,
	})
	ui.bannerSub = Theme.label({
		Text = "",
		Font = "Body",
		TextSize = touch and 18 or 24,
		Color = C.Text,
		Position = UDim2.fromOffset(0, 122),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = bg.frame,
	})
	bg.texts = { ui.bannerTitle, ui.bannerArrow, ui.bannerSub }

	-- HEAVY CONTACT callout
	local hg = popGroup(root, "HeavyContact", UDim2.fromScale(0.5, 0.62), UDim2.fromOffset(620, 110)) -- below the crosshair
	ui.heavyG = hg
	ui.heavyTitle = Theme.label({
		Text = "HEAVY CONTACT",
		Font = "Header",
		TextSize = touch and 24 or 36,
		Color = C.Accent,
		Size = UDim2.new(1, 0, 0, 44),
		Parent = hg.frame,
	})
	ui.heavyArrow = Theme.label({
		Text = "▲",
		Font = "Black",
		TextSize = touch and 26 or 34,
		Color = C.Accent,
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0.5, -150, 0, 52),
		Size = UDim2.fromOffset(40, 40),
		Parent = hg.frame,
	})
	ui.heavySub = Theme.label({
		Text = "",
		Font = "Body",
		TextSize = touch and 16 or 20,
		Color = C.Text,
		XAlign = Enum.TextXAlignment.Left,
		Position = UDim2.new(0.5, -105, 0, 52),
		Size = UDim2.fromOffset(320, 40),
		Parent = hg.frame,
	})
	hg.texts = { ui.heavyTitle, ui.heavyArrow, ui.heavySub }

	-- extraction countdown (top right)
	local ex = Theme.panel({
		Name = "ExtractCountdown",
		Color = C.Navy,
		Transparency = 0.15,
		Corner = 8,
		Stroke = C.Accent,
		StrokeTransparency = 0.1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, touch and 60 or 76),
		Size = UDim2.fromOffset(touch and 170 or 220, touch and 64 or 80),
		Visible = false,
		Parent = root,
	})
	ui.ex = ex
	ui.exStroke = ex:FindFirstChildOfClass("UIStroke")
	ui.exLabel = Theme.label({
		Text = "SKIFF ETA",
		Font = "Black",
		TextSize = touch and 12 or 14,
		Color = C.Muted,
		Position = UDim2.fromOffset(0, 5),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = ex,
	})
	ui.exTime = Theme.label({
		Text = "0:00",
		Font = "Header",
		TextSize = touch and 26 or 36,
		Color = C.Accent,
		Position = UDim2.fromOffset(0, touch and 20 or 22),
		Size = UDim2.new(1, 0, 0, touch and 30 or 40),
		Parent = ex,
	})
	local exBg = Instance.new("Frame")
	exBg.BackgroundColor3 = C.Black
	exBg.BackgroundTransparency = 0.5
	exBg.BorderSizePixel = 0
	exBg.AnchorPoint = Vector2.new(0.5, 1)
	exBg.Position = UDim2.new(0.5, 0, 1, -7)
	exBg.Size = UDim2.new(1, -20, 0, 5)
	exBg.Parent = ex
	ui.exBar = Instance.new("Frame")
	ui.exBar.BorderSizePixel = 0
	ui.exBar.BackgroundColor3 = C.Accent
	ui.exBar.Size = UDim2.fromScale(1, 1)
	ui.exBar.Parent = exBg
end

local function stripColor(col: Color3)
	if ui.stripStroke then
		ui.stripStroke.Color = col
	end
	ui.stripArrow.TextColor3 = col
	ui.stripText.TextColor3 = col
	ui.stripBar.BackgroundColor3 = col
end

local function pulseStrip()
	if not ui.strip or not ui.strip.Visible then
		return
	end
	ui.strip.BackgroundTransparency = 0
	Theme.tween(ui.strip, 0.5, { BackgroundTransparency = 0.2 })
	if ui.stripStroke then
		ui.stripStroke.Transparency = 0
	end
end

-- Strip text / colour for the current snapshot (the per-frame step only moves the arrow, bar and clock)
local function refreshStrip()
	local s = cur
	if not ui.strip then
		return
	end
	if not s or s.state == "off" or s.state == "calm" then
		if relaxToken == 0 then
			ui.strip.Visible = false
		end
		return
	end
	if s.state == "relax" then
		-- the all-clear strip is shown by onTransition and hides itself after a few seconds
		if relaxToken == 0 then
			ui.strip.Visible = false
		end
		return
	end
	ui.strip.Visible = true
	local W = IT.Warnings[s.faction] or IT.WarningDefault
	local dirName = IT.compassShort(s.dir or 0)
	if s.extract then
		stripColor(C.Danger)
		ui.stripArrow.Text = "▲"
		ui.stripText.Text = string.format('HOLD THE PAD  <font size="14" color="#f4f6fa">WAVE %d  .  FROM %s</font>', s.wave or 0, dirName)
	elseif s.state == "breach" then
		stripColor(C.Danger)
		ui.stripArrow.Text = "▲"
		ui.stripText.Text = string.format('BREACH INBOUND  <font size="14" color="#f4f6fa">FROM %s</font>', IT.compassName(s.dir or 0))
	else -- build
		stripColor(C.Accent)
		ui.stripArrow.Text = "!"
		ui.stripArrow.Rotation = 0
		ui.stripText.Text = string.format('%s  <font size="13" color="#f4f6fa">%s</font>', W.title, W.sub)
	end
end

-- Cues ------------------------------------------------------------------------------------------------------------
local function startBuildLoop()
	buildLoopToken += 1
	local my = buildLoopToken
	task.spawn(function()
		while my == buildLoopToken and cur and cur.state == "build" do
			local s = cur
			local W = IT.Warnings[s.faction] or IT.WarningDefault
			local total = math.max((s.endsAt or 0) - (s.t0 or 0), 1)
			local p = math.clamp((now() - (s.t0 or now())) / total, 0, 1)
			if Audio then
				local pos = farPos(s.dir or 0, 260 - 110 * p)
				if pos then
					Audio.play(W.sound, pos, { volume = 0.55 + 0.6 * p, priority = 4 })
				end
			end
			if Juice then
				Juice.shake(0.2 + 0.7 * p, 0.9)
			end
			music(0.45 + 0.4 * p, 3)
			task.wait(math.max(4.2 - 2.4 * p, 1.6))
		end
	end)
end

local function showBreachBanner(title: string, sub: string, bearing: number)
	bannerBearing = bearing
	ui.bannerTitle.Text = title
	ui.bannerSub.Text = sub
	showPop(ui.bannerG, 3.6)
end

local function onTransition(old: string, new: string, s: any, extractNew: boolean)
	buildLoopToken += 1 -- stops a running BUILD loop (restarted below when needed)
	if new == "build" then
		refreshStrip()
		pulseStrip()
		music(0.5, 2)
		startBuildLoop()
	elseif new == "breach" then
		refreshStrip()
		pulseStrip()
		if extractNew then
			showBreachBanner("HOLD THE PAD", "THE BREACH WILL NOT STOP UNTIL THE " .. string.upper(Config.ShuttleName) .. " LIFTS OFF", s.dir or 0)
			ui.bannerArrow.Visible = false
		else
			ui.bannerArrow.Visible = true
			showBreachBanner("BREACH INBOUND", "FROM THE " .. IT.compassName(s.dir or 0), s.dir or 0)
		end
		if Audio then
			Audio.play2D("BreachHorn")
			local pos = farPos(s.dir or 0, 200)
			if pos then
				Audio.play("WarnRumble", pos, { volume = 1.3, priority = 5 })
			end
		end
		if Juice then
			Juice.flash(C.Danger, 0.3, 0.6)
			Juice.shake(2.2, 1.2)
		end
		music(MUSIC.breach, 1.2)
	elseif new == "relax" then
		music(MUSIC.relax, 4)
		if old == "breach" or old == "build" then
			-- brief all-clear strip
			relaxToken += 1
			local my = relaxToken
			ui.strip.Visible = true
			stripColor(C.Friendly)
			ui.stripArrow.Text = "✚"
			ui.stripArrow.Rotation = 0
			ui.stripText.Text = 'BREACH REPELLED  <font size="14" color="#f4f6fa">mop up the stragglers</font>'
			ui.stripTime.Text = ""
			ui.stripBar.Size = UDim2.fromScale(0, 1)
			pulseStrip()
			if Audio then
				Audio.play2D("ObjectiveDone", { volume = 0.5 })
			end
			task.delay(5, function()
				if relaxToken == my then
					relaxToken = 0
					refreshStrip()
				end
			end)
		end
	elseif new == "calm" then
		music(MUSIC.calm, 5)
		refreshStrip()
	else -- "off"
		music(MUSIC.off, 1)
		refreshStrip()
	end
end

local function onIntensity(s: any)
	if type(s) ~= "table" or not built then
		return
	end
	local old = cur
	cur = s
	local oldState = old and old.state or "off"
	local extractNew = s.extract == true and not (old and old.extract == true)
	if s.state ~= oldState or extractNew then
		if s.state ~= "relax" then
			relaxToken = 0 -- a new phase cancels the temporary "repelled" strip
		end
		onTransition(oldState, s.state, s, extractNew)
	else
		-- same phase, new wave / new side: refresh and ping
		local newWave = old and (s.wave ~= old.wave or s.dir ~= old.dir)
		refreshStrip()
		if newWave and s.state == "breach" then
			pulseStrip()
			if Audio then
				local pos = farPos(s.dir or 0, 190)
				if pos then
					Audio.play("WarnRumble", pos, { volume = 0.95, priority = 4 })
				end
			end
			if Juice then
				Juice.shake(0.7, 0.6)
			end
		end
	end
	if s.extract then
		music(MUSIC.extract, 1.5)
	end
end

local function onHeavy(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" or not built then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local delta = d.p - cam.CFrame.Position
	local bearing = IT.bearingOf(Vector3.new(delta.X, 0, delta.Z))
	local dist = Vector3.new(delta.X, 0, delta.Z).Magnitude
	heavy.bearing = bearing
	heavy.p = d.p
	heavy.active = true
	local behemoth = d.class == "behemoth"
	ui.heavyTitle.Text = if behemoth then "BEHEMOTH CONTACT" else "HEAVY CONTACT"
	local col = if behemoth then C.Danger else C.Accent
	ui.heavyTitle.TextColor3 = col
	ui.heavyArrow.TextColor3 = col
	ui.heavySub.Text = string.format("%s  .  %s  .  %d m", string.upper(tostring(d.name or "UNKNOWN")), IT.compassShort(bearing), math.floor(dist + 0.5))
	showPop(ui.heavyG, 3.0)
	if Audio then
		Audio.play2D("HeavyContact")
	end
	if Juice then
		Juice.shake(behemoth and 1.2 or 0.7, 0.5)
	end
end

-- Per frame ---------------------------------------------------------------------------------------------------------
local function stepExtract(t: number)
	local m = Store.get("mission")
	local ex = m and m.state == "Extract" and m.extract
	if not ex or not ex.eta then
		ui.ex.Visible = false
		lastTick = -1
		return
	end
	local label, left, total, col
	if ex.window and t < ex.window then
		label, left, total, col = "BOARD NOW", ex.window - t, Config.ExtractWindow, C.Friendly
	elseif t < ex.eta then
		label, left, total = string.upper(Config.ShuttleName) .. " ETA", ex.eta - t, math.max(Config.ExtractEta, ex.eta - t)
		col = if left <= 10 then C.Danger else C.Accent
	elseif not ex.window then
		label, left, total, col = string.upper(Config.ShuttleName) .. " DESCENDING", 0, 1, C.Accent
	else
		ui.ex.Visible = false
		return
	end
	ui.ex.Visible = true
	ui.exLabel.Text = label
	ui.exTime.Text = if label:find("DESCENDING") then "..." else fmtTime(left)
	ui.exTime.TextColor3 = col
	ui.exBar.BackgroundColor3 = col
	ui.exBar.Size = UDim2.fromScale(math.clamp(left / math.max(total, 1), 0, 1), 1)
	if ui.exStroke then
		ui.exStroke.Color = col
	end
	-- last 10 s of the ETA: a tick per second
	if t < ex.eta and left <= 10 then
		local sec = math.ceil(left)
		if sec ~= lastTick then
			lastTick = sec
			if Audio then
				Audio.play2D(if sec <= 3 then "UIClick" else "DialTick", { volume = 0.9 })
			end
			if Juice and sec <= 3 then
				Juice.shake(0.4, 0.3)
			end
		end
	end
end

local function step(_dt: number)
	if not built then
		return
	end
	local t = now()
	local yaw = camYaw()
	local s = cur
	if ui.strip.Visible and s and (s.state == "breach") then
		ui.stripArrow.Rotation = relDeg(s.dir or 0, yaw)
	end
	if s and ui.strip.Visible and (s.state == "build" or s.state == "breach") and (s.endsAt or 0) > 0 then
		local total = math.max(s.endsAt - s.t0, 1)
		local left = math.max(s.endsAt - t, 0)
		ui.stripTime.Text = fmtTime(left)
		ui.stripBar.Size = UDim2.fromScale(math.clamp(if s.state == "build" then (t - s.t0) / total else left / total, 0, 1), 1)
	elseif s and s.extract and ui.strip.Visible then
		ui.stripTime.Text = ""
		ui.stripBar.Size = UDim2.fromScale(0, 1)
	end
	if ui.bannerG.frame.Visible and ui.bannerArrow.Visible then
		ui.bannerArrow.Rotation = relDeg(bannerBearing, yaw)
	end
	if ui.heavyG.frame.Visible and heavy.active then
		local cam = workspace.CurrentCamera
		if cam then
			local d = heavy.p - cam.CFrame.Position
			ui.heavyArrow.Rotation = relDeg(IT.bearingOf(Vector3.new(d.X, 0, d.Z)), yaw)
		end
	end
	local mission = Store.get("mission")
	local inMission = mission and (mission.state == "Active" or mission.state == "Extract")
	ui.gui.Enabled = inMission == true
	stepExtract(t)
end

-- Init --------------------------------------------------------------------------------------------------------------
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

function IntensityFx.init(fx: any, audio: any, juice: any)
	Fx, Audio, Juice = fx, audio, juice
	local root = findClientRoot()
	if not root then
		warn("[IntensityFx] client root not found")
		return
	end
	Store = require(root.Store)
	Theme = require((root :: any).UI.Theme)
	C = Theme.C

	Fx.register("HeavyContact", onHeavy)

	task.spawn(function()
		-- the GUI needs PlayerGui (yields until it exists); Fx.init must not block on it
		build()
		RunService.RenderStepped:Connect(step)
		Store.on("intensity", onIntensity)
	end)
end

return IntensityFx
