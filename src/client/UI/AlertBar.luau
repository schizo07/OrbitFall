-- Top-centre alert stack, directly under the compass tape (HUD/Compass builds the tape at y = 16 and its heading chip
-- down to y ~ 46; the stack starts at AlertBar.TOP).
--   1. ALERT BAR   24 px solid red (85 %), white caps. Sticky alerts (breach / extraction hold / build warnings): the
--                  highest priority one shows for as long as it is set; it pulses twice whenever the shown alert changes.
--   2. CALLOUT     small amber line (HEAVY CONTACT ...), a few seconds.
--   3. NOTICE      smaller coloured title + sub line, queued (HUD.banner routes here).
-- Own ScreenGui "OrbitAlert". Safe to call before init (everything is a no-op until the GUI exists; HUD.init and
-- IntensityFx both call AlertBar.init, which is idempotent).
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local AlertBar = {}
AlertBar.TOP = 50

local built = false
local touch = false
local ui: { [string]: any } = {}

type Alert = { id: string, text: string, color: Color3, priority: number, seq: number, arrow: boolean }
local sticky: { [string]: Alert } = {}
local seq = 0
local shownId: string? = nil
local shownText = ""
local pulseToken = 0
local calloutToken = 0
local noticeQueue: { { title: string, sub: string?, color: Color3, hold: number } } = {}
local noticeBusy = false
local lastNoticeTitle = ""
local lastNoticeAt = 0

local function tw(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?)
	return Theme.tween(inst, t, props, style)
end

function AlertBar.init()
	if built then
		return
	end
	built = true
	touch = Theme.isTouch()
	local gui = Theme.gui("OrbitAlert", { DisplayOrder = 11, Insets = "CoreUISafeInsets" })
	ui.gui = gui
	local root = Theme.root(gui, "hud")
	local content = Style.content(root, touch)

	local stack = Instance.new("Frame")
	stack.Name = "AlertStack"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(0.5, 0)
	stack.Position = UDim2.new(0.5, 0, 0, AlertBar.TOP)
	stack.Size = UDim2.fromScale(0.34, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.Parent = content
	local lim = Instance.new("UISizeConstraint")
	lim.MinSize = Vector2.new(340, 0)
	lim.Parent = stack
	Theme.list(stack, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center)
	ui.stack = stack

	-- 1. alert bar
	local bar = Style.rect({
		Name = "AlertBar",
		Color = Style.Red,
		Transparency = 0.15,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 1,
		Visible = false,
		Parent = stack,
	})
	Style.brackets(bar, Style.White, 5)
	ui.bar = bar
	ui.arrow = Style.glyph("up", {
		Size = 12,
		Box = UDim2.fromOffset(24, 24),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 18, 0.5, 0),
		Visible = false,
		Parent = bar,
	})
	ui.text = Style.label({
		Text = "",
		TextSize = Style.ALERT,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, -90, 1, 0),
		Position = UDim2.fromOffset(45, 0),
		Parent = bar,
	})
	ui.time = Style.label({
		Text = "",
		TextSize = 16,
		XAlign = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(48, 24),
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

	-- 2. callout (amber line)
	local callout = Instance.new("Frame")
	callout.Name = "Callout"
	callout.BackgroundTransparency = 1
	callout.Size = UDim2.new(0, 0, 0, 20)
	callout.AutomaticSize = Enum.AutomaticSize.X
	callout.LayoutOrder = 2
	callout.Visible = false
	callout.Parent = stack
	Theme.list(callout, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	ui.calloutArrow = Style.glyph("up", {
		Size = 11,
		Color = Style.Amber,
		Box = UDim2.fromOffset(16, 20),
		LayoutOrder = 1,
		Parent = callout,
	})
	ui.calloutText = Style.label({
		Text = "",
		TextSize = 16,
		Color = Style.Amber,
		Size = UDim2.fromOffset(0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = callout,
	})
	ui.callout = callout

	-- 3. notice (queued banner replacement)
	local notice = Instance.new("Frame")
	notice.Name = "Notice"
	notice.BackgroundTransparency = 1
	notice.Size = UDim2.new(1, 0, 0, 0)
	notice.AutomaticSize = Enum.AutomaticSize.Y
	notice.LayoutOrder = 3
	notice.Visible = false
	notice.Parent = stack
	Theme.list(notice, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Center)
	ui.notice = notice
	ui.noticeTitle = Style.label({
		Text = "",
		TextSize = Style.ALERT,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 1,
		Parent = notice,
	})
	ui.noticeSub = Style.label({
		Text = "",
		TextSize = Style.TEXT,
		Color = Style.Grey,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 18),
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
			tw(ui.bar, 0.12, { BackgroundTransparency = 0.8 })
			task.wait(0.15)
			if my ~= pulseToken then
				return
			end
			tw(ui.bar, 0.12, { BackgroundTransparency = 0.15 })
			task.wait(0.15)
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
		shownId, shownText = nil, ""
		pulseToken += 1
		return
	end
	local changedAlert = shownId ~= best.id
	ui.bar.Visible = true
	ui.bar.BackgroundColor3 = best.color
	local dark = best.color == Style.Amber
	ui.text.TextColor3 = if dark then Style.Black else Style.White
	ui.text.TextStrokeTransparency = if dark then 1 else 0.65
	Style.tint(ui.arrow, ui.text.TextColor3)
	ui.time.TextColor3 = ui.text.TextColor3
	ui.arrow.Visible = best.arrow
	ui.text.Text = string.upper(best.text)
	ui.prog.fill.BackgroundColor3 = ui.text.TextColor3
	if changedAlert then
		ui.time.Text = ""
		ui.prog.back.Visible = false
		ui.arrow.Rotation = 0
	end
	shownId = best.id
	if changedAlert then
		pulse()
	end
	shownText = best.text
end

-- id: stable key ("breach", "extract", ...). priority: higher wins (extract 3, breach 2, build 1). opts: color, priority, arrow, seconds
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

-- Per-frame extras for the alert that is showing. rotation in degrees (nil = leave), clock text ("" hides), fraction 0..1 (nil hides)
function AlertBar.setArrow(rotation: number)
	if built and ui.arrow.Visible then
		ui.arrow.Rotation = rotation
	end
end

function AlertBar.setClock(text: string, fraction: number?)
	if not built or not ui.bar.Visible then
		return
	end
	if ui.time.Text ~= text then -- called every frame by IntensityFx; the text only changes about once a second
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

-- Hide the whole stack outside missions
function AlertBar.setVisible(on: boolean)
	if built then
		ui.gui.Enabled = on
	end
end

return AlertBar
