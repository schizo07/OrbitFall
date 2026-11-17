-- Client side of the call-in meshes: clones from ReplicatedStorage.CallInModels (published by server/CallIns/ModelShare)
-- and poses kit parts around their Data/Meshes pivots. Every getter returns nil while the mesh is not there yet,
-- so callers keep their part-built version as the fallback.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Meshes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Meshes"))

local CallInModels = {}

export type Rig = { model: Model, parts: { [string]: BasePart }, rel: { [BasePart]: CFrame }, scale: number }

-- anchored, non-colliding clone of a callin_* mesh (nil when it has not arrived), optionally uniformly scaled
function CallInModels.get(key: string, scale: number?): Model?
	local folder = ReplicatedStorage:FindFirstChild("CallInModels")
	local tpl = folder and folder:FindFirstChild(key)
	if not tpl or not tpl:IsA("Model") then
		return nil
	end
	local m = tpl:Clone()
	for _, d in m:GetChildren() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	if scale and scale ~= 1 then
		m:ScaleTo(scale)
	end
	return m
end

-- part CFrames relative to the model origin; pose = cf * motion * rel
function CallInModels.rig(model: Model, scale: number?): Rig
	local origin = model:GetPivot()
	local parts: { [string]: BasePart } = {}
	local rel: { [BasePart]: CFrame } = {}
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			parts[d.Name] = d
			rel[d] = origin:ToObjectSpace(d.CFrame)
		end
	end
	return { model = model, parts = parts, rel = rel, scale = scale or 1 }
end

-- manifest pivot of a part in the (scaled) model frame
function CallInModels.pivot(rig: Rig, key: string, partName: string): Vector3
	local info = Meshes[key]
	local p = info and info.pivots and info.pivots[partName]
	return (p or Vector3.zero) * rig.scale
end

function CallInModels.hinge(p: Vector3, rot: CFrame): CFrame
	return CFrame.new(p) * rot * CFrame.new(-p)
end

function CallInModels.pose(rig: Rig, cf: CFrame, motions: { [string]: CFrame }?)
	for name, part in rig.parts do
		local m = motions and motions[name]
		part.CFrame = if m then cf * m * rig.rel[part] else cf * rig.rel[part]
	end
end

return CallInModels
