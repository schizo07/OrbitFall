-- First-time player hints: a small card at the top centre (under the alert stack, well above the crosshair and clear of
-- the phone buttons), one hint at a time, queued by priority, a few seconds each. The hint list, triggers and wording
-- live in shared/Data/Tips.luau; this module detects the triggers from state the client already has:
--   Store "me" (ammo, health, stims, stamina, downed, call-in holding), Store "squad", Store "intensity" (breach),
--   Store "mission" (state, extract), Store "objectives" (side markers), Store "holding", Player attribute CarryCell,
--   Fx "HeavyContact".
-- Counts are per session (no client-side persistence in Roblox). Text follows the active input (keyboard / gamepad /
-- touch) at the moment the card shows.
-- Studio A/B "TIPS" (workspace attribute Feel_Tips): nil = on, "early" = only during the first 3 minutes of combat
-- this session, "off" = never.
-- Studio test: workspace attribute DebugTip = "<id>" shows that hint now (ignores counts), then clears itself.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local TipData = require(Shared.Data.Tips)
local Weapons = require(Shared.Data.Weapons)
local Carry = require(Shared.Carry)
local DownedRules = require(Shared.Downed)

local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local InfoLayer = require(script.Parent.InfoLayer)
local Store = require(script.Parent.Parent.Store)
local Input = require(script.Parent.Parent.Input)

local Tips = {}

local EARLY_SECONDS = 180 -- Feel_Tips = "early"
local STALE = 25 -- a queued hint older than this is dropped (the moment has passed)
local GAP = 1.2 -- seconds between two cards
local POLL = 0.25

local player = Players.LocalPlayer
local ui: { [string]: any } = {}
local built = false

local counts: { [string]: number } = {}
local queued: { [string]: boolean } = {}
type Item = { tip: TipData.Tip, at: number, seq: number, vars: { [string]: string }? }
local queue: { Item } = {}
local seq = 0
local showing = false
local combatTime = 0
local lastShownAt = -100

-- ---------------------------------------------------------------- gating
local function mode(): string
	local ok, t = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	if ok and t == Enum.UserInputType.Touch then
		return "touch"
	end
	if ok and t and string.find(t.Name, "Gamepad") then
		return "pad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	end
	return "kb"
end

local function enabled(): boolean
	local v = workspace:GetAttribute("Feel_Tips")
	if v == "off" then
		return false
	end
	if v == "early" then
		return combatTime < EARLY_SECONDS
	end
	return true
end

local function inCombat(): boolean
	local m = Store.get("mission")
	local st = type(m) == "table" and m.state or nil
	return st == "Active" or st == "Extract"
end

local function canShow(): boolean
	return inCombat() and not Store.get("menuOpen")
end

-- ---------------------------------------------------------------- text
local function resolve(tip: TipData.Tip, vars: { [string]: string }?): string
	local m = mode()
	local slot = workspace:GetAttribute("Feel_UplinkArm") == "slot"
	local text: string
	if m == "touch" then
		text = tip.touch
	elseif m == "pad" then
		text = if slot and tip.padSlot then tip.padSlot else tip.pad
	else
		text = if slot and tip.kbSlot then tip.kbSlot else tip.kb
	end
	local press = if DownedRules.stimHold() > 0 then "Hold" else "Press"
	local interact = if Input.padInteractKey() == "@up" then "D-pad Up" else "X"
	text = string.gsub(text, "{press}", press)
	text = string.gsub(text, "{interact}", interact)
	if vars then
		for k, v in vars do
			text = string.gsub(text, "{" .. k .. "}", (string.gsub(v, "%%", "%%%%")))
		end
	end
	return text
end

-- ---------------------------------------------------------------- card
local function build()
	if built then
		return
	end
	built = true
	local touch = Theme.isTouch()
	local gui = Theme.gui("OrbitTips", { DisplayOrder = 11, Insets = "CoreUISafeInsets" })
	ui.gui = gui
	local root = Theme.root(gui, "hud")
	-- new layouts (UI STYLE A-C): one scale, no content x0.8; the card sits at HudLayout "tips" (phone y 110, under the feed)
	local isNew = InfoLayer.isNew()
	local content = if isNew then root else Style.content(root, touch)

	local group = Instance.new("CanvasGroup")
	group.Name = "TipCard"
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.AnchorPoint = Vector2.new(0.5, 0)
	group.Position = UDim2.fromScale(0.5, 0.24) -- under the alert stack (y 50 + ~100), far above the crosshair
	group.Size = UDim2.fromScale(0.36, 0)
	if isNew then
		InfoLayer.place(group, "tips", touch)
		group.Size = UDim2.new(group.Size.X.Scale, group.Size.X.Offset, 0, 0)
	end
	group.AutomaticSize = Enum.AutomaticSize.Y
	group.GroupTransparency = 1
	group.Visible = false
	group.Parent = content
	local lim = Instance.new("UISizeConstraint")
	lim.MinSize = Vector2.new(if isNew and touch then 200 else 300, 0)
	lim.MaxSize = Vector2.new(460, math.huge)
	lim.Parent = group
	ui.group = group

	local panel = Style.panel({
		Name = "Panel",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = group,
	})
	Theme.pad(panel, 10, 6, 10, 6)
	Theme.list(panel, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)

	local tag = Style.rect({
		Name = "Tag",
		Color = Style.Amber,
		Size = UDim2.fromOffset(34, 18),
		LayoutOrder = 1,
		Parent = panel,
	})
	Style.label({
		Text = "TIP",
		Color = Style.Black,
		TextSize = 12,
		XAlign = Enum.TextXAlignment.Center,
		Shadow = false,
		Size = UDim2.fromScale(1, 1),
		Parent = tag,
	})

	local text = Style.label({
		Name = "Text",
		Color = Style.White,
		TextSize = Style.TEXT + 1,
		Wrap = true,
		Size = UDim2.new(1, -42, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = panel,
	})
	ui.text = text
	ui.scale = Instance.new("UIScale")
	ui.scale.Parent = group
end

local showToken = 0
local function hideCard()
	showToken += 1
	local g = ui.group
	if g then
		g.Visible = false
		g.GroupTransparency = 1
	end
	showing = false
end

local pump: () -> ()

local function showCard(item: Item)
	build()
	showing = true
	lastShownAt = os.clock()
	local text = resolve(item.tip, item.vars)
	ui.text.Text = text
	showToken += 1
	local token = showToken
	local g = ui.group
	g.Visible = true
	g.GroupTransparency = 1
	ui.scale.Scale = 0.92
	Theme.tween(g, 0.2, { GroupTransparency = 0 })
	Theme.tween(ui.scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
	local hold = math.clamp(2.5 + #text * 0.05, 4.5, 8)
	task.delay(hold, function()
		if token ~= showToken then
			return
		end
		Theme.tween(g, 0.3, { GroupTransparency = 1 })
		task.wait(0.3)
		if token ~= showToken then
			return
		end
		g.Visible = false
		showing = false
		task.delay(GAP, pump)
	end)
end

pump = function()
	if showing or not canShow() or os.clock() - lastShownAt < GAP then
		return
	end
	while #queue > 0 do
		local item = table.remove(queue, 1) :: Item
		queued[item.tip.id] = nil
		if os.clock() - item.at > STALE or not enabled() then
			continue
		end
		if (counts[item.tip.id] or 0) >= item.tip.times then
			continue
		end
		counts[item.tip.id] = (counts[item.tip.id] or 0) + 1
		showCard(item)
		return
	end
end

local function push(tip: TipData.Tip, vars: { [string]: string }?, force: boolean?)
	if not force and (not enabled() or (counts[tip.id] or 0) >= tip.times or queued[tip.id]) then
		return
	end
	if force then
		counts[tip.id] = 0
		for i = #queue, 1, -1 do
			if queue[i].tip.id == tip.id then
				table.remove(queue, i)
			end
		end
	end
	seq += 1
	queued[tip.id] = true
	table.insert(queue, { tip = tip, at = os.clock(), seq = seq, vars = vars })
	table.sort(queue, function(a, b)
		local pa, pb = a.tip.priority or 1, b.tip.priority or 1
		if pa ~= pb then
			return pa > pb
		end
		return a.seq < b.seq
	end)
	pump()
end

-- Queue every hint with this trigger (respecting each one's delay and session count).
local function fire(trigger: string, vars: { [string]: string }?, skip: { [string]: boolean }?)
	if not enabled() then
		return
	end
	for _, tip in TipData.list do
		if tip.trigger ~= trigger or (counts[tip.id] or 0) >= tip.times or queued[tip.id] or (skip and skip[tip.id]) then
			continue
		end
		if tip.delay and tip.delay > 0 then
			queued[tip.id] = true -- reserve so a second trigger in the delay does not double it
			task.delay(tip.delay, function()
				queued[tip.id] = nil
				if inCombat() then
					push(tip, vars)
				end
			end)
		else
			push(tip, vars)
		end
	end
end

function Tips.fire(trigger: string)
	fire(trigger)
end

-- ---------------------------------------------------------------- detectors
local prev: { [string]: any } = {}

local function heldId(me: any): any
	local h = Store.get("holding")
	if h == nil and type(me) == "table" and type(me.callins) == "table" then
		h = me.callins.holding
	end
	return h
end

local function hasMainObjective(): boolean
	local objs = Store.get("objectives")
	if type(objs) ~= "table" then
		return false
	end
	for _, o in objs do
		if type(o) == "table" and o.main then
			return true
		end
	end
	return false
end

local function edge(key: string, value: boolean): boolean
	local was = prev[key]
	prev[key] = value
	return value and was == false
end

local sideSeen: { [any]: boolean } = {}

local function pollMe()
	local me = Store.get("me")
	if type(me) ~= "table" or me.alive == false then
		return
	end
	local now = workspace:GetServerTimeNow()
	local downed = me.downed == true
	if edge("downed", downed) then
		fire("downed")
	end
	-- ammo (weapon in hand)
	local ws = type(me.weapons) == "table" and me.weapons or nil
	local w = ws and type(me.weapon) == "number" and ws[me.weapon] or nil
	local def = type(w) == "table" and type(w.id) == "string" and Weapons.get(w.id) or nil
	local reloading = type(me.reloadUntil) == "number" and me.reloadUntil > now
	if def and type(def.mag) == "number" and def.mag >= 6 and type(w.mag) == "number" and not reloading then
		local low = w.mag > 0 and w.mag <= def.mag * 0.25
		if edge("lowMag", low) then
			fire("lowMag")
		end
		local dry = w.spare == 0 and w.mag <= def.mag * 0.5
		if edge("noSpare", dry) then
			fire("noSpare")
		end
	end
	-- health
	local hurt = not downed
		and type(me.hp) == "number"
		and type(me.maxHp) == "number"
		and me.maxHp > 0
		and me.hp > 0
		and me.hp / me.maxHp < 0.45
		and (me.stims or 0) > 0
	if edge("hurt", hurt) then
		fire("hurt")
	end
	if edge("exhausted", me.exhausted == true) then
		fire("exhausted")
	end
	if edge("armed", heldId(me) ~= nil) then
		fire("armed")
	end
end

local function pollSide()
	local objs = Store.get("objectives")
	local c = player.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if type(objs) ~= "table" or not hrp then
		return
	end
	for _, o in objs do
		if type(o) ~= "table" or o.main or o.done or typeof(o.marker) ~= "Vector3" then
			continue
		end
		local key = o.id or o.title
		if key == nil or sideSeen[key] then
			continue
		end
		if (o.marker - hrp.Position).Magnitude <= TipData.SIDE_RANGE then
			sideSeen[key] = true
			fire("side", { title = tostring(o.title or "side objective") })
			return
		end
	end
end

local function onMission(m: any)
	local st = type(m) == "table" and m.state or nil
	local wasActive = prev.missionState == "Active" or prev.missionState == "Extract"
	if st == "Active" and not wasActive then
		sideSeen = {}
		-- wait a moment for the objectives list, then queue the start hints (objective hint only with a main objective)
		task.delay(1, function()
			if not inCombat() then
				return
			end
			fire("start", nil, if hasMainObjective() then nil else { objective = true }) -- test arena: no objective
		end)
	end
	if st ~= "Active" and st ~= "Extract" then
		table.clear(queue)
		table.clear(queued)
		hideCard()
	end
	prev.missionState = st
	local ex = type(m) == "table" and m.extract or nil
	if edge("extract", st == "Extract" and ex == nil) then
		fire("extract")
	end
	if edge("board", type(ex) == "table" and ex.window ~= nil) then
		fire("board")
	end
end

local function onSquad(squad: any)
	if type(squad) ~= "table" then
		return
	end
	for _, m in squad do
		if type(m) ~= "table" or type(m.userId) ~= "number" or m.userId == player.UserId then
			continue
		end
		local k = tostring(m.userId)
		if edge("mateDown" .. k, m.downed == true) then
			fire("mateDown")
		end
		if edge("mateOut" .. k, m.alive == false and m.downed ~= true) then
			fire("mateOut")
		end
	end
end

-- ---------------------------------------------------------------- init
function Tips.init(fx: any)
	if prev.inited then
		return
	end
	prev.inited = true
	build()
	Store.on("mission", onMission)
	Store.on("squad", onSquad)
	Store.on("intensity", function(s: any)
		if edge("breach", type(s) == "table" and s.state == "breach") then
			fire("breach")
		end
	end)
	prev.cell = player:GetAttribute(Carry.ATTR) == true
	player:GetAttributeChangedSignal(Carry.ATTR):Connect(function()
		if edge("cell", player:GetAttribute(Carry.ATTR) == true) then
			fire("cell")
		end
	end)
	if type(fx) == "table" and fx.register then
		fx.register("HeavyContact", function(d: any)
			if type(d) == "table" and (d.class == "heavy" or d.class == "behemoth") then
				fire("heavy")
			end
		end)
	end
	if RunService:IsStudio() then
		workspace:GetAttributeChangedSignal("DebugTip"):Connect(function()
			local id = workspace:GetAttribute("DebugTip")
			if type(id) ~= "string" or id == "" then
				return
			end
			workspace:SetAttribute("DebugTip", nil)
			local tip = TipData.byId[id]
			if tip then
				push(tip, { title = "Test side objective" }, true)
			else
				warn("[Tips] no hint with id", id)
			end
		end)
	end
	task.spawn(function()
		local sideAcc = 0
		while true do
			task.wait(POLL)
			if inCombat() then
				combatTime += POLL
				local ok, err = pcall(pollMe)
				if not ok then
					warn("[Tips] poll failed:", err)
				end
				sideAcc += POLL
				if sideAcc >= 0.5 then
					sideAcc = 0
					pcall(pollSide)
				end
			end
			if showing and (not canShow() or not enabled()) then
				hideCard()
			end
			if not showing and #queue > 0 then
				pump()
			end
		end
	end)
end

-- UI STYLE switch: build the card again in the new style / place (a tip on screen is dropped; the queue carries on)
InfoLayer.onRebuild(function(ctx: any)
	if (type(ctx) == "table" and ctx.first) or not built then
		return
	end
	hideCard()
	if ui.gui then
		ui.gui:Destroy()
	end
	ui = {}
	built = false
	build()
	task.delay(GAP, pump)
end)

return Tips
