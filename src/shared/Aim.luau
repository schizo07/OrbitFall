--!strict
-- Shared bullet origin. The server traces every shot from here toward the client's crosshair point
-- (server/WeaponService), and the client mirrors the same trace (client/WeaponController barrelTrace) so tracers,
-- impacts and the barrel reticle show where the bullet really lands. Built from the root + the replicated `Stance`
-- character attribute only: client-side poses (prone tilt, aim lean) don't replicate, so a posed Head would put the
-- client's origin ~1.5-2 studs away from the server's when prone.
local Aim = {}

Aim.SIDE = 1.0 -- studs to the root's right (the rifle shoulder); mirrored to the left when the gun is in the left hand
-- origin height above / forward of the HumanoidRootPart centre per stance (about where the head sits in the client
-- pose; measured in Play 2026-11-14: head y 1.47 standing, 1.38 crouched, -0.31 and 1.4 forward prone)
Aim.HEIGHT = {
	stand = 1.5,
	crouch = 1.4,
	prone = -0.3,
	dive = -0.3,
}
Aim.FORWARD = {
	prone = 1.3,
	dive = 1.3,
}

-- hand: +1 gun on the right shoulder (default), -1 on the left (the replicated `Hand` character attribute on the
-- server, CombatPose.handSign() on the owning client)
function Aim.origin(c: Model?, hand: number?): Vector3?
	if not c then
		return nil
	end
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local st = c:GetAttribute("Stance")
	local key = if type(st) == "string" then st else "stand"
	local h = Aim.HEIGHT[key] or Aim.HEIGHT.stand
	local fwd = Aim.FORWARD[key] or 0
	local cf = root.CFrame
	local side = if type(hand) == "number" and hand < 0 then -Aim.SIDE else Aim.SIDE
	return cf.Position + Vector3.new(0, h, 0) + cf.RightVector * side + cf.LookVector * fwd
end

return Aim
