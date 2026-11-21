-- Pickup notification router: classifies server Notify pickup texts and routes compact lines into EventFeed.
local Style = require(script.Parent.HudStyle)
local EventFeed = require(script.Parent.EventFeed)

local PickupToast = {}

local lastAcquired = -100

function PickupToast.build(_parent: Instance, _isTouch: boolean) end

function PickupToast.setVisible(_on: boolean) end

function PickupToast.show(text: string, shape: string?, color: Color3?, plus: number?)
	local short = string.gsub(text, "^ACQUIRED%s+", "")
	short = string.gsub(short, "^SAMPLE COLLECTED%s+", "SAMPLE ")
	EventFeed.pickup(short, shape or "diamond", color or Style.Orange, plus)
end

function PickupToast.route(text: string): boolean
	local lower = string.lower(text)
	local n, m = string.match(text, "^Sample collected %((%d+)/(%d+)%)")
	if n then
		PickupToast.show(string.format("SAMPLE COLLECTED  %s/%s", n, m), "diamond", Style.Green)
		return true
	end
	if string.find(lower, "^sample collected") then
		PickupToast.show("SAMPLE COLLECTED", "diamond", Style.Green)
		return true
	end
	local sig = string.match(text, "^Cell signal found: (.+)$")
	if sig then
		PickupToast.show("CELL SIGNAL FOUND  " .. sig, "diamond", Style.Cyan)
		return true
	end
	if string.find(lower, "^cell signal found") then
		PickupToast.show("CELL SIGNAL FOUND", "diamond", Style.Cyan)
		return true
	end
	local charge = string.match(text, "^Lifter charging (%d+/%d+)$")
	if charge then
		PickupToast.show("LIFTER CHARGING  " .. charge, "bar", Style.Amber)
		return true
	end
	local item, amt = string.match(text, "^Acquired (.-) %+(%d+)$")
	if item then
		lastAcquired = os.clock()
		local isStim = string.find(string.lower(item), "stim") ~= nil
		PickupToast.show("ACQUIRED  " .. item, if isStim then "plus" else "bar", if isStim then Style.Green else Style.Amber, tonumber(amt))
		return true
	end
	if string.find(lower, "^resupplied") then
		if os.clock() - lastAcquired > 1.5 then
			PickupToast.show("RESUPPLIED", "bar", Style.Amber)
			lastAcquired = os.clock()
		end
		return true
	end
	local picked = string.match(text, "^Picked up (.+)$")
	if picked then
		PickupToast.show("PICKED UP  " .. picked, "diamond", Style.Orange)
		return true
	end
	local eq = string.match(text, "^Equipped (.+)$")
	if eq then
		PickupToast.show("WEAPON  " .. eq, "diamond", Style.Orange)
		return true
	end
	return false
end

function PickupToast.clear() end

return PickupToast
