local utils = require 'shared.utils'

local activeCitizenIds = {}
local selectorBuckets = {}
local SELECTOR_BUCKET_BASE = 700000

local function selectorBucketId(src)
  return SELECTOR_BUCKET_BASE + src
end

local function setSelectorBucket(src)
  if type(src) ~= 'number' or src <= 0 then return nil end
  local bucket = selectorBuckets[src] or selectorBucketId(src)
  selectorBuckets[src] = bucket
  SetPlayerRoutingBucket(src, bucket)
  local player = Player and Player(src)
  if player and player.state then
    player.state:set('execMulticharSelector', true, true)
  end
  return bucket
end

local function clearSelectorBucket(src, targetBucket)
  if type(src) ~= 'number' or src <= 0 then return end
  selectorBuckets[src] = nil
  SetPlayerRoutingBucket(src, tonumber(targetBucket) or 0)
  local player = Player and Player(src)
  if player and player.state then
    player.state:set('execMulticharSelector', false, true)
  end
end

local function setActiveCitizenId(src, citizenid)
  if type(src) ~= 'number' or src <= 0 then return end
  if citizenid == nil then
    activeCitizenIds[src] = nil
  else
    activeCitizenIds[src] = citizenid
  end
  local player = Player and Player(src)
  if player and player.state then
    player.state:set('execCitizenId', citizenid or '', true)
  end
end

local function clearActiveCitizenId(src)
  if type(src) ~= 'number' or src <= 0 then return end
  activeCitizenIds[src] = nil
  local player = Player and Player(src)
  if player and player.state then
    player.state:set('execCitizenId', '', true)
  end
end

AddEventHandler('onResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  MySQL.ready(function()
    MySQL.query([[]]
      .. [[CREATE TABLE IF NOT EXISTS `characters` (]]
      .. [[  `citizenid` VARCHAR(64) NOT NULL,]]
      .. [[  `license`   VARCHAR(64) NOT NULL,]]
      .. [[  `firstname` VARCHAR(32) NOT NULL,]]
      .. [[  `lastname`  VARCHAR(32) NOT NULL,]]
      .. [[  `gender`    VARCHAR(8)  NOT NULL,]]
      .. [[  `dob`       DATE        NULL,]]
      .. [[  `created_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,]]
      .. [[  PRIMARY KEY (`citizenid`),]]
      .. [[  KEY `license_idx` (`license`)]]
      .. [[) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    )
    MySQL.query([[]]
      .. [[CREATE TABLE IF NOT EXISTS `character_appearance` (]]
      .. [[  `citizenid` VARCHAR(64) NOT NULL,]]
      .. [[  `appearance` LONGTEXT NULL,]]
      .. [[  `updated_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,]]
      .. [[  PRIMARY KEY (`citizenid`)]]
      .. [[) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    )
  end)
end)

local function identifier(src, typ)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:sub(1, #typ+1) == (typ..":") then return id end
  end
end
local function license(src)
  return identifier(src, 'license') or identifier(src, 'license2') or identifier(src, 'fivem') or identifier(src, 'steam') or ('net:'..tostring(src))
end

local function decodeAppearanceModel(appearance)
  if type(appearance) ~= 'string' or appearance == '' then return nil end
  local ok, decoded = pcall(json.decode, appearance)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded._execModel or decoded._execModelHash or decoded.model or decoded.modelHash or decoded.ped or decoded.hash or decoded.pedHash
end

lib.callback.register('exec_multichar:list', function(src)
  local lic = license(src)
  local rows = MySQL.query.await([[
    SELECT c.citizenid, c.firstname, c.lastname, c.gender, DATE_FORMAT(c.dob, "%Y-%m-%d") AS dob, ca.appearance
    FROM characters c
    LEFT JOIN character_appearance ca ON ca.citizenid = c.citizenid
    WHERE c.license = ?
    ORDER BY c.created_at ASC
  ]], { lic })
  for _, row in ipairs(rows or {}) do
    row.model = decodeAppearanceModel(row.appearance)
    row.appearance = nil
  end
  return rows or {}
end)

lib.callback.register('exec_multichar:create', function(src, data)
  local lic = license(src)
  local citizenid = utils.randomCitizenId('EXEC')
  local first = utils.sanitizeName(data.firstname)
  local last  = utils.sanitizeName(data.lastname)
  local gender= (data.gender == 'female') and 'female' or 'male'
  local dob   = data.dob or '2000-01-01'
  MySQL.insert.await('INSERT INTO characters (citizenid, license, firstname, lastname, gender, dob) VALUES (?, ?, ?, ?, ?, ?)', { citizenid, lic, first, last, gender, dob })
  return { ok=true, citizenid=citizenid, display=(first .. ' ' .. last), gender=gender }
end)

lib.callback.register('exec_multichar:getAppearance', function(src, citizenid)
  local row = MySQL.single.await('SELECT appearance FROM character_appearance WHERE citizenid = ?', { citizenid })
  return row and row.appearance or nil
end)

RegisterNetEvent('exec_multichar:saveAppearance', function(citizenid, appearanceJson)
  if type(appearanceJson) == 'table' then appearanceJson = json.encode(appearanceJson) end
  MySQL.insert('INSERT INTO character_appearance (citizenid, appearance) VALUES (?, ?) ON DUPLICATE KEY UPDATE appearance = VALUES(appearance), updated_at = CURRENT_TIMESTAMP', { citizenid, appearanceJson })
end)

lib.callback.register('exec_multichar:delete', function(src, citizenid)
  local lic = license(src)
  local owner = MySQL.single.await('SELECT license FROM characters WHERE citizenid = ?', { citizenid })
  if not owner or owner.license ~= lic then
    return { ok=false, error='Not your character' }
  end
  if activeCitizenIds[src] == citizenid then
    clearActiveCitizenId(src)
  end
  MySQL.prepare.await('DELETE FROM character_appearance WHERE citizenid = ?', { citizenid })
  MySQL.prepare.await('DELETE FROM characters WHERE citizenid = ?', { citizenid })
  return { ok=true }
end)

lib.callback.register('exec_multichar:select', function(src, citizenid)
  local row = MySQL.single.await('SELECT citizenid, firstname, lastname, gender FROM characters WHERE citizenid = ?', { citizenid })
  if not row then return { ok=false, error='Character not found' } end
  TriggerClientEvent('exec_multichar:selected', src, { citizenid=citizenid, display=row.firstname .. ' ' .. row.lastname })
  TriggerClientEvent('exec_multichar:readyForPvp', src, { citizenid=citizenid, display=row.firstname .. ' ' .. row.lastname })
  setActiveCitizenId(src, citizenid)
  return { ok=true }
end)

AddEventHandler('playerDropped', function()
  local src = source
  selectorBuckets[src] = nil
  clearActiveCitizenId(src)
end)

RegisterNetEvent('exec_multichar:clearActiveCharacter', function()
  local src = source
  clearActiveCitizenId(src)
end)

RegisterNetEvent('exec_multichar:enterSelectorBucket', function()
  setSelectorBucket(source)
end)

RegisterNetEvent('exec_multichar:leaveSelectorBucket', function(targetBucket)
  clearSelectorBucket(source, targetBucket)
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  for src in pairs(selectorBuckets) do
    if GetPlayerName(src) then
      clearSelectorBucket(src, 0)
    end
  end
end)

exports('GetActiveCitizenId', function(src)
  if type(src) ~= 'number' then return nil end
  return activeCitizenIds[src]
end)

exports('EnterSelectorBucket', function(src)
  return setSelectorBucket(src)
end)

exports('ReleaseSelectorBucket', function(src, targetBucket)
  clearSelectorBucket(src, targetBucket)
end)

exports('IsInSelectorBucket', function(src)
  if type(src) ~= 'number' then return false end
  return selectorBuckets[src] ~= nil
end)
