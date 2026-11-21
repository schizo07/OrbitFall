-- Hairline stamina readout bridged into the unified bottom-left self vitals strip (UI/Vitals).
-- Driven by client/Movement.luau: StaminaBar.init(getter) where getter() -> (stamina 0..1, exhausted, sprinting, boosted).
local RunService = game:GetService("RunService")
local Vitals = require(script.Parent.Vitals)

local StaminaBar = {}

local inited = false

function StaminaBar.init(getter: () -> (number, boolean, boolean))
	if inited then
		return
	end
	inited = true
	RunService.RenderStepped:Connect(function()
		local v, exhausted, sprinting, boosted = (getter :: any)()
		Vitals.setStamina(v or 1, exhausted == true, sprinting == true, boosted == true)
	end)
end

return StaminaBar
