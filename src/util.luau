--!strict
--!native
-- What the site generator's modules share: text trimmed, escaped and slugged, URLs joined, globs
-- matched against content paths, and files read, walked, written and copied below folders made
-- as they are needed.

export type Entry = { path: string, relative: string }

local util = {}

--- `text` without the whitespace at its ends. Text that starts and ends on a byte above the
--- space is handed back as it is, which is most of what a document's lines are.
function util.trim(text: string): string
  local first, last = string.byte(text, 1), string.byte(text, -1)
  if first and first > 32 and last > 32 and type(text) == 'string' then return text end

  return string.match(text, '^%s*(.*%S)') or ''
end

--- `value` as text with the five characters HTML reserves spelled as entities.
function util.escapeHtml(value: unknown): string
  local text = tostring(value)
  text = string.gsub(text, '&', '&amp;')
  text = string.gsub(text, '<', '&lt;')
  text = string.gsub(text, '>', '&gt;')
  text = string.gsub(text, '"', '&quot;')
  text = string.gsub(text, "'", '&#x27;')

  return text
end

function util.escapeAttribute(value: unknown): string return util.escapeHtml(value) end

--- A shallow copy of every key `source` has; an empty table for none.
function util.copy<Key, Value>(source: { [Key]: Value }?): { [Key]: Value }
  local out = {}
  for key, value in pairs(source or {}) do
    out[key] = value
  end

  return out
end

--- A copy of `source` up to its first gap.
function util.arrayCopy<Value>(source: { Value }?): { Value }
  local out = {}
  for index, value in ipairs(source or {}) do
    out[index] = value
  end

  return out
end

--- Whether `value` is a table whose keys are exactly `1..n`.
function util.isArray(value: unknown): boolean
  if type(value) ~= 'table' then return false end

  local length = 0
  for key in pairs(value :: { [unknown]: unknown }) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end

    if key > length then length = key end
  end

  for index = 1, length do
    if rawget(value :: { unknown }, index) == nil then return false end
  end

  return true
end

--- `path` below `base`, with one slash between them. An absolute URL or a fragment is its own
--- answer.
function util.joinUrl(base: string, path: string): string
  if string.match(path, '^https?://') or string.sub(path, 1, 1) == '#' then return path end

  local stem = string.match(base, '^(.-)/*$') :: string
  local rest = string.match(path, '^/*(.*)$') :: string

  return `{stem}/{rest}`
end

--- `value` as a URL slug: lower case, every run of other characters one dash, none at the ends.
function util.slugify(value: unknown): string
  local slug = string.lower(tostring(value))
  slug = string.gsub(slug, '[^%w%._~-]+', '-')
  slug = string.gsub(slug, '%-+', '-')
  slug = string.gsub(slug, '^%-+', '')
  slug = string.gsub(slug, '%-+$', '')

  return slug
end

--- The text after the last dot of a path's file name, if it has one.
function util.pathExtension(path: string): string? return (string.match(path, '%.([^%./]+)$')) end

--- A file's contents, or an error naming the file that is not there.
function util.readRequired(path: string): string
  local contents = jess.fs.read(path)
  if contents == nil then error(`read {path}: file does not exist`, 0) end

  return contents
end

--- Every file below `root`, folders walked in name order, appended to `files`: where it is, and
--- its path relative to `root` (below `prefix`, when one is given) with forward slashes.
function util.walk(root: string, files: { Entry }?, prefix: string?): { Entry }
  local found: { Entry } = files or {}
  local below = prefix or ''
  if not jess.fs.isDir(root) then return found end

  local names = jess.fs.list(root)
  table.sort(names)

  for _, name in names do
    local path = jess.fs.join(root, name)
    local relative = if below == '' then name else `{below}/{name}`

    if jess.fs.isDir(path) then
      util.walk(path, found, relative)
    elseif jess.fs.isFile(path) then
      table.insert(found, { path = path, relative = relative })
    end
  end

  return found
end

--- Makes the folder `path` is in, when it names one.
function util.ensureParent(path: string)
  local parent = jess.fs.parent(path)
  if parent and parent ~= '' then jess.fs.createDir(parent) end
end

function util.write(path: string, data: string)
  util.ensureParent(path)
  return jess.fs.write(path, data)
end

function util.copyFile(from: string, to: string)
  util.ensureParent(to)
  return jess.fs.copy(from, to)
end

--- Copies every file below `from` to the same place below `to`, and counts them.
function util.copyTree(from: string, to: string): number
  local entries = util.walk(from)
  for _, entry in entries do
    util.copyFile(entry.path, jess.fs.join(to, entry.relative))
  end

  return #entries
end

--- One glob segment as an anchored Lua pattern: `*` any run and `?` any one character, neither
--- crossing a slash, and everything else itself.
local function segmentPattern(segment: string): string
  local out = { '^' }
  for index = 1, #segment do
    local character = string.sub(segment, index, index)

    if character == '*' then
      table.insert(out, '[^/]*')
    elseif character == '?' then
      table.insert(out, '[^/]')
    elseif string.find('^$()%.[]+-', character, 1, true) then
      table.insert(out, `%{character}`)
    else
      table.insert(out, character)
    end
  end

  table.insert(out, '$')
  return table.concat(out)
end

--- A path's segments: what lies before each slash of `path` with one appended.
local function segments(path: string): { string }
  local out = {}
  for segment in string.gmatch(`{path}/`, '(.-)/') do
    table.insert(out, segment)
  end

  return out
end

--- Whether `path` matches `glob`, a segment at a time: `**` is any number of segments, and
--- either may be written with backslashes or a leading `./`.
function util.globMatch(path: string, glob: string): boolean
  local pathSegments = segments((string.gsub(string.gsub(path, '\\', '/'), '^%./', '')))
  local globSegments = segments((string.gsub(string.gsub(glob, '\\', '/'), '^%./', '')))
  local pathCount, globCount = #pathSegments, #globSegments
  local memo: { [string]: boolean } = {}

  local function matches(globIndex: number, pathIndex: number): boolean
    local key = `{globIndex}:{pathIndex}`
    local known = memo[key]
    if known ~= nil then return known end

    local matched = false
    if globIndex > globCount then
      matched = pathIndex > pathCount
    elseif globSegments[globIndex] == '**' then
      matched = matches(globIndex + 1, pathIndex) or (pathIndex <= pathCount and matches(globIndex, pathIndex + 1))
    elseif
      pathIndex <= pathCount
      and string.match(pathSegments[pathIndex], segmentPattern(globSegments[globIndex]))
    then
      matched = matches(globIndex + 1, pathIndex + 1)
    end

    memo[key] = matched
    return matched
  end

  return matches(1, 1)
end

--- `text` cut at every `separator`, a comma unless one is given; its characters for an empty
--- separator.
function util.split(text: string, separator: string?): { string }
  local cut = separator or ','
  if cut == '' then return [for index in range(1, #text) => string.sub(text, index, index)] end

  local out = {}
  local at = 1

  while true do
    local first, last = string.find(text, cut, at, true)
    if not first then break end

    table.insert(out, string.sub(text, at, first - 1))
    at = (last :: number) + 1
  end

  table.insert(out, string.sub(text, at))
  return out
end

return util
