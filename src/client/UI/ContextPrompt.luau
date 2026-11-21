--!nonstrict
-- Bottom-centre context prompt: "TAP [R] TO RELOAD". A key / button glyph box inside the text, with priority and dedupe.
-- Only one prompt shows at a time: the highest priority, the newest on ties. Showing an id that is already up only
-- refreshes its text and timer (no re-pop). Glyphs follow the active input (keyboard / gamepad / touch) and re-render
-- when it changes.
--
-- API
--   ContextPrompt.show(id, text, key, seconds?, priority?)
--       text      may contain "{key}" where the glyph goes; without it the glyph goes first
--       key       an action name from ACTIONS below (Reload, Stim, Prone, Grenade, Dial, Interact, Sprint, Crouch, Jump,
--                 Swap, Fire, Aim) or a literal key label (shown as is); "" = plain message without a key box
--       seconds   nil = until hide(id)
--       priority  default 1 (higher wins)
--   ContextPrompt.hide(id)
--   ContextPrompt.isShowing(id) -> bool   (true while it is queued, even when a higher one covers it)
--   ContextPrompt.setVisible(on)          HUD hides the whole layer outside combat
--   ContextPrompt.setProgress(id, frac?)  a fill bar under the prompt while `id` is the one showing (nil = no bar);
--                                         used by the stim hold (Fx/VitalsFx)
-- Wired by: HUD (empty magazine -> reload), Fx/VitalsFx (critical health -> stim, heavy fire -> prone, stim denials).

local UserInputService = game:GetService("UserInputService")

-- New layouts (UI STYLE A-C): the prompt sits at the layout's "prompt" spot (PC 20 px under the centre clear box; phone
-- left of the SIDE button), in the skin's fonts; glass / visor get their backing, hairline is text on a stroke. The
-- layer is built again after a style switch.
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local HudSkin = require(script.Parent.HudSkin)
local InfoLayer = require(script.Parent.InfoLayer)

local ContextPrompt = {}

local newMode = false
local TEXT_SIZE, KEY_SIZE = 17, 22

-- per input mode: kb = keyboard, pad = gamepad, touch = on-screen button name. "@shape" draws a Style.glyph shape.
local ACTIONS: { [string]: { kb: string, pad: string, touch: string } } = {
	Reload = { kb = "R", pad = "X", touch = "RELOAD" },
	Stim = { kb = "F", pad = "@left", touch = "STIM" },
	Prone = { kb = "Z", pad = "HOLD B", touch = "HOLD CROUCH" },
	Crouch = { kb = "C", pad = "B", touch = "CROUCH" },
	Grenade = { kb = "G", pad = "RB", touch = "GRENADE" },
	Dial = { kb = "Q", pad = "LB", touch = "UPLINK" },
	Interact = { kb = "E", pad = "X", touch = "TAP" }, -- ProximityPrompt defaults
	Sprint = { kb = "SHIFT", pad = "L3", touch = "SPRINT" },
	Jump = { kb = "SPACE", pad = "A", touch = "JUMP" },
	Swap = { kb = "1-3", pad = "Y", touch = "SWAP" },
	Fire = { kb = "LMB", pad = "RT", touch = "FIRE" },
	Aim = { kb = "RMB", pad = "LT", touch = "AIM" },
}

local H = 30 -- row height (virtual px)

type Entry = { id: string, text: string, key: string, until_: number?, priority: number, serial: number, progress: number? }

local entries: { [string]: Entry } = {}
local serial = 0
local ui: { [string]: any } = {}
local built = false
local visible = true
local shownId: string? = nil
local shownSig = ""
local mode = "kb"

local function inputMode(): string
	local t = UserInputService:GetLastInputType()
	if t == Enum.UserInputType.Touch then
		return "touch"
	end
	if string.find(t.Name, "Gamepad") then
		return "pad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	end
	return "kb"
end

local function glyphFor(key: string): string
	local a = ACTIONS[key]
	if not a then
		return key
	end
	if key == "Interact" and mode == "pad" and workspace:GetAttribute("Feel_PadInteract") == "dpad" then
		return "@up" -- client/Input "PAD INTERACT" B: prompts on D-pad Up
	end
	return (a :: any)[mode] or a.kb
end

local function build()
	if built then
		return
	end
	built = true
	local touch = Theme.isTouch()
	newMode = true
	local E = InfoLayer.entry("prompt", touch)
	local g = Theme.gui("OrbitPrompt", { DisplayOrder = 12, Insets = "CoreUISafeInsets" })
	ui.gui = g
	local r = Theme.root(g, "hud")
	H = E.Size.Y.Offset
	TEXT_SIZE = E.TextSize or 16
	KEY_SIZE = E.KeySize or 22
	local wrap = Instance.new("Frame")
	wrap.Name = "PromptWrap"
	wrap.BackgroundTransparency = 1
	InfoLayer.place(wrap, "prompt", touch)
	wrap.Size = UDim2.fromOffset(0, 0)
	wrap.AutomaticSize = Enum.AutomaticSize.XY
	wrap.Parent = r
	Theme.list(wrap, Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Center)
	local holder = Instance.new("Frame")
	holder.Name = "Prompt"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(0, H)
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.LayoutOrder = 1
	holder.Visible = false
	holder.Parent = wrap
	InfoLayer.backing(holder, "plate")
	local lim = Instance.new("UISizeConstraint")
	lim.MaxSize = Vector2.new(E.MaxWidth or 420, math.huge)
	lim.Parent = holder
	Theme.pad(holder, 10, 0, 10, 0)
	Theme.list(holder, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	ui.holder = holder
	ui.scale = scale
	ui.parts = {}
	local bar = HudSkin.bar({
		Name = "PromptProgress",
		Size = UDim2.fromOffset(math.floor((E.MaxWidth or 400) * 0.45), 4),
		Color = InfoLayer.col("heal"),
		LayoutOrder = 2,
		Parent = wrap,
	})
	ui.progress = { back = bar.root, set = bar.set }
	ui.progress.back.Visible = false
end

local function clearParts()
	for _, p in ui.parts do
		p:Destroy()
	end
	table.clear(ui.parts)
end

local function addText(text: string, order: number)
	if text == "" then
		return
	end
	if newMode then
		table.insert(
			ui.parts,
			InfoLayer.label({
				Text = text,
				TextSize = TEXT_SIZE,
				ColorRole = "text",
				Shadow = true,
				Size = UDim2.fromOffset(0, H),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = order,
				Parent = ui.holder,
			})
		)
		return
	end
	local l = Style.label({
		Text = text,
		TextSize = 17,
		Color = Style.White,
		Size = UDim2.fromOffset(0, H),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
		Parent = ui.holder,
	})
	table.insert(ui.parts, l)
end

local function addKeyNew(glyph: string, order: number)
	local isGlyph = string.sub(glyph, 1, 1) == "@"
	local own = InfoLayer.col("own")
	local box = Instance.new("Frame")
	box.Name = "Key"
	box.BorderSizePixel = 0
	box.BackgroundColor3 = own
	box.BackgroundTransparency = 0.85
	box.Size = UDim2.fromOffset(if isGlyph then KEY_SIZE else 0, KEY_SIZE)
	box.AutomaticSize = if isGlyph then Enum.AutomaticSize.None else Enum.AutomaticSize.X
	box.LayoutOrder = order
	box.Parent = ui.holder
	local st = Instance.new("UIStroke")
	st.Color = own
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = box
	if isGlyph then
		Style.glyph(string.sub(glyph, 2), { Size = math.floor(KEY_SIZE * 0.5), Color = own, Box = UDim2.fromScale(1, 1), Parent = box })
	else
		Theme.pad(box, 6, 0, 6, 0)
		InfoLayer.label({
			Text = glyph,
			Role = "number",
			TextSize = math.floor(KEY_SIZE * 0.68),
			Color = own,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(0, KEY_SIZE),
			AutomaticSize = Enum.AutomaticSize.X,
			Parent = box,
		})
	end
	table.insert(ui.parts, box)
end

local function addKey(glyph: string, order: number)
	if newMode then
		addKeyNew(glyph, order)
		return
	end
	local box = Style.rect({
		Name = "Key",
		Color = Style.White,
		Transparency = 0.85,
		Size = UDim2.fromOffset(if string.sub(glyph, 1, 1) == "@" then 24 else 0, 22),
		AutomaticSize = if string.sub(glyph, 1, 1) == "@" then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		LayoutOrder = order,
		Parent = ui.holder,
	})
	local st = Instance.new("UIStroke")
	st.Color = Style.Amber
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = box
	if string.sub(glyph, 1, 1) == "@" then
		Style.glyph(string.sub(glyph, 2), { Size = 12, Color = Style.Amber, Box = UDim2.fromScale(1, 1), Parent = box })
	else
		Theme.pad(box, 6, 0, 6, 0)
		Style.label({
			Text = glyph,
			TextSize = 15,
			Color = Style.Amber,
			XAlign = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X,
			Parent = box,
		})
	end
	table.insert(ui.parts, box)
end

local function render(e: Entry)
	clearParts()
	local glyph = glyphFor(e.key)
	local a, b = string.find(e.text, "{key}", 1, true)
	if e.key == "" then
		addText((string.gsub(e.text, "{key}", "")), 1) -- plain message, no key box
	elseif a then
		addText(string.sub(e.text, 1, a - 1), 1)
		addKey(glyph, 2)
		addText(string.sub(e.text, (b :: number) + 1), 3)
	else
		addKey(glyph, 1)
		addText(e.text, 2)
	end
end

local function top(): Entry?
	local best: Entry? = nil
	for _, e in entries do
		if not best or e.priority > best.priority or (e.priority == best.priority and e.serial > best.serial) then
			best = e
		end
	end
	return best
end

local function refresh(force: boolean?)
	if not built then
		return
	end
	local e = top()
	local on = visible and e ~= nil
	ui.holder.Visible = on
	ui.progress.back.Visible = on and e ~= nil and e.progress ~= nil
	if e and e.progress then
		ui.progress.set(e.progress)
	end
	if not e then
		shownId, shownSig = nil, ""
		return
	end
	local sig = e.text .. "|" .. e.key .. "|" .. mode
	if force or sig ~= shownSig then
		render(e)
	end
	if on and e.id ~= shownId then
		-- new prompt: a small pop
		ui.scale.Scale = 1.12
		Theme.tween(ui.scale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	shownId, shownSig = e.id, sig
end

function ContextPrompt.show(id: string, text: string, key: string, seconds: number?, priority: number?)
	build()
	local e = entries[id]
	if not e then
		serial += 1
		e = { id = id, text = text, key = key, until_ = nil, priority = priority or 1, serial = serial }
		entries[id] = e
	end
	e.text, e.key, e.priority = text, key, priority or e.priority
	e.until_ = if seconds then os.clock() + seconds else nil
	if seconds then
		local my = e
		task.delay(seconds + 0.02, function()
			if entries[id] == my and my.until_ and os.clock() >= my.until_ then
				entries[id] = nil
				refresh()
			end
		end)
	end
	refresh()
end

function ContextPrompt.hide(id: string)
	if entries[id] then
		entries[id] = nil
		refresh()
	end
end

function ContextPrompt.isShowing(id: string): boolean
	return entries[id] ~= nil
end

function ContextPrompt.setProgress(id: string, frac: number?)
	local e = entries[id]
	if not e then
		return
	end
	e.progress = if frac then math.clamp(frac, 0, 1) else nil
	if built and top() == e then
		ui.progress.back.Visible = visible and e.progress ~= nil
		if e.progress then
			ui.progress.set(e.progress)
		end
	end
end

function ContextPrompt.setVisible(on: boolean)
	visible = on
	refresh()
end

-- style switch: build the layer again for the new style and show the current prompt in it
InfoLayer.onRebuild(function()
	if not built then
		return -- built lazily on the first show()
	end
	if not newMode and not InfoLayer.isNew() then
		return -- old HUD before and after: nothing to rebuild
	end
	if ui.gui then
		ui.gui:Destroy()
	end
	ui = {}
	built = false
	shownId, shownSig = nil, ""
	build()
	refresh(true)
end)

mode = inputMode()
UserInputService.LastInputTypeChanged:Connect(function()
	local m = inputMode()
	if m ~= mode then
		mode = m
		refresh(true)
	end
end)

return ContextPrompt
