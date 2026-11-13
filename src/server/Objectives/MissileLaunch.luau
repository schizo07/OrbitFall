-- Main objective "Missile Launch" (docs/spec.md §7). Five steps:
--  1 retrieve launch codes (guarded)  2 start the generator + 30 s defend  3 trajectory mini-game at the console
--  4 two levers within a window open the silo doors  5 LAUNCH (10 s countdown, missile flies)
-- Receives `ctx` from ObjectiveService; returns a controller { entry, stop, onMinigame }.

local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local MissileLaunch = {}

local STEP_TEXTS = {
	"Retrieve the launch codes from the downed courier",
	"Start the generator",
	"Set the missile trajectory at the console",
	"Open the silo doors (pull both levers)",
	"Launch the missile",
}

local GEN_DURATION = 30
local LAUNCH_COUNTDOWN = 10
local MISSILE_RISE = 900
local MISSILE_TIME = 9 -- climb after the ignition hold (quad-in with a slight cubic arc, see WorldFx missilePath: ~45 studs after 2 s, so it stays in frame, then a bright streak high in the sky)
local IGNITION_HOLD = 1.5

local DARK = Color3.fromRGB(44, 48, 58)
local STEEL = Color3.fromRGB(110, 116, 128)
local HAZARD = Color3.fromRGB(255, 190, 40)
local WARM_LIGHT = Color3.fromRGB(255, 215, 170) -- lights that reach the sand stay warm/neutral (teal tinted the ground green)

function MissileLaunch.start(ctx: any, onComplete: () -> ()): any
	local map = ctx.map
	local S = ctx.S
	local root = Instance.new("Folder")
	root.Name = "Missile"
	root.Parent = ctx.folder

	local entry = ctx.newEntry({ id = "MISSILE", title = "Missile Launch", main = true, steps = STEP_TEXTS })
	local ctl: any = { entry = entry }
	local step = 1
	local alive = true

	local codesCF: CFrame = map.sites.codes
	local genCF: CFrame = map.sites.generator
	local conCF: CFrame = map.sites.console
	local siloCF: CFrame = map.sites.silo
	local leverACF: CFrame = map.sites.leverA
	local leverBCF: CFrame = map.sites.leverB

	-- spawn a mesh set piece scaled up and re-seated so its bounding-box bottom rests on the ground
	-- (positions must be read from the returned piece, i.e. after scaling; piece.cf is the re-seated pivot)
	local function spawnScaled(key: string, baseCF: CFrame, radius: number, parent: Instance, name: string, scale: number): any
		local gcf = SetPieces.groundCF(map, baseCF, radius * scale)
		local piece = SetPieces.spawn(S, key, gcf, parent, { name = name, scale = scale })
		if piece then
			local bb, size = piece.model:GetBoundingBox()
			local dy = gcf.Position.Y - (bb.Position.Y - size.Y / 2)
			if math.abs(dy) > 0.01 then
				piece.model:PivotTo(piece.model:GetPivot() + Vector3.new(0, dy, 0))
			end
			piece.cf = piece.model:GetPivot()
		end
		return piece
	end

	local prompts: { [number]: { ProximityPrompt } } = {}
	local leverMarker: Vector3? = nil -- mesh silo: the levers stand at the silo, not at the map's leverA/leverB sites
	local function refreshPrompts()
		for i, list in prompts do
			for _, pp in list do
				if pp.Parent then
					pp.Enabled = (i == step) and (not pp:GetAttribute("Locked"))
				end
			end
		end
	end

	local function setStepMarker()
		local pos
		if step == 1 then
			pos = codesCF.Position
		elseif step == 2 then
			pos = genCF.Position
		elseif step == 3 then
			pos = conCF.Position
		elseif step == 4 then
			pos = leverMarker or (leverACF.Position + leverBCF.Position) / 2
		elseif step == 5 then
			pos = ctl.launchPos or siloCF.Position
		end
		ctx.setMarker(entry, pos)
	end

	local function finishStep(i: number, text: string?)
		ctx.completeStep(entry, i, text)
		step = i + 1
		setStepMarker()
		refreshPrompts()
	end

	-- ============================================================ 1. courier wreck
	local caseGlow: Part? = nil
	local case: BasePart
	local function buildPrimitiveWreck()
		local f = Instance.new("Model")
		f.Name = "CourierWreck"
		f.Parent = root
		local b = codesCF
		local hullCol = Color3.fromRGB(88, 94, 106)
		ctx.part(f, Vector3.new(14, 5, 8), b * CFrame.new(0, 2.6, 0) * CFrame.Angles(math.rad(11), math.rad(8), math.rad(-9)), hullCol, Enum.Material.Metal)
		ctx.part(f, Vector3.new(7, 4, 7), b * CFrame.new(9, 1.4, 3) * CFrame.Angles(math.rad(-14), math.rad(40), math.rad(16)), hullCol, Enum.Material.CorrodedMetal)
		ctx.part(f, Vector3.new(0.8, 7, 5), b * CFrame.new(-6, 5, -2) * CFrame.Angles(math.rad(6), 0, math.rad(32)), Color3.fromRGB(170, 70, 50), Enum.Material.Metal)
		ctx.part(f, Vector3.new(5, 2, 4), b * CFrame.new(-10, 0.8, 5) * CFrame.Angles(0, math.rad(25), math.rad(10)), Color3.fromRGB(60, 62, 70), Enum.Material.Metal, { CanCollide = false })
		-- emergency stripe + scorch
		ctx.glow(f, Vector3.new(10, 0.4, 0.4), b * CFrame.new(0, 4.8, -3.7) * CFrame.Angles(math.rad(11), math.rad(8), math.rad(-9)), HAZARD)
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
		smoke.Rate = 10
		smoke.Lifetime = NumberRange.new(3, 5)
		smoke.Speed = NumberRange.new(4, 7)
		smoke.SpreadAngle = Vector2.new(15, 15)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 9) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		smoke.Color = ColorSequence.new(Color3.fromRGB(60, 58, 60))
		smoke.EmissionDirection = Enum.NormalId.Top
		local smokeAnchor = ctx.part(f, Vector3.new(1, 1, 1), b * CFrame.new(2, 5, 0), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false })
		smoke.Parent = smokeAnchor
		-- the code case
		case = ctx.part(f, Vector3.new(3.2, 2, 2.2), b * CFrame.new(5, 1.1, -5) * CFrame.Angles(0, math.rad(20), 0), Color3.fromRGB(40, 44, 54), Enum.Material.Metal, { Name = "CodeCase" })
		caseGlow = ctx.glow(f, Vector3.new(3.3, 0.35, 2.3), case.CFrame * CFrame.new(0, 0.6, 0), Config.Colors.Friendly)
		ctx.light(caseGlow, WARM_LIGHT, 14, 1.2)
	end
	do
		local wreck = SetPieces.spawn(S, "courier_wreck", SetPieces.groundCF(map, codesCF, 7), root, { name = "CourierWreck", drop = { "Ground" } })
		if wreck and wreck.parts.DataCase then
			case = wreck.parts.DataCase
			ctx.light(case, WARM_LIGHT, 14, 1.2)
			local smoke = Instance.new("ParticleEmitter")
			smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
			smoke.Rate = 10
			smoke.Lifetime = NumberRange.new(3, 5)
			smoke.Speed = NumberRange.new(4, 7)
			smoke.SpreadAngle = Vector2.new(15, 15)
			smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 9) })
			smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
			smoke.Color = ColorSequence.new(Color3.fromRGB(60, 58, 60))
			smoke.EmissionDirection = Enum.NormalId.Top
			local smokeAnchor = ctx.part(wreck.model, Vector3.new(1, 1, 1), wreck.cf * CFrame.new(1.8, 6.5, 0.4), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
			smoke.Parent = smokeAnchor
		else
			buildPrimitiveWreck()
		end
		local hl = Instance.new("Highlight")
		hl.FillTransparency = 1
		hl.OutlineColor = Config.Colors.Friendly
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = case
		prompts[1] = {
			ctx.prompt(case, {
				action = "Retrieve",
				object = "Launch Codes",
				hold = 2,
				distance = 10,
				onTrigger = function()
					if step ~= 1 then
						return
					end
					case:Destroy()
					if caseGlow then
						caseGlow:Destroy()
					end
					ctx.sound("ObjectiveDone", codesCF.Position)
					finishStep(1, "Launch codes secured. Head to the generator.")
				end,
			}),
		}
	end

	-- guard wave when players approach the wreck
	task.spawn(function()
		while alive and ctx.alive() and step == 1 do
			if #ctx.playersNear(codesCF.Position, 60) > 0 then
				ctx.notify("Hostiles guarding the courier wreck!", Config.Colors.Danger)
				ctx.wave(codesCF.Position, 14)
				break
			end
			task.wait(0.5)
		end
	end)

	-- ============================================================ 2. generator
	local blades: { Part } = {}
	local statusLamp: BasePart
	local exhaust: { ParticleEmitter } = {}
	local genRunning = false
	local genSpeed = 0
	local genPromptPart: BasePart
	local corePart: BasePart? = nil -- mesh generator: "Core" glow pulses while it runs
	local coreTween: Tween? = nil
	local function startCorePulse(period: number)
		if not corePart then
			return
		end
		if coreTween then
			coreTween:Cancel()
		end
		corePart.Transparency = 0
		coreTween = SetPieces.pulse(corePart, "Transparency", 0, 0.45, period)
	end
	local function buildPrimitiveGenerator()
		local f = Instance.new("Model")
		f.Name = "Generator"
		f.Parent = root
		local b = genCF
		ctx.part(f, Vector3.new(16, 8, 9), b * CFrame.new(0, 4, 0), Color3.fromRGB(84, 90, 100), Enum.Material.Metal)
		ctx.part(f, Vector3.new(16.4, 1, 9.4), b * CFrame.new(0, 8.4, 0), DARK, Enum.Material.DiamondPlate)
		for _, x in { -4, 4 } do
			ctx.cyl(f, 5.4, 3, b * CFrame.new(x, 10, 0), DARK, Enum.Material.Metal)
			local blade = ctx.part(f, Vector3.new(7, 0.3, 1.1), b * CFrame.new(x, 11.7, 0), Color3.fromRGB(180, 186, 196), Enum.Material.Metal, { CanCollide = false })
			blade:SetAttribute("Base", b * CFrame.new(x, 11.7, 0))
			blades[#blades + 1] = blade
			local blade2 = ctx.part(f, Vector3.new(1.1, 0.3, 7), b * CFrame.new(x, 11.72, 0), Color3.fromRGB(180, 186, 196), Enum.Material.Metal, { CanCollide = false })
			blade2:SetAttribute("Base", b * CFrame.new(x, 11.72, 0))
			blades[#blades + 1] = blade2
		end
		for _, x in { -6, 6 } do
			local pipe = ctx.cyl(f, 1.8, 11, b * CFrame.new(x, 6, 5.6), STEEL, Enum.Material.Metal)
			local em = Instance.new("ParticleEmitter")
			em.Texture = "rbxasset://textures/particles/smoke_main.dds"
			em.Rate = 22
			em.Lifetime = NumberRange.new(2, 3.5)
			em.Speed = NumberRange.new(6, 10)
			em.SpreadAngle = Vector2.new(10, 10)
			em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 7) })
			em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
			em.Color = ColorSequence.new(Color3.fromRGB(110, 106, 104))
			em.EmissionDirection = Enum.NormalId.Top
			em.Enabled = false
			em.Parent = pipe
			exhaust[#exhaust + 1] = em
		end
		-- control panel with the start prompt
		local panel = ctx.part(f, Vector3.new(5, 3.4, 0.8), b * CFrame.new(0, 3.2, -4.8), DARK, Enum.Material.Metal, { Name = "ControlPanel" })
		statusLamp = ctx.glow(f, Vector3.new(1.4, 1.4, 0.4), b * CFrame.new(0, 3.6, -5.3), Color3.fromRGB(255, 60, 50))
		ctx.light(statusLamp, Color3.fromRGB(255, 60, 50), 22, 1.4)
		ctx.glow(f, Vector3.new(3.6, 0.4, 0.3), b * CFrame.new(0, 2.2, -5.3), Config.Colors.Accent)
		-- ground cables
		for i = 1, 3 do
			ctx.part(f, Vector3.new(0.6, 0.5, 11), b * CFrame.new(-4 + i * 3, 0.3, -11) * CFrame.Angles(0, math.rad(i * 8 - 16), 0), Color3.fromRGB(30, 30, 34), Enum.Material.Plastic, { CanCollide = false })
		end
		genPromptPart = panel
	end
	do
		local GEN_SCALE = 1.6
		local gen = spawnScaled("generator", genCF, 3, root, "Generator", GEN_SCALE)
		if gen and gen.parts.Switch and gen.parts.Core then
			genPromptPart = gen.parts.Switch
			corePart = gen.parts.Core
			statusLamp = gen.parts.Core
			statusLamp.Color = Color3.fromRGB(255, 60, 50) -- off: red until it spins up
			ctx.light(statusLamp, Color3.fromRGB(255, 80, 60), 22, 1.4)
			local vent = ctx.part(gen.model, Vector3.new(1, 1, 1), gen.cf * CFrame.new(-1.2 * GEN_SCALE, 5.2 * GEN_SCALE, 0), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
			local em = Instance.new("ParticleEmitter")
			em.Texture = "rbxasset://textures/particles/smoke_main.dds"
			em.Rate = 22
			em.Lifetime = NumberRange.new(2, 3.5)
			em.Speed = NumberRange.new(6, 10)
			em.SpreadAngle = Vector2.new(10, 10)
			em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 7) })
			em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
			em.Color = ColorSequence.new(Color3.fromRGB(110, 106, 104))
			em.EmissionDirection = Enum.NormalId.Top
			em.Enabled = false
			em.Parent = vent
			exhaust[#exhaust + 1] = em
		else
			buildPrimitiveGenerator()
		end
		prompts[2] = {
			ctx.prompt(genPromptPart, {
				action = "Start Generator",
				object = "Emergency Generator",
				hold = 4,
				distance = 10,
				onTrigger = function()
					if step ~= 2 or genRunning then
						return
					end
					genRunning = true
					for _, p in prompts[2] do
						p:SetAttribute("Locked", true)
					end
					refreshPrompts()
					for _, em in exhaust do
						em.Enabled = true
					end
					startCorePulse(0.7)
					ctx.sound("Generator", genCF.Position)
					ctx.notify("Generator spinning up - defend it! (stay close)", Config.Colors.Accent)
					local st = entry.steps[2]
					st.text = "Defend the generator while it spins up"
					ctx.changed(true)
					ctx.defend({
						center = genCF.Position,
						radius = 20,
						duration = if workspace:GetAttribute("DebugFast") then 4 else GEN_DURATION,
						wavePeriod = 9,
						waveBudget = 7,
						onTick = function(p: number, paused: boolean)
							st.progress = p
							st.text = if paused then "Return to the generator! (spin-up paused)" else "Defend the generator while it spins up"
							genSpeed = if paused then 1 else 4 + p * 14
							statusLamp.Color = Color3.fromRGB(255, 60 + math.floor(p * 160), 50)
							ctx.changed()
						end,
						onDone = function()
							genSpeed = 20
							statusLamp.Color = Color3.fromRGB(60, 255, 110)
							startCorePulse(1.6)
							for _, em in exhaust do
								em.Rate = 12
							end
							st.progress = nil
							st.text = "Start the generator"
							finishStep(2, "Generator online! Power routed to the console.")
						end,
					})
				end,
			}),
		}
	end

	-- blade spin + periodic generator sound
	task.spawn(function()
		local ang = 0
		local soundT = 0
		while alive and ctx.alive() do
			local dt = 0.1
			task.wait(dt)
			if genSpeed > 0 then
				ang += genSpeed * dt
				for _, bl in blades do
					local base: CFrame = bl:GetAttribute("Base")
					bl.CFrame = base * CFrame.Angles(0, ang, 0)
				end
				soundT += dt
				if soundT >= 6 then
					soundT = 0
					ctx.sound("Generator", genCF.Position)
				end
			end
		end
	end)

	-- ============================================================ 3. console + trajectory mini-game
	local consoleScreen: BasePart
	local consoleText: TextLabel
	local consolePromptPart: BasePart
	local consoleGlow: BasePart? = nil -- mesh console: the neon Screen shows the state by colour
	local consolePending: { [Player]: any } = {}
	local consoleLight: PointLight? = nil
	local function setConsole(text: string, color: Color3)
		consoleText.Text = text
		consoleText.TextColor3 = color
		if consoleGlow then
			consoleGlow.Color = color
		end
		if consoleLight then
			consoleLight.Color = if color == Config.Colors.Friendly then WARM_LIGHT else color
			-- dim while unpowered, clearly lit once the generator is online
			local powered = text ~= "NO POWER"
			consoleLight.Brightness = if powered then 2.5 else 0.6
			consoleLight.Range = if powered then 24 else 14
		end
	end
	local function buildPrimitiveConsole()
		local f = Instance.new("Model")
		f.Name = "Console"
		f.Parent = root
		local b = conCF
		ctx.part(f, Vector3.new(8, 3, 4), b * CFrame.new(0, 1.5, 0), DARK, Enum.Material.Metal)
		ctx.part(f, Vector3.new(7, 1.4, 3), b * CFrame.new(0, 3.6, 0.2), STEEL, Enum.Material.Metal)
		consoleScreen = ctx.part(f, Vector3.new(7.4, 4, 0.5), b * CFrame.new(0, 6, 0.4) * CFrame.Angles(math.rad(-14), 0, 0), Color3.fromRGB(14, 20, 30), Enum.Material.SmoothPlastic, { Name = "Screen" })
		local sg = Instance.new("SurfaceGui")
		sg.Face = Enum.NormalId.Front
		sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		sg.CanvasSize = Vector2.new(740, 400)
		sg.LightInfluence = 0
		sg.Brightness = 1.6
		sg.Parent = consoleScreen
		local fr = Instance.new("Frame")
		fr.Size = UDim2.fromScale(1, 1)
		fr.BackgroundColor3 = Color3.fromRGB(10, 18, 28)
		fr.BorderSizePixel = 0
		fr.Parent = sg
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.fromScale(0.94, 0.4)
		title.Position = UDim2.fromScale(0.03, 0.06)
		title.Font = Enum.Font.Michroma
		title.Text = "TRAJECTORY"
		title.TextColor3 = Config.Colors.Friendly
		title.TextScaled = true
		title.Parent = fr
		consoleText = Instance.new("TextLabel")
		consoleText.BackgroundTransparency = 1
		consoleText.Size = UDim2.fromScale(0.94, 0.3)
		consoleText.Position = UDim2.fromScale(0.03, 0.55)
		consoleText.Font = Enum.Font.GothamBold
		consoleText.Text = "NO POWER"
		consoleText.TextColor3 = Config.Colors.Danger
		consoleText.TextScaled = true
		consoleText.Parent = fr
		consoleLight = ctx.light(consoleScreen, WARM_LIGHT, 16, 1)
		for _, x in { -3.2, 3.2 } do
			ctx.part(f, Vector3.new(0.5, 7, 0.5), b * CFrame.new(x, 4, 0.8), STEEL, Enum.Material.Metal, { CanCollide = false })
		end
		-- antenna dish
		ctx.cyl(f, 0.7, 10, b * CFrame.new(-7, 5, 3), STEEL, Enum.Material.Metal, { CanCollide = false })
		ctx.cyl(f, 5, 0.6, b * CFrame.new(-7, 10.4, 3) * CFrame.Angles(math.rad(25), 0, math.rad(20)), Color3.fromRGB(190, 194, 202), Enum.Material.Metal, { CanCollide = false })

		consolePromptPart = consoleScreen
	end
	do
		local con = spawnScaled("trajectory_console", conCF, 2, root, "Console", 1.5)
		if con and con.parts.Keyboard and con.parts.Screen then
			consolePromptPart = con.parts.Keyboard
			consoleScreen = con.parts.Screen
			consoleGlow = con.parts.Screen
			consoleText = Instance.new("TextLabel") -- not parented: keeps the state text API; the glow colour is what players see
			consoleText.Text = "NO POWER"
			consoleGlow.Color = Config.Colors.Danger
			consoleLight = ctx.light(consoleGlow, Config.Colors.Danger, 14, 0.6)
		else
			buildPrimitiveConsole()
		end
		prompts[3] = {
			ctx.prompt(consolePromptPart, {
				action = "Set Trajectory",
				object = "Targeting Console",
				hold = 0.4,
				distance = 11,
				onTrigger = function(player: Player)
					if step ~= 3 then
						return
					end
					local now = os.clock()
					local pend = consolePending[player]
					if pend and now - pend.t0 < 8 then
						return
					end
					local bands = {}
					local hw = { 16, 13, 10 }
					for i = 1, 3 do
						bands[i] = { c = ctx.rng:NextInteger(-48, 48), h = hw[i] }
					end
					local speeds = { 1.4 + ctx.rng:NextNumber(0, 0.4), 1.95 + ctx.rng:NextNumber(0, 0.4), 2.6 + ctx.rng:NextNumber(0, 0.5) }
					consolePending[player] = { t0 = now, bands = bands }
					if S and S.Fx then
						S.Fx.to(player, "Minigame", { id = "trajectory", obj = "MISSILE", bands = bands, speeds = speeds, pos = consoleScreen.Position, timeout = 90 })
					end
				end,
			}),
		}
	end

	-- test hook: answer the pending trajectory mini-game with perfect locks
	function ctl.debugSolve(player: Player)
		local pend = consolePending[player]
		if not pend then
			return false
		end
		pend.t0 -= 3
		local locks = {}
		for i, b in pend.bands do
			locks[i] = b.c
		end
		ctl.onMinigame(player, "MISSILE", { locks = locks })
		return true
	end

	function ctl.onMinigame(player: Player, objectiveId: string, payload: any)
		if objectiveId ~= "MISSILE" or step ~= 3 then
			return
		end
		local pend = consolePending[player]
		if not pend then
			return
		end
		consolePending[player] = nil
		if type(payload) ~= "table" or payload.cancel then
			return
		end
		local function reject(msg: string)
			if S and S.State then
				S.State.notify(player, msg, Config.Colors.Danger)
			end
		end
		local locks = payload.locks
		if type(locks) ~= "table" or #locks ~= 3 then
			return reject("Trajectory rejected - lock all three needles.")
		end
		local elapsed = os.clock() - pend.t0
		if elapsed < 1.8 or elapsed > 200 then
			return reject("Trajectory rejected - try again.")
		end
		local root = ctx.getRoot(player)
		if not root or (root.Position - consoleScreen.Position).Magnitude > 45 then
			return reject("Too far from the console.")
		end
		for i = 1, 3 do
			local a = locks[i]
			if type(a) ~= "number" or a ~= a or math.abs(a) > 100 then
				return reject("Trajectory rejected - try again.")
			end
			local band = pend.bands[i]
			if math.abs(a - band.c) > band.h + 5 then
				return reject("Trajectory off target - try again.")
			end
		end
		setConsole("LOCKED", Color3.fromRGB(60, 255, 110))
		finishStep(3, "Trajectory locked. Open the silo doors!")
	end

	-- keep console text in sync with the generator
	task.spawn(function()
		while alive and ctx.alive() and step < 3 do
			task.wait(0.5)
		end
		if alive and ctx.alive() and step == 3 then
			setConsole("READY", Config.Colors.Friendly)
		end
	end)

	-- ============================================================ 4. silo + levers
	local doorL: BasePart, doorR: BasePart
	local siloPiece: any = nil -- mesh silo (SetPieces.Piece) when the asset loaded
	local siloBase = siloCF
	local doorsOpen = false
	local missile: Model? = nil
	local missileRoot: Part? = nil
	local siloMouth: Vector3 = siloCF.Position + Vector3.new(0, 2, 0) -- where the ignition smoke pours out
	local siloLights: { any } = {} -- Parts (glow bulbs) or Lights: only `.Color` is used
	local function attachExhaust(nozzle: BasePart): PointLight
		-- All exhaust particles (flame, smoke column, ground plume) are client-side and quality-scaled (client/Fx/WorldFx.luau
		-- onMissile); the server only keeps the nozzle light. ctl.nozzle tells the client where the tail is.
		ctl.nozzle = nozzle
		return ctx.light(nozzle, Color3.fromRGB(255, 150, 60), 60, 0)
	end
	local function buildPrimitiveSilo()
		local f = Instance.new("Model")
		f.Name = "Silo"
		f.Parent = root
		local b = siloBase
		local wallCol = Color3.fromRGB(150, 146, 140)
		local H = 34
		siloMouth = (b * CFrame.new(0, H + 2, 0)).Position
		ctx.part(f, Vector3.new(22, H, 3), b * CFrame.new(0, H / 2, 9.5), wallCol, Enum.Material.Concrete)
		ctx.part(f, Vector3.new(22, H, 3), b * CFrame.new(0, H / 2, -9.5), wallCol, Enum.Material.Concrete)
		ctx.part(f, Vector3.new(3, H, 16), b * CFrame.new(9.5, H / 2, 0), wallCol, Enum.Material.Concrete)
		ctx.part(f, Vector3.new(3, H, 16), b * CFrame.new(-9.5, H / 2, 0), wallCol, Enum.Material.Concrete)
		-- hazard bands
		for _, y in { 6, 14, 22 } do
			for _, s in { -1, 1 } do
				ctx.glow(f, Vector3.new(22.2, 1.4, 0.3), b * CFrame.new(0, y, s * 11.2), HAZARD, { Transparency = 0.15 })
			end
		end
		doorL = ctx.part(f, Vector3.new(11, 2, 22), b * CFrame.new(-5.5, H + 1, 0), Color3.fromRGB(96, 100, 110), Enum.Material.DiamondPlate, { Name = "DoorL" })
		doorR = ctx.part(f, Vector3.new(11, 2, 22), b * CFrame.new(5.5, H + 1, 0), Color3.fromRGB(96, 100, 110), Enum.Material.DiamondPlate, { Name = "DoorR" })
		ctx.glow(f, Vector3.new(0.5, 0.4, 20), b * CFrame.new(-0.4, H + 2.1, 0), HAZARD, { Transparency = 0.1 })
		for _, c in { { -9, -9 }, { 9, -9 }, { -9, 9 }, { 9, 9 } } do
			local l = ctx.glow(f, Vector3.new(1.6, 1.6, 1.6), b * CFrame.new(c[1] * 1.15, H + 1.8, c[2] * 1.15), Color3.fromRGB(255, 80, 50))
			l.Shape = Enum.PartType.Ball
			siloLights[#siloLights + 1] = l
		end
		-- the missile, standing inside (root part anchored, everything else welded to it)
		local m = Instance.new("Model")
		m.Name = "Missile"
		m.Parent = f
		local rp = ctx.part(m, Vector3.new(1, 1, 1), b * CFrame.new(0, 14, 0), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, Name = "Root" })
		local function mp(size: Vector3, off: CFrame, color: Color3, mat: Enum.Material?, shape: Enum.PartType?): Part
			local p = ctx.part(m, size, rp.CFrame * off, color, mat, { CanCollide = false, CanQuery = false })
			if shape then
				p.Shape = shape
			end
			return p
		end
		local parts: { Part } = {}
		local white = Color3.fromRGB(232, 234, 240)
		parts[#parts + 1] = mp(Vector3.new(18, 5, 5), CFrame.Angles(0, 0, math.pi / 2), white, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		parts[#parts + 1] = mp(Vector3.new(3, 4, 4), CFrame.new(0, 10.5, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(215, 70, 55), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		parts[#parts + 1] = mp(Vector3.new(3, 2.6, 2.6), CFrame.new(0, 13, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(215, 70, 55), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		parts[#parts + 1] = mp(Vector3.new(1.4, 1.4, 1.4), CFrame.new(0, 14.6, 0), Color3.fromRGB(255, 220, 90), Enum.Material.Neon, Enum.PartType.Ball)
		for k = 0, 3 do
			local a = k * math.pi / 2
			parts[#parts + 1] = mp(Vector3.new(0.5, 5, 3.4), CFrame.Angles(0, a, 0) * CFrame.new(0, -6, 3.4) * CFrame.Angles(math.rad(8), 0, 0), Color3.fromRGB(215, 70, 55), Enum.Material.SmoothPlastic)
		end
		local nozzle = mp(Vector3.new(2, 3.6, 3.6), CFrame.new(0, -9.5, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(70, 74, 84), Enum.Material.Metal, Enum.PartType.Cylinder)
		parts[#parts + 1] = nozzle
		local glowLight = attachExhaust(nozzle)
		missileRoot = rp
		missile = m
		-- weld everything to the root, then free it (root stays anchored)
		for _, p in parts do
			local w = Instance.new("WeldConstraint")
			w.Part0 = rp
			w.Part1 = p
			w.Parent = p
			p.Anchored = false
			p.Massless = true
		end
		ctl.glowLight = glowLight

		-- levers
		local function makeLever(cf: CFrame, name: string, idx: number)
			local lf = Instance.new("Model")
			lf.Name = "Lever" .. name
			lf.Parent = root
			ctx.part(lf, Vector3.new(4, 1.2, 4), cf * CFrame.new(0, 0.6, 0), DARK, Enum.Material.Metal)
			ctx.part(lf, Vector3.new(2, 2.2, 1.6), cf * CFrame.new(0, 2.3, 0), STEEL, Enum.Material.Metal)
			local lamp = ctx.glow(lf, Vector3.new(1, 1, 1), cf * CFrame.new(0, 4.2, -1.2), Color3.fromRGB(255, 70, 50))
			lamp.Shape = Enum.PartType.Ball
			local arm = ctx.part(lf, Vector3.new(0.6, 4.4, 0.6), cf, Color3.fromRGB(190, 194, 200), Enum.Material.Metal, { CanCollide = false })
			local knob = ctx.glow(lf, Vector3.new(1.4, 1.4, 1.4), cf, Color3.fromRGB(255, 190, 40))
			knob.Shape = Enum.PartType.Ball
			local function pose(angleDeg: number)
				local pivot = cf * CFrame.new(0, 2.2, -1.6) * CFrame.Angles(math.rad(angleDeg), 0, 0)
				return pivot * CFrame.new(0, 2.2, 0), pivot * CFrame.new(0, 4.6, 0)
			end
			local a, k = pose(35)
			arm.CFrame, knob.CFrame = a, k
			local function setAngle(angle: number, animate: boolean)
				local ac, kc = pose(angle)
				if animate then
					ctx.tween(arm, 0.3, { CFrame = ac })
					ctx.tween(knob, 0.3, { CFrame = kc })
				else
					arm.CFrame, knob.CFrame = ac, kc
				end
			end
			local pp = ctx.prompt(arm, {
				action = "Pull",
				object = "Silo Lever " .. name,
				hold = 0,
				distance = 11,
				onTrigger = function(player: Player)
					ctl.pullLever(idx, player)
				end,
			})
			-- the prompt is on the arm part; keep it in reach of the base
			return { arm = arm, lamp = lamp, set = setAngle, prompt = pp }
		end
		ctl.levers = { makeLever(leverACF, "A", 1), makeLever(leverBCF, "B", 2) }
		prompts[4] = { ctl.levers[1].prompt, ctl.levers[2].prompt }
	end

	local function buildMeshSilo(piece: any)
		local P = piece.parts
		siloMouth = piece.cf.Position + Vector3.new(0, 2, 0)
		doorL, doorR = P.Door_L, P.Door_R
		local alarm = ctx.light(P.Body, Color3.fromRGB(255, 80, 50), 34, 1.4)
		siloLights[1] = alarm
		-- the missile: rest pose is lowered in the pit; welded to an invisible anchored root so it can rise and fly as one assembly
		local mesh: BasePart = P.Missile
		local m = Instance.new("Model")
		m.Name = "Missile"
		m.Parent = piece.model
		local rp = ctx.part(m, Vector3.new(1, 1, 1), mesh.CFrame, DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, Name = "Root" })
		mesh.Parent = m
		mesh.CanCollide = false
		mesh.CanQuery = false
		mesh.Massless = true
		-- exhaust helper at the base; same orientation as the old cylinder nozzle (emitters fire along its -X = down)
		local nozzle = ctx.part(m, Vector3.new(1, 1, 1), rp.CFrame * CFrame.new(0, -mesh.Size.Y / 2, 0) * CFrame.Angles(0, 0, math.pi / 2), DARK, Enum.Material.Metal, { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, Name = "Nozzle" })
		for _, part in { mesh, nozzle } do
			local w = Instance.new("WeldConstraint")
			w.Part0 = rp
			w.Part1 = part
			w.Parent = part
			part.Anchored = false
			part.Massless = true
		end
		m.PrimaryPart = rp
		ctl.glowLight = attachExhaust(nozzle)
		missileRoot = rp
		missile = m

		-- levers pivot at the stand caps; pulled = tipped toward the silo
		local function makeMeshLever(partName: string, name: string, idx: number): any
			local lp: BasePart = P[partName]
			local rest = lp.CFrame
			local pulled = SetPieces.swing(piece, partName, CFrame.Angles(math.rad(28), 0, 0), rest)
			local lamp = ctx.light(lp, Color3.fromRGB(255, 70, 50), 9, 1.2)
			local function setAngle(angle: number, animate: boolean)
				local target = if angle < 0 then pulled else rest
				if animate then
					ctx.tween(lp, 0.3, { CFrame = target })
				else
					lp.CFrame = target
				end
			end
			local pp = ctx.prompt(lp, {
				action = "Pull",
				object = "Silo Lever " .. name,
				hold = 0,
				distance = 11,
				onTrigger = function(player: Player)
					ctl.pullLever(idx, player)
				end,
			})
			return { arm = lp, lamp = lamp, set = setAngle, prompt = pp }
		end
		ctl.levers = { makeMeshLever("Lever_L", "A", 1), makeMeshLever("Lever_R", "B", 2) }
		prompts[4] = { ctl.levers[1].prompt, ctl.levers[2].prompt }
		leverMarker = (P.Lever_L.Position + P.Lever_R.Position) / 2
	end
	do
		local piece = SetPieces.spawn(S, "missile_silo", SetPieces.groundCF(map, siloBase, 6), root, { name = "Silo" })
		local P = piece and piece.parts
		if piece and P and P.Door_L and P.Door_R and P.Missile and P.Lever_L and P.Lever_R and P.Body then
			siloPiece = piece
			buildMeshSilo(piece)
		else
			if piece then
				piece.model:Destroy()
			end
			buildPrimitiveSilo()
		end
	end

	local launching = false
	local leverDown = { false, false }
	local leverTime = { 0, 0 }

	local function openDoors()
		doorsOpen = true
		ctx.sound("Alarm", siloCF.Position)
		ctx.fx("Shake", { p = siloCF.Position, mag = 0.6, r = 160 })
		-- hatch seals blow: steam jets out of the seam, then the leaves slam open (client: WorldFx onMissile phase "doors")
		ctx.fx("Missile", { phase = "doors", p = siloMouth, t = 1.6 })
		if siloPiece then
			-- hatch leaves swing up about their rim hinges (Door_L sits at -X: +72 deg about Z lifts it; Door_R mirrored)
			-- short pause for the steam, then a fast swing that bounces against the stops
			local lTarget = SetPieces.swing(siloPiece, "Door_L", CFrame.Angles(0, 0, math.rad(72)), doorL.CFrame)
			local rTarget = SetPieces.swing(siloPiece, "Door_R", CFrame.Angles(0, 0, math.rad(-72)), doorR.CFrame)
			task.delay(0.5, function()
				if alive and ctx.alive() then
					ctx.tween(doorL, 1.6, { CFrame = lTarget }, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
					ctx.tween(doorR, 1.6, { CFrame = rTarget }, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
				end
			end)
			task.delay(1.2, function()
				if alive and ctx.alive() then
					ctx.fx("Shake", { p = siloCF.Position, mag = 1.1, r = 140 }) -- the leaves hit their stops
					ctx.sound("PodImpact", siloCF.Position)
				end
			end)
			local mr = missileRoot
			if mr then
				-- the missile rises out of the pit once the hatch is part-open (manifest: raise 12.8 studs to stand at the pit plate)
				local target = CFrame.new(0, 12.8, 0) * mr.CFrame
				ctl.riseTarget = target
				task.delay(2, function()
					if alive and ctx.alive() and not launching and mr.Parent then
						ctl.riseTween = ctx.tween(mr, 5, { CFrame = target }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					end
				end)
			end
		else
			ctx.tween(doorL, 4, { CFrame = doorL.CFrame * CFrame.new(-11.5, 0, 0) })
			ctx.tween(doorR, 4, { CFrame = doorR.CFrame * CFrame.new(11.5, 0, 0) })
		end
		for _, l in siloLights do
			l.Color = Color3.fromRGB(70, 255, 120)
		end
		finishStep(4, "Silo doors opening! Go to the launch control.")
	end

	function ctl.pullLever(idx: number, player: Player)
		if step ~= 4 or doorsOpen or leverDown[idx] then
			return
		end
		local other = 3 - idx
		local solo = #ctx.players() <= 1
		local window = if solo then 12 else 8
		local now = os.clock()
		leverDown[idx] = true
		leverTime[idx] = now
		ctl.levers[idx].set(-35, true)
		ctl.levers[idx].lamp.Color = Color3.fromRGB(70, 255, 120)
		ctl.levers[idx].prompt.Enabled = false
		ctx.sound("UIClick", leverMarker or leverACF.Position)
		if leverDown[other] and now - leverTime[other] <= window then
			entry.steps[4].text = "Open the silo doors (pull both levers)"
			ctx.changed()
			openDoors()
			return
		end
		entry.steps[4].text = string.format("Pull the other lever within %d s!", window)
		ctx.changed(true)
		ctx.notify(string.format("Lever %s down - pull the other within %d s!", if idx == 1 then "A" else "B", window), Config.Colors.Accent)
		task.delay(window, function()
			if alive and ctx.alive() and not doorsOpen and leverDown[idx] and leverTime[idx] == now then
				leverDown[idx] = false
				ctl.levers[idx].set(35, true)
				ctl.levers[idx].lamp.Color = Color3.fromRGB(255, 70, 50)
				ctl.levers[idx].prompt.Enabled = step == 4
				entry.steps[4].text = "Open the silo doors (pull both levers)"
				ctx.changed(true)
				ctx.notify("Levers reset - pull both within the time limit.", Config.Colors.Danger)
			end
		end)
	end

	-- ============================================================ 5. launch control + launch
	do
		local f = Instance.new("Model")
		f.Name = "LaunchControl"
		f.Parent = root
		local p = siloCF.Position
		local dir = (Vector3.new(0, 0, 0) - Vector3.new(p.X, 0, p.Z))
		dir = if dir.Magnitude > 1 then dir.Unit else Vector3.new(0, 0, 1)
		local px, pz = p.X + dir.X * 34 + dir.Z * 18, p.Z + dir.Z * 34 - dir.X * 18
		local py = map.groundY(px, pz)
		local cf = CFrame.lookAt(Vector3.new(px, py, pz), Vector3.new(p.X, py, p.Z))
		local btn: BasePart
		local launchConsole = spawnScaled("trajectory_console", cf, 2, f, "LaunchConsole", 1.5)
		if launchConsole and launchConsole.parts.Keyboard and launchConsole.parts.Screen then
			-- same console mesh as step 3: keyboard = the LAUNCH prompt, screen glows red
			btn = launchConsole.parts.Keyboard
			btn.Name = "LaunchButton"
			local scr = launchConsole.parts.Screen
			scr.Color = Color3.fromRGB(255, 60, 50)
			ctx.light(scr, Color3.fromRGB(255, 60, 50), 14, 1.2)
		else
			ctx.part(f, Vector3.new(5, 3, 3), cf * CFrame.new(0, 1.5, 0), DARK, Enum.Material.Metal)
			ctx.part(f, Vector3.new(5.4, 1, 3.6), cf * CFrame.new(0, 3.3, 0) * CFrame.Angles(math.rad(-16), 0, 0), STEEL, Enum.Material.Metal)
			btn = ctx.cyl(f, 2.4, 0.8, cf * CFrame.new(0, 4, 0.1) * CFrame.Angles(math.rad(-16), 0, 0), Color3.fromRGB(255, 50, 40), Enum.Material.Neon, { Name = "LaunchButton" })
			ctx.light(btn, Color3.fromRGB(255, 60, 50), 14, 1.2)
		end
		ctl.launchPos = Vector3.new(px, py, pz)
		prompts[5] = {
			ctx.prompt(btn, {
				action = "LAUNCH",
				object = "Missile Control",
				hold = 1,
				distance = 11,
				onTrigger = function()
					if step ~= 5 or launching then
						return
					end
					launching = true
					prompts[5][1]:SetAttribute("Locked", true)
					prompts[5][1].Enabled = false
					local st = entry.steps[5]
					ctx.notify("LAUNCH SEQUENCE STARTED - clear the silo!", Config.Colors.Danger)
					task.spawn(function()
						for n = LAUNCH_COUNTDOWN, 1, -1 do
							if not (alive and ctx.alive()) then
								return
							end
							st.text = string.format("LAUNCH IN %d", n)
							st.progress = 1 - n / LAUNCH_COUNTDOWN
							ctx.changed(true)
							if n == LAUNCH_COUNTDOWN or n % 3 == 0 then
								ctx.sound("Klaxon", siloCF.Position)
							end
							if n == LAUNCH_COUNTDOWN or n == 5 or n <= 3 then
								ctx.sound("Alarm", siloCF.Position)
							end
							ctx.fx("Shake", { p = siloCF.Position, mag = 0.15 + (LAUNCH_COUNTDOWN - n) * 0.05, r = 220 })
							for _, l in siloLights do
								l.Color = Color3.fromRGB(255, 80, 50)
								task.delay(0.4, function()
									if l.Parent then
										l.Color = Color3.fromRGB(255, 190, 60)
									end
								end)
							end
							task.wait(1)
						end
						if not (alive and ctx.alive()) then
							return
						end
						-- IGNITION
						st.text = "LIFTOFF!"
						st.progress = 1
						ctx.changed(true)
						local mr, mm = missileRoot, missile
						if not mr or not mm then
							return
						end
						if ctl.riseTween then
							ctl.riseTween:Cancel()
							ctl.riseTween = nil
							if ctl.riseTarget then
								mr.CFrame = ctl.riseTarget
							end
						end
						local startCF = mr.CFrame
						local launchP = startCF.Position
						local dirUp = Vector3.new(0.12, 1, 0.08).Unit

						-- ignition hold: smoke billows out of the silo (client-side, quality-scaled), exhaust lights, the missile shakes
						ctx.fx("Missile", { phase = "ignite", p = siloMouth, t = IGNITION_HOLD })
						if ctl.glowLight then
							ctl.glowLight.Brightness = 6
							ctl.glowLight.Range = 60
						end
						local holdEnd = os.clock() + IGNITION_HOLD
						local nextShake = 0
						while os.clock() < holdEnd do
							if not (alive and ctx.alive()) then
								return
							end
							mr.CFrame = startCF * CFrame.new((math.random() - 0.5) * 0.25, (math.random() - 0.5) * 0.12, (math.random() - 0.5) * 0.25)
							if os.clock() >= nextShake then
								nextShake = os.clock() + 0.4
								ctx.fx("Shake", { p = siloMouth, mag = 1.2, r = 120 })
							end
							task.wait(0.04)
						end
						mr.CFrame = startCF

						-- liftoff. The flight is animated on every client (smooth, synced with the exhaust Fx): the client moves the
						-- replicated missile root locally along the same arc; the server leaves it in place and deletes it afterwards.
						local tailDist = if ctl.nozzle then (ctl.nozzle.Position - launchP).Magnitude else 8
						ctx.fx("Missile", {
							phase = "launch",
							p = siloCF.Position,
							mouth = siloMouth,
							top = launchP,
							rise = MISSILE_RISE,
							t = MISSILE_TIME,
							dir = dirUp,
							tail = tailDist,
							m = mr,
						})
						ctx.sound("MissileLaunch", siloCF.Position)
						ctx.fx("Shake", { p = siloCF.Position, mag = 3, r = 1200 })
						ctx.fx("Shake", { p = siloMouth, mag = 4, r = 120 }) -- strong shake for anyone close to the silo
						ctx.fx("Explosion", { p = siloMouth, r = 30, size = "XL", style = "fire" })
						-- scorch whatever stands at the base
						if S and S.Enemies and S.Enemies.explode then
							pcall(S.Enemies.explode, siloCF.Position, 40, 18, 600, 5, { kind = "objective", id = "MissileLaunch" })
						end
						if S and S.Players and S.Players.knock then
							for _, pl in ctx.playersNear(siloCF.Position, 26) do
								pcall(S.Players.knock, pl, siloCF.Position, 90)
							end
						end
						-- fly: reparent out of the objective folder so it survives Objectives.stop()
						mm.Parent = Workspace
						Debris:AddItem(mm, MISSILE_TIME + 4)
						task.wait(5)
						if alive and ctx.alive() then
							st.text = "Launch the missile"
							st.progress = nil
							finishStep(5, "MISSILE AWAY! Call the Skiff for extraction.")
							ctx.setMarker(entry, nil)
							onComplete()
						end
					end)
				end,
			}),
		}
	end

	-- ============================================================ finish setup
	refreshPrompts()
	setStepMarker()
	ctx.changed(true)

	function ctl.stop()
		alive = false
		for k in consolePending do
			consolePending[k] = nil
		end
	end

	return ctl
end

return MissileLaunch
