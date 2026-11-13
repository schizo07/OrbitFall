--!strict
-- Remote registry. Server calls Net.init() once; everyone else uses Net.event/Net.func.
--
-- PROTOCOL (see docs/architecture.md):
--  Fire        C->S  (slot: number, aimPoint: Vector3, seq: number)
--  Action      C->S  (action: string, ...any)
--  Fx          S->C  (kind: string, data: table)            reliable
--  FxU         S->C  (kind: string, data: table)            unreliable (tracers, impacts)
--  State       S->C  (key: string, value: any)
--  Notify      S->C  (text: string, color: Color3?, kind: string?)
--  HitConfirm  S->C  (result: string, pos: Vector3, killed: boolean, weak: boolean)
--  Request     C->S  RemoteFunction (cmd: string, args: any) -> (ok: boolean, result: any)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

local EVENTS = { "Fire", "Action", "Fx", "State", "Notify", "HitConfirm" }
local UNRELIABLE = { "FxU" }
local FUNCS = { "Request" }

local folder: Folder? = nil

function Net.init()
	assert(RunService:IsServer(), "Net.init is server-only")
	local f = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = "Remotes"
		nf.Parent = ReplicatedStorage
		f = nf
	end
	assert(f)
	for _, n in EVENTS do
		if not f:FindFirstChild(n) then
			local r = Instance.new("RemoteEvent")
			r.Name = n
			r.Parent = f
		end
	end
	for _, n in UNRELIABLE do
		if not f:FindFirstChild(n) then
			local r = Instance.new("UnreliableRemoteEvent")
			r.Name = n
			r.Parent = f
		end
	end
	for _, n in FUNCS do
		if not f:FindFirstChild(n) then
			local r = Instance.new("RemoteFunction")
			r.Name = n
			r.Parent = f
		end
	end
	folder = f
end

local function getFolder(): Folder
	if folder then
		return folder
	end
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	return folder :: Folder
end

function Net.event(name: string): RemoteEvent
	return getFolder():WaitForChild(name) :: RemoteEvent
end

function Net.unreliable(name: string): UnreliableRemoteEvent
	return getFolder():WaitForChild(name) :: UnreliableRemoteEvent
end

function Net.func(name: string): RemoteFunction
	return getFolder():WaitForChild(name) :: RemoteFunction
end

return Net
