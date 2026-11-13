-- Server -> client visual/audio events. See docs/architecture.md "Fx kinds".
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local FxService = {}
local fx: RemoteEvent
local fxu: UnreliableRemoteEvent

function FxService.init(_S)
	fx = Net.event("Fx")
	fxu = Net.unreliable("FxU")
end

function FxService.play(kind: string, data: any)
	fx:FireAllClients(kind, data)
end

function FxService.playU(kind: string, data: any)
	fxu:FireAllClients(kind, data)
end

function FxService.to(player: Player, kind: string, data: any)
	fx:FireClient(player, kind, data)
end

function FxService.except(player: Player, kind: string, data: any, unreliable: boolean?)
	for _, p in Players:GetPlayers() do
		if p ~= player then
			if unreliable then
				fxu:FireClient(p, kind, data)
			else
				fx:FireClient(p, kind, data)
			end
		end
	end
end

return FxService
