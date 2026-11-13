-- Small stamina bar under the crosshair (below the reload bar). Fades in while stamina < full, fades out ~0.7 s
-- after it refills. Teal when healthy, orange when low, pulsing red while exhausted (with a tick at the recover mark).
-- Driven by client/Movement.luau: StaminaBar.init(getter) where getter() -> (stamina 0..1, exhausted, sprinting).
-- HUD may later take this over by reading Store "stamina" / me.stamina; then just stop calling init.
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)

local C = Theme.C
local StaminaBar = {}

local W, H = 76, 5
local Y_OFFSET = 60 -- px below screen centre (reload bar sits at +44)

function StaminaBar.init(getter: () -> (number, boolean, boolean))
	local gui = Theme.gui("OrbitStamina", { DisplayOrder = 12, Insets = "None" })

	local group = Instance.new("CanvasGroup")
	group.Name = "Stamina"
	group.AnchorPoint = Vector2.new(0.5, 0)
	group.Position = UDim2.new(0.5, 0, 0.5, Y_OFFSET)
	group.Size = UDim2.fromOffset(W + 4, H + 4)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.Parent = gui

	local back = Instance.new("Frame")
	back.Name = "Back"
	back.AnchorPoint = Vector2.new(0.5, 0.5)
	back.Position = UDim2.fromScale(0.5, 0.5)
	back.Size = UDim2.fromOffset(W, H)
	back.BackgroundColor3 = C.Dark
	back.BackgroundTransparency = 0.35
	back.BorderSizePixel = 0
	back.Parent = group
	Theme.corner(back, H)
	Theme.stroke(back, C.Black, 1, 0.4)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = C.Friendly
	fill.BorderSizePixel = 0
	fill.Parent = back
	Theme.corner(fill, H)

	local tick = Instance.new("Frame")
	tick.Name = "Recover"
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.Position = UDim2.fromScale(Config.Move.RecoverAt, 0.5)
	tick.Size = UDim2.fromOffset(2, H + 4)
	tick.BackgroundColor3 = C.White
	tick.BorderSizePixel = 0
	tick.Visible = false
	tick.Parent = back

	local alpha = 0
	local fullFor = 0
	RunService.RenderStepped:Connect(function(dt)
		local v, exhausted, sprinting = getter()
		local me = Store.get("me")
		local hidden = Store.get("menuOpen") == true or (type(me) == "table" and me.alive == false)
		if v >= 0.999 and not sprinting then
			fullFor += dt
		else
			fullFor = 0
		end
		local want = if hidden or fullFor > 0.7 then 0 else 1
		alpha += (want - alpha) * (1 - math.exp(-dt * (if want > alpha then 14 else 6)))
		group.GroupTransparency = 1 - alpha
		group.Visible = alpha > 0.01
		if not group.Visible then
			return
		end
		fill.Size = UDim2.fromScale(math.clamp(v, 0, 1), 1)
		if exhausted then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
			fill.BackgroundColor3 = C.Danger:Lerp(C.Accent, pulse * 0.5)
		elseif v < Config.Move.RecoverAt then
			fill.BackgroundColor3 = C.Accent
		else
			fill.BackgroundColor3 = C.Friendly
		end
		tick.Visible = exhausted
	end)
end

return StaminaBar
