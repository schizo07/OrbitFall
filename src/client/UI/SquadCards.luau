-- Bottom-left squadmate strip directly above the unified self vitals strip.
-- Every squadmate is compressed into one slim single-line row:
--   [2 px squad accent]  [callsign]  [crisp white HP bar]  [inline status when wounded / downed / carrying]
local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)

local SquadCards = {}

local nu: { [string]: any } = {}
local strip: { [number]: any } = {}
local touch = false
local want = false
local lastMe: any = nil
local lastMission: any = nil

local CELL = Color3.fromRGB(110, 225, 255)

local function deadStatus(m: any, t: number): (string, Color3)
	if type(m.respawnAt) == "number" and m.respawnAt > t then
		return string.format("RESPAWN %dS", math.ceil(m.respawnAt - t)), InfoLayer.col("own")
	end
	local me = lastMe
	local lives = lastMission and lastMission.lives
	if type(lives) == "number" and lives <= 0 then
		return "NO REINFORCE", InfoLayer.col("dim")
	end
	if me and me.alive == false then
		return "DOWN", InfoLayer.col("danger")
	end
	local ready = me and me.reinforceReadyAt or 0
	if ready > t then
		return string.format("REINFORCE %dS", math.ceil(ready - t)), InfoLayer.col("danger")
	end
	return "REINFORCE", InfoLayer.col("danger")
end

local function makeRow(m: any): any
	local E = InfoLayer.entry("squad", touch)
	local rowH: number = E.RowHeight or 24
	local tagSize: number = E.TagSize or 13
	local statusSize: number = E.StatusSize or 12
	local hpH: number = E.HpHeight or 4
	local tagW = math.floor(tagSize * 2.1)

	local f = HudSkin.panel("plate", {
		Name = "Mate" .. tostring(m.userId),
		Size = UDim2.new(1, 0, 0, rowH),
		Parent = nu.holder,
	})

	local accent = Style.rect({
		Name = "Accent",
		Color = InfoLayer.col("text"),
		Size = UDim2.new(0, 2, 1, 0),
		Parent = f,
	})

	local tag = InfoLayer.label({
		Text = "",
		Role = "number",
		TextSize = tagSize,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.fromOffset(tagW, rowH),
		Parent = f,
	})

	local barX = tagW + 10
	local bar = HudSkin.bar({
		Name = "Hp",
		Parent = f,
		Size = UDim2.new(1, -(barX + 8), 0, hpH),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, barX, 0.5, 0),
		Color = InfoLayer.col("text"),
	})

	local status = InfoLayer.label({
		Text = "",
		TextSize = statusSize,
		ColorRole = "danger",
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 0),
		Size = UDim2.new(1, -(barX + 6), 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = false,
		Parent = f,
	})

	return {
		frame = f,
		accent = accent,
		tag = tag,
		bar = bar,
		status = status,
		m = m,
		barX = barX,
		hpH = hpH,
	}
end

local function refreshRow(r: any, m: any, t: number)
	r.m = m
	local cs = Style.callsign(m.userId)
	local plr = Players:GetPlayerByUserId(m.userId)
	local deploy = plr and plr:GetAttribute("Deploy")
	local carrying = plr ~= nil and plr:GetAttribute("CarryCell") == true
	local alive = m.alive ~= false and deploy ~= "loadout"
	local frac = if (m.maxHp or 0) > 0 then Theme.clamp((m.hp or 0) / m.maxHp, 0, 1) else 0
	local downed = alive and m.downed == true

	r.tag.Text = cs.tag
	local tagCol = if alive then cs.color else InfoLayer.col("dim")
	r.tag.TextColor3 = tagCol
	r.accent.BackgroundColor3 = tagCol

	local text, col, pulse = "", InfoLayer.col("danger"), 0
	if deploy == "loadout" then
		text, col = "LOADOUT", InfoLayer.col("dim")
	elseif not alive then
		text, col = deadStatus(m, t)
		pulse = if text == "REINFORCE" then 3 else 0
	elseif downed then
		text, pulse = "BLEEDING OUT", 5
	elseif deploy == "dropping" then
		text, col, pulse = "DROPPING", InfoLayer.col("own"), 4
	elseif carrying then
		text, col = "CELL", CELL
	end

	local showStatus = text ~= ""
	r.status.Visible = showStatus
	r.bar.root.Visible = not showStatus or carrying

	if showStatus then
		r.status.Text = InfoLayer.caseText(text)
		r.status.TextColor3 = col
		r.status.TextTransparency = if pulse > 0 then 0.1 + 0.4 * math.abs(math.sin(t * pulse)) else 0
	end

	if carrying then
		r.bar.root.Size = UDim2.new(1, -(r.barX + 44), 0, r.hpH)
	else
		r.bar.root.Size = UDim2.new(1, -(r.barX + 8), 0, r.hpH)
	end

	if alive then
		r.bar.set(frac, if frac > 0.35 and not downed then InfoLayer.col("text") else InfoLayer.col("danger"))
	end
end

function SquadCards.setBottom(_offset: number) end

function SquadCards.setRoom(_a: number, _b: number, _bx: number) end

function SquadCards.build(_parent: Instance, isTouch: boolean)
	touch = isTouch
	nu = {}
	table.clear(strip)
	local holder = InfoLayer.fresh("SquadStrip")
	InfoLayer.place(holder, "squad", touch)
	holder.Size = UDim2.fromOffset(holder.Size.X.Offset, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Visible = false
	Theme.list(holder, Enum.FillDirection.Vertical, if touch then 3 else 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom)
	nu.holder = holder
end

function SquadCards.setVisible(on: boolean)
	want = on
	if nu.holder then
		nu.holder.Visible = on and next(strip) ~= nil
	end
end

function SquadCards.update(squad: any, me: any, mission: any, userId: number, t: number)
	lastMe, lastMission = me, mission
	if not nu.holder then
		return
	end
	local seen: { [number]: boolean } = {}
	if type(squad) == "table" then
		for _, m in squad do
			if type(m) ~= "table" or type(m.userId) ~= "number" or m.userId == userId then
				continue
			end
			seen[m.userId] = true
			local r = strip[m.userId]
			if not r then
				r = makeRow(m)
				strip[m.userId] = r
			end
			r.frame.LayoutOrder = Style.callsign(m.userId).index
			refreshRow(r, m, t)
		end
	end
	local n = 0
	for id, r in strip do
		if not seen[id] then
			r.frame:Destroy()
			strip[id] = nil
		else
			n += 1
		end
	end
	nu.holder.Visible = want and n > 0
end

function SquadCards.tick(me: any, mission: any, t: number)
	if nu.holder and nu.holder.Visible then
		lastMe, lastMission = me, mission
		for _, r in strip do
			refreshRow(r, r.m, t)
		end
	end
end

return SquadCards
