-- Trooper armour (gritty palette): welds the Blender `armor_kit` pieces onto an R15 avatar (called from PlayerService on every character spawn).
--   TrooperArmor.apply(S, player, character)
-- Kit frame = the Blender dummy (standard R15 proportions); every piece is anchored to the avatar body part it was modelled on and
-- scaled by (actual part size / standard R15 size), per axis. Parts are CanCollide/CanQuery/CanTouch false and Massless.
-- Hats, hair, face, back, shoulder and front accessories are hidden (Transparency 1) so they cannot clip through the armour.
-- Palette: charcoal base, worn-tan secondary, dark glossy visor with a thin orange glint; Player attribute "SquadColor"
-- (Color3) tints only the small thruster lamps (manifest cyan when unset).
-- If the asset or the R15 parts are missing nothing happens (the plain avatar is the fallback).

local TrooperArmor = {}

local KIT = "armor_kit"

-- piece -> { body part it welds to, kit piece whose pivot is that body part's centre on the dummy }
local MOUNT: { [string]: { string } } = {
	Helmet = { "Head", "Helmet" },
	Visor = { "Head", "Helmet" },
	ChestPlate = { "UpperTorso", "ChestPlate" },
	Backpack = { "UpperTorso", "ChestPlate" },
	Thruster_L = { "UpperTorso", "ChestPlate" },
	Thruster_R = { "UpperTorso", "ChestPlate" },
	Pauldron_L = { "LeftUpperArm", "Pauldron_L" },
	Pauldron_R = { "RightUpperArm", "Pauldron_R" },
	Shin_L = { "LeftLowerLeg", "Shin_L" },
	Shin_R = { "RightLowerLeg", "Shin_R" },
}

-- standard R15 sizes the kit was modelled on
local STD: { [string]: Vector3 } = {
	Head = Vector3.new(1.2, 1.2, 1.2),
	UpperTorso = Vector3.new(2, 1.6, 1),
	LeftUpperArm = Vector3.new(1, 1.17, 1),
	RightUpperArm = Vector3.new(1, 1.17, 1),
	LeftLowerLeg = Vector3.new(1, 1.19, 1),
	RightLowerLeg = Vector3.new(1, 1.19, 1),
}

local HIDE_ACCESSORIES: { [Enum.AccessoryType]: boolean } = {
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Face] = true,
	[Enum.AccessoryType.Eyebrow] = true,
	[Enum.AccessoryType.Eyelash] = true,
	[Enum.AccessoryType.Back] = true,
	[Enum.AccessoryType.Shoulder] = true,
	[Enum.AccessoryType.Front] = true,
}

local function hideAccessory(acc: Instance)
	if not acc:IsA("Accessory") or not HIDE_ACCESSORIES[acc.AccessoryType] then
		return
	end
	for _, d in acc:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = 1
		end
	end
end

-- Gritty palette. The kit meshes come with TextureID = the white/navy/orange palette atlas, and MeshPart.Color does NOT tint a
-- TextureID (the texture wins), so the atlas is cleared and every piece is coloured by Color + Material directly. A thin trim
-- strip per main piece (max 6 extra parts) breaks up the flat colour so it does not read as plain plastic.
-- Light plates on a dark suit: the trooper must read as a bright shape against dark dust/swamp/rock (it was a black blob).
local BONE = Color3.fromRGB(196, 188, 170) -- primary: bone-white painted plate on helmet, chest, shins
local GUNMETAL = Color3.fromRGB(70, 74, 80) -- secondary: gunmetal pauldrons and backpack
local HAZARD = Color3.fromRGB(200, 96, 40) -- hazard-orange trim on the light pieces
local LIGHT_EDGE = Color3.fromRGB(210, 200, 180) -- light edge trim on the dark pieces
local VISOR_COLOR = Color3.fromRGB(30, 30, 34)
local VISOR_GLINT = Color3.fromRGB(255, 150, 60)
local THRUSTER_DEFAULT = Color3.fromRGB(110, 170, 190) -- muted cyan when no squad colour is set
local PIECE_BASE: { [string]: { color: Color3, material: Enum.Material } } = {
	Helmet = { color = BONE, material = Enum.Material.SmoothPlastic }, -- painted: plastic keeps it light (Metal darkens)
	ChestPlate = { color = BONE, material = Enum.Material.SmoothPlastic },
	Shin_L = { color = BONE, material = Enum.Material.SmoothPlastic },
	Shin_R = { color = BONE, material = Enum.Material.SmoothPlastic },
	Pauldron_L = { color = GUNMETAL, material = Enum.Material.Metal }, -- bare gunmetal
	Pauldron_R = { color = GUNMETAL, material = Enum.Material.Metal },
	Backpack = { color = Color3.fromRGB(92, 96, 72), material = Enum.Material.Fabric }, -- olive canvas pack
}

-- trim strip per piece: size and offset are fractions of the (scaled) piece bounding box (min 0.05 studs); the kit faces -Z.
type Trim = { size: Vector3, off: Vector3, color: Color3, material: Enum.Material }
local TRIM: { [string]: Trim } = {
	-- crest ridge over the top of the helmet, front to back
	Helmet = { size = Vector3.new(0.1, 0.05, 0.7), off = Vector3.new(0, 0.48, 0.05), color = HAZARD, material = Enum.Material.Metal },
	-- horizontal band across the chest front
	ChestPlate = { size = Vector3.new(0.62, 0.07, 0.05), off = Vector3.new(0, 0.12, -0.47), color = HAZARD, material = Enum.Material.Metal },
	-- dark edge along the outer side of each pauldron
	Pauldron_L = { size = Vector3.new(0.05, 0.12, 0.8), off = Vector3.new(-0.47, -0.3, 0), color = LIGHT_EDGE, material = Enum.Material.Metal },
	Pauldron_R = { size = Vector3.new(0.05, 0.12, 0.8), off = Vector3.new(0.47, -0.3, 0), color = LIGHT_EDGE, material = Enum.Material.Metal },
	-- vertical worn-tan stripe down the front of each shin guard
	Shin_L = { size = Vector3.new(0.14, 0.6, 0.05), off = Vector3.new(0, 0.05, -0.47), color = GUNMETAL, material = Enum.Material.Fabric },
	Shin_R = { size = Vector3.new(0.14, 0.6, 0.05), off = Vector3.new(0, 0.05, -0.47), color = GUNMETAL, material = Enum.Material.Fabric },
}

-- Drop the palette atlas so Color/Material show. A SurfaceAppearance (if the import kept one) is tinted instead; if its Color
-- cannot be set it is removed so the flat colour shows.
local function paint(part: BasePart, col: Color3, material: Enum.Material?)
	if part:IsA("MeshPart") then
		pcall(function()
			(part :: MeshPart).TextureID = ""
		end)
	end
	local sa = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if sa then
		local ok = pcall(function()
			(sa :: any).Color = col -- tint on the colour map; keep the part colour neutral so it is not multiplied twice
		end)
		if ok then
			part.Color = Color3.new(1, 1, 1)
			return
		end
		sa:Destroy()
	end
	part.Color = col
	if material then
		part.Material = material
	end
	part.Reflectance = 0
end

local function trimPart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local t = Instance.new("Part")
	t.Name = name
	t.Size = size
	t.Color = color
	t.Material = material
	t.TopSurface = Enum.SurfaceType.Smooth
	t.BottomSurface = Enum.SurfaceType.Smooth
	t.Anchored = false
	t.CanCollide = false
	t.CanQuery = false
	t.CanTouch = false
	t.Massless = true
	t.CastShadow = false
	return t
end

local function clampVec(v: Vector3, lo: number, hi: number): Vector3
	return Vector3.new(math.clamp(v.X, lo, hi), math.clamp(v.Y, lo, hi), math.clamp(v.Z, lo, hi))
end

local function build(S: any, p: Player, c: Model): boolean
	local assets = S and S.Assets
	if not assets then
		return false
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	if not hum or hum.RigType ~= Enum.HumanoidRigType.R15 then
		return false
	end
	local old = c:FindFirstChild("TrooperArmor")
	if old then
		old:Destroy()
	end
	local tpl = assets.get(KIT)
	if not tpl then
		return false
	end
	tpl:PivotTo(CFrame.new()) -- Blender dummy frame (T-pose, facing -Z)
	local centres: { [string]: Vector3 } = {}
	for _, m in MOUNT do
		centres[m[2]] = assets.pivot(KIT, m[2]) or Vector3.zero
	end

	local squadColor = p:GetAttribute("SquadColor")
	local armor = Instance.new("Model")
	armor.Name = "TrooperArmor"
	local placed: { { part: MeshPart | BasePart, limb: BasePart, cf: CFrame } } = {}
	for _, d in tpl:GetChildren() do
		local mount = MOUNT[d.Name]
		if d:IsA("BasePart") and mount then
			local limb = c:FindFirstChild(mount[1])
			if limb and limb:IsA("BasePart") then
				local ratio = clampVec(Vector3.new(limb.Size.X / STD[mount[1]].X, limb.Size.Y / STD[mount[1]].Y, limb.Size.Z / STD[mount[1]].Z), 0.6, 1.8)
				local rel = (d.Position - centres[mount[2]]) * ratio
				d.Size = d.Size * ratio
				d.Anchored = false
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
				d.CastShadow = d.Material ~= Enum.Material.Neon
				local baseCF = limb.CFrame * CFrame.new(rel) * d.CFrame.Rotation
				if d.Name == "Visor" then
					-- dark glossy glass with a thin warm-orange glint along its top edge (no more cyan slab)
					paint(d, VISOR_COLOR, Enum.Material.SmoothPlastic)
					d.Reflectance = 0.3
					d.CastShadow = true
					local glint = Instance.new("Part")
					glint.Name = "VisorGlint"
					glint.Material = Enum.Material.Neon
					glint.Color = VISOR_GLINT
					glint.Size = Vector3.new(d.Size.X * 0.78, 0.045, 0.04)
					glint.Anchored = false
					glint.CanCollide = false
					glint.CanQuery = false
					glint.CanTouch = false
					glint.Massless = true
					glint.CastShadow = false
					placed[#placed + 1] = { part = glint, limb = limb, cf = baseCF * CFrame.new(0, d.Size.Y * 0.28, -(d.Size.Z * 0.5 + 0.012)) }
				elseif d.Name == "Thruster_L" or d.Name == "Thruster_R" then
					-- the squad colour lives on the small thruster lamps only (muted cyan when none is set)
					paint(d, if typeof(squadColor) == "Color3" then squadColor else THRUSTER_DEFAULT, nil)
				elseif PIECE_BASE[d.Name] then
					local pb = PIECE_BASE[d.Name]
					paint(d, pb.color, pb.material)
					local tr = TRIM[d.Name]
					if tr then
						local sz = d.Size
						local strip = trimPart(d.Name .. "Trim", Vector3.new(
							math.max(0.05, sz.X * tr.size.X),
							math.max(0.05, sz.Y * tr.size.Y),
							math.max(0.05, sz.Z * tr.size.Z)
							), tr.color, tr.material)
						local off = Vector3.new(sz.X * tr.off.X, sz.Y * tr.off.Y, sz.Z * tr.off.Z)
						placed[#placed + 1] = { part = strip, limb = limb, cf = baseCF * CFrame.new(off) }
					end
				end
				placed[#placed + 1] = { part = d, limb = limb, cf = baseCF }
			end
		end
	end
	if #placed == 0 then
		tpl:Destroy()
		return false
	end
	for _, e in placed do
		e.part.CFrame = e.cf
		e.part.Parent = armor
	end
	tpl:Destroy()
	armor.Parent = c
	for _, e in placed do
		local w = Instance.new("WeldConstraint")
		w.Part0 = e.limb
		w.Part1 = e.part
		w.Parent = e.part
	end
	return true
end

function TrooperArmor.apply(S: any, p: Player, c: Model)
	local assets = S and S.Assets
	if not assets then
		return
	end
	-- hats / hair would clip through the helmet: hide existing and late accessories
	for _, ch in c:GetChildren() do
		hideAccessory(ch)
	end
	c.ChildAdded:Connect(function(ch)
		task.defer(hideAccessory, ch)
	end)

	task.spawn(function()
		if not assets.ready(KIT) and not assets.failed(KIT) then
			assets.waitFor(KIT, 40)
		end
		-- R15 parts may still be streaming in
		for _, name in { "Head", "UpperTorso", "LeftUpperArm", "RightUpperArm", "LeftLowerLeg", "RightLowerLeg" } do
			if not c:WaitForChild(name, 5) then
				return
			end
		end
		if not c.Parent then
			return
		end
		local ok, res = pcall(build, S, p, c)
		if not ok then
			warn("[TrooperArmor] build failed:", res)
		end
		-- avatar scale / description may be applied after spawn: refit once appearance has loaded
		local refit: RBXScriptConnection? = nil
		local function stop()
			if refit then
				refit:Disconnect()
				refit = nil
			end
		end
		c.Destroying:Once(stop)
		refit = p.CharacterAppearanceLoaded:Connect(function(ch)
			stop()
			if ch == c and c.Parent then
				local ok2, res2 = pcall(build, S, p, c)
				if not ok2 then
					warn("[TrooperArmor] refit failed:", res2)
				end
				for _, a in c:GetChildren() do
					hideAccessory(a)
				end
			end
		end)
	end)
end

return TrooperArmor
