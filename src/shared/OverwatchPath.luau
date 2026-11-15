-- Flight path of the Overwatch Skiff call-in. The server (CallIns/Effects/OVERWATCH) uses it to place the door gun, every
-- client (Fx "OverwatchSkiff" in client/Fx/CallInFx) uses it to draw the hull, so both always agree on where it is.
--   OverwatchPath.total(duration)        -> seconds from the Fx start to the Skiff being gone
--   OverwatchPath.cframe(centre, radius, duration, tau) -> hull CFrame at tau seconds after the start (nose = -Z), and
--                                          whether it is on the circle (true) or flying in / out (false)
-- `centre` is the circle centre at flight height. The Skiff comes in along the tangent, circles clockwise seen from above
-- (the beacon is on its right, where the door gun side is) and leaves along the tangent.

local OverwatchPath = {}

OverwatchPath.APPROACH_TIME = 4 -- s flying in
OverwatchPath.LEAVE_TIME = 4 -- s flying out
local APPROACH_DIST = 170 -- studs from the circle entry point at tau = 0
local CLIMB = 45 -- studs it comes in below / leaves above the flight height
local SPEED = 15 -- studs/s along the circle
local BANK = math.rad(13)
local START_ANGLE = -0.6 -- radians; entry point on the circle

function OverwatchPath.total(duration: number): number
	return OverwatchPath.APPROACH_TIME + duration + OverwatchPath.LEAVE_TIME
end

local function onCircle(centre: Vector3, radius: number, theta: number): (Vector3, Vector3)
	local pos = centre + Vector3.new(math.cos(theta) * radius, 0, math.sin(theta) * radius)
	local fwd = Vector3.new(-math.sin(theta), 0, math.cos(theta))
	return pos, fwd
end

function OverwatchPath.cframe(centre: Vector3, radius: number, duration: number, tau: number): (CFrame, boolean)
	local tin, tout = OverwatchPath.APPROACH_TIME, OverwatchPath.LEAVE_TIME
	local w = SPEED / math.max(radius, 1)
	local a = (APPROACH_DIST - SPEED * tin) / (tin * tin) -- decelerates from fast to circle speed exactly on arrival
	if tau < tin then
		local left = tin - math.max(tau, 0)
		local p0, f0 = onCircle(centre, radius, START_ANGLE)
		local back = a * left * left + SPEED * left
		local k = back / APPROACH_DIST
		local pos = p0 - f0 * back - Vector3.new(0, CLIMB * k, 0)
		return CFrame.lookAt(pos, pos + f0) * CFrame.Angles(0, 0, -BANK * (1 - k)), false
	end
	if tau <= tin + duration then
		local theta = START_ANGLE + w * (tau - tin)
		local pos, fwd = onCircle(centre, radius, theta)
		return CFrame.lookAt(pos, pos + fwd) * CFrame.Angles(0, 0, -BANK), true
	end
	local s = math.min(tau - tin - duration, tout)
	local pe, fe = onCircle(centre, radius, START_ANGLE + w * duration)
	local ahead = SPEED * s + a * s * s
	local k = ahead / APPROACH_DIST
	local pos = pe + fe * ahead + Vector3.new(0, CLIMB * k, 0)
	return CFrame.lookAt(pos, pos + fe) * CFrame.Angles(0, 0, -BANK * (1 - k)), false
end

return OverwatchPath
