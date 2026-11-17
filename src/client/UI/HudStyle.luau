-- In-mission HUD style kit: thin, flat, edge-hugging panels (black 55 % transparent, square corners, 1 px white corner
-- brackets at 70 % opacity), condensed bold caps font, four accent colours. Used by HUD / AlertBar / CallInList / ...
-- Ship lobby screens keep using Theme; nothing here touches Theme's own helpers.
local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)

local Style = {}

Style.Amber = Color3.fromHex("F5B93A") -- own / neutral
Style.Cyan = Color3.fromHex("5FD4E6") -- objectives
Style.Red = Color3.fromHex("D8232A") -- alerts
Style.Green = Color3.fromHex("57D163") -- samples / friendly
Style.Orange = Color3.fromHex("F07A2B") -- rare pickups
Style.Grey = Color3.fromHex("A7ADB7")
Style.White = Color3.new(1, 1, 1)
Style.Black = Color3.new(0, 0, 0)

-- UI STYLE (UI/HudSkin): the colour fields above and Style.Font follow the active skin. HUD.rebuild() calls
-- Style.refreshSkin() before building again, so modules that read them at build time follow too. Old HUD = the values above.
local OLD_COLORS = {
	Amber = Style.Amber,
	Cyan = Style.Cyan,
	Red = Style.Red,
	Green = Style.Green,
	Orange = Style.Orange,
	Grey = Style.Grey,
	White = Style.White,
}
local SKIN_ROLE = { Amber = "own", Cyan = "objective", Red = "danger", Green = "heal", Orange = "rare", Grey = "dim", White = "text" }

Style.MARGIN = 16
Style.PANEL_ALPHA = 0.55 -- BackgroundTransparency of the black panels
Style.BRACKET_ALPHA = 0.3 -- = 70 % opaque
Style.TEXT = 14
Style.ALERT = 18

-- Condensed bold caps face. Oswald Bold via its font family; Gotham Bold if the family cannot be built.
local function makeFont(): Font
	local ok, f = pcall(function()
		return Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
	end)
	if ok and f then
		return f
	end
	return Font.fromEnum(Enum.Font.GothamBold)
end
local OLD_FONT = makeFont()
Style.Font = OLD_FONT

function Style.refreshSkin()
	local s = HudSkin.current()
	for k, c in OLD_COLORS do
		(Style :: any)[k] = if s then s.colors[SKIN_ROLE[k]] else c
	end
	Style.Font = if s then s.fonts.label else OLD_FONT
end
Style.refreshSkin()

function Style.up(s: any): string
	return string.upper(tostring(s or ""))
end

-- 1 px corner brackets around a frame (children of a Folder, so a UIListLayout in `frame` ignores them)
function Style.brackets(frame: GuiObject, color: Color3?, arm: number?, alpha: number?): Folder
	if HudSkin.current() then
		-- the new skins draw no corner brackets on elements; an empty holder keeps callers working
		local empty = Instance.new("Folder")
		empty.Name = "Brackets"
		empty.Parent = frame
		return empty
	end
	local col = color or Style.White
	local len = arm or 6
	local tr = alpha or Style.BRACKET_ALPHA
	local holder = Instance.new("Folder")
	holder.Name = "Brackets"
	local function bar(anchor: Vector2, pos: UDim2, size: UDim2)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = col
		f.BackgroundTransparency = tr
		f.BorderSizePixel = 0
		f.AnchorPoint = anchor
		f.Position = pos
		f.Size = size
		f.ZIndex = frame.ZIndex + 2
		f.Parent = holder
	end
	bar(Vector2.new(0, 0), UDim2.fromOffset(0, 0), UDim2.fromOffset(len, 1))
	bar(Vector2.new(0, 0), UDim2.fromOffset(0, 0), UDim2.fromOffset(1, len))
	bar(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromOffset(len, 1))
	bar(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromOffset(1, len))
	bar(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromOffset(len, 1))
	bar(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromOffset(1, len))
	bar(Vector2.new(1, 1), UDim2.fromScale(1, 1), UDim2.fromOffset(len, 1))
	bar(Vector2.new(1, 1), UDim2.fromScale(1, 1), UDim2.fromOffset(1, len))
	holder.Parent = frame
	return holder
end

local PANEL_SKIP = { Color = true, Transparency = true, Brackets = true, BracketColor = true }
-- Flat panel. p: Color, Transparency (default 0.55), Brackets (default true), BracketColor, plus any Frame property.
function Style.panel(p: { [string]: any }?): Frame
	p = p or {}
	local skin = HudSkin.current()
	if skin then
		return Style.skinPanel(p :: { [string]: any }, skin)
	end
	local f = Instance.new("Frame")
	f.BackgroundColor3 = p.Color or Style.Black
	f.BackgroundTransparency = p.Transparency or Style.PANEL_ALPHA
	f.BorderSizePixel = 0
	local parent = nil
	for k, v in p do
		if PANEL_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		else
			(f :: any)[k] = v
		end
	end
	if p.Brackets ~= false then
		Style.brackets(f, p.BracketColor)
	end
	f.Parent = parent
	return f
end

-- Style.panel with a new skin: black panels become the skin's backing (fade / glass / scan); coloured panels (red alert
-- bar, amber fills) keep their colour and alpha, rounded on glass.
function Style.skinPanel(p: { [string]: any }, skin: any): Frame
	local coloured = p.Color ~= nil and p.Color ~= Style.Black and p.Color ~= Color3.new(0, 0, 0)
	local f: Frame
	if coloured then
		f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = p.Color
		f.BackgroundTransparency = p.Transparency or Style.PANEL_ALPHA
		if skin.id == "glass" then
			local cr = Instance.new("UICorner")
			cr.CornerRadius = UDim.new(0, skin.corner)
			cr.Parent = f
		end
	else
		f = HudSkin.panel("auto")
	end
	local parent = nil
	for k, v in p do
		if PANEL_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		else
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

local LABEL_SKIP = { Color = true, XAlign = true, YAlign = true, Wrap = true, Rich = true, Shadow = true }
-- Caps label in the HUD font. p: Text, Color, TextSize (default 14), XAlign (default Left), YAlign, Rich, Wrap + any property.
function Style.label(p: { [string]: any }?): TextLabel
	p = p or {}
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.FontFace = Style.Font
	l.TextColor3 = p.Color or Style.White
	l.TextSize = p.TextSize or Style.TEXT
	l.TextXAlignment = p.XAlign or Enum.TextXAlignment.Left
	l.TextYAlignment = p.YAlign or Enum.TextYAlignment.Center
	l.TextWrapped = p.Wrap == true
	l.RichText = p.Rich == true
	l.TextStrokeColor3 = Style.Black
	l.TextStrokeTransparency = p.Shadow == false and 1 or 0.65
	l.Text = ""
	local skin = HudSkin.current()
	local caps = not skin or skin.caps
	local parent = nil
	for k, v in p do
		if LABEL_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		elseif k == "Text" and type(v) == "string" then
			l.Text = if p.Rich or not caps then v else string.upper(v)
		else
			(l :: any)[k] = v
		end
	end
	if skin then
		-- skin font + text treatment (UIStroke instead of TextStroke); Shadow = false keeps the text bare
		HudSkin.styleText(l, "label")
		if p.Shadow == false then
			local st = l:FindFirstChild("SkinStroke")
			if st then
				st:Destroy()
			end
		end
	end
	l.Parent = parent
	return l
end

-- Plain solid rectangle (bars, ticks, separators)
function Style.rect(p: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = p.Color or Style.White
	f.BackgroundTransparency = p.Transparency or 0
	local parent = nil
	for k, v in p do
		if k == "Color" or k == "Transparency" then
			continue
		end
		if k == "Parent" then
			parent = v
		else
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- Thin horizontal bar: back track + fill. Returns { back, fill, set(alpha, color?) }.
function Style.bar(p: { [string]: any }): any
	local back = Style.rect({
		Name = p.Name or "Bar",
		Color = Style.Black,
		Transparency = 0.45,
		Size = p.Size or UDim2.new(1, 0, 0, 3),
		Position = p.Position,
		AnchorPoint = p.AnchorPoint,
		LayoutOrder = p.LayoutOrder,
		ClipsDescendants = true,
		Parent = p.Parent,
	})
	local fill = Style.rect({
		Name = "Fill",
		Color = p.Color or Style.White,
		Size = UDim2.fromScale(0, 1),
		Parent = back,
	})
	local skin = HudSkin.current()
	if skin and skin.barKind == "pill" then
		back.ClipsDescendants = false
		for _, f in { back, fill } do
			local cr = Instance.new("UICorner")
			cr.CornerRadius = UDim.new(0.5, 0)
			cr.Parent = f
		end
	end
	local bar = { back = back, fill = fill }
	function bar.set(alpha: number, color: Color3?)
		fill.Size = UDim2.fromScale(Theme.clamp(alpha, 0, 1), 1)
		if color then
			fill.BackgroundColor3 = color
		end
	end
	return bar
end

-- Drawn glyphs -----------------------------------------------------------------------------------------------------------
-- Roblox fonts only cover ASCII reliably (symbols such as arrows, diamonds, gears, stars and emoji render as empty boxes),
-- so every icon-like mark is built from plain Frames. Style.glyph(shape, props) returns a transparent host Frame; recolour it
-- with Style.tint(host, colour), fade it with Style.glyphAlpha(host, t) / Style.glyphTween(host, time, t).
-- shapes: diamond, diamondHollow, square, dot, ring, reticle, up, down, right, left, cross, plus, bar, dash, star, cog, token, lock, check, skull
local SQ2 = math.sqrt(2)

local function gpart(host: Instance, hollow: boolean?): Frame
	local f = Instance.new("Frame")
	f.Name = "Part"
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.BackgroundColor3 = Style.White
	if hollow then
		f.BackgroundTransparency = 1
		f:SetAttribute("Hollow", true)
		local st = Instance.new("UIStroke")
		st.Name = "Part"
		st.Thickness = 1.5
		st.Color = Style.White
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	end
	f.Parent = host
	return f
end

local function gsize(f: Frame, w: number, h: number)
	f.Size = UDim2.fromOffset(math.max(1, math.round(w)), math.max(1, math.round(h)))
end

-- Triangle: a 45 degree square clipped by a half-size frame. dir = up | down | right | left
local function gtriangle(host: Frame, dir: string, size: number)
	local clip = Instance.new("Frame")
	clip.Name = "Clip"
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.ClipsDescendants = true
	clip.AnchorPoint = Vector2.new(0.5, 0.5)
	clip.Position = UDim2.fromScale(0.5, 0.5)
	local horizontal = dir == "right" or dir == "left"
	if horizontal then
		clip.Size = UDim2.fromOffset(math.round(size / 2), size)
	else
		clip.Size = UDim2.fromOffset(size, math.round(size / 2))
	end
	clip.Parent = host
	local sq = gpart(clip)
	sq.Rotation = 45
	gsize(sq, size / SQ2, size / SQ2)
	if dir == "up" then
		sq.Position = UDim2.fromScale(0.5, 1)
	elseif dir == "down" then
		sq.Position = UDim2.fromScale(0.5, 0)
	elseif dir == "right" then
		sq.Position = UDim2.fromScale(0, 0.5)
	else
		sq.Position = UDim2.fromScale(1, 0.5)
	end
end

local GLYPH_SKIP = { Size = true, Color = true, Shape = true, Box = true }
-- props: Size = glyph size in px (default 12), Color, Box = UDim2 host size (default Size x Size), + any Frame property
function Style.glyph(shape: string, props: { [string]: any }?): Frame
	local p = props or {}
	local size: number = p.Size or 12
	local host = Instance.new("Frame")
	host.Name = "Glyph"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = p.Box or UDim2.fromOffset(size, size)
	local parent = nil
	for k, v in p do
		if GLYPH_SKIP[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		else
			(host :: any)[k] = v
		end
	end
	if shape == "diamond" then
		local d = gpart(host)
		d.Rotation = 45
		gsize(d, size / SQ2, size / SQ2)
	elseif shape == "diamondHollow" then
		local d = gpart(host, true)
		d.Rotation = 45
		gsize(d, size / SQ2 - 2, size / SQ2 - 2)
	elseif shape == "square" then
		gsize(gpart(host), size * 0.8, size * 0.8)
	elseif shape == "dot" or shape == "ring" then
		local d = gpart(host, shape == "ring")
		local s = if shape == "ring" then size * 0.8 - 2 else size * 0.8
		gsize(d, s, s)
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0.5, 0)
		cr.Parent = d
	elseif shape == "up" or shape == "down" or shape == "right" or shape == "left" then
		gtriangle(host, shape, size)
	elseif shape == "cross" then
		for _, rot in { 45, -45 } do
			local b = gpart(host)
			b.Rotation = rot
			gsize(b, 2, size * 0.95)
		end
	elseif shape == "plus" then
		local a = gpart(host)
		gsize(a, 3, size * 0.9)
		local b = gpart(host)
		gsize(b, size * 0.9, 3)
	elseif shape == "bar" then
		gsize(gpart(host), math.max(3, size * 0.4), size)
	elseif shape == "dash" then
		gsize(gpart(host), size, math.max(3, size * 0.3))
	elseif shape == "reticle" then
		local r = gpart(host, true)
		gsize(r, size * 0.9 - 2, size * 0.9 - 2)
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0.5, 0)
		cr.Parent = r
		local d = gpart(host)
		gsize(d, size * 0.3, size * 0.3)
		local cd = Instance.new("UICorner")
		cd.CornerRadius = UDim.new(0.5, 0)
		cd.Parent = d
	elseif shape == "star" then
		local a = gpart(host)
		gsize(a, size * 0.62, size * 0.62)
		local b = gpart(host)
		b.Rotation = 45
		gsize(b, size * 0.62, size * 0.62)
	elseif shape == "cog" then
		local r = gpart(host, true)
		gsize(r, size * 0.62, size * 0.62)
		local cr = Instance.new("UICorner")
		cr.CornerRadius = UDim.new(0.5, 0)
		cr.Parent = r
		for _, rot in { 0, 45, 90, 135 } do
			local b = gpart(host)
			b.Rotation = rot
			gsize(b, 2, size * 0.98)
		end
	elseif shape == "token" then
		local o = gpart(host, true)
		o.Rotation = 45
		gsize(o, size / SQ2 - 2, size / SQ2 - 2)
		local i = gpart(host)
		i.Rotation = 45
		gsize(i, size * 0.26, size * 0.26)
	elseif shape == "lock" then
		local body = gpart(host)
		body.Position = UDim2.fromScale(0.5, 0.68)
		gsize(body, size * 0.72, size * 0.5)
		local sh = gpart(host, true)
		sh.Position = UDim2.fromScale(0.5, 0.3)
		gsize(sh, size * 0.4, size * 0.5)
	elseif shape == "check" then
		local a = gpart(host)
		a.Rotation = 45
		a.Position = UDim2.fromScale(0.3, 0.62)
		gsize(a, 2, size * 0.4)
		local b = gpart(host)
		b.Rotation = -45
		b.Position = UDim2.fromScale(0.62, 0.5)
		gsize(b, 2, size * 0.8)
	elseif shape == "skull" then
		-- rounded cranium + narrower jaw; eye sockets, nose and tooth gaps are dark "Eye" frames (not tinted by Style.tint)
		local function dark(w: number, h: number, x: number, y: number, round: boolean): Frame
			local e = Instance.new("Frame")
			e.Name = "Eye"
			e.BorderSizePixel = 0
			e.BackgroundColor3 = Style.Black
			e.AnchorPoint = Vector2.new(0.5, 0.5)
			e.Position = UDim2.fromScale(x, y)
			gsize(e, w, h)
			if round then
				local c = Instance.new("UICorner")
				c.CornerRadius = UDim.new(0.5, 0)
				c.Parent = e
			end
			e.Parent = host
			return e
		end
		local skullPart = gpart(host)
		skullPart.Position = UDim2.fromScale(0.5, 0.4)
		gsize(skullPart, size * 0.88, size * 0.72)
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0.42, 0)
		cc.Parent = skullPart
		local jaw = gpart(host)
		jaw.Position = UDim2.fromScale(0.5, 0.8)
		gsize(jaw, size * 0.5, size * 0.34)
		local jc = Instance.new("UICorner")
		jc.CornerRadius = UDim.new(0.2, 0)
		jc.Parent = jaw
		dark(size * 0.22, size * 0.24, 0.31, 0.42, true)
		dark(size * 0.22, size * 0.24, 0.69, 0.42, true)
		dark(size * 0.08, size * 0.12, 0.5, 0.6, false)
		dark(math.max(1, size * 0.05), size * 0.2, 0.42, 0.88, false)
		dark(math.max(1, size * 0.05), size * 0.2, 0.58, 0.88, false)
	end
	Style.tint(host, p.Color or Style.White)
	host.Parent = parent
	return host
end

function Style.tint(host: Instance, color: Color3)
	for _, d in host:GetDescendants() do
		if d.Name == "Part" then
			if d:IsA("UIStroke") then
				d.Color = color
			elseif d:IsA("Frame") then
				d.BackgroundColor3 = color
			end
		end
	end
end

-- 0 = opaque, 1 = invisible (filled parts and outlines)
function Style.glyphAlpha(host: Instance, alpha: number)
	for _, d in host:GetDescendants() do
		if d.Name == "Part" then
			if d:IsA("UIStroke") then
				d.Transparency = alpha
			elseif d:IsA("Frame") and not d:GetAttribute("Hollow") then
				d.BackgroundTransparency = alpha
			end
		end
	end
end

function Style.glyphTween(host: Instance, time: number, alpha: number)
	for _, d in host:GetDescendants() do
		if d.Name == "Part" then
			if d:IsA("UIStroke") then
				Theme.tween(d, time, { Transparency = alpha })
			elseif d:IsA("Frame") and not d:GetAttribute("Hollow") then
				Theme.tween(d, time, { BackgroundTransparency = alpha })
			end
		end
	end
end

-- Short ASCII codes for the call-in icons (the CallIns data icons are dingbats the fonts lack). Shape follows the beacon colour.
local CALLIN_CODE = {
	LANCE = "LNC", HALFTON = "BMB", STRAFE = "STR", TOXIN = "TOX", EMP = "EMP", MINES = "MIN", SUPPLY = "SUP", BARRAGE = "BRG",
	SENTRY = "SEN", ROCKETDROP = "RKT", GATLINGDROP = "GAT", SHIELD = "SHD", SMOKE = "SMK", CLUSTER = "CLU", RAILDROP = "RAL",
	REINFORCE = "REIN", OVERWATCH = "OVR", DECOY = "DCY",
}
function Style.callinCode(def: any): string
	if not def then
		return "--"
	end
	return CALLIN_CODE[def.id] or string.upper(string.sub(tostring(def.id), 1, 3))
end

-- offense = diamond, supply = square (crate), defense = ring
function Style.callinShape(def: any): string
	if def and def.id == "REINFORCE" then
		return "plus"
	end
	local b = def and def.beacon
	if b == "supply" then
		return "square"
	elseif b == "defense" then
		return "ring"
	end
	return "diamond"
end

-- Row with the small ">" tick at its left. Returns (row, tick).
function Style.listRow(parent: Instance, height: number, order: number?, color: Color3?): (Frame, TextLabel)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, height)
	row.LayoutOrder = order or 0
	row.Parent = parent
	local tick = Style.label({
		Text = ">", -- "▸" has no glyph in the HUD font (renders as a box)
		TextSize = 12,
		Color = color or Style.Amber,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 10, 1, 0),
		Parent = row,
	})
	tick.Name = "Tick"
	return row, tick
end

-- Content frame inside a Theme.root: on touch everything is drawn at 0.8 x (smaller HUD, same 16 px margins in content space).
function Style.content(root: Frame, touch: boolean): Frame
	local k = if touch then 0.8 else 1
	local f = Instance.new("Frame")
	f.Name = "Content"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1 / k, 1 / k)
	local us = Theme.layoutScale(Instance.new("UIScale"))
	us.Scale = k
	us.Parent = f
	f.Parent = root
	return f
end

-- Extra size of the main readable boxes (uplink / area info column, own weapon card, timer block) on top of the viewport
-- scale that Theme.root + Style.content already apply. Phones are boosted too because content is drawn at 0.8 x there, but
-- less than PC so the left column still ends above the FEED button (y 50 %). Phones use 1.0 with the new global scale
-- (Theme.scaleFor + the text floor already make phone text readable); the "old" UI SCALE preset keeps 1.2.
Style.BOOST_PC = 1.3
Style.BOOST_TOUCH = 1.0
Style.BOOST_TOUCH_OLD = 1.2

-- Top-left column widths (content px, before the boost). Touch: main column (area info + objective) + uplink column.
Style.LEFT_PC_W = 230
Style.LEFT_TOUCH_W = 200
Style.CALLIN_TOUCH_W = 112

-- Right edge of the top-left column(s) in content px, boost included, plus a gap. Widgets that must stay clear of the
-- column horizontally (call-in cards) start here.
function Style.leftColumnRight(touch: boolean): number
	local w = if touch then Style.LEFT_TOUCH_W + 8 + Style.CALLIN_TOUCH_W else Style.LEFT_PC_W
	return Style.MARGIN + w * Style.boost(touch) + 16
end

function Style.boost(touch: boolean): number
	if touch then
		return if Theme.uiOld() then Style.BOOST_TOUCH_OLD else Style.BOOST_TOUCH
	end
	return Style.BOOST_PC
end

-- UIScale child on a (top-left / bottom-left / top-right anchored) frame: the frame grows by `Style.boost`, its position
-- offsets (screen margins) stay as they are. Follows the UI SCALE preset live. Returns the UIScale.
function Style.applyBoost(frame: GuiObject, touch: boolean, extra: number?): UIScale
	local us = Theme.layoutScale(Instance.new("UIScale"))
	us.Name = "Boost"
	us.Scale = Style.boost(touch) * (extra or 1)
	us.Parent = frame
	Theme.onScaleChanged(function()
		if us.Parent then
			us.Scale = Style.boost(touch) * (extra or 1)
		end
	end)
	return us
end

-- Callsigns: squad members sorted by userId get S1, S2, S3 ... and a stable colour. The local player is always amber.
local PALETTE = { Color3.fromHex("5FD4E6"), Color3.fromHex("57D163"), Color3.fromHex("F07A2B"), Color3.fromHex("D98AE6"), Color3.fromHex("E8E26A") }
local callsigns: { [number]: { tag: string, color: Color3, index: number } } = {}
local localId = 0

function Style.setSquad(squad: any, myUserId: number)
	localId = myUserId
	table.clear(callsigns)
	if type(squad) ~= "table" then
		return
	end
	local ids = {}
	for _, m in squad do
		if type(m) == "table" and type(m.userId) == "number" then
			table.insert(ids, m.userId)
		end
	end
	table.sort(ids)
	for i, id in ids do
		callsigns[id] = {
			tag = "S" .. tostring(i),
			color = if id == myUserId then Style.Amber else PALETTE[(i - 1) % #PALETTE + 1],
			index = i,
		}
	end
end

function Style.callsign(userId: number): { tag: string, color: Color3, index: number }
	local c = callsigns[userId]
	if c then
		return c
	end
	return { tag = "S1", color =if userId == localId then Style.Amber else PALETTE[1], index = 1 }
end

-- Tween that tolerates dead instances
function Style.tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?)
	return Theme.tween(inst, t, props, style)
end

return Style
