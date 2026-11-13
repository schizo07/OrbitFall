-- Main objective "Uplink Relay": find the relay -> plug in the cable (hold 3 s) -> defend a 120 s upload
-- (pauses when nobody is within 15 studs) -> retrieve the data core (pickup prompt).
-- Receives `ctx` from ObjectiveService; returns a controller { entry, stop }.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local SetPieces = require(script.Parent.SetPieces)

local UplinkRelay = {}

local STEP_TEXTS = {
	"Find the uplink relay",
	"Plug in the uplink cable",
	"Defend the data upload",
	"Retrieve the data core",
}

local UPLOAD_TIME = 120
local DARK = Color3.fromRGB(44, 48, 58)
local STEEL = Color3.fromRGB(120, 126, 138)
local CYAN = Color3.fromRGB(110, 225, 255)

function UplinkRelay.start(ctx: any, onComplete: () -> ()): any
	local map = ctx.map
	local root = Instance.new("Folder")
	root.Name = "Uplink"
	root.Parent = ctx.folder
	local entry = ctx.newEntry({ id = "UPLINK", title = "Uplink Relay", main = true, steps = STEP_TEXTS })
	local ctl: any = { entry = entry }
	local step = 1
	local alive = true

	local relayCF: CFrame = map.sites.uplink
	local vaultCF: CFrame = map.sites.generator
	local prompts: { [number]: { ProximityPrompt } } = {}

	local function refresh()
		for i, list in prompts do
			for _, pp in list do
				if pp.Parent then
					pp.Enabled = (i == step) and not pp:GetAttribute("Locked")
				end
			end
		end
	end

	local function setMarker()
		local pos
		if step <= 3 then
			pos = relayCF.Position
		elseif step == 4 then
			pos = vaultCF.Position
		end
		ctx.setMarker(entry, pos)
	end

	local function finishStep(i: number, text: string?)
		ctx.completeStep(entry, i, text)
		step = i + 1
		setMarker()
		refresh()
	end

	-- ============================================================ relay structure
	local beam: BasePart
	local dishGlow: any -- Part (primitive relay) or PointLight (mesh dish): only `.Color` is used
	local cable: BasePart
	local socketPart: BasePart
	local dishPart: BasePart? = nil -- mesh dish: aims/rotates during the upload
	local dishSpin = 0 -- rad/s
	local function buildPrimitiveRelay()
		local f = Instance.new("Model")
		f.Name = "Relay"
		f.Parent = root
		local b = relayCF
		ctx.cyl(f, 8, 4, b * CFrame.new(0, 2, 0), DARK, Enum.Material.Metal)
		ctx.cyl(f, 1.6, 18, b * CFrame.new(0, 13, 0), STEEL, Enum.Material.Metal)
		for k = 0, 2 do
			local a = k * math.rad(120)
			ctx.part(f, Vector3.new(0.7, 12, 0.7), b * CFrame.Angles(0, a, 0) * CFrame.new(0, 8, 3.2) * CFrame.Angles(math.rad(-14), 0, 0), STEEL, Enum.Material.Metal, { CanCollide = false })
		end
		-- dish
		local dishCF = b * CFrame.new(0, 24, 0) * CFrame.Angles(math.rad(-38), 0, 0)
		local dish = ctx.cyl(f, 17, 1.2, dishCF, Color3.fromRGB(200, 204, 212), Enum.Material.Metal, { CanCollide = false })
		dish.Name = "Dish"
		ctx.cyl(f, 7, 1.6, dishCF * CFrame.new(0, 0.9, 0), DARK, Enum.Material.Metal, { CanCollide = false })
		ctx.part(f, Vector3.new(0.5, 9, 0.5), dishCF * CFrame.new(0, 5.2, 0), STEEL, Enum.Material.Metal, { CanCollide = false })
		dishGlow = ctx.glow(f, Vector3.new(1.4, 1.4, 1.4), dishCF * CFrame.new(0, 9.8, 0), Color3.fromRGB(255, 80, 60))
		dishGlow.Shape = Enum.PartType.Ball
		ctx.light(dishGlow, Color3.fromRGB(255, 90, 60), 26, 1.4)
		-- status ring
		ctx.cyl(f, 8.4, 0.5, b * CFrame.new(0, 4.2, 0), CYAN, Enum.Material.Neon, { CanCollide = false, Transparency = 0.2 })
		-- socket + cable reel
		local socket = ctx.part(f, Vector3.new(2.6, 2.6, 1.6), b * CFrame.new(0, 1.7, -4.4), DARK, Enum.Material.Metal, { Name = "Socket" })
		ctx.glow(f, Vector3.new(1.6, 0.4, 0.3), b * CFrame.new(0, 2.6, -5.25), Config.Colors.Accent)
		local reelCF = b * CFrame.new(-8, 0, -15)
		ctx.part(f, Vector3.new(5, 3, 4), reelCF * CFrame.new(0, 1.5, 0), Color3.fromRGB(96, 104, 90), Enum.Material.Metal)
		ctx.cyl(f, 4.4, 3, reelCF * CFrame.new(0, 4, 0) * CFrame.Angles(math.rad(90), 0, 0), Color3.fromRGB(30, 30, 36), Enum.Material.Plastic)
		-- the cable (revealed when plugged): from the reel to the socket
		local a = reelCF.Position + Vector3.new(0, 1.2, 0)
		local c = (b * CFrame.new(0, 1.2, -5.2)).Position
		cable = ctx.glow(f, Vector3.new(0.5, 0.5, (c - a).Magnitude), CFrame.lookAt((a + c) / 2, c), CYAN, { Transparency = 1 })
		-- beam to the sky (upload visual)
		beam = ctx.glow(f, Vector3.new(2.4, 700, 2.4), CFrame.new(dishCF.Position + Vector3.new(0, 350, 0)), CYAN, { Transparency = 1 })

		socketPart = socket
	end
	do
		local relay = SetPieces.spawn(ctx.S, "uplink_dish", SetPieces.groundCF(map, relayCF, 4), root, { name = "Relay" })
		if relay and relay.parts.Terminal and relay.parts.Dish then
			socketPart = relay.parts.Terminal
			dishPart = relay.parts.Dish
			local dishPos = SetPieces.pivot(relay, "Dish")
			local light = ctx.light(dishPart, Color3.fromRGB(255, 90, 60), 26, 1.4)
			dishGlow = light
			-- cable from the ground (where the reel used to be) to the terminal; revealed when plugged in
			local a = (relay.cf * CFrame.new(-9, 0.4, -14)).Position
			local c = socketPart.Position
			cable = ctx.glow(relay.model, Vector3.new(0.5, 0.5, (c - a).Magnitude), CFrame.lookAt((a + c) / 2, c), CYAN, { Transparency = 1 })
			-- beam to the sky (upload visual)
			beam = ctx.glow(relay.model, Vector3.new(2.4, 700, 2.4), CFrame.new(dishPos + Vector3.new(0, 350, 0)), CYAN, { Transparency = 1 })
			local restCF = dishPart.CFrame
			local yaw = 0
			task.spawn(function()
				while alive and ctx.alive() and dishPart and dishPart.Parent do
					task.wait(0.05)
					if dishSpin > 0 then
						yaw = (yaw + dishSpin * 0.05) % (math.pi * 2)
						dishPart.CFrame = SetPieces.swing(relay, "Dish", CFrame.Angles(0, yaw, 0), restCF)
					end
				end
			end)
		else
			buildPrimitiveRelay()
		end
		prompts[2] = {
			ctx.prompt(socketPart, {
				action = "Plug In Cable",
				object = "Uplink Relay",
				hold = 3,
				distance = 11,
				onTrigger = function()
					if step ~= 2 then
						return
					end
					for _, p in prompts[2] do
						p:SetAttribute("Locked", true)
					end
					cable.Transparency = 0.1
					dishGlow.Color = Color3.fromRGB(255, 200, 70)
					dishSpin = 0.35
					finishStep(2, "Uplink connected. Defend the upload!")
					ctx.sound("Generator", relayCF.Position)
					local st = entry.steps[3]
					ctx.defend({
						center = relayCF.Position,
						radius = 15,
						duration = if workspace:GetAttribute("DebugFast") then 5 else UPLOAD_TIME,
						wavePeriod = 14,
						waveBudget = 9,
						onTick = function(p: number, paused: boolean)
							st.progress = p
							st.text = if paused then "Return to the relay! (upload paused)" else string.format("Defend the data upload (%d%%)", math.floor(p * 100))
							beam.Transparency = if paused then 0.92 else 0.55 - p * 0.25
							dishSpin = if paused then 0.05 else 0.35 + p * 0.9
							dishGlow.Color = if paused then Color3.fromRGB(255, 80, 60) else Color3.fromRGB(255, 200 + math.floor(p * 50), 70)
							ctx.changed()
						end,
						onDone = function()
							st.progress = nil
							st.text = "Defend the data upload"
							beam.Transparency = 0.3
							dishSpin = 0
							dishGlow.Color = Color3.fromRGB(255, 225, 190) -- done: warm white (green lit the sand)
							ctx.sound("ObjectiveDone", relayCF.Position)
							finishStep(3, "Upload complete! A data core was ejected - retrieve it.")
							ctl.spawnCore()
						end,
					})
				end,
			}),
		}
	end

	-- step 1: just reach the relay
	task.spawn(function()
		while alive and ctx.alive() and step == 1 do
			if #ctx.playersNear(relayCF.Position, 35) > 0 then
				finishStep(1, "Relay located. Plug in the uplink cable.")
				break
			end
			task.wait(0.4)
		end
	end)

	-- ============================================================ data core vault
	function ctl.spawnCore()
		local f = Instance.new("Model")
		f.Name = "DataCoreVault"
		f.Parent = root
		local b = vaultCF
		ctx.cyl(f, 7, 2.4, b * CFrame.new(0, 1.2, 0), DARK, Enum.Material.Metal)
		ctx.cyl(f, 6, 0.4, b * CFrame.new(0, 2.5, 0), CYAN, Enum.Material.Neon, { Transparency = 0.3, CanCollide = false })
		for k = 0, 2 do
			local a = k * math.rad(120)
			ctx.part(f, Vector3.new(1.2, 9, 1.2), b * CFrame.Angles(0, a, 0) * CFrame.new(0, 4.5, 6), STEEL, Enum.Material.Metal)
		end
		local core = ctx.glow(f, Vector3.new(2.6, 2.6, 2.6), b * CFrame.new(0, 5.2, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45)), CYAN, { Name = "DataCore", CanCollide = true, CanQuery = true })
		ctx.light(core, Color3.fromRGB(255, 225, 190), 14, 1) -- warm: a cyan light washed the ground teal
		local hl = Instance.new("Highlight")
		hl.FillTransparency = 1
		hl.OutlineColor = CYAN
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = core
		prompts[4] = {
			ctx.prompt(core, {
				action = "Take",
				object = "Data Core",
				hold = 1.5,
				distance = 11,
				onTrigger = function()
					if step ~= 4 then
						return
					end
					core:Destroy()
					finishStep(4, "Data core secured!")
					onComplete()
				end,
			}),
		}
		refresh()
		-- ambush when players approach the vault
		task.spawn(function()
			while alive and ctx.alive() and step == 4 do
				if #ctx.playersNear(vaultCF.Position, 55) > 0 then
					ctx.notify("Hostiles are guarding the data core!", Config.Colors.Danger)
					ctx.wave(vaultCF.Position, 12)
					break
				end
				task.wait(0.5)
			end
		end)
	end

	refresh()
	setMarker()
	ctx.changed(true)

	function ctl.stop()
		alive = false
	end

	return ctl
end

return UplinkRelay
