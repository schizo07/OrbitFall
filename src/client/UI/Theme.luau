-- UI theme + constructors shared by HUD / Screens / UplinkDial / MobileControls.
-- Style: chunky sci-fi stencil. Dark navy panels, orange accent, teal friendly, white text with black stroke.
-- All sizes in these helpers are plain pixels; each ScreenGui gets a UIScale root via Theme.root().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Theme = {}

-- Colours -------------------------------------------------------------------------------------------
local C = table.clone(Config.Colors)
C.Dark = Color3.fromHex("0b0f17")
C.PanelLight = Color3.fromHex("26314a")
C.PanelHi = Color3.fromHex("33405e")
C.White = Color3.new(1, 1, 1)
C.Black = Color3.new(0, 0, 0)
C.Grey = Color3.fromHex("5b6577")
C.Good = C.Friendly
Theme.C = C
Theme.Colors = C

-- Fonts ---------------------------------------------------------------------------------------------
local function fontOr(enum: Enum.Font, fallback: Enum.Font): Font
	local ok, f = pcall(Font.fromEnum, enum)
	if ok and f then
		return f
	end
	return Font.fromEnum(fallback)
end
Theme.Fonts = {
	Header = fontOr(Enum.Font.Michroma, Enum.Font.GothamBlack),
	Body = fontOr(Enum.Font.GothamBold, Enum.Font.SourceSansBold),
	Black = fontOr(Enum.Font.GothamBlack, Enum.Font.GothamBold),
	Medium = fontOr(Enum.Font.GothamMedium, Enum.Font.GothamBold),
}

-- Misc helpers --------------------------------------------------------------------------------------
function Theme.isTouch(): boolean
	local ok, Input = pcall(function()
		return require(script.Parent.Parent.Input)
	end)
	if ok and Input and Input.isTouch then
		local ok2, v = pcall(Input.isTouch)
		if ok2 then
			return v == true
		end
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local audioMod: any = nil
local audioTried = false
local lastHover = 0
function Theme.sfx(key: string)
	if not audioTried then
		audioTried = true
		local ok, a = pcall(function()
			return require(script.Parent.Parent.Audio)
		end)
		if ok then
			audioMod = a
		end
	end
	if audioMod and audioMod.play2D then
		pcall(audioMod.play2D, key)
	end
end

function Theme.tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

function Theme.clamp(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

function Theme.formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function Theme.formatNumber(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local out = s
	while true do
		local r, k = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = r
		if k == 0 then
			break
		end
	end
	return out
end

function Theme.hex(c: Color3): string
	return "#" .. c:ToHex()
end

function Theme.playerGui(): PlayerGui
	return Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
end

local SHORT = {
	ROCKETDROP = "ROCKET", GATLINGDROP = "GATLING", RAILDROP = "RAIL", REINFORCE = "REINF", HALFTON = "BOMB",
	BARRAGE = "BARRAGE", STRAFE = "STRAFE", SUPPLY = "SUPPLY", CLUSTER = "CLUSTER",
}
function Theme.callinShort(def: any): string
	if not def then
		return "?"
	end
	return SHORT[def.id] or string.upper(def.id)
end

function Theme.beaconColor(beacon: string?): Color3
	if beacon == "supply" then
		return C.BeaconSupply
	elseif beacon == "defense" then
		return C.BeaconDefense
	end
	return C.BeaconOffense
end

-- Shared call-in slot status. slot = {id, readyAt, uses, charges, maxCharges}
function Theme.slotStatus(slot: any, def: any, now: number?): (boolean, number, string)
	local t = now or workspace:GetServerTimeNow()
	local remaining = math.max(0, (slot.readyAt or 0) - t)
	if slot.uses ~= nil and slot.uses <= 0 then
		return false, remaining, "NO USES"
	end
	if remaining > 0 and not (slot.charges ~= nil and slot.charges > 0) then
		return false, remaining, "COOLDOWN"
	end
	return true, remaining, "READY"
end

-- Property application ---------------------------------------------------------------------------
local function apply(inst: Instance, props: { [string]: any }, skip: { [string]: boolean })
	local parent = nil
	for k, v in props do
		if skip[k] then
			continue
		end
		if k == "Parent" then
			parent = v
		else
			(inst :: any)[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
end

function Theme.new(class: string, props: { [string]: any }?): any
	local inst = Instance.new(class)
	apply(inst, props or {}, {})
	return inst
end

function Theme.corner(parent: Instance, radius: number?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

function Theme.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or C.PanelHi
	s.Thickness = thickness or 2
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

function Theme.pad(parent: Instance, l: number, t: number?, r: number?, b: number?): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, l)
	p.PaddingTop = UDim.new(0, t or l)
	p.PaddingRight = UDim.new(0, r or l)
	p.PaddingBottom = UDim.new(0, b or t or l)
	p.Parent = parent
	return p
end

function Theme.list(parent: Instance, dir: Enum.FillDirection?, padding: number?, hAlign: Enum.HorizontalAlignment?, vAlign: Enum.VerticalAlignment?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.FillDirection = dir or Enum.FillDirection.Vertical
	l.Padding = UDim.new(0, padding or 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left
	l.VerticalAlignment = vAlign or Enum.VerticalAlignment.Top
	l.Parent = parent
	return l
end

-- Angled corner brackets (stencil accent) ---------------------------------------------------------
function Theme.accent(frame: GuiObject, color: Color3?, arm: number?): Folder
	local col = color or C.Accent
	local len = arm or 14
	local holder = Instance.new("Folder")
	holder.Name = "Accent"
	local function bar(anchor: Vector2, pos: UDim2, size: UDim2)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = col
		f.BorderSizePixel = 0
		f.AnchorPoint = anchor
		f.Position = pos
		f.Size = size
		f.ZIndex = frame.ZIndex + 2
		-- inside a Folder: still drawn relative to `frame`, but ignored by any UIListLayout in it
		f.Parent = holder
		return f
	end
	bar(Vector2.new(0, 0), UDim2.fromOffset(-2, -2), UDim2.fromOffset(len, 3))
	bar(Vector2.new(0, 0), UDim2.fromOffset(-2, -2), UDim2.fromOffset(3, len))
	bar(Vector2.new(1, 1), UDim2.new(1, 2, 1, 2), UDim2.fromOffset(len, 3))
	bar(Vector2.new(1, 1), UDim2.new(1, 2, 1, 2), UDim2.fromOffset(3, len))
	holder.Parent = frame
	return holder
end

-- Panel ---------------------------------------------------------------------------------------------
local PANEL_SKIP = { Class = true, Color = true, Transparency = true, Corner = true, Stroke = true, StrokeThickness = true, StrokeTransparency = true, Accent = true }
function Theme.panel(p: { [string]: any }?): Frame
	p = p or {}
	local f = Instance.new(p.Class or "Frame") :: any
	f.BackgroundColor3 = p.Color or C.Panel
	f.BackgroundTransparency = p.Transparency or 0
	f.BorderSizePixel = 0
	if p.Corner ~= 0 then
		Theme.corner(f, p.Corner or 8)
	end
	if p.Stroke ~= false then
		local sc = typeof(p.Stroke) == "Color3" and p.Stroke or C.PanelHi
		Theme.stroke(f, sc, p.StrokeThickness or 2, p.StrokeTransparency or 0.2)
	end
	apply(f, p, PANEL_SKIP)
	if p.Accent then
		Theme.accent(f, typeof(p.Accent) == "Color3" and p.Accent or C.Accent)
	end
	return f
end

-- Label ---------------------------------------------------------------------------------------------
local LABEL_SKIP = { Font = true, Color = true, XAlign = true, YAlign = true, Wrap = true, NoStroke = true, Rich = true, Class = true }
function Theme.label(p: { [string]: any }?): TextLabel
	p = p or {}
	local l = Instance.new(p.Class or "TextLabel") :: any
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.FontFace = Theme.Fonts[p.Font or "Body"] or Theme.Fonts.Body
	l.TextColor3 = p.Color or C.Text
	l.TextSize = p.TextSize or 18
	l.TextStrokeColor3 = C.Black
	l.TextStrokeTransparency = p.NoStroke and 1 or 0.4
	l.TextXAlignment = p.XAlign or Enum.TextXAlignment.Center
	l.TextYAlignment = p.YAlign or Enum.TextYAlignment.Center
	l.TextWrapped = p.Wrap == true
	l.RichText = p.Rich == true
	l.Text = ""
	apply(l, p, LABEL_SKIP)
	return l
end

-- Button --------------------------------------------------------------------------------------------
local VARIANTS = {
	primary = { bg = C.Accent, text = C.Dark, stroke = C.Gold, noStroke = true },
	good = { bg = C.Friendly, text = C.Dark, stroke = C.White, noStroke = true },
	danger = { bg = C.Danger, text = C.White, stroke = C.White, noStroke = false },
	secondary = { bg = C.PanelLight, text = C.Text, stroke = C.PanelHi, noStroke = false },
	ghost = { bg = C.Panel, text = C.Text, stroke = C.PanelHi, noStroke = false },
}
local BUTTON_SKIP = { Rich = true, Variant = true, OnClick = true, Font = true, Color = true, TextColor = true, Corner = true, Stroke = true, NoStroke = true, Hover = true, NoSound = true, Accent = true, StrokeColor = true }

function Theme.setEnabled(btn: GuiButton, enabled: boolean)
	btn:SetAttribute("Disabled", not enabled)
	local base = btn:GetAttribute("BaseColor")
	local baseText = btn:GetAttribute("BaseText")
	if base and typeof(base) == "Color3" then
		btn.BackgroundColor3 = enabled and base or base:Lerp(C.Grey, 0.65)
	end
	if baseText and typeof(baseText) == "Color3" and btn:IsA("TextButton") then
		btn.TextColor3 = enabled and baseText or baseText:Lerp(C.Grey, 0.55)
	end
end

function Theme.button(p: { [string]: any }?): TextButton
	p = p or {}
	local v = VARIANTS[p.Variant or "secondary"] or VARIANTS.secondary
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.BackgroundColor3 = p.Color or v.bg
	btn.FontFace = Theme.Fonts[p.Font or "Black"] or Theme.Fonts.Black
	btn.TextColor3 = p.TextColor or v.text
	btn.TextSize = p.TextSize or 18
	btn.TextStrokeColor3 = C.Black
	btn.TextStrokeTransparency = (p.NoStroke ~= nil and p.NoStroke or v.noStroke) and 1 or 0.4
	btn.Text = ""
	btn.RichText = p.Rich == true
	apply(btn, p, BUTTON_SKIP)
	Theme.corner(btn, p.Corner or 8)
	local st = Theme.stroke(btn, p.StrokeColor or v.stroke, 2, p.Stroke == false and 1 or 0.35)
	local scale = Instance.new("UIScale")
	scale.Name = "Press"
	scale.Parent = btn
	btn:SetAttribute("BaseColor", btn.BackgroundColor3)
	btn:SetAttribute("BaseText", btn.TextColor3)
	if p.Accent then
		Theme.accent(btn, typeof(p.Accent) == "Color3" and p.Accent or C.Accent, 10)
	end

	local hovering = false
	local function disabled(): boolean
		return btn:GetAttribute("Disabled") == true
	end
	if p.Hover ~= false then
		btn.MouseEnter:Connect(function()
			hovering = true
			if disabled() then
				return
			end
			Theme.tween(scale, 0.1, { Scale = 1.04 })
			Theme.tween(st, 0.1, { Transparency = 0, Color = C.Accent })
			local now = os.clock()
			if now - lastHover > 0.06 and not p.NoSound then
				lastHover = now
				Theme.sfx("UIHover")
			end
		end)
		btn.MouseLeave:Connect(function()
			hovering = false
			Theme.tween(scale, 0.12, { Scale = 1 })
			Theme.tween(st, 0.12, { Transparency = 0.35, Color = p.StrokeColor or v.stroke })
		end)
	end
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if not disabled() then
				Theme.tween(scale, 0.06, { Scale = 0.94 })
			end
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			Theme.tween(scale, 0.1, { Scale = hovering and 1.04 or 1 }, Enum.EasingStyle.Back)
		end
	end)
	btn.Activated:Connect(function()
		if disabled() then
			if not p.NoSound then
				Theme.sfx("UIError")
			end
			return
		end
		if not p.NoSound then
			Theme.sfx("UIClick")
		end
		if p.OnClick then
			task.spawn(p.OnClick)
		end
	end)
	return btn
end

-- Icon chip (rounded square with a glyph) ------------------------------------------------------------
function Theme.chip(p: { [string]: any }?): (Frame, TextLabel)
	p = p or {}
	local f = Theme.panel({
		Color = p.Color or C.Navy,
		Corner = p.Corner or 10,
		Stroke = p.StrokeColor or C.Accent,
		StrokeThickness = p.StrokeThickness or 2,
		StrokeTransparency = p.StrokeTransparency or 0.1,
		Size = p.Size or UDim2.fromOffset(48, 48),
		Position = p.Position,
		AnchorPoint = p.AnchorPoint,
		LayoutOrder = p.LayoutOrder,
		Name = p.Name or "Chip",
		Parent = p.Parent,
	})
	local g = Theme.label({
		Text = p.Glyph or "?",
		Font = "Black",
		TextScaled = true,
		TextColor3 = p.GlyphColor or C.Text,
		Size = UDim2.fromScale(0.64, 0.64),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = f,
		Name = "Glyph",
	})
	return f, g
end

-- Progress bar ----------------------------------------------------------------------------------------
export type Bar = { Frame: Frame, Fill: Frame, set: (self: Bar, alpha: number, animate: boolean?) -> () }
function Theme.bar(p: { [string]: any }?): Bar
	p = p or {}
	local back = Theme.panel({
		Color = p.Back or C.Dark,
		Corner = p.Corner or 4,
		Stroke = p.Stroke ~= nil and p.Stroke or false,
		Size = p.Size or UDim2.new(1, 0, 0, 10),
		Position = p.Position,
		AnchorPoint = p.AnchorPoint,
		LayoutOrder = p.LayoutOrder,
		Name = p.Name or "Bar",
		ClipsDescendants = true,
		Parent = p.Parent,
	})
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = p.Color or C.Accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = back
	Theme.corner(fill, p.Corner or 4)
	local bar = { Frame = back, Fill = fill }
	function bar.set(self: Bar, alpha: number, animate: boolean?)
		alpha = Theme.clamp(alpha, 0, 1)
		if animate then
			Theme.tween(fill, 0.2, { Size = UDim2.fromScale(alpha, 1) })
		else
			fill.Size = UDim2.fromScale(alpha, 1)
		end
	end
	return bar :: any
end

-- Scrolling frame -----------------------------------------------------------------------------------------
function Theme.scroll(p: { [string]: any }?): ScrollingFrame
	p = p or {}
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.ScrollBarThickness = p.Thickness or 6
	s.ScrollBarImageColor3 = C.Accent
	s.ScrollBarImageTransparency = 0.2
	s.AutomaticCanvasSize = p.Horizontal and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
	s.CanvasSize = UDim2.new()
	s.ScrollingDirection = p.Horizontal and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
	s.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	apply(s, p, { Thickness = true, Horizontal = true })
	return s
end

-- ScreenGui + responsive root ---------------------------------------------------------------------------------
function Theme.gui(name: string, opts: { [string]: any }?): ScreenGui
	opts = opts or {}
	local old = Theme.playerGui():FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.DisplayOrder = opts.DisplayOrder or 1
	g.IgnoreGuiInset = opts.IgnoreGuiInset ~= false
	local mode = opts.Insets or "DeviceSafeInsets"
	pcall(function()
		g.ScreenInsets = (Enum.ScreenInsets :: any)[mode]
	end)
	g.Enabled = opts.Enabled ~= false
	g.Parent = Theme.playerGui()
	return g
end

function Theme.scaleFor(kind: string?): number
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1920, 1080)
	local y = math.max(vp.Y, 200)
	if Theme.isTouch() then
		if kind == "menu" then
			return Theme.clamp(y / 480, 0.8, 1.25)
		end
		return Theme.clamp(y / 540, 0.72, 1.25)
	end
	return Theme.clamp(y / 1080, 0.6, 1.5)
end

-- Returns a transparent full-size Frame whose children are laid out in "virtual" pixels
-- (1080p on PC, ~830x470 on phones) and uniformly scaled to the real viewport.
function Theme.root(gui: ScreenGui, kind: string?): (Frame, UIScale)
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	local us = Instance.new("UIScale")
	us.Parent = root
	local function refresh()
		local s = Theme.scaleFor(kind)
		us.Scale = s
		root.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	refresh()
	root.Parent = gui
	local camConn: RBXScriptConnection? = nil
	local function hookCam()
		if camConn then
			camConn:Disconnect()
		end
		local cam = workspace.CurrentCamera
		if cam then
			camConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
		end
		refresh()
	end
	hookCam()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCam)
	return root, us
end

-- Convenience: connect to Store.on without caring about its callback signature.
function Theme.watch(key: string, fn: (any) -> ()): () -> ()
	local Store = require(script.Parent.Parent.Store)
	local off = Store.on(key, function()
		fn(Store.get(key))
	end)
	task.defer(fn, Store.get(key))
	return off
end

-- Pooled step (RunService) helper that auto-disconnects.
function Theme.every(interval: number, fn: (number) -> ()): RBXScriptConnection
	local acc = 0
	return RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= interval then
			local d = acc
			acc = 0
			fn(d)
		end
	end)
end

return Theme
