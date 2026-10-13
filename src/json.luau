--!strict
--!native
-- Deterministic JSON output for generated AsHyAmS data. Jess deliberately ships a decoder only;
-- this writer keeps site output in Luau and preserves the one distinction ordinary Luau tables
-- cannot express by themselves: an empty object versus an empty array.
local bytes = require '@dream/bytes'
local jessJson = require '@jess/json'

local json = {}

local Null = jessJson.null

-- What `json.array` and `json.object` mark a table with. The field is what a reader of the
-- metatable sees; the encoder tells them apart by identity.
local ArrayMark = { __ashyams_json = 'array' }
local ObjectMark = { __ashyams_json = 'object' }

-- The key order an object was given, held weakly so the object's life is its own.
local Orders: { [unknown]: { string } } = {}
setmetatable(Orders, { __mode = 'k' })

--- Marks `value` (a new table without one) as a JSON array, empty or not.
function json.array<Value>(value: { Value }?): { Value }
  local array = value or {}
  setmetatable(array, ArrayMark)

  return array
end

--- Marks `value` (a new table without one) as a JSON object, whose keys are written in `order`
--- first and the rest sorted after them.
function json.object(value: { [string]: unknown }?, order: { string }?): { [string]: unknown }
  local object = value or {}
  setmetatable(object, ObjectMark)
  if order then Orders[object] = order end

  return object
end

--- A marked array holding `value`'s elements up to its first gap.
function json.arrayCopy<Value>(value: { Value }?): { Value }
  local out = json.array()
  for index, item in ipairs(value or {}) do
    out[index] = item
  end

  return out
end

--- A marked object holding every key of `value`.
function json.objectCopy(value: { [string]: unknown }?): { [string]: unknown }
  local out = json.object()
  for key, item in pairs(value or {}) do
    out[key] = item
  end

  return out
end

local Escapes: { [number]: string } = table.freeze {
  [8] = '\\b',
  [9] = '\\t',
  [10] = '\\n',
  [12] = '\\f',
  [13] = '\\r',
  [34] = '\\"',
  [92] = '\\\\',
}

-- The bytes a JSON string cannot hold as they are: the controls, the quote and the backslash.
local Escaped = bytes.regex('[\\x00-\\x1f"\\\\]', { unicode = false })

local function quote(text: string): string
  -- `find` counts from zero: the offset it answers with is one less than the byte's index, and
  -- that index is the offset to search on from.
  local found = Escaped:find(text, 0)
  if not found then return `"{text}"` end

  local out = { '"' }
  local start = 1

  while found do
    local index = found + 1
    local byte = string.byte(text, index)
    if index > start then table.insert(out, string.sub(text, start, index - 1)) end

    table.insert(out, Escapes[byte] or string.format('\\u%04x', byte))
    start = index + 1
    found = Escaped:find(text, index)
  end

  if start <= #text then table.insert(out, string.sub(text, start)) end

  table.insert(out, '"')
  return table.concat(out)
end

--- Whether a table is written as an array: one marked so, or an unmarked one whose keys are
--- exactly `1..n` for some `n` above zero.
local function isArray(value: { [unknown]: unknown }): boolean
  local mark = getmetatable(value)
  if mark == ArrayMark then return true end
  if mark == ObjectMark then return false end

  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end

    count += 1
    if key > maximum then maximum = key end
  end

  if count == 0 then return false end

  return maximum == count
end

local function numberText(value: number): string
  if value ~= value or value == math.huge or value == -math.huge then
    error('JSON cannot encode a non-finite number', 0)
  end

  if value == 0 then return '0' end

  return tostring(value)
end

--- An object's keys in the order they are written: the order it was given, for the keys it
--- has, then every other key sorted.
local function objectKeys(value: { [unknown]: unknown }): { string }
  local ordered = Orders[value]
  if not ordered then
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= 'string' then error('JSON object keys must be strings', 0) end

      table.insert(keys, key)
    end

    table.sort(keys)
    return keys
  end

  local keys = {}
  local seen: { [string]: boolean } = {}

  for _, key in ipairs(ordered) do
    if value[key] ~= nil then
      table.insert(keys, key)
      seen[key] = true
    end
  end

  local rest = {}
  for key in pairs(value) do
    if type(key) ~= 'string' then error('JSON object keys must be strings', 0) end

    if not seen[key] then table.insert(rest, key) end
  end

  table.sort(rest)
  for _, key in ipairs(rest) do
    table.insert(keys, key)
  end

  return keys
end

--- What a value that is not a table is written as, or nil for a table. Raises on a value JSON
--- has no spelling for.
local function scalar(value: unknown): string?
  if value == Null then return 'null' end

  local kind = type(value)
  if kind == 'nil' then return 'null' end
  if kind == 'boolean' then return if value then 'true' else 'false' end
  if kind == 'number' then return numberText(value :: number) end
  if kind == 'string' then return quote(value :: string) end
  if kind ~= 'table' then error(`JSON cannot encode {kind}`, 0) end

  return nil
end

local function encodeCompact(value: unknown, stack: { [unknown]: boolean }): string
  local written = scalar(value)
  if written then return written end

  local container = value :: { [unknown]: unknown }
  if stack[container] then error('JSON cannot encode a cyclic table', 0) end

  stack[container] = true
  local out = {}

  if isArray(container) then
    table.insert(out, '[')

    for index = 1, #container do
      if index > 1 then table.insert(out, ',') end

      table.insert(out, encodeCompact(container[index], stack))
    end

    table.insert(out, ']')
  else
    local keys = objectKeys(container)
    table.insert(out, '{')

    for index, key in ipairs(keys) do
      if index > 1 then table.insert(out, ',') end

      table.insert(out, quote(key))
      table.insert(out, ':')
      table.insert(out, encodeCompact(container[key], stack))
    end

    table.insert(out, '}')
  end

  stack[container] = nil
  return table.concat(out)
end

local function spaces(count: number): string return string.rep(' ', count) end

local function encodePretty(value: unknown, depth: number, stack: { [unknown]: boolean }): string
  local written = scalar(value)
  if written then return written end

  local container = value :: { [unknown]: unknown }
  if stack[container] then error('JSON cannot encode a cyclic table', 0) end

  stack[container] = true
  local out = {}

  if isArray(container) then
    local count = #container
    if count == 0 then
      stack[container] = nil
      return '[]'
    end

    table.insert(out, '[\n')

    for index = 1, count do
      table.insert(out, spaces((depth + 1) * 2))
      table.insert(out, encodePretty(container[index], depth + 1, stack))
      table.insert(out, if index < count then ',\n' else '\n')
    end

    table.insert(out, spaces(depth * 2))
    table.insert(out, ']')
  else
    local keys = objectKeys(container)
    if #keys == 0 then
      stack[container] = nil
      return '{}'
    end

    table.insert(out, '{\n')

    for index, key in ipairs(keys) do
      table.insert(out, spaces((depth + 1) * 2))
      table.insert(out, quote(key))
      table.insert(out, ': ')
      table.insert(out, encodePretty(container[key], depth + 1, stack))
      table.insert(out, if index < #keys then ',\n' else '\n')
    end

    table.insert(out, spaces(depth * 2))
    table.insert(out, '}')
  end

  stack[container] = nil
  return table.concat(out)
end

--- `value` as JSON: indented by two spaces with a newline at the end, or on one line with no
--- space in it when `pretty` is false.
function json.encode(value: unknown, pretty: boolean?): string
  if pretty == false then return encodeCompact(value, {}) end

  return `{encodePretty(value, 0, {})}\n`
end

return json
