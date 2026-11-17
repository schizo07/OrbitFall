-- Call-in meshes (Data/Meshes `callin_*` kit entries): publishes the server-only Assets templates to
-- ReplicatedStorage.CallInModels so client Fx can clone them (client/CallInModels.luau), and holds the small
-- rig helpers the server effects use to move kit parts around their manifest pivots.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelShare = {}

-- keys the client Fx clone (falling pods, bombs, shells, jet, dropship)
local CLIENT_KEYS = {
	"callin_drop_capsule",
	"callin_supply_pod",
	"callin_strafe_jet",
	"callin_bomb_halfton",
	"callin_shell_barrage",
	"callin_shell_bomblet",
	"callin_shell_emp",
	"callin_shell_canister",
	"callin_cog_dropship",
}

export type Rig = { model: Model, parts: { [string]: BasePart }, rel: { [BasePart]: CFrame } }

-- Part CFrames relative to the model origin (the Blender origin), so a pose is  cf * motion * rel
function ModelShare.rig(model: Model): Rig
	local origin = model:GetPivot()
	local parts: { [string]: BasePart } = {}
	local rel: { [BasePart]: CFrame } = {}
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			parts[d.Name] = d
			rel[d] = origin:ToObjectSpace(d.CFrame)
		end
	end
	return { model = model, parts = parts, rel = rel }
end

-- rotation `rot` about the point `p` (model frame)
function ModelShare.hinge(p: Vector3, rot: CFrame): CFrame
	return CFrame.new(p) * rot * CFrame.new(-p)
end

-- places every part at cf * motions[name] * rel (parts without a motion just follow cf)
function ModelShare.pose(rig: Rig, cf: CFrame, motions: { [string]: CFrame }?)
	for name, part in rig.parts do
		local m = motions and motions[name]
		part.CFrame = if m then cf * m * rig.rel[part] else cf * rig.rel[part]
	end
end

-- Anchored, non-colliding, non-queryable clone (visual only). nil while the asset is not loaded / failed.
function ModelShare.visual(S: any, key: string): Model?
	local assets = S and S.Assets
	if not assets then
		return nil
	end
	local m = assets.get(key, { anchored = true })
	if not m then
		return nil
	end
	for _, d in m:GetChildren() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = false
		end
	end
	return m
end

function ModelShare.start(S: any)
	local assets = S and S.Assets
	if not assets then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild("CallInModels")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CallInModels"
		folder.Parent = ReplicatedStorage
	end
	for _, key in CLIENT_KEYS do
		task.spawn(function()
			if not assets.waitFor(key, 90) then
				return
			end
			local m = ModelShare.visual(S, key)
			if m and folder and not folder:FindFirstChild(key) then
				m.Parent = folder
			end
		end)
	end
end

return ModelShare
