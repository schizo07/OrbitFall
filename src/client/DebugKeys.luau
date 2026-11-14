-- STUDIO-ONLY test keys + a tiny key-help label (docs/RESET-brief.md stage 1/2). Main.client requires this only when
-- RunService:IsStudio(); the server honours the DevSpawn remote only in Studio too (server/DevTools.luau).
-- Keys (none clash with Input.luau: R G Q E LShift 1 2 3 Tab C LCtrl Z Space; WASD is Roblox's own):
--   4 Tinker Drone      5 Skitterling       6 Tinker swarm x6    7 Skitter swarm x6
--   8 Rivet (COG medium)  9 Spitter (Brood medium)  0 clear enemies
--   -  god mode toggle  =  Director auto pacing toggle   T force breach (starts the Director)
--   Y  refill ammo + reset call-in cooldowns             V switch faction (what the Director spawns)
--   H  hide / show this label
-- The label shows only while workspace attribute TestArena is true (set by server/World/TestArena.luau). The spawn / god / refill
-- keys also work during a normal Studio mission (the server needs a built map); director / breach / faction are arena-only.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local DebugKeys = {}

local KEYMAP: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.Four] = "tinker",
	[Enum.KeyCode.Five] = "skitter",
	[Enum.KeyCode.Six] = "tinkerswarm",
	[Enum.KeyCode.Seven] = "skitterswarm",
	[Enum.KeyCode.Eight] = "rivet",
	[Enum.KeyCode.Nine] = "spitter",
	[Enum.KeyCode.Zero] = "clear",
	[Enum.KeyCode.Minus] = "god",
	[Enum.KeyCode.Equals] = "director",
	[Enum.KeyCode.T] = "breach",
	[Enum.KeyCode.Y] = "refill",
	[Enum.KeyCode.V] = "faction",
}

local function onOff(v: any): string
	return if v == true then "ON" else "OFF"
end

local function helpText(): string
	local fac = workspace:GetAttribute("ArenaFaction")
	return table.concat({
		"TEST ARENA   [H] hide",
		"4 Tinker Drone   5 Skitterling",
		"6 Tinker x6      7 Skitter x6",
		"8 Rivet (med)    9 Spitter (med)",
		"0 Clear enemies",
		"- God mode: " .. onOff(workspace:GetAttribute("ArenaGod")),
		"= Auto pacing: " .. onOff(workspace:GetAttribute("ArenaDirector")),
		"T Force breach",
		"Y Refill + call-in reset",
		"V Faction: " .. (if type(fac) == "string" then fac else "COG"),
	}, "\n")
end

function DebugKeys.init()
	if not RunService:IsStudio() then
		return
	end
	local player = Players.LocalPlayer
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local ev = remotes and remotes:WaitForChild("DevSpawn", 10)
	if not ev then
		warn("[DebugKeys] DevSpawn remote not found (server DevTools failed to load?)")
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "DebugKeys"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 60
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	local label = Instance.new("TextLabel")
	label.Name = "Help"
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.Position = UDim2.new(1, -8, 0.5, 0)
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.55
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(245, 185, 58)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = helpText()
	label.Visible = false
	label.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 4), UDim.new(0, 4)
	pad.Parent = label

	local hidden = false
	local function refresh()
		local inArena = workspace:GetAttribute("TestArena") == true
		label.Visible = inArena and not hidden
		if inArena then
			label.Text = helpText()
		end
	end
	for _, attr in { "TestArena", "ArenaGod", "ArenaDirector", "ArenaFaction" } do
		workspace:GetAttributeChangedSignal(attr):Connect(refresh)
	end
	refresh()

	UserInputService.InputBegan:Connect(function(io, gp)
		if gp or UserInputService:GetFocusedTextBox() then
			return
		end
		if io.KeyCode == Enum.KeyCode.H then
			hidden = not hidden
			refresh()
			return
		end
		local op = KEYMAP[io.KeyCode]
		if op then
			ev:FireServer(op)
		end
	end)
end

return DebugKeys
