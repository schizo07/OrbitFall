--!nonstrict
-- In-mission HUD skins. Studio A/B: workspace attribute Feel_UiStyle (Variants group "UI STYLE"):
--   nil       = "hairline"  thin lines and angled cuts, no boxes
--   "glass"   = "glass"     rounded translucent pills and cards
--   "visor"   = "visor"     one phosphor hue, monospace, helmet display
--   "old"     = the pre-2026-11-17 HUD (HudSkin.current() returns nil; every caller falls back to its old code)
--
-- API (all safe to call with the old HUD selected; they then return plain / unstyled results):
--   HudSkin.current(): Skin?           the active skin table, nil for the old HUD
--   HudSkin.id(): string                "hairline" | "glass" | "visor" | "old"
--   HudSkin.isNew(): boolean            true for the three new skins
--   HudSkin.SKINS                       token tables by id (colors, fonts, text, panelKind, barKind, motion)
--   HudSkin.color(role): Color3         role = text | dim | objective | own | danger | heal | rare | line | shadow | panel
--   HudSkin.font(role): Font            role = number | label | body
--   HudSkin.label(props): TextLabel     props: Role (number | label | body), ColorRole, Color, Text, TextSize, XAlign,
--                                        YAlign, Shadow (glass soft shadow on always-visible text), + any TextLabel property
--   HudSkin.styleText(label, role?)     apply the skin's font + text treatment to an existing TextLabel / TextButton
--   HudSkin.panel(kind, props?): Frame  kind = "none" | "fade" | "glass" | "scan" | "auto" (the skin's contextual backing)
--   HudSkin.bar(props): Bar             skin bar recipe (hairline angled ends, glass pill, visor ticks). props: Parent,
--                                        Name, Size, Position, AnchorPoint, LayoutOrder, ZIndex, Color, Ghost (bool),
--                                        Segments (hairline: gaps every 25 %), Ticks (visor tick count, default 30)
--                                        Bar: { root, fill, set(alpha, color?), ghost(alpha), track(color, alpha?) }
--   HudSkin.enter(inst, from?)          appear; from = "left" | "right" | "top" | "bottom" (hairline slide direction)
--   HudSkin.leave(inst, destroy?)       disappear (Visible = false at the end, or Destroy when destroy == true)
--   HudSkin.bump(inst)                  "this value just changed" pop
--   HudSkin.swapText(label, text)       goal-change text transition (type-in / cross-fade / cursor rewrite)
--   HudSkin.onRebuild(fn): () -> ()     fn(ctx) after every HUD build (the first one and each rebuild after a style
--                                        switch). ctx = { skin, id, touch, gui = OrbitHUD, root = layout root Frame }.
--                                        Register once (module scope or a guard), not inside a build function.
--   HudSkin.fireRebuild(ctx)            called by HUD only
local RunService = game:GetService("RunService")
local Theme = require(script.Parent.Theme)

local HudSkin = {}

local ATTR = "Feel_UiStyle"
HudSkin.ATTR = ATTR

local PRESET_ATTR = "Feel_HudPreset"
HudSkin.PRESET_ATTR = PRESET_ATTR

local PRESET_TO_ID = { clean = "clean", frame = "frame" }

function HudSkin.preset(): string
	local v = workspace:GetAttribute(PRESET_ATTR)
	return (type(v) == "string" and PRESET_TO_ID[v]) or "bold"
end

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
	stroke: { thickness: number, color: Color3, transparency: number }?,
	softShadow: boolean,
	panelKind: string,
	barKind: string,
	corner: number,
	glyphHollow: boolean,
}

HudSkin.SKINS = {
	hairline = {
		id = "hairline",
		colors = {
			text = hex("F2F4F5"),
			dim = hex("8C96A3"),
			objective = hex("4FE3F0"),
			own = hex("FFB547"),
			danger = hex("FF4D4D"),
			heal = hex("6BF28A"),
			rare = hex("FF8A3D"),
			line = hex("FFFFFF"),
			shadow = hex("000000"),
			panel = hex("000000"),
		},
		fonts = {
			number = font("Sarpanch", Enum.FontWeight.Bold, Enum.Font.GothamBold),
			label = font("TitilliumWeb", Enum.FontWeight.SemiBold, Enum.Font.GothamMedium),
			body = font("TitilliumWeb", Enum.FontWeight.SemiBold, Enum.Font.GothamMedium),
		},
		caps = true,
		stroke = { thickness = 1.5, color = hex("000000"), transparency = 0.45 },
		softShadow = false,
		panelKind = "fade",
		barKind = "angled",
		corner = 0,
		glyphHollow = true,
	},
	glass = {
		id = "glass",
		colors = {
			text = hex("EAF2F7"),
			dim = hex("9FB0C0"),
			objective = hex("39D0C8"),
			own = hex("FFC266"),
			danger = hex("FF5A6A"),
			heal = hex("7CF29B"),
			rare = hex("FFA057"),
			line = hex("FFFFFF"),
			shadow = hex("000000"),
			panel = hex("101A24"),
		},
		fonts = {
			number = font("BuilderSans", Enum.FontWeight.Bold, Enum.Font.GothamBold),
			label = font("BuilderSans", Enum.FontWeight.Bold, Enum.Font.GothamBold),
			body = font("BuilderSans", Enum.FontWeight.Medium, Enum.Font.GothamMedium),
		},
		caps = false,
		stroke = nil,
		softShadow = true,
		panelKind = "glass",
		barKind = "pill",
		corner = 8,
		glyphHollow = false,
	},
	visor = {
		id = "visor",
		colors = {
			text = hex("7FF3E6"),
			dim = hex("3E8C84"),
			objective = hex("7FF3E6"),
			own = hex("7FF3E6"),
			danger = hex("FF4F5E"),
			heal = hex("C8FFF7"),
			rare = hex("C8FFF7"),
			line = hex("7FF3E6"),
			shadow = hex("03211E"),
			panel = hex("7FF3E6"),
		},
		fonts = {
			number = font("RobotoMono", Enum.FontWeight.Bold, Enum.Font.Code),
			label = font("Jura", Enum.FontWeight.Bold, Enum.Font.GothamBold),
			body = font("Jura", Enum.FontWeight.Bold, Enum.Font.GothamBold),
		},
		caps = true,
		stroke = { thickness = 1, color = hex("03211E"), transparency = 0.3 },
		softShadow = false,
		panelKind = "scan",
		barKind = "ticks",
		corner = 0,
		glyphHollow = true,
	},
}

-- old HUD colours (HudStyle's constants) for HudSkin.color() with the old HUD selected
local OLD = {
	text = Color3.new(1, 1, 1),
	dim = hex("A7ADB7"),
	objective = hex("5FD4E6"),
	own = hex("F5B93A"),
	danger = hex("D8232A"),
	heal = hex("57D163"),
	rare = hex("F07A2B"),
	line = Color3.new(1, 1, 1),
	shadow = Color3.new(0, 0, 0),
	panel = Color3.new(0, 0, 0),
}

local VALUE_TO_ID = { glass = "glass", visor = "visor", old = "old" }

function HudSkin.id(): string
	local v = workspace:GetAttribute(ATTR)
	return (type(v) == "string" and VALUE_TO_ID[v]) or "hairline"
end

function HudSkin.current(): Skin?
	local id = HudSkin.id()
	if id == "old" then
		return nil
	end
	return HudSkin.SKINS[id]
end

function HudSkin.isNew(): boolean
	return HudSkin.id() ~= "old"
end

function HudSkin.color(role: string): Color3
	local s = HudSkin.current()
	local set = if s then s.colors else OLD
	local c = set[role] or set.text
	if s and HudSkin.preset() == "frame" then
		-- high-contrast frame preset: brighten muted/secondary text and keep text pure
		if role == "text" and s.id ~= "visor" then
			return Color3.new(1, 1, 1)
		elseif role == "dim" then
			return c:Lerp(set.text, 0.45)
		end
	end
	return c
end

function HudSkin.font(role: string?): Font
	local s = HudSkin.current()
	if not s then
		return Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
	end
	return s.fonts[role or "label"] or s.fonts.label
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

-- Font + text treatment on an existing TextLabel / TextButton. Safe to call again after a skin change.
function HudSkin.styleText(l: any, role: string?)
	local s = HudSkin.current()
	if not s then
		return
	end
	l.FontFace = s.fonts[role or "label"] or s.fonts.label
	local st = strokeOf(l)
	local preset = HudSkin.preset()
	-- strokes cost a draw pass; phones skip them only on truly tiny text unless in high-contrast frame mode
	local small = isTouch() and (l.TextSize or 14) < 12 and preset ~= "frame"
	if s.stroke and not small then
		if not st then
			st = Instance.new("UIStroke")
			st.Name = "SkinStroke"
			st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			st.Parent = l
		end
		local stroke = st :: UIStroke
		stroke.Thickness = if preset == "frame" then math.max(s.stroke.thickness, 2) else s.stroke.thickness
		stroke.Color = s.stroke.color
		stroke.Transparency = if preset == "frame" then math.min(s.stroke.transparency, 0.2) else s.stroke.transparency
		l.TextStrokeTransparency = 1
	else
		if st then
			st:Destroy()
		end
		l.TextStrokeTransparency = 1
	end
end

-- Soft shadow (glass, Shadow = true): a wide faint dark edge. (A dark copy of the label would have to be its child,
-- and children draw above their parent, so it would cover the text.)
local function addSoftShadow(l: TextLabel)
	if isTouch() and l.TextSize < 13 then
		return
	end
	local st = strokeOf(l)
	if not st then
		st = Instance.new("UIStroke")
		st.Name = "SkinStroke"
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Parent = l
	end
	local stroke = st :: UIStroke
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.78
end

local LABEL_SKIP = { Role = true, ColorRole = true, Color = true, XAlign = true, YAlign = true, Shadow = true, Rich = true, Wrap = true }
-- props: Role (number | label | body, default label), ColorRole or Color, Text, TextSize (default 14), XAlign, YAlign,
-- Rich, Wrap, Shadow (soft shadow on glass), + any TextLabel property
function HudSkin.label(p: { [string]: any }?): TextLabel
	p = p or {}
	local s = HudSkin.current()
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.TextSize = p.TextSize or 14
	l.TextColor3 = p.Color or HudSkin.color(p.ColorRole or "text")
	l.TextXAlignment = p.XAlign or Enum.TextXAlignment.Left
	l.TextYAlignment = p.YAlign or Enum.TextYAlignment.Center
	l.TextWrapped = p.Wrap == true
	l.RichText = p.Rich == true
	l.Text = ""
	if s then
		HudSkin.styleText(l, p.Role)
	else
		l.FontFace = HudSkin.font(p.Role)
		l.TextStrokeColor3 = Color3.new(0, 0, 0)
		l.TextStrokeTransparency = 0.65
	end
	local parent = nil
	for k, v in p do
		if LABEL_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		elseif k == "Text" and type(v) == "string" then
			l.Text = if (not s or s.caps) and not p.Rich then string.upper(v) else v
		else
			(l :: any)[k] = v
		end
	end
	if s and s.softShadow and p.Shadow == true then
		addSoftShadow(l)
	end
	l.Parent = parent
	return l
end

-- Panels -----------------------------------------------------------------------------------------------------------
local function gradient(parent: Instance, seq: NumberSequence, rotation: number): UIGradient
	local g = Instance.new("UIGradient")
	g.Transparency = seq
	g.Rotation = rotation
	g.Parent = parent
	return g
end

local SCAN_SEQ: NumberSequence? = nil
local function scanSeq(): NumberSequence
	if not SCAN_SEQ then
		local kps = {}
		local n = 16
		for i = 0, n - 1 do
			local t = i / (n - 1)
			table.insert(kps, NumberSequenceKeypoint.new(t, if i % 2 == 0 then 0.9 else 0.97))
		end
		SCAN_SEQ = NumberSequence.new(kps)
	end
	return SCAN_SEQ :: NumberSequence
end

-- kind: "none" (transparent group frame), "fade" (black, left-to-right fade 0.35 -> 1), "glass" (rounded translucent
-- card with a 1 px edge and a top highlight), "scan" (faint phosphor scanlines), "auto" (the skin's own kind; "none"
-- with the old HUD). props = any Frame property (Parent last).
function HudSkin.panel(kind: string?, props: { [string]: any }?): Frame
	local s = HudSkin.current()
	local preset = HudSkin.preset()
	local k = kind or "auto"
	if k == "auto" then
		k = if s then s.panelKind else "none"
	end
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundTransparency = 1
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	if k == "banner" then
		-- strong backing plate for banners (bold / clean)
		f.BackgroundColor3 = if s and s.id == "glass" then HudSkin.SKINS.glass.colors.panel else hex("070B12")
		f.BackgroundTransparency = if preset == "bold" then 0.16 else 0.24
		if s and s.id == "glass" then
			local cr = Instance.new("UICorner")
			cr.CornerRadius = UDim.new(0, 10)
			cr.Parent = f
		end
		local st = Instance.new("UIStroke")
		st.Name = "SkinEdge"
		st.Color = if s then s.colors.line else Color3.new(1, 1, 1)
		st.Transparency = if preset == "frame" then 0.35 elseif preset == "bold" then 0.6 else 0.78
		st.Thickness = if preset == "bold" then 1.5 else 1
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	elseif k == "chip" then
		-- compact pill/chip backing for Clean preset
		f.BackgroundColor3 = if s and s.id == "glass" then HudSkin.SKINS.glass.colors.panel else hex("0B111A")
		f.BackgroundTransparency = 0.22
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0.5, 0)
		cr.Parent = f
		local st = Instance.new("UIStroke")
		st.Name = "SkinEdge"
		st.Color = if s then s.colors.line else Color3.new(1, 1, 1)
		st.Transparency = 0.72
		st.Thickness = 1
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	elseif preset == "frame" and k ~= "none" then
		-- high-contrast solid backing for Frame preset
		f.BackgroundColor3 = hex("06090F")
		f.BackgroundTransparency = 0.1
		local st = Instance.new("UIStroke")
		st.Name = "SkinEdge"
		st.Color = if s then s.colors.line else Color3.new(1, 1, 1)
		st.Transparency = 0.42
		st.Thickness = 1.5
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	elseif k == "fade" then
		f.BackgroundTransparency = 0
		local a0 = if preset == "bold" then 0.14 else 0.35
		local a1 = if preset == "bold" then 0.88 else 1
		gradient(f, NumberSequence.new(a0, a1), 0).Name = "SkinFade"
	elseif k == "glass" then
		f.BackgroundTransparency = 0
		f.BackgroundColor3 = HudSkin.SKINS.glass.colors.panel
		local a0 = if preset == "bold" then 0.1 else 0.25
		local a1 = if preset == "bold" then 0.34 else 0.55
		gradient(
			f,
			NumberSequence.new({ NumberSequenceKeypoint.new(0, a0), NumberSequenceKeypoint.new(1, a1) }),
			90
		).Name = "SkinGlass"
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0, (s and s.id == "glass") and s.corner or 8)
		cr.Parent = f
		local st = Instance.new("UIStroke")
		st.Name = "SkinEdge"
		st.Color = Color3.new(1, 1, 1)
		st.Transparency = if preset == "bold" then 0.62 else 0.82
		st.Thickness = if preset == "bold" then 1.5 else 1
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
		-- in a Folder so a UIListLayout inside the panel ignores it
		local deco = Instance.new("Folder")
		deco.Name = "SkinDeco"
		deco.Parent = f
		local hi = Instance.new("Frame")
		hi.Name = "SkinHighlight"
		hi.BorderSizePixel = 0
		hi.BackgroundColor3 = Color3.new(1, 1, 1)
		hi.BackgroundTransparency = if preset == "bold" then 0.78 else 0.88
		hi.Position = UDim2.fromOffset(6, 1)
		hi.Size = UDim2.new(1, -12, 0, 1)
		hi.Parent = deco
	elseif k == "scan" then
		f.BackgroundTransparency = if preset == "bold" then 0.45 else 0
		f.BackgroundColor3 = if preset == "bold" then hex("041815") else HudSkin.SKINS.visor.colors.panel
		gradient(f, scanSeq(), 90).Name = "SkinScan"
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
local SQ2 = math.sqrt(2)

-- angled cap (hairline): a right triangle made of a 45 degree square clipped by an h x h frame. side "left" fills the
-- bottom-right half (bottom edge reaches further left), "right" the top-left half: together a "/" parallelogram.
local function angledCap(track: Frame, side: string, h: number): Frame
	local clip = Instance.new("Frame")
	clip.Name = "Cap" .. side
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.ClipsDescendants = true
	clip.Size = UDim2.fromOffset(h, h)
	if side == "left" then
		clip.AnchorPoint = Vector2.new(1, 0)
		clip.Position = UDim2.fromScale(0, 0)
	else
		clip.AnchorPoint = Vector2.new(0, 0)
		clip.Position = UDim2.fromScale(1, 0)
	end
	clip.Parent = track.Parent
	local sq = Instance.new("Frame")
	sq.Name = "Part"
	sq.BorderSizePixel = 0
	sq.AnchorPoint = Vector2.new(0.5, 0.5)
	sq.Rotation = 45
	sq.Size = UDim2.fromOffset(math.ceil(h * SQ2), math.ceil(h * SQ2))
	sq.Position = if side == "left" then UDim2.fromScale(1, 1) else UDim2.fromScale(0, 0)
	sq.Parent = clip
	return sq
end

export type Bar = {
	root: Frame,
	fill: Frame?,
	set: (alpha: number, color: Color3?) -> (),
	ghost: (alpha: number) -> (),
	track: (color: Color3, alpha: number?) -> (),
}

local BAR_SKIP = { Color = true, Ghost = true, Segments = true, Ticks = true, Height = true }

-- Skin bar. The root frame takes Size / Position / AnchorPoint / LayoutOrder / Name from props. Writes only on change.
function HudSkin.bar(p: { [string]: any }): Bar
	local s = HudSkin.current()
	local kind = if s then s.barKind else "flat"
	local col: Color3 = p.Color or HudSkin.color("text")
	local trackCol = Color3.new(0, 0, 0)
	local trackAlpha = 0.5
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
	local bar: any = { root = root }
	local shownA, shownG, shownCol = -1, -1, nil

	if kind == "ticks" then
		local n: number = p.Ticks or 30
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Horizontal
		list.Padding = UDim.new(0, 1)
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = root
		local ticks = {}
		for i = 1, n do
			local t = Instance.new("Frame")
			t.Name = "Tick"
			t.BorderSizePixel = 0
			t.LayoutOrder = i
			t.Size = UDim2.new(1 / n, -1, 1, 0)
			t.BackgroundColor3 = col
			t.BackgroundTransparency = 0.8
			t.Parent = root
			ticks[i] = t
		end
		local function paint(alpha: number, ghostA: number, c: Color3)
			local lit = math.ceil(Theme.clamp(alpha, 0, 1) * n - 0.001)
			local ghostLit = math.ceil(Theme.clamp(ghostA, 0, 1) * n - 0.001)
			for i, t in ticks do
				if i <= lit then
					t.BackgroundColor3 = c
					t.BackgroundTransparency = 0
				elseif i <= ghostLit then
					t.BackgroundColor3 = HudSkin.color("danger")
					t.BackgroundTransparency = 0.35
				else
					t.BackgroundColor3 = c
					t.BackgroundTransparency = 0.82
				end
			end
		end
		local curA, curG = 1, 0
		function bar.set(alpha: number, c: Color3?)
			local nc = c or col
			local litNow = math.ceil(Theme.clamp(alpha, 0, 1) * n - 0.001)
			if litNow == shownA and nc == shownCol then
				return
			end
			shownA, shownCol, col, curA = litNow, nc, nc, alpha
			paint(curA, curG, col)
		end
		function bar.ghost(alpha: number)
			local g = math.ceil(Theme.clamp(alpha, 0, 1) * n - 0.001)
			if g == shownG then
				return
			end
			shownG, curG = g, alpha
			paint(curA, curG, col)
		end
		function bar.track(_c: Color3, _a: number?) end
		root.Parent = parent
		return bar
	end

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BorderSizePixel = 0
	track.BackgroundColor3 = trackCol
	track.BackgroundTransparency = trackAlpha
	track.Size = UDim2.fromScale(1, 1)
	track.ClipsDescendants = kind ~= "pill"
	track.Parent = root
	local ghost: Frame? = nil
	if p.Ghost then
		local gf = Instance.new("Frame")
		gf.Name = "Ghost"
		gf.BorderSizePixel = 0
		gf.BackgroundColor3 = HudSkin.color("danger"):Lerp(Color3.new(1, 1, 1), 0.45)
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
	bar.fill = fill

	local capL, capR = nil, nil
	if kind == "pill" then
		for _, f in { track, fill, ghost } do
			if f then
				local cr = Instance.new("UICorner")
				cr.CornerRadius = UDim.new(0.5, 0)
				cr.Parent = f
			end
		end
	elseif kind == "angled" then
		-- caps sit outside the track on both ends; the height is read once the bar has a size
		local function addCaps()
			local h = root.AbsoluteSize.Y
			if h <= 0 or capL then
				return
			end
			-- caps are measured in the root's own (layout) pixels
			local scale = 1
			local anc = root.Parent
			while anc and not anc:IsA("LayerCollector") do
				local us = anc:FindFirstChildOfClass("UIScale")
				if us then
					scale *= us.Scale
				end
				anc = anc.Parent
			end
			local hl = math.max(2, math.round(h / math.max(scale, 0.01)))
			capL = angledCap(track, "left", hl)
			capR = angledCap(track, "right", hl)
			capL.BackgroundColor3 = col
			capL.BackgroundTransparency = 0
			capR.BackgroundColor3 = trackCol
			capR.BackgroundTransparency = trackAlpha
			-- refresh the cap colours to the last set() value
			shownA = -1
			if bar._last then
				bar.set(bar._last[1], bar._last[2])
			end
		end
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(addCaps)
		task.defer(addCaps)
		if p.Segments then
			for _, x in { 0.25, 0.5, 0.75 } do
				local gap = Instance.new("Frame")
				gap.Name = "Gap"
				gap.BorderSizePixel = 0
				gap.BackgroundColor3 = Color3.new(0, 0, 0)
				gap.BackgroundTransparency = 0.2
				gap.AnchorPoint = Vector2.new(0.5, 0)
				gap.Position = UDim2.fromScale(x, 0)
				gap.Size = UDim2.new(0, 2, 1, 0)
				gap.ZIndex = 3
				gap.Parent = track
			end
		end
	end

	function bar.set(alpha: number, c: Color3?)
		local a = Theme.clamp(alpha, 0, 1)
		local nc = c or col
		bar._last = { a, c }
		if math.abs(a - shownA) > 0.0005 then
			shownA = a
			fill.Size = UDim2.fromScale(a, 1)
		end
		if nc ~= shownCol then
			shownCol, col = nc, nc
			fill.BackgroundColor3 = nc
		end
		if capL then
			capL.BackgroundColor3 = if a > 0.001 then nc else trackCol
			capL.BackgroundTransparency = if a > 0.001 then fill.BackgroundTransparency else trackAlpha
		end
		if capR then
			local full = a >= 0.999
			capR.BackgroundColor3 = if full then nc else trackCol
			capR.BackgroundTransparency = if full then fill.BackgroundTransparency else trackAlpha
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
-- fades every GuiObject / UIStroke under (and including) inst between its authored look (a = 0) and invisible (a = 1);
-- the authored values are remembered the first time an instance is faded
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
		return UDim2.fromOffset(-12, 0)
	elseif from == "right" then
		return UDim2.fromOffset(12, 0)
	elseif from == "bottom" then
		return UDim2.fromOffset(0, 12)
	elseif from == "top" then
		return UDim2.fromOffset(0, -12)
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
	local s = HudSkin.current()
	nextGen(inst)
	inst.Visible = true
	if not s then
		return
	end
	if s.id == "hairline" then
		local home = inst:GetAttribute("SkinHome") or inst.Position
		inst:SetAttribute("SkinHome", home)
		inst.Position = home + slideOffset(from)
		HudSkin.fade(inst, 1, 0)
		Theme.tween(inst, 0.18, { Position = home }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		HudSkin.fade(inst, 0, 0.18)
	elseif s.id == "glass" then
		local us = scaleOf(inst, "SkinPop")
		us.Scale = 0.92
		HudSkin.fade(inst, 1, 0)
		Theme.tween(us, 0.22, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		HudSkin.fade(inst, 0, 0.22)
	else
		-- visor: three quick flickers
		local g = motionGen[inst]
		task.spawn(function()
			for _, a in { 0, 0.6, 0, 0.6, 0 } do
				if motionGen[inst] ~= g or not inst.Parent then
					return
				end
				HudSkin.fade(inst, a, 0)
				task.wait(0.024)
			end
		end)
	end
end

function HudSkin.leave(inst: GuiObject, destroy: boolean?)
	local s = HudSkin.current()
	local g = nextGen(inst)
	local function finish()
		if motionGen[inst] ~= g or not inst.Parent then
			return
		end
		if destroy then
			inst:Destroy()
		else
			inst.Visible = false
			HudSkin.fade(inst, 0, 0)
			local us = inst:FindFirstChild("SkinPop")
			if us and us:IsA("UIScale") then
				us.Scale = 1
			end
			local h = inst:GetAttribute("SkinHeight")
			if typeof(h) == "UDim2" then
				inst.Size = h
				inst:SetAttribute("SkinHeight", nil)
			end
		end
	end
	if not s then
		if destroy then
			inst:Destroy()
		else
			inst.Visible = false
		end
		return
	end
	local t = 0.25
	if s.id == "glass" then
		t = 0.2
		Theme.tween(scaleOf(inst, "SkinPop"), t, { Scale = 0.96 })
		HudSkin.fade(inst, 1, t)
	elseif s.id == "visor" then
		t = 0.15
		if not inst:GetAttribute("SkinHeight") then
			inst:SetAttribute("SkinHeight", inst.Size)
		end
		local sz = inst.Size
		if inst.AutomaticSize == Enum.AutomaticSize.None then
			Theme.tween(inst, t, { Size = UDim2.new(sz.X.Scale, sz.X.Offset, 0, 1) })
		end
		HudSkin.fade(inst, 1, t)
	else
		HudSkin.fade(inst, 1, t)
	end
	task.delay(t + 0.02, finish)
end

-- "this value changed": hairline / visor scale pop on the instance, glass flashes the panel edge if it has one
function HudSkin.bump(inst: GuiObject)
	local s = HudSkin.current()
	if not s then
		return
	end
	if s.id == "glass" then
		local edge = inst:FindFirstChild("SkinEdge")
		if edge and edge:IsA("UIStroke") then
			edge.Color = s.colors.own
			edge.Transparency = 0.2
			Theme.tween(edge, 0.3, { Transparency = 0.82, Color = Color3.new(1, 1, 1) })
			return
		end
	end
	local us = scaleOf(inst, "SkinBump")
	us.Scale = if s.id == "visor" then 1.08 else 1.15
	Theme.tween(us, 0.12, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

-- Goal-change text transition. Old HUD: plain set.
function HudSkin.swapText(l: TextLabel, text: string)
	local s = HudSkin.current()
	if s and s.caps then
		text = string.upper(text)
	end
	if not s or l.Text == text then
		l.Text = text
		return
	end
	local g = nextGen(l)
	if s.id == "hairline" then
		l.Text = text
		l.MaxVisibleGraphemes = 0
		local n = utf8.len(text) or #text
		task.spawn(function()
			local t0 = os.clock()
			while motionGen[l] == g and l.Parent do
				local u = (os.clock() - t0) / 0.3
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
	elseif s.id == "glass" then
		Theme.tween(l, 0.12, { TextTransparency = 1 })
		task.delay(0.12, function()
			if motionGen[l] ~= g or not l.Parent then
				return
			end
			l.Text = text
			Theme.tween(l, 0.13, { TextTransparency = 0 })
		end)
	else
		-- visor: rewrite character by character behind a cursor
		task.spawn(function()
			local n = #text
			local t0 = os.clock()
			while motionGen[l] == g and l.Parent do
				local u = (os.clock() - t0) / 0.35
				if u >= 1 then
					break
				end
				l.Text = string.sub(text, 1, math.floor(n * u)) .. "_"
				RunService.Heartbeat:Wait()
			end
			if motionGen[l] == g then
				l.Text = text
			end
		end)
	end
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
