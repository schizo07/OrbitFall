-- Ephemeral 4 s drop intro caption (planet / faction / difficulty) under the compass.
-- The permanent top-center objective box is removed: objectives live in the top-right checklist (UI/ObjectiveList).
-- Preserves the public API expected by ObjectiveList and AreaInfo (build, destroy, setVisible, set, setExtract, intro, step).
local Theme = require(script.Parent.Theme)
local InfoLayer = require(script.Parent.InfoLayer)

local GoalLine = {}

local INTRO_FOR = 4

local ui: { [string]: any } = {}
local introGen = 0
local extractCb: ((string?) -> ())? = nil
local lastExtract: string? = nil

function GoalLine.onExtract(fn: (string?) -> ())
	extractCb = fn
	if lastExtract ~= nil then
		fn(lastExtract)
	end
end

function GoalLine.destroy()
	InfoLayer.drop("GoalLine")
	ui = {}
	lastExtract = nil
end

function GoalLine.build(isTouch: boolean)
	ui = {}
	local E = InfoLayer.entry("goal", isTouch)
	local textSize: number = E.TextSize or 15
	local holder = InfoLayer.fresh("GoalLine")
	InfoLayer.place(holder, "goal", isTouch)
	holder.Visible = true
	ui.holder = holder

	ui.intro = InfoLayer.label({
		Text = "",
		TextSize = textSize,
		ColorRole = "dim",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = holder,
	})
end

function GoalLine.setVisible(_on: boolean)
	-- Only the ephemeral drop intro lives here; it manages its own visibility.
end

function GoalLine.set(_g: any)
	-- Permanent top-center goal box removed; ObjectiveList renders the top-right checklist directly.
end

function GoalLine.setExtract(text: string?)
	if text == lastExtract then
		return
	end
	lastExtract = text
	if extractCb then
		extractCb(text)
	end
end

-- 4 s drop intro caption (planet / faction / difficulty)
function GoalLine.intro(text: string)
	if not ui.intro then
		return
	end
	introGen += 1
	local gen = introGen
	ui.intro.Text = InfoLayer.caseText(text)
	ui.intro.TextTransparency = 0
	ui.intro.Visible = true
	task.delay(INTRO_FOR, function()
		if gen ~= introGen or not ui.intro then
			return
		end
		Theme.tween(ui.intro, 0.4, { TextTransparency = 1 })
		task.delay(0.45, function()
			if gen == introGen and ui.intro then
				ui.intro.Visible = false
			end
		end)
	end)
end

function GoalLine.step(_cam: Camera) end

return GoalLine
