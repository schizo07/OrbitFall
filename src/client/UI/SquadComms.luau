-- Squad chatter: short radio lines generated client-side from events the HUD already receives (nothing is sent anywhere).
--   own actions  -> a tiny line above the own card:   RELOADING (reload bar starts), GRENADE OUT (grenade count drops),
--                   CALLING IN <NAME> (a call-in is armed / being held), NEED REINFORCE (local player went down)
--   spotting     -> a radio line in the event feed:   BREACH - NW! (Fx "Breach"), HEAVY CONTACT - NE (Fx "HeavyContact")
--   squadmates   -> "B2: NEED REINFORCE" in the feed when a squadmate goes from alive to down (Store "squad")
--   call-ins     -> "<NAME> ON TARGET" in amber when a beacon lands (Fx "Beacon" / "BeaconEnd")
-- Rate limit: at most one bark per 2.5 s overall, plus a per-kind cooldown, so it can never spam.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallIns = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("CallIns"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local EventFeed = require(script.Parent.EventFeed)
local Store = require(script.Parent.Parent.Store)

local SquadComms = {}

local GAP = 2.5 -- min seconds between any two barks
local HOLD = 2.2 -- how long the own-card line stays
local COOLDOWN: { [string]: number } = {
	reload = 6,
	grenade = 3,
	callin = 4,
	down = 15,
	breach = 10,
	heavy = 8,
	mate = 6,
}
local SHORT = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

local player = Players.LocalPlayer
local ui: { [string]: any } = {}
local active = false
local lastBark = -100
local lastKind: { [string]: number } = {}
local lineGen = 0
local beaconNames: { [any]: string } = {}

-- state seen last time (edge detection)
local prevGrenades: number? = nil
local prevHolding: string? = nil
local prevAlive: boolean? = nil
local prevMates: { [number]: boolean } = {}
local matesSeen = false

local function allowed(kind: string): boolean
	if not active then
		return false
	end
	local t = os.clock()
	if t - lastBark < GAP then
		return false
	end
	if t - (lastKind[kind] or -100) < (COOLDOWN[kind] or 6) then
		return false
	end
	lastBark = t
	lastKind[kind] = t
	return true
end

local function myTag(): string
	return Style.callsign(player.UserId).tag
end

local function bearingName(from: Vector3, to: Vector3): string
	local d = to - from
	local deg = (math.deg(math.atan2(d.X, -d.Z)) + 360) % 360 -- same convention as the compass tape (N = -Z)
	return SHORT[math.floor((deg + 22.5) / 45) % 8 + 1]
end

-- Tiny line above the own card ---------------------------------------------------------------------------------------
function SquadComms.build(ownCard: Instance, _touch: boolean)
	-- Folder: the card's UIListLayout ignores it, its child is positioned against the card frame
	local folder = Instance.new("Folder")
	folder.Name = "Chatter"
	folder.Parent = ownCard
	local panel = Style.panel({
		Name = "Bark",
		Brackets = false,
		Position = UDim2.new(0, 0, 0, -22),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Visible = false,
		Parent = folder,
	})
	Theme.pad(panel, 6, 0, 8, 0)
	ui.panel = panel
	ui.text = Style.label({
		Text = "",
		TextSize = 13,
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = panel,
	})
end

local function ownBark(text: string)
	if not ui.panel then
		return
	end
	lineGen += 1
	local gen = lineGen
	ui.text.Text = string.format("%s > %s", myTag(), text)
	ui.text.TextColor3 = Style.Amber
	ui.text.TextTransparency = 0
	ui.text.TextStrokeTransparency = 0.65
	ui.panel.BackgroundTransparency = Style.PANEL_ALPHA
	ui.panel.Visible = true
	task.delay(HOLD, function()
		if gen ~= lineGen then
			return
		end
		Theme.tween(ui.panel, 0.3, { BackgroundTransparency = 1 })
		Theme.tween(ui.text, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
		task.delay(0.35, function()
			if gen == lineGen then
				ui.panel.Visible = false
			end
		end)
	end)
end

local function radio(userId: number, text: string)
	local cs = Style.callsign(userId)
	EventFeed.push(string.format("%s: %s", cs.tag, text), cs.color, "bark")
end

-- Hooks ------------------------------------------------------------------------------------------------------------------
-- combat on/off (HUD.applyVisibility). Leaving combat forgets every edge so the next mission starts clean.
function SquadComms.setActive(on: boolean)
	if on == active then
		return
	end
	active = on
	if not on then
		prevGrenades, prevHolding, prevAlive = nil, nil, nil
		table.clear(prevMates)
		matesSeen = false
		table.clear(beaconNames)
		if ui.panel then
			lineGen += 1
			ui.panel.Visible = false
		end
	end
end

-- HUD.setReload went from nil to a progress value
function SquadComms.onReload()
	if allowed("reload") then
		ownBark("RELOADING")
	end
end

-- Store "me"
function SquadComms.onMe(me: any)
	if type(me) ~= "table" then
		return
	end
	local g = me.grenades
	if type(g) == "number" then
		if prevGrenades and g < prevGrenades and allowed("grenade") then
			ownBark("GRENADE OUT")
		end
		prevGrenades = g
	end
	local holding = me.callins and me.callins.holding
	local hid: string? = nil
	if type(holding) == "table" and type(holding.id) == "string" then
		hid = holding.id
	end
	if hid and hid ~= prevHolding and allowed("callin") then
		local def = CallIns.get(hid)
		ownBark("CALLING IN " .. string.upper(def and def.name or hid))
	end
	prevHolding = hid
	local alive = me.alive ~= false
	if prevAlive == true and not alive and allowed("down") then
		ownBark("NEED REINFORCE")
	end
	prevAlive = alive
end

-- Store "squad" (others only; the local player is handled by onMe)
function SquadComms.onSquad(squad: any)
	if type(squad) ~= "table" then
		return
	end
	local now: { [number]: boolean } = {}
	for _, m in squad do
		if type(m) == "table" and type(m.userId) == "number" and m.userId ~= player.UserId then
			local alive = m.alive ~= false
			now[m.userId] = alive
			if matesSeen and prevMates[m.userId] == true and not alive and allowed("mate") then
				radio(m.userId, "NEED REINFORCE")
			end
		end
	end
	prevMates = now
	matesSeen = true
end

local function camPos(): Vector3?
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position
end

-- Fx handlers (Fx = client/Fx module, passed in by HUD.init)
function SquadComms.init(fx: any)
	if type(fx) ~= "table" or not fx.register then
		return
	end
	-- breach call-out from the Director's state (same bearing as the alert bar); the "Breach" Fx also fires for every
	-- ground-emerging patrol, so it is not used here
	local lastState: string? = nil
	Store.on("intensity", function(s: any)
		local st = type(s) == "table" and s.state or nil
		if st == "breach" and lastState ~= "breach" and type(s.dir) == "number" and allowed("breach") then
			radio(player.UserId, string.format("BREACH - %s!", SHORT[math.floor(((s.dir % 360) + 22.5) / 45) % 8 + 1]))
		end
		lastState = st
	end)
	fx.register("HeavyContact", function(d: any)
		if type(d) ~= "table" then
			return
		end
		local cp = camPos()
		local where = if cp and typeof(d.p) == "Vector3" then " - " .. bearingName(cp, d.p) else ""
		if allowed("heavy") then
			radio(player.UserId, "HEAVY CONTACT" .. where)
		end
	end)
	fx.register("Beacon", function(d: any)
		if type(d) == "table" and d.id ~= nil and type(d.callin) == "string" then
			local def = CallIns.get(d.callin)
			beaconNames[d.id] = string.upper(def and def.name or d.callin)
		end
	end)
	fx.register("BeaconEnd", function(d: any)
		if type(d) ~= "table" or d.id == nil then
			return
		end
		local name = beaconNames[d.id]
		beaconNames[d.id] = nil
		if name and active then
			EventFeed.push(name .. " ON TARGET", Style.Amber, "callin")
		end
	end)
end

return SquadComms
