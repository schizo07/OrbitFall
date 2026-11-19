-- In-mission event feed, bottom-right (250 x 110 px, 5 lines, newest at the bottom, each line fades after 8 s).
--   red   = player DIED lines          amber = own kills / streaks, call-in arrivals, squad chatter
--   cyan  = objective completions
-- (UI/WarFeed is the war-map community feed on the ship; this one is the live mission feed.)
-- API: build(parent, touch) / push(text, color, kind?) / route(notifyText, color, kind) -> handled / setVisible / clear / tick.
-- Touch: the feed (plus a one-line resource summary) sits behind a FEED button in the top row (right of the compass),
-- auto-closes after 8 s.
-- New layouts (UI STYLE A-C): the one event feed. Right-mid on PC (6 lines, newest on top, 6 s), under the alert stack on
-- phones (2 lines, 4 s), no FEED button. Every line has a glyph by kind; pickups (UI/PickupToast), HUD toasts
-- (EventFeed.toast) and your own radio lines (UI/SquadComms) land here too. A repeat of the same line bumps a counter
-- (pickups add up their "+N").
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local TopRight = require(script.Parent.TopRight)

local EventFeed = {}

local newMode = false
local nu: { [string]: any } = {}
local feedLines: { any } = {}

-- line glyph by kind (Style.glyph shapes)
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

local MAX_LINES = 5
local LIFE = 8 -- seconds a line stays before it fades
local FADE = 0.6
local MAX_CHARS = 38
local OPEN_FOR = 8 -- touch popup auto-close
local FEED_X = Style.MARGIN + 210 + 66 + 8 -- touch, "old" layout: just right of the own card (HUD: HP_BAR_W 210 + 66 wide)
-- Touch FEED button, default layout: top row, just right of the compass (Compass: centred, 0.34 of the content width),
-- so it is out of the left thumbstick zone and big enough to tap; the popup opens under the compass, left of the button.
local COMPASS_RIGHT = 0.67
local FEED_W, FEED_H = 76, 40

local ui: { [string]: any } = {}
local lines: { any } = {}
local touch = false
local want = false
local open = false
local openUntil = 0
local serial = 0

local function lineHeight(): number
	return if touch then 18 else 20
end

local function setOpen(on: boolean)
	open = on
	if on then
		openUntil = os.clock() + OPEN_FOR
		ui.unread.Visible = false
	end
	ui.holder.Visible = want and (not touch or open)
	if ui.btnLabel then
		ui.btnLabel.TextColor3 = if open then Style.Amber else Style.White
	end
end

-- Studio A/B "PHONE HUD" (Feel_PhoneHud): nil = FEED button in the top row; "old" = button + popup bottom-left
-- beside the own card (inside the thumbstick zone, 62 x 24 content px)
local function placeTouch()
	local holder, btn = ui.holder, ui.button
	if not holder or not btn then
		return
	end
	if workspace:GetAttribute("Feel_PhoneHud") == "old" then
		holder.AnchorPoint = Vector2.new(0, 1)
		holder.Position = UDim2.new(0, FEED_X, 1, -(Style.MARGIN + 28))
		btn.AnchorPoint = Vector2.new(0, 1)
		btn.Position = UDim2.new(0, FEED_X, 1, -Style.MARGIN)
		btn.Size = UDim2.fromOffset(62, 24)
	else
		btn.AnchorPoint = Vector2.new(0, 0)
		btn.Position = UDim2.new(COMPASS_RIGHT, 12, 0, Style.MARGIN)
		btn.Size = UDim2.fromOffset(FEED_W, FEED_H)
		holder.AnchorPoint = Vector2.new(1, 0)
		holder.Position = UDim2.new(COMPASS_RIGHT, 4, 0, Style.MARGIN + FEED_H + 4)
	end
end

local function removeLine(line: any)
	local i = table.find(lines, line)
	if i then
		table.remove(lines, i)
	end
	if line.row.Parent then
		line.row:Destroy()
	end
end

local function fadeLine(line: any, gen: number)
	if line.gen ~= gen or not line.row.Parent then
		return
	end
	line.dying = true
	Theme.tween(line.row, FADE, { BackgroundTransparency = 1 })
	Theme.tween(line.tick, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
	Theme.tween(line.label, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 })
	task.delay(FADE + 0.05, function()
		if line.gen == gen then
			removeLine(line)
		end
	end)
end

local function armLine(line: any)
	line.gen += 1
	local gen = line.gen
	task.delay(LIFE, fadeLine, line, gen)
end

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

-- New layouts ---------------------------------------------------------------------------------------------------------
-- HUD / module colours -> skin colour roles; squad callsign colours and other custom colours pass through
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

local function buildNew()
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
		E.Gap or 6,
		if touch then Enum.HorizontalAlignment.Center else Enum.HorizontalAlignment.Right,
		Enum.VerticalAlignment.Top
	)
	nu.holder = holder
	nu.E = E
end

local function removeNew(line: any)
	local i = table.find(feedLines, line)
	if i then
		table.remove(feedLines, i)
	end
	if line.row.Parent then
		line.row:Destroy()
	end
end

local function armNew(line: any)
	line.gen += 1
	local gen = line.gen
	local E = nu.E
	task.delay(E.Life or 6, function()
		if line.gen ~= gen or not line.row.Parent then
			return
		end
		line.dying = true
		local fade = E.FadeTime or 0.4
		HudSkin.fade(line.row, 1, fade)
		task.delay(fade + 0.05, function()
			if line.gen == gen then
				removeNew(line)
			end
		end)
	end)
end

-- one feed line. shape = glyph (default by kind); plus = amount that adds up on repeats ("+2 GRENADES")
local function pushNew(text: string, color: Color3?, kind: string?, shape: string?, plus: number?)
	if not nu.holder then
		return
	end
	local E = nu.E
	local col = roleColor(color)
	local base = InfoLayer.caseText(text)
	-- the same line again while it is still up: bump a counter instead of stacking
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
			armNew(l)
			return
		end
	end
	serial += 1
	local H: number = E.LineHeight or 20
	local row = Instance.new("Frame")
	row.Name = "Line"
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.fromOffset(0, H)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.LayoutOrder = -serial -- newest on top
	Theme.list(row, Enum.FillDirection.Horizontal, E.GlyphGap or 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local preset = InfoLayer.preset()
	if InfoLayer.style() == "glass" or preset == "clean" then
		Theme.pad(row, 12, 0, 12, 0)
		local b = InfoLayer.backing(row)
		local c = b:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = b
	elseif preset == "bold" or preset == "frame" then
		Theme.pad(row, 10, 0, 10, 0)
		InfoLayer.backing(row, true)
	end
	local textSize: number = E.TextSize or 15
	local g = Style.glyph(shape or KIND_SHAPE[kind or ""] or "dot", {
		Size = math.max(7, math.floor(textSize * 0.6)),
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
		Shadow = true,
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
	while #feedLines > (E.Lines or 6) do
		removeNew(feedLines[1])
	end
	HudSkin.enter(row, if touch then "top" else "right")
	armNew(line)
end

function EventFeed.build(parent: Instance, isTouch: boolean)
	touch = isTouch
	newMode = InfoLayer.isNew()
	-- a rebuild (style switch) drops the previous build's lines
	table.clear(lines)
	if newMode then
		ui = {}
		buildNew()
		return
	end
	InfoLayer.drop("EventFeed")
	table.clear(feedLines)
	local H = lineHeight()
	local holder = Instance.new("Frame")
	holder.Name = "EventFeed"
	holder.BackgroundTransparency = 1
	if touch then
		-- opens above the FEED button, which sits right of the own card (bottom-left) so it never lands on the
		-- left column (objectives / uplink list), whose height changes with the mission and the screen
		holder.AnchorPoint = Vector2.new(0, 1)
		holder.Position = UDim2.new(0, FEED_X, 1, -(Style.MARGIN + 28))
		holder.Size = UDim2.fromOffset(220, 5 * H + 4 * 2 + 20)
		holder.Visible = false
		holder.ZIndex = 5
	else
		holder.AnchorPoint = Vector2.new(1, 1)
		holder.Position = UDim2.new(1, -Style.MARGIN, 1, -Style.MARGIN)
		holder.Size = UDim2.fromOffset(250, 110)
		holder.Visible = false
	end
	holder.Parent = parent
	ui.holder = holder

	local resH = if touch then 20 else 0
	local list = Instance.new("Frame")
	list.Name = "Lines"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(0, resH)
	list.Size = UDim2.new(1, 0, 1, -resH)
	list.Parent = holder
	Theme.list(
		list,
		Enum.FillDirection.Vertical,
		2,
		if touch then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Right,
		Enum.VerticalAlignment.Bottom
	)
	ui.list = list

	if touch then
		local res = Style.panel({
			Name = "Resources",
			Size = UDim2.new(1, 0, 0, 18),
			Parent = holder,
		})
		ui.res = Style.label({
			Text = "",
			Rich = true,
			TextSize = 12,
			Size = UDim2.new(1, -10, 1, 0),
			Position = UDim2.fromOffset(6, 0),
			Parent = res,
		})
		local btn = Instance.new("TextButton")
		btn.Name = "FeedButton"
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.BackgroundColor3 = Style.Black
		btn.BackgroundTransparency = Style.PANEL_ALPHA
		btn.BorderSizePixel = 0
		btn.AnchorPoint = Vector2.new(0, 1)
		btn.Position = UDim2.new(0, FEED_X, 1, -Style.MARGIN)
		btn.Size = UDim2.fromOffset(62, 24)
		btn.Visible = false
		btn.ZIndex = 6
		btn.Parent = parent
		Style.brackets(btn)
		ui.btnLabel = Style.label({
			Text = "FEED",
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 7,
			Parent = btn,
		})
		ui.unread = Style.rect({
			Name = "Unread",
			Color = Style.Amber,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -3, 0, 3),
			Size = UDim2.fromOffset(5, 5),
			Visible = false,
			ZIndex = 8,
			Parent = btn,
		})
		ui.button = btn
		placeTouch()
		workspace:GetAttributeChangedSignal("Feel_PhoneHud"):Connect(placeTouch)
		btn.Activated:Connect(function()
			setOpen(not open)
			Theme.sfx("UIClick")
		end)
	else
		ui.unread = { Visible = false } -- stand-in so push() needs no touch branch
	end
end

function EventFeed.push(text: string, color: Color3?, kind: string?)
	if newMode then
		pushNew(text, color, kind, nil, nil)
		return
	end
	if not ui.list then
		return
	end
	local col = color or Style.Amber
	local up = Style.up(text)
	if #up > MAX_CHARS then
		up = string.sub(up, 1, MAX_CHARS - 3) .. "..."
	end
	-- the same line again while the last one is still up: bump a counter instead of spamming
	local last = lines[#lines]
	if last and not last.dying and last.base == up and last.row.Parent then
		last.count += 1
		last.label.Text = string.format("%s  x%d", up, last.count)
		armLine(last)
		return
	end
	serial += 1
	local H = lineHeight()
	local row = Style.panel({
		Name = "Line",
		Brackets = false,
		Size = UDim2.fromOffset(0, H),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = serial,
		Parent = ui.list,
	})
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(if touch then 220 else 250, H)
	cap.Parent = row
	Theme.pad(row, 5, 0, 7, 0)
	Theme.list(row, Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local tick = Style.label({
		Text = ">",
		TextSize = 12,
		Color = col,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(10, H),
		LayoutOrder = 1,
		Parent = row,
	})
	local label = Style.label({
		Text = up,
		TextSize = if touch then 13 else Style.TEXT,
		Color = col,
		Size = UDim2.fromOffset(0, H),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = row,
	})
	local line = { row = row, tick = tick, label = label, base = up, count = 1, gen = 0, dying = false }
	table.insert(lines, line)
	while #lines > MAX_LINES do
		removeLine(lines[1])
	end
	-- quick fade-in
	row.BackgroundTransparency = 1
	tick.TextTransparency = 1
	label.TextTransparency = 1
	Theme.tween(row, 0.15, { BackgroundTransparency = Style.PANEL_ALPHA })
	Theme.tween(tick, 0.15, { TextTransparency = 0 })
	Theme.tween(label, 0.15, { TextTransparency = 0 })
	armLine(line)
	if touch and not open and want then
		ui.unread.Visible = true
	end
end

-- Server Notify texts that belong in the feed. Returns true when handled (HUD then skips the toast).
function EventFeed.route(text: string, color: Color3?, _kind: string?): boolean
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

-- New layouts only: a pickup line with its own glyph and an amount that adds up ("+2 GRENADES"). Returns false with the
-- old HUD (PickupToast then shows its own toast).
function EventFeed.pickup(text: string, shape: string?, color: Color3?, plus: number?): boolean
	if not newMode then
		return false
	end
	pushNew(text, color, "pickup", shape, plus)
	return true
end

-- New layouts only: a short HUD message (what HUD.toast shows with the old HUD). Returns false with the old HUD.
function EventFeed.toast(text: string, color: Color3?): boolean
	if not newMode then
		return false
	end
	pushNew(text, color, "toast", nil, nil)
	return true
end

function EventFeed.isNew(): boolean
	return newMode
end

function EventFeed.setVisible(on: boolean)
	want = on
	if newMode then
		if nu.holder then
			nu.holder.Visible = on
		end
		return
	end
	if not ui.holder then
		return
	end
	if ui.button then
		ui.button.Visible = on
	end
	ui.holder.Visible = on and (not touch or open)
end

function EventFeed.clear()
	if newMode then
		for _, l in table.clone(feedLines) do
			removeNew(l)
		end
		table.clear(feedLines)
		return
	end
	for _, l in table.clone(lines) do
		removeLine(l)
	end
	table.clear(lines)
	if touch and ui.holder then
		setOpen(false)
		ui.unread.Visible = false
	end
end

local function resourceText(): string
	local parts = {}
	for _, r in TopRight.summary() do
		table.insert(parts, string.format('<font color="#%s">%s</font> %d', r.color:ToHex(), r.label, r.count))
	end
	if #parts == 0 then
		return '<font color="#A7ADB7">NO RESOURCES YET</font>'
	end
	return table.concat(parts, "   ")
end

-- 10 Hz from HUD
function EventFeed.tick()
	if newMode or not touch or not ui.holder or not open then
		return
	end
	if os.clock() > openUntil then
		setOpen(false)
		return
	end
	ui.res.Text = resourceText()
end

return EventFeed
