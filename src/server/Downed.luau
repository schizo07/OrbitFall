-- Downed state (owned by PlayerService; rules in shared/Downed.luau, tuning in Config.Downed).
-- A hit that would kill a trooper puts them down instead: Health becomes a small pool (Config.Downed.Pool of max) that
-- bleeds out over BleedTime; hits while down do HitMult damage. Health 0 = the normal death (PlayerService Died handler:
-- a life, reinforce). Getting up: a squadmate holds the revive prompt on the body, or the trooper uses a stim
-- (PlayerService.useStim -> Downed.revive(p, "stim"), after the stim hold). While a squadmate holds the prompt the
-- downed Player gets ReviveBy / ReviveStart and the reviver's character Reviving (shared/Downed.luau).
-- Studio A/B: workspace attribute Feel_Downed = "long" | "off" (mirrored from the client by the "studioFeel" action).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Rules = require(Shared.Downed)

local Downed = {}
local S: any = nil
local PS: any = nil

local IS_STUDIO = RunService:IsStudio()
local D = Config.Downed

type DRec = { at: number, rate: number, prompt: ProximityPrompt?, slot: number?, reviver: Player? }
local downs: { [Player]: DRec } = {}

local function now()
	return workspace:GetServerTimeNow()
end

function Downed.mode(): string
	if IS_STUDIO then
		local a = workspace:GetAttribute("Feel_Downed")
		if a == "long" or a == "off" then
			return a
		end
	end
	return if D.Enabled then "on" else "off"
end

local function bleedTime(): number
	return if Downed.mode() == "long" then D.BleedTimeLong else D.BleedTime
end

function Downed.isDowned(p: Player): boolean
	return downs[p] ~= nil
end

local function setAttrs(p: Player, on: boolean, endAt: number?)
	p:SetAttribute(Rules.ATTR, if on then true else nil)
	p:SetAttribute(Rules.END_ATTR, if on then endAt else nil)
	local c = p.Character
	if c then
		c:SetAttribute(Rules.ATTR, if on then true else nil)
	end
end

local function publishEnd(p: Player, h: Humanoid)
	local d = downs[p]
	if d and d.rate > 0 then
		p:SetAttribute(Rules.END_ATTR, now() + h.Health / d.rate)
	end
end

-- reviver feedback: the downed trooper's client shows "NAME is reviving you" + a bar, the reviver's client kneels
local function setReviver(p: Player, d: DRec, by: Player?)
	local old = d.reviver
	if old == by then
		return
	end
	if old and old.Character then
		old.Character:SetAttribute(Rules.REVIVING, nil)
	end
	d.reviver = by
	p:SetAttribute(Rules.REVIVE_BY, if by then by.UserId else nil)
	p:SetAttribute(Rules.REVIVE_START, if by then now() else nil)
	if by and by.Character then
		by.Character:SetAttribute(Rules.REVIVING, true)
	end
end

-- forget the downed state without touching health (death, respawn, leaving)
function Downed.clear(p: Player)
	local d = downs[p]
	if not d then
		return
	end
	setReviver(p, d, nil)
	downs[p] = nil
	if d.prompt then
		d.prompt:Destroy()
	end
	setAttrs(p, false)
end

function Downed.revive(p: Player, by: Player | string)
	local d = downs[p]
	if not d then
		return
	end
	local h = PS.getHumanoid(p)
	Downed.clear(p)
	if not h or h.Health <= 0 then
		return
	end
	local r = PS.get(p)
	if r and d.slot and r.weapons[d.slot] and r.slot ~= d.slot then
		r.slot = d.slot
		r.reloadUntil = 0
		if S.Weapons and S.Weapons.equipModel then
			S.Weapons.equipModel(p)
		end
	end
	local root = PS.getRoot(p)
	if typeof(by) == "Instance" then
		h.Health = math.max(h.Health, h.MaxHealth * D.ReviveHealth)
		S.State.notify(nil, by.DisplayName .. " got " .. p.DisplayName .. " back up!", Config.Colors.Friendly)
		if S.MissionStats then
			S.MissionStats.revived(by, p)
		end
		S.Fx.play("Stim", { u = p.UserId, p = root and root.Position, t = 0.6 })
	end
	S.Fx.play("Sound", { k = "Pickup", p = root and root.Position })
	PS.publish(p)
end

local function makePrompt(p: Player, root: BasePart): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.Name = Rules.PROMPT
	pp.ActionText = "Revive"
	pp.ObjectText = p.DisplayName
	pp.HoldDuration = D.ReviveHold
	pp.MaxActivationDistance = D.ReviveRange
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp:SetAttribute("ReviveFor", p.UserId) -- the downed trooper's own client hides it (client/DownedFx)
	local function canRevive(by: Player): boolean
		if by == p or not PS.isAlive(by) or downs[by] then
			return false
		end
		local br = PS.getRoot(by)
		return br ~= nil and (br.Position - root.Position).Magnitude <= D.ReviveRange + 6
	end
	local function handle(by: Player, force: boolean?)
		if not downs[p] then
			return
		end
		if not force and not canRevive(by) then
			return
		end
		Downed.revive(p, by)
	end
	pp.Triggered:Connect(handle)
	pp.PromptButtonHoldBegan:Connect(function(by)
		local d = downs[p]
		if d and canRevive(by) then
			setReviver(p, d, by)
		end
	end)
	pp.PromptButtonHoldEnded:Connect(function(by)
		local d = downs[p]
		if d and d.reviver == by then
			setReviver(p, d, nil)
		end
	end)
	-- test hook: Main's DebugHook "trigger" (ActionText substring "revive") fires this, skipping range / hold / self
	local dbg = Instance.new("BindableEvent")
	dbg.Name = "DebugTrigger"
	dbg.Event:Connect(function(by)
		handle(by, true)
	end)
	dbg.Parent = pp
	pp.Parent = root
	return pp
end

-- Called by PlayerService.damage before the hit lands. Returns true when the hit put the trooper down (handled).
function Downed.tryDown(p: Player, h: Humanoid, amount: number): boolean
	if downs[p] or Downed.mode() == "off" or h.Health - amount > 0 or h.MaxHealth >= 1e6 then
		return false
	end
	local r = PS.get(p)
	local root = PS.getRoot(p)
	if not r or not root then
		return false
	end
	local pool = math.max(1, h.MaxHealth * D.Pool)
	local d: DRec = { at = now(), rate = pool / math.max(bleedTime(), 1), prompt = nil, slot = r.slot }
	downs[p] = d
	h.Health = pool
	-- sidearm only
	if r.weapons[2] and r.slot ~= 2 then
		r.slot = 2
		r.reloadUntil = 0
		if S.Weapons and S.Weapons.equipModel then
			S.Weapons.equipModel(p)
		end
	end
	if S.CallIns and S.CallIns.cancelHolding then
		pcall(S.CallIns.cancelHolding, p)
	end
	setAttrs(p, true, now() + pool / d.rate)
	d.prompt = makePrompt(p, root)
	S.Fx.play("Sound", { k = "PlayerDown", p = root.Position })
	S.State.notify(nil, p.DisplayName .. " is down! Get them up.", Config.Colors.Danger)
	PS.publish(p)
	return true
end

function Downed.hitMult(p: Player): number
	return if downs[p] then D.HitMult else 1
end

function Downed.onHit(p: Player, h: Humanoid)
	if downs[p] then
		publishEnd(p, h)
	end
end

-- PlayerService Heartbeat: bleed
function Downed.step(dt: number)
	for p, d in downs do
		local h = PS.getHumanoid(p)
		if not h or h.Health <= 0 or not p.Parent then
			Downed.clear(p)
			continue
		end
		-- a reviver who died, went down, left or walked off without the hold-ended event: drop the feedback
		local rv = d.reviver
		if rv then
			local rr = PS.getRoot(rv)
			local mr = PS.getRoot(p)
			if not rv.Parent or not PS.isAlive(rv) or downs[rv] or not rr or not mr or (rr.Position - mr.Position).Magnitude > D.ReviveRange + 8 then
				setReviver(p, d, nil)
			end
		end
		local hp = h.Health - d.rate * dt
		if hp <= 0 then
			h.Health = 0 -- Died -> PlayerService handler (clears us)
		else
			h.Health = hp
		end
	end
end

function Downed.init(s: any, ps: any)
	S, PS = s, ps
	Players.PlayerRemoving:Connect(function(p)
		local d = downs[p]
		if d then
			setReviver(p, d, nil) -- un-kneel the squadmate who was reviving
		end
		downs[p] = nil
	end)
end

return Downed
