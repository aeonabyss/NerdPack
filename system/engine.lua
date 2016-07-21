NeP.Engine = {
	Run = false,
	SelectedCR = nil,
	ForceTarget = nil,
	lastCast = nil,
	forcePause = false,
	Current_Spell = nil,
	Rotations = {},
	------------------------------------ Fake Units ------------------------------------
	FakeUnits = {
		['lowest']		= function() return	 NeP.Healing['lowest']()					end,
		['!lowest']	= function() return '!'..NeP.Healing['lowest']()					end,
		['tank']		= function() return	 NeP.Healing['tank']()						end,
		['!tank']		= function() return '!'..NeP.Healing['tank']()						end,
		['tanktarget']	= function() return	 NeP.Healing['tank']()..'target'			end,
		['!tanktarget'] = function() return '!'..NeP.Healing['tank']()..'target'			end,
		['nil']		= function() return UnitExists('target') and 'target' or 'player'	end
	}
}

local Engine = NeP.Engine
local Core = NeP.Core
local Debug = Core.Debug
local TA = Core.TA
local Parse = NeP.DSL.parse
local fK = NeP.Interface.fetchKey

local ListClassSpec = {
	[0] = {}, -- None
	[1] = { -- Warrior
		[71] = 'Arms',
		[72] = 'Fury',
		[73] = 'Protection',
	},
	[2] = {  -- Paladin
		[65] = 'Holy',
		[66] = 'Protection',
		[70] = 'Retribution',
	},
	[3] = { -- Hunter
		[253] = 'Beast Mastery',
		[254] = 'Marksmanship',
		[255] = 'Survival',
	},
	[4] = { -- Rogue
		[259] = 'Assassination',
		[260] = 'Combat',
		[261] = 'Subtlety',
	},
	[5] = {  -- Priest
		[256] = 'Discipline',
		[257] = 'Holy',
		[258] = 'Shadow',
	},
	[6] = { -- DeathKnight
		[250] = 'Blood',
		[251] = 'Frost',
		[252] = 'Unholy',
	},
	[7] = {  -- Shaman
		[262] = 'Elemental',
		[263] = 'Enhancement',
		[264] = 'Restoration',
	},
	[8] = {  -- Mage
		[62] = 'Arcane',
		[63] = 'Fire',
		[64] = 'Frost',
	},
	[9] = { -- Warlock
		[265] = 'Affliction',
		[266] = 'Demonology',
		[267] = 'Destruction',
	},
	[10] = { -- Monk
		[268] = 'Brewmaster',
		[269] = 'Windwalker',
		[270] = 'Mistweaver',
	},
	[11] = { -- Druid
		[102] = 'Balance',
		[103] = 'Feral Combat',
		[104] = 'Guardian',
		[105] = 'Restoration',
	},
	[12] = { -- Demon Hunter
		[577] = 'Havoc',
		[581] = 'Vengeance',
	}
}

-- Register CRs
function Engine.registerRotation(SpecID, CrName, InCombat, outCombat, initFunc)
	-- Only Load Crs for our current class (saves memory)
	local Spec = GetSpecialization() or 0
	local SpecInfo = GetSpecializationInfo(Spec)
	local localizedClass, englishClass, classIndex = UnitClass('player')
	if ListClassSpec[tonumber(classIndex)][tonumber(SpecID)] ~= nil
	or ListClassSpec[tonumber(SpecID)] ~= nil then
		-- If SpecID Table is not created yet, create one.
		if Engine.Rotations[SpecID] == nil then Engine.Rotations[SpecID] = {} end
		-- In case someone tries to load a cr with the same name of a existing one
		local TableName = CrName
		if Engine.Rotations[SpecID][CrName] ~= nil then TableName = CrName..'_'..math.random(0,1000) end
		-- Create CR table
		Engine.Rotations[SpecID][TableName] = { 
			[true] = InCombat,
			[false] = outCombat,
			['InitFunc'] = initFunc or (function() return end),
			['Name'] = CrName
		}
	end
end


local function insertToLog(whatIs, spell, target)
	local targetName = UnitName(target or 'player')
	local name, icon
	if whatIs == 'Spell' then
		local spellIndex, spellBook = GetSpellBookIndex(spell)
		if spellBook then
			local spellID = select(2, GetSpellBookItemInfo(spellIndex, spellBook))
			name, _, icon = GetSpellInfo(spellIndex, spellBook)
		else
			name, _, icon = GetSpellInfo(spellIndex)
		end
	elseif whatIs == 'Item' or whatIs == 'InvItem' then
		name, _,_,_,_,_,_,_,_, icon = GetItemInfo(spell)
	end
	NeP.MFrame.usedButtons['MasterToggle'].texture:SetTexture(icon)
	NeP.ActionLog.insert('Engine_'..whatIs, name, icon, targetName)
end

local function Cast(spell, target, ground)
	if ground then
		Engine.CastGround(spell, target)
	else
		Engine.Cast(spell, target)
	end
	Engine.lastCast = spell
	insertToLog('Spell', spell, target)
end

local function checkTarget(spell, target)
	local target = tostring(target)
	local ground = false
	-- Allow functions/conditions to force a target
	if Engine.ForceTarget then
		target = Engine.ForceTarget	
		Engine.ForceTarget = nil
	end
	-- Ground target
	if string.sub(target, -7) == '.ground' then
		ground = true
		target = string.sub(target, 0, -8)
	end
	-- Fake Target
	if Engine.FakeUnits[target] then
		target = Engine.FakeUnits[target]()
	end
	-- Sanity Checks
	if IsHarmfulSpell(spell) and not UnitCanAttack('player', target) then
		return false
	elseif UnitExists(target) and Engine.LineOfSight('player', target) then
		return true, target, ground
	end
	return false
end

local function castSanityCheck(spell)
	if type(spell) == 'string' then
		-- Turn string to number (If they'r IDs)
		if string.match(spell, '%d') then
			spell = tonumber(spell)
			-- SOME SPELLS DO NOT CAST BY IDs! (make them names...)
			spell = GetSpellInfo(spell)
		end
		if spell then
			Debug('Engine', 'castSanityCheck_Spell:'..tostring(spell))
			-- Make sure we have the spell
			local skillType, spellId = GetSpellBookItemInfo(tostring(spell))
			if skillType == 'FUTURESPELL' then 
				Debug('Engine', 'castSanityCheck hit FUTURESPELL')
				return false
			-- Spell Sanity Checks
			elseif IsUsableSpell(spell) then
				if GetSpellCooldown(spell) < 1 then
					Debug('Engine', 'castSanityCheck passed')
					Engine.Current_Spell = spell
					return true, spell
				end 
			end
		end
	end
	return false
end

local function canIterate(pX)
	if not UnitIsDeadOrGhost('player') then
		local tP, pX = type(px), nil
		if tP == 'string' then pX = string.sub(pX, 1, 1) end
		local nCasting = UnitCastingInfo('player') == nil
		local nChanneling = UnitChannelInfo('player') == nil
		if nCasting and nChanneling or pX == '!' then
			return true
		end
	end
	return false
end

local function castingTime(target)
    local _,_,_,_,_, endTime= UnitCastingInfo(target)
    if endTime then return endTime end
    return false
end

local invItems = {
	['head']		= 'HeadSlot',
	['helm']		= 'HeadSlot',
	['neck']		= 'NeckSlot',
	['shoulder']	= 'ShoulderSlot',
	['shirt']		= 'ShirtSlot',
	['chest']		= 'ChestSlot',
	['belt']		= 'WaistSlot',
	['waist']		= 'WaistSlot',
	['legs']		= 'LegsSlot',
	['pants']		= 'LegsSlot',
	['feet']		= 'FeetSlot',
	['boots']		= 'FeetSlot',
	['wrist']		= 'WristSlot',
	['bracers']		= 'WristSlot',
	['gloves']		= 'HandsSlot',
	['hands']		= 'HandsSlot',
	['finger1']		= 'Finger0Slot',
	['finger2']		= 'Finger1Slot',
	['trinket1']	= 'Trinket0Slot',
	['trinket2']	= 'Trinket1Slot',
	['back']		= 'BackSlot',
	['cloak']		= 'BackSlot',
	['mainhand']	= 'MainHandSlot',
	['offhand']		= 'SecondaryHandSlot',
	['weapon']		= 'MainHandSlot',
	['weapon1']		= 'MainHandSlot',
	['weapon2']		= 'SecondaryHandSlot',
	['ranged']		= 'RangedSlot'
}

local sTrigger = {
	-- Cancel cast
	['!'] = function(spell, target)
	print(1)
		local spell = string.sub(spell, 2);
		local canCast, spell = castSanityCheck(spell)
		if canCast then
			print(2)
			local castingTime = castingTime('player')
			if not castingTime or castingTime > 1 then
				print(3)
				local hasTarget, target, ground = checkTarget(target)
				if hasTarget then
					print(4)
					SpellStopCasting()
					Cast(spell, target, ground)
					return true
				end
			end
		end
	end,
	-- Item
	['#'] = function(spell, target)
		Debug('Engine', 'Hit Item trigger')
		local item = string.sub(spell, 2);
		-- Inventory (Gear)
		if invItems[tostring(item)] then
			local item = invItems[tostring(item)]
			local item_X = GetInventoryItemID("player", GetInventorySlotInfo(item))
			Debug('Engine', 'Inventory Item: '..item)
			local isUsable, notEnoughMana = IsUsableItem(item_X)
			if isUsable then
				Debug('Engine', 'Is Usable')
				local itemStart, itemDuration, itemEnable = GetItemCooldown(item_X)
				if itemStart == 0 then
					Debug('Engine', 'Used item')
					insertToLog('InvItem', item_X, target)
					Engine.UseInvItem(GetInventorySlotInfo(item))
					return true
				end
			end
		-- Normal
		else
			local isUsable, notEnoughMana = IsUsableItem(item)
			if isUsable then
				local itemStart, itemDuration, itemEnable = GetItemCooldown(item)
				if itemStart == 0 and GetItemCount(item) > 0 then
					insertToLog('Item', item, target)
					Engine.UseItem(item, target)
					return true
				end
			end
		end
	end,
	-- Lib
	['@'] = function(spell, target)
		NeP.library.parse(false, spell, target)
		return true
	end,
	-- Macro
	['/'] = function(spell, target)
		Engine.Macro(spell)
		return true
	end
}

local pTypes = {
	['table'] = function(spell, tar)
		Debug('Engine', 'Iterate: Hit Table')
		Engine.Iterate(spell)
	end,
	['function'] = function(spell, tar)
		Debug('Engine', 'Iterate: Hit Func')
		if canIterate() then
			spell()
			return true
		end
	end,
	['string'] = function(spell, tar)
		Debug('Engine', 'Iterate: Hit String')
		local pX = string.sub(spell, 1, 1)
		-- Pause
		if spell == 'pause' then
			Debug('Engine', 'Iterate: Hit Pause')
				return true
		-- Special trigers
		elseif sTrigger[pX] then
			Debug('Engine', 'Iterate: Hit Special Trigers')
			local sb = sTrigger[pX](spell, tar)
			return sb
		-- Regular sanity checks
		else
			Debug('Engine', 'Iterate: Hit Normal')
			local canCast, spell = castSanityCheck(spell)
			if canCast then
				Debug('Engine', 'Iterate: Can Cast')
				local hasTarget, target, ground = checkTarget(spell, tar)
				if hasTarget then
					Debug('Engine', 'Iterate: Has Target: '..target..' Ground: '..tostring(ground))
					Cast(spell, target, ground)
					return true
				end
			end
		end
	end
}

-- This iterates the routine table itself.
function Engine.Iterate(table)
	for i=1, #table do
		local aR, tP = table[i], type(table[i][1])
		if pTypes[tP]and canIterate(aR[1]) then
			if Parse(aR[2], aR[1]) then
				local sB = pTypes[tP](aR[1], aR[3])
				if sB then break end
			end
		end
	end
end

-- Engine Ticker
local LastTimeOut = 0
C_Timer.NewTicker(0.1, (function()
	local Running = NeP.Config.Read('bStates_MasterToggle', false)
	if Running and not Engine.forcePause then
		-- Hide FaceRoll.
		NeP.FaceRoll:Hide()
		-- Run the engine.
		if Engine.SelectedCR then
			local InCombatCheck = UnitAffectingCombat('player')
			local table = Engine.SelectedCR[InCombatCheck]
			Engine.Iterate(table)
		else
			Core.Message(TA('Engine', 'NoCR'))
		end
	end
end), nil)