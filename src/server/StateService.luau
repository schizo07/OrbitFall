-- Pushes state snapshots to clients (keys: mission, me, profile, squad, objectives).
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local StateService = {}
local stateEv: RemoteEvent
local notifyEv: RemoteEvent
local last: { [string]: any } = {} -- broadcast cache for late joiners

function StateService.init(_S)
	stateEv = Net.event("State")
	notifyEv = Net.event("Notify")
	Players.PlayerAdded:Connect(function(p)
		task.wait(1)
		for k, v in last do
			stateEv:FireClient(p, k, v)
		end
	end)
end

function StateService.send(player: Player, key: string, value: any)
	stateEv:FireClient(player, key, value)
end

function StateService.broadcast(key: string, value: any)
	last[key] = value
	stateEv:FireAllClients(key, value)
end

function StateService.notify(player: Player?, text: string, color: Color3?, kind: string?)
	if player then
		notifyEv:FireClient(player, text, color, kind)
	else
		notifyEv:FireAllClients(text, color, kind)
	end
end

return StateService
