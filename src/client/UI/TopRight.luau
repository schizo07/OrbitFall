-- Top-right: reinforcement / lives counter ("▼ n") + mission timer ("T-mm:ss"), and under it a row of 52 px outlined
-- resource chips (samples green, rare orange, salvage / super amber, kills + XP grey). Chips only appear once their
-- count is above zero. On touch only the timer row is built; the counts are still tracked and EventFeed shows them
-- as a one-line summary behind its FEED button (TopRight.summary()).
-- New layouts (UI STYLE A-C): the timer alone ("12:41", no "T-") at the top-right; "v 3" reinforcements left of it
-- only for 10 s after the count changed or while someone is down; no chips (the counts go into the mission sheet).
local Style = require(script.Parent.HudStyle)
local Theme = require(script.Parent.Theme)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)
local Store = require(script.Parent.Parent.Store)

local TopRight = {}

local LIVES_SHOW = 10
local newMode = false
local nu: { [string]: any } = {}
local livesShown: number? = nil
local livesChangedAt = -100

local CHIP = 52
local ui: { [string]: any } = {}
local chips: { [string]: { frame: Frame, num: TextLabel, count: number } } = {}
local counts: { [string]: number } = {}

-- order = display order (right to left reading order is left to right here)
-- shape = a Style.glyph shape (drawn from Frames: the HUD font has no dingbat glyphs, they render as empty boxes)
local DEFS = {
	{ key = "samples", label = "SAMPLES", color = Style.Green, shape = "diamond" },
	{ key = "rare", label = "RARE", color = Style.Orange, shape = "diamond" },
	{ key = "salvage", label = "SALVAGE", color = Style.Amber, shape = "cog" },
	{ key = "super", label = "SUPER", color = Style.Amber, shape = "star" },
	{ key = "kills", label = "KILLS", color = Style.Grey, shape = "cross" },
	{ key = "xp", label = "XP", color = Style.Grey, shape = "up" },
}

local function buildNew(touch: boolean)
	nu = {}
	local T = InfoLayer.entry("timer", touch)
	local R = InfoLayer.entry("reinforce", touch)
	-- one right-aligned row at the timer's spot: [v 3] gap [12:41]; the reinforce part hides when it has nothing to say
	local h = T.Size.Y.Offset
	local holder = InfoLayer.fresh("TopRight")
	InfoLayer.place(holder, "timer", touch)
	holder.Size = UDim2.fromOffset(0, h)
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Visible = false
	Theme.list(holder, Enum.FillDirection.Horizontal, R.Gap or 17, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	nu.holder = holder
	local lives = Instance.new("Frame")
	lives.Name = "Reinforce"
	lives.BackgroundTransparency = 1
	lives.Size = UDim2.fromOffset(0, h)
	lives.AutomaticSize = Enum.AutomaticSize.X
	lives.LayoutOrder = 1
	lives.Visible = false
	lives.Parent = holder
	Theme.list(lives, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local rs: number = R.TextSize or 17
	nu.livesIcon = Style.glyph("down", {
		Size = math.floor(rs * 0.6),
		Color = InfoLayer.col("own"),
		Box = UDim2.fromOffset(math.floor(rs * 0.7), h),
		LayoutOrder = 1,
		Parent = lives,
	})
	nu.lives = InfoLayer.label({
		Text = "0",
		Role = "number",
		TextSize = rs,
		ColorRole = "own",
		Shadow = true,
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = lives,
	})
	nu.livesRow = lives
	nu.timer = InfoLayer.label({
		Text = "00:00",
		Role = "number",
		TextSize = T.TextSize or 20,
		ColorRole = "text",
		Shadow = true,
		XAlign = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = holder,
	})
end

-- reinforcements show while they matter: 10 s after the count changed, or while a squadmate / you are down
local function livesWanted(): boolean
	if os.clock() - livesChangedAt < LIVES_SHOW then
		return true
	end
	local me = Store.get("me")
	if type(me) == "table" and me.alive == false then
		return true
	end
	local squad = Store.get("squad")
	if type(squad) == "table" then
		for _, m in squad do
			if type(m) == "table" and m.alive == false then
				return true
			end
		end
	end
	return false
end

-- HUD colour -> skin colour role (the old HUD passes its own urgency colours)
local function roleColor(c: Color3): Color3
	if c == Style.Red then
		return InfoLayer.col("danger")
	elseif c == Style.Amber then
		return InfoLayer.col("own")
	elseif c == Style.Green then
		return InfoLayer.col("heal")
	end
	return InfoLayer.col("text")
end

function TopRight.build(parent: Instance, touch: boolean)
	newMode = InfoLayer.isNew()
	table.clear(chips) -- a rebuild (style switch) drops the previous build's chips
	if newMode then
		ui = {}
		livesShown = nil
		buildNew(touch)
		return
	end
	InfoLayer.drop("TopRight")
	nu = {}
	local holder = Instance.new("Frame")
	holder.Name = "TopRight"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -Style.MARGIN, 0, Style.MARGIN)
	holder.Size = UDim2.fromOffset(0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.XY
	holder.Parent = parent
	Style.applyBoost(holder, touch, 0.92) -- timer / lives / chips a bit larger (about 1.2 x PC, 1.1 x phone)
	Theme.list(holder, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right)
	ui.holder = holder

	local row = Style.panel({
		Name = "TimerRow",
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Parent = holder,
	})
	Theme.pad(row, 8, 0, 8, 0)
	Theme.list(row, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	ui.livesIcon = Style.glyph("down", { Size = 10, Color = Style.Amber, Box = UDim2.fromOffset(10, 24), LayoutOrder = 0, Parent = row })
	ui.lives = Style.label({
		Text = "0",
		TextSize = Style.ALERT,
		Color = Style.Amber,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Parent = row,
	})
	Style.rect({ Color = Style.White, Transparency = 0.6, Size = UDim2.fromOffset(1, 14), LayoutOrder = 2, Parent = row })
	ui.timer = Style.label({
		Text = "T-00:00",
		TextSize = Style.ALERT,
		Size = UDim2.fromOffset(64, 24),
		XAlign = Enum.TextXAlignment.Right,
		LayoutOrder = 3,
		Parent = row,
	})
	ui.row = row

	local chipRow = Instance.new("Frame")
	chipRow.Name = "Resources"
	chipRow.BackgroundTransparency = 1
	chipRow.Size = UDim2.fromOffset(0, CHIP)
	chipRow.AutomaticSize = Enum.AutomaticSize.X
	chipRow.LayoutOrder = 2
	chipRow.Visible = false
	chipRow.Parent = holder
	Theme.list(chipRow, Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Right)
	ui.chipRow = chipRow

	if touch then
		return -- resources are hidden on touch (the Mobile cluster owns the right edge)
	end
	for i, d in DEFS do
		local f = Instance.new("Frame")
		f.Name = d.key
		f.BackgroundColor3 = Style.Black
		f.BackgroundTransparency = Style.PANEL_ALPHA
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(CHIP, CHIP)
		f.LayoutOrder = i
		f.Visible = false
		f.Parent = chipRow
		local st = Instance.new("UIStroke")
		st.Color = d.color
		st.Thickness = 1
		st.Transparency = 0.1
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
		Style.glyph(d.shape, {
			Size = if d.shape == "up" then 11 else 14,
			Color = d.color,
			Box = UDim2.new(1, 0, 0, 16),
			Position = UDim2.fromOffset(0, 3),
			Parent = f,
		})
		local num = Style.label({
			Text = "0",
			TextSize = 20,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 22),
			Position = UDim2.fromOffset(0, 16),
			Parent = f,
		})
		Style.label({
			Text = d.label,
			TextSize = 10,
			Color = d.color,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.new(1, 0, 0, 12),
			Position = UDim2.new(0, 0, 1, -13),
			Parent = f,
		})
		chips[d.key] = { frame = f, num = num, count = 0 }
	end
end

function TopRight.setVisible(on: boolean)
	if newMode then
		if nu.holder then
			nu.holder.Visible = on
		end
		return
	end
	if ui.holder then
		ui.holder.Visible = on
	end
end

-- text like "T-12:30"; color for urgency
function TopRight.setTimer(text: string, color: Color3)
	if newMode then
		if nu.timer then
			nu.timer.Text = (string.gsub(text, "^T%-", ""))
			nu.timer.TextColor3 = roleColor(color)
		end
		return
	end
	if ui.timer then
		ui.timer.Text = text
		ui.timer.TextColor3 = color
	end
end

function TopRight.setLives(n: number?)
	if newMode then
		if not nu.lives then
			return
		end
		if n ~= livesShown then
			if livesShown ~= nil and n ~= nil then
				livesChangedAt = os.clock()
				HudSkin.bump(nu.lives)
			end
			livesShown = n
			if n then
				local col = if n <= 1 then InfoLayer.col("danger") else InfoLayer.col("own")
				nu.lives.Text = tostring(n)
				nu.lives.TextColor3 = col
				Style.tint(nu.livesIcon, col)
			end
		end
		nu.livesRow.Visible = n ~= nil and livesWanted()
		return
	end
	if not ui.lives then
		return
	end
	ui.lives.Visible = n ~= nil
	ui.livesIcon.Visible = n ~= nil
	if n then
		local col = if n <= 1 then Style.Red else Style.Amber
		ui.lives.Text = tostring(n)
		ui.lives.TextColor3 = col
		Style.tint(ui.livesIcon, col)
	end
end

-- Show / update a resource chip (count <= 0 hides it). Unknown keys are ignored.
function TopRight.setResource(key: string, count: number)
	local n = math.max(0, math.floor(count + 0.5))
	counts[key] = n
	local c = chips[key]
	if not c or newMode then
		return
	end
	if n == c.count then
		return
	end
	local grew = n > c.count
	c.count = n
	c.frame.Visible = n > 0
	c.num.Text = tostring(n)
	local any = false
	for _, other in chips do
		if other.frame.Visible then
			any = true
			break
		end
	end
	ui.chipRow.Visible = any
	if grew then
		c.num.TextColor3 = Style.Amber
		Theme.tween(c.num, 0.4, { TextColor3 = Style.White })
	end
end

function TopRight.getResource(key: string): number
	return counts[key] or 0
end

-- Non-zero resources in chip order: { { label, color, count } } (touch summary line in EventFeed)
function TopRight.summary(): { { label: string, color: Color3, count: number } }
	local out = {}
	for _, d in DEFS do
		local n = counts[d.key] or 0
		if n > 0 then
			table.insert(out, { label = d.label, color = d.color, count = n })
		end
	end
	return out
end

-- Height of the whole block so panels below can avoid it (px, content space)
function TopRight.bottom(): number
	return Style.MARGIN + 24 + (if ui.chipRow and ui.chipRow.Visible then 6 + CHIP else 0)
end

return TopRight
