-- Live community war feed + global stats strip, shown on the war map (docs/spec.md §14).
-- Data: Store "warFeed" (rolling events, newest last) and "warLive" ({d, n, m, k}) pushed by WarService.
-- Owned by WarMap: WarFeed.build(parent, opts) once, then layout()/refresh()/step(dt).
local TweenService = game:GetService("TweenService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local Store = require(script.Parent.Parent.Store)

local WarFeed = {}
local C = Config.Colors

local EVENT_COLOR = {
	friendly = C.Friendly,
	accent = C.Accent,
	danger = C.Danger,
	gold = C.Gold,
	muted = C.Muted,
}
local EVENT_ICON = { lib = "+", drop = "»", flip = "!", op = "★", status = "•" }
local HEADER_H, STATS_H = 24, 46

local root: Frame
local list: ScrollingFrame
local statsRow: Frame
local toggleBtn: TextButton
local liveDot: Frame
local tiles: { { value: TextLabel, key: string, shown: number } } = {}
local rows: { [string]: { btn: TextButton, time: TextLabel, t: number } } = {}
local expanded = true
local userToggled = false
local onPlanet: ((string) -> ())? = nil
local audio: ((string) -> ())? = nil
local lastLayout: any = nil
local built = false

local function new(class: string, props: { [string]: any }, children: { Instance }?): any
	local i = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then
			(i :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = i
	end
	if props.Parent then
		i.Parent = props.Parent
	end
	return i
end

local function corner(r: number?): UICorner
	return new("UICorner", { CornerRadius = r and UDim.new(0, r) or UDim.new(1, 0) })
end

local function label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = C.Text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	}
	for k, v in props do
		base[k] = v
	end
	return new("TextLabel", base)
end

local function ago(t: number): string
	local s = math.max(0, workspace:GetServerTimeNow() - t)
	if s < 20 then
		return "now"
	elseif s < 60 then
		return string.format("%ds", s)
	elseif s < 3600 then
		return string.format("%dm", s // 60)
	elseif s < 86400 then
		return string.format("%dh", s // 3600)
	end
	return string.format("%dd", s // 86400)
end

local function fmtCount(n: number): string
	n = math.floor(n + 0.5)
	if n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.1fk", n / 1e3)
	end
	-- thousands separator
	local s = tostring(n)
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function WarFeed.build(parent: Instance, opts: { onPlanet: ((string) -> ())?, audio: ((string) -> ())? }?)
	onPlanet = opts and opts.onPlanet
	audio = opts and opts.audio
	root = new("Frame", {
		Name = "Feed",
		BackgroundColor3 = C.Navy,
		BackgroundTransparency = 0.1,
		ClipsDescendants = true,
		ZIndex = 25,
		Parent = parent,
	}, {
		corner(10),
		new("UIStroke", { Color = C.Friendly, Thickness = 1.5, Transparency = 0.55, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }),
	})
	-- header: blinking live dot, title, collapse toggle (the whole header is the toggle: big touch target)
	toggleBtn = new("TextButton", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 26,
		Parent = root,
	})
	liveDot = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(9, 9),
		BackgroundColor3 = C.Danger,
		ZIndex = 27,
		Parent = toggleBtn,
	}, { corner() })
	label({
		Text = "LIVE  ·  WAR FEED",
		Font = Enum.Font.Michroma,
		TextSize = 12,
		TextColor3 = C.Friendly,
		TextWrapped = false,
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(1, -50, 1, 0),
		ZIndex = 27,
		Parent = toggleBtn,
	})
	label({
		Name = "Chevron",
		Text = "▾",
		TextSize = 16,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 30, 1, 0),
		ZIndex = 27,
		Parent = toggleBtn,
	})
	toggleBtn.Activated:Connect(function()
		expanded = not expanded
		userToggled = true
		if audio then
			audio("UIClick")
		end
		if lastLayout then
			WarFeed.layout(lastLayout.compact, lastLayout.pos, lastLayout.anchor, lastLayout.width, lastLayout.avail)
		end
	end)
	-- stats strip
	statsRow = new("Frame", {
		Position = UDim2.fromOffset(0, HEADER_H + 4),
		Size = UDim2.new(1, 0, 0, STATS_H),
		BackgroundTransparency = 1,
		ZIndex = 26,
		Parent = root,
	}, { new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	for i, def in { { "m", "MISSIONS WON", C.Text }, { "k", "ENEMIES KILLED", C.Accent }, { "n", "DIVERS ACTIVE", C.Friendly } } do
		local tile = new("Frame", {
			Size = UDim2.new(1 / 3, -4, 1, 0),
			BackgroundColor3 = C.Panel,
			BackgroundTransparency = 0.2,
			LayoutOrder = i,
			ZIndex = 26,
			Parent = statsRow,
		}, { corner(6) })
		local value = label({
			Text = "0",
			Font = Enum.Font.Michroma,
			TextSize = 15,
			TextColor3 = def[3],
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			TextScaled = false,
			Position = UDim2.fromOffset(0, 4),
			Size = UDim2.new(1, 0, 0, 20),
			ZIndex = 27,
			Parent = tile,
		})
		label({
			Text = def[2],
			Font = Enum.Font.GothamBold,
			TextSize = 9,
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(0, 26),
			Size = UDim2.new(1, 0, 0, 12),
			ZIndex = 27,
			Parent = tile,
		})
		table.insert(tiles, { value = value, key = def[1], shown = 0 })
	end
	-- event list (newest on top)
	list = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, HEADER_H + STATS_H + 10),
		Size = UDim2.new(1, 0, 1, -(HEADER_H + STATS_H + 10)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.Muted,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ZIndex = 26,
		Parent = root,
	}, { new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	label({
		Name = "Empty",
		Text = "Waiting for news from the front...",
		Font = Enum.Font.GothamMedium,
		TextColor3 = C.Muted,
		TextSize = 12,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 1e9,
		ZIndex = 27,
		Parent = list,
	})
	built = true
end

-- pos/anchor/width in pixels; avail = max height the feed may take
function WarFeed.layout(compact: boolean, pos: UDim2, anchor: Vector2, width: number, avail: number)
	if not built then
		return
	end
	lastLayout = { compact = compact, pos = pos, anchor = anchor, width = width, avail = avail }
	if not userToggled then
		expanded = not compact -- phones start collapsed (stats only); tap the header to open
	end
	local minH = HEADER_H + STATS_H + 16 + 4
	local showList = expanded and avail >= minH + 60
	local h = if showList then math.min(avail, 330) else minH
	if compact and expanded then
		h = math.min(330, math.max(avail, minH + 140)) -- phones: the open feed may overlay the briefing sheet
		showList = true
	end
	root.AnchorPoint = anchor
	root.Position = pos
	root.Size = UDim2.fromOffset(width, h)
	list.Visible = showList
	local chev = toggleBtn:FindFirstChild("Chevron") :: TextLabel?
	if chev then
		chev.Text = if showList then "▾" else "▸"
	end
end

function WarFeed.setVisible(v: boolean)
	if built then
		root.Visible = v
	end
end

function WarFeed.refresh()
	if not built then
		return
	end
	local events = Store.get("warFeed") or {}
	local keep: { [string]: boolean } = {}
	local count = #events
	for i, ev in events do
		if type(ev) == "table" and type(ev.id) == "string" then
			keep[ev.id] = true
			local r = rows[ev.id]
			if not r then
				local col = EVENT_COLOR[ev.c] or C.Text
				local btn = new("TextButton", {
					Name = "Ev",
					Size = UDim2.new(1, -4, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundColor3 = C.Panel,
					BackgroundTransparency = 0.35,
					AutoButtonColor = false,
					Text = "",
					ZIndex = 27,
					Parent = list,
				}, {
					corner(6),
					new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 36), PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5) }),
				})
				new("Frame", {
					Name = "Bar",
					Position = UDim2.new(0, -10, 0, -5),
					Size = UDim2.new(0, 3, 1, 10),
					BackgroundColor3 = col,
					BorderSizePixel = 0,
					ZIndex = 28,
					Parent = btn,
				})
				local text = label({
					Text = (EVENT_ICON[ev.k] or "•") .. "  " .. tostring(ev.text),
					Font = if ev.k == "flip" or ev.k == "op" then Enum.Font.GothamBold else Enum.Font.GothamMedium,
					TextSize = 12,
					TextColor3 = if ev.k == "lib" or ev.k == "drop" then C.Text else col,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					ZIndex = 28,
					Parent = btn,
				})
				local time = label({
					Text = ago(tonumber(ev.t) or 0),
					Font = Enum.Font.GothamMedium,
					TextSize = 11,
					TextColor3 = C.Muted,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextWrapped = false,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, 32, 0, 0),
					Size = UDim2.fromOffset(32, 14),
					ZIndex = 28,
					Parent = btn,
				})
				local pid = ev.p
				btn.Activated:Connect(function()
					if pid and onPlanet then
						onPlanet(pid)
					end
				end)
				-- arrival: flash the row in the event colour, then settle
				if root.Visible then
					btn.BackgroundColor3 = col
					btn.BackgroundTransparency = 0.55
					text.TextTransparency = 1
					TweenService:Create(btn, TweenInfo.new(1.2, Enum.EasingStyle.Quad), { BackgroundColor3 = C.Panel, BackgroundTransparency = 0.35 }):Play()
					TweenService:Create(text, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
				end
				r = { btn = btn, time = time, t = tonumber(ev.t) or 0 }
				rows[ev.id] = r
			end
			r.btn.LayoutOrder = count - i -- newest first
		end
	end
	for id, r in rows do
		if not keep[id] then
			r.btn:Destroy()
			rows[id] = nil
		end
	end
	local empty = list:FindFirstChild("Empty") :: TextLabel?
	if empty then
		empty.Visible = count == 0
	end
end

-- per frame: count-up stats, blink the live dot; relative times are cheap enough to refresh each second
local acc = 0
function WarFeed.step(dt: number)
	if not built or not root.Visible then
		return
	end
	local live = Store.get("warLive") or {}
	for _, tile in tiles do
		local target = tonumber(live[tile.key]) or 0
		local d = target - tile.shown
		if math.abs(d) > 0.01 then
			tile.shown += d * math.min(1, dt * 4)
			if math.abs(target - tile.shown) < 0.5 then
				tile.shown = target
			end
			tile.value.Text = fmtCount(tile.shown)
		elseif tile.value.Text == "" then
			tile.value.Text = fmtCount(target)
		end
	end
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	liveDot.BackgroundTransparency = 0.6 * pulse
	acc += dt
	if acc > 1 then
		acc = 0
		for _, r in rows do
			r.time.Text = ago(r.t)
		end
	end
end

return WarFeed
