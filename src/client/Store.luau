-- Client state store fed by the State remote (+ client-local keys like "holding", "menuOpen").
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local Store = {}
local data: { [string]: any } = {}
local listeners: { [string]: { [number]: (any) -> () } } = {}
local nextId = 0

function Store.get(key: string): any
	return data[key]
end

function Store.set(key: string, value: any)
	data[key] = value
	local ls = listeners[key]
	if ls then
		for _, fn in ls do
			task.spawn(fn, value)
		end
	end
end

function Store.on(key: string, fn: (any) -> ()): () -> ()
	listeners[key] = listeners[key] or {}
	nextId += 1
	local id = nextId
	listeners[key][id] = fn
	if data[key] ~= nil then
		task.spawn(fn, data[key])
	end
	return function()
		if listeners[key] then
			listeners[key][id] = nil
		end
	end
end

function Store.init()
	Net.event("State").OnClientEvent:Connect(function(key, value)
		Store.set(key, value)
	end)
	task.spawn(function()
		local ok, okReq, prof = pcall(function()
			return Net.func("Request"):InvokeServer("getProfile")
		end)
		if ok and okReq and prof then
			Store.set("profile", prof)
		end
	end)
end

return Store
