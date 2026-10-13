--!native
-- Deterministic JSON output for generated AsHyAmS data. Jess deliberately ships a decoder only;
-- this writer keeps site output in Luau and preserves the one distinction ordinary Luau tables
-- cannot express by themselves: an empty object versus an empty array.
local JessJson = require '@jess/json'
local M = {}
local Null = JessJson.null

local ARRAY_MT = { __ashyams_json = 'array' }
local OBJECT_MT = { __ashyams_json = 'object' }
local ORDERS = setmetatable({}, {__mode='k'})

function M.array(value)
    value = value or {}
    return setmetatable(value, ARRAY_MT)
end

function M.object(value, order)
    value = value or {}
    setmetatable(value, OBJECT_MT)
    if order then ORDERS[value] = order end
    return value
end

function M.arrayCopy(value)
    local out = M.array()
    for i, item in ipairs(value or {}) do out[i] = item end
    return out
end

function M.objectCopy(value)
    local out = M.object()
    for key, item in pairs(value or {}) do out[key] = item end
    return out
end

local ESCAPES = {
    [8] = '\\b', [9] = '\\t', [10] = '\\n', [12] = '\\f', [13] = '\\r',
    [34] = '\\"', [92] = '\\\\',
}

local HEX = '0123456789abcdef'
local function hex4(byte)
    local a = math.floor(byte / 4096) % 16
    local b = math.floor(byte / 256) % 16
    local c = math.floor(byte / 16) % 16
    local d = byte % 16
    return '\\u'..string.sub(HEX,a+1,a+1)..string.sub(HEX,b+1,b+1)..string.sub(HEX,c+1,c+1)..string.sub(HEX,d+1,d+1)
end

local function quote(text)
    local out = {'"'}
    local start = 1
    for i = 1, #text do
        local byte = string.byte(text, i)
        local escaped = ESCAPES[byte]
        if not escaped and byte < 32 then escaped = hex4(byte) end
        if escaped then
            if i > start then table.insert(out, string.sub(text, start, i - 1)) end
            table.insert(out, escaped)
            start = i + 1
        end
    end
    if start <= #text then table.insert(out, string.sub(text, start)) end
    table.insert(out, '"')
    return table.concat(out)
end

local function isArray(value)
    local mt = getmetatable(value)
    if mt == ARRAY_MT then return true end
    if mt == OBJECT_MT then return false end
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end
        count += 1
        if key > maximum then maximum = key end
    end
    if count == 0 then return false end
    return maximum == count
end

local function numberText(value)
    if value ~= value or value == math.huge or value == -math.huge then error('JSON cannot encode a non-finite number', 0) end
    if value == 0 then return '0' end
    return tostring(value)
end

local function objectKeys(value)
    local ordered = ORDERS[value]
    if not ordered then
        local keys = {}
        for key in pairs(value) do
            if type(key) ~= 'string' then error('JSON object keys must be strings', 0) end
            table.insert(keys, key)
        end
        table.sort(keys)
        return keys
    end
    local keys, seen = {}, {}
    for _, key in ipairs(ordered) do
        if value[key] ~= nil then table.insert(keys,key); seen[key]=true end
    end
    local rest={}
    for key in pairs(value) do
        if type(key) ~= 'string' then error('JSON object keys must be strings', 0) end
        if not seen[key] then table.insert(rest,key) end
    end
    table.sort(rest)
    for _,key in ipairs(rest) do table.insert(keys,key) end
    return keys
end

local function encodeCompact(value, stack)
    if value == Null then return 'null' end
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' then return numberText(value) end
    if kind == 'string' then return quote(value) end
    if kind ~= 'table' then error(`JSON cannot encode {kind}`, 0) end
    if stack[value] then error('JSON cannot encode a cyclic table', 0) end
    stack[value] = true
    local out = {}
    if isArray(value) then
        table.insert(out, '[')
        for i = 1, #value do
            if i > 1 then table.insert(out, ',') end
            table.insert(out, encodeCompact(value[i], stack))
        end
        table.insert(out, ']')
    else
        local keys = objectKeys(value)
        table.insert(out, '{')
        for i, key in ipairs(keys) do
            if i > 1 then table.insert(out, ',') end
            table.insert(out, quote(key)); table.insert(out, ':'); table.insert(out, encodeCompact(value[key], stack))
        end
        table.insert(out, '}')
    end
    stack[value] = nil
    return table.concat(out)
end

local function spaces(count) return string.rep(' ', count) end
local function encodePretty(value, depth, stack)
    if value == Null then return 'null' end
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' then return numberText(value) end
    if kind == 'string' then return quote(value) end
    if kind ~= 'table' then error(`JSON cannot encode {kind}`, 0) end
    if stack[value] then error('JSON cannot encode a cyclic table', 0) end
    stack[value] = true
    local out = {}
    if isArray(value) then
        if #value == 0 then stack[value] = nil; return '[]' end
        table.insert(out, '[\n')
        for i = 1, #value do
            table.insert(out, spaces((depth + 1) * 2))
            table.insert(out, encodePretty(value[i], depth + 1, stack))
            table.insert(out, i < #value and ',\n' or '\n')
        end
        table.insert(out, spaces(depth * 2)); table.insert(out, ']')
    else
        local keys = objectKeys(value)
        if #keys == 0 then stack[value] = nil; return '{}' end
        table.insert(out, '{\n')
        for i, key in ipairs(keys) do
            table.insert(out, spaces((depth + 1) * 2)); table.insert(out, quote(key)); table.insert(out, ': ')
            table.insert(out, encodePretty(value[key], depth + 1, stack))
            table.insert(out, i < #keys and ',\n' or '\n')
        end
        table.insert(out, spaces(depth * 2)); table.insert(out, '}')
    end
    stack[value] = nil
    return table.concat(out)
end

function M.encode(value, pretty)
    if pretty == false then return encodeCompact(value, {}) end
    return encodePretty(value, 0, {}) .. '\n'
end

return M
