local ac = require('ac')
local ui = require('ui')
local okUtf8, utf8lib = pcall(require, 'utf8')
local utf8 = (okUtf8 and utf8lib) or utf8
if not (utf8 and utf8.char) then
  utf8 = {
    char = function(code)
      if code < 0x80 then
        return string.char(code)
      end
      return '?'
    end
  }
end
local vec2 = vec2
local vec3 = vec3
local rgbm = rgbm
if not rgbm then
  rgbm = function(r, g, b, a)
    return { r = r, g = g, b = b, a = a or 1.0 }
  end
end
if not vec2 then
  vec2 = function(x, y)
    return { x = x, y = y }
  end
end
if not vec3 then
  vec3 = function(x, y, z)
    return { x = x or 0.0, y = y or 0.0, z = z or 0.0 }
  end
end

local function sliderFloatAdaptive(label, value, minValue, maxValue, format)
  local a, b = ui.sliderFloat(label, value, minValue, maxValue, format)
  if type(a) == 'boolean' and type(b) == 'number' then
    return a, b
  elseif type(a) == 'number' and b == nil then
    local newValue = a
    if math.abs(newValue - value) > 1e-6 then
      return true, newValue
    end
    return false, value
  elseif type(a) == 'table' and type(b) == 'boolean' and type(a[1]) == 'number' then
    local newValue = a[1]
    local changed = b
    if math.abs(newValue - value) > 1e-6 then
      changed = true
    end
    return changed, newValue
  end
  return false, value
end

local function beginDisabled(disabled)
  if ui.beginDisabled then
    ui.beginDisabled(disabled)
    return true
  end
  if disabled then
    local style = ui.getStyle and ui.getStyle()
    if style and ui.pushStyleVar and ui.StyleVar and ui.StyleVar.Alpha then
      ui.pushStyleVar(ui.StyleVar.Alpha, style.Alpha * 0.4)
      return true
    end
  end
  return false
end

local function endDisabled(active, disabled)
  if not active then
    return
  end
  if ui.endDisabled then
    ui.endDisabled()
  elseif disabled and ui.popStyleVar then
    ui.popStyleVar()
  end
end

local scriptInfo = debug.getinfo(1, 'S')
local scriptSource = scriptInfo and scriptInfo.source or ''
local scriptDir = scriptSource:match('^@(.+[\\/])[^\\/]*$') or ''
local configPath = scriptDir ~= '' and (scriptDir .. 'config_presets.json') or 'config_presets.json'

local MM_TO_M = 0.001
local REQUIRED_PATCH = 1080 -- CSP 0.1.80

local wheelDefs = {
  { index = 0, key = 'frontLeft', label = 'Front Left', side = -1 },
  { index = 1, key = 'frontRight', label = 'Front Right', side = 1 },
  { index = 2, key = 'rearLeft', label = 'Rear Left', side = -1 },
  { index = 3, key = 'rearRight', label = 'Rear Right', side = 1 }
}

local function newWheelState()
  return {
    offset = 0.0,
    track = 0.0,
    camber = 0.0,
    height = 0.0
  }
end

local function deepCopyWheelState(source)
  local result = {}
  for _, def in ipairs(wheelDefs) do
    local src = source[def.key]
    result[def.key] = {
      offset = src and src.offset or 0.0,
      track = src and src.track or 0.0,
      camber = src and src.camber or 0.0,
      height = src and src.height or 0.0
    }
  end
  return result
end

local function encodeJSONString(value)
  local replacements = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
  return '"' .. value:gsub('[\\\"\b\f\n\r\t]', replacements) .. '"'
end

local function jsonEncode(value)
  local t = type(value)
  if t == 'nil' then
    return 'null'
  elseif t == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then
      return 'null'
    end
    return string.format('%.12g', value)
  elseif t == 'boolean' then
    return value and 'true' or 'false'
  elseif t == 'string' then
    return encodeJSONString(value)
  elseif t == 'table' then
    local isArray = true
    local arrayItems = {}
    local count = 0
    for k, v in pairs(value) do
      if type(k) ~= 'number' then
        isArray = false
        break
      end
      arrayItems[k] = v
      if k > count then
        count = k
      end
    end
    if isArray then
      local buffer = {}
      for i = 1, count do
        buffer[i] = jsonEncode(arrayItems[i])
      end
      return '[' .. table.concat(buffer, ',') .. ']'
    else
      local buffer = {}
      for k, v in pairs(value) do
        buffer[#buffer + 1] = encodeJSONString(tostring(k)) .. ':' .. jsonEncode(v)
      end
      table.sort(buffer)
      return '{' .. table.concat(buffer, ',') .. '}'
    end
  end
  error('Unsupported value type for JSON encoding: ' .. t)
end

local function jsonDecode(str)
  local position = 1
  local length = #str

  local function skipWhitespace()
    while position <= length do
      local c = str:sub(position, position)
      if c ~= ' ' and c ~= '\t' and c ~= '\n' and c ~= '\r' then
        break
      end
      position = position + 1
    end
  end

  local function parseLiteral(literal, value)
    if str:sub(position, position + #literal - 1) == literal then
      position = position + #literal
      return value
    end
    error('Invalid literal near position ' .. position .. ': expected ' .. literal)
  end

  local function parseString()
    position = position + 1
    local buffer = {}
    while position <= length do
      local c = str:sub(position, position)
      if c == '"' then
        position = position + 1
        return table.concat(buffer)
      elseif c == '\\' then
        position = position + 1
        local esc = str:sub(position, position)
        position = position + 1
        if esc == '"' or esc == '\\' or esc == '/' then
          buffer[#buffer + 1] = esc
        elseif esc == 'b' then
          buffer[#buffer + 1] = '\b'
        elseif esc == 'f' then
          buffer[#buffer + 1] = '\f'
        elseif esc == 'n' then
          buffer[#buffer + 1] = '\n'
        elseif esc == 'r' then
          buffer[#buffer + 1] = '\r'
        elseif esc == 't' then
          buffer[#buffer + 1] = '\t'
        elseif esc == 'u' then
          local hex = str:sub(position, position + 3)
          if not hex:match('^[0-9a-fA-F]+$') then
            error('Invalid unicode escape near position ' .. position)
          end
          local code = tonumber(hex, 16)
          buffer[#buffer + 1] = utf8.char(code)
          position = position + 4
        else
          error('Invalid escape sequence near position ' .. position)
        end
      else
        buffer[#buffer + 1] = c
        position = position + 1
      end
    end
    error('Unterminated string at position ' .. position)
  end

  local function parseNumber()
    local startPos = position
    local char = str:sub(position, position)
    if char == '-' then
      position = position + 1
    end
    while position <= length and str:sub(position, position):match('%d') do
      position = position + 1
    end
    if position <= length and str:sub(position, position) == '.' then
      position = position + 1
      while position <= length and str:sub(position, position):match('%d') do
        position = position + 1
      end
    end
    if position <= length then
      local e = str:sub(position, position)
      if e == 'e' or e == 'E' then
        position = position + 1
        local sign = str:sub(position, position)
        if sign == '+' or sign == '-' then
          position = position + 1
        end
        while position <= length and str:sub(position, position):match('%d') do
          position = position + 1
        end
      end
    end
    local numberString = str:sub(startPos, position - 1)
    local numberValue = tonumber(numberString)
    if not numberValue then
      error('Invalid number near position ' .. startPos)
    end
    return numberValue
  end

  local parseValue

  local function parseArray()
    position = position + 1
    skipWhitespace()
    local result = {}
    if str:sub(position, position) == ']' then
      position = position + 1
      return result
    end
    while true do
      result[#result + 1] = parseValue()
      skipWhitespace()
      local c = str:sub(position, position)
      if c == ']' then
        position = position + 1
        break
      elseif c == ',' then
        position = position + 1
        skipWhitespace()
      else
        error('Expected , or ] near position ' .. position)
      end
    end
    return result
  end

  local function parseObject()
    position = position + 1
    skipWhitespace()
    local result = {}
    if str:sub(position, position) == '}' then
      position = position + 1
      return result
    end
    while true do
      if str:sub(position, position) ~= '"' then
        error('Expected string key near position ' .. position)
      end
      local key = parseString()
      skipWhitespace()
      if str:sub(position, position) ~= ':' then
        error('Expected : near position ' .. position)
      end
      position = position + 1
      skipWhitespace()
      result[key] = parseValue()
      skipWhitespace()
      local c = str:sub(position, position)
      if c == '}' then
        position = position + 1
        break
      elseif c == ',' then
        position = position + 1
        skipWhitespace()
      else
        error('Expected , or } near position ' .. position)
      end
    end
    return result
  end

  function parseValue()
    skipWhitespace()
    local c = str:sub(position, position)
    if c == '"' then
      return parseString()
    elseif c == '{' then
      return parseObject()
    elseif c == '[' then
      return parseArray()
    elseif c == 't' then
      return parseLiteral('true', true)
    elseif c == 'f' then
      return parseLiteral('false', false)
    elseif c == 'n' then
      return parseLiteral('null', nil)
    elseif c == '-' or c:match('%d') then
      return parseNumber()
    end
    error('Unexpected character near position ' .. position .. ': ' .. tostring(c))
  end

  local result = parseValue()
  skipWhitespace()
  if position <= length then
    error('Unexpected trailing characters near position ' .. position)
  end
  return result
end

local function readConfigFile()
  local file = io.open(configPath, 'r')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  if not content or content == '' then
    return nil
  end
  local ok, result = pcall(jsonDecode, content)
  if not ok then
    ac.warn('RealTimeStancer: failed to parse presets: ' .. tostring(result))
    return nil
  end
  return result
end

local function writeConfigFile(data)
  local ok, encoded = pcall(jsonEncode, data)
  if not ok then
    ac.error('RealTimeStancer: failed to encode presets: ' .. tostring(encoded))
    return
  end
  local file, err = io.open(configPath, 'w')
  if not file then
    ac.error('RealTimeStancer: unable to write presets: ' .. tostring(err))
    return
  end
  file:write(encoded)
  file:close()
end

local state = {
  car = nil,
  wheels = {},
  presets = {},
  selectedPreset = 'Live',
  newPresetName = '',
  baseWheelData = {},
  features = {
    offsetSetter = nil,
    offsetGetter = nil,
    camberSetter = nil,
    camberGetter = nil
  },
  compatibilityMessages = {},
  presetDirty = false
}

for _, def in ipairs(wheelDefs) do
  state.wheels[def.key] = newWheelState()
end

local function appendCompatibilityMessage(message)
  for _, existing in ipairs(state.compatibilityMessages) do
    if existing == message then
      return
    end
  end
  state.compatibilityMessages[#state.compatibilityMessages + 1] = message
end

local function findFirstMethod(car, candidates)
  for _, name in ipairs(candidates) do
    if type(car[name]) == 'function' then
      return name
    end
  end
  return nil
end

local function callCarMethod(car, methodName, index, value)
  local method = methodName and car[methodName]
  if type(method) ~= 'function' then
    return nil
  end
  if value ~= nil then
    local ok, result = pcall(method, car, index, value)
    if ok then
      return result
    end
    ac.warn('RealTimeStancer: call to ' .. methodName .. ' failed: ' .. tostring(result))
    return nil
  end
  local ok, result = pcall(method, car, index)
  if ok then
    return result
  end
  ac.warn('RealTimeStancer: call to ' .. methodName .. ' failed: ' .. tostring(result))
  return nil
end

local function ensureWheelBase(car)
  state.baseWheelData = {}
  state.features.offsetGetter = findFirstMethod(car, {
    'getVisualWheelOffset',
    'getWheelBaseOffset',
    'getWheelOffset',
    'getRealWheelOffset'
  })
  state.features.offsetSetter = findFirstMethod(car, {
    'setVisualWheelOffset',
    'setWheelBaseOffset',
    'setWheelOffset',
    'setRealWheelOffset'
  })
  state.features.camberGetter = findFirstMethod(car, {
    'getVisualWheelCamber',
    'getWheelCamber',
    'getRealWheelCamber'
  })
  state.features.camberSetter = findFirstMethod(car, {
    'setVisualWheelCamber',
    'setWheelCamber',
    'setRealWheelCamber'
  })

  if not state.features.offsetSetter then
    appendCompatibilityMessage('Wheel offsets are not supported on this car or CSP build.')
  end
  if not state.features.camberSetter then
    appendCompatibilityMessage('Wheel camber adjustments are unavailable.')
  end

  for _, def in ipairs(wheelDefs) do
    local baseOffset = vec3()
    if state.features.offsetGetter then
      local result = callCarMethod(car, state.features.offsetGetter, def.index)
      if result then
        baseOffset = vec3(result.x, result.y, result.z)
      end
    end
    local baseCamber = 0.0
    if state.features.camberGetter then
      local result = callCarMethod(car, state.features.camberGetter, def.index)
      if result then
        baseCamber = result
      end
    end
    state.baseWheelData[def.key] = {
      offset = baseOffset,
      camber = baseCamber
    }
  end
end

local function loadPresets()
  local loaded = readConfigFile()
  if type(loaded) ~= 'table' then
    loaded = {}
  end
  if type(loaded.presets) ~= 'table' then
    loaded.presets = {}
  end
  state.presets = loaded.presets
  if type(loaded.lastPreset) == 'string' and state.presets[loaded.lastPreset] then
    state.selectedPreset = loaded.lastPreset
  else
    state.selectedPreset = 'Live'
  end
  if next(state.presets) == nil then
    state.presets['Stock'] = { wheels = deepCopyWheelState(state.wheels) }
  end
  if state.selectedPreset ~= 'Live' then
    local preset = state.presets[state.selectedPreset]
    if preset and type(preset.wheels) == 'table' then
      local copy = deepCopyWheelState(preset.wheels)
      for _, def in ipairs(wheelDefs) do
        state.wheels[def.key] = copy[def.key]
      end
    end
  end
end

local function persistPresets()
  local data = {
    presets = state.presets,
    lastPreset = state.selectedPreset ~= 'Live' and state.selectedPreset or nil
  }
  writeConfigFile(data)
end

local function markPresetDirty()
  state.presetDirty = true
  if state.selectedPreset ~= 'Live' then
    state.selectedPreset = 'Live'
  end
end

local function resetWheel(key)
  state.wheels[key] = newWheelState()
  markPresetDirty()
end

local function resetAllWheels()
  for _, def in ipairs(wheelDefs) do
    state.wheels[def.key] = newWheelState()
  end
  markPresetDirty()
end

local function applyPreset(name)
  local preset = state.presets[name]
  if not preset or type(preset.wheels) ~= 'table' then
    return
  end
  local copy = deepCopyWheelState(preset.wheels)
  for _, def in ipairs(wheelDefs) do
    state.wheels[def.key] = copy[def.key]
  end
  state.selectedPreset = name
  state.presetDirty = false
end

local function savePresetAs(name)
  if not name or name == '' then
    return
  end
  state.presets[name] = { wheels = deepCopyWheelState(state.wheels) }
  state.selectedPreset = name
  state.presetDirty = false
  persistPresets()
end

local function deletePreset(name)
  if not state.presets[name] then
    return
  end
  state.presets[name] = nil
  state.selectedPreset = 'Live'
  state.presetDirty = false
  persistPresets()
end

local function sortedPresetNames()
  local names = {}
  for name in pairs(state.presets) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function applyWheelAdjustments(car)
  if not car then
    return
  end
  for _, def in ipairs(wheelDefs) do
    local wheelState = state.wheels[def.key]
    local base = state.baseWheelData[def.key]
    if base then
      if state.features.offsetSetter then
        local trackAdjustment = wheelState.track * def.side * MM_TO_M
        local heightAdjustment = wheelState.height * MM_TO_M
        local forwardAdjustment = wheelState.offset * MM_TO_M
        local newOffset = vec3(
          base.offset.x + trackAdjustment,
          base.offset.y + heightAdjustment,
          base.offset.z + forwardAdjustment
        )
        callCarMethod(car, state.features.offsetSetter, def.index, newOffset)
      end
      if state.features.camberSetter then
        local newCamber = base.camber + wheelState.camber
        callCarMethod(car, state.features.camberSetter, def.index, newCamber)
      end
    end
  end
end

local function ensureCar()
  local car = ac.getCar(0)
  if car ~= state.car then
    state.car = car
    state.compatibilityMessages = {}
    if car then
      ensureWheelBase(car)
    end
  end
  return car
end

local function checkPatchCompatibility()
  if not ac.getPatchVersionCode then
    appendCompatibilityMessage('Unable to verify CSP version. Update Custom Shaders Patch to 0.1.80 or newer.')
    return false
  end
  local versionCode = ac.getPatchVersionCode()
  if versionCode < REQUIRED_PATCH then
    appendCompatibilityMessage('Custom Shaders Patch 0.1.80 or newer is required.')
    return false
  end
  if ac.getPatchFeatureState then
    local stateLua = ac.getPatchFeatureState('lua')
    if stateLua and ac.PatchFeatureState then
      if stateLua ~= ac.PatchFeatureState.Available and stateLua ~= ac.PatchFeatureState.Enabled then
        appendCompatibilityMessage('CSP Lua scripting feature must be enabled.')
        return false
      end
    elseif stateLua == false then
      appendCompatibilityMessage('CSP Lua scripting feature must be enabled.')
      return false
    end
  end
  return true
end

local patchCompatible = checkPatchCompatibility()

loadPresets()

function ac.onReload()
  loadPresets()
end

function ac.onSimStart(isRace)
  state.car = nil
end

function ac.onStep(dt)
  if not patchCompatible then
    return
  end
  local car = ensureCar()
  if car then
    applyWheelAdjustments(car)
  end
end

function ac.onCarLoaded(carIndex)
  if carIndex == 0 then
    state.car = nil
  end
end

function ac.onCarReset(carIndex)
  if carIndex == 0 then
    state.car = nil
  end
end

local function drawPresetSection()
  ui.separator()
  ui.text('Presets')
  local activeLabel = state.selectedPreset or 'Live'
  if state.selectedPreset == 'Live' then
    activeLabel = 'Live (unsaved)'
  end
  if ui.beginCombo('Active Preset', activeLabel) then
    for _, name in ipairs(sortedPresetNames()) do
      local selected = state.selectedPreset == name
      if ui.selectable(name, selected) then
        applyPreset(name)
      end
    end
    if ui.selectable('Live', state.selectedPreset == 'Live') then
      state.selectedPreset = 'Live'
    end
    ui.endCombo()
  end
  local changed, value = ui.inputText('New preset name', state.newPresetName or '', 64)
  if changed then
    state.newPresetName = value
  end
  if ui.button('Save preset', vec2(-1, 0)) then
    local trimmed = state.newPresetName and state.newPresetName:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed and trimmed ~= '' then
      savePresetAs(trimmed)
      state.newPresetName = ''
    end
  end
  if state.selectedPreset ~= 'Live' then
    if ui.button('Delete preset', vec2(-1, 0)) then
      deletePreset(state.selectedPreset)
    end
  end
end

local function drawWheelControls(def)
  ui.separator()
  ui.text(def.label)
  ui.sameLine()
  if ui.button('Reset##' .. def.key) then
    resetWheel(def.key)
  end
  ui.pushItemWidth(-1)
  local offsetDisabled = not state.features.offsetSetter
  local disabledScope = beginDisabled(offsetDisabled)
  local wheelState = state.wheels[def.key]
  local changed, newOffset = sliderFloatAdaptive('Wheel offset (mm)##' .. def.key, wheelState.offset, -60.0, 60.0, '%.1f')
  if changed then
    wheelState.offset = newOffset
    markPresetDirty()
  end
  local changedTrack, newTrack = sliderFloatAdaptive('Track width (mm)##' .. def.key, wheelState.track, -60.0, 60.0, '%.1f')
  if changedTrack then
    wheelState.track = newTrack
    markPresetDirty()
  end
  local changedHeight, newHeight = sliderFloatAdaptive('Ride height (mm)##' .. def.key, wheelState.height, -80.0, 80.0, '%.1f')
  if changedHeight then
    wheelState.height = newHeight
    markPresetDirty()
  end
  endDisabled(disabledScope, offsetDisabled)
  local camberDisabled = not state.features.camberSetter
  local camberScope = beginDisabled(camberDisabled)
  local changedCamber, newCamber = sliderFloatAdaptive('Camber (°)##' .. def.key, wheelState.camber, -10.0, 10.0, '%.2f')
  if changedCamber then
    wheelState.camber = newCamber
    markPresetDirty()
  end
  endDisabled(camberScope, camberDisabled)
  ui.popItemWidth()
end

local function drawGlobalControls()
  if ui.button('Reset all wheels', vec2(-1, 0)) then
    resetAllWheels()
  end
end

function ac.onUI()
  ui.window('Real Time Stancer', vec2(380, 620), function()
    if not patchCompatible then
      ui.textWrapped('Custom Shaders Patch 0.1.80+ with Lua scripting is required.')
      for _, message in ipairs(state.compatibilityMessages) do
        ui.textWrapped(message)
      end
      return
    end
    if #state.compatibilityMessages > 0 then
      ui.pushStyleColor(ui.StyleColor.Text, rgbm(1.0, 0.6, 0.0, 1.0))
      for _, message in ipairs(state.compatibilityMessages) do
        ui.textWrapped(message)
      end
      ui.popStyleColor()
      ui.separator()
    end
    drawPresetSection()
    drawGlobalControls()
    for _, def in ipairs(wheelDefs) do
      drawWheelControls(def)
    end
  end)
end
