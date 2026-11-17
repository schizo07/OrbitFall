--!nonstrict
-- Client presentation of the Director's pacing layer (server: src/server/Enemies/Director.luau, tunables:
-- src/shared/Data/Intensity.luau). Loaded automatically by Fx.init (init(Fx, Audio, Juice)).
--
-- Inputs
--   Store "intensity"  {state = "off"|"calm"|"build"|"breach"|"relax", t0, endsAt, dir (bearing deg, 0 = N, 90 = E), wave, breach,
--                       extract (bool), faction}     (S.State.broadcast from the Director)
--   Fx "HeavyContact"  {p, kind, name, class}       (S.Fx.to: only players within ~120 studs)
--   Store "mission".extract {eta, window?}          (Mission.setExtract) -> extraction countdown
--
-- What it shows (visuals live in UI/AlertBar.luau: the 24 px ALERT BAR under the compass tape + an amber callout line)
--   * ALERT BAR (sticky, pulses twice when it appears): BUILD amber "SEISMIC ACTIVITY - NE"; BREACH red "BREACH DETECTED - NE"
--     with a rotating direction arrow + time-left clock/bar; extraction "HOLD THE PAD ..."; RELAX green "BREACH REPELLED"
--   * siren + shake + flash on the breach (unchanged), no big banner any more
--   * small amber callout line "HEAVY CONTACT - name . NE . 84 m" with a rotating arrow
--   * extraction countdown ("SKIFF ETA 0:42" -> "BOARD NOW 0:18") as the top-priority alert bar entry, tick sounds in the last 10 s
--   * audio: BUILD = rising positional rumble / machinery from the breach side + growing shake; BREACH = horn; music swell via
--     Audio.setMusicIntensity

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local IT = require(Shared:WaitForChild("Data"):WaitForChild("Intensity"))

local IntensityFx = {}

local Fx: any
local Audio: any
local Juice: any
local Store: any
local Theme: any
local C: any
local AlertBar: any
local HudStyle: any

local built = false
local cur: any = nil -- latest "intensity" snapshot
local buildLoopToken = 0
local lastTick = -1
local lastExtractKey = ""
local heavy = { bearing = 0, p = Vector3.zero, active = false }

local MUSIC = { off = 0.5, calm = 0.3, build = 0.6, breach = 0.95, relax = 0.4, extract = 1.0 }
local PRIO = { build = 1, relax = 1, breach = 2, hold = 2, extract = 3 }

local function now(): number
	return workspace:GetServerTimeNow()
end

local function camYaw(): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 0
	end
	local look = cam.CFrame.LookVector
	return math.deg(math.atan2(look.X, -look.Z))
end

local function relDeg(bearing: number, yaw: number): number
	return (bearing - yaw + 180) % 360 - 180
end

-- called every frame for the alert clock: the string is only formatted again when the whole second changes
local fmtSec, fmtText = -1, ""
local function fmtTime(s: number): string
	s = math.max(0, math.ceil(s))
	if s ~= fmtSec then
		fmtSec, fmtText = s, string.format("%d:%02d", s // 60, s % 60)
	end
	return fmtText
end

local function music(level: number, fade: number?)
	if Audio and Audio.setMusicIntensity then
		Audio.setMusicIntensity(level, fade)
	end
end

local function farPos(bearing: number, dist: number): Vector3?
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	return cam.CFrame.Position + IT.bearingVector(bearing) * dist + Vector3.new(0, -8, 0)
end

-- UI --------------------------------------------------------------------------------------------------------------
local function build()
	if built then
		return
	end
	built = true
	AlertBar.init()
end

-- Alert bar entries for the current snapshot (the per-frame step only moves the arrow and the clock)
local function refreshAlert()
	if not built then
		return
	end
	local s = cur
	if not s or s.state == "off" or s.state == "calm" then
		AlertBar.clear("build")
		AlertBar.clear("breach")
		AlertBar.clear("hold")
		AlertBar.clear("relax")
		return
	end
	if s.state == "relax" then
		-- the all-clear entry is set by onTransition and expires by itself
		AlertBar.clear("build")
		AlertBar.clear("breach")
		AlertBar.clear("hold")
		return
	end
	AlertBar.clear("relax")
	local W = IT.Warnings[s.faction] or IT.WarningDefault
	local dirShort = IT.compassShort(s.dir or 0)
	if s.extract then
		AlertBar.clear("build")
		AlertBar.clear("breach")
		AlertBar.set("hold", string.format("HOLD THE PAD - WAVE %d - %s", s.wave or 0, dirShort), { color = HudStyle.Red, priority = PRIO.hold, arrow = true })
	elseif s.state == "breach" then
		AlertBar.clear("build")
		AlertBar.clear("hold")
		AlertBar.set("breach", string.format("BREACH DETECTED - %s", dirShort), { color = HudStyle.Red, priority = PRIO.breach, arrow = true })
	else -- build
		AlertBar.clear("breach")
		AlertBar.clear("hold")
		AlertBar.set("build", string.format("%s - %s", W.title, dirShort), { color = HudStyle.Amber, priority = PRIO.build })
	end
end

-- Cues ------------------------------------------------------------------------------------------------------------
local function startBuildLoop()
	buildLoopToken += 1
	local my = buildLoopToken
	task.spawn(function()
		while my == buildLoopToken and cur and cur.state == "build" do
			local s = cur
			local W = IT.Warnings[s.faction] or IT.WarningDefault
			local total = math.max((s.endsAt or 0) - (s.t0 or 0), 1)
			local p = math.clamp((now() - (s.t0 or now())) / total, 0, 1)
			if Audio then
				local pos = farPos(s.dir or 0, 260 - 110 * p)
				if pos then
					Audio.play(W.sound, pos, { volume = 0.55 + 0.6 * p, priority = 4 })
				end
			end
			if Juice then
				Juice.shake(0.2 + 0.7 * p, 0.9)
			end
			music(0.45 + 0.4 * p, 3)
			task.wait(math.max(4.2 - 2.4 * p, 1.6))
		end
	end)
end

local function onTransition(old: string, new: string, s: any, _extractNew: boolean)
	buildLoopToken += 1 -- stops a running BUILD loop (restarted below when needed)
	if new == "build" then
		refreshAlert()
		music(0.5, 2)
		startBuildLoop()
	elseif new == "breach" then
		refreshAlert()
		if Audio then
			Audio.play2D("BreachHorn")
			local pos = farPos(s.dir or 0, 200)
			if pos then
				Audio.play("WarnRumble", pos, { volume = 1.3, priority = 5 })
			end
		end
		if Juice then
			Juice.flash(C.Danger, 0.3, 0.6)
			Juice.shake(2.2, 1.2)
		end
		music(MUSIC.breach, 1.2)
	elseif new == "relax" then
		music(MUSIC.relax, 4)
		refreshAlert()
		if old == "breach" or old == "build" then
			-- brief all-clear entry (expires by itself)
			AlertBar.set("relax", "BREACH REPELLED - MOP UP THE STRAGGLERS", { color = HudStyle.Green, priority = PRIO.relax, seconds = 5 })
			if Audio then
				Audio.play2D("ObjectiveDone", { volume = 0.5 })
			end
		end
	elseif new == "calm" then
		music(MUSIC.calm, 5)
		refreshAlert()
	else -- "off"
		music(MUSIC.off, 1)
		refreshAlert()
	end
end

local function onIntensity(s: any)
	if type(s) ~= "table" or not built then
		return
	end
	local old = cur
	cur = s
	local oldState = old and old.state or "off"
	local extractNew = s.extract == true and not (old and old.extract == true)
	if s.state ~= oldState or extractNew then
		onTransition(oldState, s.state, s, extractNew)
	else
		-- same phase, new wave / new side: refresh and ping
		local newWave = old and (s.wave ~= old.wave or s.dir ~= old.dir)
		refreshAlert()
		if newWave and s.state == "breach" then
			if Audio then
				local pos = farPos(s.dir or 0, 190)
				if pos then
					Audio.play("WarnRumble", pos, { volume = 0.95, priority = 4 })
				end
			end
			if Juice then
				Juice.shake(0.7, 0.6)
			end
		end
	end
	if s.extract then
		music(MUSIC.extract, 1.5)
	end
end

local function onHeavy(d: any)
	if type(d) ~= "table" or typeof(d.p) ~= "Vector3" or not built then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local delta = d.p - cam.CFrame.Position
	local bearing = IT.bearingOf(Vector3.new(delta.X, 0, delta.Z))
	local dist = Vector3.new(delta.X, 0, delta.Z).Magnitude
	heavy.bearing = bearing
	heavy.p = d.p
	heavy.active = true
	local behemoth = d.class == "behemoth"
	local title = if behemoth then "BEHEMOTH CONTACT" else "HEAVY CONTACT"
	local text = string.format("%s - %s | %s | %d M", title, string.upper(tostring(d.name or "UNKNOWN")), IT.compassShort(bearing), math.floor(dist + 0.5))
	AlertBar.callout(text, if behemoth then HudStyle.Red else HudStyle.Amber, 3.0, true)
	if Audio then
		Audio.play2D("HeavyContact")
	end
	if Juice then
		Juice.shake(behemoth and 1.2 or 0.7, 0.5)
	end
end

-- Per frame ---------------------------------------------------------------------------------------------------------
local function stepExtract(t: number)
	local m = Store.get("mission")
	local ex = m and m.state == "Extract" and m.extract
	if not ex or not ex.eta then
		if lastExtractKey ~= "" then
			lastExtractKey = ""
			AlertBar.clear("extract")
		end
		lastTick = -1
		return
	end
	local label, left, total, col
	local shuttle = string.upper(Config.ShuttleName)
	if ex.window and t < ex.window then
		label, left, total, col = "BOARD NOW", ex.window - t, Config.ExtractWindow, HudStyle.Green
	elseif t < ex.eta then
		label, left, total = shuttle .. " ETA - HOLD THE PAD", ex.eta - t, math.max(Config.ExtractEta, ex.eta - t)
		col = HudStyle.Red
	elseif not ex.window then
		-- holding over a hot pad / landing: the server's label, and the paused boarding time when there is one
		label, left, total, col = ex.label or (shuttle .. " DESCENDING"), 0, 1, HudStyle.Red
		if type(ex.paused) == "number" then
			left, total = ex.paused, Config.ExtractWindow
		end
	else
		if lastExtractKey ~= "" then
			lastExtractKey = ""
			AlertBar.clear("extract")
		end
		return
	end
	local key = label .. tostring(col)
	if key ~= lastExtractKey then
		lastExtractKey = key
		AlertBar.set("extract", label, { color = col, priority = PRIO.extract })
	end
	if AlertBar.isShowing("extract") then
		local waiting = t >= ex.eta and not (ex.window and t < ex.window) and type(ex.paused) ~= "number"
		AlertBar.setClock(if waiting then "..." else fmtTime(left), math.clamp(left / math.max(total, 1), 0, 1))
	end
	-- last 10 s of the ETA: a tick per second
	if t < ex.eta and left <= 10 then
		local sec = math.ceil(left)
		if sec ~= lastTick then
			lastTick = sec
			if Audio then
				Audio.play2D(if sec <= 3 then "UIClick" else "DialTick", { volume = 0.9 })
			end
			if Juice and sec <= 3 then
				Juice.shake(0.4, 0.3)
			end
		end
	end
end

local function step(_dt: number)
	if not built then
		return
	end
	local t = now()
	local yaw = camYaw()
	local s = cur
	local mission = Store.get("mission")
	local inMission = mission and (mission.state == "Active" or mission.state == "Extract")
	AlertBar.setVisible(inMission == true)
	if s then
		if AlertBar.isShowing("breach") or AlertBar.isShowing("hold") then
			AlertBar.setArrow(relDeg(s.dir or 0, yaw))
		end
		if (AlertBar.isShowing("breach") or AlertBar.isShowing("build")) and (s.endsAt or 0) > 0 then
			local total = math.max(s.endsAt - s.t0, 1)
			local left = math.max(s.endsAt - t, 0)
			AlertBar.setClock(fmtTime(left), math.clamp(if s.state == "build" then (t - s.t0) / total else left / total, 0, 1))
		end
	end
	if heavy.active and AlertBar.calloutVisible() then
		local cam = workspace.CurrentCamera
		if cam then
			local d = heavy.p - cam.CFrame.Position
			AlertBar.setCalloutArrow(relDeg(IT.bearingOf(Vector3.new(d.X, 0, d.Z)), yaw))
		end
	end
	stepExtract(t)
end

-- Init --------------------------------------------------------------------------------------------------------------
local function findClientRoot(): Instance?
	local inst: Instance? = script.Parent
	for _ = 1, 4 do
		if inst and inst:FindFirstChild("Store") then
			return inst
		end
		inst = inst and inst.Parent
	end
	return nil
end

function IntensityFx.init(fx: any, audio: any, juice: any)
	Fx, Audio, Juice = fx, audio, juice
	local root = findClientRoot()
	if not root then
		warn("[IntensityFx] client root not found")
		return
	end
	Store = require(root.Store)
	Theme = require((root :: any).UI.Theme)
	HudStyle = require((root :: any).UI.HudStyle)
	AlertBar = require((root :: any).UI.AlertBar)
	C = Theme.C

	Fx.register("HeavyContact", onHeavy)

	task.spawn(function()
		-- the GUI needs PlayerGui (yields until it exists); Fx.init must not block on it
		build()
		RunService.RenderStepped:Connect(step)
		Store.on("intensity", onIntensity)
	end)
end

return IntensityFx
