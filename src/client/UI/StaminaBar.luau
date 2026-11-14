-- Thin stamina bar, bottom centre (270 px wide, 4 px tall, flat black track + 1 px white corner brackets). Only visible while stamina
-- is changing (draining from sprint / dive, or regenerating); fades out ~0.7 s after it stops moving. White when healthy, amber when
-- low, pulsing red while exhausted (with a tick at the recover mark).
-- Driven by client/Movement.luau: StaminaBar.init(getter) where getter() -> (stamina 0..1, exhausted, sprinting).
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local StaminaBar = {}

local W, H = 270, 4
local BOTTOM = 18 -- px above the screen bottom

function StaminaBar.init(getter: () -> (number, boolean, boolean))
	local touch = Theme.isTouch()
	local gui = Theme.gui("OrbitStamina", { DisplayOrder = 12, Insets = "None" })
	local k = if touch then 0.8 else 1

	local group = Instance.new("CanvasGroup")
	group.Name = "Stamina"
	group.AnchorPoint = Vector2.new(0.5, 1)
	group.Position = UDim2.new(0.5, 0, 1, -BOTTOM * k)
	group.Size = UDim2.fromOffset((W + 8) * k, (H + 8) * k)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.Parent = gui

	local back = Style.rect({
		Name = "Back",
		Color = Style.Black,
		Transparency = Style.PANEL_ALPHA,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(W * k, H * k),
		Parent = group,
	})
	Style.brackets(back, Style.White, 4)

	local fill = Style.rect({
		Name = "Fill",
		Color = Style.White,
		Size = UDim2.fromScale(1, 1),
		Parent = back,
	})

	local tick = Style.rect({
		Name = "Recover",
		Color = Style.White,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(Config.Move.RecoverAt, 0.5),
		Size = UDim2.fromOffset(1, (H + 4) * k),
		Visible = false,
		Parent = back,
	})

	local alpha = 0
	local idleFor = 0
	local lastV = 1
	RunService.RenderStepped:Connect(function(dt)
		local v, exhausted, sprinting = getter()
		local me = Store.get("me")
		local hidden = Store.get("menuOpen") == true or (type(me) == "table" and me.alive == false)
		-- "changing": the value moved this frame, the player is sprinting below full, or exhausted
		local moving = math.abs(v - lastV) > 0.0004 or exhausted or (sprinting and v < 0.999)
		lastV = v
		if moving then
			idleFor = 0
		else
			idleFor += dt
		end
		local want = if hidden or idleFor > 0.7 then 0 else 1
		alpha += (want - alpha) * (1 - math.exp(-dt * (if want > alpha then 14 else 6)))
		group.GroupTransparency = 1 - alpha
		group.Visible = alpha > 0.01
		if not group.Visible then
			return
		end
		fill.Size = UDim2.fromScale(math.clamp(v, 0, 1), 1)
		if exhausted then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 9)
			fill.BackgroundColor3 = Style.Red:Lerp(Style.Amber, pulse * 0.5)
		elseif v < Config.Move.RecoverAt then
			fill.BackgroundColor3 = Style.Amber
		else
			fill.BackgroundColor3 = Style.White
		end
		tick.Visible = exhausted
	end)
end

return StaminaBar
