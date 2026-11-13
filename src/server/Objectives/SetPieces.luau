-- Shared helpers for the Blender set pieces (Data/Meshes kit entries: courier_wreck, generator, trajectory_console,
-- missile_silo, uplink_dish, extraction_pad, skiff, fabricator, sample_pod).
--   SetPieces.spawn(S, key, cf, parent, opts?) -> Piece?   nil when the asset is unavailable: callers fall back to part-built geometry
--   SetPieces.groundCF(map, cf, radius?) -> CFrame         sits cf on the terrain (average of the footprint, same raycast as the sites)
--   SetPieces.pivot(piece, partName) -> Vector3            manifest pivot of a part in world space
--   SetPieces.swing(piece, partName, localRot, startCF?) -> CFrame   CFrame of the part rotated about its manifest pivot
--                                                          (`localRot` is a rotation in the piece's own axes)
--   SetPieces.tween(inst, seconds, goal, style?, dir?) -> Tween
--   SetPieces.pulse(part, prop, a, b, period) -> Tween     looping property tween (glow pulses)
-- A Piece = { key, model, cf, parts = { [partName] = BasePart } }. Every part is anchored; only role "body" parts collide (the Blender
-- meshes keep their imported collision fidelity, so nothing but the hull may be a collider).

local TweenService = game:GetService("TweenService")
local Meshes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Data.Meshes)

local SetPieces = {}

export type Piece = { key: string, model: Model, cf: CFrame, parts: { [string]: BasePart } }

-- Terrain-fitted CFrame: Y from the LOWEST ground over the footprint (centre, 4 corners, 4 edge midpoints), rotation
-- unchanged. The lowest hit (not the average) so a piece on a slope sinks into the high side instead of hovering
-- over the low side.
function SetPieces.groundCF(map: any, cf: CFrame, radius: number?): CFrame
	local p = cf.Position
	if not map or not map.groundY then
		return cf
	end
	local low = map.groundY(p.X, p.Z)
	local r = radius or 0
	if r > 0 then
		for _, c in { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local w = cf:PointToWorldSpace(Vector3.new(c[1] * r, 0, c[2] * r))
			low = math.min(low, map.groundY(w.X, w.Z))
		end
	end
	return CFrame.new(p.X, low, p.Z) * cf.Rotation
end

function SetPieces.spawn(S: any, key: string, cf: CFrame, parent: Instance, opts: { name: string?, drop: { string }?, collide: { string }?, wait: number?, scale: number? }?): Piece?
	local assets = S and S.Assets
	if not assets then
		return nil
	end
	if not assets.ready(key) and not assets.failed(key) then
		assets.waitFor(key, (opts and opts.wait) or 8)
	end
	local model = assets.get(key, { anchored = true })
	if not model then
		return nil
	end
	local o = opts or {}
	if o.name then
		model.Name = o.name
	end
	for _, n in o.drop or {} do
		local d = model:FindFirstChild(n)
		if d then
			d:Destroy()
		end
	end
	local collide: { [string]: boolean } = {}
	for _, n in o.collide or {} do
		collide[n] = true
	end
	local parts: { [string]: BasePart } = {}
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("Role")
			d.Anchored = true
			d.CanCollide = role == "body" or collide[d.Name] == true
			d.CanTouch = false
			d.CanQuery = d.CanCollide or role == "interact" or role == "door"
			d.Massless = false
			parts[d.Name] = d
		end
	end
	if o.scale then
		pcall(function()
			model:ScaleTo(o.scale :: number)
		end)
	end
	model:PivotTo(cf)
	model.Parent = parent
	return { key = key, model = model, cf = cf, parts = parts }
end

function SetPieces.pivot(piece: Piece, partName: string): Vector3
	local info = Meshes[piece.key]
	local pv = info and info.pivots and info.pivots[partName]
	if pv then
		return piece.cf:PointToWorldSpace(pv)
	end
	local part = piece.parts[partName]
	return if part then part.Position else piece.cf.Position
end

function SetPieces.swing(piece: Piece, partName: string, localRot: CFrame, startCF: CFrame?): CFrame
	local part = piece.parts[partName]
	local base = startCF or (part and part.CFrame) or piece.cf
	local hinge = SetPieces.pivot(piece, partName)
	local rot = piece.cf.Rotation * localRot * piece.cf.Rotation:Inverse()
	return CFrame.new(hinge) * rot * CFrame.new(-hinge) * base
end

function SetPieces.tween(inst: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.InOut), goal)
	tw:Play()
	return tw
end

function SetPieces.pulse(part: Instance, prop: string, a: any, b: any, period: number): Tween
	(part :: any)[prop] = a
	local tw = TweenService:Create(part, TweenInfo.new(period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { [prop] = b })
	tw:Play()
	return tw
end

return SetPieces
