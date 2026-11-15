--!nonstrict
-- Weather and colour grade (client only, local effects):
--   * colour grade: a ColorCorrectionEffect "BiomeGrade" in Lighting on top of the map's own grade, per biome
--     (desert warm, ash grey-red and contrasty, swamp green, ice cool and bright). Removed on the ship.
--   * dust storms (desert, ash): server/WeatherService.luau sets workspace Weather / WeatherAt / WeatherEnd so the whole
--     squad gets the same storm. During a storm the Atmosphere thickens (fog closes in), wind-blown dust sheets and grit
--     stream past the camera, the Wind loop swells, the grade turns dusty, and the compass shows a STORM tag.
--     Ramps in and out over RAMP seconds. Visibility only.
--   * swamp spores and ice snow are always on in Fx/Ambience.luau.
-- Studio A/B (client/Variants.luau):
--   Feel_Grade    nil = per biome | "strong" | "off"
--   Feel_Weather  nil = storms on | "clear" | "now" (server starts a storm at once)

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Weather = {}

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local RGB = Color3.fromRGB
local NS = NumberSequence.new
local NK = NumberSequenceKeypoint.new

local RAMP = 10 -- seconds to build up / die down
local WIND_VOL = 1.3 -- Wind loop volume at full storm
local WIND_BASE = 0.05 -- the loop is created at this volume multiplier (no pop at start), setVolume divides it back out
local TOUCH_RATE = 0.4 -- particle rate cap on touch devices

-- Colour grade per biome: tint, saturation, contrast, brightness (added to the map's own ColorCorrection)
local GRADE = {
	desert = { tint = RGB(255, 243, 226), sat = 0.06, contrast = 0.06, bright = 0 },
	ash = { tint = RGB(255, 232, 222), sat = -0.12, contrast = 0.12, bright = -0.02 },
	swamp = { tint = RGB(232, 255, 236), sat = 0.08, contrast = 0.04, bright = 0 },
	ice = { tint = RGB(232, 244, 255), sat = -0.06, contrast = 0.05, bright = 0.03 },
}
local GRADE_STRONG = 1.9

-- Storm look per biome (only desert / ash storm)
local STORM = {
	desert = {
		dust = RGB(214, 168, 116), atmColor = RGB(196, 150, 104), density = 0.72, hazeAdd = 3,
		tint = RGB(255, 224, 186), sat = -0.18, contrast = -0.06, bright = -0.02,
	},
	ash = {
		dust = RGB(96, 84, 80), atmColor = RGB(92, 78, 74), density = 0.75, hazeAdd = 3,
		tint = RGB(240, 222, 214), sat = -0.25, contrast = -0.04, bright = -0.04,
	},
}

local Audio: any = nil
local Store: any = nil
local Theme: any = nil
local quality = 1

local activeBiome: string? = nil
local cc: ColorCorrectionEffect? = nil
local box: Part? = nil
local emitters: { { pe: ParticleEmitter, rate: number } } = {}
local lastRateK = -1
local windLoop: any = nil
local atmBase: { [Instance]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any
local lastAtmK = -1
local tag: Frame? = nil
local tagShown = false

-- helpers ---------------------------------------------------------------------------------------------------------------
local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- tint scaled away from white by k (k > 1 = stronger), clamped
local function tintK(c: Color3, k: number): Color3
	return Color3.new(
		math.clamp(1 - (1 - c.R) * k, 0, 1),
		math.clamp(1 - (1 - c.G) * k, 0, 1),
		math.clamp(1 - (1 - c.B) * k, 0, 1)
	)
end

local function mulColor(a: Color3, b: Color3): Color3
	return Color3.new(a.R * b.R, a.G * b.G, a.B * b.B)
end

local function isTouch(): boolean
	if Theme and Theme.isTouch then
		local ok, v = pcall(Theme.isTouch)
		return ok and v == true
	end
	return false
end

local function feel(key: string): string?
	local a = Workspace:GetAttribute(key)
	return if type(a) == "string" then a else nil
end

-- 0..1 storm strength right now (same on every client: computed from the server phase times)
local function stormIntensity(): number
	if not activeBiome or not STORM[activeBiome] or feel("Feel_Weather") == "clear" then
		return 0
	end
	if Workspace:GetAttribute("Weather") ~= "storm" then
		return 0
	end
	local at = Workspace:GetAttribute("WeatherAt")
	local ends = Workspace:GetAttribute("WeatherEnd")
	if type(at) ~= "number" or type(ends) ~= "number" or ends <= 0 then
		return 0
	end
	local now = Workspace:GetServerTimeNow()
	local k = math.clamp(math.min((now - at) / RAMP, (ends - now) / RAMP), 0, 1)
	return k * k * (3 - 2 * k)
end

local function windDir(): Vector3
	local at = Workspace:GetAttribute("WeatherAt")
	local a = if type(at) == "number" then (at * 0.37) % (math.pi * 2) else 0.6
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

-- colour grade ----------------------------------------------------------------------------------------------------------
local function applyGrade(storm: number)
	local g = activeBiome and GRADE[activeBiome]
	if not g then
		if cc then
			cc:Destroy()
			cc = nil
		end
		return
	end
	if not cc or cc.Parent ~= Lighting then
		local e = Instance.new("ColorCorrectionEffect")
		e.Name = "BiomeGrade"
		e.Parent = Lighting
		cc = e
	end
	local mode = feel("Feel_Grade")
	local k = if mode == "off" then 0 elseif mode == "strong" then GRADE_STRONG else 1
	local tint = tintK(g.tint, k)
	local sat, contrast, bright = g.sat * k, g.contrast * k, g.bright * k
	local s = activeBiome and STORM[activeBiome]
	if s and storm > 0 then
		tint = mulColor(tint, tintK(s.tint, storm))
		sat += s.sat * storm
		contrast += s.contrast * storm
		bright += s.bright * storm
	end
	local e = cc :: ColorCorrectionEffect
	e.TintColor = tint
	e.Saturation = sat
	e.Contrast = contrast
	e.Brightness = bright
end

-- atmosphere (fog) ------------------------------------------------------------------------------------------------------
local function applyAtmosphere(storm: number)
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atm then
		return
	end
	local b = atmBase[atm]
	if not b then
		if storm <= 0 then
			return
		end
		b = { Density = atm.Density, Haze = atm.Haze, Color = atm.Color, Glare = atm.Glare, Offset = atm.Offset }
		atmBase[atm] = b
	end
	local s = activeBiome and STORM[activeBiome]
	if not s or storm <= 0 then
		atm.Density, atm.Haze, atm.Color, atm.Glare, atm.Offset = b.Density, b.Haze, b.Color, b.Glare, b.Offset
		atmBase[atm] = nil
		return
	end
	atm.Density = lerp(b.Density, math.max(b.Density, s.density), storm)
	atm.Haze = lerp(b.Haze, math.min(b.Haze + s.hazeAdd, 10), storm)
	atm.Color = b.Color:Lerp(s.atmColor, 0.7 * storm)
	atm.Glare = lerp(b.Glare, 0, storm)
	atm.Offset = lerp(b.Offset, math.max(b.Offset, 0.4), storm)
end

local function resetAtmosphere()
	for atm, b in atmBase do
		if atm.Parent then
			pcall(function()
				local a = atm :: Atmosphere
				a.Density, a.Haze, a.Color, a.Glare, a.Offset = b.Density, b.Haze, b.Color, b.Glare, b.Offset
			end)
		end
	end
	table.clear(atmBase)
	lastAtmK = -1
end

-- storm particles (built once per mission map, rates driven by the storm strength) -------------------------------------
local function emitter(parent: Instance, props: { [string]: any }, rate: number)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = TEX_SMOKE
	pe.Rate = 0
	pe.EmissionDirection = Enum.NormalId.Front
	pe.Shape = Enum.ParticleEmitterShape.Box
	pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	pe.LockedToPart = false
	pe.Rotation = NumberRange.new(0, 360)
	for k, v in props do
		if k == "grit" then
			pe:SetAttribute("Grit", v)
		else
			(pe :: any)[k] = v
		end
	end
	pe.Parent = parent
	table.insert(emitters, { pe = pe, rate = rate })
end

local function buildStorm(biome: string)
	local s = STORM[biome]
	if not s then
		return
	end
	local p = Instance.new("Part")
	p.Name = "ClientStormBox"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(130, 34, 24)
	p.Parent = Workspace
	box = p
	-- wide dust sheets rolling across the view
	emitter(p, {
		Lifetime = NumberRange.new(2.4, 3.4),
		Speed = NumberRange.new(38, 52),
		SpreadAngle = Vector2.new(6, 4),
		Size = NS({ NK(0, 10), NK(0.5, 20), NK(1, 26) }),
		Transparency = NS({ NK(0, 1), NK(0.2, 0.7), NK(0.7, 0.74), NK(1, 1) }),
		Color = ColorSequence.new(s.dust),
		LightInfluence = 0.75,
		RotSpeed = NumberRange.new(-25, 25),
	}, 26)
	-- low rolling dust along the ground
	emitter(p, {
		Lifetime = NumberRange.new(3, 4),
		Speed = NumberRange.new(26, 36),
		SpreadAngle = Vector2.new(4, 1),
		Size = NS({ NK(0, 16), NK(1, 34) }),
		Transparency = NS({ NK(0, 1), NK(0.25, 0.62), NK(0.75, 0.7), NK(1, 1) }),
		Color = ColorSequence.new(s.dust:Lerp(Color3.new(0, 0, 0), 0.12)),
		LightInfluence = 0.75,
		Acceleration = Vector3.new(0, -2, 0),
		RotSpeed = NumberRange.new(-12, 12),
	}, 7)
	-- fine grit streaking past
	emitter(p, {
		Lifetime = NumberRange.new(1.4, 2),
		Speed = NumberRange.new(60, 80),
		SpreadAngle = Vector2.new(5, 5),
		Size = NS({ NK(0, 0.18), NK(1, 0.12) }),
		Transparency = NS({ NK(0, 0.35), NK(1, 0.8) }),
		Color = ColorSequence.new(s.dust:Lerp(Color3.new(1, 1, 1), 0.2)),
		LightInfluence = 0.6,
		grit = true,
	} :: any, 90)
end

local function setRates(storm: number)
	local touch = isTouch()
	local q = math.clamp(quality, 0.3, 1) * (if touch then TOUCH_RATE else 1)
	for _, e in emitters do
		local skip = touch and e.pe:GetAttribute("Grit") == true
		e.pe.Rate = if skip then 0 else e.rate * q * storm
	end
end

local function teardownStorm()
	for _, e in emitters do
		e.pe:Destroy()
	end
	table.clear(emitters)
	if box then
		box:Destroy()
		box = nil
	end
	lastRateK = -1
	if windLoop then
		windLoop.stop(1)
		windLoop = nil
	end
end

-- compass tag -----------------------------------------------------------------------------------------------------------
-- Called from UI/Compass.build with the compass holder; the tag sits to the right of the heading chip.
function Weather.compassTag(holder: Instance)
	local ok, Style = pcall(function()
		return require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("HudStyle"))
	end)
	if not ok or not Style then
		return
	end
	if tag then
		tag:Destroy()
	end
	local t = Style.panel({
		Name = "StormTag",
		Size = UDim2.fromOffset(54, 16),
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0.5, 40, 1, 2),
		Visible = false,
		Brackets = false,
		Parent = holder,
	})
	Style.label({
		Text = "STORM",
		TextSize = 12,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = t,
	})
	tag = t
	tagShown = false
end

local function showTag(on: boolean)
	if tag and tag.Parent and on ~= tagShown then
		tagShown = on
		tag.Visible = on
	end
end

-- lifecycle -------------------------------------------------------------------------------------------------------------
local function desiredBiome(): string?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	local mission = Store and Store.get("mission")
	if mission and mission.state == "Ship" then
		return nil
	end
	local b = map:GetAttribute("Biome")
	return if type(b) == "string" and GRADE[b] then b else nil
end

local function refresh()
	local want = desiredBiome()
	if want == activeBiome then
		return
	end
	teardownStorm()
	resetAtmosphere()
	activeBiome = want
	if want then
		buildStorm(want)
	end
	applyGrade(0)
	showTag(false)
end

local function step()
	if not activeBiome then
		return
	end
	local storm = stormIntensity()
	-- particles follow the camera, upwind of it, blowing through the view
	if box then
		local cam = Workspace.CurrentCamera
		if cam then
			local w = windDir()
			local c = cam.CFrame.Position - w * 45 + Vector3.new(0, 4, 0)
			box.CFrame = CFrame.lookAt(c, c + w)
		end
	end
	if math.abs(storm - lastRateK) > 0.02 or (storm == 0 and lastRateK ~= 0) then
		lastRateK = storm
		setRates(storm)
		applyGrade(storm)
	end
	if math.abs(storm - lastAtmK) > 0.01 or (storm == 0 and lastAtmK ~= 0) then
		lastAtmK = storm
		applyAtmosphere(storm)
	end
	-- wind loop: only alive while a storm blows
	if storm > 0.01 then
		if not windLoop and Audio and Audio.loop then
			windLoop = Audio.loop("Wind", nil, { volume = WIND_BASE })
		end
		if windLoop then
			windLoop.setVolume(storm * WIND_VOL / WIND_BASE)
		end
	elseif windLoop then
		windLoop.stop(1)
		windLoop = nil
	end
	showTag(storm > 0.05)
end

function Weather.init(Fx: any, AudioMod: any, _Juice: any)
	Audio = AudioMod
	quality = if Fx and type(Fx.quality) == "number" then Fx.quality else 1
	pcall(function()
		Store = require(script.Parent.Parent:WaitForChild("Store", 10))
	end)
	pcall(function()
		Theme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme"))
	end)
	if Store then
		Store.on("mission", function()
			task.defer(refresh)
		end)
	end
	Workspace.ChildAdded:Connect(function(c)
		if c.Name == "Map" then
			task.defer(refresh)
		end
	end)
	Workspace.ChildRemoved:Connect(function(c)
		if c.Name == "Map" then
			task.defer(refresh)
		end
	end)
	-- A/B switches take effect live
	Workspace:GetAttributeChangedSignal("Feel_Grade"):Connect(function()
		applyGrade(lastRateK > 0 and lastRateK or 0)
	end)
	RunService.RenderStepped:Connect(step)
	-- safety net (late attribute replication); also re-applies the grade if a map rebuild removed it
	task.spawn(function()
		while true do
			refresh()
			if activeBiome and (not cc or cc.Parent ~= Lighting) then
				applyGrade(math.max(lastRateK, 0))
			end
			task.wait(1)
		end
	end)
end

return Weather
