--!nonstrict
-- Where every element of the new in-mission HUD sits (the three new UI STYLE skins share it; the old HUD ignores it).
-- Values are layout px inside a Theme.root(gui, "hud") frame with NO Style.content 0.8 and NO boosts: one scale,
-- Theme.scaleFor("hud"). Designed on a 1920 x 1080 PC (layout px = final / 1.07) and the 800 x 380 reference phone
-- (layout px = final / 0.81); anchors use screen-relative scale so other sizes follow.
--
--   HudLayout.get(name, touch) -> entry   entry.Position / AnchorPoint / Size are ready to assign; other fields are
--                                         extra numbers for that element (text sizes, gaps, line counts, ...)
--   HudLayout.apply(inst, name, touch)    assigns Position, AnchorPoint and Size
--   HudLayout.NAMES                       every name
--
-- Names: compass, goal, progress, side, alert, tips, timer, reinforce, feed, squad, callinCards, callins, health,
-- weapon, stamina, prompt, satellites, downed, sheet, clearBox
local HudLayout = {}

local function pc(v: number): number
	return math.round(v / 1.07)
end
local function ph(v: number): number
	return math.round(v / 0.81)
end

local PC = {
	-- top centre
	compass = {
		Position = UDim2.new(0.5, 0, 0, pc(22)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.new(0.29, 0, 0, pc(18)),
		HeadingSize = pc(14),
	},
	goal = {
		Position = UDim2.new(0.5, 0, 0, pc(48)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(720), pc(30)),
		MaxWidth = pc(720),
		TextSize = pc(26),
		DistSize = pc(22),
		CaretSize = pc(14),
		HitHeight = pc(30),
	},
	progress = {
		Position = UDim2.new(0.5, 0, 0, pc(80)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(500), 2),
		Height = 2,
	},
	side = {
		Position = UDim2.new(0.5, 0, 0, pc(90)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(600), pc(20)),
		MaxWidth = pc(600),
		TextSize = pc(16),
		NextGap = pc(4), -- GOAL LINES B: the next-step rows stack under the side line with this gap
	},
	alert = {
		Position = UDim2.new(0.5, 0, 0, pc(118)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(520), pc(28)),
		BarHeight = pc(28),
		TextSize = pc(18),
		CalloutHeight = pc(22),
	},
	tips = {
		Position = UDim2.fromScale(0.5, 0.24),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.3, 0),
	},
	-- top right
	timer = {
		Position = UDim2.new(1, -pc(24), 0, pc(22)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(100), pc(26)),
		TextSize = pc(22),
	},
	reinforce = {
		-- right edge of "v3" sits this far left of the timer's left edge (timer is auto width)
		Gap = pc(18),
		Position = UDim2.new(1, -pc(24 + 100 + 18), 0, pc(24)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(60), pc(22)),
		TextSize = pc(18),
	},
	-- right mid
	feed = {
		Position = UDim2.new(1, -pc(24), 0, pc(380)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(360), pc(6 * 22 + 5 * 8)),
		Lines = 6,
		LineHeight = pc(22),
		Gap = pc(8),
		TextSize = pc(16),
		GlyphGap = pc(10),
		Life = 6,
		FadeTime = 0.4,
	},
	-- left mid
	squad = {
		Position = UDim2.fromOffset(pc(24), pc(420)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(260), pc(180)),
		RowCollapsed = pc(14),
		RowOpen = pc(34),
		TagSize = pc(16),
		StatusSize = pc(13),
		HpHeight = 3,
	},
	callinCards = {
		Position = UDim2.fromOffset(pc(24), pc(300)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(260), pc(110)),
		CardHeight = pc(34),
		Max = 3,
	},
	-- bottom left (bottom offsets measured from the screen's bottom edge)
	callins = {
		Position = UDim2.new(0, pc(24), 1, -pc(1080 - 968 - 36)),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(pc(5 * 36 + 4 * 8), pc(36)),
		Icon = pc(36),
		Gap = pc(8),
		-- expanded while the uplink key is held: rows grow upward from the strip's top to y 700
		ExpandedWidth = pc(260),
		ExpandedTop = pc(700),
		NameSize = pc(15),
	},
	health = {
		Position = UDim2.new(0, pc(24), 1, -pc(1080 - 1010 - 10)),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(pc(360), pc(10)),
		PipsX = pc(392 - 24), -- stim pips start this far right of the bar's left edge
		PipSize = pc(10),
		PipGap = pc(4),
	},
	weapon = {
		Position = UDim2.new(1, -pc(24), 1, -pc(24)),
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(pc(320), pc(110)),
		NameSize = pc(16),
		ModeSize = pc(13),
		MagSize = pc(52),
		SpareSize = pc(22),
		CountSize = pc(16),
		GlyphSize = pc(12),
	},
	stamina = {
		-- StaminaBar is drawn in raw px (its own Insets = None gui); kept as today
		Position = UDim2.new(0.5, 0, 1, -28),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(270, 3),
	},
	prompt = {
		Position = UDim2.new(0.5, 0, 0.5, pc(780 - 540)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(400), pc(28)),
		MaxWidth = pc(400),
		TextSize = pc(20),
		KeySize = pc(24),
	},
	-- crosshair layer is raw px (OrbitCrosshair, Insets None): offsets from the crosshair centre, final px
	satellites = {
		Position = UDim2.fromOffset(38, 22),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(60, 18),
		MagOffset = Vector2.new(38, 22),
		TextSize = 15,
		ArcRadius = 34,
		ArcWidth = 3,
	},
	downed = {
		-- DownedFx panel: raw px under the crosshair (kept), size for the new skins
		Position = UDim2.new(0.5, 0, 0.5, 70),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(300, 58),
	},
	sheet = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(pc(900), pc(560)),
		RowSize = pc(18),
		TitleSize = pc(28),
		CloseSize = pc(44),
	},
	-- nothing but the crosshair layer, the downed panel and the context prompt inside it (final px at 1920 x 1080)
	clearBox = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(pc(400), pc(300)),
	},
}

local PHONE = {
	compass = {
		Position = UDim2.new(0.5, 0, 0, ph(8)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(240), ph(10)),
		HeadingSize = ph(12),
	},
	-- The column under the compass starts below its heading readout (tape bottom ph(18) + the 16 px chip) and sits left
	-- of centre (x 0.44, tips 0.42): the touch cluster's CROUCH / STIM column reaches to about 64 % of the width on
	-- 680-830 px phones (measured on the S22 Ultra, iPhone 17 Pro / 16 Pro Max).
	goal = {
		-- the text is 14 px; the tap box (mission sheet) is 44 px tall around it
		Position = UDim2.new(0.44, 0, 0, ph(34)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(300), ph(18)),
		MaxWidth = ph(300),
		TextSize = ph(14),
		DistSize = ph(12),
		CaretSize = ph(10),
		HitHeight = ph(44),
	},
	progress = {
		Position = UDim2.new(0.44, 0, 0, ph(52)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(220), 2),
		Height = 2,
	},
	side = {
		-- phones have no room for a side line under the goal; it shares the feed rows
		Position = UDim2.new(0.44, 0, 0, ph(82)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(280), ph(15)),
		MaxWidth = ph(280),
		TextSize = ph(12),
		NextGap = ph(2),
	},
	alert = {
		Position = UDim2.new(0.44, 0, 0, ph(58)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(280), ph(20)),
		BarHeight = ph(20),
		TextSize = ph(12),
		CalloutHeight = ph(16),
	},
	tips = {
		-- no room above the crosshair on short phones: just under it, left of centre, clear of SPRINT / UPLINK on the
		-- right and above the downed panel. The crosshair is at the screen centre, ~29 px above 50 % of this inset frame.
		Position = UDim2.new(0.42, 0, 0.5, ph(2)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(280), 0),
	},
	timer = {
		Position = UDim2.new(1, -ph(10), 0, ph(8)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(ph(56), ph(16)),
		TextSize = ph(14),
	},
	reinforce = {
		Gap = ph(6),
		Position = UDim2.new(1, -ph(10 + 56 + 6), 0, ph(8)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(ph(30), ph(16)),
		TextSize = ph(12),
	},
	feed = {
		Position = UDim2.new(0.44, 0, 0, ph(82)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(280), ph(2 * 15 + 2)),
		Lines = 2,
		LineHeight = ph(15),
		Gap = ph(2),
		TextSize = ph(12),
		GlyphGap = ph(6),
		Life = 4,
		FadeTime = 0.4,
	},
	squad = {
		Position = UDim2.fromOffset(ph(10), ph(76)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(150), ph(48)),
		RowCollapsed = ph(16),
		RowOpen = ph(16),
		TagSize = ph(12),
		StatusSize = ph(12),
		HpHeight = 2,
		Compact = true,
	},
	callinCards = {
		-- left edge under the squad strip: inside the thumbstick zone, so only other troopers' arming shows here
		Position = UDim2.fromOffset(ph(10), ph(130)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(170), ph(80)),
		CardHeight = ph(24),
		Max = 2,
	},
	callins = {
		Position = UDim2.fromOffset(ph(10), ph(44)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(5 * 26 + 4 * 4), ph(26)),
		Icon = ph(26),
		Gap = ph(4),
		ExpandedWidth = 0, -- never expands on touch: the radial dial covers it
		ExpandedTop = 0,
		NameSize = ph(12),
	},
	health = {
		Position = UDim2.fromOffset(ph(10), ph(8)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(150), ph(6)),
		PipsX = ph(156),
		PipSize = ph(8),
		PipGap = ph(3),
	},
	weapon = {
		-- one compact row under the health bar: mag, spare, grenades (name hidden)
		Position = UDim2.fromOffset(ph(10), ph(18)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(190), ph(22)),
		NameSize = 0,
		ModeSize = ph(12),
		MagSize = ph(18),
		SpareSize = ph(12),
		CountSize = ph(12),
		GlyphSize = ph(8),
		Compact = true,
	},
	stamina = {
		Position = UDim2.new(0.5, 0, 1, -28),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(270, 3),
	},
	prompt = {
		-- centred at 40 % of the width (the longest prompt, HOLD CROUCH, ends left of the SIDE chip on 680-830 px phones)
		Position = UDim2.new(0.4, 0, 1, -ph(50)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(200), ph(22)),
		MaxWidth = ph(200),
		TextSize = ph(14),
		KeySize = ph(18),
	},
	satellites = {
		Position = UDim2.fromOffset(26, 14),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(44, 14),
		MagOffset = Vector2.new(26, 14),
		TextSize = 12,
		ArcRadius = 22,
		ArcWidth = 2,
	},
	downed = {
		Position = UDim2.new(0.5, 0, 0.5, 60),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(250, 58), -- the panel's rows need 58 px; the root scale (0.81) brings it to ~47 px
	},
	sheet = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(640), ph(320)),
		RowSize = ph(13),
		TitleSize = ph(18),
		CloseSize = ph(44),
	},
	clearBox = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(200), ph(140)),
	},
}

HudLayout.PC = PC
HudLayout.PHONE = PHONE
HudLayout.NAMES = {}
for name in PC do
	table.insert(HudLayout.NAMES, name)
end
table.sort(HudLayout.NAMES)

local EMPTY = {
	Position = UDim2.fromOffset(0, 0),
	AnchorPoint = Vector2.new(0, 0),
	Size = UDim2.fromOffset(0, 0),
}

function HudLayout.get(name: string, touch: boolean): { [string]: any }
	local t = if touch then PHONE else PC
	local e = t[name] or PC[name]
	if not e then
		warn("HudLayout: no entry " .. tostring(name))
		return EMPTY
	end
	return e
end

function HudLayout.apply(inst: GuiObject, name: string, touch: boolean)
	local e = HudLayout.get(name, touch)
	inst.AnchorPoint = e.AnchorPoint
	inst.Position = e.Position
	inst.Size = e.Size
end

return HudLayout
