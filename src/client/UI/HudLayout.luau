--!nonstrict
-- Where every element of the new in-mission HUD sits across the 3 Studio-switchable HUD presets:
--   "bold"  (A, live default): current layout, ~1.6x bigger text, ~1.5x taller banners with stronger backing, bigger margins
--   "clean" (B): fewer elements, big centred objective banner at top, smaller compass, side panels as compact chips
--   "frame" (C): solid docked top bar (compass + objective + timer) and bottom bar (vitals + call-ins + weapon), high contrast
--
-- Values are layout px inside a Theme.root(gui, "hud") frame.
--   HudLayout.preset() -> "bold" | "clean" | "frame"
--   HudLayout.get(name, touch) -> entry
--   HudLayout.apply(inst, name, touch)
--   HudLayout.phoneBottomWidth() -> number (layout px safe width left of MobileControls)
local Theme = require(script.Parent.Theme)

local HudLayout = {}

local ATTR = "Feel_HudPreset"
HudLayout.ATTR = ATTR

local VALID_PRESETS = { clean = true, frame = true }

function HudLayout.preset(): string
	local v = workspace:GetAttribute(ATTR)
	return if type(v) == "string" and VALID_PRESETS[v] then v else "bold"
end

local function pc(v: number): number
	return math.round(v / 1.07)
end
local function ph(v: number): number
	return math.round(v / 0.81)
end

-- Safe width (in HUD layout px) on the bottom-left of a phone so Frame's bottom bar never overlaps MobileControls.
-- MobileControls' leftmost button (Shoulder) extends to 342 mobile-px from the right edge.
function HudLayout.phoneBottomWidth(): number
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(800, 380)
	local mobScale = Theme.clamp(vp.Y / 420, 1, 1.4)
	local hudScale = math.max(Theme.scaleFor("hud"), 0.01)
	local safeReal = math.max(220, vp.X - 356 * mobScale)
	return math.floor(safeReal / hudScale)
end

-- Preset A: Bold ------------------------------------------------------------------------------------------------------
local BOLD_PC = {
	compass = {
		Position = UDim2.new(0.5, 0, 0, pc(32)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.new(0.30, 0, 0, pc(28)),
		HeadingSize = pc(22),
		CardinalSize = pc(22),
		InterSize = pc(18),
	},
	goal = {
		Position = UDim2.new(0.5, 0, 0, pc(90)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(840), pc(52)),
		MaxWidth = pc(840),
		BannerHeight = pc(52),
		TextSize = pc(36),
		DistSize = pc(30),
		CaretSize = pc(20),
		HitHeight = pc(52),
		ProgressHeight = 4,
	},
	progress = {
		Position = UDim2.new(0.5, 0, 0, pc(146)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(580), 4),
		Height = 4,
	},
	side = {
		Position = UDim2.new(0.5, 0, 0, pc(154)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(760), pc(28)),
		MaxWidth = pc(760),
		TextSize = pc(24),
		NextGap = pc(6),
	},
	alert = {
		Position = UDim2.new(0.5, 0, 0, pc(190)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(680), pc(46)),
		BarHeight = pc(46),
		TextSize = pc(28),
		SubSize = pc(23),
		CalloutHeight = pc(34),
	},
	tips = {
		Position = UDim2.fromScale(0.5, 0.27),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.36, 0),
		TextSize = pc(23),
	},
	timer = {
		Position = UDim2.new(1, -pc(40), 0, pc(34)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(150), pc(42)),
		TextSize = pc(34),
	},
	reinforce = {
		Gap = pc(20),
		Position = UDim2.new(1, -pc(40 + 150 + 20), 0, pc(36)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(86), pc(36)),
		TextSize = pc(28),
	},
	feed = {
		Position = UDim2.new(1, -pc(40), 0, pc(370)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(480), pc(6 * 32 + 5 * 8)),
		Lines = 6,
		LineHeight = pc(32),
		Gap = pc(8),
		TextSize = pc(24),
		GlyphGap = pc(12),
		Life = 6,
		FadeTime = 0.4,
	},
	squad = {
		Position = UDim2.fromOffset(pc(40), pc(450)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(360), pc(240)),
		RowCollapsed = pc(28),
		RowOpen = pc(56),
		TagSize = pc(24),
		StatusSize = pc(23),
		HpHeight = 4,
	},
	callinCards = {
		Position = UDim2.fromOffset(pc(40), pc(280)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(360), pc(160)),
		CardHeight = pc(50),
		Max = 3,
	},
	callins = {
		Position = UDim2.new(0, pc(40), 1, -pc(84)),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(pc(5 * 48 + 4 * 10), pc(48)),
		Icon = pc(48),
		Gap = pc(10),
		ExpandedWidth = pc(360),
		ExpandedTop = pc(620),
		NameSize = pc(23),
	},
	health = {
		Position = UDim2.new(0, pc(40), 1, -pc(40)),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(pc(400), pc(14)),
		PipsX = pc(414),
		PipSize = pc(15),
		PipGap = pc(6),
	},
	weapon = {
		Position = UDim2.new(1, -pc(40), 1, -pc(40)),
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(pc(460), pc(154)),
		NameSize = pc(24),
		ModeSize = pc(23),
		MagSize = pc(72),
		SpareSize = pc(34),
		CountSize = pc(24),
		GlyphSize = pc(16),
	},
	stamina = {
		Position = UDim2.new(0.5, 0, 1, -28),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(270, 4),
	},
	prompt = {
		Position = UDim2.new(0.5, 0, 0.5, pc(240)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(560), pc(42)),
		MaxWidth = pc(560),
		TextSize = pc(28),
		KeySize = pc(34),
	},
	satellites = {
		Position = UDim2.fromOffset(42, 24),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(72, 22),
		MagOffset = Vector2.new(42, 24),
		TextSize = 18,
		ArcRadius = 36,
		ArcWidth = 3,
	},
	downed = {
		Position = UDim2.new(0.5, 0, 0.5, 70),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(320, 62),
	},
	sheet = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(pc(1020), pc(640)),
		RowSize = pc(24),
		TitleSize = pc(34),
		CloseSize = pc(48),
	},
	clearBox = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(pc(400), pc(300)),
	},
}

local BOLD_PHONE = {
	compass = {
		Position = UDim2.new(0.48, 0, 0, ph(12)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(220), ph(18)),
		HeadingSize = ph(15),
		CardinalSize = ph(15),
		InterSize = ph(13),
	},
	goal = {
		Position = UDim2.new(0.44, 0, 0, ph(46)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(330), ph(32)),
		MaxWidth = ph(330),
		BannerHeight = ph(32),
		TextSize = ph(19),
		DistSize = ph(16),
		CaretSize = ph(13),
		HitHeight = ph(46),
		ProgressHeight = 3,
	},
	progress = {
		Position = UDim2.new(0.44, 0, 0, ph(80)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(250), 3),
		Height = 3,
	},
	side = {
		Position = UDim2.new(0.44, 0, 0, ph(112)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(300), ph(20)),
		MaxWidth = ph(300),
		TextSize = ph(15),
		NextGap = ph(3),
	},
	alert = {
		Position = UDim2.new(0.44, 0, 0, ph(84)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(330), ph(30)),
		BarHeight = ph(30),
		TextSize = ph(17),
		SubSize = ph(15),
		CalloutHeight = ph(22),
	},
	tips = {
		Position = UDim2.new(0.42, 0, 0.5, ph(2)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(300), 0),
		TextSize = ph(16),
	},
	timer = {
		Position = UDim2.new(1, -ph(14), 0, ph(10)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(ph(80), ph(24)),
		TextSize = ph(19),
	},
	reinforce = {
		Gap = ph(8),
		Position = UDim2.new(1, -ph(14 + 80 + 8), 0, ph(10)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(ph(46), ph(22)),
		TextSize = ph(16),
	},
	feed = {
		Position = UDim2.new(0.44, 0, 0, ph(122)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(300), ph(2 * 22 + 4)),
		Lines = 2,
		LineHeight = ph(22),
		Gap = ph(4),
		TextSize = ph(15),
		GlyphGap = ph(8),
		Life = 4,
		FadeTime = 0.4,
	},
	squad = {
		Position = UDim2.fromOffset(ph(14), ph(96)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(178), ph(72)),
		RowCollapsed = ph(20),
		RowOpen = ph(20),
		TagSize = ph(15),
		StatusSize = ph(15),
		HpHeight = 3,
		Compact = true,
	},
	callinCards = {
		Position = UDim2.fromOffset(ph(14), ph(174)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(195), ph(80)),
		CardHeight = ph(30),
		Max = 2,
	},
	callins = {
		Position = UDim2.fromOffset(ph(14), ph(60)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(5 * 30 + 4 * 5), ph(30)),
		Icon = ph(30),
		Gap = ph(5),
		ExpandedWidth = 0,
		ExpandedTop = 0,
		NameSize = ph(15),
	},
	health = {
		Position = UDim2.fromOffset(ph(14), ph(12)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(156), ph(9)),
		PipsX = ph(164),
		PipSize = ph(10),
		PipGap = ph(4),
	},
	weapon = {
		Position = UDim2.fromOffset(ph(14), ph(26)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(240), ph(28)),
		NameSize = 0,
		ModeSize = ph(15),
		MagSize = ph(22),
		SpareSize = ph(16),
		CountSize = ph(15),
		GlyphSize = ph(10),
		Compact = true,
	},
	stamina = {
		Position = UDim2.new(0.4, 0, 1, -28),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(230, 4),
	},
	prompt = {
		Position = UDim2.new(0.38, 0, 1, -ph(54)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(245), ph(30)),
		MaxWidth = ph(245),
		TextSize = ph(17),
		KeySize = ph(20),
	},
	satellites = {
		Position = UDim2.fromOffset(28, 16),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(54, 18),
		MagOffset = Vector2.new(28, 16),
		TextSize = 14,
		ArcRadius = 24,
		ArcWidth = 2,
	},
	downed = {
		Position = UDim2.new(0.5, 0, 0.5, 60),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(250, 58),
	},
	sheet = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(660), ph(340)),
		RowSize = ph(16),
		TitleSize = ph(22),
		CloseSize = ph(46),
	},
	clearBox = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(200), ph(140)),
	},
}

-- Preset B: Clean -----------------------------------------------------------------------------------------------------
-- Big centred objective banner at the top, smaller compass below it, side panels collapsed into compact chips, large text.
local CLEAN_PC = {
	compass = {
		Position = UDim2.new(0.5, 0, 0, pc(84)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.new(0.18, 0, 0, pc(22)),
		HeadingSize = pc(22),
		CardinalSize = pc(22),
		InterSize = pc(18),
		Compact = true,
	},
	goal = {
		Position = UDim2.new(0.5, 0, 0, pc(18)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(780), pc(56)),
		MaxWidth = pc(780),
		BannerHeight = pc(56),
		TextSize = pc(38),
		DistSize = pc(30),
		CaretSize = pc(20),
		HitHeight = pc(56),
		ProgressHeight = 4,
		HideNext = true,
	},
	progress = {
		Position = UDim2.new(0.5, 0, 0, pc(76)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(560), 4),
		Height = 4,
	},
	side = {
		Position = UDim2.new(0.5, 0, 0, pc(114)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(680), pc(26)),
		MaxWidth = pc(680),
		TextSize = pc(23),
		NextGap = pc(4),
	},
	alert = {
		Position = UDim2.new(0.5, 0, 0, pc(142)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(600), pc(42)),
		BarHeight = pc(42),
		TextSize = pc(26),
		SubSize = pc(22),
		CalloutHeight = pc(32),
	},
	tips = {
		Position = UDim2.fromScale(0.5, 0.25),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.34, 0),
		TextSize = pc(23),
	},
	timer = {
		Position = UDim2.new(1, -pc(28), 0, pc(20)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(140), pc(40)),
		TextSize = pc(30),
		Chip = true,
	},
	reinforce = {
		Gap = pc(14),
		Position = UDim2.new(1, -pc(28 + 140 + 14), 0, pc(20)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(84), pc(40)),
		TextSize = pc(26),
	},
	feed = {
		Position = UDim2.new(1, -pc(28), 0, pc(400)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(420), pc(3 * 30 + 2 * 8)),
		Lines = 3,
		LineHeight = pc(30),
		Gap = pc(8),
		TextSize = pc(23),
		GlyphGap = pc(10),
		Life = 4,
		FadeTime = 0.35,
	},
	squad = {
		Position = UDim2.fromOffset(pc(28), pc(450)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(220), pc(180)),
		RowCollapsed = pc(34),
		RowOpen = pc(34),
		TagSize = pc(23),
		StatusSize = pc(22),
		HpHeight = 3,
		ChipMode = true,
	},
	callinCards = {
		Position = UDim2.fromOffset(pc(28), pc(330)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(320), pc(100)),
		CardHeight = pc(42),
		Max = 2,
	},
	callins = {
		Position = UDim2.new(0, pc(28), 1, -pc(70)),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(pc(5 * 42 + 4 * 8), pc(42)),
		Icon = pc(42),
		Gap = pc(8),
		ExpandedWidth = pc(320),
		ExpandedTop = pc(640),
		NameSize = pc(22),
		Chip = true,
	},
	health = {
		Position = UDim2.new(0, pc(28), 1, -pc(28)),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(pc(320), pc(14)),
		PipsX = pc(336),
		PipSize = pc(24),
		PipGap = pc(6),
		ShowChip = true,
	},
	weapon = {
		Position = UDim2.new(1, -pc(28), 1, -pc(28)),
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(pc(380), pc(110)),
		NameSize = 0,
		ModeSize = pc(22),
		MagSize = pc(68),
		SpareSize = pc(32),
		CountSize = pc(24),
		GlyphSize = pc(15),
		ChipCounts = true,
	},
	stamina = BOLD_PC.stamina,
	prompt = {
		Position = UDim2.new(0.5, 0, 0.5, pc(230)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(500), pc(40)),
		MaxWidth = pc(500),
		TextSize = pc(26),
		KeySize = pc(32),
	},
	satellites = BOLD_PC.satellites,
	downed = BOLD_PC.downed,
	sheet = BOLD_PC.sheet,
	clearBox = BOLD_PC.clearBox,
}

local CLEAN_PHONE = {
	compass = {
		Position = UDim2.new(0.45, 0, 0, ph(50)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(165), ph(16)),
		HeadingSize = ph(15),
		CardinalSize = ph(15),
		InterSize = ph(13),
		Compact = true,
	},
	goal = {
		Position = UDim2.new(0.45, 0, 0, ph(10)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(330), ph(34)),
		MaxWidth = ph(330),
		BannerHeight = ph(34),
		TextSize = ph(19),
		DistSize = ph(16),
		CaretSize = ph(13),
		HitHeight = ph(46),
		ProgressHeight = 3,
		HideNext = true,
	},
	progress = {
		Position = UDim2.new(0.45, 0, 0, ph(46)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(240), 3),
		Height = 3,
	},
	side = BOLD_PHONE.side,
	alert = {
		Position = UDim2.new(0.44, 0, 0, ph(90)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(320), ph(28)),
		BarHeight = ph(28),
		TextSize = ph(16),
		SubSize = ph(15),
		CalloutHeight = ph(22),
	},
	tips = BOLD_PHONE.tips,
	timer = {
		Position = UDim2.new(1, -ph(12), 0, ph(10)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(ph(84), ph(24)),
		TextSize = ph(18),
		Chip = true,
	},
	reinforce = {
		Gap = ph(6),
		Position = UDim2.new(1, -ph(12 + 84 + 6), 0, ph(10)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(ph(46), ph(24)),
		TextSize = ph(16),
	},
	feed = {
		Position = UDim2.new(0.44, 0, 0, ph(124)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(290), ph(2 * 22 + 4)),
		Lines = 2,
		LineHeight = ph(22),
		Gap = ph(4),
		TextSize = ph(15),
		GlyphGap = ph(8),
		Life = 3.5,
		FadeTime = 0.35,
	},
	squad = {
		Position = UDim2.fromOffset(ph(12), ph(92)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(150), ph(84)),
		RowCollapsed = ph(24),
		RowOpen = ph(24),
		TagSize = ph(15),
		StatusSize = ph(15),
		HpHeight = 2,
		Compact = true,
		ChipMode = true,
	},
	callinCards = {
		Position = UDim2.fromOffset(ph(12), ph(180)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(180), ph(66)),
		CardHeight = ph(28),
		Max = 2,
	},
	callins = {
		Position = UDim2.fromOffset(ph(12), ph(56)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(5 * 28 + 4 * 5), ph(28)),
		Icon = ph(28),
		Gap = ph(5),
		ExpandedWidth = 0,
		ExpandedTop = 0,
		NameSize = ph(15),
		Chip = true,
	},
	health = {
		Position = UDim2.fromOffset(ph(12), ph(10)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(136), ph(9)),
		PipsX = ph(144),
		PipSize = ph(16),
		PipGap = ph(4),
		ShowChip = true,
	},
	weapon = {
		Position = UDim2.fromOffset(ph(12), ph(24)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(235), ph(26)),
		NameSize = 0,
		ModeSize = ph(15),
		MagSize = ph(22),
		SpareSize = ph(16),
		CountSize = ph(15),
		GlyphSize = ph(10),
		Compact = true,
		ChipCounts = true,
	},
	stamina = BOLD_PHONE.stamina,
	prompt = BOLD_PHONE.prompt,
	satellites = BOLD_PHONE.satellites,
	downed = BOLD_PHONE.downed,
	sheet = BOLD_PHONE.sheet,
	clearBox = BOLD_PHONE.clearBox,
}

-- Preset C: Frame -----------------------------------------------------------------------------------------------------
-- Docked to solid high-contrast edge bars (top: compass + objective + timer; bottom: vitals + call-ins + weapon).
local FRAME_PC = {
	topBar = {
		Height = pc(72),
	},
	bottomBar = {
		Height = pc(80),
	},
	compass = {
		Position = UDim2.new(0, pc(24), 0, pc(24)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(0.22, 0, 0, pc(24)),
		HeadingSize = pc(22),
		CardinalSize = pc(22),
		InterSize = pc(18),
		HeadingBeside = true,
	},
	goal = {
		Position = UDim2.new(0.53, 0, 0, pc(36)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(pc(720), pc(48)),
		MaxWidth = pc(720),
		BannerHeight = pc(48),
		TextSize = pc(32),
		DistSize = pc(26),
		CaretSize = pc(18),
		HitHeight = pc(56),
		ProgressHeight = 3,
		HideNext = true,
		Docked = true,
	},
	progress = {
		Position = UDim2.new(0.53, 0, 0, pc(66)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(560), 3),
		Height = 3,
	},
	side = {
		Position = UDim2.new(0.53, 0, 0, pc(76)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(680), pc(26)),
		MaxWidth = pc(680),
		TextSize = pc(23),
		NextGap = pc(4),
	},
	alert = {
		Position = UDim2.new(0.5, 0, 0, pc(82)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(640), pc(42)),
		BarHeight = pc(42),
		TextSize = pc(26),
		SubSize = pc(22),
		CalloutHeight = pc(32),
	},
	tips = {
		Position = UDim2.fromScale(0.5, 0.24),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromScale(0.34, 0),
		TextSize = pc(23),
	},
	timer = {
		Position = UDim2.new(1, -pc(24), 0, pc(36)),
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(pc(140), pc(40)),
		TextSize = pc(30),
	},
	reinforce = {
		Gap = pc(16),
		Position = UDim2.new(1, -pc(24 + 140 + 16), 0, pc(36)),
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(pc(80), pc(36)),
		TextSize = pc(25),
	},
	feed = {
		Position = UDim2.new(1, -pc(24), 0, pc(96)),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(pc(460), pc(5 * 30 + 4 * 6)),
		Lines = 5,
		LineHeight = pc(30),
		Gap = pc(6),
		TextSize = pc(23),
		GlyphGap = pc(10),
		Life = 5,
		FadeTime = 0.35,
	},
	squad = {
		Position = UDim2.fromOffset(pc(24), pc(96)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(330), pc(220)),
		RowCollapsed = pc(28),
		RowOpen = pc(52),
		TagSize = pc(23),
		StatusSize = pc(22),
		HpHeight = 4,
	},
	callinCards = {
		Position = UDim2.fromOffset(pc(24), pc(270)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(pc(330), pc(150)),
		CardHeight = pc(46),
		Max = 3,
	},
	callins = {
		Position = UDim2.new(0.46, 0, 1, -pc(40)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(pc(5 * 46 + 4 * 10), pc(46)),
		Icon = pc(46),
		Gap = pc(10),
		ExpandedWidth = pc(340),
		ExpandedTop = pc(640),
		NameSize = pc(22),
		Docked = true,
	},
	health = {
		Position = UDim2.new(0, pc(24), 1, -pc(40)),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(pc(320), pc(16)),
		PipsX = pc(334),
		PipSize = pc(16),
		PipGap = pc(6),
	},
	weapon = {
		Position = UDim2.new(1, -pc(24), 1, -pc(40)),
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(pc(540), pc(56)),
		NameSize = pc(22),
		ModeSize = pc(22),
		MagSize = pc(50),
		SpareSize = pc(28),
		CountSize = pc(22),
		GlyphSize = pc(14),
		Docked = true,
	},
	stamina = {
		Position = UDim2.new(0.5, 0, 1, -pc(90)),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(290, 4),
	},
	prompt = {
		Position = UDim2.new(0.5, 0, 0.5, pc(215)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(pc(520), pc(40)),
		MaxWidth = pc(520),
		TextSize = pc(26),
		KeySize = pc(32),
	},
	satellites = BOLD_PC.satellites,
	downed = BOLD_PC.downed,
	sheet = BOLD_PC.sheet,
	clearBox = BOLD_PC.clearBox,
}

local FRAME_PHONE = {
	topBar = {
		Height = ph(38), -- 47 layout px -> ~38 real px at 380p, safely above MobileControls Stim (42 px)
	},
	bottomBar = {
		Height = ph(66),
	},
	compass = {
		Position = UDim2.new(0, ph(10), 0, ph(19)),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(ph(128), ph(16)),
		HeadingSize = ph(15),
		CardinalSize = ph(15),
		InterSize = ph(13),
		HeadingBeside = true,
		Compact = true,
	},
	goal = {
		Position = UDim2.new(0.53, 0, 0, ph(19)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(250), ph(30)),
		MaxWidth = ph(250),
		BannerHeight = ph(30),
		TextSize = ph(16),
		DistSize = ph(15),
		CaretSize = ph(12),
		HitHeight = ph(38),
		ProgressHeight = 3,
		HideNext = true,
		Docked = true,
	},
	progress = {
		Position = UDim2.new(0.53, 0, 0, ph(35)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(200), 2),
		Height = 2,
	},
	side = BOLD_PHONE.side,
	alert = {
		Position = UDim2.new(0.44, 0, 0, ph(44)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(310), ph(28)),
		BarHeight = ph(28),
		TextSize = ph(16),
		SubSize = ph(15),
		CalloutHeight = ph(22),
	},
	tips = BOLD_PHONE.tips,
	timer = {
		Position = UDim2.new(1, -ph(10), 0, ph(19)),
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(ph(78), ph(24)),
		TextSize = ph(18),
	},
	reinforce = {
		Gap = ph(6),
		Position = UDim2.new(1, -ph(10 + 78 + 6), 0, ph(19)),
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(ph(44), ph(22)),
		TextSize = ph(15),
	},
	feed = {
		Position = UDim2.new(0.44, 0, 0, ph(78)),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(ph(280), ph(2 * 22 + 4)),
		Lines = 2,
		LineHeight = ph(22),
		Gap = ph(4),
		TextSize = ph(15),
		GlyphGap = ph(8),
		Life = 4,
		FadeTime = 0.35,
	},
	squad = {
		Position = UDim2.fromOffset(ph(10), ph(46)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(168), ph(64)),
		RowCollapsed = ph(20),
		RowOpen = ph(20),
		TagSize = ph(15),
		StatusSize = ph(15),
		HpHeight = 3,
		Compact = true,
	},
	callinCards = {
		Position = UDim2.fromOffset(ph(10), ph(118)),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(ph(180), ph(68)),
		CardHeight = ph(28),
		Max = 2,
	},
	-- Docked inside the bottom-left bar (x = 0..phoneBottomWidth(), never overlapping MobileControls on the right)
	health = {
		Position = UDim2.new(0, ph(10), 1, -ph(49)),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(ph(116), ph(8)),
		PipsX = ph(122),
		PipSize = ph(10),
		PipGap = ph(3),
	},
	weapon = {
		Position = UDim2.new(0, ph(178), 1, -ph(49)),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(ph(220), ph(26)),
		NameSize = 0,
		ModeSize = ph(14),
		MagSize = ph(20),
		SpareSize = ph(15),
		CountSize = ph(15),
		GlyphSize = ph(9),
		Compact = true,
	},
	callins = {
		Position = UDim2.new(0, ph(10), 1, -ph(18)),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(ph(5 * 26 + 4 * 5), ph(26)),
		Icon = ph(26),
		Gap = ph(5),
		ExpandedWidth = 0,
		ExpandedTop = 0,
		NameSize = ph(15),
		Docked = true,
	},
	stamina = {
		Position = UDim2.new(0.28, 0, 1, -ph(72)),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(200, 4),
	},
	prompt = {
		Position = UDim2.new(0.28, 0, 1, -ph(90)),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ph(230), ph(28)),
		MaxWidth = ph(230),
		TextSize = ph(16),
		KeySize = ph(19),
	},
	satellites = BOLD_PHONE.satellites,
	downed = BOLD_PHONE.downed,
	sheet = BOLD_PHONE.sheet,
	clearBox = BOLD_PHONE.clearBox,
}

local PRESETS = {
	bold = { PC = BOLD_PC, PHONE = BOLD_PHONE },
	clean = { PC = CLEAN_PC, PHONE = CLEAN_PHONE },
	frame = { PC = FRAME_PC, PHONE = FRAME_PHONE },
}

HudLayout.PRESETS = PRESETS
HudLayout.PC = BOLD_PC
HudLayout.PHONE = BOLD_PHONE
HudLayout.NAMES = {}
for name in BOLD_PC do
	table.insert(HudLayout.NAMES, name)
end
table.sort(HudLayout.NAMES)

local EMPTY = {
	Position = UDim2.fromOffset(0, 0),
	AnchorPoint = Vector2.new(0, 0),
	Size = UDim2.fromOffset(0, 0),
}

function HudLayout.get(name: string, touch: boolean): { [string]: any }
	local p = PRESETS[HudLayout.preset()] or PRESETS.bold
	local t = if touch then p.PHONE else p.PC
	local e = t[name] or p.PC[name] or BOLD_PC[name]
	if not e then
		warn("HudLayout: no entry " .. tostring(name))
		return EMPTY
	end
	return e
end

function HudLayout.apply(inst: GuiObject, name: string, touch: boolean)
	local e = HudLayout.get(name, touch)
	if e.AnchorPoint then
		inst.AnchorPoint = e.AnchorPoint
	end
	if e.Position then
		inst.Position = e.Position
	end
	if e.Size then
		inst.Size = e.Size
	end
end

return HudLayout
