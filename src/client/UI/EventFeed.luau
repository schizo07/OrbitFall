-- In-mission ephemeral event feed (bottom-right on PC, compact upper-center under alerts on phone).
-- Every line has a glyph by kind and auto-fades; repeated lines bump a counter (pickups add up their "+N").
local Store = require(script.Parent.Parent.Store)
local Style = require(script.Parent.HudStyle)
local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)

local EventFeed = {}

local nu: { [string]: any } = {}
local feedLines: { any } = {}
local touch = false
local serial = 0

local KIND_SHAPE: { [string]: string } = {
	died = "skull",
	kill = "cross",
	objective = "check",
	callin = "diamond",
	bark = "dash",
	comms = "dash",
	pickup = "diamond",
	toast = "dot",
}

local function squadMember(name: string): any?
	local squad = Store.get("squad")
	if type(squad) == "table" then
		for _, m in squad do
			if type(m) == "table" and m.name == name then
				return m
			end
		end
	end
	return nil
end

local function roleColor(c: Color3?): Color3
	if c == nil or c == Style.Amber then
		return InfoLayer.col("own")
	elseif c == Style.Red then
		return InfoLayer.col("danger")
	elseif c == Style.Cyan then
		return InfoLayer.col("objective")
	elseif c == Style.Green then
		return InfoLayer.col("heal")
	elseif c == Style.Orange then
		return InfoLayer.col("rare")
	elseif c == Style.White then
		return InfoLayer.col("text")
	elseif c == Style.Grey then
		return InfoLayer.col("dim")
	end
	return c
end

local function removeLine(line: any)
	local i = table.find(feedLines, line)
	if i then
		table.remove(feedLines, i)
	end
	if line.row.Parent then
		line.row:Destroy()
	end
end

local function armLine(line: any)
	line.gen += 1
	local gen = line.gen
	local E = nu.E
	task.delay(E.Life or 5.5, function()
		if line.gen ~= gen or not line.row.Parent then
			return
		end
		line.dying = true
		local fade = E.FadeTime or 0.35
		HudSkin.fade(line.row, 1, fade)
		task.delay(fade + 0.05, function()
			if line.gen == gen then
				removeLine(line)
			end
		end)
	end)
end

local function pushLine(text: string, color: Color3?, kind: string?, shape: string?, plus: number?)
	if not nu.holder then
		return
	end
	local E = nu.E
	local col = roleColor(color)
	local base = InfoLayer.caseText(text)
	for _, l in feedLines do
		if not l.dying and l.base == base and l.row.Parent then
			l.count += 1
			if plus and l.plus then
				l.plus += plus
				l.label.Text = string.format("+%d %s", l.plus, base)
			else
				l.label.Text = string.format("%s  x%d", base, l.count)
			end
			HudSkin.bump(l.label)
			armLine(l)
			return
		end
	end
	serial += 1
	local H: number = E.LineHeight or 22
	local row = Instance.new("Frame")
	row.Name = "Line"
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.fromOffset(0, H)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.LayoutOrder = if touch then -serial else serial
	Theme.pad(row, 7, 0, 7, 0)
	Theme.list(row, Enum.FillDirection.Horizontal, E.GlyphGap or 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	InfoLayer.backing(row, "plate")

	local textSize: number = E.TextSize or 14
	local g = Style.glyph(shape or KIND_SHAPE[kind or ""] or "dot", {
		Size = math.max(7, math.floor(textSize * 0.58)),
		Color = col,
		Box = UDim2.fromOffset(math.floor(textSize * 0.8), H),
		LayoutOrder = if touch then 1 else 2,
		Parent = row,
	})
	g.AnchorPoint = Vector2.zero

	local label = InfoLayer.label({
		Text = if plus then string.format("+%d %s", plus, base) else base,
		Raw = true,
		TextSize = textSize,
		Color = col,
		XAlign = if touch then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(0, H),
		AutomaticSize = Enum.AutomaticSize.X,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = if touch then 2 else 1,
		Parent = row,
	})
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(nu.holder.Size.X.Offset - textSize * 2, H)
	cap.Parent = label
	row.Parent = nu.holder

	local line = { row = row, label = label, base = base, count = 1, gen = 0, dying = false, plus = plus }
	table.insert(feedLines, line)
	while #feedLines > (E.Lines or 5) do
		removeLine(feedLines[1])
	end
	HudSkin.enter(row, if touch then "top" else "right")
	armLine(line)
end

function EventFeed.build(_parent: Instance, isTouch: boolean)
	touch = isTouch
	nu = {}
	table.clear(feedLines)
	local E = InfoLayer.entry("feed", touch)
	local holder = InfoLayer.fresh("EventFeed")
	InfoLayer.place(holder, "feed", touch)
	holder.Visible = false
	holder.ClipsDescendants = false
	Theme.list(
		holder,
		Enum.FillDirection.Vertical,
		E.Gap or 4,
		if touch then Enum.HorizontalAlignment.Center else Enum.HorizontalAlignment.Right,
		if touch then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Bottom
	)
	nu.holder = holder
	nu.E = E
end

function EventFeed.push(text: string, color: Color3?, kind: string?)
	pushLine(text, color, kind, nil, nil)
end

function EventFeed.route(text: string, _color: Color3?, _kind: string?): boolean
	local who = string.match(text, "^(.+) is down!$")
	if who then
		local m = squadMember(who)
		local tag = if m then Style.callsign(m.userId).tag else nil
		local name = Style.up(who)
		if #name > 14 then
			name = string.sub(name, 1, 12) .. "..."
		end
		EventFeed.push((if tag then tag .. " - " else "") .. name .. " DIED", Style.Red, "died")
		return true
	end
	local n = string.match(text, "^(%d+) squadmates? reinforced")
	if n then
		EventFeed.push(string.format("%s SQUADMATE%s REINFORCED", n, if n == "1" then "" else "S"), Style.Amber, "callin")
		return true
	end
	return false
end

function EventFeed.pickup(text: string, shape: string?, color: Color3?, plus: number?): boolean
	pushLine(text, color, "pickup", shape, plus)
	return true
end

function EventFeed.toast(text: string, color: Color3?): boolean
	pushLine(text, color, "toast", nil, nil)
	return true
end

function EventFeed.isNew(): boolean
	return true
end

function EventFeed.setVisible(on: boolean)
	if nu.holder then
		nu.holder.Visible = on
	end
end

function EventFeed.clear()
	for _, l in table.clone(feedLines) do
		removeLine(l)
	end
	table.clear(feedLines)
end

function EventFeed.tick() end

return EventFeed
