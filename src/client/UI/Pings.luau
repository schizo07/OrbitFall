-- Squad ping. Look at something and press the ping key: every player sees a marker there for LIFE seconds, plus a radio
-- line in the event feed and a pip on the compass tape. One ping per player; a new one replaces the old.
--   * input: Input action "Ping" (middle mouse), gamepad D-pad Right (only while the Uplink dial / LB is not held,
--     same as the stim on D-pad Left in Fx/VitalsFx), touch: hold a finger still on the camera-drag area (right 55 %)
--     for HOLD_TIME s, pings where the crosshair points
--   * pings an enemy: the marker follows it ("S2: BULWARK") and goes away when it dies; ground: "S1: HERE"
--   * server: server/PingService (rate limit, distance, enemy exists) relays Net "Ping" to everybody
--   * marker: BillboardGui (always on top) in the pinger's squad colour + distance readout; Compass.setExtra pip
-- Studio A/B "SQUAD PING" (Variants): workspace attribute Feel_Ping = "on" enables sending. Off (default): the input
-- does nothing and nothing is sent. Pings from other players are always drawn.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local Style = require(script.Parent.HudStyle)
local Compass = require(script.Parent.Compass)
local EventFeed = require(script.Parent.EventFeed)
local Store = require(script.Parent.Parent.Store)
local Input = require(script.Parent.Parent.Input)

local Pings = {}

local LIFE = 8 -- seconds a ping stays
local FADE = 0.7 -- fade-out at the end
local COOLDOWN = 1.2 -- client-side, matches the server's rate limit
local MAX_RANGE = 360 -- crosshair trace length (the server accepts up to 400 studs from the player)
local HOLD_TIME = 0.45 -- touch long press
local HOLD_SLOP = 12 -- px the finger may move during the long press
local LOOK_X = 0.45 -- touch: right 55 % of the screen is the camera-drag area (CameraController)
local ACTIVE = { Active = true, Extract = true }

local player = Players.LocalPlayer
local aimPoint: ((number, number?) -> (Vector3, RaycastResult?))? = nil
local audio: any = nil
local lastSent = -100
local pings: { [number]: any } = {} -- userId -> ping record
local presses: { [InputObject]: Vector2 } = {}

local function enabled(): boolean
	return workspace:GetAttribute("Feel_Ping") == "on"
end

local function missionState(): string
	local m = Store.get("mission")
	return type(m) == "table" and m.state or "Ship"
end

-- Marker ----------------------------------------------------------------------------------------------------------------
local function remove(uid: number)
	local pg = pings[uid]
	if not pg then
		return
	end
	pings[uid] = nil
	Compass.setExtra(tostring(uid), nil)
	pg.gui:Destroy()
	pg.att:Destroy()
end

local function findEnemy(id: number): Model?
	local folder = workspace:FindFirstChild("Enemies")
	if not folder then
		return nil
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("EnemyId") == id then
			return m
		end
	end
	return nil
end

local function create(d: any)
	local uid: number = d.u
	remove(uid)
	local cs = Style.callsign(uid)
	local isEnemy = type(d.e) == "number"
	local model = if isEnemy then findEnemy(d.e) else nil
	local rootPart = model and model.PrimaryPart
	local pos: Vector3 = d.p
	local off = 0
	if model and rootPart then
		local cf, size = model:GetBoundingBox()
		off = cf.Position.Y + size.Y / 2 + 1.5 - rootPart.Position.Y
		pos = rootPart.Position + Vector3.new(0, off, 0)
	end

	local att = Instance.new("Attachment")
	att.Name = "Ping_" .. uid
	att.WorldPosition = pos
	att.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "Ping_" .. uid
	gui.Adornee = att
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Size = UDim2.fromOffset(150, 76)
	gui.StudsOffset = if model then Vector3.zero else Vector3.new(0, 1.5, 0)
	gui.Parent = player:WaitForChild("PlayerGui")

	local group = Instance.new("CanvasGroup")
	group.BackgroundTransparency = 1
	group.Size = UDim2.fromScale(1, 1)
	group.Parent = gui

	local label = if isEnemy and type(d.n) == "string" then d.n else "HERE"
	Style.label({
		Name = "Label",
		Text = string.format("%s: %s", cs.tag, label),
		TextSize = 15,
		Color = cs.color,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 16),
		Parent = group,
	})
	local dist = Style.label({
		Name = "Dist",
		Text = "",
		TextSize = 13,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = group,
	})
	Style.glyph(if isEnemy then "diamondHollow" else "down", {
		Size = 16,
		Color = cs.color,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 38),
		Parent = group,
	})

	pings[uid] = {
		gui = gui,
		att = att,
		group = group,
		dist = dist,
		born = os.clock(),
		pos = pos,
		model = model,
		root = rootPart,
		off = off,
		color = cs.color,
		metres = -1,
	}
	Compass.setExtra(tostring(uid), pos, cs.color)

	local line = if isEnemy and type(d.n) == "string" then "CONTACT - " .. d.n else "OVER HERE"
	EventFeed.push(string.format("%s: %s", cs.tag, line), cs.color, "bark")
	if audio then
		audio.play2D("UIClick", { pitch = 1.6 })
	end
end

local function step()
	local cam = workspace.CurrentCamera
	if not cam or next(pings) == nil then
		return
	end
	local now = os.clock()
	local camPos = cam.CFrame.Position
	for uid, pg in pings do
		local age = now - pg.born
		if age >= LIFE then
			remove(uid)
			continue
		end
		if pg.model then
			-- follows the enemy; gone (killed or despawned) = marker gone
			if not pg.model:IsDescendantOf(workspace) or not pg.root or not pg.root:IsDescendantOf(workspace) then
				remove(uid)
				continue
			end
			pg.pos = pg.root.Position + Vector3.new(0, pg.off, 0)
			pg.att.WorldPosition = pg.pos
		end
		Compass.setExtra(tostring(uid), pg.pos, pg.color)
		local metres = math.floor((pg.pos - camPos).Magnitude + 0.5)
		if metres ~= pg.metres then
			pg.metres = metres
			pg.dist.Text = string.format("%d m", metres)
		end
		if age > LIFE - FADE then
			pg.group.GroupTransparency = (age - (LIFE - FADE)) / FADE
		end
	end
end

-- Sending ---------------------------------------------------------------------------------------------------------------
local function enemyIdOf(inst: Instance?): number?
	while inst and inst ~= workspace do
		local v = inst:GetAttribute("EnemyId")
		if type(v) == "number" then
			return v
		end
		inst = inst.Parent
	end
	return nil
end

local function sendPing()
	if not enabled() or not aimPoint then
		return
	end
	if not ACTIVE[missionState()] or Store.get("menuOpen") == true then
		return
	end
	local me = Store.get("me")
	if type(me) == "table" and me.alive == false then
		return
	end
	local now = os.clock()
	if now - lastSent < COOLDOWN then
		return
	end
	local c = player.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local p, res = aimPoint(MAX_RANGE, 0)
	if not res then
		return -- sky / out of range
	end
	if (p - root.Position).Magnitude > 395 then
		return
	end
	lastSent = now
	Net.event("Ping"):FireServer(p, enemyIdOf(res.Instance))
end

-- Init ------------------------------------------------------------------------------------------------------------------
-- aim = WeaponController.aimPoint (crosshair trace)
function Pings.init(aim: (number, number?) -> (Vector3, RaycastResult?))
	aimPoint = aim
	local okA, a = pcall(function()
		return require(script.Parent.Parent.Audio)
	end)
	if okA then
		audio = a
	end

	Net.event("Ping").OnClientEvent:Connect(function(d: any)
		if type(d) ~= "table" or type(d.u) ~= "number" or typeof(d.p) ~= "Vector3" then
			return
		end
		create(d)
	end)
	RunService.RenderStepped:Connect(step)

	Store.on("mission", function()
		if not ACTIVE[missionState()] then
			for uid in pings do
				remove(uid)
			end
		end
	end)

	Input.on("Ping", function(isDown)
		if isDown then
			sendPing()
		end
	end)

	-- gamepad D-pad Right, only while the Uplink dial (LB) is not held (the D-pad types call-in codes then)
	UserInputService.InputBegan:Connect(function(io)
		if io.KeyCode == Enum.KeyCode.DPadRight and not Input.isDown("Dial") then
			Input.set("Ping", true)
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if io.KeyCode == Enum.KeyCode.DPadRight then
			Input.set("Ping", false)
		end
	end)

	-- touch long press on the camera-drag area
	UserInputService.TouchStarted:Connect(function(io, gp)
		local cam = workspace.CurrentCamera
		if gp or not cam or not enabled() or io.Position.X <= cam.ViewportSize.X * LOOK_X then
			return
		end
		presses[io] = Vector2.new(io.Position.X, io.Position.Y)
		task.delay(HOLD_TIME, function()
			local start = presses[io]
			if not start then
				return
			end
			presses[io] = nil
			local cur = Vector2.new(io.Position.X, io.Position.Y)
			if (cur - start).Magnitude < HOLD_SLOP and next(presses) == nil then
				sendPing()
			end
		end)
	end)
	UserInputService.TouchEnded:Connect(function(io)
		presses[io] = nil
	end)
end

return Pings
