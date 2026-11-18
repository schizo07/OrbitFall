-- The landed drop capsule each trooper rode down in (server/PlayerService.dropTo). Once its door is open the server
-- places a real capsule on the spot (door down, invisible back and side walls to bump into) and it stays there until
-- that trooper dies, leaves, or drops in again. The falling capsule is client Fx (client/Fx/CallInFx dropPodMesh),
-- which hands over to this one: it looks for a model in DropCapsules with attribute Owner = the player's UserId.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelShare = require(script.Parent.CallIns.ModelShare)
local Meshes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Meshes"))

local DropCapsule = {}

local KEY = "callin_drop_capsule"
local DOOR_OPEN = math.rad(88) -- same swing as the client door
local WALL_R = 3.5 -- studs from the centre to the wall colliders
local WALL_H = 12
local WALL_T = 0.8

local S: any
local placed: { [Player]: Model } = {}

local function folder(): Instance
	local parent = workspace:FindFirstChild("Map") or workspace -- goes with the map when it is rebuilt
	local f = parent:FindFirstChild("DropCapsules")
	if not f then
		f = Instance.new("Folder")
		f.Name = "DropCapsules"
		f.Parent = parent
	end
	return f
end

local function wall(m: Model, size: Vector3, cf: CFrame)
	local p = Instance.new("Part")
	p.Name = "Collider"
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.CastShadow = false
	p.Parent = m
end

function DropCapsule.clear(p: Player)
	local m = placed[p]
	placed[p] = nil
	if m then
		m:Destroy()
	end
end

-- ground: capsule floor centre; door: flat unit direction the door faces
function DropCapsule.place(p: Player, ground: Vector3, door: Vector3)
	DropCapsule.clear(p)
	local m = ModelShare.visual(S, KEY)
	if not m then
		return -- asset not loaded: the client capsule just fades as before
	end
	local cf = CFrame.lookAt(ground, ground + door)
	local rig = ModelShare.rig(m)
	local info = Meshes[KEY]
	local pivot = info and info.pivots and info.pivots.Door or Vector3.zero
	ModelShare.pose(rig, cf, { Door = ModelShare.hinge(pivot, CFrame.Angles(-DOOR_OPEN, 0, 0)) })
	-- back and side walls only: the door side (-Z, the look direction) stays open so the trooper inside walks out freely
	local y = WALL_H / 2
	wall(m, Vector3.new(WALL_R * 2, WALL_H, WALL_T), cf * CFrame.new(0, y, WALL_R))
	wall(m, Vector3.new(WALL_T, WALL_H, WALL_R * 2), cf * CFrame.new(WALL_R, y, 0))
	wall(m, Vector3.new(WALL_T, WALL_H, WALL_R * 2), cf * CFrame.new(-WALL_R, y, 0))
	m.WorldPivot = cf
	m.Name = "DropCapsule"
	m:SetAttribute("Owner", p.UserId)
	m.Parent = folder()
	placed[p] = m
end

function DropCapsule.init(s: any)
	S = s
	game:GetService("Players").PlayerRemoving:Connect(DropCapsule.clear)
end

return DropCapsule
