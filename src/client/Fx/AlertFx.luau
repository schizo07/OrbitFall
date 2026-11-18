--!nonstrict

-- Enemy awareness markers (server: src/server/Enemies/Awareness.luau).
-- Reads enemy model attributes:
--   Aware = "idle" | "sus" | "alert"   (nil = hunting, no marker)
--   Suspicion = 0..1                    (steps of 0.1)
-- "sus": a "?" over the enemy that fills up from the bottom with Suspicion.
-- "alert" right after "idle" / "sus": a "!" that pops in with a bounce and a beep, then fades out after ~1.5 s.
-- Pooled billboards (MAX_MARKERS, nearest to the camera first), fixed pixel size so they read on phones.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AlertFx = {}

local Audio: any

local C3 = Color3.fromRGB
local SUS_DIM = C3(70, 64, 48)
local SUS_FILL = C3(255, 214, 64)
local BANG = C3(255, 70, 46)
local STROKE = C3(20, 16, 14)

local MAX_MARKERS = 12
local MAX_DIST = 170 -- studs from the camera
local POP_LIFE = 1.5 -- seconds the "!" stays (fades over the last FADE)
local FADE = 0.4
local PICK_EVERY = 0.1
local W, H = 34, 42 -- marker size in pixels
local BEEP_GAP = 0.25 -- at most one pop beep this often

type Rec = {
	m: Model,
	root: BasePart?,
	up: number?,
	aware: string?,
	popT: number?,
	fill: number,
	marker: any?,
	conn: RBXScriptConnection?,
}

local recs: { [Model]: Rec } = {}
local pool: { any } = {}
local free: { any } = {}
local lastBeep = 0

-- Markers ------------------------------------------------------------------------------
local function label(parent: Instance, text: string, color: Color3, transparency: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromOffset(W, H)
	l.AnchorPoint = Vector2.new(0, 1)
	l.Position = UDim2.fromScale(0, 1)
	l.Font = Enum.Font.FredokaOne
	l.Text = text
	l.TextSize = H
	l.TextColor3 = color
	l.TextTransparency = transparency
	l.TextStrokeTransparency = 1
	local s = Instance.new("UIStroke")
	s.Color = STROKE
	s.Thickness = 2.5
	s.Transparency = transparency
	s.Parent = l
	l.Parent = parent
	return l
end

local function makeMarker(parentGui: Instance): any
	local gui = Instance.new("BillboardGui")
	gui.Name = "AlertMarker"
	gui.ResetOnSpawn = false
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = MAX_DIST
	gui.Size = UDim2.fromOffset(W, H)
	gui.Enabled = false

	-- "?" : dim back + a clip frame (anchored at the bottom) that shows the bright copy up to the fill height
	local q = Instance.new("Frame")
	q.Name = "Q"
	q.BackgroundTransparency = 1
	q.Size = UDim2.fromScale(1, 1)
	q.Parent = gui
	label(q, "?", SUS_DIM, 0.15)
	local clip = Instance.new("Frame")
	clip.Name = "Clip"
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.AnchorPoint = Vector2.new(0, 1)
	clip.Position = UDim2.fromScale(0, 1)
	clip.Size = UDim2.fromScale(1, 0)
	clip.Parent = q
	label(clip, "?", SUS_FILL, 0)

	-- "!" with a scale bounce
	local bang = label(gui, "!", BANG, 0)
	bang.Name = "Bang"
	bang.AnchorPoint = Vector2.new(0.5, 1)
	bang.Position = UDim2.fromScale(0.5, 1)
	local sc = Instance.new("UIScale")
	sc.Parent = bang

	gui.Parent = parentGui
	return { gui = gui, q = q, clip = clip, bang = bang, bangStroke = bang:FindFirstChildOfClass("UIStroke"), scale = sc, rec = nil }
end

local function release(rec: Rec)
	local mk = rec.marker
	if mk then
		rec.marker = nil
		mk.rec = nil
		mk.gui.Enabled = false
		mk.gui.Adornee = nil
		table.insert(free, mk)
	end
end

local function topOffset(rec: Rec): number
	if rec.up then
		return rec.up
	end
	local root = rec.root
	local up = 4
	if root then
		local ok, cf, size = pcall(function()
			return rec.m:GetBoundingBox()
		end)
		if ok and cf and size then
			up = math.max(cf.Position.Y + size.Y / 2 - root.Position.Y, 2) + 1.6
		end
	end
	rec.up = up
	return up
end

-- Tracking -----------------------------------------------------------------------------
local function onAware(rec: Rec)
	local new = rec.m:GetAttribute("Aware")
	local old = rec.aware
	rec.aware = if type(new) == "string" then new else nil
	if rec.aware == "alert" and (old == "idle" or old == "sus") then
		rec.popT = os.clock()
		local t = os.clock()
		if t - lastBeep >= BEEP_GAP and rec.root and Audio then
			lastBeep = t
			pcall(Audio.play, "MineBeep", rec.root.Position, { pitch = 1.45, volume = 0.7 })
		end
	elseif rec.aware ~= "alert" then
		rec.popT = nil
	end
end

local function add(m: Instance)
	if not m:IsA("Model") or recs[m] then
		return
	end
	local a = m:GetAttribute("Aware")
	local rec: Rec = {
		m = m,
		root = m.PrimaryPart,
		up = nil,
		aware = if type(a) == "string" then a else nil,
		popT = nil,
		fill = 0,
		marker = nil,
		conn = nil,
	}
	rec.conn = m:GetAttributeChangedSignal("Aware"):Connect(function()
		onAware(rec)
	end)
	recs[m] = rec
end

local function remove(m: Instance)
	local rec = recs[m :: Model]
	if not rec then
		return
	end
	recs[m :: Model] = nil
	if rec.conn then
		rec.conn:Disconnect()
	end
	release(rec)
end

-- Pick + draw --------------------------------------------------------------------------
local wanted: { Rec } = {}
local dists: { [Rec]: number } = {}
local pickT = 0

local function wants(rec: Rec, t: number): boolean
	if rec.aware == "sus" then
		return true
	end
	return rec.popT ~= nil and t - rec.popT < POP_LIFE
end

local function pick(t: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local cp = cam.CFrame.Position
	table.clear(wanted)
	table.clear(dists)
	for _, rec in recs do
		if not rec.root or not rec.root.Parent then
			rec.root = rec.m.PrimaryPart
		end
		local root = rec.root
		if root and wants(rec, t) then
			local d = (root.Position - cp).Magnitude
			if d <= MAX_DIST then
				dists[rec] = d
				table.insert(wanted, rec)
			end
		end
	end
	table.sort(wanted, function(a, b)
		return dists[a] < dists[b]
	end)
	-- free markers of records that dropped out
	local keep: { [Rec]: boolean } = {}
	for i = 1, math.min(#wanted, MAX_MARKERS) do
		keep[wanted[i]] = true
	end
	for _, mk in pool do
		local r = mk.rec
		if r and not keep[r] then
			release(r)
		end
	end
	for i = 1, math.min(#wanted, MAX_MARKERS) do
		local rec = wanted[i]
		if not rec.marker then
			local mk = table.remove(free)
			if mk then
				mk.rec = rec
				rec.marker = mk
				rec.fill = tonumber(rec.m:GetAttribute("Suspicion")) or 0
				mk.gui.Adornee = rec.root
				mk.gui.StudsOffset = Vector3.new(0, topOffset(rec), 0)
				mk.gui.Enabled = true
			end
		end
	end
end

local function draw(dt: number)
	local t = os.clock()
	if t - pickT >= PICK_EVERY then
		pickT = t
		pick(t)
	end
	for _, mk in pool do
		local rec: Rec? = mk.rec
		if rec then
			if rec.aware == "sus" then
				local s = math.clamp(tonumber(rec.m:GetAttribute("Suspicion")) or 0, 0, 1)
				rec.fill += (s - rec.fill) * math.min(1, dt * 8)
				mk.q.Visible = true
				mk.bang.Visible = false
				mk.clip.Size = UDim2.fromScale(1, 0.12 + 0.88 * rec.fill)
			elseif rec.popT then
				local age = t - rec.popT
				mk.q.Visible = false
				mk.bang.Visible = true
				local s
				if age < 0.16 then
					s = 1.6 * age / 0.16
				elseif age < 0.34 then
					s = 1.6 - 0.6 * (age - 0.16) / 0.18
				else
					s = 1
				end
				mk.scale.Scale = math.max(s, 0.01)
				local fade = math.clamp((age - (POP_LIFE - FADE)) / FADE, 0, 1)
				mk.bang.TextTransparency = fade
				if mk.bangStroke then
					mk.bangStroke.Transparency = fade
				end
			end
		end
	end
end

-- Init ---------------------------------------------------------------------------------
function AlertFx.init(_fx: any, audio: any, _juice: any)
	Audio = audio
	task.spawn(function()
		local pg = Players.LocalPlayer:WaitForChild("PlayerGui", 30)
		if not pg then
			return
		end
		for _ = 1, MAX_MARKERS do
			local mk = makeMarker(pg)
			table.insert(pool, mk)
			table.insert(free, mk)
		end
		local folder = workspace:WaitForChild("Enemies", 120)
		if not folder then
			return
		end
		for _, m in folder:GetChildren() do
			add(m)
		end
		folder.ChildAdded:Connect(add)
		folder.ChildRemoved:Connect(remove)
	end)
	RunService.RenderStepped:Connect(draw)
end

return AlertFx
