-- Scope view overlay for zoom >= 2 weapons while aiming (client/CameraController owns the first-person lens and FOV).
-- A round lens (everything outside it masked dark), a thick cartoon rim, a soft vignette inside the rim and a post
-- reticle. Studio A/B "SCOPE" (Feel_Scope): "fade" = the lens fades in from black over FADE_TIME.
local RunService = game:GetService("RunService")

local Theme = require(script.Parent.Theme)

local ScopeOverlay = {}

local LENS_SCALE = 0.9 -- lens diameter, share of the screen height
local FADE_TIME = 0.15
local MASK = Color3.fromHex("0c0e13")
local RIM = Color3.fromHex("1b1d22")
local RIM_ACCENT = Color3.fromHex("9fe8ff")
local INK = Color3.fromHex("101218")

-- { instance, property, transparency at full view }
local fades: { { any } } = {}
local gui: ScreenGui? = nil
local cover: Frame? = nil
local shown = -1

local function circle(parent: Instance, scale: number, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(scale, scale)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

local function stroke(parent: Instance, thickness: number, color: Color3, transparency: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.Transparency = transparency
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	table.insert(fades, { s, "Transparency", transparency })
end

local function bar(parent: Instance, pos: UDim2, size: UDim2, transparency: number)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = INK
	f.BackgroundTransparency = transparency
	f.BorderSizePixel = 0
	f.Parent = parent
	table.insert(fades, { f, "BackgroundTransparency", transparency })
end

local function build()
	local g = Theme.gui("OrbitScope", { DisplayOrder = 9, Insets = "None", Enabled = false, NoTextFloor = true })
	gui = g

	-- lens: everything outside the circle is covered by one very wide stroke
	local lens = circle(g, LENS_SCALE, "Lens")
	lens.SizeConstraint = Enum.SizeConstraint.RelativeYY
	stroke(lens, 4000, MASK, 0)

	-- view cover (the "fade" preset fades the picture in from black)
	local cv = circle(lens, 1, "Cover")
	cv.BackgroundColor3 = MASK
	cv.BackgroundTransparency = 1
	cover = cv

	-- soft vignette just inside the rim
	local vig = { { 1, 0.55 }, { 0.975, 0.72 }, { 0.95, 0.84 }, { 0.92, 0.93 } }
	for i, v in vig do
		stroke(circle(lens, v[1], "Vignette" .. i), 12, MASK, v[2])
	end
	-- cartoon rim: thick dark ring + thin light accent ring
	stroke(circle(lens, 1, "Rim"), 10, RIM, 0)
	stroke(circle(lens, 0.985, "RimAccent"), 2.5, RIM_ACCENT, 0.15)

	-- reticle: thick posts left / right / bottom, thin cross lines with an open centre, small range ticks
	local ret = Instance.new("Frame")
	ret.Name = "Reticle"
	ret.BackgroundTransparency = 1
	ret.Size = UDim2.fromScale(1, 1)
	ret.Parent = lens
	local POST, THIN = 7, 2
	bar(ret, UDim2.fromScale(0.1, 0.5), UDim2.new(0.2, 0, 0, POST), 0.05)
	bar(ret, UDim2.fromScale(0.9, 0.5), UDim2.new(0.2, 0, 0, POST), 0.05)
	bar(ret, UDim2.fromScale(0.5, 0.9), UDim2.new(0, POST, 0.2, 0), 0.05)
	bar(ret, UDim2.fromScale(0.335, 0.5), UDim2.new(0.27, 0, 0, THIN), 0.15)
	bar(ret, UDim2.fromScale(0.665, 0.5), UDim2.new(0.27, 0, 0, THIN), 0.15)
	bar(ret, UDim2.fromScale(0.5, 0.235), UDim2.new(0, THIN, 0.47, 0), 0.15)
	bar(ret, UDim2.fromScale(0.5, 0.665), UDim2.new(0, THIN, 0.27, 0), 0.15)
	for _, x in { 0.38, 0.42, 0.58, 0.62 } do
		bar(ret, UDim2.fromScale(x, 0.5), UDim2.fromOffset(THIN, 10), 0.25)
	end
	for _, y in { 0.58, 0.62, 0.66 } do
		bar(ret, UDim2.fromScale(0.5, y), UDim2.fromOffset(10 - (y - 0.58) * 60, THIN), 0.25)
	end
end

-- a: 0 hidden .. 1 full view; blackout: 1 = lens fully covered .. 0 clear
local function setAlpha(a: number, blackout: number)
	local key = math.floor(a * 40 + 0.5) * 100 + math.floor(blackout * 40 + 0.5)
	if key == shown then
		return
	end
	shown = key
	local g = gui :: ScreenGui
	g.Enabled = a > 0
	for _, e in fades do
		e[1][e[2]] = e[3] + (1 - e[3]) * (1 - a)
	end
	if cover then
		cover.BackgroundTransparency = 1 - blackout
	end
end

function ScopeOverlay.init(cam: any)
	build()
	RunService.RenderStepped:Connect(function()
		local on, since = cam.scopeState()
		if not on then
			setAlpha(0, 0)
			return
		end
		if workspace:GetAttribute("Feel_Scope") == "fade" then
			local k = math.clamp((os.clock() - since) / FADE_TIME, 0, 1)
			setAlpha(k, 1 - k)
		else
			setAlpha(1, 0)
		end
	end)
end

return ScopeOverlay
