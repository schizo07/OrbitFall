--!nonstrict
-- Client audio engine (docs/spec.md §10). Layered, rate-limited, voice-capped, positional.
--
--   Audio.play(key, at, opts?)    at: Vector3 | BasePart | Attachment | CFrame | nil (nil = non-positional)
--                                 opts: {volume = 1, pitch = 1, source = any (perSource limiting), priority = n}
--                                 returns true when at least one layer was started/scheduled
--   Audio.play2D(key, opts?)
--   Audio.loop(key, at?, opts?) -> {stop(fade?), setVolume(v), setPitch(p), setPosition(v3), isPlaying()}
--   Audio.duck(groups, db, seconds)
--   Audio.setMusic(key|nil, fade?)
--   Audio.setGroupVolume(group, v) / Audio.setMasterVolume(v)
--   Audio.preload()               background ContentProvider:PreloadAsync of every non-empty id
--   Audio.init()                  idempotent (also called lazily)
--   Audio.stopAll()
--   Audio.distanceToListener(pos)
--
-- Layers with empty ids ("") are silently skipped, so the game runs mute until the catalogue is filled.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Sounds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sounds"))

local Audio = {}

local VOICE_CAP = 48
local LOOP_CAP = 24
local POOL_PER_ID = 4
local ONE_SHOT_TIMEOUT = 15

local GROUP_VOLUMES = {
	Weapons = 0.85,
	Impacts = 0.8,
	Explosions = 1.0,
	Enemies = 0.85,
	CallIns = 0.95,
	UI = 0.75,
	Ambience = 0.5,
	Music = 0.4,
}

local master: SoundGroup? = nil
local groupObjs: { [string]: SoundGroup } = {}
local groupBase: { [string]: number } = {}
local holder: Part? = nil
local attachPool: { Attachment } = {}

local voiceSet: { [any]: boolean } = {}
local voiceCount = 0
local loopCount = 0
local soundPool: { [string]: { Sound } } = {}
local limitState: { [string]: { number } } = {}
local warned: { [string]: boolean } = {}
local hasIdsCache: { [any]: boolean } = {}

local rng = Random.new()

-- INIT ------------------------------------------------------------------------------

function Audio.init()
	if master then
		return
	end
	local old = SoundService:FindFirstChild("OrbitMaster")
	if old then
		old:Destroy()
	end
	local m = Instance.new("SoundGroup")
	m.Name = "OrbitMaster"
	m.Volume = 1

	local comp = Instance.new("CompressorSoundEffect")
	comp.Name = "MasterCompressor"
	comp.Threshold = -14
	comp.Ratio = 4
	comp.Attack = 0.005
	comp.Release = 0.15
	comp.GainMakeup = 2
	comp.Parent = m

	local eq = Instance.new("EqualizerSoundEffect")
	eq.Name = "MasterEQ"
	eq.LowGain = 3
	eq.MidGain = 0
	eq.HighGain = 1
	eq.Parent = m

	for name, vol in GROUP_VOLUMES do
		local g = Instance.new("SoundGroup")
		g.Name = name
		g.Volume = vol
		g.Parent = m
		groupObjs[name] = g
		groupBase[name] = vol
	end
	m.Parent = SoundService
	master = m

	local oldPart = workspace:FindFirstChild("ClientAudio")
	if oldPart then
		oldPart:Destroy()
	end
	local p = Instance.new("Part")
	p.Name = "ClientAudio"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.1, 0.1, 0.1)
	p.CFrame = CFrame.new(0, 3000, 0)
	p.Parent = workspace
	holder = p
end

local function ensure()
	if not master then
		Audio.init()
	end
end

-- HELPERS ---------------------------------------------------------------------------

local function warnOnce(msg: string)
	if not warned[msg] then
		warned[msg] = true
		warn("[Audio] " .. msg)
	end
end

local function getAttachment(): Attachment
	local a = table.remove(attachPool)
	if a and a.Parent then
		return a
	end
	a = Instance.new("Attachment")
	a.Parent = holder
	return a
end

local function releaseAttachment(a: Attachment)
	if #attachPool < 64 and a.Parent then
		table.insert(attachPool, a)
	else
		a:Destroy()
	end
end

local function resolvePos(at: any): Vector3?
	local t = typeof(at)
	if t == "Vector3" then
		return at
	elseif t == "CFrame" then
		return at.Position
	elseif t == "Instance" then
		if at:IsA("BasePart") then
			return at.Position
		elseif at:IsA("Attachment") then
			return at.WorldPosition
		elseif at:IsA("Model") then
			return at:GetPivot().Position
		end
	end
	return nil
end

function Audio.distanceToListener(pos: Vector3): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 0
	end
	return (cam.CFrame.Position - pos).Magnitude
end

local function range(v: any, default: any): number
	if v == nil then
		v = default
	end
	if type(v) == "number" then
		return v
	end
	local lo, hi = v[1], v[2] or v[1]
	if lo == hi then
		return lo
	end
	return lo + (hi - lo) * rng:NextNumber()
end

local function acquireSound(id: string): Sound
	local list = soundPool[id]
	local s = list and table.remove(list)
	if s then
		return s
	end
	s = Instance.new("Sound")
	s.SoundId = id
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	return s
end

local function recycleSound(s: Sound)
	s.Parent = nil
	local id = s.SoundId
	local list = soundPool[id]
	if not list then
		list = {}
		soundPool[id] = list
	end
	if #list < POOL_PER_ID then
		s.Volume = 0
		table.insert(list, s)
	else
		s:Destroy()
	end
end

local function entryHasIds(entry: any): boolean
	local c = hasIdsCache[entry]
	if c == nil then
		c = false
		for _, l in entry.layers do
			if l.id and l.id ~= "" then
				c = true
				break
			end
		end
		hasIdsCache[entry] = c
	end
	return c
end

-- VOICES ----------------------------------------------------------------------------

local function finishVoice(v)
	if v.done then
		return
	end
	v.done = true
	voiceSet[v] = nil
	voiceCount -= 1
	for _, c in v.conns do
		c:Disconnect()
	end
	local s = v.sound
	if s.Parent then
		s:Stop()
	end
	if v.att then
		releaseAttachment(v.att)
	end
	recycleSound(s)
end

local function cullFor(priority: number): boolean
	local victim, vp, vt = nil, math.huge, math.huge
	for v in voiceSet do
		if v.priority < vp or (v.priority == vp and v.t < vt) then
			victim, vp, vt = v, v.priority, v.t
		end
	end
	if victim and victim.priority <= priority then
		finishVoice(victim)
		return true
	end
	return false
end

-- Starts one layer as a one-shot voice. pos nil => non-positional.
local function startVoice(layer, entry, pos: Vector3?, volume: number, pitch: number, priority: number)
	local id = layer.id
	if id == nil or id == "" then
		return
	end
	if voiceCount >= VOICE_CAP and not cullFor(priority) then
		return
	end
	local group = groupObjs[layer.group or entry.group or "Weapons"]
	local snd = acquireSound(id)
	snd.Looped = false
	snd.Volume = volume
	snd.PlaybackSpeed = pitch
	snd.SoundGroup = group
	snd.TimePosition = 0

	local att: Attachment? = nil
	if pos then
		att = getAttachment()
		att.WorldPosition = pos
		snd.RollOffMinDistance = layer.minDist or 10
		snd.RollOffMaxDistance = layer.maxDist or 450
		snd.Parent = att
	else
		snd.Parent = SoundService
	end

	local v = { sound = snd, att = att, priority = priority, t = os.clock(), done = false, conns = {} }
	voiceSet[v] = true
	voiceCount += 1
	v.conns[1] = snd.Ended:Once(function()
		finishVoice(v)
	end)
	v.conns[2] = snd.Stopped:Once(function()
		finishVoice(v)
	end)
	snd:Play()
	task.delay(ONE_SHOT_TIMEOUT, finishVoice, v)
end

-- RATE LIMIT ------------------------------------------------------------------------

local function passLimit(key: string, entry, source: any): boolean
	local lim = entry.limit
	if not lim then
		return true
	end
	local lk = key
	if entry.perSource and source ~= nil then
		lk = key .. "|" .. tostring(source)
	end
	local times = limitState[lk]
	if not times then
		times = {}
		limitState[lk] = times
	end
	local now = os.clock()
	local cutoff = now - lim.window
	local i = 1
	while i <= #times do
		if times[i] < cutoff then
			table.remove(times, i)
		else
			i += 1
		end
	end
	if #times >= lim.count then
		return false
	end
	table.insert(times, now)
	return true
end

-- DUCKING ---------------------------------------------------------------------------

local ducks = {}
local duckConn: RBXScriptConnection? = nil

local function updateDucks()
	local now = os.clock()
	local mults = {}
	for i = #ducks, 1, -1 do
		local d = ducks[i]
		local t = now - d.t0
		if t >= d.dur then
			table.remove(ducks, i)
		else
			local m
			local hold = d.dur * 0.4
			if t < 0.04 then
				m = 1 + (d.mult - 1) * (t / 0.04)
			elseif t < hold then
				m = d.mult
			else
				m = d.mult + (1 - d.mult) * ((t - hold) / (d.dur - hold))
			end
			local cur = mults[d.group]
			if cur == nil or m < cur then
				mults[d.group] = m
			end
		end
	end
	for name, obj in groupObjs do
		obj.Volume = groupBase[name] * (mults[name] or 1)
	end
	if #ducks == 0 and duckConn then
		duckConn:Disconnect()
		duckConn = nil
	end
end

function Audio.duck(groups: { string } | string, db: number, seconds: number)
	ensure()
	if type(groups) == "string" then
		groups = { groups }
	end
	local mult = 10 ^ (db / 20)
	local now = os.clock()
	for _, g in groups do
		if groupObjs[g] then
			table.insert(ducks, { group = g, mult = mult, t0 = now, dur = math.max(seconds, 0.1) })
		end
	end
	if not duckConn and #ducks > 0 then
		duckConn = RunService.Heartbeat:Connect(updateDucks)
	end
end

function Audio.setGroupVolume(group: string, v: number)
	ensure()
	if groupObjs[group] then
		groupBase[group] = v
		groupObjs[group].Volume = v
	end
end

function Audio.setMasterVolume(v: number)
	ensure()
	master.Volume = v
end

-- PLAY ------------------------------------------------------------------------------

function Audio.play(key: string, at: any?, opts: { volume: number?, pitch: number?, source: any?, priority: number? }?): boolean
	local entry = Sounds[key]
	if not entry then
		warnOnce("unknown sound key " .. tostring(key))
		return false
	end
	if not entryHasIds(entry) then
		return false
	end
	ensure()
	opts = opts or {}
	if not passLimit(key, entry, opts.source) then
		return false
	end

	local pos = resolvePos(at)
	local dist = 0
	if pos then
		dist = Audio.distanceToListener(pos)
	end
	local nearDist = entry.nearDist or 40
	local farDist = entry.farDist or 120
	local volMul = opts.volume or 1
	local pitchMul = opts.pitch or 1
	local priority = opts.priority or entry.priority or 2
	local played = false

	for _, layer in entry.layers do
		local id = layer.id
		if id ~= nil and id ~= "" then
			local ok = true
			if layer.far and dist < farDist then
				ok = false
			elseif layer.near and dist > nearDist then
				ok = false
			elseif pos and dist > (layer.maxDist or 450) then
				ok = false
			elseif layer.chance and rng:NextNumber() > layer.chance then
				ok = false
			end
			if ok then
				played = true
				local varv = layer.volVar or 0.1
				local vol = (layer.vol or 1) * volMul * (1 + (rng:NextNumber() * 2 - 1) * varv)
				local pitch = range(layer.pitch, { 0.95, 1.05 }) * pitchMul
				local delay = range(layer.delay, 0)
				-- sub-bass "felt" copy: non-positional, quieter with distance
				local pHi = if type(layer.pitch) == "table" then layer.pitch[2] or layer.pitch[1] else layer.pitch
				local felt = pos ~= nil and layer.near and (layer.felt == true or (pHi ~= nil and pHi <= 0.65))
				local feltVol = vol * 0.6 * math.clamp(1 - dist / math.max(nearDist, 1), 0.25, 1)
				if delay > 0.001 then
					task.delay(delay, function()
						startVoice(layer, entry, pos, vol, pitch, priority)
						if felt then
							startVoice(layer, entry, nil, feltVol, pitch, priority)
						end
					end)
				else
					startVoice(layer, entry, pos, vol, pitch, priority)
					if felt then
						startVoice(layer, entry, nil, feltVol, pitch, priority)
					end
				end
			end
		end
	end

	if played and entry.duck and dist <= farDist * 1.5 then
		Audio.duck(entry.duck.groups, entry.duck.db, entry.duck.seconds)
	end
	return played
end

function Audio.play2D(key: string, opts: { volume: number?, pitch: number?, source: any?, priority: number? }?): boolean
	return Audio.play(key, nil, opts)
end

-- LOOPS -----------------------------------------------------------------------------

function Audio.loop(key: string, at: any?, opts: { volume: number?, pitch: number? }?)
	local handle = {}
	local entry = Sounds[key]
	local dead = false
	local sounds = {}
	local att: Attachment? = nil

	local function noop() end
	handle.stop = noop
	handle.setVolume = noop
	handle.setPitch = noop
	handle.setPosition = noop
	handle.isPlaying = function()
		return false
	end

	if not entry then
		warnOnce("unknown sound key " .. tostring(key))
		return handle
	end
	if not entryHasIds(entry) or loopCount >= LOOP_CAP then
		return handle
	end
	ensure()
	opts = opts or {}

	local layers = {}
	for _, l in entry.layers do
		if l.loop and l.id and l.id ~= "" then
			table.insert(layers, l)
		end
	end
	if #layers == 0 then
		for _, l in entry.layers do
			if l.id and l.id ~= "" then
				table.insert(layers, l)
			end
		end
	end
	if #layers == 0 then
		return handle
	end

	local parent: Instance = SoundService
	local followsInstance = false
	if typeof(at) == "Vector3" or typeof(at) == "CFrame" then
		att = getAttachment()
		att.WorldPosition = if typeof(at) == "CFrame" then at.Position else at
		parent = att
	elseif typeof(at) == "Instance" and (at:IsA("BasePart") or at:IsA("Attachment")) then
		parent = at
		followsInstance = true
	end

	local volMul = opts.volume or 1
	local pitchMul = opts.pitch or 1
	loopCount += 1

	for _, l in layers do
		local s = Instance.new("Sound")
		s.SoundId = l.id
		s.Looped = true
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = l.minDist or 10
		s.RollOffMaxDistance = l.maxDist or 450
		s.PlaybackSpeed = range(l.pitch, { 0.98, 1.02 }) * pitchMul
		s.SoundGroup = groupObjs[l.group or entry.group or "Ambience"]
		s.Volume = 0
		s.Parent = parent
		table.insert(sounds, { sound = s, base = l.vol or 1, pitch = s.PlaybackSpeed })
	end
	local curVol = volMul
	local function applyVolume(fade: number)
		for _, e in sounds do
			if e.sound.Parent then
				if fade > 0 then
					TweenService:Create(e.sound, TweenInfo.new(fade, Enum.EasingStyle.Quad), { Volume = e.base * curVol }):Play()
				else
					e.sound.Volume = e.base * curVol
				end
			end
		end
	end
	for _, e in sounds do
		e.sound:Play()
	end
	applyVolume(0.15)

	local function cleanup()
		if dead then
			return
		end
		dead = true
		loopCount -= 1
		for _, e in sounds do
			e.sound:Destroy()
		end
		if att then
			releaseAttachment(att)
			att = nil
		end
	end
	if followsInstance then
		-- following a part/attachment: clean up when it is destroyed
		parent.Destroying:Once(cleanup)
	end

	handle.stop = function(fade: number?)
		if dead then
			return
		end
		local f = fade or 0.2
		if f > 0 then
			for _, e in sounds do
				if e.sound.Parent then
					TweenService:Create(e.sound, TweenInfo.new(f, Enum.EasingStyle.Quad), { Volume = 0 }):Play()
				end
			end
			task.delay(f + 0.05, cleanup)
		else
			cleanup()
		end
	end
	handle.setVolume = function(v: number)
		curVol = v * volMul
		if not dead then
			applyVolume(0)
		end
	end
	handle.setPitch = function(p: number)
		if not dead then
			for _, e in sounds do
				e.sound.PlaybackSpeed = e.pitch * p
			end
		end
	end
	handle.setPosition = function(p: Vector3)
		if att and not dead then
			att.WorldPosition = p
		end
	end
	handle.isPlaying = function()
		return not dead
	end
	return handle
end

-- MUSIC -----------------------------------------------------------------------------

local musicKey: string? = nil
local musicSound: Sound? = nil
local musicPitch = 1
local musicRamp = 0 -- invalidates a running volume ramp
local MUSIC_LEVEL_DEFAULT = 0.5

-- Pacing swell (client/Fx/IntensityFx.luau): level 0 = quiet .. 1 = full tilt. Ramps the Music group's volume (0.7x..1.3x of
-- its base) and the playback speed (0.96x..1.04x). 0.5 = the unmodified mix (call with 0.5 to reset). Persists across tracks.
function Audio.setMusicIntensity(level: number, fade: number?)
	ensure()
	level = math.clamp(level, 0, 1)
	local f = math.max(fade or 1.2, 0.05)
	musicPitch = 0.96 + 0.08 * level
	if musicSound then
		TweenService:Create(musicSound, TweenInfo.new(f, Enum.EasingStyle.Quad), { PlaybackSpeed = musicPitch }):Play()
	end
	local target = GROUP_VOLUMES.Music * (0.7 + 0.6 * level)
	local from = groupBase.Music or GROUP_VOLUMES.Music
	musicRamp += 1
	local my = musicRamp
	local t0 = os.clock()
	task.spawn(function()
		while my == musicRamp do
			local a = math.clamp((os.clock() - t0) / f, 0, 1)
			local v = from + (target - from) * a
			groupBase.Music = v -- ducking multiplies this base, so it keeps working
			if not duckConn and groupObjs.Music then
				groupObjs.Music.Volume = v
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
	end)
end
Audio.MUSIC_LEVEL_DEFAULT = MUSIC_LEVEL_DEFAULT

function Audio.setMusic(key: string?, fade: number?)
	ensure()
	local f = fade or 1.5
	if key == musicKey then
		return
	end
	local old = musicSound
	musicKey = key
	musicSound = nil
	if old then
		TweenService:Create(old, TweenInfo.new(f, Enum.EasingStyle.Quad), { Volume = 0 }):Play()
		task.delay(f + 0.1, function()
			old:Destroy()
		end)
	end
	if not key then
		return
	end
	local entry = Sounds[key]
	if not entry then
		warnOnce("unknown music key " .. tostring(key))
		return
	end
	local layer = nil
	for _, l in entry.layers do
		if l.id and l.id ~= "" then
			layer = l
			break
		end
	end
	if not layer then
		return
	end
	local s = Instance.new("Sound")
	s.Name = "Music_" .. key
	s.SoundId = layer.id
	s.Looped = true
	s.Volume = 0
	s.PlaybackSpeed = musicPitch
	s.SoundGroup = groupObjs.Music
	s.Parent = SoundService
	s:Play()
	TweenService:Create(s, TweenInfo.new(f, Enum.EasingStyle.Quad), { Volume = layer.vol or 1 }):Play()
	musicSound = s
end

-- MISC ------------------------------------------------------------------------------

function Audio.stopAll()
	for v in voiceSet do
		finishVoice(v)
	end
end

-- Warms the asset cache and the Sound pool. Runs in the background.
function Audio.preload()
	ensure()
	task.spawn(function()
		local ids: { string } = {}
		local seen = {}
		for _, entry in Sounds do
			for _, l in entry.layers do
				if l.id and l.id ~= "" and not seen[l.id] then
					seen[l.id] = true
					table.insert(ids, l.id)
				end
			end
		end
		local BATCH = 16
		for i = 1, #ids, BATCH do
			local batch = {}
			for j = i, math.min(i + BATCH - 1, #ids) do
				local s = Instance.new("Sound")
				s.SoundId = ids[j]
				s.RollOffMode = Enum.RollOffMode.InverseTapered
				table.insert(batch, s)
			end
			local ok, err = pcall(function()
				ContentProvider:PreloadAsync(batch)
			end)
			if not ok then
				warn("[Audio] preload failed: " .. tostring(err))
			end
			for _, s in batch do
				local list = soundPool[s.SoundId]
				if not list then
					list = {}
					soundPool[s.SoundId] = list
				end
				if #list < POOL_PER_ID then
					s.Volume = 0
					table.insert(list, s)
				else
					s:Destroy()
				end
			end
			task.wait()
		end
	end)
end

return Audio
