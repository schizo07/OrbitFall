-- Routes the `Action` remote to handlers registered with S.Actions.on(name, fn(player, ...)).
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local ActionRouter = {}
local handlers: { [string]: (Player, ...any) -> () } = {}

function ActionRouter.on(name: string, fn: (Player, ...any) -> ())
	handlers[name] = fn
end

function ActionRouter.init(_S)
	Net.event("Action").OnServerEvent:Connect(function(player, name, ...)
		if typeof(name) ~= "string" then
			return
		end
		local h = handlers[name]
		if h then
			local ok, err = pcall(h, player, ...)
			if not ok then
				warn("[Action]", name, err)
			end
		end
	end)
end

return ActionRouter
