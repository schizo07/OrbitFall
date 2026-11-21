--!nonstrict
-- Unified perimeter HUD layout (85 %+ clear center viewport).
-- Values are layout px inside a Theme.root(gui, "hud") frame (Insets = CoreUISafeInsets).
--   HudLayout.preset() -> "perimeter"
--   HudLayout.get(name, touch) -> entry
--   HudLayout.apply(inst, name, touch)
--   HudLayout.phoneBottomWidth() -> number (layout px safe width left of MobileControls)
local Theme = require(script.Parent.Theme)

local HudLayout = {}

function HudLayout.preset(): string
	return "perimeter"
end

-- Safe width (in HUD layout px) on the bottom-left of a phone so the self strip never overlaps MobileControls.
-- MobileControls' leftmost button (Shoulder) extends to 342 mobile-px from the right edge.
function HudLayout.phoneBottomWidth(): number
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(800, 380)
	local mobScale = Theme.clamp(vp.Y / 420, 1, 1.4)
	local hudScale = math.max(Theme.scaleFor("hud"), 0.01)
	local safeReal = math.max(200, vp.X - 356 * mobScale)
	return math.floor(safeReal / hudScale)
end

local PC = {
	-- Top-center: razor-slim compass bar + bearing chip + slim crimson AlertBar directly beneath
	compass = {
		Position = UDim2.new(0.5, 0, 0, 10),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.new(0.30, 0, 0, 24),
		MinWidth = 280,
		HeadingSize = 14,
		CardinalSize = 15,
		InterSize = 12,
	},
	alert = {
		Position = UDim2.new(0.5, 0, 0, 56),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(460, 26),
		BarHeight = 26,
		TextSize = 16,
		SubSize = 14,
		CalloutHeight = 22,
	},
	tips = {
		Position = UDim2.new(0.5, 0, 0, 58),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(420, 0),
		TextSize = 14,
	},
	-- Ephemeral 4 s drop intro only (no permanent top-center objective box)
	goal = {
		Position = UDim2.new(0.5, 0, 0, 58),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(520, 24),
		TextSize = 15,
	},
	-- Top-right: compact mission timer + clean objective checklist, clear of Roblox's top-right PlayerList
	timer = {
		Position = UDim2.new(1, -20, 0, 148),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(112, 26),
		TextSize = 17,
	},
	objectives = {
		Position = UDim2.new(1, -20, 0, 180),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(252, 0),
		TitleSize = 15,
		TextSize = 14,
		SubSize = 12,
	},
	-- Top-left: collapsed call-in chip + reinforcement pill, clear of Roblox's top-left chrome
	callins = {
		Position = UDim2.fromOffset(20, 12),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(220, 26),
		DrawerWidth = 304,
		TextSize = 14,
	},
	callinCards = {
		Position = UDim2.fromOffset(20, 260),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(260, 126),
		CardHeight = 38,
		Max = 3,
	},
	-- Bottom-left: unified self vitals + weapon strip + hairline stamina, with squadmates directly above
	health = {
		Position = UDim2.new(0, 20, 1, -18),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(356, 76),
		BarHeight = 9,
		StaminaHeight = 3,
		TextSize = 14,
	},
	weapon = {
		Position = UDim2.fromOffset(0, 0),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(1, 0, 0, 26),
		NameSize = 14,
		ModeSize = 12,
		MagSize = 22,
		SpareSize = 14,
		CountSize = 13,
		GlyphSize = 11,
	},
	squad = {
		Position = UDim2.new(0, 20, 1, -102),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(268, 0),
		RowHeight = 24,
		TagSize = 13,
		StatusSize = 12,
		HpHeight = 4,
	},
	-- Bottom-right: ephemeral event feed (replaces old bottom-right weapon box)
	feed = {
		Position = UDim2.new(1, -20, 1, -18),
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(340, 130),
		Lines = 5,
		LineHeight = 22,
		Gap = 4,
		TextSize = 14,
		GlyphGap = 8,
		Life = 5.5,
		FadeTime = 0.35,
	},
	-- Center ephemeral cues only
	prompt = {
		Position = UDim2.new(0.5, 0, 1, -68),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(420, 32),
		MaxWidth = 420,
		TextSize = 16,
		KeySize = 22,
	},
	satellites = {
		Position = UDim2.fromOffset(38, 22),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(64, 20),
		MagOffset = Vector2.new(38, 22),
		TextSize = 16,
		ArcRadius = 34,
		ArcWidth = 3,
	},
	downed = {
		Position = UDim2.new(0.5, 0, 0.5, 68),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(280, 58),
	},
	sheet = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(820, 520),
		RowSize = 16,
		TitleSize = 24,
		CloseSize = 44,
	},
}

local PHONE = {
	compass = {
		Position = UDim2.new(0.46, 0, 0, 6),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(210, 20),
		MinWidth = 180,
		HeadingSize = 12,
		CardinalSize = 13,
		InterSize = 11,
		Compact = true,
	},
	alert = {
		Position = UDim2.new(0.46, 0, 0, 44),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(290, 24),
		BarHeight = 24,
		TextSize = 14,
		SubSize = 12,
		CalloutHeight = 20,
	},
	tips = {
		Position = UDim2.new(0.44, 0, 0, 46),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(270, 0),
		TextSize = 13,
	},
	goal = {
		Position = UDim2.new(0.46, 0, 0, 46),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(280, 20),
		TextSize = 13,
	},
	timer = {
		Position = UDim2.new(1, -10, 0, 6),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(84, 22),
		TextSize = 14,
	},
	objectives = {
		Position = UDim2.new(1, -10, 0, 32),
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(204, 0),
		TitleSize = 13,
		TextSize = 12,
		SubSize = 11,
		Compact = true,
	},
	callins = {
		Position = UDim2.fromOffset(10, 6),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(156, 22),
		DrawerWidth = 224,
		TextSize = 12,
	},
	callinCards = {
		Position = UDim2.fromOffset(10, 86),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(180, 66),
		CardHeight = 28,
		Max = 2,
	},
	health = {
		Position = UDim2.new(0, 10, 1, -8),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(264, 60),
		BarHeight = 7,
		StaminaHeight = 3,
		TextSize = 12,
	},
	weapon = {
		Position = UDim2.fromOffset(0, 0),
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(1, 0, 0, 22),
		NameSize = 0,
		ModeSize = 11,
		MagSize = 17,
		SpareSize = 12,
		CountSize = 12,
		GlyphSize = 9,
		Compact = true,
	},
	squad = {
		Position = UDim2.new(0, 10, 1, -74),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(196, 0),
		RowHeight = 20,
		TagSize = 12,
		StatusSize = 11,
		HpHeight = 3,
		Compact = true,
	},
	feed = {
		Position = UDim2.new(0.44, 0, 0, 74),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(250, 44),
		Lines = 2,
		LineHeight = 19,
		Gap = 3,
		TextSize = 12,
		GlyphGap = 6,
		Life = 3.5,
		FadeTime = 0.3,
	},
	prompt = {
		Position = UDim2.new(0.38, 0, 1, -78),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(240, 28),
		MaxWidth = 240,
		TextSize = 14,
		KeySize = 18,
	},
	satellites = {
		Position = UDim2.fromOffset(26, 15),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(50, 16),
		MagOffset = Vector2.new(26, 15),
		TextSize = 13,
		ArcRadius = 24,
		ArcWidth = 2,
	},
	downed = {
		Position = UDim2.new(0.5, 0, 0.5, 56),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(240, 54),
	},
	sheet = {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(640, 330),
		RowSize = 14,
		TitleSize = 20,
		CloseSize = 44,
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
