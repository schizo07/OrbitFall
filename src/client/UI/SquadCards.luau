-- Left-edge squad cards (y 58 % .. 78 % of the screen): one compact flat card per OTHER squad member.
--   card = callsign tag, primary weapon name (falls back to the display name), call-in icons, 3 px health bar.
--   dead = grey tag, red "REINFORCE AVAILABLE" (or the cooldown / "NO REINFORCEMENTS" / respawn countdown).
-- Data: Store "squad" entries { userId, name, hp, maxHp, alive } (PlayerService.squadState). Optional, shown as soon as the
-- server publishes them: m.weapon (weapon id), m.callins (array of call-in ids), m.respawnAt (server time).
-- Reinforce state reads me.alive / me.reinforceReadyAt and mission.lives (HUD forwards them via update()).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Data"):WaitForChild("Weapons"))
local CallIns = require(Shared:WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local SquadCards = {}

local ui: { [string]: any } = {}
local cards: { [number]: any } = {}
local touch = false
local want = false
local lastMe: any = nil
local lastMission: any = nil

local MAX_ICONS = 4

local function cardWidth(): number
	return if touch then 140 else 200
end

local function cardHeight(): number
	return if touch then 30 else 40
end

local function weaponName(m: any): string
	if type(m.weapon) == "string" then
		local def = Weapons.get(m.weapon)
		return string.upper(def and def.name or m.weapon)
	end
	return string.upper(m.name or "?")
end

local function makeCard(m: any, order: number): any
	local w, h = cardWidth(), cardHeight()
	local f = Style.panel({
		Name = "Card" .. tostring(m.userId),
		Size = UDim2.fromOffset(w, h),
		LayoutOrder = order,
		Parent = ui.holder,
	})
	local tag = Style.label({
		Text = "",
		Size = UDim2.fromOffset(24, 16),
		Position = UDim2.fromOffset(6, if touch then 2 else 4),
		Parent = f,
	})
	local nameW = if touch then w - 36 else w - 36 - MAX_ICONS * 16
	local name = Style.label({
		Text = "",
		Size = UDim2.fromOffset(nameW, 16),
		Position = UDim2.fromOffset(30, if touch then 2 else 4),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = f,
	})
	local icons = Instance.new("Frame")
	icons.Name = "Icons"
	icons.BackgroundTransparency = 1
	icons.AnchorPoint = Vector2.new(1, 0)
	icons.Position = UDim2.new(1, -6, 0, 4)
	icons.Size = UDim2.fromOffset(MAX_ICONS * 16, 16)
	icons.Visible = not touch
	icons.Parent = f
	Theme.list(icons, Enum.FillDirection.Horizontal, 0, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local status = Style.label({
		Text = "",
		TextSize = 12,
		Color = Style.Red,
		Size = UDim2.new(1, -12, 0, 14),
		Position = UDim2.fromOffset(6, if touch then 12 else 18),
		Visible = false,
		Parent = f,
	})
	local bar = Style.bar({
		Size = UDim2.new(1, -12, 0, 3),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 6, 1, -4),
		Parent = f,
	})
	return { frame = f, tag = tag, name = name, icons = icons, status = status, bar = bar, iconKey = "", alive = nil, m = m }
end

local function setIcons(c: any, ids: any)
	local key = if type(ids) == "table" then table.concat(ids, ",") else ""
	if key == c.iconKey then
		return
	end
	c.iconKey = key
	for _, k in c.icons:GetChildren() do
		if k:IsA("GuiObject") then
			k:Destroy()
		end
	end
	if type(ids) ~= "table" then
		return
	end
	for i, id in ids do
		if i > MAX_ICONS then
			break
		end
		local def = CallIns.get(id)
		if def then
			-- category shape in the beacon colour (the data icons are dingbats the HUD font lacks)
			Style.glyph(Style.callinShape(def), {
				Size = 10,
				Color = Theme.beaconColor(def.beacon),
				Box = UDim2.fromOffset(16, 16),
				LayoutOrder = i,
				Parent = c.icons,
			})
		end
	end
end

-- text + colour for a fallen squadmate's card
local function deadStatus(m: any, t: number): (string, Color3)
	if type(m.respawnAt) == "number" and m.respawnAt > t then
		return string.format("RESPAWN %ds", math.ceil(m.respawnAt - t)), Style.Amber
	end
	local me = lastMe
	local lives = lastMission and lastMission.lives
	if type(lives) == "number" and lives <= 0 then
		return "NO REINFORCEMENTS", Style.Grey
	end
	if me and me.alive == false then
		return "DOWN", Style.Red
	end
	local ready = me and me.reinforceReadyAt or 0
	if ready > t then
		return string.format("REINFORCE %ds", math.ceil(ready - t)), Style.Red
	end
	return "REINFORCE AVAILABLE", Style.Red
end

local function refreshCard(c: any, m: any, t: number)
	c.m = m
	local cs = Style.callsign(m.userId)
	local alive = m.alive ~= false
	c.tag.Text = cs.tag
	c.tag.TextColor3 = if alive then cs.color else Style.Grey
	c.name.Text = weaponName(m)
	c.name.TextColor3 = if alive then Style.White else Style.Grey
	c.name.Visible = alive or not touch -- phones: the state text takes the weapon line
	setIcons(c, m.callins)
	c.icons.Visible = not touch and alive
	local frac = if (m.maxHp or 0) > 0 then Theme.clamp((m.hp or 0) / m.maxHp, 0, 1) else 0
	if alive then
		c.bar.set(frac, if frac > 0.35 then Style.White else Style.Red)
		c.status.Visible = false
	else
		local text, col = deadStatus(m, t)
		c.bar.set(1, Style.Red)
		c.bar.fill.BackgroundTransparency = 0.6
		c.status.Visible = true
		c.status.Text = text
		c.status.TextColor3 = col
		-- slow pulse while the reinforce is actually callable
		c.status.TextTransparency = if text == "REINFORCE AVAILABLE" then 0.15 + 0.3 * math.abs(math.sin(t * 3)) else 0
	end
	if alive and c.alive == false then
		c.bar.fill.BackgroundTransparency = 0
	end
	c.alive = alive
end

local function relayout()
	if not ui.holder then
		return
	end
	local n = 0
	for _ in cards do
		n += 1
	end
	ui.holder.Visible = want and n > 0
end

function SquadCards.build(parent: Instance, isTouch: boolean)
	touch = isTouch
	local holder = Instance.new("Frame")
	holder.Name = "SquadCards"
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.new(0, Style.MARGIN, 0.58, 0)
	holder.Size = UDim2.fromOffset(cardWidth(), 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	holder.Parent = parent
	Theme.list(holder, Enum.FillDirection.Vertical, if touch then 3 else 4)
	ui.holder = holder
end

function SquadCards.setVisible(on: boolean)
	want = on
	relayout()
end

-- squad = Store "squad"; me = Store "me"; mission = Store "mission"; t = workspace:GetServerTimeNow()
function SquadCards.update(squad: any, me: any, mission: any, userId: number, t: number)
	if not ui.holder then
		return
	end
	lastMe, lastMission = me, mission
	local seen: { [number]: boolean } = {}
	local order = 0
	if type(squad) == "table" then
		for _, m in squad do
			if type(m) ~= "table" or type(m.userId) ~= "number" or m.userId == userId then
				continue
			end
			seen[m.userId] = true
			order += 1
			local c = cards[m.userId]
			if not c then
				c = makeCard(m, order)
				cards[m.userId] = c
			end
			c.frame.LayoutOrder = Style.callsign(m.userId).index
			refreshCard(c, m, t)
		end
	end
	for id, c in cards do
		if not seen[id] then
			c.frame:Destroy()
			cards[id] = nil
		end
	end
	relayout()
end

-- 10 Hz: countdown text / pulse of the dead cards
function SquadCards.tick(me: any, mission: any, t: number)
	if not ui.holder or not ui.holder.Visible then
		return
	end
	lastMe, lastMission = me, mission
	for _, c in cards do
		if c.alive == false then
			refreshCard(c, c.m, t)
		end
	end
end

return SquadCards
