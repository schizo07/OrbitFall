-- Left-edge squad cards, stacked upward from just above the own card: one compact flat card per OTHER squad member.
--   card = callsign tag, primary weapon name (falls back to the display name), call-in icons, 3 px health bar.
--   dead = grey tag, red "REINFORCE AVAILABLE" (or the cooldown / "NO REINFORCEMENTS" / respawn countdown).
-- Data: Store "squad" entries { userId, name, hp, maxHp, alive } (PlayerService.squadState). Optional, shown as soon as the
-- server publishes them: m.weapon (weapon id), m.callins (array of call-in ids), m.respawnAt (server time).
-- Reinforce state reads me.alive / me.reinforceReadyAt and mission.lives (HUD forwards them via update()).
-- Join state (Player attribute `Deploy`, server/Mission.luau): "loadout" -> IN LOADOUT, "dropping" -> DROPPING IN,
-- then the normal card (health bar, or DOWN + the reinforce line when dead).
-- Haul objective: a CELL chip (cyan) replaces the call-in icons while that member carries a core cell (attribute CarryCell).
local Players = game:GetService("Players")
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
local lastT = 0

local MAX_ICONS = 4
local CELL = Color3.fromRGB(110, 225, 255) -- shared/Carry.luau COLOR

local function cardWidth(): number
	return if touch then 140 else 200
end

-- Phones with a full squad: when the stack would run up into the objective list the cards go compact (22 px, one text row;
-- the state text replaces the weapon name). HUD tells us how much room there is via setRoom().
local TOUCH_H, TOUCH_COMPACT_H = 30, 22
local compact = false
local roomA, roomB, xB = math.huge, 0, 0

local function cardHeight(): number
	if touch then
		return if compact then TOUCH_COMPACT_H else TOUCH_H
	end
	return 40
end

local function applyGeometry(c: any)
	c.frame.Size = UDim2.fromOffset(cardWidth(), cardHeight())
	if not touch then
		return
	end
	local y = 2
	c.tag.Position = UDim2.fromOffset(6, y)
	c.name.Position = UDim2.fromOffset(30, y)
	c.cell.Position = UDim2.new(1, -6, 0, y)
	-- the state text shares the tag's row (it used to sit under the tag and clip it), so it starts right of the callsign tag
	c.status.Position = UDim2.fromOffset(30, y)
	c.status.Size = UDim2.new(1, -36, 0, 14)
	c.status.TextTruncate = Enum.TextTruncate.AtEnd
	c.bar.back.Size = UDim2.new(1, -12, 0, if compact then 2 else 3)
	c.bar.back.Position = UDim2.new(0, 6, 1, if compact then -1 else -4)
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
	-- carried core cell chip (haul objective)
	local cell = Instance.new("Frame")
	cell.Name = "CellChip"
	cell.BackgroundTransparency = 1
	cell.AnchorPoint = Vector2.new(1, 0)
	cell.Position = UDim2.new(1, -6, 0, if touch then 2 else 4)
	cell.Size = UDim2.fromOffset(44, 16)
	cell.Visible = false
	cell.Parent = f
	local gem = Instance.new("Frame")
	gem.AnchorPoint = Vector2.new(0.5, 0.5)
	gem.Position = UDim2.fromOffset(7, 8)
	gem.Size = UDim2.fromOffset(8, 8)
	gem.Rotation = 45
	gem.BackgroundColor3 = CELL
	gem.BorderSizePixel = 0
	gem.Parent = cell
	Style.label({
		Text = "CELL",
		TextSize = 12,
		Color = CELL,
		Size = UDim2.new(1, -15, 1, 0),
		Position = UDim2.fromOffset(15, 0),
		Parent = cell,
	})
	local c = { frame = f, tag = tag, name = name, nameW = nameW, icons = icons, status = status, bar = bar, cell = cell, iconKey = "", alive = nil, m = m }
	applyGeometry(c)
	return c
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
	local plr = Players:GetPlayerByUserId(m.userId)
	local deploy = plr and plr:GetAttribute("Deploy")
	local carrying = plr ~= nil and plr:GetAttribute("CarryCell") == true
	local alive = m.alive ~= false and deploy ~= "loadout"
	c.tag.Text = cs.tag
	c.tag.TextColor3 = if alive then cs.color else Style.Grey
	c.name.Text = if deploy == "loadout" then Style.up(m.name or "?") elseif alive then weaponName(m) else "DOWN"
	c.name.TextColor3 = if alive then Style.White elseif deploy == "loadout" then Style.Grey else Style.Red
	c.name.Visible = alive or not touch -- phones: the state text takes the weapon line
	setIcons(c, m.callins)
	c.cell.Visible = carrying and alive
	c.icons.Visible = not touch and alive and not carrying
	c.name.Size = UDim2.fromOffset(if c.cell.Visible and touch then c.nameW - 46 else c.nameW, 16)
	local frac = if (m.maxHp or 0) > 0 then Theme.clamp((m.hp or 0) / m.maxHp, 0, 1) else 0
	if deploy == "loadout" then
		c.bar.set(0, Style.Grey)
		c.status.Visible = true
		c.status.Text = "IN LOADOUT"
		c.status.TextColor3 = Style.Grey
		c.status.TextTransparency = 0
	elseif alive then
		c.bar.set(frac, if frac > 0.35 then Style.White else Style.Red)
		c.status.Visible = deploy == "dropping"
		if deploy == "dropping" then
			c.status.Text = "DROPPING IN"
			c.status.TextColor3 = Style.Amber
			c.status.TextTransparency = 0.1 + 0.3 * math.abs(math.sin(t * 4))
		end
	else
		local text, col = deadStatus(m, t)
		c.bar.set(1, Style.Red)
		c.bar.fill.BackgroundTransparency = 0.6
		c.status.Visible = true
		-- phone cards have ~100 px for the text: drop the long words
		local shown = text
		if touch then
			shown = string.gsub(shown, " AVAILABLE", "")
			shown = string.gsub(shown, "REINFORCEMENTS", "REINFORCE")
		end
		c.status.Text = shown
		c.status.TextColor3 = col
		-- slow pulse while the reinforce is actually callable
		c.status.TextTransparency = if text == "REINFORCE AVAILABLE" then 0.15 + 0.3 * math.abs(math.sin(t * 3)) else 0
	end
	if (alive or deploy == "loadout") and c.alive == false then
		c.bar.fill.BackgroundTransparency = 0
	end
	if touch then
		c.name.Visible = alive and not c.status.Visible -- one text row: the state text takes the name's place
	end
	c.alive = alive
	c.special = deploy ~= nil or carrying
end

local function applyPosition()
	if ui.holder then
		ui.holder.Position = UDim2.new(0, ui.x or Style.MARGIN, 1, -math.floor(ui.bottom or 200))
	end
end

-- Phones: pick card size and column so the stack never covers the objective list.
--   1) full cards under the objective column  2) compact cards there  3) compact cards under the uplink column (roomB, xB)
local function refit()
	if not touch then
		return
	end
	local n = 0
	for _ in cards do
		n += 1
	end
	local needCompact, x = false, Style.MARGIN
	if n > 0 and n * TOUCH_H + (n - 1) * 3 > roomA then
		needCompact = true
		if n * TOUCH_COMPACT_H + (n - 1) * 2 > roomA and roomB > roomA then
			x = xB
		end
	end
	if x ~= ui.x then
		ui.x = x
		applyPosition()
	end
	if needCompact == compact then
		return
	end
	compact = needCompact
	ui.layout.Padding = UDim.new(0, if compact then 2 else 3)
	for _, c in cards do
		applyGeometry(c)
		c.name.Visible = true
		refreshCard(c, c.m, lastT)
	end
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

-- offset: content px from the bottom edge to the bottom of the stack
function SquadCards.setBottom(offset: number)
	ui.bottom = offset
	applyPosition()
end

function SquadCards.build(parent: Instance, isTouch: boolean)
	touch = isTouch
	local holder = Instance.new("Frame")
	holder.Name = "SquadCards"
	holder.BackgroundTransparency = 1
	-- bottom-anchored: grows upward from just above the own card (HUD calls setBottom once it knows the card height)
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.Position = UDim2.new(0, Style.MARGIN, 1, -200)
	holder.Size = UDim2.fromOffset(cardWidth(), 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	holder.Parent = parent
	ui.layout = Theme.list(holder, Enum.FillDirection.Vertical, if touch then 3 else 4)
	ui.holder = holder
end

-- Content px of free height above the stack's bottom edge: roomA under the objective column (x = margin), roomB under the
-- uplink column (starts at content x xB). HUD recomputes these whenever those columns or the own card change size.
function SquadCards.setRoom(a: number, b: number, bx: number)
	roomA, roomB, xB = a, b, bx
	refit()
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
	lastMe, lastMission, lastT = me, mission, t
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
	refit()
	relayout()
end

-- 10 Hz: countdown text / pulse of the dead cards
function SquadCards.tick(me: any, mission: any, t: number)
	if not ui.holder or not ui.holder.Visible then
		return
	end
	lastMe, lastMission, lastT = me, mission, t
	for _, c in cards do
		-- dead cards (countdown / pulse) + join / carry states, and any card whose join / carry attribute just changed
		local plr = Players:GetPlayerByUserId(c.m.userId)
		local now = plr ~= nil and (plr:GetAttribute("Deploy") ~= nil or plr:GetAttribute("CarryCell") == true)
		if c.alive == false or c.special or now then
			refreshCard(c, c.m, t)
		end
	end
end

return SquadCards
