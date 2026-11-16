-- Side objective AIRDEF (COG planets; ObjectiveService swaps it for a crashed-ship site on Brood planets):
-- an old AA battery on a spare site.
--   1. activate it at the control panel (hold 4 s)
--   2. defend it while the launcher rises out of its silo (35 s of someone within 35 studs; waves come for it)
-- Then, for the rest of the mission, it shoots down every incoming enemy dropship (server/AirDefence.luau, Director
-- `deliver` "drop"): the carrier explodes in the air and its squad never lands. Heavy drop pods still fall.
--   SideAirDefence.start(ctx, siteCF, index) -> controller { entry, stop, isDestroyed }
-- Studio: QuickStartSides=AIRDEF. A/B group "AIR DEFENCE" (Variants): Feel_AirDefence = nil (all) | "half".
local SetPieces = require(script.Parent.SetPieces)
local AirDefence = require(script.Parent.Parent.AirDefence)

local SideAirDefence = {}

local ACTIVATE_HOLD = 4
local DEFEND_TIME = 35
local DEFEND_RADIUS = 35
local RISE = 11 -- studs the launcher climbs out of the silo
local RANGE = 1000 -- covers the whole map

local DARK = Color3.fromRGB(40, 44, 54)
local STEEL = Color3.fromRGB(100, 106, 118)
local OLIVE = Color3.fromRGB(88, 96, 70)
local AMBER = Color3.fromRGB(255, 190, 70)
local GREEN = Color3.fromRGB(110, 255, 150)
local CONCRETE = Color3.fromRGB(128, 124, 116)

function SideAirDefence.start(ctx: any, siteCF: CFrame, index: number): any
	local base: CFrame = SetPieces.groundCF(ctx.map, siteCF, 10)
	local pos = base.Position

	local f = Instance.new("Model")
	f.Name = "AABattery" .. index
	f.Parent = ctx.folder

	local entry = ctx.newEntry({
		id = if index > 1 then "AIRDEF" .. index else "AIRDEF",
		title = "Bring the AA Battery Online",
		main = false,
		steps = {
			"Activate the AA battery (hold 4 s)",
			"Defend the battery while the launcher rises",
		},
	})
	local ctl: any = { entry = entry, isDestroyed = false }
	local alive = true
	local online = false
	local aaId = "AA" .. index

	-- ------------------------------------------------------------ the site
	ctx.part(f, Vector3.new(30, 1, 30), base * CFrame.new(0, 0.5, 0), CONCRETE, Enum.Material.Concrete)
	-- low blast wall around the silo, open towards the panel
	for k = 0, 7 do
		local a = k / 8 * math.pi * 2
		if k ~= 1 then
			ctx.part(f, Vector3.new(7, 2.4, 1.6), base * CFrame.Angles(0, a, 0) * CFrame.new(0, 2.2, -13), OLIVE, Enum.Material.Concrete)
		end
	end
	-- silo ring + two hatch doors
	ctx.cyl(f, 15, 1.2, base * CFrame.new(0, 1.2, 0), DARK, Enum.Material.DiamondPlate)
	local hatchL = ctx.part(f, Vector3.new(6.4, 0.6, 12.6), base * CFrame.new(-3.25, 1.95, 0), STEEL, Enum.Material.Metal, { Name = "HatchL" })
	local hatchR = ctx.part(f, Vector3.new(6.4, 0.6, 12.6), base * CFrame.new(3.25, 1.95, 0), STEEL, Enum.Material.Metal, { Name = "HatchR" })
	for _, h in { hatchL, hatchR } do
		ctx.glow(f, Vector3.new(0.4, 0.2, 12), h.CFrame * CFrame.new(if h == hatchL then 3 else -3, 0.35, 0), AMBER, { Name = "Stripe" })
	end

	-- the launcher (built at its raised pose, then sunk into the silo)
	local launcher = Instance.new("Model")
	launcher.Name = "Launcher"
	launcher.Parent = f
	local raised: { [BasePart]: CFrame } = {}
	local function lp(p: BasePart)
		raised[p] = p.CFrame
		p.CFrame = p.CFrame - Vector3.new(0, RISE, 0)
	end
	lp(ctx.cyl(launcher, 5, 6, base * CFrame.new(0, 4, 0), DARK, Enum.Material.Metal, { CanCollide = false }))
	lp(ctx.part(launcher, Vector3.new(7, 2.4, 7), base * CFrame.new(0, 7.6, 0), OLIVE, Enum.Material.Metal, { CanCollide = false }))
	local rack = base * CFrame.new(0, 10.2, 0.6) * CFrame.Angles(math.rad(50), 0, 0)
	lp(ctx.part(launcher, Vector3.new(7.4, 4.6, 5.2), rack, OLIVE, Enum.Material.Metal, { CanCollide = false }))
	local tubeTips: { BasePart } = {}
	for row = 0, 1 do
		for col = -1, 1 do
			-- 2 x 3 missile tubes on the rack's front face (-Z, tilted 50 degrees up)
			lp(ctx.part(launcher, Vector3.new(1.8, 1.8, 0.5), rack * CFrame.new(col * 2.3, row * 2.1 - 1.05, -2.75), DARK, Enum.Material.Metal, { CanCollide = false }))
			local tip = ctx.glow(launcher, Vector3.new(1.1, 1.1, 0.2), rack * CFrame.new(col * 2.3, row * 2.1 - 1.05, -3.05), AMBER)
			lp(tip)
			table.insert(tubeTips, tip)
		end
	end
	local radar = ctx.part(launcher, Vector3.new(4.4, 2.2, 0.4), base * CFrame.new(-3.8, 11.5, -2.4) * CFrame.Angles(math.rad(-15), 0, 0), STEEL, Enum.Material.Metal, { CanCollide = false, Name = "Radar" })
	lp(radar)
	lp(ctx.part(launcher, Vector3.new(0.5, 3, 0.5), base * CFrame.new(-3.8, 9.6, -2.2), DARK, Enum.Material.Metal, { CanCollide = false }))

	local function setRise(k: number, seconds: number)
		for p, cf in raised do
			if p.Parent then
				ctx.tween(p, seconds, { CFrame = cf - Vector3.new(0, RISE * (1 - k), 0) }, Enum.EasingStyle.Linear)
			end
		end
	end

	-- control panel
	local panelPos = base:PointToWorldSpace(Vector3.new(4.5, 0, -16.5))
	local gy = if ctx.map.groundY then ctx.map.groundY(panelPos.X, panelPos.Z) else pos.Y
	local panel = ctx.part(f, Vector3.new(4, 3.4, 2.2), CFrame.new(panelPos.X, gy + 1.7, panelPos.Z) * base.Rotation, DARK, Enum.Material.Metal, { Name = "Panel" })
	local screen = ctx.glow(f, Vector3.new(3.2, 1.5, 0.2), panel.CFrame * CFrame.new(0, 0.6, -1.15), AMBER)
	ctx.light(screen, Color3.fromRGB(255, 200, 120), 14, 1)

	-- amber column readable from far away (the main objective beacon is warm / white)
	local beam = ctx.glow(f, Vector3.new(0.9, 80, 0.9), base * CFrame.new(0, 40, 0), AMBER, { Transparency = 0.6 })
	SetPieces.pulse(beam, "Transparency", 0.6, 0.85, 1.1)
	ctx.setMarker(entry, pos)

	-- ------------------------------------------------------------ online: register + idle radar sweep
	local function goOnline()
		online = true
		screen.Color = GREEN
		for _, t in tubeTips do
			t.Color = GREEN
		end
		beam:Destroy()
		local top = raised[radar] and raised[radar].Position or (pos + Vector3.new(0, 12, 0))
		AirDefence.add(aaId, function()
			return if alive and online then top else nil
		end, RANGE)
		ctx.sound("MissileLaunch", pos)
		ctx.fx("Shake", { p = pos, mag = 0.8, r = 60 })
		task.spawn(function()
			local a = 0
			while alive and radar.Parent do
				a += 0.9
				local cf = raised[radar]
				if cf then
					local pivot = base * CFrame.new(-3.8, 11.5, -2.4)
					radar.CFrame = (pivot * CFrame.Angles(0, a, 0) * CFrame.Angles(math.rad(-15), 0, 0)) :: CFrame
				end
				task.wait(0.5)
			end
		end)
	end

	-- ------------------------------------------------------------ stage 2: defend while it rises
	local defendCtl: any = nil
	local function startDefend()
		ctx.tween(hatchL, 1.5, { CFrame = hatchL.CFrame * CFrame.new(-6.2, 0, 0) })
		ctx.tween(hatchR, 1.5, { CFrame = hatchR.CFrame * CFrame.new(6.2, 0, 0) })
		ctx.sound("WarnMachinery", pos)
		ctx.setMarker(entry, pos)
		local lastP = -1
		defendCtl = ctx.defend({
			center = pos,
			radius = DEFEND_RADIUS,
			duration = DEFEND_TIME,
			wavePeriod = 14,
			waveBudget = 4,
			onTick = function(p: number, paused: boolean)
				local st = entry.steps[2]
				st.progress = math.min(p, 0.99)
				st.text = if paused then "Stay near the battery - the launcher stops rising"
					else "Defend the battery while the launcher rises"
				if math.abs(p - lastP) > 0.004 then
					lastP = p
					setRise(p, 0.25)
				end
				ctx.changed()
			end,
			onDone = function()
				if not alive or not ctx.alive() then
					return
				end
				setRise(1, 0.4)
				ctx.completeStep(entry, 2, "AA battery online - enemy dropships will be shot down!")
				ctx.setMarker(entry, nil)
				task.delay(0.4, goOnline)
			end,
		})
	end

	-- ------------------------------------------------------------ stage 1: activate
	local prompt: ProximityPrompt
	prompt = ctx.prompt(panel, {
		action = "Activate",
		object = "AA Battery",
		hold = ACTIVATE_HOLD,
		distance = 10,
		onTrigger = function()
			if not prompt.Enabled then
				return
			end
			prompt.Enabled = false
			screen.Color = Color3.fromRGB(255, 240, 160)
			ctx.completeStep(entry, 1, "AA battery powering up - hold the area!")
			startDefend()
		end,
	})

	function ctl.stop()
		alive = false
		online = false
		AirDefence.remove(aaId)
		if defendCtl then
			defendCtl.cancel()
		end
	end

	return ctl
end

return SideAirDefence
