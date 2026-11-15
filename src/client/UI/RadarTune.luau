-- Radar side objective, client side (server/Objectives/SideRadar.luau).
--   Fx "RadarTune" { state = "open", obj, t0, period, c, h, need, timeout }   opens the tune panel: a needle sweeps 0..1..0
--                  over `period` s from t0 (workspace:GetServerTimeNow time); tap while it is in the green band (c +- h).
--                  Each tap inside the band is sent as Action "minigame"(obj, { hit = serverTime }); the server answers
--                  { state = "hit", n } | "reject" | "done" | { state = "close", why }. A tap outside the band locks
--                  input for MISS_LOCK s (it only costs time). Cancel sends (obj, { cancel = true }).
--   Fx "RadarPing" { blips = { {p, n, src?} }, t, o }   forwards the enemy blips to UI/Compass and plays a ping.
-- Input: Interact (E) / Space / gamepad A or R2 / the TAP button (touch and mouse). Cancel: Backspace / gamepad B / CANCEL.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Config = require(Shared.Config)
local Compass = require(script.Parent.Compass)
local Store = require(script.Parent.Parent.Store)

local RadarTune = {}

local MISS_LOCK = 0.6
local TRACK_W = 380
local GREEN = Color3.fromRGB(80, 255, 140)

local Audio: any = nil
local localPlayer = Players.LocalPlayer
local active: any = nil -- the open panel: { close = fn, onServer = fn }

local function play2D(key: string)
	if Audio and Audio.play2D then
		pcall(Audio.play2D, key)
	end
end

local function make(class: string, props: { [string]: any }, parent: Instance?): any
	local i = Instance.new(class)
	for k, v in props do
		i[k] = v
	end
	if parent then
		i.Parent = parent
	end
	return i
end

local function sweepAt(t: number, t0: number, period: number): number
	local u = ((t - t0) / period) % 1
	return 1 - math.abs(2 * u - 1)
end

local function open(data: any)
	if active then
		active.close(false)
	end
	local objId: string = data.obj or "RADAR"
	local t0: number = tonumber(data.t0) or Workspace:GetServerTimeNow()
	local period: number = math.max(tonumber(data.period) or 1.7, 0.5)
	local c: number = tonumber(data.c) or 0.5
	local h: number = tonumber(data.h) or 0.1
	local need: number = math.clamp(tonumber(data.need) or 3, 1, 6)
	local timeout: number = tonumber(data.timeout) or 15
	local endsAt = os.clock() + timeout

	local pg = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local gui = make("ScreenGui", { Name = "RadarTune", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 60, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, pg)
	local canvas = make("Frame", {
		Name = "Canvas",
		Size = UDim2.fromOffset(440, 236),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.6),
		BackgroundColor3 = Config.Colors.Panel,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 12) }, canvas)
	make("UIStroke", { Color = GREEN, Thickness = 2 }, canvas)
	local uiScale = make("UIScale", {}, canvas)
	local conns: { RBXScriptConnection } = {}
	local function fit()
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		uiScale.Scale = math.clamp(math.min(vp.X / 520, vp.Y / 420), 0.6, 1.3)
	end
	fit()
	local cam = Workspace.CurrentCamera
	if cam then
		conns[#conns + 1] = cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end

	make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(300, 28), Position = UDim2.fromOffset(16, 10), Font = Enum.Font.Michroma, Text = "TUNE THE DISH", TextColor3 = GREEN, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left }, canvas)
	make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(408, 20), Position = UDim2.fromOffset(16, 40), Font = Enum.Font.GothamBold, Text = string.format("Tap when the needle is in the green band (%d hits)", need), TextColor3 = Config.Colors.Muted, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left }, canvas)

	-- sweep track
	local track = make("Frame", { Size = UDim2.fromOffset(TRACK_W, 30), Position = UDim2.fromOffset(30, 70), BackgroundColor3 = Color3.fromRGB(16, 22, 30), BorderSizePixel = 0, ClipsDescendants = true }, canvas)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, track)
	local band = make("Frame", {
		Size = UDim2.fromScale(h * 2, 1),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(c, 0),
		BackgroundColor3 = GREEN,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
	}, track)
	local needle = make("Frame", { Size = UDim2.new(0, 4, 1, 6), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = Config.Colors.Text, BorderSizePixel = 0, ZIndex = 3 }, track)

	-- hit lamps
	local lamps: { Frame } = {}
	for i = 1, need do
		local x = 220 + (i - (need + 1) / 2) * 34
		local lamp = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(x, 120), BackgroundColor3 = Color3.fromRGB(70, 74, 86), BorderSizePixel = 0 }, canvas)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, lamp)
		lamps[i] = lamp
	end
	local msg = make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(408, 20), Position = UDim2.fromOffset(16, 134), Font = Enum.Font.GothamBold, Text = "", TextColor3 = Config.Colors.Gold, TextSize = 16 }, canvas)
	local timeBar = make("Frame", { Size = UDim2.fromOffset(TRACK_W, 4), Position = UDim2.fromOffset(30, 104), BackgroundColor3 = Config.Colors.Muted, BorderSizePixel = 0 }, canvas)

	local tapBtn = make("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(220, 60),
		Position = UDim2.fromOffset(220, 162),
		BackgroundColor3 = GREEN,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBlack,
		Text = "TAP  [E]",
		TextColor3 = Color3.fromRGB(20, 20, 26),
		TextSize = 26,
		AutoButtonColor = true,
	}, canvas)
	make("UICorner", { CornerRadius = UDim.new(0, 12) }, tapBtn)
	local cancelBtn = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(84, 30),
		Position = UDim2.fromOffset(428, 10),
		BackgroundColor3 = Color3.fromRGB(50, 58, 74),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "CANCEL",
		TextColor3 = Config.Colors.Text,
		TextSize = 14,
	}, canvas)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, cancelBtn)

	local confirmed = 0 -- server-confirmed hits
	local pending = 0 -- taps sent, not answered yet
	local lockedUntil = 0
	local closed = false
	local finished = false

	local function paintLamps()
		for i, lamp in lamps do
			lamp.BackgroundColor3 = if i <= confirmed then GREEN elseif i <= confirmed + pending then Config.Colors.Gold else Color3.fromRGB(70, 74, 86)
		end
	end

	local function close(sendCancel: boolean)
		if closed then
			return
		end
		closed = true
		if active and active.gui == gui then
			active = nil
		end
		ContextActionService:UnbindAction("RadarTuneTap")
		ContextActionService:UnbindAction("RadarTuneCancel")
		for _, cn in conns do
			cn:Disconnect()
		end
		if sendCancel and not finished then
			Net.event("Action"):FireServer("minigame", objId, { cancel = true })
		end
		gui:Destroy()
		pcall(Store.set, "menuOpen", nil)
	end
	-- free the mouse (the camera respects menuOpen) so TAP / CANCEL can be clicked
	pcall(Store.set, "menuOpen", true)

	local function tap()
		if closed or finished then
			return
		end
		local now = os.clock()
		if now < lockedUntil then
			return
		end
		local st = Workspace:GetServerTimeNow()
		local p = sweepAt(st, t0, period)
		if math.abs(p - c) <= h then
			lockedUntil = now + 0.25
			pending += 1
			paintLamps()
			play2D(if math.abs(p - c) <= h * 0.4 then "DialPerfect" else "DialTick")
			msg.Text = ""
			Net.event("Action"):FireServer("minigame", objId, { hit = st })
		else
			lockedUntil = now + MISS_LOCK
			play2D("UIClick")
			msg.Text = "MISSED - WAIT FOR THE BAND"
			msg.TextColor3 = Config.Colors.Danger
			band.BackgroundColor3 = Config.Colors.Danger
			task.delay(MISS_LOCK, function()
				if not closed then
					band.BackgroundColor3 = GREEN
				end
			end)
		end
	end

	local function onServer(d: any)
		if closed then
			return
		end
		if d.state == "hit" then
			confirmed = math.max(confirmed, tonumber(d.n) or confirmed + 1)
			pending = math.max(pending - 1, 0)
			paintLamps()
		elseif d.state == "reject" then
			pending = math.max(pending - 1, 0)
			paintLamps()
			msg.Text = "SIGNAL SLIPPED - TRY AGAIN"
			msg.TextColor3 = Config.Colors.Danger
		elseif d.state == "done" then
			finished = true
			confirmed = need
			pending = 0
			paintLamps()
			msg.Text = "SIGNAL LOCKED"
			msg.TextColor3 = GREEN
			task.delay(0.8, close, false)
		elseif d.state == "close" then
			finished = true
			msg.Text = if type(d.why) == "string" and d.why ~= "close" then d.why else ""
			msg.TextColor3 = Config.Colors.Danger
			task.delay(if msg.Text ~= "" then 1.2 else 0, close, false)
		end
	end

	tapBtn.Activated:Connect(tap)
	cancelBtn.Activated:Connect(function()
		close(true)
	end)
	ContextActionService:BindActionAtPriority("RadarTuneTap", function(_, state)
		if state == Enum.UserInputState.Begin then
			tap()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.E, Enum.KeyCode.Space, Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonR2)
	ContextActionService:BindActionAtPriority("RadarTuneCancel", function(_, state)
		if state == Enum.UserInputState.Begin then
			close(true)
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)

	conns[#conns + 1] = RunService.RenderStepped:Connect(function()
		local p = sweepAt(Workspace:GetServerTimeNow(), t0, period)
		needle.Position = UDim2.fromScale(p, 0.5)
		local inside = math.abs(p - c) <= h
		needle.BackgroundColor3 = if inside then GREEN else Config.Colors.Text
		local left = endsAt - os.clock()
		timeBar.Size = UDim2.fromOffset(TRACK_W * math.clamp(left / timeout, 0, 1), 4)
		if left < -2 then
			close(false) -- the server's own timeout normally closes it first
		end
		local ch = localPlayer.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			close(true)
		end
	end)

	active = { gui = gui, close = close, onServer = onServer }
end

function RadarTune.init(Fx: any, audio: any)
	Audio = audio
	if not Fx or not Fx.register then
		return
	end
	Fx.register("RadarTune", function(d: any)
		if type(d) ~= "table" then
			return
		end
		if d.state == "open" then
			open(d)
		elseif active then
			active.onServer(d)
		end
	end)
	Fx.register("RadarPing", function(d: any)
		if type(d) ~= "table" or type(d.blips) ~= "table" then
			return
		end
		pcall(Compass.ping, d.blips, tonumber(d.t) or 6)
		play2D("DialTick")
	end)
end

return RadarTune
