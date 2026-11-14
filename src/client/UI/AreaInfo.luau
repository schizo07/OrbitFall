-- Top-left area / mission info panel (above the UPLINK list): where we are and what to do next.
--   zone     planet name (big), sector + biome line, enemy faction + difficulty
--   objective  active step of the primary objective, with a rotating arrow and the distance (m) to its marker
--   threat   Director pacing state (calm / building / breach / lull) + live hostile count  (PC only)
--   extract  skiff ETA / boarding window countdown once the extraction is called, or "extraction active"
-- Pure display. Data (all already replicated, HUD forwards it): Store "mission" { planet, planetName, factionName,
-- difficulty, objectiveName, extract = { eta, window }, state }, "objectives" { title, main, done, marker, steps },
-- "intensity" { state, enemies }. The mission timer stays in TopRight.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Planets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Planets"))
local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)

local AreaInfo = {}

local touch = false
local ui: { [string]: any } = {}
local target: Vector3? = nil -- world marker of the tracked objective
local lastDist = -1
local blinkExtract = false

local BIOME_NAMES: { [string]: string } = {
	desert = "DESERT WASTES",
	ash = "ASH FIELDS",
	swamp = "SPORE MARSH",
	ice = "ICE SHELF",
}

local THREAT: { [string]: { text: string, color: Color3 } } = {
	calm = { text = "CALM", color = Style.Green },
	build = { text = "BUILDING", color = Style.Amber },
	breach = { text = "BREACH", color = Style.Red },
	relax = { text = "LULL", color = Style.Green },
}

function AreaInfo.build(parent: Instance, isTouch: boolean, order: number?)
	touch = isTouch
	local p = Style.panel({
		Name = "AreaInfo",
		Size = if isTouch then UDim2.fromOffset(176, 0) else UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 1,
		Visible = false,
		Parent = parent,
	})
	Theme.pad(p, 8, 6, 8, 7)
	Theme.list(p, Enum.FillDirection.Vertical, 3)

	ui.zone = Style.label({
		Text = "",
		TextSize = if isTouch then 16 else 20,
		Size = UDim2.new(1, 0, 0, if isTouch then 20 else 24),
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 1,
		Parent = p,
	})
	ui.sector = Style.label({
		Text = "",
		TextSize = 13,
		Color = Style.Grey,
		Size = UDim2.new(1, 0, 0, 15),
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 2,
		Parent = p,
	})
	ui.faction = Style.label({
		Text = "",
		TextSize = 13,
		Color = Style.Amber,
		Size = UDim2.new(1, 0, 0, 15),
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 3,
		Parent = p,
	})
	ui.divider = Style.rect({
		Color = Style.White,
		Transparency = 0.75,
		Size = UDim2.new(1, 0, 0, 1),
		LayoutOrder = 4,
		Parent = p,
	})

	-- objective: caption + active step + arrow / distance
	ui.objText = Style.label({
		Text = "",
		TextSize = 14,
		Color = Style.White,
		Size = UDim2.new(1, 0, 0, 17),
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 5,
		Parent = p,
	})
	local distRow = Instance.new("Frame")
	distRow.Name = "DistRow"
	distRow.BackgroundTransparency = 1
	distRow.Size = UDim2.new(1, 0, 0, 24)
	distRow.LayoutOrder = 6
	distRow.Visible = false
	distRow.Parent = p
	ui.distRow = distRow
	ui.arrow = Style.glyph("up", {
		Size = 16,
		Color = Style.Cyan,
		Box = UDim2.fromOffset(24, 24),
		Parent = distRow,
	})
	ui.arrow.AnchorPoint = Vector2.new(0, 0)
	ui.dist = Style.label({
		Text = "",
		TextSize = 20,
		Color = Style.Cyan,
		Size = UDim2.new(0, 90, 1, 0),
		Position = UDim2.fromOffset(30, 0),
		Parent = distRow,
	})
	ui.distTag = Style.label({
		Text = "TO OBJECTIVE",
		TextSize = 11,
		Color = Style.Grey,
		XAlign = Enum.TextXAlignment.Right,
		Size = UDim2.new(1, -124, 1, 0),
		Position = UDim2.fromOffset(124, 0),
		Visible = not isTouch,
		Parent = distRow,
	})

	ui.threat = Style.label({
		Text = "",
		Rich = true,
		TextSize = 13,
		Size = UDim2.new(1, 0, 0, 15),
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 7,
		Visible = false,
		Parent = p,
	})
	ui.extract = Style.label({
		Text = "",
		TextSize = 15,
		Color = Style.Green,
		Size = UDim2.new(1, 0, 0, 18),
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 8,
		Visible = false,
		Parent = p,
	})
	ui.panel = p
end

function AreaInfo.setVisible(on: boolean)
	if ui.panel then
		ui.panel.Visible = on
	end
end

local function primaryObjective(objs: any): (string?, Vector3?)
	if type(objs) ~= "table" or #objs == 0 then
		return nil, nil
	end
	local primary: any = nil
	for _, o in objs do
		if o.main then
			primary = o
			break
		end
	end
	primary = primary or objs[1]
	local text: string
	if primary.done then
		text = "OBJECTIVE COMPLETE"
	else
		local act: any = nil
		if primary.steps then
			for _, s in primary.steps do
				if s.active then
					act = s
					break
				end
			end
		end
		text = act and act.text or primary.title or "OBJECTIVE"
	end
	-- marker: the primary's, else the nearest listed unfinished objective's
	local marker: Vector3? = nil
	if not primary.done and primary.marker then
		marker = primary.marker
	else
		for _, o in objs do
			if not o.done and o.marker then
				marker = o.marker
				break
			end
		end
	end
	return text, marker
end

-- m = Store "mission", objs = Store "objectives", it = Store "intensity", t = workspace:GetServerTimeNow()
function AreaInfo.update(m: any, objs: any, it: any, t: number)
	if not ui.panel or type(m) ~= "table" then
		return
	end
	-- zone / sector / faction
	local planet = m.planet and Planets.get(m.planet)
	local zone = m.planetName or (planet and planet.name) or m.objectiveName or "FIELD OPERATION"
	ui.zone.Text = Style.up(zone)
	local sectorLine = ""
	if planet then
		local sec = (Planets.Sectors :: any)[planet.sector]
		sectorLine = (sec and sec.name or "") .. (if BIOME_NAMES[planet.biome] then "  /  " .. BIOME_NAMES[planet.biome] else "")
	end
	ui.sector.Text = Style.up(sectorLine)
	ui.sector.Visible = sectorLine ~= ""
	local fac = m.factionName
	if type(fac) == "string" and fac ~= "" then
		ui.faction.Text = Style.up(fac) .. "  -  DIFF " .. tostring(m.difficulty or 1)
		ui.faction.Visible = true
	else
		ui.faction.Visible = false
	end

	-- objective
	local text, marker = primaryObjective(objs)
	target = marker
	ui.objText.Visible = text ~= nil
	ui.divider.Visible = text ~= nil or ui.sector.Visible
	if text then
		ui.objText.Text = Style.up(text)
		ui.objText.TextColor3 = if text == "OBJECTIVE COMPLETE" then Style.Green else Style.White
	end
	ui.distRow.Visible = marker ~= nil
	if not marker then
		lastDist = -1
	end

	-- threat (PC only)
	if not touch and type(it) == "table" and THREAT[it.state] then
		local th = THREAT[it.state]
		ui.threat.Text = string.format(
			'<font color="#%s">%s</font>   <font color="#%s">HOSTILES %d</font>',
			th.color:ToHex(),
			th.text,
			Style.Grey:ToHex(),
			it.enemies or 0
		)
		ui.threat.Visible = true
	else
		ui.threat.Visible = false
	end

	-- extraction
	local ex = m.extract
	local line: string? = nil
	blinkExtract = false
	if type(ex) == "table" and type(ex.eta) == "number" then
		if t < ex.eta then
			line = "SKIFF ETA  " .. Theme.formatTime(ex.eta - t)
		elseif type(ex.window) == "number" and t < ex.window then
			line = "BOARD NOW  " .. Theme.formatTime(ex.window - t)
			blinkExtract = true
		else
			line = "SKIFF ON STATION"
		end
	elseif m.state == "Extract" then
		line = "EXTRACTION ACTIVE"
	end
	ui.extract.Visible = line ~= nil
	if line then
		ui.extract.Text = line
		ui.extract.TextColor3 = if blinkExtract and math.floor(t * 2) % 2 == 0 then Style.Amber else Style.Green
	end
end

-- Per frame: distance + arrow towards the tracked objective marker, relative to the camera heading.
function AreaInfo.step(cam: Camera)
	local tgt = target
	if not ui.panel or not tgt or not ui.distRow.Visible then
		return
	end
	local char = Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local from = if root then root.Position else cam.CFrame.Position
	local d = tgt - from
	local dist = math.floor(Vector3.new(d.X, 0, d.Z).Magnitude + 0.5)
	if dist ~= lastDist then
		lastDist = dist
		ui.dist.Text = string.format("%d M", dist)
	end
	local look = cam.CFrame.LookVector
	local camAng = math.deg(math.atan2(look.X, -look.Z))
	local bearing = math.deg(math.atan2(d.X, -d.Z))
	ui.arrow.Rotation = (bearing - camAng + 180) % 360 - 180
end

return AreaInfo
