-- World-space squad tags: a floating tag over every OTHER squad member (callsign in squad colour + name), drawn in a
-- screen overlay so it shows through walls.
--   * fades out when the teammate is close (< FADE_NEAR studs) and dims when it sits near the screen centre (the aim)
--   * clamps to the screen edge (with a pointer) when the teammate is off-screen or behind the camera
--   * a cyan cell glyph + CELL when that teammate carries a core cell (Player attribute CarryCell, haul objective)
--   * red NAME DOWNED + a small bleed-out bar (DownedEnd); the bar turns green and fills while someone revives them
-- Shown only while the mission is in Drop / Active / Extract.
-- Studio A/B "SQUAD TAGS" (client/Variants.luau): workspace attribute TagTune_Mode = nil (fade) | "solid" | "off".
-- Also: SquadTags.feed(text, color) puts Notify "comms" / "ship" lines ("<name>: <line>", HALCYON announcements) into the
-- event feed, word-wrapped, the speaker's line tinted with their squad colour.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Theme = require(script.Parent.Theme)
local Style = require(script.Parent.HudStyle)
local EventFeed = require(script.Parent.EventFeed)
local Store = require(script.Parent.Parent.Store)
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local SquadTags = {}

local FADE_NEAR = 9 -- studs: hidden below this
local FADE_FULL = 20 -- studs: fully shown from here
local CENTRE_R = 90 -- px around the screen centre where tags dim
local EDGE = 34 -- px margin when clamped to the screen edge
local HEAD_UP = 5.4 -- studs above the root (clears the carrier icon at ~4)
local SHOWN = { Drop = true, Active = true, Extract = true }
local FEED_CHARS = 36 -- EventFeed truncates at 38 characters per line
local CELL = Color3.fromRGB(110, 225, 255)
local IS_STUDIO = RunService:IsStudio()

local player = Players.LocalPlayer
local gui: ScreenGui? = nil
local tags: { [Player]: any } = {}

local function mode(): string
	if not IS_STUDIO then
		return "fade"
	end
	local v = workspace:GetAttribute("TagTune_Mode")
	return if v == "solid" or v == "off" then v else "fade"
end

local function makeTag(p: Player): any
	local g = Instance.new("CanvasGroup")
	g.Name = "Tag_" .. p.UserId
	g.BackgroundTransparency = 1
	g.AnchorPoint = Vector2.new(0.5, 1)
	g.Size = UDim2.fromOffset(150, 40)
	g.Parent = gui
	local tag = Style.label({
		Name = "Callsign",
		Text = "",
		TextSize = 15,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, 0),
		Parent = g,
	})
	local name = Style.label({
		Name = "Name",
		Text = "",
		TextSize = 12,
		Color = Style.White,
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 13),
		Position = UDim2.fromOffset(0, 15),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = g,
	})
	local pointer = Style.glyph("down", {
		Name = "Pointer",
		Size = 8,
		Color = Style.White,
		Box = UDim2.fromOffset(150, 10),
		Position = UDim2.fromOffset(0, 29),
		Parent = g,
	})
	local cell = Instance.new("Frame")
	cell.Name = "Cell"
	cell.AnchorPoint = Vector2.new(0.5, 0.5)
	cell.Size = UDim2.fromOffset(9, 9)
	cell.Rotation = 45
	cell.BackgroundColor3 = CELL
	cell.BorderSizePixel = 0
	cell.Visible = false
	cell.Parent = g
	-- downed: bleed-out left (red), or the revive hold (green) while a squadmate holds the prompt
	local bleed = Style.bar({
		Name = "Bleed",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 29),
		Size = UDim2.fromOffset(64, 3),
		Color = Style.Red,
		Parent = g,
	})
	bleed.back.Visible = false
	return { g = g, tag = tag, name = name, pointer = pointer, cell = cell, bleed = bleed, span = 0, key = "" }
end

local function dropTag(p: Player)
	local t = tags[p]
	if t then
		t.g:Destroy()
		tags[p] = nil
	end
end

local function step()
	if not gui then
		return
	end
	local m = Store.get("mission")
	local md = mode()
	local on = md ~= "off" and type(m) == "table" and SHOWN[m.state] == true
	gui.Enabled = on
	if not on then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	local cx, cy = vp.X / 2, vp.Y / 2
	local camPos = cam.CFrame.Position
	local seen: { [Player]: boolean } = {}
	for _, p in Players:GetPlayers() do
		if p == player then
			continue
		end
		local c = p.Character
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = c and c:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 then
			continue
		end
		seen[p] = true
		local t = tags[p] or makeTag(p)
		tags[p] = t
		-- text (only rewritten when it changes)
		local cs = Style.callsign(p.UserId)
		local carrying = p:GetAttribute("CarryCell") == true
		local downed = p:GetAttribute("Downed") == true -- server/Downed.luau: red DOWNED, never faded out
		local key = cs.tag .. "|" .. p.DisplayName .. "|" .. tostring(carrying) .. "|" .. tostring(downed)
		if key ~= t.key then
			t.key = key
			t.tag.Text = cs.tag
			t.tag.TextColor3 = cs.color
			Style.tint(t.pointer, cs.color)
			t.name.Text = if downed then (Style.up(p.DisplayName) .. "  DOWNED")
				elseif carrying then (Style.up(p.DisplayName) .. "  CELL")
				else Style.up(p.DisplayName)
			t.name.TextColor3 = if downed then Style.Red elseif carrying then CELL else Style.White
			t.cell.Visible = carrying
			t.cell.Position = UDim2.new(0.5, 24, 0, 8)
			t.bleed.back.Visible = downed
			t.span = 0
		end
		if downed then
			local nowT = workspace:GetServerTimeNow()
			local endAt = p:GetAttribute("DownedEnd")
			local left = if type(endAt) == "number" then math.max(0, endAt - nowT) else 0
			if t.span <= 0 then
				t.span = math.max(left, 1) -- first look after going down = the full bar
			end
			local rs = p:GetAttribute("ReviveStart")
			if type(rs) == "number" and p:GetAttribute("ReviveBy") ~= nil then
				t.bleed.set((nowT - rs) / math.max(Config.Downed.ReviveHold, 0.1), Style.Green)
			else
				t.bleed.set(left / t.span, Style.Red)
			end
		end
		-- position
		local world = root.Position + Vector3.new(0, HEAD_UP, 0)
		local sp = cam:WorldToViewportPoint(world)
		local x, y = sp.X, sp.Y
		local clamped = false
		if sp.Z < 0 then
			-- behind the camera: mirror through the centre and push to the edge
			x, y = cx - (x - cx), cy - (y - cy)
			local dx, dy = x - cx, y - cy
			local k = math.max(math.abs(dx) / math.max(cx - EDGE, 1), math.abs(dy) / math.max(cy - EDGE, 1), 1e-3)
			x, y = cx + dx / k, cy + dy / k
			clamped = true
		elseif x < EDGE or x > vp.X - EDGE or y < EDGE + 30 or y > vp.Y - EDGE then
			x = math.clamp(x, EDGE, vp.X - EDGE)
			y = math.clamp(y, EDGE + 30, vp.Y - EDGE)
			clamped = true
		end
		t.g.Position = UDim2.fromOffset(x, y)
		t.pointer.Visible = not clamped
		-- fade
		local vis = 1
		if md == "fade" and not clamped and not downed then
			local d = (root.Position - camPos).Magnitude
			vis = math.clamp((d - FADE_NEAR) / (FADE_FULL - FADE_NEAR), 0, 1)
			local r = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)
			vis *= 0.35 + 0.65 * math.clamp((r - 30) / (CENTRE_R - 30), 0, 1)
		end
		t.g.GroupTransparency = 1 - vis
		t.g.Visible = vis > 0.02
	end
	for p in tags do
		if not seen[p] then
			dropTag(p)
		end
	end
end

-- Notify kinds "comms" (callouts "<name>: <line>") and "ship" (Halcyon announcements) -> event feed lines
function SquadTags.feed(text: string, color: Color3?)
	local col = color or Style.Amber
	local who = string.match(text, "^(.-):")
	if who and who ~= "HALCYON" then
		local squad = Store.get("squad")
		if type(squad) == "table" then
			for _, m in squad do
				if type(m) == "table" and m.name == who and type(m.userId) == "number" then
					col = Style.callsign(m.userId).color
					break
				end
			end
		end
	end
	-- word-wrap: EventFeed truncates long lines
	local line = ""
	local lines = {}
	for word in string.gmatch(text, "%S+") do
		if line ~= "" and #line + 1 + #word > FEED_CHARS then
			table.insert(lines, line)
			line = "  " .. word
		else
			line = if line == "" then word else line .. " " .. word
		end
	end
	if line ~= "" then
		table.insert(lines, line)
	end
	for _, l in lines do
		EventFeed.push(l, col, "comms")
	end
	return true
end

function SquadTags.init()
	gui = Theme.gui("OrbitSquadTags", { DisplayOrder = 5, Insets = "None" })
	Players.PlayerRemoving:Connect(dropTag)
	local lastWarn = -99
	RunService:BindToRenderStep("OrbitSquadTags", Enum.RenderPriority.Camera.Value + 2, function()
		local ok, err = pcall(step)
		if not ok and os.clock() - lastWarn > 5 then
			lastWarn = os.clock()
			warn("[SquadTags]", err)
		end
	end)
end

return SquadTags
