-- Squad call-in cards, mid-left perimeter: compact ephemeral card per trooper call-in (server Fx "CallInCard").
--   CallInCards.show(userId, callinId, stage)   stage = "arm" | "throw"
--   CallInCards.clear()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallIns = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local InfoLayer = require(script.Parent.InfoLayer)

local CallInCards = {}

local MAX = 3
local LIFE = 4
local FADE = 0.35
local W = 260
local H = 38

local DIR_SHAPE = { U = "up", D = "down", L = "left", R = "right" }

local built = false
local holder: Frame
local cards: { any } = {}
local serial = 0

local function build()
	if built then
		return
	end
	built = true
	local touch = Theme.isTouch()
	local g = Theme.gui("OrbitCallInCards", { DisplayOrder = 6, Insets = "CoreUISafeInsets" })
	local r = Theme.root(g, "hud")
	local E = InfoLayer.entry("callinCards", touch)
	holder = Instance.new("Frame")
	holder.Name = "Cards"
	holder.BackgroundTransparency = 1
	InfoLayer.place(holder, "callinCards", touch)
	holder.Parent = r
	Theme.list(holder, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom)
	W = holder.Size.X.Offset
	H = E.CardHeight or H
	MAX = E.Max or MAX
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
	card.stage.Text = InfoLayer.caseText(if stage == "throw" then "INBOUND" else "PRIMED")
	card.stage.TextColor3 = if stage == "throw" then InfoLayer.col("text") else InfoLayer.col("own")
end

local function makeCard(userId: number, def: any): any
	serial += 1
	local cs = Style.callsign(userId)
	local beacon = if def.id == "REINFORCE" then InfoLayer.col("heal") else Theme.beaconColor(def.beacon)
	local f = Instance.new("Frame")
	f.Name = "Card"
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(W, H)
	f.LayoutOrder = serial
	f.Parent = holder
	InfoLayer.backing(f, "plate")
	Style.rect({ Color = cs.color, Size = UDim2.new(0, 2, 1, 0), Parent = f })
	local ts = math.max(12, math.floor(H * 0.38))
	InfoLayer.label({
		Text = cs.tag,
		Role = "number",
		TextSize = ts,
		Color = cs.color,
		XAlign = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(0, ts * 2, 1, 0),
		Parent = f,
	})
	local x = 6 + ts * 2
	InfoLayer.label({
		Text = def.name,
		TextSize = ts,
		ColorRole = "text",
		Position = UDim2.fromOffset(x, 2),
		Size = UDim2.new(1, -x - 76, 0.56, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = f,
	})
	local stage = InfoLayer.label({
		Text = "",
		TextSize = math.max(11, ts - 1),
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 2),
		Size = UDim2.new(0, 70, 0.56, 0),
		Parent = f,
	})
	local arrows = Instance.new("Frame")
	arrows.BackgroundTransparency = 1
	arrows.Position = UDim2.new(0, x, 0.58, 0)
	arrows.Size = UDim2.new(1, -x - 6, 0.4, -2)
	arrows.Parent = f
	Theme.list(arrows, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local a = math.max(6, math.floor(H * 0.22))
	for i, d in CallIns.codeOf(def) do
		Style.glyph(DIR_SHAPE[d] or "dot", { Size = a, Color = beacon, LayoutOrder = i, Parent = arrows })
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
	local s = Instance.new("UIScale")
	s.Scale = 0.88
	s.Parent = card.frame
	Theme.tween(s, 0.14, { Scale = 1 }, Enum.EasingStyle.Back)
	arm(card)
end

function CallInCards.clear()
	for _, c in cards do
		c.gen += 1
		c.frame:Destroy()
	end
	table.clear(cards)
end

InfoLayer.onRebuild(function()
	CallInCards.clear()
	built = false
end)

return CallInCards
