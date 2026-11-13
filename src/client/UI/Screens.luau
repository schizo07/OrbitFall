-- Ship menus: Loadout, Armory, Bonds, Shop, Mission.
-- Opened by ProximityPrompts with attribute OpenScreen = "Loadout"|"Armory"|"Bonds"|"Shop"|"Mission",
-- or Screens.open(name). Sets Store "menuOpen" = true while open (camera/input should free the mouse).
-- Server calls: Net.func("Request"):InvokeServer(cmd, args) -> (ok, result)
--   getProfile, setLoadout, buyArmory, bondAccess, bondBuy, startMission.
-- Store keys read: profile, mission (menus auto-close when the mission leaves "Ship").

local ContextActionService = game:GetService("ContextActionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Net = require(Shared:WaitForChild("Net"))
local Weapons = require(Shared:WaitForChild("Data"):WaitForChild("Weapons"))
local CallIns = require(Shared:WaitForChild("Data"):WaitForChild("CallIns"))
local Bonds = require(Shared:WaitForChild("Data"):WaitForChild("Bonds"))
local Store = require(script.Parent.Parent.Store)
local Theme = require(script.Parent.Theme)

local C = Theme.C
local player = Players.LocalPlayer

local Screens = {}

local NAMES = { "Loadout", "Armory", "Bonds", "Shop", "Mission" }
local TITLES = { Loadout = "LOADOUT", Armory = "ARMORY", Bonds = "BONDS", Shop = "SHOP", Mission = "MISSION TABLE" }

local built = false
local gui: ScreenGui
local root: Frame
local window: Frame
local content: Frame
local toastHolder: Frame
local titleLabel: TextLabel
local tabButtons: { [string]: TextButton } = {}
local hdrSalvage: TextLabel
local hdrTokens: TextLabel
local hdrRank: TextLabel

local openName: string? = nil
local renderToken = 0
local scrollMemory: { [string]: Vector2 } = {}
local busy = false
local touch = false

-- Page state (persist across re-renders)
local loadout: { primary: string, secondary: string, grenade: string, callins: { string } } = { primary = "PR7", secondary = "P3", grenade = "FRAG", callins = { "LANCE", "HALFTON", "STRAFE", "SUPPLY" } }
local loadoutDirty = false
local loadoutThread: thread? = nil
local savedAt = 0
local slotSel = 1
local detail: { kind: string, id: string }? = nil
local armoryFilter = "ALL"
local bondSel = "FIELDKIT"
local bondPage = 1
local missionSel = { faction = "COG", objective = "MISSILE", difficulty = 1 }

-- Helpers ----------------------------------------------------------------------------------------------------------
local function profile(): any
	return Store.get("profile") or {}
end

local function unlockedList(kind: string): { [string]: boolean }
	local u = profile().unlocked or {}
	local t = kind == "weapon" and u.weapons or u.callins
	local out = {}
	if type(t) == "table" then
		for k, v in t do
			if type(k) == "string" and v == true then
				out[k] = true
			elseif type(v) == "string" then
				out[v] = true
			end
		end
	end
	return out
end

local function virtualWidth(): number
	local cam = workspace.CurrentCamera
	local x = cam and cam.ViewportSize.X or 1920
	return x / Theme.scaleFor("menu")
end

function Screens.toast(text: string, color: Color3?)
	if not toastHolder then
		return
	end
	local col = color or C.Text
	local pill = Theme.panel({
		Color = C.Navy,
		Corner = 8,
		Stroke = col,
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = math.floor(os.clock() * 1000),
		Parent = toastHolder,
	})
	Theme.pad(pill, 16, 0, 16, 0)
	Theme.label({
		Text = text,
		Font = "Body",
		TextSize = 16,
		Color = col,
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = pill,
	})
	task.delay(3.2, function()
		pill:Destroy()
	end)
end

local function errorToast(text: string)
	Theme.sfx("UIError")
	Screens.toast(text, C.Danger)
end

local function request(cmd: string, args: any): (boolean, any)
	local ok, a, b = pcall(function()
		return Net.func("Request"):InvokeServer(cmd, args)
	end)
	if not ok then
		errorToast("Could not reach the server")
		return false, nil
	end
	if a ~= true then
		errorToast(tostring(b or "Request failed"))
		return false, b
	end
	return true, b
end

local function refreshProfile()
	local ok, result = request("getProfile", nil)
	if ok and type(result) == "table" then
		Store.set("profile", result)
	end
end

local function ownedCount(bondId: string, page: number): (number, number)
	local bond = Bonds.get(bondId)
	local state = (profile().bonds or {})[bondId]
	local owned, total = 0, 0
	if bond then
		for _, it in bond.items do
			if it.page == page then
				total += 1
				if state and state.items and state.items[it.id] then
					owned += 1
				end
			end
		end
	end
	return owned, total
end

local function bondAccess(bondId: string): boolean
	local bond = Bonds.get(bondId)
	if not bond then
		return false
	end
	if not bond.premium then
		return true
	end
	local state = (profile().bonds or {})[bondId]
	if state and state.access then
		return true
	end
	if bond.pass and (profile().passes or {})[bond.pass] then
		return true
	end
	return false
end

-- Small UI builders --------------------------------------------------------------------------------------------------
local function section(parent: Instance, text: string, order: number, color: Color3?)
	local l = Theme.label({
		Text = text,
		Font = "Header",
		TextSize = 13,
		Color = color or C.Accent,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = order,
		Parent = parent,
	})
	return l
end

local function grid(parent: Instance, cols: number, cellH: number, order: number, gap: number?): Frame
	local g = gap or 8
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.LayoutOrder = order
	f.Parent = parent
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.new(1 / cols, -(g * (cols - 1)) / cols, 0, cellH)
	gl.CellPadding = UDim2.fromOffset(g, g)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = f
	return f
end

local function bodyScroll(parent: Instance, name: string?, pos: UDim2?, size: UDim2?): ScrollingFrame
	local s = Theme.scroll({
		Name = name or "Body",
		Position = pos or UDim2.fromOffset(0, 0),
		Size = size or UDim2.fromScale(1, 1),
		Thickness = touch and 8 or 6,
		Parent = parent,
	})
	Theme.pad(s, 2, 2, 10, 8)
	Theme.list(s, Enum.FillDirection.Vertical, 10)
	return s
end

local function statRow(parent: Instance, label: string, frac: number, valueText: string, color: Color3, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 20)
	row.LayoutOrder = order
	row.Parent = parent
	Theme.label({
		Text = label,
		Font = "Header",
		TextSize = 10,
		Color = C.Muted,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(50, 20),
		Parent = row,
	})
	local bar = Theme.bar({ Size = UDim2.new(1, -120, 0, 9), Position = UDim2.new(0, 54, 0.5, -4), Color = color, Parent = row })
	bar:set(frac)
	Theme.label({
		Text = valueText,
		Font = "Black",
		TextSize = 13,
		XAlign = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(60, 20),
		Position = UDim2.new(1, -60, 0, 0),
		Parent = row,
	})
end

local function weaponStats(parent: Instance, w: any, startOrder: number)
	local pellets = w.pellets or 1
	local dmg = w.damage * pellets
	local dtxt = pellets > 1 and string.format("%dx%d", w.damage, pellets) or tostring(w.damage)
	if w.kind == "grenade" and w.splash then
		dmg = w.splash.damage
		dtxt = tostring(w.splash.damage)
	end
	statRow(parent, "DAMAGE", math.sqrt(math.min(dmg, 900) / 900), dtxt, C.Accent, startOrder)
	statRow(parent, "ARMOUR PEN", w.ap / 5, tostring(w.ap), C.Gold, startOrder + 1)
	if w.rpm then
		statRow(parent, "RATE", w.rpm / 900, tostring(w.rpm), C.Friendly, startOrder + 2)
	end
	if w.mag then
		statRow(parent, "MAGAZINE", math.sqrt(w.mag / 150), tostring(w.mag), C.BeaconSupply, startOrder + 3)
	end
	if w.splash and w.kind == "grenade" then
		statRow(parent, "RADIUS", w.splash.radius / 10, tostring(w.splash.radius), C.Friendly, startOrder + 2)
	end
end

local function callinStats(parent: Instance, d: any, startOrder: number)
	local rows = {
		{ "CATEGORY", string.upper(d.category) },
		{ "COOLDOWN", d.cooldown .. " s" },
		{ "ARRIVAL", d.delay .. " s" },
		{ "USES", d.uses and tostring(d.uses) or (d.charges and (d.charges .. " charges") or "Unlimited") },
	}
	for i, r in rows do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 20)
		row.LayoutOrder = startOrder + i
		row.Parent = parent
		Theme.label({ Text = r[1], Font = "Header", TextSize = 10, Color = C.Muted, XAlign = Enum.TextXAlignment.Left, Size = UDim2.fromOffset(90, 20), Parent = row })
		Theme.label({ Text = r[2], Font = "Black", TextSize = 13, XAlign = Enum.TextXAlignment.Right, Size = UDim2.new(1, -90, 0, 20), Position = UDim2.fromOffset(90, 0), Parent = row })
	end
end

-- Generic selectable card (button) with title/subtitle/glyph -------------------------------------------------------------
local function card(parent: Instance, p: { [string]: any }): TextButton
	local selected = p.Selected == true
	local btn = Theme.button({
		Variant = "ghost",
		Color = selected and Color3.fromHex("2b3a5a") or (p.Color or C.Panel),
		StrokeColor = selected and C.Accent or (p.Stroke or C.PanelHi),
		Size = p.Size or UDim2.fromOffset(120, 64),
		LayoutOrder = p.Order or 0,
		OnClick = p.OnClick,
		Parent = parent,
	})
	if selected then
		local st = btn:FindFirstChildOfClass("UIStroke")
		if st then
			st.Transparency = 0
			st.Thickness = 3
		end
	end
	if p.Glyph then
		Theme.label({
			Text = p.Glyph,
			Font = "Black",
			TextSize = p.GlyphSize or 24,
			Size = UDim2.new(0, 40, 1, 0),
			Position = UDim2.fromOffset(4, 0),
			Parent = btn,
		})
	end
	local left = p.Glyph and 46 or 10
	Theme.label({
		Text = p.Title or "",
		Font = "Black",
		TextSize = p.TitleSize or 14,
		Color = p.TitleColor or C.Text,
		XAlign = Enum.TextXAlignment.Left,
		YAlign = Enum.TextYAlignment.Center,
		Wrap = true,
		Size = UDim2.new(1, -left - 8, 0, (p.Desc and 22) or (p.Sub and 24) or 40),
		Position = UDim2.new(0, left, 0, (p.Desc and 8) or (p.Sub and 8) or 10),
		Parent = btn,
	})
	if p.Desc then
		Theme.label({
			Text = p.Desc,
			Font = "Medium",
			TextSize = 11,
			Color = C.Muted,
			Wrap = true,
			XAlign = Enum.TextXAlignment.Left,
			YAlign = Enum.TextYAlignment.Top,
			Size = UDim2.new(1, -left - 8, 1, -34),
			Position = UDim2.new(0, left, 0, 32),
			Parent = btn,
		})
	end
	if p.Sub then
		Theme.label({
			Text = p.Sub,
			Font = "Medium",
			TextSize = 11,
			Color = p.SubColor or C.Muted,
			XAlign = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, -left - 8, 0, 16),
			Position = UDim2.new(0, left, 1, -22),
			Parent = btn,
		})
	end
	if p.Badge then
		local b = Theme.panel({
			Color = p.BadgeColor or C.Accent,
			Corner = 6,
			Stroke = false,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -4, 0, 4),
			Size = UDim2.fromOffset(22, 18),
			Parent = btn,
		})
		Theme.label({ Text = p.Badge, Font = "Black", TextSize = 12, Color = C.Dark, NoStroke = true, Size = UDim2.fromScale(1, 1), Parent = b })
	end
	return btn
end

-- Tab button ------------------------------------------------------------------------------------------------------------
local render: () -> ()

local function setTabVisual(name: string, active: boolean)
	local b = tabButtons[name]
	if not b then
		return
	end
	b:SetAttribute("BaseColor", active and C.Accent or C.PanelLight)
	b.BackgroundColor3 = active and C.Accent or C.PanelLight
	b.TextColor3 = active and C.Dark or C.Text
	b:SetAttribute("BaseText", b.TextColor3)
	b.TextStrokeTransparency = active and 1 or 0.4
end

local function updateHeader()
	if not hdrSalvage then
		return
	end
	local p = profile()
	hdrSalvage.Text = string.format('<font color="%s">⚙</font> %s', Theme.hex(C.Accent), Theme.formatNumber(p.salvage or 0))
	hdrTokens.Text = string.format('<font color="%s">◈</font> %s', Theme.hex(C.Friendly), Theme.formatNumber(p.tokens or 0))
	hdrRank.Text = string.format('<font color="%s">RANK</font> %d', Theme.hex(C.Muted), p.rank or 1)
end

-- LOADOUT ---------------------------------------------------------------------------------------------------------------------
local function syncLoadoutFromProfile(force: boolean?)
	if loadoutDirty and not force then
		return
	end
	local l = profile().loadout
	if type(l) == "table" then
		loadout = {
			primary = l.primary or "PR7",
			secondary = l.secondary or "P3",
			grenade = l.grenade or "FRAG",
			callins = table.clone(l.callins or CallIns.Starter),
		}
		for i = 1, CallIns.SlotCount do
			if not loadout.callins[i] then
				loadout.callins[i] = CallIns.Starter[i]
			end
		end
	end
end

local function commitLoadout()
	loadoutDirty = true
	if loadoutThread then
		task.cancel(loadoutThread)
	end
	loadoutThread = task.delay(0.4, function()
		loadoutThread = nil
		local ok = request("setLoadout", {
			primary = loadout.primary,
			secondary = loadout.secondary,
			grenade = loadout.grenade,
			callins = loadout.callins,
		})
		loadoutDirty = false
		if ok then
			savedAt = os.clock()
			if openName == "Loadout" then
				render()
			end
		else
			refreshProfile()
			syncLoadoutFromProfile(true)
			if openName == "Loadout" then
				render()
			end
		end
	end)
end

local function renderDetail(parent: Instance)
	local panel = Theme.panel({
		Name = "Detail",
		Color = C.Navy,
		Accent = true,
		Size = UDim2.new(0.4, -6, 1, 0),
		Position = UDim2.fromScale(0.6, 0),
		Parent = parent,
	})
	local s = Theme.scroll({ Size = UDim2.fromScale(1, 1), Parent = panel })
	Theme.pad(s, 14, 12, 18, 12)
	Theme.list(s, Enum.FillDirection.Vertical, 6)
	local d = detail
	if not d then
		d = { kind = "weapon", id = loadout.primary }
	end
	if d.kind == "weapon" then
		local w = Weapons.get(d.id)
		if w then
			Theme.label({ Text = string.upper(w.name), Font = "Header", TextSize = 15, Color = C.Accent, Wrap = true, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = s })
			Theme.label({ Text = string.upper(w.slot .. " - " .. w.kind), Font = "Medium", TextSize = 11, Color = C.Muted, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 2, Parent = s })
			Theme.label({ Text = w.desc, Font = "Medium", TextSize = 14, Wrap = true, XAlign = Enum.TextXAlignment.Left, YAlign = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = s })
			weaponStats(s, w, 10)
		end
	else
		local cdef = CallIns.get(d.id)
		if cdef then
			local col = Theme.beaconColor(cdef.beacon)
			Theme.label({ Text = cdef.icon .. "  " .. string.upper(cdef.name), Font = "Header", TextSize = 15, Color = col, Wrap = true, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = s })
			Theme.label({ Text = string.upper(cdef.beacon) .. " BEACON", Font = "Medium", TextSize = 11, Color = C.Muted, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 2, Parent = s })
			Theme.label({ Text = cdef.desc, Font = "Medium", TextSize = 14, Wrap = true, XAlign = Enum.TextXAlignment.Left, YAlign = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = s })
			callinStats(s, cdef, 10)
		end
	end
	local synced = (os.clock() - savedAt) < 2.5
	Theme.label({
		Text = loadoutDirty and "Saving..." or (synced and "✓ Loadout saved" or "Changes save automatically"),
		Font = "Medium",
		TextSize = 12,
		Color = synced and C.Friendly or C.Muted,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = 100,
		Parent = s,
	})
end

local function renderLoadout(parent: Instance)
	syncLoadoutFromProfile()
	local left = bodyScroll(parent, "Body", UDim2.fromOffset(0, 0), UDim2.new(0.6, -6, 1, 0))
	renderDetail(parent)

	local owned = unlockedList("weapon")
	local ownedCall = unlockedList("callin")
	local order = 1
	local function weaponSection(slot: string, title: string, key: string)
		section(left, title, order)
		order += 1
		local g = grid(left, 3, 62, order, 8)
		order += 1
		local list = Weapons.list(slot)
		for i, w in list do
			if owned[w.id] then
				card(g, {
					Title = w.name,
					Sub = string.upper(w.kind),
					Selected = (loadout :: any)[key] == w.id,
					Order = i,
					OnClick = function()
						(loadout :: any)[key] = w.id
						detail = { kind = "weapon", id = w.id }
						commitLoadout()
						render()
					end,
				})
			end
		end
	end
	weaponSection("primary", "PRIMARY WEAPON", "primary")
	weaponSection("secondary", "SECONDARY", "secondary")
	weaponSection("grenade", "GRENADE", "grenade")

	section(left, "CALL-IN SLOTS  (pick a slot, then a call-in)", order, C.Friendly)
	order += 1
	local slots = Instance.new("Frame")
	slots.BackgroundTransparency = 1
	slots.Size = UDim2.new(1, 0, 0, 80)
	slots.LayoutOrder = order
	order += 1
	slots.Parent = left
	local sl = Theme.list(slots, Enum.FillDirection.Horizontal, 8)
	sl.HorizontalAlignment = Enum.HorizontalAlignment.Left
	for i = 1, CallIns.SlotCount do
		local id = loadout.callins[i]
		local def = id and CallIns.get(id)
		local b = Theme.button({
			Variant = "ghost",
			Color = slotSel == i and Color3.fromHex("2b3a5a") or C.Panel,
			StrokeColor = slotSel == i and C.Accent or (def and Theme.beaconColor(def.beacon) or C.PanelHi),
			Size = UDim2.new(0.25, -6, 1, 0),
			LayoutOrder = i,
			OnClick = function()
				slotSel = i
				if def then
					detail = { kind = "callin", id = def.id }
				end
				render()
			end,
			Parent = slots,
		})
		if slotSel == i then
			local st = b:FindFirstChildOfClass("UIStroke")
			if st then
				st.Thickness = 3
				st.Transparency = 0
			end
		end
		Theme.label({ Text = def and def.icon or "-", Font = "Black", TextSize = 26, Size = UDim2.new(1, 0, 0, 36), Position = UDim2.fromOffset(0, 6), Parent = b })
		Theme.label({ Text = def and Theme.callinShort(def) or "EMPTY", Font = "Black", TextSize = 11, Size = UDim2.new(1, -6, 0, 14), Position = UDim2.new(0, 3, 1, -20), Parent = b })
		Theme.label({ Text = tostring(i), Font = "Header", TextSize = 10, Color = C.Accent, XAlign = Enum.TextXAlignment.Left, Size = UDim2.fromOffset(16, 14), Position = UDim2.fromOffset(6, 4), Parent = b })
	end

	section(left, "AVAILABLE CALL-INS", order)
	order += 1
	local cg = grid(left, 3, 62, order, 8)
	order += 1
	local list = CallIns.list()
	local n = 0
	for _, def in list do
		if ownedCall[def.id] then
			n += 1
			local slotNum = table.find(loadout.callins, def.id)
			card(cg, {
				Glyph = def.icon,
				Title = def.name,
				Sub = string.upper(def.category),
				Badge = slotNum and tostring(slotNum) or nil,
				BadgeColor = C.Friendly,
				Selected = slotNum == slotSel,
				Stroke = Theme.beaconColor(def.beacon),
				Order = n,
				TitleSize = 12,
				OnClick = function()
					local cur = loadout.callins[slotSel]
					local other = table.find(loadout.callins, def.id)
					if other and other ~= slotSel then
						loadout.callins[other] = cur
					end
					loadout.callins[slotSel] = def.id
					detail = { kind = "callin", id = def.id }
					commitLoadout()
					render()
				end,
			})
		end
	end
	if n == 0 then
		Theme.label({ Text = "Nothing unlocked yet.", Font = "Medium", TextSize = 14, Color = C.Muted, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = order, Parent = left })
	end
end

-- ARMORY --------------------------------------------------------------------------------------------------------------------------
local function renderArmory(parent: Instance)
	local p = profile()
	local salvage, rank = p.salvage or 0, p.rank or 1
	local ownedW, ownedC = unlockedList("weapon"), unlockedList("callin")

	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.Size = UDim2.new(1, 0, 0, 34)
	bar.Parent = parent
	local l = Theme.list(bar, Enum.FillDirection.Horizontal, 8)
	l.VerticalAlignment = Enum.VerticalAlignment.Center
	for i, f in { "ALL", "WEAPONS", "CALL-INS" } do
		local b = Theme.button({
			Text = f,
			TextSize = 13,
			Variant = armoryFilter == f and "primary" or "secondary",
			Size = UDim2.fromOffset(110, 32),
			LayoutOrder = i,
			OnClick = function()
				armoryFilter = f
				render()
			end,
			Parent = bar,
		})
		b.Font = Enum.Font.GothamBlack
	end
	Theme.label({
		Text = "Spend Salvage earned in missions. Higher ranks unlock more gear.",
		Font = "Medium",
		TextSize = 12,
		Color = C.Muted,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -370, 1, 0),
		LayoutOrder = 10,
		Visible = not touch,
		Parent = bar,
	})

	local body = bodyScroll(parent, "Body", UDim2.fromOffset(0, 42), UDim2.new(1, 0, 1, -42))
	local items = {}
	if armoryFilter ~= "CALL-INS" then
		for _, w in Weapons.list() do
			if w.unlock == "armory" then
				table.insert(items, { kind = "weapon", id = w.id, name = w.name, desc = w.desc, price = w.salvage or 0, rank = w.rank or 1, glyph = string.upper(string.sub(w.kind, 1, 4)), color = C.Accent, owned = ownedW[w.id] == true, stats = w })
			end
		end
	end
	if armoryFilter ~= "WEAPONS" then
		for _, c in CallIns.list() do
			if c.unlock == "armory" then
				table.insert(items, { kind = "callin", id = c.id, name = c.name, desc = c.desc, price = c.salvage or 0, rank = c.rank or 1, glyph = c.icon, color = Theme.beaconColor(c.beacon), owned = ownedC[c.id] == true, stats = c })
			end
		end
	end
	table.sort(items, function(a, b)
		if a.owned ~= b.owned then
			return not a.owned
		end
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return a.price < b.price
	end)
	local cols = virtualWidth() >= 1000 and 3 or 2
	local g = grid(body, cols, 150, 1, 10)
	for i, it in items do
		local locked = rank < it.rank
		local card_ = Theme.panel({
			Color = C.Panel,
			Stroke = it.owned and C.Friendly or it.color,
			StrokeTransparency = it.owned and 0.4 or 0.5,
			LayoutOrder = i,
			Parent = g,
		})
		Theme.chip({ Glyph = it.glyph, Color = C.Navy, StrokeColor = it.color, Size = UDim2.fromOffset(52, 52), Position = UDim2.fromOffset(10, 10), Parent = card_ })
		Theme.label({ Text = it.name, Font = "Black", TextSize = 15, XAlign = Enum.TextXAlignment.Left, Wrap = true, Size = UDim2.new(1, -80, 0, 22), Position = UDim2.fromOffset(70, 10), Parent = card_ })
		Theme.label({ Text = string.upper(it.kind == "weapon" and (it.stats.slot .. " weapon") or (it.stats.category .. " call-in")), Font = "Medium", TextSize = 10, Color = C.Muted, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, -80, 0, 14), Position = UDim2.fromOffset(70, 34), Parent = card_ })
		Theme.label({ Text = it.desc, Font = "Medium", TextSize = 12, Color = Color3.fromHex("c5cddc"), Wrap = true, XAlign = Enum.TextXAlignment.Left, YAlign = Enum.TextYAlignment.Top, Size = UDim2.new(1, -20, 0, 44), Position = UDim2.fromOffset(10, 66), Parent = card_ })
		local state
		local canBuy = false
		if it.owned then
			state = "OWNED"
		elseif locked then
			state = "RANK " .. it.rank
		elseif salvage < it.price then
			state = string.format("⚙ %s", Theme.formatNumber(it.price))
		else
			state = string.format("BUY  ⚙ %s", Theme.formatNumber(it.price))
			canBuy = true
		end
		local btn = Theme.button({
			Text = state,
			TextSize = 14,
			Variant = it.owned and "good" or (canBuy and "primary" or "secondary"),
			Size = UDim2.new(1, -20, 0, 30),
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 10, 1, -8),
			OnClick = function()
				if busy then
					return
				end
				busy = true
				local ok = request("buyArmory", { kind = it.kind, id = it.id })
				busy = false
				if ok then
					Theme.sfx("UIBuy")
					Screens.toast("Unlocked " .. it.name, C.Friendly)
					refreshProfile()
				end
			end,
			Parent = card_,
		})
		btn.Font = Enum.Font.GothamBlack
		if it.owned or not canBuy then
			Theme.setEnabled(btn, false)
			if not it.owned then
				btn.TextColor3 = locked and C.Danger or C.Muted
			end
		end
		if it.owned then
			btn.BackgroundColor3 = C.Friendly:Lerp(C.Navy, 0.6)
		end
	end
	if #items == 0 then
		Theme.label({ Text = "Nothing here.", Font = "Medium", TextSize = 14, Color = C.Muted, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 2, Parent = body })
	end
end

-- BONDS --------------------------------------------------------------------------------------------------------------------------
local function promptPass(passKey: string?)
	if not passKey then
		return
	end
	local info = Config.GamePasses[passKey]
	if not info or info.id == 0 then
		Screens.toast("Not on sale yet", C.Accent)
		Theme.sfx("UIError")
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, info.id)
	end)
	if not ok then
		errorToast("Purchase unavailable")
		warn(err)
	end
end

local function renderBonds(parent: Instance)
	local p = profile()
	if not Bonds.get(bondSel) then
		bondSel = Bonds.order[1]
	end
	local bond = Bonds.get(bondSel) :: any

	-- bond tabs
	local tabs = Instance.new("Frame")
	tabs.BackgroundTransparency = 1
	tabs.Size = UDim2.new(1, 0, 0, 38)
	tabs.Parent = parent
	local tl = Theme.list(tabs, Enum.FillDirection.Horizontal, 8)
	tl.VerticalAlignment = Enum.VerticalAlignment.Center
	for i, id in Bonds.order do
		local b = Bonds.get(id) :: any
		local active = id == bondSel
		local btn = Theme.button({
			Text = (bondAccess(id) and "" or "🔒 ") .. string.upper(b.name),
			TextSize = 13,
			Color = active and b.color or C.PanelLight,
			TextColor = active and C.Dark or C.Text,
			StrokeColor = b.color,
			NoStroke = active,
			Size = UDim2.new(1 / #Bonds.order, -6, 1, 0),
			LayoutOrder = i,
			OnClick = function()
				bondSel = id
				bondPage = 1
				render()
			end,
			Parent = tabs,
		})
		btn.Font = Enum.Font.GothamBlack
	end

	local top = 46
	-- access banner
	local access = bondAccess(bondSel)
	if not access then
		local banner = Theme.panel({
			Color = C.Navy,
			Stroke = bond.color,
			Size = UDim2.new(1, 0, 0, touch and 62 or 52),
			Position = UDim2.fromOffset(0, top),
			Parent = parent,
		})
		Theme.label({
			Text = string.format("PREMIUM TRACK  -  unlock for %d BT, or get the pass with Robux. Everything on it can still be earned.", bond.accessCost),
			Font = "Medium",
			TextSize = 12,
			Wrap = true,
			XAlign = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, -330, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			Parent = banner,
		})
		local canAfford = (p.tokens or 0) >= bond.accessCost
		local b1 = Theme.button({
			Text = string.format("UNLOCK  ◈ %d", bond.accessCost),
			TextSize = 13,
			Variant = canAfford and "good" or "secondary",
			Size = UDim2.fromOffset(150, 34),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -168, 0.5, 0),
			OnClick = function()
				if busy then
					return
				end
				busy = true
				local ok = request("bondAccess", { bond = bondSel })
				busy = false
				if ok then
					Theme.sfx("UIBuy")
					Screens.toast(bond.name .. " unlocked", C.Friendly)
					refreshProfile()
				end
			end,
			Parent = banner,
		})
		b1.Font = Enum.Font.GothamBlack
		if not canAfford then
			Theme.setEnabled(b1, false)
		end
		local pass = bond.pass and Config.GamePasses[bond.pass]
		local b2 = Theme.button({
			Text = pass and (pass.id == 0 and "GET WITH ROBUX" or string.format("R$ %d", pass.robux)) or "ROBUX",
			TextSize = 13,
			Variant = "primary",
			Size = UDim2.fromOffset(150, 34),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			OnClick = function()
				promptPass(bond.pass)
			end,
			Parent = banner,
		})
		b2.Font = Enum.Font.GothamBlack
		top += (touch and 62 or 52) + 8
	end

	-- page tabs
	local pagesRow = Instance.new("Frame")
	pagesRow.BackgroundTransparency = 1
	pagesRow.Size = UDim2.new(1, 0, 0, 32)
	pagesRow.Position = UDim2.fromOffset(0, top)
	pagesRow.Parent = parent
	local pl = Theme.list(pagesRow, Enum.FillDirection.Horizontal, 8)
	pl.VerticalAlignment = Enum.VerticalAlignment.Center
	local pageOpen: { [number]: boolean } = { true, false, false }
	for pg = 2, 3 do
		local o, total = ownedCount(bondSel, pg - 1)
		pageOpen[pg] = pageOpen[pg - 1] and o >= math.min(bond.pageUnlock, total)
	end
	for pg = 1, 3 do
		local o, total = ownedCount(bondSel, pg)
		local label = string.format("PAGE %d  %s", pg, pageOpen[pg] and string.format("%d/%d", o, total) or "🔒")
		local btn = Theme.button({
			Text = label,
			TextSize = 12,
			Variant = bondPage == pg and "primary" or "secondary",
			Size = UDim2.fromOffset(130, 30),
			LayoutOrder = pg,
			OnClick = function()
				bondPage = pg
				render()
			end,
			Parent = pagesRow,
		})
		btn.Font = Enum.Font.GothamBlack
	end
	top += 40

	local body = bodyScroll(parent, "Body", UDim2.fromOffset(0, top), UDim2.new(1, 0, 1, -top))
	local pageLocked = not pageOpen[bondPage]
	if pageLocked then
		local o, total = ownedCount(bondSel, bondPage - 1)
		local need = math.min(bond.pageUnlock, total)
		Theme.label({
			Text = string.format("Page %d is locked. Own %d items on page %d to open it (%d/%d).", bondPage, need, bondPage - 1, o, need),
			Font = "Medium",
			TextSize = 14,
			Color = C.Accent,
			XAlign = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 22),
			LayoutOrder = 1,
			Parent = body,
		})
	end
	local cols = virtualWidth() >= 1000 and 4 or 3
	local g = grid(body, cols, 140, 2, 10)
	local state = (p.bonds or {})[bondSel]
	local n = 0
	for _, it in bond.items do
		if it.page ~= bondPage then
			continue
		end
		n += 1
		local owned = (state and state.items and state.items[it.id]) or false
		local canAfford = (p.tokens or 0) >= it.cost
		local usable = access and not pageLocked
		local c = Theme.panel({
			Color = C.Panel,
			Stroke = owned and C.Friendly or bond.color,
			StrokeTransparency = owned and 0.3 or 0.55,
			LayoutOrder = n,
			Parent = g,
		})
		Theme.label({ Text = string.upper(it.grant.kind), Font = "Header", TextSize = 9, Color = bond.color, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, -16, 0, 14), Position = UDim2.fromOffset(10, 8), Parent = c })
		Theme.label({ Text = it.name, Font = "Black", TextSize = 14, Wrap = true, XAlign = Enum.TextXAlignment.Left, YAlign = Enum.TextYAlignment.Top, Size = UDim2.new(1, -16, 0, 36), Position = UDim2.fromOffset(10, 22), Parent = c })
		Theme.label({ Text = it.desc, Font = "Medium", TextSize = 11, Color = C.Muted, Wrap = true, XAlign = Enum.TextXAlignment.Left, YAlign = Enum.TextYAlignment.Top, Size = UDim2.new(1, -16, 0, 30), Position = UDim2.fromOffset(10, 58), Parent = c })
		local text
		if owned then
			text = "OWNED ✓"
		else
			text = string.format("◈ %d", it.cost)
		end
		local btn = Theme.button({
			Text = text,
			TextSize = 13,
			Variant = owned and "good" or ((usable and canAfford) and "primary" or "secondary"),
			Size = UDim2.new(1, -20, 0, 28),
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 10, 1, -8),
			OnClick = function()
				if busy then
					return
				end
				busy = true
				local ok = request("bondBuy", { item = it.id })
				busy = false
				if ok then
					Theme.sfx("UIBuy")
					Screens.toast("Acquired " .. it.name, C.Friendly)
					refreshProfile()
				end
			end,
			Parent = c,
		})
		btn.Font = Enum.Font.GothamBlack
		if owned then
			btn.BackgroundColor3 = C.Friendly:Lerp(C.Navy, 0.6)
			Theme.setEnabled(btn, false)
		elseif not (usable and canAfford) then
			Theme.setEnabled(btn, false)
			if not canAfford and usable then
				btn.TextColor3 = C.Danger
			elseif not usable then
				btn.Text = access and "LOCKED" or "🔒 " .. text
			end
		end
	end
end

-- SHOP ---------------------------------------------------------------------------------------------------------------------------
local function renderShop(parent: Instance)
	local p = profile()
	local body = bodyScroll(parent)
	section(body, "BOND TOKEN PACKS", 1, C.Friendly)
	local packs = {}
	for key, info in Config.Products do
		table.insert(packs, { key = key, info = info })
	end
	table.sort(packs, function(a, b)
		return a.info.tokens < b.info.tokens
	end)
	local g = grid(body, 3, 138, 2, 10)
	for i, pk in packs do
		local c = Theme.panel({ Color = C.Panel, Stroke = C.Friendly, StrokeTransparency = 0.5, LayoutOrder = i, Parent = g })
		Theme.label({ Text = "◈", Font = "Black", TextSize = 28, Color = C.Friendly, Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 8), Parent = c })
		Theme.label({ Text = Theme.formatNumber(pk.info.tokens) .. " BOND TOKENS", Font = "Black", TextSize = 15, Size = UDim2.new(1, -10, 0, 22), Position = UDim2.fromOffset(5, 46), Parent = c })
		local btn = Theme.button({
			Text = string.format("R$ %d", pk.info.robux),
			TextSize = 15,
			Variant = "primary",
			Size = UDim2.new(1, -24, 0, 34),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -10),
			OnClick = function()
				if pk.info.id == 0 then
					Screens.toast("Not on sale yet", C.Accent)
					Theme.sfx("UIError")
					return
				end
				local ok, err = pcall(function()
					MarketplaceService:PromptProductPurchase(player, pk.info.id)
				end)
				if not ok then
					errorToast("Purchase unavailable")
					warn(err)
				end
			end,
			Parent = c,
		})
		btn.Font = Enum.Font.GothamBlack
	end

	section(body, "GAME PASSES", 3, C.Accent)
	local passes = {
		{ key = "IroncladBond", name = "Ironclad Bond", desc = "Unlocks the whole Ironclad track: access plus every item.", color = Bonds.get("IRONCLAD") and (Bonds.get("IRONCLAD") :: any).color or C.Accent },
		{ key = "HivebreakerBond", name = "Hivebreaker Bond", desc = "Unlocks the whole Hivebreaker track: access plus every item.", color = Bonds.get("HIVEBREAKER") and (Bonds.get("HIVEBREAKER") :: any).color or C.Accent },
		{ key = "SquadColours", name = "Squad Colours", desc = "Cosmetic paint and name colour for your squad.", color = C.Gold },
	}
	local g2 = grid(body, 3, 156, 4, 10)
	for i, ps in passes do
		local info = Config.GamePasses[ps.key]
		local owned = (p.passes or {})[ps.key] == true
		local freeNote
		if info and info.freeAtRank then
			freeNote = string.format("Free at rank %d (you: %d)", info.freeAtRank, p.rank or 1)
			if (p.rank or 1) >= info.freeAtRank then
				owned = true
			end
		end
		local c = Theme.panel({ Color = C.Panel, Stroke = ps.color, StrokeTransparency = 0.45, LayoutOrder = i, Parent = g2 })
		Theme.label({ Text = string.upper(ps.name), Font = "Header", TextSize = 13, Color = ps.color, XAlign = Enum.TextXAlignment.Left, Wrap = true, Size = UDim2.new(1, -20, 0, 20), Position = UDim2.fromOffset(10, 10), Parent = c })
		Theme.label({ Text = ps.desc, Font = "Medium", TextSize = 12, Wrap = true, XAlign = Enum.TextXAlignment.Left, YAlign = Enum.TextYAlignment.Top, Size = UDim2.new(1, -20, 0, 52), Position = UDim2.fromOffset(10, 36), Parent = c })
		if freeNote then
			Theme.label({ Text = freeNote, Font = "Medium", TextSize = 11, Color = C.Friendly, XAlign = Enum.TextXAlignment.Left, Size = UDim2.new(1, -20, 0, 14), Position = UDim2.fromOffset(10, 90), Parent = c })
		end
		local btn = Theme.button({
			Text = owned and "OWNED ✓" or (info and string.format("R$ %d", info.robux) or "R$"),
			TextSize = 14,
			Variant = owned and "good" or "primary",
			Size = UDim2.new(1, -20, 0, 30),
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 10, 1, -8),
			OnClick = function()
				promptPass(ps.key)
			end,
			Parent = c,
		})
		btn.Font = Enum.Font.GothamBlack
		if owned then
			btn.BackgroundColor3 = C.Friendly:Lerp(C.Navy, 0.6)
			Theme.setEnabled(btn, false)
		end
	end

	local fair = Theme.panel({
		Color = C.Navy,
		Stroke = C.Friendly,
		StrokeTransparency = 0.5,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 5,
		Parent = body,
	})
	Theme.pad(fair, 14, 12, 14, 12)
	Theme.label({
		Text = "Everything here can also be earned by playing.  No random boxes, no paid health or damage boosts.",
		Font = "Black",
		TextSize = 14,
		Color = C.Friendly,
		Wrap = true,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = fair,
	})
end

-- MISSION ------------------------------------------------------------------------------------------------------------------------
local FACTIONS = {
	{ id = "COG", name = "Cogwork Legion", glyph = "⚙", color = C.Accent, desc = "Armoured robots that fight at range. Shoot the glowing red eyes." },
	{ id = "BROOD", name = "Skitter Brood", glyph = "✱", color = Color3.fromHex("8cff3a"), desc = "Swarming bugs with fast melee. Goo sacs pop big." },
}
local OBJECTIVES = {
	{ id = "MISSILE", name = "Missile Launch", glyph = "🚀", desc = "Find the codes, power the generator, set the trajectory, open the silo, launch." },
	{ id = "UPLINK", name = "Uplink Relay", glyph = "📡", desc = "Find the relay, plug in the uplink, defend the upload, retrieve the data core." },
}
local DIFFICULTY = { "Cadet", "Trooper", "Veteran", "Elite", "Mayhem" }

local function renderMission(parent: Instance)
	local body = bodyScroll(parent, "Body", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 1, -64))
	section(body, "ENEMY FACTION", 1)
	local g = grid(body, 2, 92, 2, 10)
	for i, f in FACTIONS do
		card(g, {
			Glyph = f.glyph,
			GlyphSize = 30,
			Title = f.name,
			TitleSize = 16,
			Desc = f.desc,
			Selected = missionSel.faction == f.id,
			Stroke = f.color,
			Order = i,
			OnClick = function()
				missionSel.faction = f.id
				render()
			end,
		})
	end

	section(body, "MAIN OBJECTIVE", 3)
	local g2 = grid(body, 2, 92, 4, 10)
	for i, o in OBJECTIVES do
		card(g2, {
			Glyph = o.glyph,
			GlyphSize = 28,
			Title = o.name,
			TitleSize = 16,
			Desc = o.desc,
			Selected = missionSel.objective == o.id,
			Stroke = C.Friendly,
			Order = i,
			OnClick = function()
				missionSel.objective = o.id
				render()
			end,
		})
	end

	section(body, "DIFFICULTY", 5)
	local g3 = grid(body, 5, 70, 6, 8)
	for i, name in DIFFICULTY do
		local hp = Config.DifficultyHpScale[i] or 1
		card(g3, {
			Title = tostring(i) .. "  " .. string.upper(name),
			TitleSize = 12,
			Sub = string.format("Enemy HP x%.1f", hp),
			Selected = missionSel.difficulty == i,
			Stroke = i >= 4 and C.Danger or C.PanelHi,
			Order = i,
			OnClick = function()
				missionSel.difficulty = i
				render()
			end,
		})
	end

	-- footer: summary + launch
	local footer = Theme.panel({
		Color = C.Navy,
		Accent = C.Accent,
		Size = UDim2.new(1, 0, 0, 56),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Parent = parent,
	})
	local fac = FACTIONS[1]
	for _, f in FACTIONS do
		if f.id == missionSel.faction then
			fac = f
		end
	end
	local obj = OBJECTIVES[1]
	for _, o in OBJECTIVES do
		if o.id == missionSel.objective then
			obj = o
		end
	end
	Theme.label({
		Text = string.format("%s  -  vs %s  -  %s", string.upper(obj.name), string.upper(fac.name), string.upper(DIFFICULTY[missionSel.difficulty])),
		Font = "Header",
		TextSize = 12,
		XAlign = Enum.TextXAlignment.Left,
		Wrap = true,
		Size = UDim2.new(1, -230, 1, 0),
		Position = UDim2.fromOffset(14, 0),
		Parent = footer,
	})
	local launch = Theme.button({
		Text = "LAUNCH  ▶",
		TextSize = 20,
		Variant = "primary",
		Size = UDim2.fromOffset(200, 42),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		OnClick = function()
			if busy then
				return
			end
			busy = true
			local ok = request("startMission", { faction = missionSel.faction, objective = missionSel.objective, difficulty = missionSel.difficulty })
			busy = false
			if ok then
				Theme.sfx("UIBuy")
				Screens.toast("Launching mission...", C.Friendly)
				Screens.close()
			end
		end,
		Parent = footer,
	})
	launch.Font = Enum.Font.GothamBlack
end

local PAGES: { [string]: (Instance) -> () } = {
	Loadout = renderLoadout,
	Armory = renderArmory,
	Bonds = renderBonds,
	Shop = renderShop,
	Mission = renderMission,
}

-- Render / open / close ---------------------------------------------------------------------------------------------------------------
render = function()
	if not built or not openName then
		return
	end
	local name = openName
	-- remember scroll
	local old = content:FindFirstChild("Body")
	if old and old:IsA("ScrollingFrame") then
		scrollMemory[name] = old.CanvasPosition
	end
	for _, c in content:GetChildren() do
		c:Destroy()
	end
	renderToken += 1
	local my = renderToken
	titleLabel.Text = TITLES[name] or name
	for _, n in NAMES do
		setTabVisual(n, n == name)
	end
	updateHeader()
	local fn = PAGES[name]
	if fn then
		fn(content)
	end
	local saved = scrollMemory[name]
	if saved and saved.Y > 0 then
		task.defer(function()
			RunService.RenderStepped:Wait()
			if my == renderToken then
				local b = content:FindFirstChild("Body")
				if b and b:IsA("ScrollingFrame") then
					b.CanvasPosition = saved
				end
			end
		end)
	end
end

local function build()
	if built then
		return
	end
	built = true
	touch = Theme.isTouch()
	gui = Theme.gui("OrbitScreens", { DisplayOrder = 60, Insets = "DeviceSafeInsets", Enabled = false })
	root = Theme.root(gui, "menu")

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = C.Dark
	dim.BackgroundTransparency = 0.35
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = root
	dim.Activated:Connect(function()
		Screens.close()
	end)

	window = Theme.panel({
		Name = "Window",
		Color = C.Navy,
		Accent = true,
		Stroke = C.Accent,
		StrokeTransparency = 0.5,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.94, 0.9),
		Active = true,
		Parent = root,
	})
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(1120, 720)
	limit.Parent = window
	Theme.pad(window, 14, 12, 14, 12)

	-- header
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 44)
	header.Parent = window
	titleLabel = Theme.label({
		Text = "",
		Font = "Header",
		TextSize = touch and 18 or 22,
		XAlign = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 260, 1, 0),
		Parent = header,
	})
	local cur = Instance.new("Frame")
	cur.BackgroundTransparency = 1
	cur.AnchorPoint = Vector2.new(1, 0)
	cur.Position = UDim2.new(1, -54, 0, 0)
	cur.Size = UDim2.new(0, 390, 1, 0)
	cur.Parent = header
	Theme.list(cur, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local function chipLabel(order: number, color: Color3): TextLabel
		local pnl = Theme.panel({ Color = C.Dark, Corner = 8, StrokeTransparency = 0.6, Size = UDim2.fromOffset(touch and 100 or 120, 34), LayoutOrder = order, Parent = cur })
		return Theme.label({ Text = "", Font = "Black", TextSize = 15, Rich = true, Size = UDim2.fromScale(1, 1), Parent = pnl })
	end
	hdrRank = chipLabel(1, C.Gold)
	hdrSalvage = chipLabel(2, C.Accent)
	hdrTokens = chipLabel(3, C.Friendly)
	local close = Theme.button({
		Text = "✕",
		TextSize = 20,
		Variant = "danger",
		Size = UDim2.fromOffset(44, 44),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		OnClick = function()
			Screens.close()
		end,
		Parent = header,
	})
	close.Font = Enum.Font.GothamBlack

	-- tabs
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromOffset(0, 50)
	tabs.Size = UDim2.new(1, 0, 0, 40)
	tabs.Parent = window
	Theme.list(tabs, Enum.FillDirection.Horizontal, 6)
	for i, n in NAMES do
		local b = Theme.button({
			Text = string.upper(n),
			TextSize = touch and 12 or 14,
			Variant = "secondary",
			Size = UDim2.new(1 / #NAMES, -5, 1, 0),
			LayoutOrder = i,
			OnClick = function()
				Screens.open(n)
			end,
			Parent = tabs,
		})
		b.Font = Enum.Font.GothamBlack
		tabButtons[n] = b
	end

	content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(0, 98)
	content.Size = UDim2.new(1, 0, 1, -98)
	content.ClipsDescendants = true
	content.Parent = window

	toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toasts"
	toastHolder.BackgroundTransparency = 1
	toastHolder.AnchorPoint = Vector2.new(0.5, 1)
	toastHolder.Position = UDim2.new(0.5, 0, 1, -16)
	toastHolder.Size = UDim2.fromOffset(500, 0)
	toastHolder.AutomaticSize = Enum.AutomaticSize.Y
	toastHolder.ZIndex = 50
	toastHolder.Parent = root
	Theme.list(toastHolder, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)
end

local function bindClose(on: boolean)
	local name = "OrbitScreensClose"
	if on then
		ContextActionService:BindActionAtPriority(name, function(_, state)
			if state == Enum.UserInputState.Begin then
				Screens.close()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB, Enum.KeyCode.Backspace)
	else
		ContextActionService:UnbindAction(name)
	end
end

function Screens.isOpen(): boolean
	return openName ~= nil
end

function Screens.open(name: string)
	-- missions are launched from the galactic war map (UI/WarMap)
	if name == "Mission" then
		if openName then
			Screens.close()
		end
		local ok, WarMap = pcall(require, script.Parent.WarMap)
		if ok then
			WarMap.open()
		end
		return
	end
	if not PAGES[name] then
		return
	end
	build()
	local wasOpen = openName ~= nil
	if not wasOpen then
		local m = Store.get("mission")
		if m and m.state and m.state ~= "Ship" then
			return
		end
		syncLoadoutFromProfile(true)
		loadoutDirty = false
	end
	openName = name
	gui.Enabled = true
	if not wasOpen then
		Theme.sfx("UIOpen")
		Store.set("menuOpen", true)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		bindClose(true)
		window.Position = UDim2.fromScale(0.5, 0.53)
		Theme.tween(window, 0.2, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back)
		task.spawn(refreshProfile)
	end
	render()
end

function Screens.close()
	if not openName then
		return
	end
	openName = nil
	if gui then
		gui.Enabled = false
	end
	bindClose(false)
	Store.set("menuOpen", false)
	if loadoutThread then
		-- flush a pending loadout change immediately
		task.cancel(loadoutThread)
		loadoutThread = nil
		task.spawn(function()
			request("setLoadout", {
				primary = loadout.primary,
				secondary = loadout.secondary,
				grenade = loadout.grenade,
				callins = loadout.callins,
			})
			loadoutDirty = false
		end)
	end
end

function Screens.init()
	build()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who ~= player then
			return
		end
		local screen = prompt:GetAttribute("OpenScreen")
		if type(screen) == "string" and PAGES[screen] then
			Screens.open(screen)
		end
	end)
	Store.on("profile", function()
		if openName then
			syncLoadoutFromProfile()
			render()
		end
	end)
	Store.on("mission", function()
		local m = Store.get("mission")
		if openName and m and m.state and m.state ~= "Ship" then
			Screens.close()
		end
	end)
end

return Screens
