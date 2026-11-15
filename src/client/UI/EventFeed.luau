-- In-mission event feed, bottom-right (250 x 110 px, 5 lines, newest at the bottom, each line fades after 8 s).
--   red   = player DIED lines          amber = own kills / streaks, call-in arrivals, squad chatter
--   cyan  = objective completions
-- (UI/WarFeed is the war-map community feed on the ship; this one is the live mission feed.)
-- API: build(parent, touch) / push(text, color, kind?) / route(notifyText, color, kind) -> handled / setVisible / clear / tick.
-- Touch: the feed (plus a one-line resource summary) sits behind a small FEED button on the left edge, auto-closes after 8 s.
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local TopRight = require(script.Parent.TopRight)

local EventFeed = {}

local MAX_LINES = 5
local LIFE = 8 -- seconds a line stays before it fades
local FADE = 0.6
local MAX_CHARS = 38
local OPEN_FOR = 8 -- touch popup auto-close
local FEED_X = Style.MARGIN + 210 + 66 + 8 -- touch: just right of the own card (HUD: HP_BAR_W 210 + 66 wide)

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

function EventFeed.build(parent: Instance, isTouch: boolean)
	touch = isTouch
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
		btn.Activated:Connect(function()
			setOpen(not open)
			Theme.sfx("UIClick")
		end)
	else
		ui.unread = { Visible = false } -- stand-in so push() needs no touch branch
	end
end

function EventFeed.push(text: string, color: Color3?, _kind: string?)
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

function EventFeed.setVisible(on: boolean)
	want = on
	if not ui.holder then
		return
	end
	if ui.button then
		ui.button.Visible = on
	end
	ui.holder.Visible = on and (not touch or open)
end

function EventFeed.clear()
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
	if not touch or not ui.holder or not open then
		return
	end
	if os.clock() > openUntil then
		setOpen(false)
		return
	end
	ui.res.Text = resourceText()
end

return EventFeed
