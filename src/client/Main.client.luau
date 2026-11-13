-- Client bootstrap.
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local root = script.Parent
local player = Players.LocalPlayer

local function safeRequire(inst: Instance?): any
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if not ok then
		warn("[Client] failed to load", inst:GetFullName(), mod)
		return nil
	end
	return mod
end

local function safeCall(name: string, fn: any, ...)
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Client] init failed:", name, err)
	end
end

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

local Store = safeRequire(root.Store)
local Input = safeRequire(root.Input)
local Audio = safeRequire(root:FindFirstChild("Audio"))
local Juice = safeRequire(root:FindFirstChild("Juice"))
local Fx = safeRequire(root:FindFirstChild("Fx"))
local UI = root:FindFirstChild("UI")
local HUD = UI and safeRequire(UI:FindFirstChild("HUD"))
local Mobile = UI and safeRequire(UI:FindFirstChild("MobileControls"))
local Screens = UI and safeRequire(UI:FindFirstChild("Screens"))
local Dial = UI and safeRequire(UI:FindFirstChild("UplinkDial"))
local WarMap = UI and safeRequire(UI:FindFirstChild("WarMap"))
local Cam = safeRequire(root.CameraController)
local Weapon = safeRequire(root.WeaponController)
local CallIn = safeRequire(root.CallInController)

safeCall("Store", Store.init)
safeCall("Input", Input.init)
if Audio then
	safeCall("Audio", Audio.init)
end
if Fx then
	safeCall("Fx", Fx.init)
end
if HUD then
	safeCall("HUD", HUD.init)
end
if Mobile and Input.isTouch() then
	safeCall("MobileControls", Mobile.init)
end
if Screens then
	safeCall("Screens", Screens.init)
end
if WarMap then
	safeCall("WarMap", WarMap.init)
end
if Dial and Dial.init then
	safeCall("UplinkDial", Dial.init)
end
safeCall("Camera", Cam.init)
local MovementMod = safeRequire(root:FindFirstChild("Movement")) or {}
safeCall("Movement", MovementMod.init) -- stamina, stances, dive, mantle, knockdown
do -- two-handed weapon hold + aim pose for every armed character (client/CombatPose.luau)
	local Pose = safeRequire(root:FindFirstChild("CombatPose"))
	local fxFolder = root:FindFirstChild("Fx")
	local GunFeelMod = fxFolder and safeRequire(fxFolder:FindFirstChild("GunFeel"))
	if Pose then
		safeCall("CombatPose", Pose.init, GunFeelMod, MovementMod, fxFolder and safeRequire(fxFolder:FindFirstChild("ArmorFx")))
	end
end
if Weapon then
	Weapon.setHUD(HUD)
	safeCall("Weapon", Weapon.init)
end
if CallIn and Weapon then
	safeCall("CallIn", CallIn.init, Dial, Weapon.aimPoint)
end

-- Knockback / hurt feedback from the server
if Fx then
	Fx.register("Knock", function(d)
		local c = player.Character
		local rootPart = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		if rootPart and d.v then
			rootPart.AssemblyLinearVelocity += d.v
			if hum and d.v.Magnitude > 40 then
				hum:ChangeState(Enum.HumanoidStateType.FallingDown)
				task.delay(0.8, function()
					if hum.Parent then
						hum:ChangeState(Enum.HumanoidStateType.GettingUp)
					end
				end)
			end
		end
	end)
	Fx.register("Hurt", function(d)
		if Juice then
			Juice.vignette(Color3.fromRGB(255, 40, 40), math.clamp((d.amount or 10) / 60, 0.15, 0.6), 0.45)
			Juice.shake(math.clamp((d.amount or 10) / 40, 0.1, 0.8), 0.25)
		end
		if Audio then
			Audio.play2D("PlayerHurt")
		end
	end)
end

-- Beacons -> HUD compass / world markers
if Fx and HUD and HUD.addBeacon then
	Fx.register("Beacon", function(d)
		local CallIns = require(Shared.Data.CallIns)
		local def = d.callin and CallIns.get(d.callin)
		HUD.addBeacon(d.id, d.p, d.color, def and def.name or "Beacon")
	end)
	Fx.register("BeaconEnd", function(d)
		task.delay(1.5, HUD.removeBeacon, d.id)
	end)
end

-- Client-local toasts (e.g. "Throw the beacon")
if HUD and HUD.toast then
	Store.on("toast", function(t)
		if t then
			HUD.toast(t)
		end
	end)
end

-- Jump action for touch buttons
Input.on("Jump", function(d)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if d and hum then
		hum.Jump = true
	end
end)

-- Music by mission state
if Audio and Audio.setMusic then
	Store.on("mission", function(m)
		if not m then
			return
		end
		if m.state == "Ship" or m.state == "Countdown" then
			Audio.setMusic("Music_Ship")
		elseif m.state == "Active" or m.state == "Extract" then
			Audio.setMusic("Music_Combat")
		end
	end)
end

-- tell the server we're listening so it resends per-player state (me/profile/war)
Net.event("Action"):FireServer("clientReady")
print(("[%s] client ready"):format(Config.GameName))
