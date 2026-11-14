-- Top-left passive call-in list ("UPLINK"): one 36 px row per loadout slot plus the REINFORCE row.
--   row = "▸" tick, amber icon, caps name, uses pips (bottom right), charges badge (top right).
--   cooldown = the row dims, a dark wipe shrinks left-to-right as the cooldown runs out, remaining seconds on the right.
-- Pure display: the Uplink Dial (UI/UplinkDial + CallInController) still owns all input.
-- Data: Store "me".callins.slots[{id, readyAt, uses, charges, maxCharges}] and me.reinforceReadyAt (HUD forwards `me`).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallIns = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local CallInList = {}

local touch = false
local ui: { [string]: any } = {}
local rows: { any } = {}
local rowKey: string? = nil

local function rowHeight(): number
	return if touch then 30 else 36
end

local function makeRow(def: any, order: number, reinforce: boolean, slotIndex: number?): any
	local h = rowHeight()
	local row, tick = Style.listRow(ui.list, h, order, Style.Amber)
	tick.Position = UDim2.fromOffset(0, 0)
	local icon = Style.label({
		Text = Style.callinCode(def), -- ASCII code; the data icons are dingbats the HUD font lacks
		TextSize = if touch then 11 else 12,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(0, 24, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Parent = row,
	})
	local name = Style.label({
		Text = if reinforce then "REINFORCE" else (def and def.name or "?"),
		Size = UDim2.new(1, -(if touch then 84 else 96), 1, 0),
		Position = UDim2.fromOffset(40, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = not touch, -- phones: icons only
		Parent = row,
	})
	local pips = Instance.new("Frame")
	pips.Name = "Pips"
	pips.BackgroundTransparency = 1
	pips.AnchorPoint = Vector2.new(1, 1)
	pips.Position = UDim2.new(1, -6, 1, -5)
	pips.Size = UDim2.fromOffset(60, 4)
	pips.Parent = row
	Theme.list(pips, Enum.FillDirection.Horizontal, 2, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local badge = Style.label({
		Text = "",
		TextSize = 12,
		Color = Style.Amber,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 2),
		Size = UDim2.fromOffset(40, 14),
		Parent = row,
	})
	-- cooldown wipe (dark block that shrinks towards the left) + seconds
	local wipe = Style.rect({
		Name = "Wipe",
		Color = Style.Black,
		Transparency = 0.35,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 3,
		Parent = row,
	})
	local secs = Style.label({
		Text = "",
		TextSize = if touch then 14 else 16,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(44, 20),
		XAlign = Enum.TextXAlignment.Right,
		ZIndex = 4,
		Parent = row,
	})
	return {
		row = row, tick = tick, icon = icon, name = name, pips = pips, badge = badge, wipe = wipe, secs = secs,
		def = def, reinforce = reinforce, slotIndex = slotIndex, pipCount = -1, pipMax = -1, ready = nil,
	}
end

local function rebuild(me: any)
	for _, r in rows do
		r.row:Destroy()
	end
	table.clear(rows)
	local slots = me and me.callins and me.callins.slots or {}
	for i, s in slots do
		local def = CallIns.get(s.id)
		local r = makeRow(def, i, false, i)
		if def then
			r.tick.TextColor3 = Theme.beaconColor(def.beacon)
		end
		table.insert(rows, r)
	end
	local rdef = CallIns.get("REINFORCE")
	local rr = makeRow(rdef, 20, true, nil)
	rr.icon.Text = Style.callinCode(rdef)
	rr.tick.TextColor3 = Style.Green
	table.insert(rows, rr)
end

function CallInList.build(parent: Instance, isTouch: boolean, order: number?)
	touch = isTouch
	local p = Style.panel({
		Name = "CallIns",
		Size = if isTouch then UDim2.fromOffset(104, 0) else UDim2.new(1, 0, 0, 0), -- phones: narrow icon column
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 1,
		Visible = false,
		Parent = parent,
	})
	Theme.pad(p, 6, 4, 6, 6)
	Theme.list(p, Enum.FillDirection.Vertical, 2)
	Style.label({
		Text = "UPLINK",
		TextSize = 12,
		Color = Style.Grey,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 0,
		Parent = p,
	})
	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.LayoutOrder = 1
	list.Parent = p
	Theme.list(list, Enum.FillDirection.Vertical, 2)
	ui.panel = p
	ui.list = list
end

function CallInList.setVisible(on: boolean)
	if ui.panel then
		ui.panel.Visible = on and #rows > 0
		ui.want = on
	end
end

-- me = Store "me"; t = workspace:GetServerTimeNow()
function CallInList.update(me: any, t: number)
	if not ui.panel then
		return
	end
	if type(me) ~= "table" or type(me.callins) ~= "table" or type(me.callins.slots) ~= "table" then
		return
	end
	local slots = me.callins.slots
	local ids = {}
	for _, s in slots do
		table.insert(ids, s.id)
	end
	local key = table.concat(ids, ",")
	if key ~= rowKey then
		rowKey = key
		rebuild(me)
		ui.panel.Visible = ui.want == true and #rows > 0
	end
	for _, r in rows do
		local def = r.def
		if not def then
			continue
		end
		local available, remaining, reason
		local slot
		if r.reinforce then
			remaining = math.max(0, (me.reinforceReadyAt or 0) - t)
			available = remaining <= 0
			reason = if available then "READY" else "COOLDOWN"
		else
			slot = slots[r.slotIndex]
			if not slot then
				continue
			end
			available, remaining, reason = Theme.slotStatus(slot, def, t)
		end
		local frac = 0
		if remaining > 0 and not (slot and slot.charges ~= nil and slot.charges > 0) then
			frac = Theme.clamp(remaining / math.max(def.cooldown, 1), 0, 1)
		end
		if reason == "NO USES" then
			r.wipe.Size = UDim2.fromScale(1, 1)
			r.secs.Text = "-"
			r.secs.TextColor3 = Style.Red
		elseif frac > 0 then
			r.wipe.Size = UDim2.fromScale(frac, 1)
			r.secs.Text = tostring(math.ceil(remaining)) .. "s"
			r.secs.TextColor3 = Style.White
		else
			r.wipe.Size = UDim2.fromScale(0, 1)
			r.secs.Text = ""
		end
		local dim = if available then 0 else 0.55
		r.icon.TextTransparency = dim
		r.name.TextTransparency = dim
		r.tick.TextTransparency = dim
		if slot then
			r.badge.Text = if slot.maxCharges and slot.maxCharges > 1 then ("x" .. tostring(slot.charges or 0)) else ""
			if def.uses then
				local have = slot.uses or def.uses
				if r.pipCount ~= have or r.pipMax ~= def.uses then
					for _, c in r.pips:GetChildren() do
						if c:IsA("Frame") then
							c:Destroy()
						end
					end
					for i = 1, def.uses do
						Style.rect({
							Color = if i <= have then Style.Amber else Style.Grey,
							Transparency = if i <= have then 0 else 0.55,
							Size = UDim2.fromOffset(9, 4),
							LayoutOrder = i,
							Parent = r.pips,
						})
					end
					r.pipCount, r.pipMax = have, def.uses
				end
			end
		end
		if r.ready ~= available then
			if available and r.ready == false then
				-- ready flash: the tick pops
				r.tick.TextColor3 = Style.White
				Theme.tween(r.tick, 0.4, { TextColor3 = if r.reinforce then Style.Green else Theme.beaconColor(def.beacon) })
			end
			r.ready = available
		end
	end
end

return CallInList
