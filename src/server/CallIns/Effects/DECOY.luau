-- Holo Decoy: a flickering cyan hologram trooper stands on the beacon and taunts for `duration` s. Enemies within `radius` studs
-- treat it as `preference` x closer than any trooper (EnemyAI.pickTarget), so it pulls a swarm off a buddy or into a Gravity Well.
-- It soaks `hp` damage through Decoys.damage (melee, bolts, splash, beams), then bursts in a harmless shower of light.
-- The decoy is only an entry in server/Decoys.luau; the model here is cosmetic and never blocks shots (no collision, no query).
local Decoys = require(script.Parent.Parent.Parent.Decoys)

local CYAN = Color3.fromRGB(80, 235, 255)
local BASE_ALPHA = 0.45
local TICK = 0.1

local function part(model: Model, name: string, shape: Enum.PartType, size: Vector3, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.Material = Enum.Material.Neon
	p.Color = CYAN
	p.Transparency = BASE_ALPHA
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.CFrame = cf
	p.Parent = model
	return p
end

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local ground = ctx.groundAt(ctx.pos)
	local dir: Vector3 = ctx.dir or Vector3.zAxis
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local look = if flat.Magnitude > 0.05 then flat.Unit else Vector3.new(0, 0, -1)
	-- hips stand ~3 studs above the ground (R15 proportions); `base` has the model's feet on the ground, facing `look`
	local base = CFrame.lookAt(ground, ground + look)

	local model = Instance.new("Model")
	model.Name = "HoloDecoy"
	local cyl = Enum.PartType.Block -- (blocky R15-ish limbs)
	local torso = part(model, "Torso", cyl, Vector3.new(2, 2, 1), base * CFrame.new(0, 3.5, 0))
	local parts = {
		torso,
		part(model, "Head", Enum.PartType.Ball, Vector3.new(1.4, 1.4, 1.4), base * CFrame.new(0, 5.2, 0)),
		part(model, "ArmL", cyl, Vector3.new(1, 2, 1), base * CFrame.new(-1.5, 3.5, 0)),
		part(model, "ArmR", cyl, Vector3.new(1, 2, 1), base * CFrame.new(1.5, 5, 0) * CFrame.Angles(0, 0, math.rad(160))), -- taunting wave
		part(model, "LegL", cyl, Vector3.new(1, 2, 1), base * CFrame.new(-0.5, 1.5, 0)),
		part(model, "LegR", cyl, Vector3.new(1, 2, 1), base * CFrame.new(0.5, 1.5, 0)),
	}
	-- projector disc under the feet
	local disc = part(model, "Disc", Enum.PartType.Cylinder, Vector3.new(0.2, 4.5, 4.5), CFrame.new(ground + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.pi / 2))
	disc.Transparency = 0.6
	table.insert(parts, disc)
	local glow = Instance.new("PointLight")
	glow.Color = CYAN
	glow.Range = 14
	glow.Brightness = 1.5
	glow.Parent = torso
	model.PrimaryPart = torso
	model.Parent = ctx.folder

	local decoy = Decoys.add({
		part = torso,
		pos = ground + Vector3.new(0, 3, 0),
		hp = prm.hp,
		radius = prm.radius,
		preference = prm.preference,
	})

	local fxId = ctx.nextId()
	local burst = false
	local function finish()
		Decoys.remove(decoy)
		if model.Parent then
			model:Destroy()
		end
		if not burst then
			burst = true
			S.Fx.play("DecoyBurst", { id = fxId, p = ground + Vector3.new(0, 3, 0) })
		end
	end
	ctx.onStop(finish) -- also runs when the round ends and every effect is stopped

	S.Fx.play("DecoyPing", { id = fxId, p = ground, r = prm.radius, t = prm.duration })

	local startT = os.clock()
	while decoy.alive and decoy.hp > 0 and os.clock() - startT < prm.duration do
		-- gentle flicker; the hurt hologram glitches more
		local hurt = 1 - math.clamp(decoy.hp / decoy.maxHp, 0, 1)
		local left = prm.duration - (os.clock() - startT)
		local glitch = math.random() < 0.06 + hurt * 0.25 + (if left < 2 then 0.25 else 0)
		for _, p in parts do
			p.Transparency = if glitch then 0.8 + math.random() * 0.15 else BASE_ALPHA + math.random() * 0.12 + hurt * 0.15
		end
		glow.Brightness = if glitch then 0.3 else 1.5
		task.wait(TICK)
	end
	finish()
end
