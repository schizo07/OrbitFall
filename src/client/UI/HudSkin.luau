--!nonstrict
-- Unified in-mission perimeter HUD visual system:
--   dark translucent plates (~58 % opacity, crisp 1 px border), sharp military corners,
--   TitilliumWeb SemiBold labels + Sarpanch Bold numerals, high-contrast tactical accents.
--
-- API:
--   HudSkin.current(): Skin
--   HudSkin.id(): string
--   HudSkin.isNew(): boolean
--   HudSkin.preset(): string
--   HudSkin.SKINS
--   HudSkin.color(role): Color3         text | dim | objective | own | danger | heal | rare | line | shadow | panel
--   HudSkin.font(role?): Font           number | label | body
--   HudSkin.styleText(label, role?)
--   HudSkin.label(props?): TextLabel
--   HudSkin.panel(kind?, props?): Frame "none" | "plate" | "fade" | "chip" | "banner" | "auto"
--   HudSkin.bar(props): Bar             { root, fill, set(alpha, color?), ghost(alpha), track(color, alpha?) }
--   HudSkin.fade(inst, a, t)
--   HudSkin.enter(inst, from?)
--   HudSkin.leave(inst, destroy?)
--   HudSkin.bump(inst)
--   HudSkin.swapText(label, text)
--   HudSkin.onRebuild(fn): () -> ()
--   HudSkin.fireRebuild(ctx)
local RunService = game:GetService("RunService")
local Theme = require(script.Parent.Theme)

local HudSkin = {}

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

local function font(family: string, weight: Enum.FontWeight, fallback: Enum.Font): Font
	local ok, f = pcall(function()
		return Font.new("rbxasset://fonts/families/" .. family .. ".json", weight, Enum.FontStyle.Normal)
	end)
	if ok and f then
		return f
	end
	return Font.fromEnum(fallback)
end

export type Skin = {
	id: string,
	colors: { [string]: Color3 },
	fonts: { number: Font, label: Font, body: Font },
	caps: boolean,
	stroke: { thickness: number, color: Color3, transparency: number },
	panelKind: string,
	barKind: string,
	corner: number,
	glyphHollow: boolean,
}

local SKIN: Skin = {
	id = "perimeter",
	colors = {
		text = hex("F2F4F7"),
		dim = hex("96A2B0"),
		objective = hex("5FD4E6"),
		own = hex("F5C445"),
		danger = hex("E0282F"),
		heal = hex("57D163"),
		rare = hex("F07A2B"),
		line = hex("FFFFFF"),
		shadow = hex("000000"),
		panel = hex("0A0E14"),
	},
	fonts = {
		number = font("Sarpanch", Enum.FontWeight.Bold, Enum.Font.GothamBold),
		label = font("TitilliumWeb", Enum.FontWeight.SemiBold, Enum.Font.GothamMedium),
		body = font("TitilliumWeb", Enum.FontWeight.SemiBold, Enum.Font.GothamMedium),
	},
	caps = true,
	stroke = { thickness = 1.2, color = hex("000000"), transparency = 0.48 },
	panelKind = "plate",
	barKind = "flat",
	corner = 0,
	glyphHollow = false,
}

HudSkin.SKINS = { perimeter = SKIN }
HudSkin.PLATE_ALPHA = 0.42 -- ~58 % opacity dark plate
HudSkin.BORDER_ALPHA = 0.78

function HudSkin.id(): string
	return SKIN.id
end

function HudSkin.current(): Skin
	return SKIN
end

function HudSkin.isNew(): boolean
	return true
end

function HudSkin.preset(): string
	return SKIN.id
end

function HudSkin.color(role: string): Color3
	return SKIN.colors[role] or SKIN.colors.text
end

function HudSkin.font(role: string?): Font
	return (SKIN.fonts :: { [string]: Font })[role or "label"] or SKIN.fonts.label
end

local touchCache: boolean? = nil
local function isTouch(): boolean
	if touchCache == nil then
		touchCache = Theme.isTouch()
	end
	return touchCache :: boolean
end

-- Text -------------------------------------------------------------------------------------------------------------
local function strokeOf(l: Instance): UIStroke?
	local st = l:FindFirstChild("SkinStroke")
	return if st and st:IsA("UIStroke") then st else nil
end

function HudSkin.styleText(l: any, role: string?)
	l.FontFace = HudSkin.font(role)
	local st = strokeOf(l)
	local small = isTouch() and (l.TextSize or 14) < 11
	if not small then
		if not st then
			st = Instance.new("UIStroke")
			st.Name = "SkinStroke"
			st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			st.Parent = l
		end
		local stroke = st :: UIStroke
		stroke.Thickness = SKIN.stroke.thickness
		stroke.Color = SKIN.stroke.color
		stroke.Transparency = SKIN.stroke.transparency
		l.TextStrokeTransparency = 1
	else
		if st then
			st:Destroy()
		end
		l.TextStrokeTransparency = 1
	end
end

local LABEL_SKIP = { Role = true, ColorRole = true, Color = true, XAlign = true, YAlign = true, Shadow = true, Rich = true, Wrap = true }

function HudSkin.label(p: { [string]: any }?): TextLabel
	local props = p or {}
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.TextSize = props.TextSize or 14
	l.TextColor3 = props.Color or HudSkin.color(props.ColorRole or "text")
	l.TextXAlignment = props.XAlign or Enum.TextXAlignment.Left
	l.TextYAlignment = props.YAlign or Enum.TextYAlignment.Center
	l.TextWrapped = props.Wrap == true
	l.RichText = props.Rich == true
	l.Text = ""
	HudSkin.styleText(l, props.Role)
	local parent = nil
	for k, v in props do
		if LABEL_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		elseif k == "Text" and type(v) == "string" then
			l.Text = if not props.Rich then string.upper(v) else v
		else
			(l :: any)[k] = v
		end
	end
	if props.Shadow == false then
		local st = strokeOf(l)
		if st then
			st:Destroy()
		end
	end
	l.Parent = parent
	return l
end

-- Panels -----------------------------------------------------------------------------------------------------------
function HudSkin.panel(kind: string?, props: { [string]: any }?): Frame
	local k: string = if kind == nil or kind == "auto" then SKIN.panelKind else kind
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = SKIN.colors.panel
	f.BackgroundTransparency = 1

	if k == "plate" or k == "banner" or k == "chip" then
		f.BackgroundTransparency = HudSkin.PLATE_ALPHA
		local st = Instance.new("UIStroke")
		st.Name = "SkinEdge"
		st.Color = SKIN.colors.line
		st.Transparency = HudSkin.BORDER_ALPHA
		st.Thickness = 1
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	elseif k == "fade" then
		f.BackgroundTransparency = 0
		local g = Instance.new("UIGradient")
		g.Name = "SkinFade"
		g.Rotation = 0
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, HudSkin.PLATE_ALPHA),
			NumberSequenceKeypoint.new(0.75, 0.56),
			NumberSequenceKeypoint.new(1, 0.92),
		})
		g.Parent = f
	end

	f:SetAttribute("SkinPanel", k)
	local parent = nil
	if props then
		for key, v in props do
			if key == "Parent" then
				parent = v
			else
				(f :: any)[key] = v
			end
		end
	end
	f.Parent = parent
	return f
end

-- Bars -------------------------------------------------------------------------------------------------------------
export type Bar = {
	root: Frame,
	fill: Frame?,
	set: (alpha: number, color: Color3?) -> (),
	ghost: (alpha: number) -> (),
	track: (color: Color3, alpha: number?) -> (),
}

local BAR_SKIP = { Color = true, Ghost = true, Segments = true, Ticks = true, Height = true, Brackets = true }

function HudSkin.bar(p: { [string]: any }): Bar
	local col: Color3 = p.Color or HudSkin.color("text")
	local trackCol = Color3.new(0, 0, 0)
	local trackAlpha = 0.52
	local root = Instance.new("Frame")
	root.Name = "Bar"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.new(1, 0, 0, 6)
	local parent = nil
	for k, v in p do
		if BAR_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		else
			(root :: any)[k] = v
		end
	end

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BorderSizePixel = 0
	track.BackgroundColor3 = trackCol
	track.BackgroundTransparency = trackAlpha
	track.Size = UDim2.fromScale(1, 1)
	track.ClipsDescendants = true
	track.Parent = root

	local ghost: Frame? = nil
	if p.Ghost then
		local gf = Instance.new("Frame")
		gf.Name = "Ghost"
		gf.BorderSizePixel = 0
		gf.BackgroundColor3 = HudSkin.color("danger"):Lerp(Color3.new(1, 1, 1), 0.35)
		gf.BackgroundTransparency = 0.15
		gf.Size = UDim2.fromScale(1, 1)
		gf.ZIndex = 1
		gf.Parent = track
		ghost = gf
	end

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = col
	fill.Size = UDim2.fromScale(1, 1)
	fill.ZIndex = 2
	fill.Parent = track

	if p.Segments then
		for _, x in { 0.25, 0.5, 0.75 } do
			local gap = Instance.new("Frame")
			gap.Name = "Gap"
			gap.BorderSizePixel = 0
			gap.BackgroundColor3 = SKIN.colors.panel
			gap.BackgroundTransparency = 0.25
			gap.AnchorPoint = Vector2.new(0.5, 0)
			gap.Position = UDim2.fromScale(x, 0)
			gap.Size = UDim2.new(0, 1, 1, 0)
			gap.ZIndex = 3
			gap.Parent = track
		end
	end

	if p.Brackets then
		for _, side in { 0, 1 } do
			local tick = Instance.new("Frame")
			tick.Name = if side == 0 then "EndL" else "EndR"
			tick.BorderSizePixel = 0
			tick.BackgroundColor3 = SKIN.colors.line
			tick.BackgroundTransparency = 0.35
			tick.AnchorPoint = Vector2.new(side, 0.5)
			tick.Position = UDim2.new(side, if side == 0 then -2 else 2, 0.5, 0)
			tick.Size = UDim2.new(0, 1, 1, 4)
			tick.ZIndex = 4
			tick.Parent = root
		end
	end

	local shownA, shownG, shownCol = -1, -1, nil :: Color3?
	local bar: any = { root = root, fill = fill }

	function bar.set(alpha: number, c: Color3?)
		local a = Theme.clamp(alpha, 0, 1)
		local nc = c or col
		if math.abs(a - shownA) > 0.0005 then
			shownA = a
			fill.Size = UDim2.fromScale(a, 1)
		end
		if nc ~= shownCol then
			shownCol, col = nc, nc
			fill.BackgroundColor3 = nc
		end
	end

	function bar.ghost(alpha: number)
		if not ghost then
			return
		end
		local g = Theme.clamp(alpha, 0, 1)
		if math.abs(g - shownG) > 0.0005 then
			shownG = g
			ghost.Size = UDim2.fromScale(g, 1)
		end
	end

	function bar.track(c: Color3, a: number?)
		trackCol = c
		trackAlpha = a or trackAlpha
		track.BackgroundColor3 = c
		track.BackgroundTransparency = trackAlpha
	end

	root.Parent = parent
	return bar
end

-- Motion -----------------------------------------------------------------------------------------------------------
local base: { [Instance]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any

local FADE_PROPS = {
	Frame = { "BackgroundTransparency" },
	TextLabel = { "BackgroundTransparency", "TextTransparency" },
	TextButton = { "BackgroundTransparency", "TextTransparency" },
	ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
	ImageButton = { "BackgroundTransparency", "ImageTransparency" },
	UIStroke = { "Transparency" },
}

local function fadeOne(inst: Instance, a: number, t: number)
	local props = FADE_PROPS[inst.ClassName]
	if not props then
		return
	end
	local b = base[inst]
	if not b then
		b = {}
		for _, k in props do
			b[k] = (inst :: any)[k]
		end
		base[inst] = b
	end
	local goal = {}
	for _, k in props do
		local v = b[k]
		goal[k] = v + (1 - v) * a
	end
	if t <= 0 then
		for k, v in goal do
			(inst :: any)[k] = v
		end
	else
		Theme.tween(inst, t, goal)
	end
end

function HudSkin.fade(inst: Instance, a: number, t: number)
	fadeOne(inst, a, t)
	for _, d in inst:GetDescendants() do
		fadeOne(d, a, t)
	end
end

local function slideOffset(from: string?): UDim2
	if from == "left" then
		return UDim2.fromOffset(-10, 0)
	elseif from == "right" then
		return UDim2.fromOffset(10, 0)
	elseif from == "bottom" then
		return UDim2.fromOffset(0, 10)
	elseif from == "top" then
		return UDim2.fromOffset(0, -10)
	end
	return UDim2.fromOffset(0, 0)
end

local function scaleOf(inst: Instance, name: string): UIScale
	local us = inst:FindFirstChild(name)
	if us and us:IsA("UIScale") then
		return us
	end
	local n = Instance.new("UIScale")
	n.Name = name
	n.Parent = inst
	return n
end

local motionGen: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local function nextGen(inst: Instance): number
	local g = (motionGen[inst] or 0) + 1
	motionGen[inst] = g
	return g
end

function HudSkin.enter(inst: GuiObject, from: string?)
	nextGen(inst)
	inst.Visible = true
	local home = inst:GetAttribute("SkinHome") or inst.Position
	inst:SetAttribute("SkinHome", home)
	inst.Position = home + slideOffset(from)
	HudSkin.fade(inst, 1, 0)
	Theme.tween(inst, 0.16, { Position = home }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	HudSkin.fade(inst, 0, 0.16)
end

function HudSkin.leave(inst: GuiObject, destroy: boolean?)
	local g = nextGen(inst)
	local t = 0.2
	HudSkin.fade(inst, 1, t)
	task.delay(t + 0.02, function()
		if motionGen[inst] ~= g or not inst.Parent then
			return
		end
		if destroy then
			inst:Destroy()
		else
			inst.Visible = false
			HudSkin.fade(inst, 0, 0)
		end
	end)
end

function HudSkin.bump(inst: GuiObject)
	local us = scaleOf(inst, "SkinBump")
	us.Scale = 1.14
	Theme.tween(us, 0.12, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

function HudSkin.swapText(l: TextLabel, text: string)
	local up = string.upper(text)
	if l.Text == up then
		return
	end
	local g = nextGen(l)
	l.Text = up
	l.MaxVisibleGraphemes = 0
	local n = utf8.len(up) or #up
	task.spawn(function()
		local t0 = os.clock()
		while motionGen[l] == g and l.Parent do
			local u = (os.clock() - t0) / 0.25
			if u >= 1 then
				break
			end
			l.MaxVisibleGraphemes = math.floor(n * u)
			RunService.Heartbeat:Wait()
		end
		if motionGen[l] == g then
			l.MaxVisibleGraphemes = -1
		end
	end)
end

-- Rebuild signal ---------------------------------------------------------------------------------------------------
local rebuildFns: { (any) -> () } = {}

function HudSkin.onRebuild(fn: (any) -> ()): () -> ()
	table.insert(rebuildFns, fn)
	return function()
		local i = table.find(rebuildFns, fn)
		if i then
			table.remove(rebuildFns, i)
		end
	end
end

function HudSkin.fireRebuild(ctx: any)
	for _, fn in table.clone(rebuildFns) do
		task.spawn(fn, ctx)
	end
end

return HudSkin
