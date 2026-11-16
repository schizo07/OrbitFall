--!nonstrict
-- Client side of the downed state (server/Downed.luau, rules shared/Downed.luau, tuning Config.Downed).
--   * DOWNED panel (centre, a little below the crosshair): title, bleed-out bar + seconds left (Player attribute
--     DownedEnd = server time the bleed-out finishes at the current rate)
--   * context prompt: "Press [F] to stim back up" while you have stims, else "No stims - crawl to a squadmate"
--   * your own body's revive prompt is hidden (only squadmates see "Revive")
--   Studio A/B: Variants group DOWNED (Feel_Downed, mirrored to the server by Variants)
-- Movement / gates live elsewhere: client/Movement (forced prone, crawl speed, no stance input), client/CellCarry
-- (fire / aim / grenade gates), WeaponController (sidearm only), CallInController (no dial).
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Rules = require(Shared.Downed)
local Store = require(script.Parent.Store)

local DownedFx = {}

local player = Players.LocalPlayer
local ui: any = nil
local Style: any = nil
local Theme: any = nil
local ContextPrompt: any = nil
local Audio: any = nil
local shownAt = 0
local fullSpan = 12 -- seconds the bar spans (first DownedEnd seen after going down)

local function build()
	local gui = Theme.gui("OrbitDowned", { DisplayOrder = 9 })
	local root = Theme.root(gui, "hud")
	local holder = Style.panel({
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 70),
		Size = UDim2.fromOffset(260, 58),
		BracketColor = Style.Red,
		Visible = false,
		Parent = root,
	})
	local title = Style.label({
		Name = "Title",
		Text = "Downed",
		TextSize = 24,
		Color = Style.Red,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = holder,
	})
	local sub = Style.label({
		Name = "Sub",
		Text = "",
		TextSize = 13,
		Color = Style.White,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = holder,
	})
	local bar = Style.bar({
		Name = "Bleed",
		Size = UDim2.new(1, -20, 0, 5),
		Position = UDim2.new(0, 10, 1, -10),
		Color = Style.Red,
		Parent = holder,
	})
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	ui = { gui = gui, holder = holder, title = title, sub = sub, bar = bar, scale = scale }
end

local function me(): any
	local m = Store.get("me")
	return if type(m) == "table" then m else nil
end

local function squadmatesUp(): number
	local n = 0
	for _, p in Players:GetPlayers() do
		local h = p ~= player and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 and not Rules.isDowned(p) then
			n += 1
		end
	end
	return n
end

local function hideOwnPrompt(pp: Instance)
	if pp:IsA("ProximityPrompt") and pp:GetAttribute("ReviveFor") == player.UserId then
		pp.Enabled = false
	end
end

local function onDownedChanged()
	local down = Rules.isDowned(player)
	if not ui then
		return
	end
	if down then
		shownAt = os.clock()
		local endAt = player:GetAttribute(Rules.END_ATTR)
		fullSpan = if type(endAt) == "number" then math.max(1, endAt - workspace:GetServerTimeNow()) else 12
		ui.holder.Visible = true
		ui.scale.Scale = 1.25
		Style.tween(ui.scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
		if Audio then
			Audio.play2D("UIError", { volume = 0.7 })
		end
		local c = player.Character
		local root = c and c:FindFirstChild("HumanoidRootPart")
		local pp = root and root:FindFirstChild(Rules.PROMPT)
		if pp then
			hideOwnPrompt(pp)
		end
	else
		ui.holder.Visible = false
		if ContextPrompt then
			ContextPrompt.hide("downed")
		end
	end
end

local function step()
	if not ui or not ui.holder.Visible then
		return
	end
	local endAt = player:GetAttribute(Rules.END_ATTR)
	local left = if type(endAt) == "number" then math.max(0, endAt - workspace:GetServerTimeNow()) else 0
	ui.bar.set(left / fullSpan)
	-- the title pulses faster as the bar runs out
	local rate = 2 + 6 * (1 - math.clamp(left / fullSpan, 0, 1))
	ui.title.TextTransparency = 0.25 * (0.5 + 0.5 * math.sin((os.clock() - shownAt) * rate * math.pi))
	local m = me()
	local stims = m and type(m.stims) == "number" and m.stims or 0
	local mates = squadmatesUp()
	local txt = string.format("Bleeding out  %ds", math.ceil(left))
	if mates > 0 then
		txt ..= "  -  squadmates can revive you"
	end
	ui.sub.Text = string.upper(txt)
	if ContextPrompt then
		if stims > 0 then
			ContextPrompt.show("downed", "Press {key} to stim back up", "Stim", nil, 8)
		elseif mates > 0 then
			ContextPrompt.show("downed", "No stims - crawl to a squadmate", "", nil, 8)
		else
			ContextPrompt.show("downed", "No stims left", "", nil, 8)
		end
	end
end

function DownedFx.init(audio: any?)
	Audio = audio
	local uiFolder = script.Parent:FindFirstChild("UI")
	local okS, S = pcall(require, uiFolder:FindFirstChild("HudStyle"))
	local okT, T = pcall(require, uiFolder:FindFirstChild("Theme"))
	local okC, C = pcall(require, uiFolder:FindFirstChild("ContextPrompt"))
	if okS and okT then
		Style, Theme = S, T
		build()
	end
	ContextPrompt = if okC then C else nil

	player:GetAttributeChangedSignal(Rules.ATTR):Connect(onDownedChanged)
	player:GetAttributeChangedSignal(Rules.END_ATTR):Connect(function()
		-- a hit shortened the bleed: keep the bar's span so the bar visibly drops
		if Rules.isDowned(player) and ui and not ui.holder.Visible then
			onDownedChanged()
		end
	end)
	-- only squadmates see the revive prompt on a downed body
	ProximityPromptService.PromptShown:Connect(function(pp)
		hideOwnPrompt(pp)
	end)
	local function watch(c: Model)
		c.DescendantAdded:Connect(hideOwnPrompt)
		if ui then
			onDownedChanged()
		end
	end
	if player.Character then
		watch(player.Character)
	end
	player.CharacterAdded:Connect(watch)
	RunService.RenderStepped:Connect(step)
	onDownedChanged()
end

return DownedFx
