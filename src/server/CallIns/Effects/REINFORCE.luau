-- Reinforce: every fallen squadmate (while the team pool lasts) drops in on the beacon.
return function(ctx)
	local S = ctx.S
	local pos = ctx.groundAt(ctx.pos)

	local dead = S.Players.getDead()
	if #dead == 0 then
		return
	end
	S.Fx.play("Sound", { k = "ShipRadio", p = pos })

	local revived = 0
	for _, player in dead do
		if S.Mission and S.Mission.useLife and not S.Mission.useLife() then
			if revived == 0 and ctx.owner then
				S.State.notify(ctx.owner, "No reinforcements left", nil, "callin")
			end
			break
		end
		revived += 1
		S.Players.respawnAt(player, pos)
		task.wait(0.3)
	end
	if revived > 0 and ctx.owner then
		S.State.notify(nil, ("%d squadmate%s reinforced"):format(revived, revived == 1 and "" or "s"), Color3.fromRGB(62, 230, 200), "callin")
	end
end
