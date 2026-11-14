-- Squad call-in cards, mid-left: one card per trooper call-in (server Fx "CallInCard" via SquadComms).
--   CallInCards.show(userId, callinId, stage)   stage = "arm" | "throw"
--   CallInCards.clear()
-- Card: callsign tag in the trooper's colour, call-in name, arrow code, stage (ACTIVATING / INBOUND).
-- The same trooper + call-in refreshes its card instead of stacking a second one. Max 3 cards; each fades after
-- Feel_CallInCardLife seconds (Studio A/B, default 4). Feel_CallInCardOwn = false hides your own call-ins.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallIns = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local CallInCards = {}

local MAX = 3
local LIFE = 4
local FADE = 0.35
local W = 250
local H = 46
local ARROW = 11

local DIR_SHAPE = { U = "up", D = "down", L = "left", R = "right" }

local built = false
local holder: Frame
local cards: { any } = {} -- oldest first
local serial = 0

local function build()
	if built then
		return
	end
	built = true
	local touch = Theme.isTouch()
	local gui = Theme.gui("OrbitCallInCards", { DisplayOrder = 6 })
	local root = Theme.root(gui, "hud")
	local content = Style.content(root, touch)
	holder = Instance.new("Frame")
	holder.Name = "Cards"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(W, MAX * (H + 4))
	if touch then
		-- below the FEED button (y 50 % - 26) so the left column and the feed stay clear
		holder.AnchorPoint = Vector2.new(0, 0)
		holder.Position = UDim2.new(0, Style.MARGIN, 0.5, 6)
	else
		holder.AnchorPoint = Vector2.new(0, 0.5)
		holder.Position = UDim2.new(0, Style.MARGIN, 0.56, 0)
	end
	holder.Parent = content
	Theme.list(holder, Enum.FillDirection.Vertical, 4)
end

local function lifeTime(): number
	local v = workspace:GetAttribute("Feel_CallInCardLife")
	return if type(v) == "number" and v > 0 then v else LIFE
end

local function fadeOut(card: any)
	if card.dying then
		return
	end
	card.dying = true
	local f = card.frame
	Theme.tween(f, FADE, { BackgroundTransparency = 1 })
	for _, d in f:GetDescendants() do
		if d:IsA("TextLabel") then
			Theme.tween(d, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
		elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
			Theme.tween(d, FADE, { BackgroundTransparency = 1 })
		elseif d:IsA("UIStroke") then
			Theme.tween(d, FADE, { Transparency = 1 })
		end
	end
	task.delay(FADE + 0.05, function()
		local i = table.find(cards, card)
		if i then
			table.remove(cards, i)
		end
		f:Destroy()
	end)
end

local function arm(card: any)
	card.gen += 1
	local gen = card.gen
	task.delay(lifeTime(), function()
		if card.gen == gen then
			fadeOut(card)
		end
	end)
end

local function setStage(card: any, stage: string)
	card.stage.Text = if stage == "throw" then "INBOUND" else "ACTIVATING"
	card.stage.TextColor3 = if stage == "throw" then Style.White else Style.Amber
end

local function makeCard(userId: number, def: any): any
	serial += 1
	local cs = Style.callsign(userId)
	local beacon = if def.id == "REINFORCE" then Style.Green else Theme.beaconColor(def.beacon)
	local f = Style.panel({
		Name = "Card",
		Size = UDim2.fromOffset(W, H),
		LayoutOrder = serial,
		BracketColor = cs.color,
		Parent = holder,
	})
	-- colour strip in the trooper's callsign colour
	Style.rect({ Color = cs.color, Size = UDim2.new(0, 4, 1, 0), Parent = f })
	Style.label({
		Text = cs.tag,
		TextSize = 18,
		Color = cs.color,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(0, 34, 1, 0),
		Parent = f,
	})
	Style.label({
		Text = def.name,
		TextSize = 15,
		Color = Style.White,
		Position = UDim2.fromOffset(44, 3),
		Size = UDim2.new(1, -130, 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = f,
	})
	local stage = Style.label({
		Text = "",
		TextSize = 13,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 4),
		Size = UDim2.fromOffset(84, 18),
		Parent = f,
	})
	local arrows = Instance.new("Frame")
	arrows.BackgroundTransparency = 1
	arrows.Position = UDim2.fromOffset(44, 25)
	arrows.Size = UDim2.new(1, -50, 0, ARROW + 4)
	arrows.Parent = f
	Theme.list(arrows, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	for i, d in CallIns.codeOf(def) do
		Style.glyph(DIR_SHAPE[d] or "dot", { Size = ARROW, Color = beacon, LayoutOrder = i, Parent = arrows })
	end
	return { frame = f, stage = stage, key = tostring(userId) .. ":" .. def.id, gen = 0, dying = false }
end

function CallInCards.show(userId: number, callinId: string, stage: string)
	local def = CallIns.get(callinId)
	if not def then
		return
	end
	if userId == Players.LocalPlayer.UserId and workspace:GetAttribute("Feel_CallInCardOwn") == false then
		return
	end
	build()
	local key = tostring(userId) .. ":" .. callinId
	for _, c in cards do
		if c.key == key and not c.dying then
			setStage(c, stage)
			arm(c)
			return
		end
	end
	-- keep at most MAX: drop the oldest live card
	local live = 0
	for _, c in cards do
		if not c.dying then
			live += 1
		end
	end
	if live >= MAX then
		for _, c in cards do
			if not c.dying then
				fadeOut(c)
				break
			end
		end
	end
	local card = makeCard(userId, def)
	setStage(card, stage)
	table.insert(cards, card)
	-- small pop-in
	local s = Instance.new("UIScale")
	s.Scale = 0.85
	s.Parent = card.frame
	Theme.tween(s, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
	arm(card)
end

function CallInCards.clear()
	for _, c in cards do
		c.gen += 1
		c.frame:Destroy()
	end
	table.clear(cards)
end

return CallInCards
