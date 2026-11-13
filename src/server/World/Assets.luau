-- S.Assets: loads the Blender-made meshes (Data/Meshes) at boot and serves clones.
--   Assets.get(key, opts?) -> Model?   a clone of the template (nil when failed / not loaded yet).
--                                      opts.anchored = true anchors every part (static props)
--   Assets.ready(key) -> boolean
--   Assets.failed(key) -> boolean      true once all retries are used up
--   Assets.size(key) -> Vector3?       template bounding box in studs (feet at y = 0, centred on x/z)
--   Assets.waitAll(timeout) -> boolean true when nothing is still loading (yields up to `timeout` seconds)
--   Assets.info(key) -> Meshes.MeshInfo?
--   Assets.pivot(key, partName) -> Vector3?   manifest pivot of a kit part, in the model frame (see Data/Meshes `pivots`)
--   Assets.waitFor(key, timeout) -> boolean    yields until that key is loaded/failed
-- Kit entries (set pieces `courier_wreck`... `sample_pod`, `armor_kit`, `wpn_*`) are NOT recentred for use: their Model.WorldPivot is the
-- Blender origin (ground centre / weapon grip / dummy-body origin); parts are Unanchored/CanCollide=false until the caller decides.
--
-- Templates live in ServerStorage.MeshTemplates as Models named after the key. Every template is normalised:
-- MeshParts are flattened into one Model, coloured + materialled from Data/Meshes (FBX imports arrive grey),
-- recentred so the bounding box sits on y = 0 and is centred on x/z, and Model.WorldPivot = the origin
-- (so `PivotTo(cf)` puts the feet centre at cf). Parts are Unanchored / CanCollide=false / Massless: callers
-- weld or anchor them. Callers MUST handle `nil` (fallback to the part-built path).
--
-- Rigged enemies (Data/Meshes entry has `rig`): the template carries the Model attribute Rigged = true and the part
-- names are the manifest part names. A template point is  manifest pivot - Vector3.new(rig.center.X, 0, rig.center.Z)
-- (the recentring below removes the bounding-box centre on x/z; feet are already y = 0). EnemyModels builds the
-- Motor6D chain from that. If the rig asset cannot be loaded and the entry has `legacy`, the old single-piece mesh is
-- loaded instead (Rigged = false) so enemies still show up and use the old bob/sway.

local InsertService = game:GetService("InsertService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Meshes = require(ReplicatedStorage:WaitForChild("Shared").Data.Meshes)

local Assets = {}

local MAX_ATTEMPTS = 3 -- first try + 2 retries

local status: { [string]: string } = {} -- "loading" | "ok" | "failed"
local sizes: { [string]: Vector3 } = {}
local started = false
local folder: Folder? = nil

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = ServerStorage:FindFirstChild("MeshTemplates")
	if not f then
		f = Instance.new("Folder")
		f.Name = "MeshTemplates"
		f.Parent = ServerStorage
	end
	folder = f :: Folder
	return folder :: Folder
end

local function lookupPart(parts: { [string]: Meshes.PartInfo }, name: string): Meshes.PartInfo?
	local p = parts[name]
	if p then
		return p
	end
	-- importer may suffix duplicate names: "Body.001", "Body_1", "Body1"
	local stripped = string.gsub(name, "[%._]?%d+$", "")
	return parts[stripped]
end

local function aabb(parts: { BasePart }): (Vector3, Vector3)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in parts do
		local h = p.Size * 0.5
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local w = p.CFrame:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
					lo = lo:Min(w)
					hi = hi:Max(w)
				end
			end
		end
	end
	return lo, hi
end

-- Turn the raw LoadAsset result into a normalised template Model (or nil).
-- `rigged`: the parts are the rig-v2 parts (textured: keep any SurfaceAppearance/TextureID). `checkScale`: false for the
-- legacy fallback mesh, whose size may legitimately differ from the manifest (rig) size.
local function process(key: string, info: Meshes.MeshInfo, parts: { [string]: Meshes.PartInfo }, rigged: boolean, checkScale: boolean, loaded: Instance): Model?
	local found: { MeshPart } = {}
	for _, d in loaded:GetDescendants() do
		if d:IsA("MeshPart") then
			table.insert(found, d)
		end
	end
	if #found == 0 then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = key
	for _, mp in found do
		local pi = lookupPart(parts, mp.Name)
		local keepSurface = rigged or (pi ~= nil and pi.textured == true)
		for _, c in mp:GetChildren() do
			-- imported grey surface/scripts/welds are replaced by our own colours and welds
			if (c:IsA("SurfaceAppearance") and not keepSurface) or c:IsA("LuaSourceContainer") or c:IsA("JointInstance") or c:IsA("Constraint") then
				c:Destroy()
			end
		end
		if pi then
			mp.Color = pi.color
			mp.Material = pi.material
			mp:SetAttribute("Role", pi.role)
		else
			warn(("[Assets] %s: MeshPart '%s' is not in Data/Meshes"):format(key, mp.Name))
			mp:SetAttribute("Role", "body")
		end
		mp.Anchored = false
		mp.CanCollide = false
		mp.CanTouch = false
		mp.CanQuery = true
		mp.Massless = true
		mp.CastShadow = mp.Material ~= Enum.Material.Neon
		mp.Parent = model
	end
	model.WorldPivot = CFrame.new()
	model:SetAttribute("Rigged", rigged)

	-- Uniform scale sanity check (an importer set to the wrong unit would give 100x / 0.01x meshes).
	local lo, hi = aabb(found)
	local size = hi - lo
	local expect = info.size
	local ratio = size.Y / math.max(expect.Y, 0.001)
	if math.abs(ratio - 1) > 0.08 then
		local rx = size.X / math.max(expect.X, 0.001)
		local rz = size.Z / math.max(expect.Z, 0.001)
		if checkScale and math.abs(rx - ratio) < 0.1 * ratio and math.abs(rz - ratio) < 0.1 * ratio then
			warn(("[Assets] %s imported at scale %.3f, rescaling"):format(key, ratio))
			model.WorldPivot = CFrame.new((lo + hi) / 2)
			model:ScaleTo(1 / ratio)
			lo, hi = aabb(found)
			size = hi - lo
		else
			warn(("[Assets] %s size %s differs from manifest %s (axes?)"):format(key, tostring(size), tostring(expect)))
		end
	end

	-- feet on y = 0, centred on x/z
	local delta = Vector3.new(-(lo.X + hi.X) / 2, -lo.Y, -(lo.Z + hi.Z) / 2)
	for _, mp in found do
		mp.CFrame = mp.CFrame + delta
	end
	-- kit entries (set pieces, weapons, armour) keep the Blender frame: the pivot is the model origin, so
	-- PivotTo(cf) puts the Blender origin (ground centre / grip / body-part centre) at cf and manifest pivots apply as-is.
	model.WorldPivot = CFrame.new(info.origin or Vector3.zero)
	sizes[key] = size
	return model
end

-- Diagnostics only: every rig pivot (template space) should sit on/near its own part. A big miss means the imported
-- part positions do not match the manifest frame (the Motor6D joints would then be in the wrong place).
local function checkRig(key: string, info: Meshes.MeshInfo, model: Model)
	local rig = info.rig
	if not rig then
		return
	end
	local off = Vector3.new(rig.center.X, 0, rig.center.Z)
	local bad = 0
	for _, rp in rig.parts do
		local part = model:FindFirstChild(rp.name)
		if part and part:IsA("BasePart") then
			local local_ = part.CFrame:PointToObjectSpace(rp.pivot - off)
			local h = part.Size * 0.5
			local out = Vector3.new(
				math.max(math.abs(local_.X) - h.X, 0),
				math.max(math.abs(local_.Y) - h.Y, 0),
				math.max(math.abs(local_.Z) - h.Z, 0)
			).Magnitude
			if out > 1.25 then
				bad += 1
				warn(("[Assets] %s: rig pivot of '%s' is %.1f studs outside the part"):format(key, rp.name, out))
			end
		else
			warn(("[Assets] %s: rig part '%s' missing from the imported asset"):format(key, rp.name))
			bad += 1
		end
	end
	if bad > 0 then
		warn(("[Assets] %s: %d rig pivot problem(s), check rigAssetId / import axes"):format(key, bad))
	end
end

-- One asset id, up to `attempts` tries. Returns true when a template was stored.
local function tryAsset(key: string, info: Meshes.MeshInfo, assetId: number, parts: { [string]: Meshes.PartInfo }, rigged: boolean, attempts: number): boolean
	for attempt = 1, attempts do
		local ok, res = pcall(function()
			return InsertService:LoadAsset(assetId)
		end)
		if ok and res then
			local okP, model = pcall(process, key, info, parts, rigged, rigged or info.legacy == nil, res)
			res:Destroy()
			if okP and model then
				if rigged then
					checkRig(key, info, model)
				end
				model.Parent = getFolder()
				return true
			end
			warn(("[Assets] %s: no MeshParts in asset %d (%s)"):format(key, assetId, tostring(model)))
		else
			warn(("[Assets] %s: LoadAsset(%d) attempt %d failed: %s"):format(key, assetId, attempt, tostring(res)))
		end
		if attempt < attempts then
			task.wait(attempt) -- 1 s, then 2 s
		end
	end
	return false
end

local function loadOne(key: string, info: Meshes.MeshInfo)
	status[key] = "loading"
	if tryAsset(key, info, info.assetId, info.parts, info.rig ~= nil, MAX_ATTEMPTS) then
		status[key] = "ok"
		return
	end
	local legacy = info.legacy
	if info.rig and legacy then
		warn(("[Assets] %s: rig asset unavailable, falling back to the non-rigged mesh"):format(key))
		if tryAsset(key, info, legacy.assetId, legacy.parts, false, 2) then
			status[key] = "ok"
			return
		end
	end
	status[key] = "failed"
	warn(("[Assets] %s unavailable, callers use the part-built fallback"):format(key))
end

function Assets.start()
	if started then
		return
	end
	started = true
	getFolder()
	for key, info in Meshes do
		status[key] = "loading"
		task.spawn(loadOne, key, info)
	end
end

function Assets.init(_registry: any)
	Assets.start()
end

function Assets.ready(key: string): boolean
	return status[key] == "ok"
end

function Assets.failed(key: string): boolean
	return status[key] == "failed"
end

function Assets.info(key: string): Meshes.MeshInfo?
	return Meshes[key]
end

function Assets.size(key: string): Vector3?
	return sizes[key]
end

function Assets.get(key: string, opts: { anchored: boolean? }?): Model?
	if status[key] ~= "ok" then
		return nil
	end
	local tpl = getFolder():FindFirstChild(key)
	if not tpl or not tpl:IsA("Model") then
		return nil
	end
	local clone = tpl:Clone()
	if opts and opts.anchored then
		for _, d in clone:GetChildren() do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
	end
	return clone
end

-- Manifest part pivot in the kit model frame (the frame of the model after PivotTo(cf): world = cf * pivot).
function Assets.pivot(key: string, partName: string): Vector3?
	local info = Meshes[key]
	return info and info.pivots and info.pivots[partName] or nil
end

-- Yields (up to `timeout` s) until `key` is loaded or failed. Returns Assets.ready(key).
function Assets.waitFor(key: string, timeout: number?): boolean
	local t0 = os.clock()
	local limit = timeout or 8
	while status[key] == "loading" and os.clock() - t0 < limit do
		task.wait(0.1)
	end
	return status[key] == "ok"
end

function Assets.waitAll(timeout: number?): boolean
	local t0 = os.clock()
	local limit = timeout or 10
	while os.clock() - t0 < limit do
		local pending = false
		for _, st in status do
			if st == "loading" then
				pending = true
				break
			end
		end
		if not pending then
			return true
		end
		task.wait(0.1)
	end
	for _, st in status do
		if st == "loading" then
			return false
		end
	end
	return true
end

return Assets
