-- Main objective "Recover Core Cells": load N core cells (5 / 6 / 7 / 8 / 9 by difficulty) into the cargo lifter.
-- The cells rest at four places (World/MapPlan): the spilled cell at the crashed drone, Signal Mesa, the Quarry and the
-- Walker Graveyard, MapPlan.cellCount(place, difficulty) of them each, on the spots the map's anchors give (a ring around
-- the place when an anchor is missing). Every place has its own twist (HaulTwists.luau). The cargo lifter stands on the
-- concrete apron of the silo site (the refinery): a cargo bed, an upright glowing blue terminal panel and a painted
-- Halcyon emblem, all built from parts. The refinery fights back as cells go in (probe, counter-attack); the last cell
-- starts a launch countdown with a big wave, and the lifter leaves when it runs out.
--   pick up : hold Interact 0.5 s on a cell (ProximityPrompt). The server welds the cell to the trooper's chest and sets
--             the Player + character attribute `CarryCell` (shared/Carry.luau: no fire / aim / grenades, speed x0.8).
--   drop    : Action "cellDrop" (client: Interact or Grenade while carrying), dying, being knocked down (stance "down")
--             or leaving the game drops it where the trooper stood; a dropped cell keeps a world marker.
--   deliver : a carrier entering the lifter zone (LIFT_RADIUS around the cargo bed) loads the cell: counter [k/N].
--   done    : N/N -> launch countdown (LAUNCH_SECONDS), then the step completes, the lifter launches, onComplete() (the
--             Mission goes to Extract).
-- Callouts go through the Notify remote with kind "comms" as "<name>: <line>".
-- Receives `ctx` from ObjectiveService; returns a controller { entry, stop, drop, stepsDone, debugSolve }.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Carry = require(Shared.Carry)
local SetPieces = require(script.Parent.SetPieces)
local HaulTwists = require(script.Parent.HaulTwists)
local MapPlan = require(script.Parent.Parent.World.MapPlan)

local HaulCells = {}

local PLACES = { "spilled", "mesa", "quarry", "graveyard" } -- cell places, in the order the cells are numbered
local PLACE_LABEL = { spilled = "DRONE WRECK", mesa = "SIGNAL MESA", quarry = "QUARRY", graveyard = "WALKER GRAVEYARD" }
local PICK_HOLD = 0.5
local LIFT_RADIUS = 7.5 -- horizontal studs from the cargo bed centre that load a carried cell
local LIFT_DY = 9
local REPICK_LOCK = 0.6 -- s after a drop before that trooper can grab again (holding Interact to drop doesn't re-grab)
local LAUNCH_SECONDS = 25 -- last cell loaded -> the lifter leaves after this long (the big wave hits meanwhile)
local DEBUG_LAUNCH_SECONDS = 4 -- same with the DebugFast attribute
local PAD_H = 0.2 -- height of the dark pad a resting cell stands on
local STEP_FMT = "Load cells into the cargo lifter [%d/%d]"
local LAUNCH_FMT = "Hold the cargo lifter: launching in %d s"

local DARK = Color3.fromRGB(40, 44, 52)
local STEEL = Color3.fromRGB(112, 118, 128)
local HAZARD = Color3.fromRGB(230, 170, 40)
local PANEL_BLUE = Color3.fromRGB(70, 150, 255)
local PAINT = Color3.fromRGB(226, 196, 92)
local CONCRETE = Color3.fromRGB(122, 120, 116)
local CALLOUT = Color3.fromRGB(244, 246, 250)

type Cell = {
	id: number,
	case: Part,
	parts: { BasePart },
	prompt: ProximityPrompt,
	state: string, -- "cache" | "carried" | "dropped" | "loaded"
	home: CFrame,
	cache: any,
	carrier: Player?,
	weld: Weld?,
	marker: BillboardGui?,
	above: BillboardGui?,
	everTaken: boolean,
}

-- small world marker: a rotated-square "cell" glyph plus an optional caption
local function billboard(adornee: BasePart, name: string, caption: string?, offset: Vector3, maxDist: number, glyph: number): BillboardGui
	local bb = Instance.new("BillboardGui")
	bb.Name = name
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(if caption then 170 else glyph + 8, if caption then glyph + 22 else glyph + 8)
	bb.StudsOffsetWorldSpace = offset
	bb.MaxDistance = maxDist
	bb.Adornee = adornee
	local d = Instance.new("Frame")
	d.Name = "Glyph"
	d.AnchorPoint = Vector2.new(0.5, 0)
	d.Position = UDim2.new(0.5, 0, 0, 4)
	d.Size = UDim2.fromOffset(glyph, glyph)
	d.Rotation = 45
	d.BackgroundColor3 = Carry.COLOR
	d.BorderSizePixel = 0
	local st = Instance.new("UIStroke")
	st.Color = Color3.new(0, 0, 0)
	st.Thickness = 1.5
	st.Transparency = 0.2
	st.Parent = d
	d.Parent = bb
	if caption then
		local l = Instance.new("TextLabel")
		l.Name = "Caption"
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 0)
		l.Position = UDim2.new(0.5, 0, 0, glyph + 6)
		l.Size = UDim2.new(1, 0, 0, 14)
		l.Font = Enum.Font.GothamBold
		l.TextSize = 12
		l.TextColor3 = Carry.COLOR
		l.TextStrokeTransparency = 0.4
		l.Text = caption
		l.Parent = bb
	end
	bb.Parent = adornee
	return bb
end

function HaulCells.start(ctx: any, onComplete: () -> ()): any
	local S = ctx.S
	local map = ctx.map
	local root = Instance.new("Folder")
	root.Name = "Haul"
	root.Parent = ctx.folder

	-- cells per place (MapPlan: 5 / 6 / 7 / 8 / 9 in all by difficulty 1..5)
	local diff = math.clamp(math.floor(tonumber(ctx.difficulty) or 1), 1, 5)
	local counts: { [string]: number } = {}
	local total = 0
	local room = if Workspace:GetAttribute("DebugFast") then 2 else math.huge
	for _, name in PLACES do
		local n = math.min(MapPlan.cellCount(name, diff), room)
		counts[name] = n
		room -= n
		total += n
	end
	local entry = ctx.newEntry({ id = "HAUL", title = "Recover Core Cells", main = true, steps = { string.format(STEP_FMT, 0, total) } })
	local ctl: any = { entry = entry }
	local alive = true
	local finished = false
	local delivered = 0

	local cells: { Cell } = {}
	local carriers: { [Player]: Cell } = {}
	local lastPos: { [Player]: Vector3 } = {}
	local dropLock: { [Player]: number } = {}

	local function callout(p: Player, line: string)
		if S and S.State then
			S.State.notify(nil, p.DisplayName .. ": " .. line, CALLOUT, "comms")
		end
	end

	-- ============================================================ cargo lifter (silo site apron)
	local siteCF: CFrame = map.sites.silo or map.sites.console
	local base = SetPieces.groundCF(map, siteCF, 12)
	local gC = map.groundY and map.groundY(siteCF.Position.X, siteCF.Position.Z) or base.Position.Y
	local top = gC + 0.45 -- slab surface (the map's round apron tops out at ground + 0.15)
	local lowest = base.Position.Y
	local plaza = CFrame.new(siteCF.Position.X, top, siteCF.Position.Z) * siteCF.Rotation -- local -Z faces the map centre
	local slabH = math.clamp(top - lowest + 1, 1, 5)
	local lifter = Instance.new("Model")
	lifter.Name = "CargoLifter"
	lifter.Parent = root
	ctx.part(lifter, Vector3.new(26, slabH, 26), plaza * CFrame.new(0, -slabH / 2, 0), CONCRETE, Enum.Material.Concrete, { CastShadow = false })
	-- Anything of the map that stands in the slab's footprint and crosses its top surface pokes through it: the apron's hazard
	-- bollards (server/World/MapBuilder.luau) and any small prop or chunk on the plaza. Bollards go wherever they are near
	-- the slab; other parts only when they are small (the apron disc and walls are bigger than 9 studs and stay).
	if map.folder then
		for _, d in map.folder:GetDescendants() do
			if d:IsA("BasePart") then
				local lp = plaza:PointToObjectSpace(d.Position)
				if math.abs(lp.X) <= 15 and math.abs(lp.Z) <= 15 then
					if d.Name == "HazardBollard" then
						d:Destroy()
					elseif math.abs(lp.X) <= 14.5 and math.abs(lp.Z) <= 14.5 and math.max(d.Size.X, d.Size.Y, d.Size.Z) <= 9 then
						-- vertical half-extent of the part's (rotated) box
						local cf = d.CFrame
						local s = d.Size
						local half = 0.5 * (math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z)
						local y = d.Position.Y
						if y + half > top + 0.03 and y - half < top then
							d:Destroy()
						end
					end
				end
			end
		end
	end
	-- floor grates along the side edges
	for _, gx in { -10.5, 10.5 } do
		for _, gz in { -7, 0, 7 } do
			ctx.part(lifter, Vector3.new(3.2, 0.08, 5), plaza * CFrame.new(gx, 0.04, gz), Color3.fromRGB(58, 60, 64), Enum.Material.DiamondPlate, { CanCollide = false, CastShadow = false })
		end
	end
	-- painted emblem (front of the plaza): ring, cross bars and a centre diamond, flat paint on the slab
	do
		local e = plaza * CFrame.new(0, 0, -6.5)
		local paint = { CanCollide = false, CanQuery = false, CastShadow = false }
		ctx.cyl(lifter, 11, 0.04, e * CFrame.new(0, 0.02, 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.cyl(lifter, 9.6, 0.04, e * CFrame.new(0, 0.035, 0), CONCRETE, Enum.Material.Concrete, paint)
		ctx.part(lifter, Vector3.new(0.7, 0.04, 9.2), e * CFrame.new(0, 0.05, 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.part(lifter, Vector3.new(9.2, 0.04, 0.7), e * CFrame.new(0, 0.05, 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.part(lifter, Vector3.new(3.6, 0.04, 3.6), e * CFrame.new(0, 0.065, 0) * CFrame.Angles(0, math.rad(45), 0), PAINT, Enum.Material.SmoothPlastic, paint)
		ctx.part(lifter, Vector3.new(1.7, 0.04, 1.7), e * CFrame.new(0, 0.08, 0) * CFrame.Angles(0, math.rad(45), 0), CONCRETE, Enum.Material.Concrete, paint)
	end
	-- cargo bed (the delivery zone) with hazard edges and four guide posts
	local bedCF = plaza * CFrame.new(0, 0.15, 2.5)
	local bed = ctx.part(lifter, Vector3.new(8, 0.3, 8), bedCF, Color3.fromRGB(64, 68, 76), Enum.Material.DiamondPlate, { Name = "CargoBed" })
	local bedParts: { BasePart } = { bed }
	for _, s in { { 0, -3.85, 8, 0.3 }, { 0, 3.85, 8, 0.3 }, { -3.85, 0, 0.3, 8 }, { 3.85, 0, 0.3, 8 } } do
		local strip = ctx.part(lifter, Vector3.new(s[3], 0.32, s[4]), bedCF * CFrame.new(s[1], 0.02, s[2]), HAZARD, Enum.Material.SmoothPlastic, { CanCollide = false, CastShadow = false })
		table.insert(bedParts, strip)
	end
	for _, c in { { -4.4, -4.4 }, { 4.4, -4.4 }, { -4.4, 4.4 }, { 4.4, 4.4 } } do
		ctx.part(lifter, Vector3.new(0.6, 7, 0.6), plaza * CFrame.new(c[1], 3.5, 2.5 + c[2]), DARK, Enum.Material.Metal)
		ctx.part(lifter, Vector3.new(0.66, 0.5, 0.66), plaza * CFrame.new(c[1], 6.6, 2.5 + c[2]), HAZARD, Enum.Material.Metal, { CanCollide = false })
	end
	-- terminal: upright glowing blue panel behind the bed, facing the arrivals, with one load light per cell
	local panelCF = plaza * CFrame.new(0, 0, 8.6)
	ctx.part(lifter, Vector3.new(7.2, 9.4, 0.9), panelCF * CFrame.new(0, 4.7, 0), DARK, Enum.Material.Metal)
	ctx.part(lifter, Vector3.new(1, 3, 1), panelCF * CFrame.new(-2.6, 0.4, -0.9) * CFrame.Angles(math.rad(20), 0, 0), DARK, Enum.Material.Metal)
	ctx.part(lifter, Vector3.new(1, 3, 1), panelCF * CFrame.new(2.6, 0.4, -0.9) * CFrame.Angles(math.rad(20), 0, 0), DARK, Enum.Material.Metal)
	local screen = ctx.glow(lifter, Vector3.new(5.8, 5.6, 0.2), panelCF * CFrame.new(0, 5.6, -0.5), PANEL_BLUE, { Name = "LifterPanel", Transparency = 0.05 })
	ctx.light(screen, Color3.fromRGB(150, 190, 255), 14, 1.2)
	local slotLights: { BasePart } = {}
	local spacing = math.min(0.75, 5.6 / total)
	for i = 1, total do
		local x = (i - (total + 1) / 2) * spacing
		slotLights[i] = ctx.part(lifter, Vector3.new(spacing * 0.7, 0.55, 0.14), panelCF * CFrame.new(x, 2.1, -0.5), Color3.fromRGB(30, 34, 40), Enum.Material.SmoothPlastic, { CanCollide = false, CastShadow = false })
	end
	local liftPos = bedCF.Position
	-- where loaded cells sit on the bed (3 x 3 grid)
	local function bedSlot(i: number): CFrame
		local k = i - 1
		local col, row = k % 3, math.floor(k / 3)
		return bedCF * CFrame.new((col - 1) * 2.2, 0.15 + Carry.SIZE.Y / 2, (row - 1) * 2.2)
	end

	-- ============================================================ cells
	local function buildCell(cf: CFrame, id: number): Cell
		local opts = { Name = "CoreCell", CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }
		local case = ctx.part(root, Carry.SIZE, cf, DARK, Enum.Material.Metal, opts)
		case.Massless = true
		local parts: { BasePart } = { case }
		local function add(p: BasePart)
			p.Anchored = false
			p.Massless = true
			p.CanTouch = false
			local w = Instance.new("WeldConstraint")
			w.Part0 = case
			w.Part1 = p
			w.Parent = p
			table.insert(parts, p)
		end
		-- glowing core band through the middle + steel end caps + a carry handle on top
		add(ctx.glow(root, Vector3.new(Carry.SIZE.X * 0.6, Carry.SIZE.Y * 0.62, Carry.SIZE.Z + 0.08), cf, Carry.COLOR, { Name = "Core" }))
		for _, sx in { -1, 1 } do
			add(ctx.part(root, Vector3.new(0.16, Carry.SIZE.Y + 0.1, Carry.SIZE.Z + 0.1), cf * CFrame.new(sx * (Carry.SIZE.X / 2 - 0.05), 0, 0), STEEL, Enum.Material.Metal, { CanCollide = false, CanQuery = false, CastShadow = false }))
		end
		add(ctx.part(root, Vector3.new(0.9, 0.12, 0.14), cf * CFrame.new(0, Carry.SIZE.Y / 2 + 0.12, 0), STEEL, Enum.Material.Metal, { CanCollide = false, CanQuery = false, CastShadow = false }))
		-- lights the carrier up while the cell is in their arms (on in pickup, off in detach)
		local light = Instance.new("PointLight")
		light.Name = "CarryLight"
		light.Color = Carry.COLOR
		light.Range = 10
		light.Brightness = 1.6
		light.Shadows = false
		light.Enabled = false
		light.Parent = case
		local cell: Cell = {
			id = id,
			case = case,
			parts = parts,
			prompt = nil :: any,
			state = "cache",
			home = cf,
			cache = nil,
			carrier = nil,
			weld = nil,
			marker = nil,
			above = nil,
			everTaken = false,
		}
		return cell
	end

	-- ============================================================ caches
	local function groundAtXZ(x: number, z: number): number
		local y = if map.groundY then map.groundY(x, z) else top
		if type(y) ~= "number" or y ~= y then
			return top
		end
		return y
	end

	-- the centre of a place on the ground: the map's own number, else the plan's
	local function placeCentre(name: string): Vector3
		local p = if type(map.places) == "table" then map.places[name] else nil
		if typeof(p) == "Vector3" then
			return p
		end
		if name == "spilled" then
			local cr = if type(map.crash) == "table" then map.crash else nil
			local v2 = if cr and typeof(cr.spilled) == "Vector2" then cr.spilled else nil
			if v2 then
				return Vector3.new(v2.X, groundAtXZ(v2.X, v2.Y), v2.Y)
			end
			local cf = map.sites.codes
			if cf then
				return cf.Position
			end
		end
		local v = MapPlan.at(name)
		if v then
			return Vector3.new(v.X, groundAtXZ(v.X, v.Y), v.Y)
		end
		return plaza.Position
	end

	-- where the `n` cells of a place rest: the map's anchors (on the floor), the rest on a ring around the place centre
	local function restSpots(name: string, n: number): { CFrame }
		local out: { CFrame } = {}
		local list = if type(map.anchors) == "table" and type(map.anchors.cellSpots) == "table" then map.anchors.cellSpots[name] else nil
		if type(list) == "table" then
			for _, cf in list do
				if typeof(cf) == "CFrame" and #out < n then
					local p = cf.Position
					local g = groundAtXZ(p.X, p.Z)
					-- an anchor that sank into the ground comes up to it
					table.insert(out, if p.Y < g - 2 then CFrame.new(p.X, g, p.Z) * cf.Rotation else cf)
				end
			end
		end
		if #out < n then
			local c = placeCentre(name)
			for i = #out + 1, n do
				local a = (i - 1) / n * math.pi * 2 + 0.6
				local x, z = c.X + math.cos(a) * 5.5, c.Z + math.sin(a) * 5.5
				table.insert(out, CFrame.new(x, groundAtXZ(x, z), z) * CFrame.Angles(0, a + math.pi, 0))
			end
		end
		return out
	end

	local caches: { any } = {}
	local cacheSpots: { [string]: { CFrame } } = {}
	local placePositions: { [string]: Vector3 } = {}
	for _, name in PLACES do
		placePositions[name] = placeCentre(name)
		local n = counts[name]
		if n > 0 then
			local spots = restSpots(name, n)
			cacheSpots[name] = spots
			table.insert(caches, { name = name, pos = placePositions[name], spots = spots, cells = {}, marker = nil })
		end
	end

	local function cacheLeft(cache: any): number
		local n = 0
		for _, c in cache.cells do
			if c.state == "cache" then
				n += 1
			end
		end
		return n
	end

	local function refreshCacheMarker(cache: any)
		local n = cacheLeft(cache)
		if n <= 0 then
			if cache.marker then
				cache.marker:Destroy()
				cache.marker = nil
			end
			return
		end
		local label = PLACE_LABEL[cache.name] or "CORE CELL"
		local cap = if n == 1 then label else (label .. " x" .. n)
		if cache.marker and cache.marker.Parent then
			local l = cache.marker:FindFirstChild("Caption") :: TextLabel?
			if l then
				l.Text = cap
			end
		elseif cache.anchor then
			cache.marker = billboard(cache.anchor, "CacheMarker", cap, Vector3.new(0, 2.6, 0), 1200, 12)
		end
	end

	local pickup: (Cell, Player) -> ()

	-- place twists: crews, the mesa alarm, the graveyard wake-up and the refinery escalation
	local twists = HaulTwists.new(ctx, { liftPos = plaza.Position, places = placePositions, spots = cacheSpots })

	for _, cache in caches do
		local f = Instance.new("Model")
		f.Name = "CellCache"
		f.Parent = root
		local spots: { CFrame } = cache.spots
		for k, spot in spots do
			-- a round dark pad with a glowing ring on the floor; the cell stands upright on it (yaw only, the anchor's tilt is dropped)
			local floor = spot.Position
			local _, yaw = spot:ToOrientation()
			local at = CFrame.new(floor) * CFrame.Angles(0, yaw, 0)
			local padOpts = { CanCollide = false, CanQuery = false, CastShadow = false }
			ctx.cyl(f, 3.4, PAD_H, at * CFrame.new(0, PAD_H / 2, 0), DARK, Enum.Material.SmoothPlastic, padOpts)
			ctx.cyl(f, 2.7, PAD_H + 0.03, at * CFrame.new(0, PAD_H / 2, 0), Carry.COLOR, Enum.Material.Neon, { CanCollide = false, CanQuery = false, CastShadow = false, Transparency = 0.45 })
			local cell = buildCell(at * CFrame.new(0, PAD_H + Carry.SIZE.Y / 2 + 0.02, 0), #cells + 1)
			cell.cache = cache
			table.insert(cache.cells, cell)
			table.insert(cells, cell)
			-- a short lamp post by the first cell carries the place's marker
			if k == 1 then
				local post = at * CFrame.new(2.6, 0, 0)
				ctx.cyl(f, 0.35, 3.2, post * CFrame.new(0, 1.6, 0), DARK, Enum.Material.Metal, { CanCollide = false })
				cache.anchor = ctx.ball(f, 0.7, post * CFrame.new(0, 3.4, 0), Carry.COLOR, Enum.Material.Neon, { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
			end
		end
		refreshCacheMarker(cache)
	end

	-- ============================================================ carry helpers
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	local function groundAt(pos: Vector3): Vector3?
		if pos.Y ~= pos.Y or pos.Y < -40 then
			return nil
		end
		local list: { Instance } = { Workspace.Terrain }
		if map.folder then
			table.insert(list, map.folder)
		end
		table.insert(list, lifter)
		rayParams.FilterDescendantsInstances = list
		local hit = Workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), rayParams)
		if hit then
			return hit.Position
		end
		if map.groundY then
			return Vector3.new(pos.X, map.groundY(pos.X, pos.Z), pos.Z)
		end
		return nil
	end

	local function setCarryAttr(p: Player, on: boolean)
		local v = if on then true else nil
		if p.Parent then
			p:SetAttribute(Carry.ATTR, v)
		end
		local c = p.Character
		if c then
			c:SetAttribute(Carry.ATTR, v)
		end
	end

	-- unweld from the carrier and anchor at `cf` (the anchor comes AFTER the weld is gone: an anchored part welded to a
	-- character would pin the whole character)
	local function detach(cell: Cell, cf: CFrame)
		local p = cell.carrier
		if p then
			carriers[p] = nil
			setCarryAttr(p, false)
		end
		cell.carrier = nil
		if cell.weld then
			cell.weld:Destroy()
			cell.weld = nil
		end
		local light = cell.case:FindFirstChild("CarryLight")
		if light and light:IsA("PointLight") then
			light.Enabled = false
		end
		if cell.above then
			cell.above:Destroy()
			cell.above = nil
		end
		cell.case.Anchored = true
		cell.case.CFrame = cf
	end

	local function setDroppedMarker(cell: Cell, on: boolean)
		if on and not cell.marker then
			cell.marker = billboard(cell.case, "DroppedMarker", "CORE CELL", Vector3.new(0, 2.4, 0), 800, 10)
		elseif not on and cell.marker then
			cell.marker:Destroy()
			cell.marker = nil
		end
	end

	-- drop the carried cell where its carrier stands (reason: "drop" | "down" | "leave")
	local function drop(p: Player, reason: string)
		local cell = carriers[p]
		if not cell then
			return
		end
		local r = ctx.getRoot(p)
		local pos = if r and r.Parent then r.Position else (lastPos[p] or cell.case.Position)
		local g = groundAt(pos)
		dropLock[p] = os.clock()
		if not g then
			-- fell out of the world: back to its cache slot
			detach(cell, cell.home)
			cell.state = "cache"
			cell.prompt.Enabled = true
			if cell.cache then
				refreshCacheMarker(cell.cache)
			end
		else
			local yaw = CFrame.Angles(0, ctx.rng:NextNumber(0, math.pi * 2), 0)
			detach(cell, CFrame.new(g + Vector3.new(0, Carry.SIZE.Y / 2 + 0.05, 0)) * yaw)
			cell.state = "dropped"
			cell.prompt.Enabled = true
			setDroppedMarker(cell, true)
		end
		if reason ~= "leave" then
			callout(p, "Cell down!")
		end
		ctx.sound("Swap", cell.case.Position)
	end
	ctl.drop = drop

	pickup = function(cell: Cell, p: Player)
		if finished or not alive or carriers[p] then
			return
		end
		if cell.state ~= "cache" and cell.state ~= "dropped" then
			return
		end
		if os.clock() - (dropLock[p] or -99) < REPICK_LOCK then
			return
		end
		if S and S.Players and S.Players.getStance and S.Players.getStance(p) == "down" then
			return
		end
		local c = p.Character
		local torso = c and (c:FindFirstChild("UpperTorso") or c:FindFirstChild("HumanoidRootPart")) :: BasePart?
		if not torso then
			return
		end
		local fromCache = cell.state == "cache"
		cell.prompt.Enabled = false
		setDroppedMarker(cell, false)
		-- unanchor first, weld in the same thread (no physics step in between)
		cell.case.Anchored = false
		cell.case.CFrame = torso.CFrame * Carry.HOLD
		local w = Instance.new("Weld")
		w.Name = "CarryWeld"
		w.Part0 = torso
		w.Part1 = cell.case
		w.C0 = Carry.HOLD
		w.Parent = cell.case
		cell.weld = w
		cell.carrier = p
		cell.state = "carried"
		local light = cell.case:FindFirstChild("CarryLight")
		if light and light:IsA("PointLight") then
			light.Enabled = true
		end
		carriers[p] = cell
		local r = ctx.getRoot(p)
		lastPos[p] = if r then r.Position else torso.Position
		setCarryAttr(p, true)
		-- small icon above the carrier's head for everybody else (the carrier sees the cell in their hands)
		local above = billboard(cell.case, "CarrierIcon", nil, Vector3.new(0, 3.6, 0), 1000, 12)
		above.PlayerToHideFrom = p
		cell.above = above
		if fromCache and cell.cache then
			refreshCacheMarker(cell.cache)
		end
		callout(p, "Cell secured.")
		ctx.sound("Pickup", torso.Position)
		if fromCache and cell.cache then
			twists.onLift(cell.cache.name, p)
		end
		if not cell.everTaken then
			cell.everTaken = true
			ctx.intensity("SAMPLE") -- lifting a cell draws attention (same as a sample pickup)
		end
	end

	-- ============================================================ delivery + completion
	local function launchLifter()
		ctx.sound("Generator", liftPos)
		local beam = ctx.glow(lifter, Vector3.new(2.6, 600, 2.6), CFrame.new(liftPos + Vector3.new(0, 300, 0)), PANEL_BLUE, { Transparency = 1 })
		ctx.tween(beam, 0.8, { Transparency = 0.45 })
		local movers: { BasePart } = table.clone(bedParts)
		for _, c in cells do
			if c.state == "loaded" then
				table.insert(movers, c.case)
			end
		end
		task.delay(1.2, function()
			if not ctx.alive() then
				return
			end
			for _, m in movers do
				if m.Parent then
					m.CanCollide = false -- troopers standing on the bed stay on the plaza
					ctx.tween(m, 6, { CFrame = m.CFrame + Vector3.new(0, 140, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				end
			end
			task.delay(6.2, function()
				for _, m in movers do
					if m.Parent and m ~= bed then
						m.Transparency = 1
					end
				end
				for _, c in cells do
					if c.state == "loaded" then
						for _, part in c.parts do
							part.Transparency = 1
						end
					end
				end
				bed.Transparency = 1
				if beam.Parent then
					ctx.tween(beam, 1.5, { Transparency = 1 })
				end
			end)
		end)
	end

	-- the last cell is in: the lifter spools up for LAUNCH_SECONDS while the big wave hits; the step completes when it ends
	local function beginLaunch()
		local secs = if Workspace:GetAttribute("DebugFast") then DEBUG_LAUNCH_SECONDS else LAUNCH_SECONDS
		local st = entry.steps[1]
		st.text = string.format(LAUNCH_FMT, secs)
		st.progress = 0
		ctx.changed(true)
		ctx.notify(string.format("All cells loaded! The lifter launches in %d s: hold the plaza!", secs), Config.Colors.Danger)
		ctx.sound("Generator", liftPos)
		ctx.sound("Alarm", liftPos)
		twists.finalWave()
		task.spawn(function()
			local t0 = os.clock()
			local shown = secs
			while alive and ctx.alive() do
				local left = secs - (os.clock() - t0)
				if left <= 0 then
					break
				end
				local whole = math.ceil(left)
				if whole ~= shown then
					shown = whole
					st.text = string.format(LAUNCH_FMT, whole)
					st.progress = 1 - left / secs
					ctx.changed()
				end
				task.wait(0.25)
			end
			if not alive or not ctx.alive() then
				return
			end
			st.text = string.format(STEP_FMT, total, total)
			st.progress = nil
			ctx.completeStep(entry, 1, "The cargo lifter is launching!")
			launchLifter()
			onComplete()
		end)
	end

	local function load(cell: Cell, by: Player?)
		if cell.state == "loaded" or finished then
			return
		end
		delivered += 1
		local idx = delivered
		local from = cell.case.CFrame
		if cell.carrier then
			detach(cell, from)
		else
			cell.case.Anchored = true
		end
		cell.state = "loaded"
		cell.prompt.Enabled = false
		setDroppedMarker(cell, false)
		if cell.cache then
			refreshCacheMarker(cell.cache)
		end
		ctx.tween(cell.case, 0.5, { CFrame = bedSlot(idx) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local light = slotLights[idx]
		if light then
			light.Color = Carry.COLOR
			light.Material = Enum.Material.Neon
		end
		if by then
			callout(by, "Loading cell.")
		end
		ctx.sound("CrateOpen", liftPos)
		local st = entry.steps[1]
		st.text = string.format(STEP_FMT, delivered, total)
		st.progress = delivered / total
		ctx.changed(true)
		if delivered >= total then
			finished = true
			beginLaunch()
		else
			twists.onDelivered(delivered, total)
			if delivered % 2 == 0 then
				ctx.intensity("MAIN_STEP")
			end
		end
	end

	function ctl.stepsDone(): number
		-- reward weight comparable to the other mains (5 steps for a full haul)
		return math.floor(5 * delivered / total)
	end

	-- test hook (DebugHook "solve"): load the next cell straight away
	function ctl.debugSolve(player: Player): boolean
		if finished then
			return false
		end
		local held = carriers[player]
		if held then
			load(held, player)
			return true
		end
		for _, c in cells do
			if c.state ~= "loaded" and c.state ~= "carried" then
				load(c, player)
				return true
			end
		end
		return false
	end

	-- prompts (after `pickup` exists)
	for _, cell in cells do
		cell.prompt = ctx.prompt(cell.case, {
			action = "Pick Up",
			object = "Core Cell",
			hold = PICK_HOLD,
			distance = 8,
			onTrigger = function(p: Player)
				pickup(cell, p)
			end,
		})
	end

	-- ============================================================ watch loop: carriers (deliver / forced drops)
	task.spawn(function()
		while alive and ctx.alive() do
			task.wait(0.1)
			if not alive or not ctx.alive() then
				break
			end
			for p, cell in carriers do
				if not p.Parent then
					drop(p, "leave")
					continue
				end
				local r = ctx.getRoot(p)
				local w = cell.weld
				local stance = if S and S.Players and S.Players.getStance then S.Players.getStance(p) else "stand"
				if not ctx.isAlive(p) or not r or not w or not w.Parent or not w.Part0 or not w.Part0:IsDescendantOf(Workspace) or stance == "down"
					or p:GetAttribute("Downed") == true then
					drop(p, "down")
					continue
				end
				lastPos[p] = r.Position
				local d = r.Position - liftPos
				if Vector2.new(d.X, d.Z).Magnitude <= LIFT_RADIUS and math.abs(d.Y) <= LIFT_DY then
					load(cell, p)
				end
			end
		end
	end)

	local leaveConn = Players.PlayerRemoving:Connect(function(p)
		if carriers[p] then
			drop(p, "leave")
		end
		lastPos[p] = nil
		dropLock[p] = nil
	end)

	ctx.setMarker(entry, liftPos)
	ctx.changed(true)
	ctx.notify(string.format("Recover %d core cells and load them into the cargo lifter.", total), Config.Colors.Friendly)
	twists.start()

	function ctl.stop()
		alive = false
		twists.stop()
		leaveConn:Disconnect()
		for p, cell in carriers do
			setCarryAttr(p, false)
			if cell.weld then
				cell.weld:Destroy()
				cell.weld = nil
			end
		end
		table.clear(carriers)
	end

	return ctl
end

return HaulCells
