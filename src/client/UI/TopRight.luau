-- Top-right compact mission timer pill (clear of Roblox's top-right PlayerList/chrome).
-- Reinforcements live on the top-left Call-In chip (CallInList reads TopRight.getLives() / Store "mission").
-- Resource counts are tracked here for MissionSheet and EventFeed summaries.
local Style = require(script.Parent.HudStyle)
local Theme = require(script.Parent.Theme)
local InfoLayer = require(script.Parent.InfoLayer)

local TopRight = {}

local nu: { [string]: any } = {}
local counts: { [string]: number } = {}
local livesCount: number? = nil

local DEFS = {
	{ key = "samples", label = "SAMPLES", color = Style.Green, shape = "diamond" },
	{ key = "rare", label = "RARE", color = Style.Orange, shape = "diamond" },
	{ key = "salvage", label = "SALVAGE", color = Style.Amber, shape = "cog" },
	{ key = "super", label = "SUPER", color = Style.Amber, shape = "star" },
	{ key = "kills", label = "KILLS", color = Style.Grey, shape = "cross" },
	{ key = "xp", label = "XP", color = Style.Grey, shape = "up" },
}

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

function TopRight.build(_parent: Instance, touch: boolean)
	nu = {}
	local T = InfoLayer.entry("timer", touch)
	local h: number = T.Size.Y.Offset
	local ts: number = T.TextSize or 17

	local holder = InfoLayer.fresh("TopRight")
	InfoLayer.place(holder, "timer", touch)
	holder.Size = UDim2.fromOffset(0, h)
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Visible = false
	InfoLayer.backing(holder, "plate")
	Theme.pad(holder, if touch then 10 else 12, 0, if touch then 10 else 12, 0)
	Theme.list(holder, Enum.FillDirection.Horizontal, if touch then 5 else 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	nu.holder = holder

	InfoLayer.label({
		Text = "T-",
		Role = "label",
		TextSize = math.max(11, ts - 3),
		ColorRole = "dim",
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Parent = holder,
	})
	nu.timer = InfoLayer.label({
		Text = "00:00",
		Role = "number",
		TextSize = ts,
		ColorRole = "text",
		XAlign = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = holder,
	})
end

function TopRight.setVisible(on: boolean)
	if nu.holder then
		nu.holder.Visible = on
	end
end

function TopRight.setTimer(text: string, color: Color3)
	if nu.timer then
		local clean = (string.gsub(text, "^T%-", ""))
		if nu.timer.Text ~= clean then
			nu.timer.Text = clean
		end
		nu.timer.TextColor3 = roleColor(color)
	end
end

function TopRight.setLives(n: number?)
	livesCount = n
end

function TopRight.getLives(): number?
	return livesCount
end

function TopRight.setResource(key: string, count: number)
	counts[key] = math.max(0, math.floor(count + 0.5))
end

function TopRight.getResource(key: string): number
	return counts[key] or 0
end

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

function TopRight.bottom(): number
	return 174
end

return TopRight
