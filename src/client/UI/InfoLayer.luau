-- Shared plumbing for the perimeter HUD information layer (timer, objectives, mission sheet, event feed, squad strip,
-- call-in chip/drawer). Visual tokens come from UI/HudSkin, positions from UI/HudLayout.
local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local InfoLayer = {}

function InfoLayer.isNew(): boolean
	return true
end

function InfoLayer.style(): string
	return HudSkin.id()
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
	return string.upper(s)
end

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

-- Plate backing sized to the frame, drawn under its children (in a Folder so UIListLayout ignores it).
function InfoLayer.backing(f: GuiObject, kind: string?): Frame
	local b = HudSkin.panel(kind or "plate", {
		Name = "Backing",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
	})
	local folder = Instance.new("Folder")
	folder.Name = "BackingHost"
	folder.Parent = f
	b.Parent = folder
	return b
end

-- Crisp header mark (45-degree tick)
function InfoLayer.mark(parent: Instance, color: Color3?, order: number?): Frame
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
	f.Size = UDim2.fromOffset(2, 9)
	f.Rotation = 45
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

function InfoLayer.bearing(cam: Camera, from: Vector3, to: Vector3): number
	local d = to - from
	local look = cam.CFrame.LookVector
	local camAng = math.deg(math.atan2(look.X, -look.Z))
	local b = math.deg(math.atan2(d.X, -d.Z))
	return (b - camAng + 180) % 360 - 180
end

return InfoLayer
