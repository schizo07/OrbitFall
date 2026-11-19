-- Shared plumbing for the information layer of the new HUD layouts (goal line, mission sheet, event feed, squad strip,
-- call-in strip, timer). Skin tokens and motion come from UI/HudSkin, positions from UI/HudLayout; this adds the
-- shared ScreenGui these modules draw in and a few small helpers.
--   InfoLayer.isNew()                  HudSkin.isNew() (false = option D: modules run their old code)
--   InfoLayer.style()                  "hairline" | "glass" | "visor" | nil
--   InfoLayer.root()                   the shared "OrbitInfo" ScreenGui root (one scale, Theme.scaleFor("hud"))
--   InfoLayer.fresh(name) / drop(name) a module's own frame in that root, replaced on every build
--   InfoLayer.place(frame, name, touch) / entry(name, touch)   HudLayout.apply / get
--   InfoLayer.col(role)                HudSkin.color (roles: text dim objective own danger heal rare line shadow panel)
--   InfoLayer.label(props)             HudSkin.label + Small (phones skip the stroke) + Raw (no case change)
--   InfoLayer.caseText(s)              caps for hairline / visor, as written for glass
--   InfoLayer.backing(frame)           the skin's contextual backing (HudSkin.panel "auto") behind a group
--   InfoLayer.mark(parent, color, order)  small style mark in front of a header line
--   InfoLayer.onRebuild(fn)            HudSkin.onRebuild
local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local InfoLayer = {}

function InfoLayer.isNew(): boolean
	return HudSkin.isNew()
end

function InfoLayer.style(): string?
	local s = HudSkin.current()
	return s and s.id
end

function InfoLayer.preset(): string
	return HudLayout.preset()
end

function InfoLayer.entry(name: string, touch: boolean): { [string]: any }
	return HudLayout.get(name, touch)
end

function InfoLayer.place(f: GuiObject, name: string, touch: boolean)
	HudLayout.apply(f, name, touch)
end

function InfoLayer.col(role: string): Color3
	return HudSkin.color(role)
end

function InfoLayer.caseText(s: string): string
	local sk = HudSkin.current()
	if sk and not sk.caps then
		return s
	end
	return string.upper(s)
end

-- props: HudSkin.label props (Role, ColorRole / Color, Text, TextSize, XAlign, YAlign, Shadow, ...) plus
--   Raw = true keeps the text's case
local SKIP = { Raw = true, Small = true, Text = true }
function InfoLayer.label(p: { [string]: any }): TextLabel
	local q = {}
	for k, v in p do
		if not SKIP[k] then
			q[k] = v
		end
	end
	local l = HudSkin.label(q)
	local text = p.Text or ""
	l.Text = if p.Raw then text else InfoLayer.caseText(text)
	return l
end

-- Contextual group backing: the skin's own kind (fade / glass / scan), sized to the frame, drawn under its children.
function InfoLayer.backing(f: GuiObject, flip: boolean?): Frame
	local b = HudSkin.panel("auto", {
		Name = "Backing",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
	})
	if flip and InfoLayer.style() ~= "glass" then
		local g = b:FindFirstChildOfClass("UIGradient")
		if g then
			g.Rotation = 180
		end
	end
	-- in a Folder so a list layout on f ignores it
	local folder = Instance.new("Folder")
	folder.Name = "BackingHost"
	folder.Parent = f
	b.Parent = folder
	return b
end

-- A small style mark at the start of a header line: hairline = 45 degree tick, glass = dot, visor = bar.
function InfoLayer.mark(parent: Instance, color: Color3?, order: number?): Frame
	local st = InfoLayer.style()
	local host = Instance.new("Frame")
	host.Name = "Mark"
	host.BackgroundTransparency = 1
	host.Size = UDim2.fromOffset(10, 16)
	host.LayoutOrder = order or 0
	host.Parent = parent
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color or InfoLayer.col("line")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	if st == "glass" then
		f.Size = UDim2.fromOffset(6, 6)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = f
	elseif st == "visor" then
		f.Size = UDim2.fromOffset(2, 12)
	else
		f.Size = UDim2.fromOffset(1, 9)
		f.Rotation = 45
	end
	f.Parent = host
	return host
end

-- Shared ScreenGui ---------------------------------------------------------------------------------------------------
local gui: ScreenGui? = nil
local root: Frame? = nil

function InfoLayer.root(): Frame
	if root and root.Parent and gui and gui.Parent then
		return root
	end
	local g = Theme.gui("OrbitInfo", { DisplayOrder = 11, Insets = "CoreUISafeInsets" })
	gui = g
	local r = Theme.root(g, "hud")
	r.Name = "Info"
	root = r
	return r
end

-- A module's own frame in the shared root; any previous one of that name is destroyed first, so a second build
-- (style switch) never leaves a copy behind.
function InfoLayer.fresh(name: string): Frame
	local r = InfoLayer.root()
	local old = r:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = r
	return f
end

-- Removes a module's frame (old-layout builds call this so nothing of the new layout lingers after a switch to D).
function InfoLayer.drop(name: string)
	if root and root.Parent then
		local old = root:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
end

function InfoLayer.onRebuild(fn: (any) -> ())
	HudSkin.onRebuild(fn)
end

function InfoLayer.localPos(cam: Camera): Vector3
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if hrp then hrp.Position else cam.CFrame.Position
end

-- Signed screen angle (deg) from the camera heading to a world point, for direction carets.
function InfoLayer.bearing(cam: Camera, from: Vector3, to: Vector3): number
	local d = to - from
	local look = cam.CFrame.LookVector
	local camAng = math.deg(math.atan2(look.X, -look.Z))
	local b = math.deg(math.atan2(d.X, -d.Z))
	return (b - camAng + 180) % 360 - 180
end

return InfoLayer
