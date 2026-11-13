-- Interactive galactic war map (docs/spec.md §14). Opened from the holo-table ("Mission" prompt).
-- Pan: drag (mouse / touch). Zoom: wheel / pinch / +- buttons. Tap a planet -> briefing + launch.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Planets = require(Shared.Data.Planets)
local Campaign = require(Shared.Data.Campaign)
local War = require(Shared.War)
local Enemies = require(Shared.Data.Enemies)

local Store = require(script.Parent.Parent.Store)
local WarFeed = require(script.Parent.WarFeed)

-- LIVE MAP: the server pushes "war" (raw contributions + outcomes), so the client recomputes the war every
-- 0.2 s with Shared/War.luau: enemy pressure ticks numbers down between pushes. Every push is diffed against
-- the previous one: gains float a "+0.42%" tick and pulse the planet, flips tween the owner colour.
-- Gains that arrive while the map is closed (e.g. your own mission) are replayed the next time it opens.

local WarMap = {}
local player = Players.LocalPlayer
local C = Config.Colors

local WORLD_W, WORLD_H = 1600, 1000
local OWNER_COLOR = {
	FREE = C.Friendly,
	COG = Color3.fromHex("ff4a3a"),
	BROOD = Color3.fromHex("8cff3a"),
}
local OBJECTIVES = { { id = "MISSILE", name = "Missile Launch" }, { id = "UPLINK", name = "Uplink Relay" } }

local gui: ScreenGui
local canvas: Frame
local world: Frame
local worldScale: UIScale
local panel: Frame
local ticker: Frame
local nodes: { [string]: any } = {} -- {btn, ring, label, sub, fire?, aura?, barBg, fill, arc, arcGrad, colorKey?, disp?, arcAngle}
local lanes: { any } = {} -- {frame, grad, a, b, len, angle, speed}
local missed: { [string]: number } = {} -- gains that arrived while the map was closed
local missedFlips: { [string]: boolean } = {}
local prevWar: any = nil
local cachedState: any = nil
local cachedAt = -1
local LANE_PULSES = 6
local selected: string? = nil
local objective = "MISSILE"
local difficulty = 1
local zoom = 1
local pan = Vector2.zero
local isOpen = false
local panelRefs: any = {}

local function audio(key: string)
	pcall(function()
		require(script.Parent.Parent.Audio).play2D(key)
	end)
end

local function toast(text: string, color: Color3?)
	pcall(function()
		require(script.Parent.HUD).toast(text, color)
	end)
end

local function new(class: string, props: { [string]: any }, children: { Instance }?): any
	local i = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then
			(i :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = i
	end
	if props.Parent then
		i.Parent = props.Parent
	end
	return i
end

local function corner(r: number?): UICorner
	return new("UICorner", { CornerRadius = r and UDim.new(0, r) or UDim.new(1, 0) })
end

local function stroke(color: Color3, th: number, tr: number?): UIStroke
	return new("UIStroke", { Color = color, Thickness = th, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = C.Text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	}
	for k, v in props do
		base[k] = v
	end
	local l = new("TextLabel", base)
	new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.4, Parent = l })
	return l
end

local function button(text: string, color: Color3, props: { [string]: any }): TextButton
	local base = {
		AutoButtonColor = false,
		BackgroundColor3 = color,
		Font = Enum.Font.GothamBlack,
		Text = text,
		TextColor3 = C.Navy,
		TextSize = 16,
	}
	for k, v in props do
		base[k] = v
	end
	local b = new("TextButton", base, { corner(8) })
	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.1), { BackgroundTransparency = 0.15 }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.1), { BackgroundTransparency = 0 }):Play()
	end)
	return b
end

local function fmtTime(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d = sec // 86400
	local h = (sec % 86400) // 3600
	local m = (sec % 3600) // 60
	if d > 0 then
		return string.format("%dd %02dh", d, h)
	elseif h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm %02ds", m, sec % 60)
end

local function fmtPrecise(sec: number): string
	sec = math.max(0, math.floor(sec))
	local d = sec // 86400
	local h = (sec % 86400) // 3600
	local m = (sec % 3600) // 60
	if d > 0 then
		return string.format("%dd %02dh %02dm %02ds", d, h, m, sec % 60)
	end
	return string.format("%02dh %02dm %02ds", h, m, sec % 60)
end

-- War state at time t from a "war" push: recomputed locally from raw contributions so decay ticks live.
local function computeFrom(w: any, t: number): { [string]: any }
	if w and type(w.c) == "table" and type(w.o) == "table" then
		local ok, res = pcall(War.compute, w.c, w.o, t)
		if ok then
			return res
		end
	end
	if w and w.planets then
		return w.planets
	end
	-- before the first server push: compute the start-of-war picture
	return War.compute({}, {}, t)
end

local function warState(): { [string]: any }
	local c = os.clock()
	if not cachedState or c - cachedAt > 0.2 then
		cachedState = computeFrom(Store.get("war"), workspace:GetServerTimeNow())
		cachedAt = c
	end
	return cachedState
end

local function outcomesNow(): { [string]: any }
	local w = Store.get("war")
	return if w and type(w.o) == "table" then w.o else {}
end

-- (status, progress) of an operation right now
local function opInfo(op: any, t: number): (string, number)
	local w = Store.get("war")
	if w and type(w.c) == "table" and type(w.o) == "table" then
		return War.opStatus(op, w.o, t), War.opProgress(op, w.c, t)
	end
	local info = w and w.ops and w.ops[op.id]
	return (info and info.status) or War.opStatus(op, {}, t), info and info.progress or 0
end

local function diversAt(id: string): number
	local live = Store.get("warLive")
	return live and live.d and tonumber(live.d[id]) or 0
end

local function ownerName(owner: string): string
	if owner == "FREE" then
		return "Free"
	end
	local f = Enemies.Factions[owner]
	return f and f.name or owner
end

-- LAYOUT ------------------------------------------------------------------------------------------
local function applyView()
	worldScale.Scale = zoom
	local vp = canvas.AbsoluteSize
	-- clamp pan so the map can't be lost off-screen
	local w, h = WORLD_W * zoom, WORLD_H * zoom
	local maxX = math.max(0, (w - vp.X) / 2 + vp.X * 0.35)
	local maxY = math.max(0, (h - vp.Y) / 2 + vp.Y * 0.35)
	pan = Vector2.new(math.clamp(pan.X, -maxX, maxX), math.clamp(pan.Y, -maxY, maxY))
	world.Position = UDim2.new(0.5, pan.X, 0.5, pan.Y)
end

local function fitZoom()
	local vp = canvas.AbsoluteSize
	-- the side panel (wide screens) or bottom sheet (phones) covers part of the canvas: fit into what's left
	local coverX, coverY = 0, 0
	if panel and panel.Visible then
		if panel.AnchorPoint.X == 1 then
			coverX = panel.AbsoluteSize.X + 24
		else
			coverY = panel.AbsoluteSize.Y + 12
		end
	end
	local w, h = math.max(100, vp.X - coverX), math.max(100, vp.Y - coverY)
	-- fit the sectors (not the empty canvas around them), in world pixels
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, sec in Planets.Sectors do
		local cx, cy, r = sec.pos.X * WORLD_W, sec.pos.Y * WORLD_H, sec.radius * WORLD_H
		x0, y0 = math.min(x0, cx - r), math.min(y0, cy - r - 30) -- room for the sector label
		x1, y1 = math.max(x1, cx + r), math.max(y1, cy + r)
	end
	local bw, bh = x1 - x0, y1 - y0
	zoom = math.clamp(math.min(w / bw, h / bh) * 0.94, 0.25, 3)
	local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
	pan = Vector2.new(-coverX / 2 - (cx - WORLD_W / 2) * zoom, -coverY / 2 - (cy - WORLD_H / 2) * zoom)
	applyView()
end

local function setZoom(z: number, focus: Vector2?)
	local old = zoom
	zoom = math.clamp(z, 0.25, 3)
	if focus then
		-- keep the point under the cursor fixed
		local centre = canvas.AbsolutePosition + canvas.AbsoluteSize / 2
		local rel = focus - centre - pan
		pan = pan - rel * (zoom / old - 1)
	end
	applyView()
end

local function buildWorld()
	-- stars
	local rng = Random.new(7)
	for _ = 1, 160 do
		local s = rng:NextNumber(1, 3)
		new("Frame", {
			BackgroundColor3 = Color3.fromHSV(rng:NextNumber(0.55, 0.7), 0.2, 1),
			BackgroundTransparency = rng:NextNumber(0.2, 0.7),
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(s, s),
			Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber()),
			Parent = world,
		}, { corner() })
	end
	-- sectors
	for _, sec in Planets.Sectors do
		local d = sec.radius * 2
		new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(sec.pos.X, sec.pos.Y),
			Size = UDim2.fromScale(d * WORLD_H / WORLD_W, d),
			BackgroundColor3 = sec.color,
			BackgroundTransparency = 0.9,
			ZIndex = 1,
			Parent = world,
		}, { corner(), stroke(sec.color, 2, 0.6) })
		label({
			Text = string.upper(sec.name),
			Font = Enum.Font.Michroma,
			TextSize = 18,
			TextColor3 = sec.color,
			TextTransparency = 0.25,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(sec.pos.X, sec.pos.Y - sec.radius - 0.02),
			Size = UDim2.fromOffset(320, 30),
			ZIndex = 2,
			Parent = world,
		})
	end
	-- supply lanes: a dim line with bright packets flowing along it (UIGradient offset, animated per frame).
	-- The frame's local +X is the flow direction; refreshLanes() flips it by 180° to reverse the flow.
	local kps = { NumberSequenceKeypoint.new(0, 0.8) }
	for i = 1, LANE_PULSES do -- 2 + 3 * 6 = 20 keypoints (the NumberSequence maximum)
		local c = (i - 0.5) / LANE_PULSES
		table.insert(kps, NumberSequenceKeypoint.new(c - 0.03, 0.8))
		table.insert(kps, NumberSequenceKeypoint.new(c, 0))
		table.insert(kps, NumberSequenceKeypoint.new(c + 0.03, 0.8))
	end
	table.insert(kps, NumberSequenceKeypoint.new(1, 0.8))
	local laneSeq = NumberSequence.new(kps)
	for _, id in Planets.Order do
		local p = Planets.get(id) :: any
		for _, otherId in p.links do
			local o = Planets.get(otherId)
			if o then
				local a = Vector2.new(p.pos.X * WORLD_W, p.pos.Y * WORLD_H)
				local b = Vector2.new(o.pos.X * WORLD_W, o.pos.Y * WORLD_H)
				local mid = (a + b) / 2
				local len = (b - a).Magnitude
				local angle = math.deg(math.atan2(b.Y - a.Y, b.X - a.X))
				local frame = new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(mid.X, mid.Y),
					Size = UDim2.fromOffset(len, 3),
					Rotation = angle,
					BackgroundColor3 = Color3.fromHex("6b7a96"),
					BackgroundTransparency = 0,
					BorderSizePixel = 0,
					ZIndex = 2,
					Parent = world,
				})
				local grad = new("UIGradient", { Transparency = laneSeq, Parent = frame })
				table.insert(lanes, { frame = frame, grad = grad, a = id, b = otherId, len = len, angle = angle, speed = 0 })
			end
		end
	end
	-- planets
	for _, id in Planets.Order do
		local p = Planets.get(id) :: any
		local size = 46 * p.size
		local btn = new("TextButton", {
			Name = id,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(p.pos.X, p.pos.Y),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = C.Friendly,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 5,
			Parent = world,
		}, { corner(), stroke(Color3.new(1, 1, 1), 2, 0.3) })
		-- shading
		new("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(90, 90, 110)),
			Rotation = 45,
			Parent = btn,
		})
		local ring = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 22, 1, 22),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 4,
			Parent = btn,
		}, { corner(), stroke(C.Accent, 3, 0) })
		local nameL = label({
			Text = p.name,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, 6),
			Size = UDim2.fromOffset(170, 18),
			ZIndex = 6,
			Parent = btn,
		})
		local sub = label({
			Text = "",
			TextSize = 12,
			Font = Enum.Font.GothamMedium,
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, 24),
			Size = UDim2.fromOffset(170, 16),
			ZIndex = 6,
			Parent = btn,
		})
		-- mini progress bar under the label (liberation / defence), eased toward the live value
		local barBg = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, 42),
			Size = UDim2.fromOffset(70, 5),
			BackgroundColor3 = Color3.fromHex("0b0f18"),
			BackgroundTransparency = 0.15,
			Visible = false,
			ZIndex = 6,
			Parent = btn,
		}, { corner(3) })
		local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Friendly, BorderSizePixel = 0, ZIndex = 7, Parent = barBg }, { corner(3) })
		-- front line: a ring split teal (our side) / enemy colour, the split sits at the live progress
		local arc = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 12, 1, 12),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 4,
			Parent = btn,
		}, { corner() })
		local arcStroke = stroke(Color3.new(1, 1, 1), 3, 0.1)
		arcStroke.Parent = arc
		local arcGrad = new("UIGradient", { Parent = arcStroke })
		btn.Activated:Connect(function()
			WarMap.select(id)
		end)
		nodes[id] = { btn = btn, ring = ring, label = nameL, sub = sub, barBg = barBg, fill = fill, arc = arc, arcGrad = arcGrad, arcStroke = arcStroke, arcAngle = 0 }
	end
end

local function refreshNodes()
	local st = warState()
	for id, n in nodes do
		local s = st[id]
		if s then
			local grad = n.btn:FindFirstChildOfClass("UIGradient") :: UIGradient
			if s.destroyed then
				n.btn.BackgroundColor3 = Color3.fromHex("ff5a1f")
				grad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHex("fff07a")),
					ColorSequenceKeypoint.new(0.45, Color3.fromHex("ff8a2b")),
					ColorSequenceKeypoint.new(1, Color3.fromHex("5a0a0a")),
				})
				n.sub.Text = "DESTROYED"
				n.sub.TextColor3 = C.Danger
				n.fire = grad
				if not n.aura then
					-- burning halo behind the planet (animated in RenderStepped)
					local aura = new("Frame", {
						Name = "Aura",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.new(1, 34, 1, 34),
						BackgroundColor3 = Color3.fromHex("ff6a1f"),
						BackgroundTransparency = 0.45,
						ZIndex = 3,
						Parent = n.btn,
					}, { corner() })
					new("UIGradient", {
						Color = ColorSequence.new(Color3.fromHex("ffd34a"), Color3.fromHex("ff2a10")),
						Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.6, 0.3), NumberSequenceKeypoint.new(1, 1) }),
						Rotation = 90,
						Parent = aura,
					})
					n.aura = aura
				end
			else
				-- owner colour: tween on a flip (instant the first time)
				local key = s.owner
				local col = OWNER_COLOR[s.owner] or C.Muted
				if n.colorKey ~= key then
					if n.colorKey ~= nil and isOpen then
						TweenService:Create(n.btn, TweenInfo.new(1.8, Enum.EasingStyle.Sine), { BackgroundColor3 = col }):Play()
					else
						n.btn.BackgroundColor3 = col
					end
				end
				grad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(90, 90, 110))
				n.fire = nil
				if n.aura then
					n.aura:Destroy()
					n.aura = nil
				end
			end
			n.colorKey = if s.destroyed then "DESTROYED" else s.owner
			n.ring.Visible = s.op ~= nil or selected == id
			local rs = n.ring:FindFirstChildOfClass("UIStroke") :: UIStroke
			rs.Color = if selected == id then Color3.new(1, 1, 1) else C.Accent
			n.barBg.Visible = not s.destroyed and (s.defense ~= nil or s.owner ~= "FREE")
			n.fill.BackgroundColor3 = if s.defense then C.Accent else C.Friendly
			n.contested = not s.destroyed and (s.op ~= nil and (s.defense ~= nil or s.owner ~= "FREE") or (s.owner ~= "FREE" and s.lib > 0))
			n.arc.Visible = n.contested
		end
	end
end

-- node labels + bars, every frame from the eased value (so bars tween up and pressure ticks down)
local function stepNodes(dt: number)
	local st = warState()
	local o = outcomesNow()
	local t = workspace:GetServerTimeNow()
	local clock = os.clock()
	for id, n in nodes do
		local s = st[id]
		if s then
			local target = War.display(s)
			n.disp = n.disp or target
			local d = target - n.disp
			n.disp = if math.abs(d) < 0.0005 then target else n.disp + d * math.min(1, dt * 2.5)
			local v = n.disp
			if not s.destroyed then
				local falling = War.pressure(id, o, t) > 0 and (s.defense or s.lib) > 0
				local arrow = if falling then " ▼" else ""
				local text, col
				if s.defense then
					text, col = string.format("UNDER ATTACK · %.2f%%%s", v, arrow), C.Accent
				elseif s.owner ~= "FREE" then
					text, col = string.format("%.2f%% liberated%s", v, arrow), OWNER_COLOR[s.owner] or C.Muted
				else
					text, col = "Free", C.Friendly
				end
				local divers = diversAt(id)
				if divers > 0 then
					text ..= string.format("  ◉%d", divers)
				end
				if n.sub.Text ~= text then
					n.sub.Text = text
				end
				n.sub.TextColor3 = col
				n.fill.Size = UDim2.fromScale(math.clamp(v / 100, 0, 1), 1)
			end
			if n.contested and n.arc.Visible then
				-- front line: teal share = progress, a bright spark on the split that crackles
				local enemy = OWNER_COLOR[s.faction or s.owner] or C.Danger
				local p = math.clamp(v / 100 + math.noise(clock * 1.7, n.btn.AbsoluteSize.X) * 0.03, 0.05, 0.95)
				n.arcGrad.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, C.Friendly),
					ColorSequenceKeypoint.new(p - 0.035, C.Friendly),
					ColorSequenceKeypoint.new(p, Color3.fromHex("fff3c4")),
					ColorSequenceKeypoint.new(p + 0.035, enemy),
					ColorSequenceKeypoint.new(1, enemy),
				})
				n.arcGrad.Rotation = n.arcAngle + math.sin(clock * 0.9 + n.arcAngle) * 8
				n.arcStroke.Transparency = 0.05 + 0.25 * math.abs(math.noise(clock * 3, n.arcAngle))
			end
		end
	end
	-- supply lanes: slide the packets along each lane
	for _, l in lanes do
		if l.speed > 0 then
			local period = 1 / LANE_PULSES
			l.grad.Offset = Vector2.new((clock * l.speed / l.len) % period, 0)
		end
	end
end

-- Lane colour + flow direction: supplies flow from our space toward the front; enemy lanes flow toward us.
local adjacency: { [string]: { string } } = {}
local function refreshLanes()
	local st = warState()
	if next(adjacency) == nil then
		for id, p in Planets.byId do
			adjacency[id] = adjacency[id] or {}
			for _, o in p.links do
				adjacency[o] = adjacency[o] or {}
				table.insert(adjacency[id], o)
				table.insert(adjacency[o], id)
			end
		end
	end
	local function side(id: string): string
		local s = st[id]
		if not s or s.destroyed then
			return "dead"
		elseif s.owner ~= "FREE" then
			return "enemy"
		elseif s.defense then
			return "front"
		end
		return "free"
	end
	local function distFrom(match: (string) -> boolean): { [string]: number }
		local dist, queue, qi = {}, {}, 1
		for id in Planets.byId do
			if match(side(id)) then
				dist[id] = 0
				table.insert(queue, id)
			end
		end
		while qi <= #queue do
			local id = queue[qi]
			qi += 1
			for _, o in adjacency[id] or {} do
				if dist[o] == nil and side(o) ~= "dead" then
					dist[o] = dist[id] + 1
					table.insert(queue, o)
				end
			end
		end
		return dist
	end
	local toEnemy = distFrom(function(sd)
		return sd == "enemy" or sd == "front"
	end)
	local toFree = distFrom(function(sd)
		return sd == "free" or sd == "front"
	end)
	for _, l in lanes do
		local sa, sb = side(l.a), side(l.b)
		local dir, col, speed = 1, Color3.fromHex("6b7a96"), 0
		local ours = function(sd)
			return sd == "free" or sd == "front"
		end
		if sa == "dead" or sb == "dead" then
			col, speed = Color3.fromHex("3a2a26"), 0
		elseif ours(sa) and sb == "enemy" then
			col, speed, dir = C.Accent, 46, 1
		elseif sa == "enemy" and ours(sb) then
			col, speed, dir = C.Accent, 46, -1
		elseif ours(sa) and ours(sb) then
			col = C.Friendly
			speed = if sa == "front" or sb == "front" then 34 else 16
			if sb == "front" and sa ~= "front" then
				dir = 1
			elseif sa == "front" and sb ~= "front" then
				dir = -1
			else
				dir = if (toEnemy[l.b] or 99) <= (toEnemy[l.a] or 99) then 1 else -1
			end
		else -- enemy <-> enemy: their reinforcements flow toward us
			col = OWNER_COLOR[st[l.a].owner] or C.Danger
			speed = 14
			dir = if (toFree[l.b] or 99) <= (toFree[l.a] or 99) then 1 else -1
		end
		l.speed = speed
		l.frame.BackgroundColor3 = col
		l.frame.Rotation = l.angle + (if dir < 0 then 180 else 0)
		if speed == 0 then
			l.grad.Offset = Vector2.zero
		end
	end
	-- front-line arcs face our nearest free neighbours (or home)
	for id, n in nodes do
		local p = Planets.get(id) :: any
		local sum = Vector2.zero
		for _, o in adjacency[id] or {} do
			local so = side(o)
			if so == "free" or so == "front" then
				local op = (Planets.get(o) :: any).pos
				sum += Vector2.new((op.X - p.pos.X) * WORLD_W, (op.Y - p.pos.Y) * WORLD_H).Unit
			end
		end
		if sum.Magnitude < 0.01 then
			local home = (Planets.get("VERDANCE") :: any).pos
			sum = Vector2.new((home.X - p.pos.X) * WORLD_W, (home.Y - p.pos.Y) * WORLD_H)
		end
		if sum.Magnitude < 0.01 then
			sum = Vector2.new(-1, 0)
		end
		-- gradient keypoint 0 (teal) faces `sum`: the gradient axis points the other way
		n.arcAngle = math.deg(math.atan2(-sum.Y, -sum.X))
	end
end

-- "+0.42%" rising from a planet
local function floatText(id: string, text: string, color: Color3, big: boolean?)
	local p = Planets.get(id) :: any
	if not p or not world then
		return
	end
	local y0 = -24 * p.size - 6
	local l = label({
		Text = text,
		Font = Enum.Font.Michroma,
		TextSize = if big then 22 else 17,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(p.pos.X, 0, p.pos.Y, y0 + 10),
		Size = UDim2.fromOffset(220, 26),
		TextTransparency = 1,
		ZIndex = 30,
		Parent = world,
	})
	local st = l:FindFirstChildOfClass("UIStroke")
	TweenService:Create(l, TweenInfo.new(0.25), { TextTransparency = 0, Position = UDim2.new(p.pos.X, 0, p.pos.Y, y0) }):Play()
	task.delay(0.25, function()
		TweenService:Create(l, TweenInfo.new(if big then 3 else 2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(p.pos.X, 0, p.pos.Y, y0 - 70),
			TextTransparency = 1,
		}):Play()
		if st then
			TweenService:Create(st, TweenInfo.new(if big then 3 else 2), { Transparency = 1 }):Play()
		end
	end)
	task.delay(if big then 3.4 else 2.4, function()
		l:Destroy()
	end)
end

-- expanding ring around a planet
local function pulse(id: string, color: Color3, big: boolean?)
	local n = nodes[id]
	if not n then
		return
	end
	for i = 1, if big then 3 else 1 do
		task.delay((i - 1) * 0.25, function()
			local f = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, 4, 1, 4),
				BackgroundTransparency = 1,
				ZIndex = 4,
				Parent = n.btn,
			}, { corner() })
			local s = stroke(color, if big then 5 else 3, 0)
			s.Parent = f
			local grow = if big then 170 else 80
			local info = TweenInfo.new(if big then 1.6 else 1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(f, info, { Size = UDim2.new(1, grow, 1, grow) }):Play()
			TweenService:Create(s, info, { Transparency = 1 }):Play()
			task.delay(info.Time + 0.1, function()
				f:Destroy()
			end)
		end)
	end
end

local function playGain(id: string, dv: number)
	floatText(id, string.format("+%.2f%%", dv), C.Friendly)
	pulse(id, C.Friendly)
end

local function playFlip(id: string, s: any)
	local col, text
	if s.destroyed then
		col, text = Color3.fromHex("ff6a1f"), "DESTROYED"
	elseif s.owner == "FREE" then
		col, text = C.Gold, "LIBERATED"
	else
		col, text = OWNER_COLOR[s.owner] or C.Danger, "LOST"
	end
	floatText(id, text, col, true)
	pulse(id, col, true)
	audio(if s.owner == "FREE" and not s.destroyed then "MissionSuccess" else "UIError")
end

-- INFO PANEL --------------------------------------------------------------------------------------
local function activeOpFor(planetId: string)
	local t = workspace:GetServerTimeNow()
	local upcoming = nil
	for _, op in Campaign.Operations do
		if op.planet == planetId then
			local s, prog = opInfo(op, t)
			if s == "active" then
				return op, s, prog
			elseif s == "upcoming" and not upcoming then
				upcoming = op
			end
		end
	end
	if upcoming then
		return upcoming, "upcoming", 0
	end
	return nil, nil, 0
end

-- sparkline: server samples (warHist) + the live value as the last column
local function refreshSpark(id: string, s: any)
	local h = Store.get("warHist")
	local vals = {}
	if h and h.v and type(h.v[id]) == "table" then
		for _, v in h.v[id] do
			table.insert(vals, tonumber(v) or 0)
		end
	end
	table.insert(vals, War.display(s))
	local cols = panelRefs.sparkCols
	local n = #cols
	while #vals > n do
		table.remove(vals, 1)
	end
	local lo, hi = math.huge, -math.huge
	for _, v in vals do
		lo, hi = math.min(lo, v), math.max(hi, v)
	end
	local span = math.max(hi - lo, 0.5)
	local mid = (hi + lo) / 2
	lo = mid - span / 2 - span * 0.1
	span *= 1.2
	local first = n - #vals + 1
	local col = if s.defense then C.Accent else C.Friendly
	for i, f in cols do
		local v = vals[i - first + 1]
		f.Visible = v ~= nil
		if v then
			f.Size = UDim2.new(1 / n, -2, math.clamp((v - lo) / span, 0.06, 1), 0)
			f.BackgroundColor3 = if i == n then Color3.new(1, 1, 1) else col
			f.BackgroundTransparency = if i == n then 0 else 0.25 + 0.5 * (1 - (i - first) / math.max(1, n - first))
		end
	end
	local step = h and tonumber(h.step) or 120
	local spanSec = step * math.max(1, #vals - 1)
	local d = vals[#vals] - vals[1]
	local window = if spanSec >= 3300 then "LAST HOUR" else string.format("LAST %d MIN", math.max(1, math.floor(spanSec / 60 + 0.5)))
	panelRefs.sparkCap.Text = string.format("%s   %s%.2f%%", window, if d >= 0 then "▲ +" else "▼ ", d)
	panelRefs.sparkCap.TextColor3 = if d > 0.004 then C.Friendly elseif d < -0.004 then C.Danger else C.Muted
end

local function refreshPanel()
	if not panelRefs.title then
		return
	end
	local id = selected
	if not id then
		panelRefs.title.Text = "SELECT A PLANET"
		panelRefs.sub.Text = "Drag to pan · scroll / pinch to zoom"
		panelRefs.status.Text = ""
		panelRefs.bar.Visible = false
		panelRefs.value.Visible = false
		panelRefs.pressure.Visible = false
		panelRefs.spark.Visible = false
		panelRefs.divers.Visible = false
		panelRefs.countdown.Visible = false
		panelRefs.op.Text = ""
		panelRefs.launch.Visible = false
		panelRefs.options.Visible = false
		return
	end
	local p = Planets.get(id) :: any
	local s = warState()[id]
	local sec = Planets.Sectors[p.sector]
	local t = workspace:GetServerTimeNow()
	panelRefs.title.Text = string.upper(p.name)
	panelRefs.sub.Text = (sec and sec.name or "") .. " · " .. p.desc
	local op, opStatus, opProg = activeOpFor(id)
	local barColor, track = C.Friendly, C.Panel
	local hasBar = false
	if s.destroyed then
		panelRefs.status.Text = "DESTROYED — this world is lost forever. No missions possible."
		panelRefs.status.TextColor3 = C.Danger
	elseif s.defense then
		panelRefs.status.Text = string.format("UNDER ATTACK by %s · DEFENCE", ownerName(s.faction))
		panelRefs.status.TextColor3 = C.Accent
		barColor, track, hasBar = C.Accent, (OWNER_COLOR[s.faction] or C.Danger):Lerp(C.Navy, 0.6), true
	elseif s.owner ~= "FREE" then
		panelRefs.status.Text = string.format("Held by %s · LIBERATION", ownerName(s.owner))
		panelRefs.status.TextColor3 = OWNER_COLOR[s.owner] or C.Text
		barColor, track, hasBar = C.Friendly, (OWNER_COLOR[s.owner] or C.Danger):Lerp(C.Navy, 0.6), true
	else
		panelRefs.status.Text = "Free world · safe for now"
		panelRefs.status.TextColor3 = C.Friendly
	end
	panelRefs.bar.Visible = hasBar
	panelRefs.value.Visible = hasBar
	panelRefs.value.TextColor3 = barColor
	panelRefs.fill.BackgroundColor3 = barColor
	panelRefs.bar.BackgroundColor3 = track
	-- enemy pressure (decay of the active operation)
	local press = War.pressure(id, outcomesNow(), t)
	panelRefs.pressure.Visible = hasBar and press > 0
	panelRefs.pressure.Text = string.format("▼ ENEMY PRESSURE  −%.2f%% per hour", press)
	-- sparkline
	panelRefs.spark.Visible = hasBar
	if hasBar then
		refreshSpark(id, s)
	end
	-- divers deployed there now (all servers)
	local divers = diversAt(id)
	panelRefs.divers.Visible = not s.destroyed
	panelRefs.divers.Text = if divers > 0 then string.format("◉  %d diver%s deployed here right now", divers, if divers == 1 then "" else "s") else "○  No divers deployed here right now"
	panelRefs.divers.TextColor3 = if divers > 0 then C.Friendly else C.Muted
	-- operation countdown (ticks every second)
	if op then
		panelRefs.countdown.Visible = true
		if opStatus == "upcoming" then
			panelRefs.countdown.Text = string.format("★ %s  ·  STARTS IN %s", string.upper(op.title), fmtPrecise(op.starts - t))
		else
			panelRefs.countdown.Text = string.format("★ %s  ·  %d%%  ·  ENDS IN %s", string.upper(op.title), math.floor(opProg), fmtPrecise(op.ends - t))
		end
		panelRefs.op.Text = op.brief
	else
		panelRefs.countdown.Visible = false
		panelRefs.op.Text = ""
	end
	panelRefs.options.Visible = s.playable
	panelRefs.launch.Visible = true
	if s.playable then
		panelRefs.launch.Text = "LAUNCH MISSION"
		panelRefs.launch.BackgroundColor3 = C.Accent
	else
		panelRefs.launch.Text = if s.destroyed then "NO MISSIONS — DESTROYED" else "NO ENEMIES HERE"
		panelRefs.launch.BackgroundColor3 = C.Muted
	end
	for _, b in panelRefs.objBtns do
		b.BackgroundColor3 = if b:GetAttribute("Obj") == objective then C.Accent else C.Panel
		b.TextColor3 = if b:GetAttribute("Obj") == objective then C.Navy else C.Text
	end
	for i, b in panelRefs.diffBtns do
		b.BackgroundColor3 = if i == difficulty then C.Accent else C.Panel
		b.TextColor3 = if i == difficulty then C.Navy else C.Text
	end
end

local function buildPanel(parent: Instance, compact: boolean)
	local pnl = new("Frame", {
		Name = "Info",
		BackgroundColor3 = C.Navy,
		BackgroundTransparency = 0.08,
		ZIndex = 20,
		Parent = parent,
	}, { corner(10), stroke(C.Accent, 2, 0.3), new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) }) })
	panel = pnl
	local scroll = new("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -54),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ZIndex = 21,
		Parent = pnl,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	panelRefs.title = label({ Font = Enum.Font.Michroma, TextSize = if compact then 18 else 22, TextColor3 = C.Accent, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 1, ZIndex = 22, Parent = scroll })
	panelRefs.sub = label({ Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, ZIndex = 22, Parent = scroll })
	panelRefs.status = label({ TextSize = 13, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, ZIndex = 22, Parent = scroll })
	-- big live number (4 decimals so enemy pressure visibly ticks it down)
	panelRefs.value = label({ Font = Enum.Font.Michroma, TextSize = if compact then 22 else 28, TextColor3 = C.Friendly, TextWrapped = false, Size = UDim2.new(1, 0, 0, if compact then 26 else 32), LayoutOrder = 4, ZIndex = 22, Parent = scroll })
	local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 12), BackgroundColor3 = C.Panel, LayoutOrder = 5, ZIndex = 22, Parent = scroll }, { corner(6) })
	panelRefs.bar = bar
	panelRefs.fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Friendly, ZIndex = 23, Parent = bar }, { corner(6) })
	-- moving sheen on the fill so the bar reads as "live"
	panelRefs.sheen = new("UIGradient", {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.45, 0), NumberSequenceKeypoint.new(0.5, 0.0), NumberSequenceKeypoint.new(0.55, 0), NumberSequenceKeypoint.new(1, 0) }),
		Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.85, 0.85, 0.85)), ColorSequenceKeypoint.new(0.45, Color3.new(0.85, 0.85, 0.85)), ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)), ColorSequenceKeypoint.new(0.55, Color3.new(0.85, 0.85, 0.85)), ColorSequenceKeypoint.new(1, Color3.new(0.85, 0.85, 0.85)) }),
		Parent = panelRefs.fill,
	})
	panelRefs.pressure = label({ Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.Danger, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6, ZIndex = 22, Parent = scroll })
	-- sparkline of the last hour
	local spark = new("Frame", { Size = UDim2.new(1, 0, 0, 58), BackgroundColor3 = C.Panel, BackgroundTransparency = 0.4, LayoutOrder = 7, ZIndex = 22, Parent = scroll }, {
		corner(6),
		new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 6) }),
	})
	panelRefs.spark = spark
	panelRefs.sparkCap = label({ Text = "LAST HOUR", Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.Muted, TextWrapped = false, Size = UDim2.new(1, 0, 0, 12), ZIndex = 23, Parent = spark })
	local cols = new("Frame", { Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 1, -16), BackgroundTransparency = 1, ZIndex = 23, Parent = spark }, {
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	panelRefs.sparkCols = {}
	for i = 1, 31 do
		panelRefs.sparkCols[i] = new("Frame", { Size = UDim2.new(1 / 31, -2, 0.1, 0), BackgroundColor3 = C.Friendly, BorderSizePixel = 0, LayoutOrder = i, Visible = false, ZIndex = 24, Parent = cols }, { corner(1) })
	end
	panelRefs.divers = label({ Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.Friendly, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 8, ZIndex = 22, Parent = scroll })
	panelRefs.countdown = label({ Font = Enum.Font.GothamBlack, TextSize = 13, TextColor3 = C.Accent, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 9, ZIndex = 22, Parent = scroll })
	panelRefs.op = label({ Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.Gold, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 10, ZIndex = 22, Parent = scroll })
	local opts = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 11, ZIndex = 22, Parent = scroll }, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	panelRefs.options = opts
	label({ Text = "OBJECTIVE", TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 1, ZIndex = 22, Parent = opts })
	local objRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 2, ZIndex = 22, Parent = opts }, { new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }) })
	panelRefs.objBtns = {}
	for _, o in OBJECTIVES do
		local b = button(o.name, C.Panel, { Size = UDim2.new(0.5, -3, 1, 0), TextSize = 13, ZIndex = 23, Parent = objRow })
		b:SetAttribute("Obj", o.id)
		b.Activated:Connect(function()
			objective = o.id
			audio("UIClick")
			refreshPanel()
		end)
		table.insert(panelRefs.objBtns, b)
	end
	label({ Text = "DIFFICULTY", TextSize = 12, TextColor3 = C.Muted, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 3, ZIndex = 22, Parent = opts })
	local diffRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 4, ZIndex = 22, Parent = opts }, { new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }) })
	panelRefs.diffBtns = {}
	for i = 1, 5 do
		local b = button(tostring(i), C.Panel, { Size = UDim2.new(0.2, -5, 1, 0), TextSize = 15, ZIndex = 23, Parent = diffRow })
		b.Activated:Connect(function()
			difficulty = i
			audio("UIClick")
			refreshPanel()
		end)
		panelRefs.diffBtns[i] = b
	end
	local launch = button("LAUNCH MISSION", C.Accent, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 46),
		TextSize = 18,
		ZIndex = 22,
		Parent = pnl,
	})
	panelRefs.launch = launch
	launch.Activated:Connect(function()
		if not selected then
			return
		end
		local s = warState()[selected]
		if not s or not s.playable then
			audio("UIError")
			return
		end
		audio("UIClick")
		local ok, okReq, res = pcall(function()
			return Net.func("Request"):InvokeServer("startMission", { planet = selected, objective = objective, difficulty = difficulty })
		end)
		if ok and okReq then
			audio("UIOpen")
			WarMap.close()
		else
			audio("UIError")
			toast(tostring((if ok then res else okReq) or "Can't launch"), C.Danger)
		end
	end)
end

-- Side panel on wide screens, bottom sheet on phones / small windows.
local function layout()
	if not panel or not gui then
		return
	end
	local vp = workspace.CurrentCamera.ViewportSize
	local compact = vp.X < 760 or vp.Y < 480
	if compact then
		panel.AnchorPoint = Vector2.new(0.5, 1)
		panel.Position = UDim2.new(0.5, 0, 1, -8)
		panel.Size = UDim2.new(1, -16, 0, math.clamp(vp.Y * 0.42, 190, 300))
	else
		panel.AnchorPoint = Vector2.new(1, 0.5)
		panel.Position = UDim2.new(1, -16, 0.5, 25)
		panel.Size = UDim2.fromOffset(if vp.X < 1100 then 320 else 380, math.min(560, vp.Y - 90))
	end
	-- ticker + live feed share the left column (wide) / ticker left + feed top-right (phones)
	if compact then
		local feedW = math.clamp(vp.X * 0.36, 220, 320)
		local tickW = math.max(200, math.min(380, vp.X - 86 - feedW))
		if ticker then
			ticker.Size = UDim2.fromOffset(tickW, 0)
		end
		WarFeed.layout(true, UDim2.new(1, -8, 0, 58), Vector2.new(1, 0), feedW, vp.Y - 66 - panel.Size.Y.Offset - 16)
	else
		local colW = math.min(420, vp.X - 70 - panel.Size.X.Offset - 40)
		if ticker then
			ticker.Size = UDim2.fromOffset(colW, 0)
		end
		local tickBottom = if ticker then ticker.AbsolutePosition.Y + ticker.AbsoluteSize.Y else 60
		WarFeed.layout(false, UDim2.new(0, 70, 1, -12), Vector2.new(0, 1), colW, vp.Y - 12 - tickBottom - 12)
	end
end

local function buildTicker(parent: Instance)
	ticker = new("Frame", {
		Name = "Ticker",
		Position = UDim2.fromOffset(70, 60), -- right of the zoom buttons
		Size = UDim2.fromOffset(380, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = parent,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
end

local function refreshTicker()
	if not ticker then
		return
	end
	local t = workspace:GetServerTimeNow()
	for i, op in Campaign.Operations do
		local status, prog = opInfo(op, t)
		local text, color
		if status == "active" then
			local divers = diversAt(op.planet)
			text = string.format("★ %s — %s  %.1f%%%s  · %s left", op.title, (Planets.get(op.planet) :: any).name, prog, if divers > 0 then string.format("  ◉%d", divers) else "", fmtTime(op.ends - t))
			color = C.Accent
		elseif status == "expired" then
			text = op.title .. " — deadline reached, resolving…"
			color = C.Muted
		elseif status == "upcoming" and op.starts - t < 3 * 86400 then
			text = string.format("• %s — starts in %s", op.title, fmtTime(op.starts - t))
			color = C.Muted
		elseif status == "success" then
			text = op.title .. " — VICTORY"
			color = C.Friendly
		elseif status == "fail" or status == "expired" then
			text = op.title .. " — FAILED"
			color = C.Danger
		end
		-- rows are updated in place (not rebuilt each second) so a tap/click is never swallowed mid-press
		local row = ticker:FindFirstChild("Op_" .. op.id) :: TextButton?
		if text then
			if not row then
				local r = button(text, C.Panel, {
					Name = "Op_" .. op.id,
					Size = UDim2.new(1, 0, 0, 30),
					TextSize = 13,
					TextColor3 = color,
					Font = Enum.Font.GothamBold,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					BackgroundTransparency = 0.15,
					LayoutOrder = i,
					ZIndex = 21,
					Parent = ticker,
				})
				new("UIPadding", { PaddingLeft = UDim.new(0, 10), Parent = r })
				r.Activated:Connect(function()
					WarMap.select(op.planet, true)
				end)
				row = r
			end
			local r2 = row :: TextButton
			r2.Text = text
			r2.TextColor3 = color
		elseif row then
			row:Destroy()
		end
	end
end

-- PUBLIC ------------------------------------------------------------------------------------------
function WarMap.select(id: string, centre: boolean?)
	selected = id
	audio("UIClick")
	if centre then
		local p = Planets.get(id) :: any
		pan = Vector2.new((0.5 - p.pos.X) * WORLD_W * zoom, (0.5 - p.pos.Y) * WORLD_H * zoom)
		applyView()
	end
	refreshNodes()
	refreshPanel()
end

function WarMap.isOpen(): boolean
	return isOpen
end

function WarMap.open()
	if isOpen or not gui then
		return
	end
	isOpen = true
	gui.Enabled = true
	Store.set("menuOpen", true)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	audio("UIOpen")
	pcall(function()
		Net.event("Action"):FireServer("warSync")
	end)
	layout()
	task.defer(fitZoom)
	-- default selection: the first active operation
	if not selected then
		local t = workspace:GetServerTimeNow()
		for _, op in Campaign.Operations do
			if opInfo(op, t) == "active" then
				selected = op.planet
				break
			end
		end
	end
	cachedState = nil
	refreshNodes()
	refreshLanes()
	refreshPanel()
	refreshTicker()
	WarFeed.refresh()
	-- replay what changed while the map was closed (your own mission, other servers)
	if next(missed) or next(missedFlips) then
		local gains, flips = missed, missedFlips
		missed, missedFlips = {}, {}
		task.delay(0.7, function()
			if not isOpen then
				return
			end
			local st = warState()
			local i = 0
			for id in flips do
				task.delay(i * 0.35, playFlip, id, st[id])
				i += 1
			end
			for id, dv in gains do
				if not flips[id] then
					task.delay(i * 0.35, playGain, id, dv)
					i += 1
				end
			end
		end)
	end
end

function WarMap.close()
	if not isOpen then
		return
	end
	isOpen = false
	gui.Enabled = false
	Store.set("menuOpen", nil)
end

function WarMap.init()
	local compact = workspace.CurrentCamera.ViewportSize.X < 900
	gui = new("ScreenGui", {
		Name = "OrbitWarMap",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 30,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local bg = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromHex("070a12"),
		BorderSizePixel = 0,
		Parent = gui,
	})
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromHex("1a1030"), Color3.fromHex("05070d")),
		Rotation = 90,
		Parent = bg,
	})
	canvas = new("Frame", {
		Name = "Canvas",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Active = true,
		Parent = gui,
	})
	world = new("Frame", {
		Name = "World",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WORLD_W, WORLD_H),
		BackgroundTransparency = 1,
		Parent = canvas,
	})
	worldScale = new("UIScale", { Parent = world })
	buildWorld()

	-- top bar
	local top = new("Frame", {
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundColor3 = C.Navy,
		BackgroundTransparency = 0.1,
		ZIndex = 20,
		Parent = gui,
	}, { stroke(C.Accent, 1, 0.5) })
	label({
		Text = "GALACTIC WAR  ·  " .. string.upper(Config.ShipName) .. " TACTICAL MAP",
		Font = Enum.Font.Michroma,
		TextSize = if compact then 13 else 18,
		TextColor3 = C.Accent,
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -200, 1, 0),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 21,
		Parent = top,
	})
	local closeBtn = button("CLOSE", C.Panel, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(100, 36),
		TextColor3 = C.Text,
		ZIndex = 21,
		Parent = top,
	})
	closeBtn.Activated:Connect(WarMap.close)
	-- zoom buttons (mobile friendly)
	local zoomCol = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.45, 0),
		Size = UDim2.fromOffset(48, 150),
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = gui,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6) }) })
	for _, def in { { "+", 1.25 }, { "-", 0.8 }, { "FIT", 0 } } do
		local b = button(def[1], C.Panel, { Size = UDim2.fromOffset(48, 46), TextSize = if def[1] == "FIT" then 13 else 24, TextColor3 = C.Text, ZIndex = 21, Parent = zoomCol })
		b.Activated:Connect(function()
			if def[2] == 0 then
				fitZoom()
			else
				setZoom(zoom * def[2])
			end
		end)
	end
	buildTicker(gui)
	buildPanel(gui, compact)
	WarFeed.build(gui, {
		onPlanet = function(id)
			WarMap.select(id, true)
		end,
		audio = audio,
	})

	-- pan / zoom input
	local dragging: InputObject? = nil
	local lastPos: Vector2? = nil
	local moved = 0
	canvas.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			if not dragging then
				dragging = io
				lastPos = Vector2.new(io.Position.X, io.Position.Y)
				moved = 0
			end
		end
	end)
	UserInputService.InputChanged:Connect(function(io)
		if not isOpen then
			return
		end
		if io.UserInputType == Enum.UserInputType.MouseWheel then
			local mp = UserInputService:GetMouseLocation()
			setZoom(zoom * (if io.Position.Z > 0 then 1.12 else 1 / 1.12), mp)
		elseif dragging and lastPos and (io == dragging or (io.UserInputType == Enum.UserInputType.MouseMovement and dragging.UserInputType == Enum.UserInputType.MouseButton1)) then
			local p = Vector2.new(io.Position.X, io.Position.Y)
			local d = p - lastPos
			lastPos = p
			moved += d.Magnitude
			pan += d
			applyView()
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if dragging and (io == dragging or io.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = nil
			lastPos = nil
		end
	end)
	-- TouchPinch's `scale` is cumulative since the gesture began, so scale from the zoom at pinch start
	local pinchStartZoom = zoom
	UserInputService.TouchPinch:Connect(function(_, scale, _, state)
		if not isOpen then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinchStartZoom = zoom
		elseif state == Enum.UserInputState.Change then
			setZoom(pinchStartZoom * scale)
		end
	end)
	canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		layout()
		applyView()
	end)

	-- every war push: diff against the previous push (both evaluated at the same moment, so decay cancels out)
	-- -> "+x%" ticks for gains (local or other servers), big pulses for flips
	Store.on("war", function(w)
		local t = workspace:GetServerTimeNow()
		local newSt = computeFrom(w, t)
		if prevWar then
			local oldSt = computeFrom(prevWar, t)
			for id, s in newSt do
				local o = oldSt[id]
				if o and nodes[id] then
					local flipped = o.owner ~= s.owner or (s.destroyed and not o.destroyed)
					if flipped then
						if isOpen then
							playFlip(id, s)
						else
							missedFlips[id] = true
						end
					elseif not s.destroyed and (s.defense ~= nil) == (o.defense ~= nil) then
						local dv = War.display(s) - War.display(o)
						if dv > 0.005 then
							if isOpen then
								playGain(id, dv)
							else
								missed[id] = (missed[id] or 0) + dv
							end
						end
					end
				end
			end
		end
		prevWar = w
		cachedState = newSt
		cachedAt = os.clock()
		if isOpen then
			refreshNodes()
			refreshLanes()
			refreshPanel()
			refreshTicker()
		end
	end)
	Store.on("warFeed", function()
		WarFeed.refresh()
	end)
	Store.on("warLive", function()
		if isOpen then
			refreshPanel()
			refreshTicker()
		end
	end)
	Store.on("warHist", function()
		if isOpen then
			refreshPanel()
		end
	end)

	-- animate: pulsing op rings, burning destroyed planets, live values, lanes, feed, countdowns
	local acc = 0
	local watchAcc = 0
	RunService.RenderStepped:Connect(function(dt)
		if not isOpen then
			return
		end
		local t = os.clock()
		stepNodes(dt)
		WarFeed.step(dt)
		-- selected planet: big ticking number + bar from the eased value
		local sn = selected and nodes[selected]
		if sn and sn.disp and panelRefs.value and panelRefs.value.Visible then
			panelRefs.value.Text = string.format("%.4f%%", sn.disp)
			panelRefs.fill.Size = UDim2.fromScale(math.clamp(sn.disp / 100, 0, 1), 1)
			panelRefs.sheen.Offset = Vector2.new(((t * 0.4) % 2) - 1, 0)
		end
		for _, n in nodes do
			if n.ring.Visible then
				local s = 1 + 0.08 * math.sin(t * 4)
				n.ring.Size = UDim2.new(s, 22, s, 22)
			end
			if n.fire then
				n.fire.Rotation = (t * 40) % 360
				n.fire.Offset = Vector2.new(math.noise(t * 2, 1) * 0.15, math.noise(t * 2, 2) * 0.15)
			end
			if n.aura then
				local f = math.noise(t * 6, 3) -- flicker
				local grow = 30 + 10 * math.sin(t * 3) + f * 8
				n.aura.Size = UDim2.new(1, grow, 1, grow)
				n.aura.BackgroundTransparency = 0.4 + f * 0.25
				local g = n.aura:FindFirstChildOfClass("UIGradient")
				if g then
					g.Rotation = 90 + math.noise(t * 2, 4) * 40
				end
			end
		end
		acc += dt
		if acc > 1 then
			acc = 0
			refreshPanel()
			refreshTicker()
			layout() -- ticker height changes move the feed
		end
		-- tell the server someone is watching, so it reads other servers' divers + squad events
		watchAcc += dt
		if watchAcc > 20 then
			watchAcc = 0
			pcall(function()
				Net.event("Action"):FireServer("warWatch")
			end)
		end
	end)

	-- the holo-table prompt routes through Screens.open("Mission") -> WarMap.open()
	-- leave the map when a mission starts
	Store.on("mission", function(m)
		if m and m.state ~= "Ship" and isOpen then
			WarMap.close()
		end
	end)
end

return WarMap
