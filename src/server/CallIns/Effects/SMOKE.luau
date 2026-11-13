-- Smoke Screen: a wall across the throw direction (length across, width deep, 10 tall).
-- Enemies inside lose track: AI should query S.CallIns.isInSmoke(pos); as a fallback they are confused.
local FALL = 0.6
local HEIGHT = 10

return function(ctx)
	local S = ctx.S
	local prm = ctx.params
	local pos = ctx.groundAt(ctx.pos)
	local id = ctx.nextId()

	S.Fx.play("Shell", { p = pos, t = FALL, s = 0.6, c = Color3.fromRGB(200, 200, 205) })
	task.wait(FALL)

	local cf = CFrame.lookAt(pos, pos + ctx.dir)
	S.Fx.play("Smoke", { id = id, p = pos, dir = ctx.dir, length = prm.length, width = prm.width, t = prm.duration })
	local remove = ctx.addSmoke(cf, prm.length, prm.width, HEIGHT)
	ctx.onStop(remove)

	local startT = os.clock()
	while os.clock() - startT < prm.duration do
		task.wait(0.5)
		local reach = math.max(prm.length, prm.width) / 2 + 6
		for _, e in S.Enemies.getInRadius(pos + Vector3.new(0, 4, 0), reach) do
			if e.alive and e.root and S.CallIns.isInSmoke(e.root.Position) then
				S.Enemies.applyStatus(e, "confuse", 1.2)
			end
		end
	end
end
