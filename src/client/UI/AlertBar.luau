-- Top-centre alert stack, directly under the compass bearing chip.
-- Visible ONLY during active breaches, waves, extraction holds, heavy callouts, or mission notices:
--   1. ALERT BAR   slim crimson bar (white bold caps, directional arrow, countdown clock, hairline progress)
--   2. CALLOUT     compact amber line (HEAVY CONTACT ...), a few seconds
--   3. NOTICE      compact coloured title + sub line, queued (HUD.banner routes here)
-- Own ScreenGui "OrbitAlert". Safe to call before init (idempotent).
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local HudLayout = require(script.Parent.HudLayout)

local AlertBar = {}
AlertBar.TOP = 56

local built = false
local touch = false
local ui: { [string]: any } = {}

type Alert = { id: string, text: string, color: Color3, priority: number, seq: number, arrow: boolean }
local sticky: { [string]: Alert } = {}
local seq = 0
local shownId: string? = nil
local pulseToken = 0
local calloutToken = 0
local noticeQueue: { { title: string, sub: string?, color: Color3, hold: number } } = {}
local noticeBusy = false
local lastNoticeTitle = ""
local lastNoticeAt = 0

local BAR_ALPHA = 0.14
local CRIMSON_FILL = Color3.fromHex("A8141C")

local function tw(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?)
	return Theme.tween(inst, t, props, style)
end

function AlertBar.init()
	if built then
		return
	end
	built = true
	touch = Theme.isTouch()
	local gui = Theme.gui("OrbitAlert", { DisplayOrder = 12, Insets = "CoreUISafeInsets" })
	ui.gui = gui
	local root = Theme.root(gui, "hud")
	local lay = HudLayout.get("alert", touch)
	local barH: number = lay.BarHeight or 26
	local textSize: number = lay.TextSize or 16
	local subSize: number = lay.SubSize or 14
	local calloutH: number = lay.CalloutHeight or 22

	local stack = Instance.new("Frame")
	stack.Name = "AlertStack"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = lay.AnchorPoint
	stack.Position = lay.Position
	stack.Size = UDim2.fromOffset(lay.Size.X.Offset, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.Parent = root
	Theme.list(stack, Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Center)
	ui.stack = stack

	-- 1. Slim crimson alert bar
	local bar = Style.rect({
		Name = "AlertBar",
		Color = CRIMSON_FILL,
		Transparency = BAR_ALPHA,
		Size = UDim2.new(1, 0, 0, barH),
		LayoutOrder = 1,
		Visible = false,
		Parent = stack,
	})
	local st = Instance.new("UIStroke")
	st.Name = "AlertEdge"
	st.Color = HudSkin.color("danger")
	st.Transparency = 0.38
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = bar
	ui.barEdge = st
	ui.bar = bar

	ui.arrow = Style.glyph("up", {
		Size = math.max(10, math.floor(textSize * 0.62)),
		Box = UDim2.fromOffset(26, barH),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 18, 0.5, 0),
		Visible = false,
		Parent = bar,
	})
	ui.text = HudSkin.label({
		Text = "",
		TextSize = textSize,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, -112, 1, 0),
		Position = UDim2.fromOffset(40, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = bar,
	})
	ui.time = HudSkin.label({
		Text = "",
		Role = "number",
		TextSize = subSize,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(64, barH),
		Parent = bar,
	})
	local prog = Style.bar({
		Name = "TimeLeft",
		Size = UDim2.new(1, 0, 0, 2),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Color = Style.White,
		Parent = bar,
	})
	prog.back.Visible = false
	ui.prog = prog

	-- 2. Callout (compact amber line)
	local callout = Instance.new("Frame")
	callout.Name = "Callout"
	callout.BackgroundTransparency = 1
	callout.Size = UDim2.fromOffset(0, calloutH)
	callout.AutomaticSize = Enum.AutomaticSize.X
	callout.LayoutOrder = 2
	callout.Visible = false
	callout.Parent = stack
	Theme.list(callout, Enum.FillDirection.Horizontal, 5, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	ui.calloutArrow = Style.glyph("up", {
		Size = math.max(10, math.floor(subSize * 0.6)),
		Color = Style.Amber,
		Box = UDim2.fromOffset(18, calloutH),
		LayoutOrder = 1,
		Parent = callout,
	})
	ui.calloutText = HudSkin.label({
		Text = "",
		TextSize = subSize,
		Color = Style.Amber,
		Size = UDim2.fromOffset(0, calloutH),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = callout,
	})
	ui.callout = callout

	-- 3. Notice (queued banner replacement)
	local notice = Instance.new("Frame")
	notice.Name = "Notice"
	notice.BackgroundTransparency = 1
	notice.Size = UDim2.fromScale(1, 0)
	notice.AutomaticSize = Enum.AutomaticSize.Y
	notice.LayoutOrder = 3
	notice.Visible = false
	notice.Parent = stack
	Theme.list(notice, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center)
	ui.notice = notice
	ui.noticeTitle = HudSkin.label({
		Text = "",
		TextSize = textSize,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, textSize + 6),
		LayoutOrder = 1,
		Parent = notice,
	})
	ui.noticeSub = HudSkin.label({
		Text = "",
		TextSize = subSize,
		ColorRole = "dim",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, subSize + 4),
		LayoutOrder = 2,
		Parent = notice,
	})
end

-- Sticky alert bar ------------------------------------------------------------------------------------------------
local function pulse()
	pulseToken += 1
	local my = pulseToken
	task.spawn(function()
		for _ = 1, 2 do
			if my ~= pulseToken or not ui.bar then
				return
			end
			tw(ui.bar, 0.12, { BackgroundTransparency = 0.72 })
			task.wait(0.14)
			if my ~= pulseToken then
				return
			end
			tw(ui.bar, 0.12, { BackgroundTransparency = BAR_ALPHA })
			task.wait(0.14)
		end
	end)
end

local function refresh()
	if not built then
		return
	end
	local best: Alert? = nil
	for _, a in sticky do
		if not best or a.priority > best.priority or (a.priority == best.priority and a.seq > best.seq) then
			best = a
		end
	end
	if not best then
		ui.bar.Visible = false
		shownId = nil
		pulseToken += 1
		return
	end
	local changedAlert = shownId ~= best.id
	ui.bar.Visible = true
	local isRed = best.color == Style.Red
	local isAmber = best.color == Style.Amber
	ui.bar.BackgroundColor3 = if isRed then CRIMSON_FILL else best.color
	if ui.barEdge then
		ui.barEdge.Color = if isRed then Color3.fromHex("FF5555") else best.color
	end
	local textCol = if isAmber then Style.Black else Style.White
	ui.text.TextColor3 = textCol
	Style.tint(ui.arrow, textCol)
	ui.time.TextColor3 = textCol
	ui.arrow.Visible = best.arrow
	ui.text.Text = string.upper(best.text)
	ui.prog.fill.BackgroundColor3 = textCol
	if changedAlert then
		ui.time.Text = ""
		ui.prog.back.Visible = false
		ui.arrow.Rotation = 0
	end
	shownId = best.id
	if changedAlert then
		pulse()
	end
end

function AlertBar.set(id: string, text: string, opts: { color: Color3?, priority: number?, arrow: boolean?, seconds: number? }?)
	local o = opts or {}
	local prev = sticky[id]
	seq += 1
	local rec: Alert = {
		id = id,
		text = text,
		color = o.color or Style.Red,
		priority = o.priority or 1,
		seq = if prev then prev.seq else seq,
		arrow = o.arrow == true,
	}
	sticky[id] = rec
	refresh()
	if o.seconds then
		task.delay(o.seconds, function()
			if sticky[id] == rec then
				AlertBar.clear(id)
			end
		end)
	end
end

function AlertBar.clear(id: string)
	if sticky[id] then
		sticky[id] = nil
		refresh()
	end
end

function AlertBar.clearAll()
	table.clear(sticky)
	refresh()
end

function AlertBar.setArrow(rotation: number)
	if built and ui.arrow.Visible then
		ui.arrow.Rotation = rotation
	end
end

function AlertBar.setClock(text: string, fraction: number?)
	if not built or not ui.bar.Visible then
		return
	end
	if ui.time.Text ~= text then
		ui.time.Text = text
	end
	if fraction then
		ui.prog.back.Visible = true
		ui.prog.set(fraction)
	else
		ui.prog.back.Visible = false
	end
end

function AlertBar.isShowing(id: string): boolean
	return shownId == id
end

-- True while any alert bar, heavy callout, or notice is visible (Tips hides to avoid overlap).
function AlertBar.isActive(): boolean
	if not built or not ui.gui or not ui.gui.Enabled then
		return false
	end
	return (ui.bar ~= nil and ui.bar.Visible)
		or (ui.callout ~= nil and ui.callout.Visible)
		or (ui.notice ~= nil and ui.notice.Visible)
end

function AlertBar.pulseOnce()
	if not built or not ui.bar or not ui.bar.Visible then
		return
	end
	tw(ui.bar, 0.08, { BackgroundTransparency = math.min(BAR_ALPHA + 0.55, 0.8) })
	task.delay(0.1, function()
		if built and ui.bar and ui.bar.Visible then
			tw(ui.bar, 0.14, { BackgroundTransparency = BAR_ALPHA })
		end
	end)
end

-- Amber callout line ------------------------------------------------------------------------------------------------
function AlertBar.callout(text: string, color: Color3?, seconds: number?, showArrow: boolean?)
	if not built then
		return
	end
	calloutToken += 1
	local my = calloutToken
	local col = color or Style.Amber
	ui.callout.Visible = true
	ui.calloutText.Text = string.upper(text)
	ui.calloutText.TextColor3 = col
	Style.tint(ui.calloutArrow, col)
	ui.calloutArrow.Visible = showArrow == true
	ui.calloutText.TextTransparency = 1
	Style.glyphAlpha(ui.calloutArrow, 1)
	tw(ui.calloutText, 0.15, { TextTransparency = 0 })
	Style.glyphTween(ui.calloutArrow, 0.15, 0)
	task.delay(seconds or 3, function()
		if my ~= calloutToken then
			return
		end
		tw(ui.calloutText, 0.35, { TextTransparency = 1 })
		Style.glyphTween(ui.calloutArrow, 0.35, 1)
		task.delay(0.4, function()
			if my == calloutToken then
				ui.callout.Visible = false
			end
		end)
	end)
end

function AlertBar.setCalloutArrow(rotation: number)
	if built and ui.callout.Visible and ui.calloutArrow.Visible then
		ui.calloutArrow.Rotation = rotation
	end
end

function AlertBar.calloutVisible(): boolean
	return built and ui.callout.Visible
end

-- Queued notice line (HUD.banner) -----------------------------------------------------------------------------------
local function runNotices()
	if noticeBusy then
		return
	end
	noticeBusy = true
	task.spawn(function()
		while #noticeQueue > 0 do
			local n = table.remove(noticeQueue, 1) :: any
			ui.noticeTitle.Text = string.upper(n.title)
			ui.noticeTitle.TextColor3 = n.color
			ui.noticeSub.Text = string.upper(n.sub or "")
			ui.noticeSub.Visible = n.sub ~= nil and n.sub ~= ""
			ui.notice.Visible = true
			ui.noticeTitle.TextTransparency = 1
			ui.noticeSub.TextTransparency = 1
			tw(ui.noticeTitle, 0.18, { TextTransparency = 0 })
			tw(ui.noticeSub, 0.25, { TextTransparency = 0 })
			task.wait(n.hold)
			tw(ui.noticeTitle, 0.3, { TextTransparency = 1 })
			tw(ui.noticeSub, 0.3, { TextTransparency = 1 })
			task.wait(0.35)
			ui.notice.Visible = false
		end
		noticeBusy = false
	end)
end

function AlertBar.notice(title: string, sub: string?, color: Color3?, hold: number?)
	if not built then
		return
	end
	local t = os.clock()
	if title == lastNoticeTitle and t - lastNoticeAt < 3 then
		return
	end
	lastNoticeTitle, lastNoticeAt = title, t
	if #noticeQueue >= 3 then
		table.remove(noticeQueue, 1)
	end
	table.insert(noticeQueue, { title = title, sub = sub, color = color or Style.Amber, hold = hold or 2.4 })
	runNotices()
end

function AlertBar.setVisible(on: boolean)
	if built then
		ui.gui.Enabled = on
	end
end

function AlertBar.rebuild()
	if not built then
		return
	end
	local enabled = ui.gui and ui.gui.Enabled
	if ui.gui then
		ui.gui:Destroy()
	end
	table.clear(ui)
	built = false
	shownId = nil
	pulseToken += 1
	calloutToken += 1
	table.clear(noticeQueue)
	AlertBar.init()
	if enabled ~= nil then
		ui.gui.Enabled = enabled
	end
	refresh()
end

return AlertBar
