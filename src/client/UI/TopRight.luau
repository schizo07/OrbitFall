-- Top-right: reinforcement / lives counter ("▼ n") + mission timer ("T-mm:ss"), and under it a row of 52 px outlined
-- resource chips (samples green, rare orange, salvage / super amber, kills + XP grey). Chips only appear once their
-- count is above zero. On touch only the timer row is built; the counts are still tracked and EventFeed shows them
-- as a one-line summary behind its FEED button (TopRight.summary()).
local Style = require(script.Parent.HudStyle)
local Theme = require(script.Parent.Theme)

local TopRight = {}

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

function TopRight.build(parent: Instance, touch: boolean)
	local holder = Instance.new("Frame")
	holder.Name = "TopRight"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -Style.MARGIN, 0, Style.MARGIN)
	holder.Size = UDim2.fromOffset(0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.XY
	holder.Parent = parent
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
	if ui.holder then
		ui.holder.Visible = on
	end
end

-- text like "T-12:30"; color for urgency
function TopRight.setTimer(text: string, color: Color3)
	if ui.timer then
		ui.timer.Text = text
		ui.timer.TextColor3 = color
	end
end

function TopRight.setLives(n: number?)
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
	if not c then
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
