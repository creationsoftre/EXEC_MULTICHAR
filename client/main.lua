local studio = require 'config.studio'
local appcfg = require 'config.appearance'
local pedcfg = require 'config.peds'
local animcfg = require 'config.anims'
local hudcfg = require 'config.huds'
local uicfg = require 'config.ui'

local selected    = false
local inStudio    = false
local creating    = false
local currentCitizenId = nil
local cam = nil
local camIndex = 1
local animIndex = 1
local animTimer = 0

local uiOpen = false
local selectionId = nil
local charactersList = {}
local appearanceCache = {}
local pendingPreview = nil

local hudControllers = {}
local hudSuppressed = false

local DEFAULT_STATUS = 'Pick a character or create a new one.'

local function sendUi(action, payload)
  if not action then return end
  local msg = payload or {}
  msg.action = action
  SendNUIMessage(msg)
end

local function setUiFocus(enable)
  SetNuiFocus(enable, enable)
  if type(SetNuiFocusKeepInput) == 'function' then
    SetNuiFocusKeepInput(false)
  end
end

local function normalizeHudEntry(data)
  if type(data) ~= 'table' then return nil end
  if data.resource and data.hide then
    return {
      type = 'export',
      resource = data.resource,
      hide = data.hide,
      show = data.show,
      hideArgs = data.hideArgs,
      showArgs = data.showArgs
    }
  elseif data.hideEvent or data.showEvent then
    return {
      type = 'event',
      hide = data.hideEvent,
      show = data.showEvent,
      hideArgs = data.hideArgs,
      showArgs = data.showArgs
    }
  end
  return nil
end

local function asArgs(value)
  if value == nil then return {} end
  if type(value) == 'table' then return value end
  return { value }
end

local function callHudEntry(entry, visible)
  if not entry then return end
  local fnName = visible and entry.show or entry.hide
  if not fnName then return end
  local args = visible and asArgs(entry.showArgs) or asArgs(entry.hideArgs)
  if entry.type == 'export' then
    local ok, err = pcall(function()
      local res = entry.resource
      if not res then return end
      local exportsTable = exports[res]
      if not exportsTable then return end
      local fn = exportsTable[fnName]
      if type(fn) ~= 'function' then return end
      fn(table.unpack(args))
    end)
    if not ok then
      print(('[exec_multichar] hud export call failed (%s:%s): %s'):format(entry.resource or 'unknown', fnName, err))
    end
  elseif entry.type == 'event' then
    TriggerEvent(fnName, table.unpack(args))
  end
end

local function setHudSuppressed(state)
  local want = state and true or false
  if hudSuppressed == want then return end
  hudSuppressed = want
  for _, entry in pairs(hudControllers) do
    callHudEntry(entry, not hudSuppressed)
  end
end

local function sendToast(text)
  if uiOpen and text and text ~= '' then
    sendUi('toast', { text = text })
  end
end

local function setUiBusyState(on, status)
  if uiOpen then
    sendUi('busy', { value = on and true or false, status = status })
  end
end

local function setUiLoading(on)
  if uiOpen then
    sendUi('loading', { value = on and true or false })
  end
end

local function setUiStatus(text)
  if uiOpen then
    sendUi('status', { text = text or DEFAULT_STATUS })
  end
end

local function openUi(status)
  if not uiOpen then
    uiOpen = true
    setHudSuppressed(true)
    setUiFocus(true)
  end
  sendUi('open', {
    status = status or DEFAULT_STATUS,
    loading = true,
    characters = {},
    selected = selectionId,
    colors = uicfg and uicfg.colors or {}
  })
end

local function closeUi(releaseHud)
  if uiOpen then
    sendUi('close', {})
  end
  uiOpen = false
  pendingPreview = nil
  setUiFocus(false)
  if releaseHud ~= false then
    setHudSuppressed(false)
  end
end

local previewCharacter

local function registerHudController(id, data)
  local entry = normalizeHudEntry(data)
  if not entry then return false end
  local key = id
  if type(key) ~= 'string' or key == '' then
    key = entry.resource or entry.hide or ('hud_' .. tostring(#hudControllers + 1))
    local idx = 1
    while hudControllers[key] do
      idx += 1
      key = key .. '_' .. idx
    end
  elseif hudControllers[key] then
    return false
  end
  hudControllers[key] = entry
  if hudSuppressed then
    callHudEntry(entry, false)
  end
  return key
end

local function unregisterHudController(id)
  if not id then return end
  hudControllers[id] = nil
end

exports('RegisterHudController', registerHudController)
exports('UnregisterHudController', unregisterHudController)
exports('SetHudSuppressed', function(state) setHudSuppressed(state) end)

CreateThread(function()
  if type(hudcfg) ~= 'table' then return end
  for idx, entry in ipairs(hudcfg) do
    local key = entry.id or ('config_' .. idx)
    registerHudController(key, entry)
  end
end)

-- camera tweakables
local camZoom = 1.0      -- target zoom
local camPanX = 0.0      -- target pan
local ZOOM_MIN, ZOOM_MAX = 0.5, 1.8
local PAN_MIN, PAN_MAX   = -1.5, 1.5
local ZOOM_STEP, PAN_STEP= 0.06, 0.08
local smoothingCfg = studio.smoothing or {}
local camSmoothingEnabled = smoothingCfg.enabled ~= false
local camPosLerp = tonumber(smoothingCfg.positionLerp) or 10.0
local camFovLerp = tonumber(smoothingCfg.fovLerp) or 12.0
local camSnapDistance = tonumber(smoothingCfg.snapDistance) or 2.5
local camState = nil
local camRendered = false

-- ===== Spawnmanager hardening =====
local function disableSpawnmanagerAutoSpawn()
  if exports and exports.spawnmanager then
    pcall(function() exports.spawnmanager:setAutoSpawn(false) end)
  end
end

local function reallyDisableAutoSpawn()
  CreateThread(function()
    local tried = 0
    while tried < 120 do
      tried += 1
      if exports and exports.spawnmanager then
        disableSpawnmanagerAutoSpawn()
        if not selected then
          pcall(function()
            if exports.spawnmanager.setAutoSpawnCallback then
              exports.spawnmanager:setAutoSpawnCallback(function()
                local pedModel = GetEntityModel(PlayerPedId())
                exports.spawnmanager:spawnPlayer({
                  x = studio.coords.x, y = studio.coords.y, z = studio.coords.z,
                  heading = studio.heading or 0.0,
                  model = pedModel,
                  skipFade = false
                }, function()
                  setStudio()
                end)
              end)
            end
          end)
        end
        break
      end
      Wait(500)
    end
  end)
end
AddEventHandler('onClientResourceStart', function(res)
  if res == 'spawnmanager' then reallyDisableAutoSpawn() end
end)

AddEventHandler('playerSpawned', function()
  if not selected then
    SetEntityCoordsNoOffset(PlayerPedId(), studio.coords.x, studio.coords.y, studio.coords.z, false, false, false)
    SetEntityHeading(PlayerPedId(), studio.heading or 0.0)
    setStudio()
  end
end)

-- ===== Studio / camera =====
local function destroyCam()
  if cam and DoesCamExist(cam) then
    RenderScriptCams(false, true, 250, true, true)
    DestroyCam(cam, false)
    cam = nil
  end
  camState = nil
  camRendered = false
end

local function boneIdByName(name)
  if not name then return nil end
  local map = { head = 31086 }
  return map[name]
end

local function camLerp(current, target, speed, dt)
  if not camSmoothingEnabled then return target end
  local alpha = 1.0 - math.exp(-(speed * dt))
  return current + ((target - current) * alpha)
end

local function getCameraTarget()
  local ped = PlayerPedId()
  if not DoesEntityExist(ped) then return nil end
  local cams = studio.cams or {}
  if not cams[camIndex] then return nil end

  local off = cams[camIndex].offset or vec3(0.0, 1.6, 0.9)
  local fov = cams[camIndex].fov or 58.0

  local pos = GetEntityCoords(ped)
  local fwd = GetEntityForwardVector(ped)
  -- derive a right vector in 2D from forward (normalize implicit)
  local rightX, rightY = -fwd.y, fwd.x

  local cX = pos.x + fwd.x * (off.y * camZoom) + rightX * camPanX
  local cY = pos.y + fwd.y * (off.y * camZoom) + rightY * camPanX
  local cZ = pos.z + (off.z * camZoom)

  return {
    x = cX,
    y = cY,
    z = cZ,
    fov = fov,
    bone = boneIdByName(cams[camIndex].bone)
  }
end

local function buildCamera(force)
  local ped = PlayerPedId()
  if not DoesEntityExist(ped) then return end

  local target = getCameraTarget()
  if not target then return end

  if not cam or not DoesCamExist(cam) then
    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    force = true
  end

  if force or not camState then
    camState = {
      x = target.x,
      y = target.y,
      z = target.z,
      fov = target.fov,
    }
  else
    local dt = math.max(GetFrameTime(), 0.0)
    local dx = target.x - camState.x
    local dy = target.y - camState.y
    local dz = target.z - camState.z
    local dist = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
    if dist > camSnapDistance then
      camState.x = target.x
      camState.y = target.y
      camState.z = target.z
      camState.fov = target.fov
    else
      camState.x = camLerp(camState.x, target.x, camPosLerp, dt)
      camState.y = camLerp(camState.y, target.y, camPosLerp, dt)
      camState.z = camLerp(camState.z, target.z, camPosLerp, dt)
      camState.fov = camLerp(camState.fov, target.fov, camFovLerp, dt)
    end
  end

  SetCamCoord(cam, camState.x, camState.y, camState.z)
  SetCamFov(cam, camState.fov)
  if target.bone then
    PointCamAtPedBone(cam, ped, target.bone, 0.0, 0.0, 0.0, true)
  else
    PointCamAtEntity(cam, ped, 0.0, 0.0, 0.0, true)
  end
  SetCamActive(cam, true)
  if force or not camRendered then
    RenderScriptCams(true, not force, force and 0 or 200, true, true)
    camRendered = true
  end
end

function setStudio()
  local ped = PlayerPedId()
  SetEntityCoordsNoOffset(ped, studio.coords.x, studio.coords.y, studio.coords.z, false,false,false)
  SetEntityHeading(ped, studio.heading or 0.0)
  FreezeEntityPosition(ped, true)
  SetEntityInvincible(ped, true)
  DisplayRadar(false)

  if studio.pose and studio.pose.enable and studio.pose.weapon then
    GiveWeaponToPed(ped, joaat(studio.pose.weapon), 0, true, true)
    SetCurrentPedWeapon(ped, joaat(studio.pose.weapon), true)
  end

  buildCamera(true)
end

local function cycleCam(delta)
  local cams = studio.cams or {}
  local total = #cams
  if total == 0 then return end
  delta = delta or 1
  camIndex = ((camIndex - 1 + delta) % total) + 1
  -- reset zoom/pan for each camera
  camZoom, camPanX = 1.0, 0.0
end

-- ===== Animations (scenarios) =====
local function stopStudioAnim() ClearPedTasks(PlayerPedId()) end

local function playAnim(idx)
  if not animcfg or not animcfg.list or #animcfg.list == 0 then return end
  local ped = PlayerPedId()
  local entry = animcfg.list[idx]
  if not entry then return end
  stopStudioAnim()
  if entry.type == 'scenario' and entry.name then
    TaskStartScenarioInPlace(ped, entry.name, 0, true)
  elseif entry.type == 'anim' and entry.dict and entry.clip then
    RequestAnimDict(entry.dict); while not HasAnimDictLoaded(entry.dict) do Wait(0) end
    TaskPlayAnim(ped, entry.dict, entry.clip, 4.0, -4.0, -1, 1, 0, false, false, false)
  end
end

local function cycleAnim(delta)
  local total = (animcfg.list and #animcfg.list) or 0
  if total == 0 then return end
  animIndex = animIndex + delta
  if animIndex < 1 then animIndex = total end
  if animIndex > total then animIndex = 1 end
  playAnim(animIndex)
end

-- Auto-rotate (disabled by default by config)
CreateThread(function()
  while true do
    Wait(500)
    if inStudio and animcfg.autoRotateSeconds and animcfg.autoRotateSeconds > 0 then
      animTimer = animTimer + 0.5
      if animTimer >= animcfg.autoRotateSeconds then
        animTimer = 0
        cycleAnim(1)
      end
    else
      animTimer = 0
    end
  end
end)

-- watchdog
CreateThread(function()
  while true do
    if inStudio then
      local ped = PlayerPedId()
      local here = GetEntityCoords(ped)
      local target = studio.coords
      if #(here - target) > 2.0 then
        SetEntityCoordsNoOffset(ped, target.x, target.y, target.z, false,false,false)
        SetEntityHeading(ped, studio.heading or 0.0)
        setStudio()
        playAnim(animIndex)
      end
      if not IsEntityPositionFrozen(ped) then FreezeEntityPosition(ped, true) end
      HideHudAndRadarThisFrame()
      DisplayRadar(false)
      Wait(0)
    else
      Wait(600)
    end
  end
end)

-- ===== Appearance helpers =====
local function parseModelValue(value)
  if type(value) == 'number' then return value end
  if type(value) ~= 'string' then return nil end
  local trimmed = value:match('^%s*(.-)%s*$')
  if trimmed == '' then return nil end
  if trimmed:sub(1, 2) == '0x' then
    return tonumber(trimmed, 16)
  end
  local numeric = tonumber(trimmed)
  if numeric then return numeric end
  return joaat(trimmed)
end

local function ensurePlayerModel(app)
  if type(app) ~= 'table' then return end
  local model = parseModelValue(app._execModelHash)
    or parseModelValue(app._execModel)
    or parseModelValue(app.model)
    or parseModelValue(app.modelHash)
    or parseModelValue(app.ped)
    or parseModelValue(app.hash)
    or parseModelValue(app.pedHash)
  if not model or model == 0 then return end
  if not IsModelInCdimage(model) or not IsModelValid(model) then return end
  local ped = PlayerPedId()
  if ped ~= 0 and GetEntityModel(ped) == model then return end
  RequestModel(model)
  while not HasModelLoaded(model) do
    Wait(0)
  end
  SetPlayerModel(PlayerId(), model)
  local newPed = PlayerPedId()
  if newPed ~= 0 then
    SetPedDefaultComponentVariation(newPed)
  end
  SetModelAsNoLongerNeeded(model)
end

local function captureCurrentAppearance(app)
  local captured = nil
  if exports and exports['fivem-appearance'] then
    pcall(function()
      if exports['fivem-appearance'].getPedAppearance then
        captured = exports['fivem-appearance']:getPedAppearance(PlayerPedId())
      end
    end)
  end

  local out = type(captured) == 'table' and captured or app
  if type(out) ~= 'table' then out = {} end

  local ped = PlayerPedId()
  if ped ~= 0 and DoesEntityExist(ped) then
    out._execModelHash = GetEntityModel(ped)
    if exports and exports['fivem-appearance'] then
      pcall(function()
        if exports['fivem-appearance'].getPedModel then
          out._execModel = exports['fivem-appearance']:getPedModel(ped)
        end
      end)
    end
  end

  return out
end

local function applySavedAppearance(jsonApp)
  local ok, app = pcall(json.decode, jsonApp or '')
  if not ok or not app then return end
  if app._execModel or app._execModelHash then
    app.model = app._execModel or app._execModelHash
  end
  ensurePlayerModel(app)
  if app._native then
    local ped = PlayerPedId()
    for i, v in pairs(app.comp or {}) do
      SetPedComponentVariation(ped, tonumber(i), v.d or 0, v.t or 0, 0)
    end
    for i, v in pairs(app.prop or {}) do
      if v.d and v.d >= 0 then SetPedPropIndex(ped, tonumber(i), v.d, v.t or 0, true)
      else ClearPedProp(ped, tonumber(i)) end
    end
  else
    pcall(function() exports['fivem-appearance']:setPlayerAppearance(app) end)
  end
end

local function loadAndApplyAppearance(citizenid, onDone)
  if not citizenid then
    if onDone then onDone(false) end
    return
  end

  local cached = appearanceCache[citizenid]
  if cached ~= nil then
    if cached then applySavedAppearance(cached) end
    if onDone then onDone(cached and true or false) end
    return
  end

  lib.callback('exec_multichar:getAppearance', false, function(jsonApp)
    if jsonApp then
      appearanceCache[citizenid] = jsonApp
      applySavedAppearance(jsonApp)
      if onDone then onDone(true) end
    else
      appearanceCache[citizenid] = false
      if onDone then onDone(false) end
    end
  end, citizenid)
end

-- ===== Selector/default ped helpers =====
local function setRandomDefaultPed()
  if not pedcfg or not pedcfg.defaults or #pedcfg.defaults == 0 then return end
  local name = pedcfg.defaults[math.random(1, #pedcfg.defaults)]
  local model = joaat(name)
  if not IsModelInCdimage(model) or not IsModelValid(model) then return end
  RequestModel(model); while not HasModelLoaded(model) do Wait(0) end
  SetPlayerModel(PlayerId(), model)
  SetPedDefaultComponentVariation(PlayerPedId())
  SetModelAsNoLongerNeeded(model)
end

local function setSelectorFallbackPed()
  setRandomDefaultPed()
  playAnim(animIndex)
end

-- ===== Selection helpers =====
local function trim(str)
  return (str and str:match('^%s*(.-)%s*$')) or ''
end

local function buildFullName(first, last)
  local a = trim(first or '')
  local b = trim(last or '')
  if a ~= '' and b ~= '' then return a .. ' ' .. b end
  if a ~= '' then return a end
  if b ~= '' then return b end
  return 'Unknown'
end

local function getCharacterById(id)
  if not id then return nil end
  for _, char in ipairs(charactersList) do
    if char.citizenid == id then return char end
  end
end

previewCharacter = function(citizenid)
  if not citizenid or not inStudio then return end
  local char = getCharacterById(citizenid)
  if not char then return end
  selectionId = citizenid
  ensurePlayerModel({ _execModel = char.model })
  local cached = appearanceCache[citizenid]
  if cached ~= nil then
    pendingPreview = nil
    if cached then applySavedAppearance(cached) end
    playAnim(animIndex)
    setUiBusyState(false)
    return
  end
  pendingPreview = citizenid
  setUiBusyState(true, 'Loading appearance...')
  lib.callback('exec_multichar:getAppearance', false, function(jsonApp)
    if pendingPreview ~= citizenid then
      return
    end
    pendingPreview = nil
    if jsonApp then
      appearanceCache[citizenid] = jsonApp
      applySavedAppearance(jsonApp)
    else
      appearanceCache[citizenid] = false
      setSelectorFallbackPed()
    end
    playAnim(animIndex)
    setUiBusyState(false)
  end, citizenid)
end

local function setCharacters(chars, preview)
  charactersList = {}
  local exists = {}
  for _, row in ipairs(chars or {}) do
    if row.citizenid then
      local entry = {
        citizenid = row.citizenid,
        firstname = row.firstname or '',
        lastname = row.lastname or '',
        name = row.name or buildFullName(row.firstname, row.lastname),
        gender = row.gender or '',
        dob = row.dob or '',
        model = row.model
      }
      charactersList[#charactersList+1] = entry
      exists[entry.citizenid] = true
    end
  end
  for id in pairs(appearanceCache) do
    if not exists[id] then
      appearanceCache[id] = nil
    end
  end
  if selectionId and not exists[selectionId] then
    selectionId = nil
  end
  if not selectionId and charactersList[1] then
    selectionId = charactersList[1].citizenid
  end
  local previewId = nil
  if preview and selectionId then
    previewId = selectionId
  end
  if uiOpen then
    sendUi('updateCharacters', {
      characters = charactersList,
      selected = selectionId,
      preview = preview and true or false
    })
    setUiStatus(DEFAULT_STATUS)
  end
  if previewId then
    previewCharacter(previewId)
  elseif preview and #charactersList == 0 then
    setSelectorFallbackPed()
  end
end

local function refreshCharacters(preview, status)
  if status then setUiStatus(status) end
  if uiOpen then setUiLoading(true) end
  lib.callback('exec_multichar:list', false, function(chars)
    if uiOpen then setUiLoading(false) end
    setCharacters(chars or {}, preview)
  end)
end

local function leaveStudio()
  inStudio = false
  FreezeEntityPosition(PlayerPedId(), false)
  SetEntityInvincible(PlayerPedId(), false)
  destroyCam()
  ClearPedTasks(PlayerPedId())
  DisplayRadar(true)
end

local function completeSelection()
  selected = true
  TriggerEvent('exec_multichar:uiState', false)
  leaveStudio()
  closeUi(true)
  disableSpawnmanagerAutoSpawn()
end

local function showSelector()
  if creating then return end
  TriggerEvent('exec_multichar:uiState', true)
  TriggerServerEvent('exec_multichar:enterSelectorBucket')
  TriggerServerEvent('exec_multichar:clearActiveCharacter')
  inStudio = true
  reallyDisableAutoSpawn()
  animIndex = 1
  if not selectionId then
    setSelectorFallbackPed()
  end
  setStudio()
  openUi(DEFAULT_STATUS)
  refreshCharacters(true, 'Loading characters...')
end

-- ===== NUI callbacks =====
RegisterNUICallback('cameraZoom', function(data, cb)
  cb({ ok = true })
  if not inStudio then return end
  local dir = data and data.direction
  local amount = tonumber(data and data.amount) or 1.0
  amount = math.max(0.2, math.min(amount, 5.0))
  if dir == 'in' then
    camZoom = math.max(ZOOM_MIN, camZoom - ZOOM_STEP * amount)
  elseif dir == 'out' then
    camZoom = math.min(ZOOM_MAX, camZoom + ZOOM_STEP * amount)
  end
end)

RegisterNUICallback('cameraPan', function(data, cb)
  cb({ ok = true })
  if not inStudio then return end
  local dir = data and data.direction
  local amount = tonumber(data and data.amount) or 1.0
  amount = math.max(0.2, math.min(amount, 5.0))
  if dir == 'left' then
    camPanX = math.max(PAN_MIN, camPanX - PAN_STEP * amount)
  elseif dir == 'right' then
    camPanX = math.min(PAN_MAX, camPanX + PAN_STEP * amount)
  end
end)

RegisterNUICallback('cameraCycle', function(data, cb)
  cb({ ok = true })
  if not inStudio then return end
  local dir = data and data.direction
  if dir == 'prev' then
    cycleCam(-1)
  elseif dir == 'next' then
    cycleCam(1)
  end
end)

RegisterNUICallback('cameraPose', function(data, cb)
  cb({ ok = true })
  if not inStudio then return end
  local delta = tonumber(data and data.delta) or 1
  if delta >= 0 then
    cycleAnim(1)
  else
    cycleAnim(-1)
  end
end)

RegisterNUICallback('setSelection', function(data, cb)
  cb({ ok = true })
  local citizenid = data and data.citizenid or nil
  if not citizenid or citizenid == selectionId then return end
  previewCharacter(citizenid)
end)

RegisterNUICallback('createCharacter', function(data, cb)
  cb({ ok = true })
  if creating then return end
  local firstname = trim(data and data.firstname or '')
  local lastname = trim(data and data.lastname or '')
  local gender = ((data and data.gender) == 'female') and 'female' or 'male'
  local dob = trim(data and data.dob or '2000-01-01')
  if firstname == '' or lastname == '' then
    sendToast('Please enter a first and last name.')
    return
  end
  creating = true
  setUiBusyState(true, 'Creating character...')
  lib.callback('exec_multichar:create', false, function(res)
    if not res or not res.ok then
      creating = false
      setUiBusyState(false)
      sendToast(res and res.error or 'Unable to create character.')
      refreshCharacters(false)
      return
    end
    selectionId = res.citizenid
    appearanceCache[selectionId] = nil
    setUiBusyState(false)
    closeUi(false)
    local function finishCreate(app)
      if not app then
        exports['fivem-appearance']:startPlayerCustomization(function(app2) finishCreate(app2) end, appcfg.creatorOptions or {})
        return
      end
      pcall(function() exports['fivem-appearance']:setPlayerAppearance(app) end)
      local savedAppearance = captureCurrentAppearance(app)
      TriggerServerEvent('exec_multichar:saveAppearance', res.citizenid, savedAppearance)
      appearanceCache[res.citizenid] = json.encode(savedAppearance)
      lib.callback('exec_multichar:select', false, function(sel)
        creating = false
        if sel and sel.ok then
          completeSelection()
        else
          sendToast(sel and sel.error or 'Unable to load character.')
          openUi(DEFAULT_STATUS)
          refreshCharacters(true)
        end
      end, res.citizenid)
    end
    exports['fivem-appearance']:startPlayerCustomization(function(app) finishCreate(app) end, appcfg.creatorOptions or {})
  end, {
    firstname = firstname,
    lastname = lastname,
    gender = gender,
    dob = dob
  })
end)

RegisterNUICallback('deleteCharacter', function(data, cb)
  cb({ ok = true })
  if creating then return end
  local citizenid = data and data.citizenid or selectionId
  if not citizenid then
    sendToast('Select a character first.')
    return
  end
  setUiBusyState(true, 'Deleting character...')
  lib.callback('exec_multichar:delete', false, function(res)
    setUiBusyState(false)
    if not res or not res.ok then
      sendToast(res and res.error or 'Delete failed.')
      return
    end
    if selectionId == citizenid then
      selectionId = nil
    end
    appearanceCache[citizenid] = nil
    sendToast('Character deleted.')
    refreshCharacters(true, DEFAULT_STATUS)
  end, citizenid)
end)

RegisterNUICallback('playCharacter', function(data, cb)
  cb({ ok = true })
  if creating then return end
  local citizenid = data and data.citizenid or selectionId
  if not citizenid then
    sendToast('Select a character first.')
    return
  end
  setUiBusyState(true, 'Loading character...')
  lib.callback('exec_multichar:select', false, function(res)
    setUiBusyState(false)
    if not res or not res.ok then
      sendToast(res and res.error or 'Unable to load character.')
      return
    end
    selectionId = citizenid
    completeSelection()
  end, citizenid)
end)

RegisterNUICallback('requestClose', function(_, cb)
  cb({ ok = false })
  sendToast('Select or create a character to continue.')
end)

-- ===== Events / Commands =====
RegisterNetEvent('exec_multichar:openMenu', function()
  if selected or creating then return end
  showSelector()
end)

RegisterNetEvent('exec_multichar:selected', function(char)
  currentCitizenId = char.citizenid
end)

RegisterNetEvent('exec_multichar:readyForPvp', function(charData)
  local citizenid = charData and charData.citizenid or currentCitizenId
  loadAndApplyAppearance(citizenid, function()
    if type(GetResourceState) == 'function' and GetResourceState('exec_framework') == 'started' then
      TriggerServerEvent('exec:ready', charData or {})
    else
      TriggerServerEvent('exec_multichar:leaveSelectorBucket')
    end
  end)
end)

local function completeLogout(lastCitizen)
  selected = false
  creating = false
  currentCitizenId = nil
  selectionId = lastCitizen
  appearanceCache = {}
  ClearPedTasks(PlayerPedId())
  showSelector()
end

RegisterCommand('logout', function()
  local lastCitizen = currentCitizenId
  if type(GetResourceState) == 'function' and GetResourceState('exec_framework') == 'started' then
    lib.callback('exec:logoutForMultichar', false, function()
      completeLogout(lastCitizen)
    end)
    return
  end
  completeLogout(lastCitizen)
end, false)

-- Studio controls: Q/E cameras, Z/X animations, MouseWheel zoom, A/D pan
CreateThread(function()
  while true do
    if inStudio and cam and DoesCamExist(cam) then
      buildCamera(false)
      Wait(0)
    else
      Wait(200)
    end
  end
end)

CreateThread(function()
  while true do
    Wait(0)
    if inStudio then
      -- camera cycle
      if IsControlJustPressed(0, 44) then -- Q
        cycleCam(-1)
      elseif IsControlJustPressed(0, 38) then -- E
        cycleCam(1)
      end
      -- animation cycle
      if IsControlJustPressed(0, 20) or IsControlJustPressed(0, 174) then -- Z or Left
        cycleAnim(-1)
      elseif IsControlJustPressed(0, 73) or IsControlJustPressed(0, 175) then -- X or Right
        cycleAnim(1)
      end
      -- zoom (mouse wheel)
      if IsControlJustPressed(0, 241) then -- wheel up
        camZoom = math.max(ZOOM_MIN, camZoom - ZOOM_STEP)
      elseif IsControlJustPressed(0, 242) then -- wheel down
        camZoom = math.min(ZOOM_MAX, camZoom + ZOOM_STEP)
      end
      -- pan left/right
      if IsControlPressed(0, 34) then -- A
        camPanX = math.max(PAN_MIN, camPanX - PAN_STEP * GetFrameTime() * 60.0)
      elseif IsControlPressed(0, 35) then -- D
        camPanX = math.min(PAN_MAX, camPanX + PAN_STEP * GetFrameTime() * 60.0)
      end
    else
      Wait(600)
    end
  end
end)

CreateThread(function()
  Wait(1200)
  if not selected then
    TriggerEvent('exec_multichar:openMenu')
  end
end)

CreateThread(function()
  while true do
    if uiOpen then
      DisableControlAction(0, 245, true) -- INPUT_MP_TEXT_CHAT_ALL
      DisableControlAction(0, 199, true) -- INPUT_FRONTEND_PAUSE
      DisableControlAction(0, 200, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE
      DisableControlAction(0, 322, true) -- ESC
      Wait(0)
    else
      Wait(400)
    end
  end
end)
