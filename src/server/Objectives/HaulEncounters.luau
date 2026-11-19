-- Per-site encounters for the desert HAUL mission ("Recover Core Cells").
-- Each cell site gets a distinct encounter, never repeated in the same mission:
--   courier  : a COG courier robot (LOOT_COG) carries the cell and flees when it notices a trooper; kill it to drop the cell
--   cradle   : cell locked in a powered clamp; hold E to release, then defend ~20 s against a small wave while it unclamps
--   conveyor : (quarry) cells ride the pit conveyor belt toward a crusher; grab before destroyed or it respawns on the far rim
--   guardian : a heavy enemy (Bulwark or Bastion) sits dormant next to the cell and wakes when the cell is lifted (or shot)
--   buried   : cell buried under sand and rubble; shoot or blast the rubble to free it (with a slow dig fallback if dry)
--
-- Low part counts and phone-friendly ProximityPrompts throughout.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Carry = require(Shared.Carry)
local Net = require(Shared.Net)
local Weapons = require(Shared.Data.Weapons)
local EnemyData = require(Shared.Data.Enemies)
local MapPlan = require(script.Parent.Parent.World.MapPlan)
local Garrisons = require(script.Parent.Parent.Enemies.Garrisons)

local HaulEncounters = {}

HaulEncounters.LABELS = {
	courier = "Courier",
	cradle = "Cradle",
	conveyor = "Conveyor",
	guardian = "Guardian",
	buried = "Buried",
}

local DORMANT_OFF = 1e15
local DARK = Color3.fromRGB(40, 44, 52)
local STEEL = Color3.fromRGB(104, 112, 124)
local HAZARD = Color3.fromRGB(238, 184, 42)
local SAND_ROCK = Color3.fromRGB(168, 122, 86)
local RUBBLE_ROCK = Color3.fromRGB(124, 92, 70)
local DANGER_RED = Color3.fromRGB(255, 76, 60)
local AMBER = Color3.fromRGB(255, 186, 62)
local CALLOUT = Color3.fromRGB(244, 246, 250)

local BELT_ACTIVATE_R = 115
local BELT_SPEED = 0.95
local COURIER_NOTICE_R = 65
local COURIER_CLOSE_R = 38
local CRADLE_DEFEND_R = 55
local RUBBLE_HP = 180

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function flatUnit(v: Vector3, fallback: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.05 then f.Unit else fallback
end

local function makeBanner(adornee: BasePart, name: string, text: string, color: Color3, offset: Vector3, maxDist: number, withBar: boolean?): (BillboardGui, TextLabel, Frame?)
	local bb = Instance.new("BillboardGui")
	bb.Name = name
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(190, if withBar then 34 else 22)
	bb.StudsOffsetWorldSpace = offset
	bb.MaxDistance = maxDist
	bb.Adornee = adornee

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Caption"
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 0, 18)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 12
	lbl.TextColor3 = color
	lbl.TextStrokeTransparency = 0.35
	lbl.Text = text
	lbl.Parent = bb

	local fill: Frame? = nil
	if withBar then
		local bg = Instance.new("Frame")
		bg.Name = "BarBg"
		bg.AnchorPoint = Vector2.new(0.5, 0)
		bg.Position = UDim2.new(0.5, 0, 0, 20)
		bg.Size = UDim2.fromOffset(110, 6)
		bg.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
		bg.BackgroundTransparency = 0.2
		bg.BorderSizePixel = 0
		bg.Parent = bb
		local f = Instance.new("Frame")
		f.Name = "Fill"
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		f.Parent = bg
		fill = f
	end

	bb.Parent = adornee
	return bb, lbl, fill
end

-- Assign a distinct encounter kind to each cache (never repeated in the same mission).
function HaulEncounters.assign(caches: { any }, rng: Random)
	local haulCfg = MapPlan.haul or {}
	local fixed: { [string]: string } = haulCfg.fixedEncounters or { quarry = "conveyor" }
	local poolSrc: { string } = haulCfg.encounterPool or { "courier", "cradle", "guardian", "buried" }
	local used: { [string]: boolean } = {}

	-- First pass: fixed site assignments (quarry -> conveyor)
	for _, cache in caches do
		local fx = fixed[cache.name]
		if fx and not used[fx] then
			cache.encounter = fx
			used[fx] = true
		end
	end

	-- Build shuffled pool of remaining unused encounter kinds
	local pool: { string } = {}
	for _, kind in poolSrc do
		if not used[kind] then
			table.insert(pool, kind)
		end
	end
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	local pi = 1
	for _, cache in caches do
		if not cache.encounter then
			local pick = pool[pi] or "cradle"
			pi += 1
			cache.encounter = pick
			used[pick] = true
		end
	end
end

function HaulEncounters.new(ctx: any, opts: any): any
	local S = ctx.S
	local map = ctx.map
	local rng = ctx.rng
	local root: Instance = opts.root
	local liftPos: Vector3 = opts.liftPos
	local faction = if EnemyData.Factions[ctx.faction] then ctx.faction else "COG"
	local roster = EnemyData.Factions[faction].roster
	local difficulty = math.clamp(math.floor(tonumber(ctx.difficulty) or 1), 1, 5)
	local anchors = map.anchors or {}
	local haulCfg = MapPlan.haul or {}

	local alive = true
	local hitConfirmEv = Net.event("HitConfirm")
	local fireConn: RBXScriptConnection? = nil

	local encFolder = Instance.new("Folder")
	encFolder.Name = "HaulEncounters"
	encFolder.Parent = root

	local states: { [any]: any } = {}
	local rubbleById: { [number]: any } = {}
	local rubbleParts: { BasePart } = {}
	local nextRubbleId = 0
	local usedTerraces: { [number]: boolean } = {}
	local seq = 0

	local function say(line: string, who: Player?)
		local p = who
		if not p then
			local list = ctx.players()
			if #list > 0 then
				p = list[rng:NextInteger(1, #list)]
			end
		end
		if p and S and S.State then
			S.State.notify(nil, p.DisplayName .. ": " .. line, CALLOUT, "comms")
		else
			ctx.notify(line, Config.Colors.Danger)
		end
	end

	local function hasLOS(fromPos: Vector3, toPos: Vector3): boolean
		local dir = toPos - fromPos
		if dir.Magnitude < 2 then
			return true
		end
		local excl: { Instance } = {}
		local ef = Workspace:FindFirstChild("Enemies")
		if ef then
			table.insert(excl, ef)
		end
		for _, p in Players:GetPlayers() do
			if p.Character then
				table.insert(excl, p.Character)
			end
		end
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = excl
		rp.RespectCanCollide = true
		rp.IgnoreWater = true
		local hit = Workspace:Raycast(fromPos, dir, rp)
		if not hit then
			return true
		end
		return (hit.Position - toPos).Magnitude <= 5
	end

	local function spawnEnemy(kind: string, pos: Vector3, face: Vector3?, eOpts: any, adopt: boolean): any?
		if not alive or not ctx.alive() or not (S and S.Enemies and S.Enemies.spawn) then
			return nil
		end
		local cf = CFrame.new(pos)
		if face then
			local d = Vector3.new(face.X - pos.X, 0, face.Z - pos.Z)
			if d.Magnitude > 0.4 then
				cf = CFrame.lookAt(pos, pos + d)
			end
		end
		local ok, e = pcall(S.Enemies.spawn, kind, cf, eOpts)
		if not ok or not e then
			return nil
		end
		if adopt then
			Garrisons.adopt(e)
		else
			e.garrison = true
		end
		return e
	end

	-- ------------------------------------------------------------------ 1. COURIER
	local function setupCourier(cache: any)
		local cell = cache.cells[1]
		if not cell then
			return
		end
		cell.state = "locked"
		cell.prompt.Enabled = false
		states[cache] = {
			kind = "courier",
			cell = cell,
			spawned = false,
			fleeing = false,
			done = false,
			enemy = nil,
			weld = nil,
			bb = nil,
		}
	end

	local function releaseCourierCell(cache: any, st: any, dropAt: Vector3?)
		if st.done then
			return
		end
		st.done = true
		cache.trackPos = nil
		if st.bb then
			st.bb:Destroy()
			st.bb = nil
		end
		if st.weld then
			st.weld:Destroy()
			st.weld = nil
		end
		local cell = st.cell
		if cell and cell.state == "locked" then
			local g = if dropAt then opts.groundAt(dropAt) else nil
			local targetCF = if g
				then CFrame.new(g + Vector3.new(0, Carry.SIZE.Y / 2 + 0.08, 0))
				else cell.home
			cell.case.Anchored = true
			cell.case.CFrame = targetCF
			cell.state = "dropped"
			cell.prompt.Enabled = true
			if opts.setDroppedMarker then
				opts.setDroppedMarker(cell, true)
			end
		end
		if opts.onSiteUpdated then
			opts.onSiteUpdated(cache)
		end
	end

	local function activateCourier(cache: any, st: any)
		if st.spawned or st.done then
			return
		end
		st.spawned = true
		local cell = st.cell
		if not cell or cell.state ~= "locked" then
			st.done = true
			return
		end
		local kind = if faction == "BROOD" then "LOOT_BROOD" else "LOOT_COG"
		local spawnPos = opts.groundAt(cell.home.Position) or cell.home.Position
		local e = spawnEnemy(kind, spawnPos, liftPos, { hpScale = 1, aggro = false, patrol = false }, true)
		if not e or not e.root then
			-- fallback: never lock the cell if spawn failed
			releaseCourierCell(cache, st, spawnPos)
			return
		end
		e.nextThink = DORMANT_OFF
		st.enemy = e

		-- Attach the glowing core cell onto the courier's back
		cell.case.Anchored = false
		local holdOffset = CFrame.new(0, 1.35, 0.75)
		cell.case.CFrame = e.root.CFrame * holdOffset
		local w = Instance.new("Weld")
		w.Name = "CourierCellWeld"
		w.Part0 = e.root
		w.Part1 = cell.case
		w.C0 = holdOffset
		w.Parent = cell.case
		st.weld = w

		-- If this site has a second cell, guard it with 2 light units
		if #cache.cells > 1 then
			seq += 1
			local sq = "haul_cour_esc_" .. seq
			for k = 2, #cache.cells do
				local cpos = cache.cells[k].home.Position
				local gpos = opts.groundAtXZ(cpos.X + 4 * (if k % 2 == 0 then 1 else -1), cpos.Z + 3)
				spawnEnemy(roster.regular, gpos, liftPos, { posture = "guard", squad = sq, home = gpos, aggro = false, patrol = false }, true)
			end
		end
	end

	local function stepCourier(cache: any, st: any)
		if not st.spawned or st.done then
			return
		end
		local e = st.enemy
		if not e or not e.alive then
			local pos = if e and e.pos then e.pos else nil
			if pos then
				ctx.fx("LootBurst", { p = pos + Vector3.new(0, 2, 0), f = faction })
				ctx.sound("ObjectiveDone", pos)
				ctx.notify("Courier down! Grab the dropped core cell.", Config.Colors.Friendly)
			end
			releaseCourierCell(cache, st, pos)
			return
		end
		local ePos = e.pos or (e.root and e.root.Position)
		if not ePos then
			return
		end
		if not st.fleeing then
			local triggered = e.hp < e.maxHp - 0.01
			local spotter: Player? = nil
			if not triggered then
				for _, p in ctx.players() do
					local r = ctx.getRoot(p)
					if r then
						local d = flat(r.Position, ePos)
						if d <= COURIER_CLOSE_R or (d <= COURIER_NOTICE_R and hasLOS(ePos + Vector3.new(0, 3, 0), r.Position + Vector3.new(0, 3, 0))) then
							triggered = true
							spotter = p
							break
						end
					end
				end
			end
			if triggered then
				st.fleeing = true
				e.nextThink = Workspace:GetServerTimeNow()
				if opts.onReveal then
					opts.onReveal(cache)
				end
				if e.root and e.root.Parent then
					local bb = makeBanner(e.root, "CourierTag", "CELL COURIER — CHASE!", AMBER, Vector3.new(0, 4.4, 0), 900, false)
					st.bb = bb
				end
				ctx.sound("Alarm", ePos)
				say("Courier's bolting with a core cell! Cut it off!", spotter)
				ctx.notify("COG Courier spotted fleeing with a core cell!", Config.Colors.Danger)
			end
		else
			cache.trackPos = ePos
		end
	end

	-- ------------------------------------------------------------------ 2. CRADLE
	local function setupCradle(cache: any)
		local model = Instance.new("Model")
		model.Name = "CellCradle_" .. cache.name
		model.Parent = encFolder

		local jaws: { { part: BasePart, openCF: CFrame } } = {}
		local lights: { BasePart } = {}
		for _, cell in cache.cells do
			cell.state = "locked"
			cell.prompt.Enabled = false
			local cf = cell.home
			for _, sx in { -1, 1 } do
				local closed = cf * CFrame.new(sx * (Carry.SIZE.X / 2 + 0.35), 0.1, 0)
				local open = cf * CFrame.new(sx * (Carry.SIZE.X / 2 + 1.65), 0.1, 0)
				local jaw = ctx.part(model, Vector3.new(0.45, Carry.SIZE.Y + 0.5, Carry.SIZE.Z + 0.5), closed, STEEL, Enum.Material.Metal, { CastShadow = false })
				table.insert(jaws, { part = jaw, openCF = open })
			end
			local lockBar = ctx.glow(model, Vector3.new(Carry.SIZE.X + 0.9, 0.2, 0.25), cf * CFrame.new(0, Carry.SIZE.Y / 2 + 0.25, 0), AMBER, { Name = "ClampLock" })
			table.insert(lights, lockBar)
		end

		local first = cache.cells[1]
		local consoleBase = first.home * CFrame.new(-2.8, -Carry.SIZE.Y / 2, 0)
		local post = ctx.part(model, Vector3.new(1.1, 3.6, 0.9), consoleBase * CFrame.new(0, 1.8, 0), DARK, Enum.Material.Metal, { Name = "CradleConsole" })
		local scr = ctx.glow(model, Vector3.new(0.85, 0.95, 0.18), consoleBase * CFrame.new(0, 2.7, -0.45), AMBER, { Name = "CradleScreen" })
		table.insert(lights, scr)
		local bb, lbl, fill = makeBanner(post, "CradleBanner", "LOCKED CRADLE", AMBER, Vector3.new(0, 3.2, 0), 160, true)
		if fill then
			fill.Size = UDim2.fromScale(0, 1)
		end

		local st: any = {
			kind = "cradle",
			model = model,
			jaws = jaws,
			lights = lights,
			bb = bb,
			lbl = lbl,
			fill = fill,
			started = false,
			done = false,
			prompt = nil,
		}

		local duration = if Workspace:GetAttribute("DebugFast") then 4 else (haulCfg.cradleSeconds or 20)
		st.prompt = ctx.prompt(post, {
			action = "Release Clamp",
			object = "Cell Cradle",
			hold = 1.0,
			distance = 9,
			onTrigger = function(player: Player)
				if st.started or st.done or not alive then
					return
				end
				st.started = true
				st.prompt.Enabled = false
				if opts.onReveal then
					opts.onReveal(cache)
				end
				ctx.sound("Generator", post.Position)
				ctx.sound("Alarm", post.Position)
				say("Cradle release started — hold off the wave!", player)
				ctx.notify(string.format("Cell cradle unclamping (%d s): defend the site!", duration), Config.Colors.Danger)

				if opts.spawnWave then
					opts.spawnWave(cache.pos, 4, "cradle")
				end

				task.spawn(function()
					local elapsed = 0
					local midWave = false
					while alive and ctx.alive() and not st.done do
						task.wait(0.25)
						if not alive or not ctx.alive() or st.done then
							return
						end
						local near = #ctx.playersNear(cache.pos, CRADLE_DEFEND_R) > 0
						if near then
							elapsed += 0.25
						end
						local frac = math.clamp(elapsed / duration, 0, 1)
						if not midWave and frac >= 0.48 then
							midWave = true
							if opts.spawnWave then
								opts.spawnWave(cache.pos, 3, "cradle2")
							end
						end
						if st.lbl and st.lbl.Parent then
							local left = math.max(0, math.ceil(duration - elapsed))
							st.lbl.Text = if near then string.format("UNCLAMPING %d s", left) else "RETURN TO CRADLE"
						end
						if st.fill and st.fill.Parent then
							st.fill.Size = UDim2.fromScale(frac, 1)
						end
						if elapsed >= duration then
							st.done = true
							for _, j in st.jaws do
								if j.part.Parent then
									ctx.tween(j.part, 0.7, { CFrame = j.openCF }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
								end
							end
							for _, l in st.lights do
								if l.Parent then
									l.Color = Carry.COLOR
								end
							end
							if st.bb and st.bb.Parent then
								st.bb:Destroy()
							end
							for _, cell in cache.cells do
								if cell.state == "locked" then
									cell.state = "cache"
									cell.prompt.Enabled = true
								end
							end
							ctx.sound("ObjectiveDone", cache.pos)
							ctx.sound("CrateOpen", cache.pos)
							ctx.notify("Cradle unlocked! Core cell ready for pickup.", Config.Colors.Friendly)
							if opts.onSiteUpdated then
								opts.onSiteUpdated(cache)
							end
							return
						end
					end
				end)
			end,
		})

		states[cache] = st
	end

	-- ------------------------------------------------------------------ 3. CONVEYOR (QUARRY)
	local function worseQuarrySpot(): CFrame
		local terr: { CFrame } = {}
		for _, cf in anchors.terraces or {} do
			if typeof(cf) == "CFrame" then
				table.insert(terr, cf)
			end
		end
		-- Pick the unused terrace farthest from the refinery (worse haul back!)
		local bestIdx: number? = nil
		local bestDist = -1
		for i, cf in terr do
			if not usedTerraces[i] then
				local d = flat(cf.Position, liftPos)
				if d > bestDist then
					bestDist = d
					bestIdx = i
				end
			end
		end
		if bestIdx then
			usedTerraces[bestIdx] = true
			return terr[bestIdx]
		end
		-- Fallback: far rim of the quarry pit away from the refinery
		local qPos = map.places and map.places.quarry or Vector3.new(165, 0, -168)
		local away = flatUnit(qPos - liftPos, Vector3.new(1, 0, -1))
		local ang = rng:NextNumber(-0.45, 0.45)
		local dir = CFrame.Angles(0, ang, 0) * away
		local p = opts.groundAtXZ(qPos.X + dir.X * 42, qPos.Z + dir.Z * 42)
		return CFrame.new(p)
	end

	local function setupConveyor(cache: any)
		local spots: { CFrame } = cache.spots
		if #spots == 0 then
			return
		end
		local beltDir: Vector3
		if #spots >= 2 then
			beltDir = flatUnit(spots[#spots].Position - spots[1].Position, Vector3.new(1, 0, 0))
		else
			local toRef = flatUnit(liftPos - cache.pos, Vector3.new(-1, 0, 1))
			beltDir = Vector3.new(-toRef.Z, 0, toRef.X)
		end

		local firstPos = spots[1].Position
		local lastPos = spots[#spots].Position
		local beltLen = math.max(flat(firstPos, lastPos), 8)
		local beltY = firstPos.Y
		local crusherPos = Vector3.new(lastPos.X, beltY, lastPos.Z) + beltDir * 7.5
		local crusherCF = CFrame.lookAt(crusherPos, crusherPos + beltDir)

		-- Shift resting cells toward the upstream end so players get ~18-26 s before the first reaches the crusher
		for i, cell in cache.cells do
			local backDist = beltLen + 4.5 - (i - 1) * 3.8
			local p = crusherPos - beltDir * math.max(backDist, 14)
			local cellY = beltY + 0.2 + Carry.SIZE.Y / 2 + 0.02
			local cf = CFrame.new(p.X, cellY, p.Z) * CFrame.Angles(0, math.atan2(beltDir.X, beltDir.Z), 0)
			cell.home = cf
			cell.case.CFrame = cf
			cell.onBelt = true
		end

		-- Build chunky Crusher gate at the downstream end of the belt (low part count: 7 parts)
		local model = Instance.new("Model")
		model.Name = "QuarryCrusher"
		model.Parent = encFolder
		for _, sx in { -2.7, 2.7 } do
			ctx.part(model, Vector3.new(0.9, 6.2, 1.4), crusherCF * CFrame.new(sx, 3.1, 0), DARK, Enum.Material.Metal)
		end
		local header = ctx.part(model, Vector3.new(6.4, 1.3, 1.8), crusherCF * CFrame.new(0, 6.0, 0), DARK, Enum.Material.Metal, { Name = "CrusherHead" })
		ctx.glow(model, Vector3.new(5.2, 0.45, 0.45), crusherCF * CFrame.new(0, 6.1, 0.95), DANGER_RED, { Name = "CrusherLight" })
		local jawBaseCF = crusherCF * CFrame.new(0, 3.4, 0)
		local jaw = ctx.part(model, Vector3.new(4.4, 1.6, 1.4), jawBaseCF, HAZARD, Enum.Material.DiamondPlate, { CanCollide = false })
		local bb, lbl = makeBanner(header, "CrusherTag", "CRUSHER", DANGER_RED, Vector3.new(0, 2.4, 0), 170, false)
		bb.Enabled = false

		states[cache] = {
			kind = "conveyor",
			beltDir = beltDir,
			crusherPos = crusherPos,
			jaw = jaw,
			jawBaseCF = jawBaseCF,
			bb = bb,
			lbl = lbl,
			active = false,
			phase = 0,
		}
	end

	local function stepConveyor(cache: any, st: any, dt: number)
		local anyOnBelt = false
		for _, cell in cache.cells do
			if cell.state == "cache" and cell.onBelt then
				anyOnBelt = true
				break
			end
		end
		if not anyOnBelt then
			if st.bb and st.bb.Enabled then
				st.bb.Enabled = false
			end
			return
		end
		if not st.active then
			if #ctx.playersNear(cache.pos, BELT_ACTIVATE_R) > 0 then
				st.active = true
				if st.bb then
					st.bb.Enabled = true
				end
				ctx.sound("Generator", st.crusherPos)
				say("Quarry conveyor's running! Grab the cells before the crusher!", nil)
				ctx.notify("Quarry belt active! Grab core cells before they hit the crusher!", Config.Colors.Danger)
			else
				return
			end
		end

		st.phase += dt * 4.5
		if st.jaw and st.jaw.Parent then
			local bob = math.sin(st.phase) * 0.95
			st.jaw.CFrame = st.jawBaseCF * CFrame.new(0, bob, 0)
		end

		local stepVec = st.beltDir * (BELT_SPEED * dt)
		for _, cell in cache.cells do
			if cell.state == "cache" and cell.onBelt then
				local nextCF = cell.case.CFrame + stepVec
				cell.case.CFrame = nextCF
				local toCrush = st.crusherPos - nextCF.Position
				local remain = Vector3.new(toCrush.X, 0, toCrush.Z):Dot(st.beltDir)
				if remain <= 1.6 then
					-- Crushed! Respawn at a worse guarded spot on the far quarry rim
					cell.onBelt = false
					ctx.fx("Debris", { p = st.crusherPos + Vector3.new(0, 1.5, 0), n = 14, c = Carry.COLOR, style = "scrap" })
					ctx.sound("HitMetal", st.crusherPos)
					ctx.sound("Alarm", st.crusherPos)

					local worse = worseQuarrySpot()
					local floor = worse.Position
					local gY = opts.groundAtXZ(floor.X, floor.Z).Y
					local padCF = CFrame.new(floor.X, gY, floor.Z)
					ctx.cyl(encFolder, 3.2, 0.2, padCF * CFrame.new(0, 0.1, 0), DARK, Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false, CastShadow = false })
					local newCF = padCF * CFrame.new(0, 0.2 + Carry.SIZE.Y / 2 + 0.02, 0)
					cell.home = newCF
					cell.case.CFrame = newCF
					cell.state = "cache"
					cell.prompt.Enabled = true
					if opts.setDroppedMarker then
						opts.setDroppedMarker(cell, true)
					end
					-- Guard the worse spot with 2 COG troopers
					seq += 1
					local sq = "haul_crush_" .. seq
					for g = 1, 2 do
						local ang = (g == 1 and 1.1 or -1.1)
						local gp = opts.groundAtXZ(floor.X + math.cos(ang) * 5.5, floor.Z + math.sin(ang) * 5.5)
						local kind = if g == 1 then roster.medium else roster.regular
						spawnEnemy(kind, gp, liftPos, { posture = "guard", squad = sq, home = gp, aggro = false, patrol = false }, true)
					end
					ctx.notify("Core cell crushed! Backup cell dropped on the far quarry rim!", Config.Colors.Danger)
					if opts.onSiteUpdated then
						opts.onSiteUpdated(cache)
					end
				end
			end
		end
	end

	-- ------------------------------------------------------------------ 4. SLEEPING GUARDIAN
	local function setupGuardian(cache: any)
		states[cache] = {
			kind = "guardian",
			spawned = false,
			woken = false,
			enemy = nil,
			bb = nil,
		}
	end

	local function activateGuardian(cache: any, st: any)
		if st.spawned then
			return
		end
		st.spawned = true
		local cell = cache.cells[1]
		local cPos = if cell then cell.home.Position else cache.pos
		local toLift = flatUnit(liftPos - cPos, Vector3.new(0, 0, -1))
		local gPos = opts.groundAtXZ(cPos.X + toLift.X * 6.5, cPos.Z + toLift.Z * 6.5)

		local heavyKind = roster.heavy or "BULWARK"
		if faction == "COG" and rng:NextNumber() < 0.4 then
			heavyKind = "BASTION"
		end
		local e = spawnEnemy(heavyKind, gPos, gPos + toLift * 10, { posture = "guard", squad = "haul_guard_" .. cache.name, home = gPos, aggro = false, patrol = false }, true)
		if e then
			e.nextThink = DORMANT_OFF
			st.enemy = e
			if e.root and e.root.Parent then
				local bb = makeBanner(e.root, "DormantTag", "DORMANT HEAVY", AMBER, Vector3.new(0, 5.2, 0), 90, false)
				st.bb = bb
			end
		end
	end

	local function wakeGuardian(cache: any, st: any, who: Player?)
		if st.woken then
			return
		end
		st.woken = true
		if st.bb and st.bb.Parent then
			st.bb:Destroy()
			st.bb = nil
		end
		local e = st.enemy
		if e and e.alive then
			local ePos = e.pos or cache.pos
			e.nextThink = Workspace:GetServerTimeNow()
			ctx.sound("HitMetal", ePos)
			ctx.sound("Alarm", ePos)
			say("Heavy unit just powered up! Watch out!", who)
			ctx.notify("Sleeping guardian awakened!", Config.Colors.Danger)
			if opts.wakeAlert then
				opts.wakeAlert(e, who, ePos)
			else
				e.aggro = true
			end
			if difficulty >= 3 and opts.spawnWave then
				opts.spawnWave(cache.pos, 2, "guard_esc")
			end
		end
	end

	local function stepGuardian(cache: any, st: any)
		if not st.spawned or st.woken then
			return
		end
		local e = st.enemy
		if not e or not e.alive then
			st.woken = true
			if st.bb and st.bb.Parent then
				st.bb:Destroy()
				st.bb = nil
			end
			return
		end
		-- Shooting or damaging the sleeping heavy wakes it immediately
		if e.hp < e.maxHp - 0.01 or e.awareState == "alert" then
			wakeGuardian(cache, st, e.lastHitBy)
		end
	end

	-- ------------------------------------------------------------------ 5. BURIED (RUBBLE)
	local function rebuildRubbleList()
		table.clear(rubbleParts)
		for _, m in rubbleById do
			if not m.broken then
				for _, p in m.parts do
					if p.Parent then
						table.insert(rubbleParts, p)
					end
				end
			end
		end
	end

	local function shatterMound(m: any, byBlast: boolean)
		if m.broken then
			return
		end
		m.broken = true
		rubbleById[m.id] = nil
		rebuildRubbleList()

		local pos = m.pos
		ctx.fx("Debris", { p = pos + Vector3.new(0, 1.2, 0), n = if byBlast then 18 else 12, c = SAND_ROCK, style = "rock" })
		ctx.sound("CrateOpen", pos)
		if m.model and m.model.Parent then
			m.model:Destroy()
		end
		local cell = m.cell
		if cell and cell.state == "locked" then
			cell.state = "cache"
			cell.prompt.Enabled = true
		end
		ctx.notify("Rubble cleared! Core cell uncovered.", Config.Colors.Friendly)
		if opts.onSiteUpdated then
			opts.onSiteUpdated(m.cache)
		end
	end

	local function damageMound(m: any, amount: number, hitPos: Vector3?, shooter: Player?, byBlast: boolean)
		if m.broken or amount <= 0 then
			return
		end
		m.hp = math.max(0, m.hp - amount)
		local broke = m.hp <= 0
		if shooter and shooter.Parent then
			hitConfirmEv:FireClient(shooter, "pen", hitPos or m.pos, broke, false, 0)
		end
		if broke then
			shatterMound(m, byBlast)
			return
		end
		local frac = m.hp / m.maxHp
		if m.fill and m.fill.Parent then
			m.fill.Size = UDim2.fromScale(frac, 1)
		end
		ctx.fx("Debris", { p = hitPos or (m.pos + Vector3.new(0, 1, 0)), n = 4, c = SAND_ROCK, style = "rock" })
		ctx.sound("HitMetal", hitPos or m.pos)
		-- Visually chip off outer rubble blocks at 66% and 33% HP
		if frac <= 0.66 and m.stage == 0 then
			m.stage = 1
			local p = m.chunks[1]
			if p and p.Parent then
				p:Destroy()
				rebuildRubbleList()
			end
		elseif frac <= 0.33 and m.stage <= 1 then
			m.stage = 2
			local p = m.chunks[2]
			if p and p.Parent then
				p:Destroy()
				rebuildRubbleList()
			end
		end
	end

	local function setupBuried(cache: any)
		local mounds: { any } = {}
		for _, cell in cache.cells do
			cell.state = "locked"
			cell.prompt.Enabled = false
			nextRubbleId += 1
			local mid = nextRubbleId

			local model = Instance.new("Model")
			model.Name = "BuriedRubble_" .. mid
			model.Parent = encFolder

			local base = cell.home.Position
			local parts: { BasePart } = {}
			local chunks: { BasePart } = {}

			local function rock(size: Vector3, offset: Vector3, rot: Vector3, color: Color3, mat: Enum.Material, isChunk: boolean?): BasePart
				local cf = CFrame.new(base + offset) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
				local p = ctx.part(model, size, cf, color, mat, { Name = "Rubble", CanCollide = true, CanQuery = true })
				p:SetAttribute("HaulRubble", mid)
				table.insert(parts, p)
				if isChunk then
					table.insert(chunks, p)
				end
				return p
			end

			local core = rock(Vector3.new(3.2, 1.9, 2.8), Vector3.new(0, 0.25, 0), Vector3.new(4, 18, -6), SAND_ROCK, Enum.Material.Sandstone, false)
			rock(Vector3.new(2.2, 1.6, 2.0), Vector3.new(1.1, 0.1, 0.6), Vector3.new(-10, 42, 12), RUBBLE_ROCK, Enum.Material.Concrete, true)
			rock(Vector3.new(2.1, 1.4, 2.1), Vector3.new(-1.1, 0.05, -0.5), Vector3.new(14, -28, -8), SAND_ROCK, Enum.Material.Sandstone, true)
			rock(Vector3.new(1.8, 0.6, 2.4), Vector3.new(0.2, 0.9, -0.4), Vector3.new(18, 65, 14), STEEL, Enum.Material.Metal, false)
			-- Small cyan energy glint peeking through the rubble so players immediately spot the buried cell
			ctx.glow(model, Vector3.new(0.7, 0.4, 0.7), CFrame.new(base + Vector3.new(0, 1.18, 0.35)), Carry.COLOR, { Name = "CellGlint" })

			local bb, lbl, fill = makeBanner(core, "BuriedTag", "BURIED CELL — SHOOT / BLAST", AMBER, Vector3.new(0, 2.5, 0), 130, true)

			local m: any = {
				id = mid,
				cache = cache,
				cell = cell,
				pos = base,
				model = model,
				parts = parts,
				chunks = chunks,
				bb = bb,
				lbl = lbl,
				fill = fill,
				hp = RUBBLE_HP,
				maxHp = RUBBLE_HP,
				stage = 0,
				broken = false,
			}

			-- Fallback slow manual dig prompt in case a player has zero ammo and zero grenades
			ctx.prompt(core, {
				action = "Dig Out",
				object = "Buried Cell (Or Shoot)",
				hold = 3.5,
				distance = 7,
				onTrigger = function(_player: Player)
					shatterMound(m, false)
				end,
			})

			rubbleById[mid] = m
			table.insert(mounds, m)
		end
		rebuildRubbleList()
		states[cache] = { kind = "buried", mounds = mounds }
	end

	-- Listen to gunfire so shooting buried rubble deals weapon damage with crisp hitmarkers
	fireConn = Net.event("Fire").OnServerEvent:Connect(function(p: Player, slot: any, aimPoint: any)
		if not alive or #rubbleParts == 0 or typeof(aimPoint) ~= "Vector3" or typeof(slot) ~= "number" then
			return
		end
		if not ctx.isAlive(p) or Carry.isCarrying(p) then
			return
		end
		local rec = S and S.Players and S.Players.get and S.Players.get(p)
		if not rec or slot ~= rec.slot then
			return
		end
		local ws = rec.weapons and rec.weapons[rec.slot]
		if not ws then
			return
		end
		local w = Weapons.get(ws.id)
		if not w then
			return
		end
		local ch = p.Character
		local head = ch and (ch:FindFirstChild("Head") or ch:FindFirstChild("HumanoidRootPart")) :: BasePart?
		if not head then
			return
		end
		local origin = head.Position
		local toAim = aimPoint - origin
		if toAim.Magnitude < 0.5 then
			return
		end
		local dir = toAim.Unit
		local range = math.min(w.range or 300, 260)

		local inc = RaycastParams.new()
		inc.FilterType = Enum.RaycastFilterType.Include
		inc.FilterDescendantsInstances = rubbleParts
		local hit = Workspace:Raycast(origin, dir * range, inc)
		if not hit or not hit.Instance then
			return
		end
		local mid = hit.Instance:GetAttribute("HaulRubble")
		local m = mid and rubbleById[mid]
		if not m or m.broken then
			return
		end
		-- Ensure no solid wall or hill blocks the shot before reaching the rubble
		local excl: { Instance } = { encFolder }
		if ch then
			table.insert(excl, ch)
		end
		local ef = Workspace:FindFirstChild("Enemies")
		if ef then
			table.insert(excl, ef)
		end
		local blk = RaycastParams.new()
		blk.FilterType = Enum.RaycastFilterType.Exclude
		blk.FilterDescendantsInstances = excl
		blk.RespectCanCollide = true
		blk.IgnoreWater = true
		local dist = (hit.Position - origin).Magnitude
		local obs = Workspace:Raycast(origin, dir * math.max(dist - 0.5, 0.1), blk)
		if obs then
			return
		end

		local dmg = (w.damage or 25) * math.max(1, (w.pellets or 1) * 0.65)
		damageMound(m, dmg, hit.Position, p, false)
	end)

	-- ------------------------------------------------------------------ Public controller
	local mgr: any = {}

	function mgr.setupCache(cache: any)
		local kind = cache.encounter
		if kind == "courier" then
			setupCourier(cache)
		elseif kind == "cradle" then
			setupCradle(cache)
		elseif kind == "conveyor" then
			setupConveyor(cache)
		elseif kind == "guardian" then
			setupGuardian(cache)
		elseif kind == "buried" then
			setupBuried(cache)
		end
	end

	function mgr.onSiteActive(cache: any)
		local st = states[cache]
		if not st then
			return
		end
		if st.kind == "courier" then
			activateCourier(cache, st)
		elseif st.kind == "guardian" then
			activateGuardian(cache, st)
		end
	end

	function mgr.onCellLift(cache: any, cell: any, player: Player?)
		if cell and cell.onBelt then
			cell.onBelt = false
		end
		local st = states[cache]
		if not st then
			return
		end
		if st.kind == "guardian" then
			wakeGuardian(cache, st, player)
		end
	end

	function mgr.onExplosion(pos: Vector3, radius: number)
		if not alive then
			return
		end
		local r = (radius or 8) + 5.5
		local hitList: { any } = {}
		for _, m in rubbleById do
			if not m.broken and (m.pos - pos).Magnitude <= r then
				table.insert(hitList, m)
			end
		end
		for _, m in hitList do
			damageMound(m, 999, m.pos, nil, true)
		end
	end

	-- Used by DebugHook "solve" so locked cells can always be solved cleanly
	function mgr.forceUnlockCell(cell: any)
		if not cell or not cell.cache then
			return
		end
		local cache = cell.cache
		local st = states[cache]
		if not st then
			return
		end
		if st.kind == "courier" and st.cell == cell then
			releaseCourierCell(cache, st, cell.home.Position)
		elseif st.kind == "cradle" then
			st.done = true
			if st.prompt then
				st.prompt.Enabled = false
			end
			if st.bb and st.bb.Parent then
				st.bb:Destroy()
			end
			cell.state = "cache"
		elseif st.kind == "buried" then
			for _, m in st.mounds do
				if m.cell == cell and not m.broken then
					shatterMound(m, true)
				end
			end
		end
	end

	function mgr.step(dt: number)
		if not alive then
			return
		end
		for cache, st in states do
			if st.kind == "courier" then
				stepCourier(cache, st)
			elseif st.kind == "conveyor" then
				stepConveyor(cache, st, dt)
			elseif st.kind == "guardian" then
				stepGuardian(cache, st)
			end
		end
	end

	function mgr.stop()
		alive = false
		if fireConn then
			fireConn:Disconnect()
			fireConn = nil
		end
		for _, st in states do
			if st.enemy and st.enemy.alive and st.enemy.nextThink and st.enemy.nextThink > DORMANT_OFF / 2 then
				st.enemy.nextThink = Workspace:GetServerTimeNow()
			end
			if st.weld then
				st.weld:Destroy()
				st.weld = nil
			end
		end
		table.clear(rubbleById)
		table.clear(rubbleParts)
		table.clear(states)
	end

	return mgr
end

return HaulEncounters
