--!nonstrict
-- Dust storms on desert and ash maps, the same for the whole squad.
-- Workspace attributes (read by client/Fx/Weather.luau):
--   Weather     "calm" | "storm"
--   WeatherAt   server time (workspace:GetServerTimeNow) the current phase started
--   WeatherEnd  server time it ends (0 = no cycle running: ship, or a biome without storms)
-- Cycle: calm 2-4 min, then a storm of 40-70 s. Visibility only: enemies keep their normal perception.
-- Studio: Feel_Weather "clear" (no storms) | "now" (a storm starts at once, calm phases shortened to 20 s),
-- mirrored from the client switcher by the "studioFeel" action.

local RunService = game:GetService("RunService")

local WeatherService = {}

local STORM_BIOMES = { desert = true, ash = true }
local CALM = { 120, 240 }
local STORM = { 40, 70 }
local IS_STUDIO = RunService:IsStudio()

local rng = Random.new()
local state = "calm"
local phaseEnd = 0
local cycleMap: Instance? = nil

local function feel(): string?
	if not IS_STUDIO then
		return nil
	end
	local a = workspace:GetAttribute("Feel_Weather")
	return if type(a) == "string" then a else nil
end

local function set(s: string, at: number, ends: number)
	state, phaseEnd = s, ends
	workspace:SetAttribute("Weather", s)
	workspace:SetAttribute("WeatherAt", at)
	workspace:SetAttribute("WeatherEnd", ends)
end

local function calmFor(now: number)
	local len = if feel() == "now" then 20 else rng:NextNumber(CALM[1], CALM[2])
	set("calm", now, now + len)
end

local function stormFor(now: number)
	set("storm", now, now + rng:NextNumber(STORM[1], STORM[2]))
end

local function tick()
	local now = workspace:GetServerTimeNow()
	local map = workspace:FindFirstChild("Map")
	local biome = map and map:GetAttribute("Biome")
	if not map or not STORM_BIOMES[biome] or feel() == "clear" then
		cycleMap = nil
		if state ~= "calm" or phaseEnd ~= 0 then
			set("calm", now, 0)
		end
		return
	end
	if map ~= cycleMap then -- new mission map: always start calm
		cycleMap = map
		calmFor(now)
		return
	end
	if now >= phaseEnd then
		if state == "storm" then
			calmFor(now)
		else
			stormFor(now)
		end
	end
end

function WeatherService.init(_S: any)
	set("calm", workspace:GetServerTimeNow(), 0)
	if IS_STUDIO then
		workspace:GetAttributeChangedSignal("Feel_Weather"):Connect(function()
			local map = workspace:FindFirstChild("Map")
			if feel() == "now" and map and STORM_BIOMES[map:GetAttribute("Biome")] and state ~= "storm" then
				cycleMap = map
				stormFor(workspace:GetServerTimeNow())
			end
		end)
	end
	task.spawn(function()
		while true do
			local ok, err = pcall(tick)
			if not ok then
				warn("[Weather]", err)
			end
			task.wait(1)
		end
	end)
end

return WeatherService
