-- Mission area metadata: feeds the MissionSheet "area" slot (planet, sector, faction, threat, extraction),
-- triggers the 4 s drop intro caption (UI/GoalLine.intro), and forwards extraction timers to UI/ObjectiveList.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Planets"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local InfoLayer = require(script.Parent.InfoLayer)
local GoalLine = require(script.Parent.GoalLine)
local MissionSheet = require(script.Parent.MissionSheet)

local AreaInfo = {}

local sheet: { [string]: any } = {}
local lastState: string? = nil

local BIOME_NAMES: { [string]: string } = {
	desert = "DESERT WASTES",
	ash = "ASH FIELDS",
	swamp = "SPORE MARSH",
	ice = "ICE SHELF",
	crystal = "CRYSTAL FLATS",
}

local THREAT: { [string]: { text: string, color: Color3 } } = {
	calm = { text = "CALM", color = Style.Green },
	build = { text = "BUILDING", color = Style.Amber },
	breach = { text = "BREACH", color = Style.Red },
	relax = { text = "LULL", color = Style.Green },
}

function AreaInfo.build(_parent: Instance, _isTouch: boolean, _order: number?)
	sheet = {}
end

local function ensureSheet(): boolean
	local slot = MissionSheet.slot("area")
	if not slot or not slot.Parent then
		return false
	end
	if sheet.slot == slot and sheet.zone and sheet.zone.Parent then
		return true
	end
	sheet = { slot = slot }
	local size = 16
	local function line(order: number, role: string, numRole: boolean?): TextLabel
		return InfoLayer.label({
			Text = "",
			TextSize = size,
			ColorRole = role,
			Role = if numRole then "number" else "label",
			Size = UDim2.new(1, 0, 0, size + 5),
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = order,
			Parent = slot,
		})
	end
	sheet.zone = line(1, "text")
	sheet.sector = line(2, "dim")
	sheet.faction = line(3, "own")
	sheet.threat = line(4, "text")
	sheet.extract = line(5, "heal")
	return true
end

local function extractLine(m: any, t: number): (string?, boolean)
	local ex = m.extract
	if type(ex) == "table" and type(ex.eta) == "number" then
		if t < ex.eta then
			return "SKIFF ETA  " .. Theme.formatTime(ex.eta - t), false
		elseif type(ex.window) == "number" and t < ex.window then
			return "BOARD NOW  " .. Theme.formatTime(ex.window - t), true
		end
		return if type(ex.label) == "string" then ex.label else "SKIFF ON STATION", false
	elseif m.state == "Extract" then
		return "EXTRACTION ACTIVE", false
	end
	return nil, false
end

function AreaInfo.setVisible(_on: boolean) end

function AreaInfo.update(m: any, _objs: any, it: any, t: number)
	if type(m) ~= "table" then
		return
	end
	local planet = m.planet and Planets.get(m.planet)
	local zone = m.planetName or (planet and planet.name) or m.objectiveName or "FIELD OPERATION"
	local sectorLine = ""
	if planet then
		local sec = (Planets.Sectors :: any)[planet.sector]
		sectorLine = (sec and sec.name or "") .. (if BIOME_NAMES[planet.biome] then "  /  " .. BIOME_NAMES[planet.biome] else "")
	end
	local fac = if type(m.factionName) == "string" and m.factionName ~= "" then m.factionName else nil

	-- 4 s drop intro when entering the field
	local st = m.state
	local inField = st == "Drop" or st == "Active" or st == "Extract"
	local wasField = lastState == "Drop" or lastState == "Active" or lastState == "Extract"
	if inField and not wasField then
		local bits = { zone }
		if fac then
			table.insert(bits, fac)
		end
		table.insert(bits, "DIFF " .. tostring(m.difficulty or 1))
		GoalLine.intro(table.concat(bits, "  /  "))
	end
	lastState = st

	-- Forward extraction countdown to the top-right objective card
	local ex = m.extract
	local goalText: string? = nil
	if type(ex) == "table" and type(ex.eta) == "number" then
		if t < ex.eta then
			goalText = "SKIFF INBOUND  " .. Theme.formatTime(ex.eta - t)
		elseif type(ex.window) == "number" and t < ex.window then
			goalText = "BOARD THE SKIFF  " .. Theme.formatTime(ex.window - t)
		elseif type(ex.label) == "string" then
			goalText = ex.label
		end
	end
	GoalLine.setExtract(goalText)

	if not ensureSheet() then
		return
	end
	sheet.zone.Text = InfoLayer.caseText(zone)
	sheet.sector.Text = InfoLayer.caseText(sectorLine)
	sheet.sector.Visible = sectorLine ~= ""
	sheet.faction.Text = InfoLayer.caseText(if fac then fac .. "  -  DIFF " .. tostring(m.difficulty or 1) else "DIFF " .. tostring(m.difficulty or 1))
	if type(it) == "table" and THREAT[it.state] then
		sheet.threat.Text = InfoLayer.caseText(string.format("THREAT %s   HOSTILES %d", THREAT[it.state].text, it.enemies or 0))
		sheet.threat.TextColor3 = if it.state == "breach" then InfoLayer.col("danger") else InfoLayer.col("text")
		sheet.threat.Visible = true
	else
		sheet.threat.Visible = false
	end
	local line = extractLine(m, t)
	sheet.extract.Visible = line ~= nil
	if line then
		sheet.extract.Text = InfoLayer.caseText(line)
	end
end

function AreaInfo.step(_cam: Camera) end

return AreaInfo
