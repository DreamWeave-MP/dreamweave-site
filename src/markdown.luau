--!strict
--!native
-- The Markdown the site's pages are written in, rendered to the HTML Zola made of it: inline
-- spans, and a document's blocks with the table of contents its headings give.
local util = require './util'

export type TocEntry = { level: number, id: string, title: string, permalink: string }

export type Options = {
  --- Render the text as inline spans alone, with no paragraph around it.
  inline: boolean?,
  --- Where a heading's anchor link goes: 'left', any other true value for the right, or nowhere.
  insertAnchorLinks: unknown,
  --- What a link's or an image's target becomes; nil keeps it as written.
  resolveLink: ((href: string, image: boolean) -> string?)?,
}

export type Document = { html: string, toc: { TocEntry } }

local markdown = {}

local NoOptions: Options = table.freeze {}

--- The closing parenthesis of a link target that opens before `start`, counting the pairs inside.
local function linkFinish(text: string, start: number): number?
  local depth = 0

  for index = start, #text do
    local character = string.sub(text, index, index)

    if character == '(' then
      depth += 1
    elseif character == ')' then
      if depth == 0 then return index end

      depth -= 1
    end
  end

  return nil
end

local function asciiWord(character: string): boolean
  if character == '' then return false end

  local byte = string.byte(character)
  return (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)
end

--- The first underscore from `start` on that is not between two word characters.
local function underscoreClose(text: string, start: number): number?
  local search = start

  while true do
    local finish = string.find(text, '_', search, true)
    if not finish then return nil end

    local before = if finish > 1 then string.sub(text, finish - 1, finish - 1) else ''
    local after = if finish < #text then string.sub(text, finish + 1, finish + 1) else ''
    if not (asciiWord(before) and asciiWord(after)) then return finish end

    search = finish + 1
  end
end

--- A link target as written, split into the address and the quoted title after it.
local function splitHref(raw: string): (string, string?)
  local target = util.trim(raw)
  local href, title = string.match(target, '^(.-)%s+["\'](.-)["\']%s*$')
  if href then return util.trim(href), title end

  return target, nil
end

local function inline(text: string, options: Options?): string
  local given = options or NoOptions
  local resolveLink = given.resolveLink
  local out = {}
  local at = 1

  while at <= #text do
    local two, character = string.sub(text, at, at + 1), string.sub(text, at, at)

    if not string.find('![`*_~<\\', character, 1, true) then
      local stop = string.find(text, '[!%[`*_~<\\]', at + 1) or #text + 1
      table.insert(out, util.escapeHtml(string.sub(text, at, stop - 1)))
      at = stop
      continue
    end

    if two == '![' then
      local close = string.find(text, '](', at + 2, true)
      local finish = if close then linkFinish(text, close + 2) else nil

      if close and finish then
        local alternative = string.sub(text, at + 2, close - 1)
        local href, title = splitHref(string.sub(text, close + 2, finish - 1))
        if resolveLink then href = resolveLink(href, true) or href end

        local tag = `<img src="{util.escapeAttribute(href)}" alt="{util.escapeAttribute(alternative)}"`
        if title then tag ..= ` title="{util.escapeAttribute(title)}"` end

        table.insert(out, `{tag}>`)
        at = finish + 1
        continue
      end
    elseif character == '[' then
      local close = string.find(text, '](', at + 1, true)
      local finish = if close then linkFinish(text, close + 2) else nil

      if close and finish then
        local label = string.sub(text, at + 1, close - 1)
        local href, title = splitHref(string.sub(text, close + 2, finish - 1))
        if resolveLink then href = resolveLink(href, false) or href end

        local tag = `<a href="{util.escapeAttribute(href)}"`
        if title then tag ..= ` title="{util.escapeAttribute(title)}"` end

        table.insert(out, `{tag}>{inline(label, given)}</a>`)
        at = finish + 1
        continue
      end
    elseif character == '`' then
      local run = 1
      while string.sub(text, at + run, at + run) == '`' do
        run += 1
      end

      local finish = string.find(text, string.rep('`', run), at + run, true)
      if finish then
        table.insert(out, `<code>{util.escapeHtml(string.sub(text, at + run, finish - 1))}</code>`)
        at = finish + run
        continue
      end
    elseif two == '**' or two == '__' then
      local finish = string.find(text, two, at + 2, true)
      if finish then
        table.insert(out, `<strong>{inline(string.sub(text, at + 2, finish - 1), given)}</strong>`)
        at = finish + 2
        continue
      end
    elseif two == '~~' then
      local finish = string.find(text, '~~', at + 2, true)
      if finish then
        table.insert(out, `<del>{inline(string.sub(text, at + 2, finish - 1), given)}</del>`)
        at = finish + 2
        continue
      end
    elseif character == '*' or character == '_' then
      -- An underscore opens emphasis wherever it stands, inside a word too; only where it closes
      -- is held to a word boundary, and when no underscore is at one, the next closes it.
      local finish = if character == '_'
        then underscoreClose(text, at + 1) or string.find(text, '_', at + 1, true)
        else string.find(text, '*', at + 1, true)

      if finish then
        table.insert(out, `<em>{inline(string.sub(text, at + 1, finish - 1), given)}</em>`)
        at = finish + 1
        continue
      end
    elseif character == '<' then
      local finish = string.find(text, '>', at + 1, true)
      if finish then
        local raw = string.sub(text, at, finish)
        local automatic = string.match(raw, '^<(https?://[^>]+)>$')

        if automatic then
          table.insert(out, `<a href="{util.escapeAttribute(automatic)}">{util.escapeHtml(automatic)}</a>`)
        else
          table.insert(out, raw)
        end

        at = finish + 1
        continue
      end
    elseif character == '\\' and at < #text then
      local escaped = string.sub(text, at + 1, at + 1)
      if string.find('\\`*_{}[]()#+-.!<>', escaped, 1, true) then
        table.insert(out, util.escapeHtml(escaped))
        at += 2
        continue
      end
    end

    table.insert(out, util.escapeHtml(character))
    at += 1
  end

  return table.concat(out)
end

markdown.inline = inline

--- A fence line's run of backticks or tildes and the language named after it.
local function fence(line: string): (string?, string?)
  local marker, language = string.match(line, '^%s*(```+)%s*(.-)%s*$')
  if not marker then
    marker, language = string.match(line, '^%s*(~~~+)%s*(.-)%s*$')
  end

  return marker, language
end

--- A list line's kind, its text, and how far it is indented.
local function listItem(line: string): (string?, string?, number?)
  local indent, mark, value = string.match(line, '^(%s*)([-+*])%s+(.+)$')
  if mark then return 'ul', value, #(indent :: string) end

  indent, mark, value = string.match(line, '^(%s*)(%d+[.)])%s+(.+)$')
  if mark then return 'ol', value, #(indent :: string) end

  return nil, nil, nil
end

--- An ATX heading's level and its text, without the closing hashes.
local function heading(line: string): (number?, string?)
  local hashes, body = string.match(line, '^%s*(#+)%s+(.+)$')
  if not hashes or #hashes > 6 then return nil, nil end

  return #hashes, (string.gsub(body :: string, '%s+#+%s*$', ''))
end

local function rule(line: string): boolean
  local marks = string.gsub(line, '%s', '')
  return marks == '---' or marks == '***' or marks == '___' or string.match(marks, '^%-+%-+%-+$') ~= nil
end

-- `%t` in the set is the letter, not a tab: a line of pipes, colons, dashes, spaces and `t`s
-- separates a table's head from its rows, as it always has here.
local function tableSeparator(line: string): boolean
  return string.find(line, '|', 1, true) ~= nil
    and string.gsub(line, '[|:%- %t]', '') == ''
    and string.find(line, '%-') ~= nil
end

--- A table row's cells, the pipes at its ends not counted.
local function cells(line: string): { string }
  local row = util.trim(line)
  if string.sub(row, 1, 1) == '|' then row = string.sub(row, 2) end
  if string.sub(row, -1) == '|' then row = string.sub(row, 1, -2) end

  local out = {}
  for cell in string.gmatch(`{row}|`, '(.-)|') do
    table.insert(out, util.trim(cell))
  end

  return out
end

--- A heading's anchor, made unique among `seen` by a number after it.
local function slug(title: string, seen: { [string]: boolean }): string
  -- Zola's default anchor strategy is classic slugification. Preserve characters inside
  -- code spans long enough for '_' to become '-' (rather than deleting it as emphasis syntax).
  local plain = string.gsub(title, '<[^>]->', '')
  plain = string.gsub(plain, '`', '')
  plain = string.gsub(plain, '%*', '')
  plain = string.gsub(plain, '~', '')
  plain = string.lower(plain)

  local base = string.gsub(plain, '[^%w]+', '-')
  base = string.gsub(base, '%-+', '-')
  base = string.gsub(base, '^%-+', '')
  base = string.gsub(base, '%-+$', '')
  if base == '' then base = 'section' end

  local unique, number = base, 1
  while seen[unique] do
    number += 1
    unique = `{base}-{number}`
  end

  seen[unique] = true
  return unique
end

--- Whether `line` ends a paragraph by starting a block of another kind.
local function startsBlock(line: string): boolean
  return fence(line) ~= nil
    or heading(line) ~= nil
    or rule(line)
    or listItem(line) ~= nil
    or string.match(line, '^%s*>') ~= nil
end

function markdown.renderDocument(text: string, options: Options?): Document
  local given = options or NoOptions
  local normal = string.gsub(text, '\r\n?', '\n')
  local lines = {}

  for line in string.gmatch(`{normal}\n`, '(.-)\n') do
    table.insert(lines, line)
  end

  local out, toc = {}, {}
  local seen: { [string]: boolean } = {}
  local index = 1

  while index <= #lines do
    local line = lines[index]
    if util.trim(line) == '' then
      index += 1
      continue
    end

    local marker, language = fence(line)
    if marker then
      -- A marker is a run of backticks or of tildes, neither of which a pattern reads as magic.
      local closing = `^%s*{marker}`
      local body = {}
      index += 1

      while index <= #lines and not string.match(lines[index], closing) do
        table.insert(body, lines[index])
        index += 1
      end

      if index <= #lines then index += 1 end

      local class = if language ~= '' then ` class="language-{util.escapeAttribute(util.trim(language :: string))}"` else ''
      table.insert(out, `<pre><code{class}>{util.escapeHtml(table.concat(body, '\n'))}\n</code></pre>\n`)
      continue
    end

    local level, title = heading(line)
    if level and title then
      local id = slug(title, seen)
      local htmlTitle = inline(title, given)
      table.insert(toc, { level = level, id = id, title = (string.gsub(title, '[`*_~]', '')), permalink = `#{id}` })

      local anchor = ''
      if given.insertAnchorLinks then
        anchor = `<a class="zola-anchor" href="#{id}" aria-label="Anchor link for: {util.escapeAttribute(title)}">§</a>`
      end

      if given.insertAnchorLinks == 'left' then
        table.insert(out, `<h{level} id="{id}">{anchor}{htmlTitle}</h{level}>\n`)
      else
        table.insert(out, `<h{level} id="{id}">{htmlTitle}{anchor}</h{level}>\n`)
      end

      index += 1
      continue
    end

    if index < #lines then
      local under = util.trim(lines[index + 1])

      if string.match(under, '^=+$') or string.match(under, '^%-+$') then
        local setextLevel = if string.sub(under, 1, 1) == '=' then 1 else 2
        local id = slug(line, seen)
        table.insert(toc, { level = setextLevel, id = id, title = line, permalink = `#{id}` })
        table.insert(out, `<h{setextLevel} id="{id}">{inline(line, given)}</h{setextLevel}>\n`)
        index += 2
        continue
      end
    end

    if rule(line) then
      table.insert(out, '<hr>\n')
      index += 1
      continue
    end

    local kind, _, indent = listItem(line)
    if kind then
      table.insert(out, `<{kind}>\n`)

      while index <= #lines do
        local itemKind, item, itemIndent = listItem(lines[index])
        if itemKind ~= kind or itemIndent ~= indent then break end

        table.insert(out, `<li>{inline(item :: string, given)}</li>\n`)
        index += 1
      end

      table.insert(out, `</{kind}>\n`)
      continue
    end

    if string.match(line, '^%s*>') then
      local quoted = {}

      while index <= #lines do
        local inner = string.match(lines[index], '^%s*>%s?(.*)$')
        if inner == nil then break end

        table.insert(quoted, inner)
        index += 1
      end

      table.insert(out, `<blockquote>\n{markdown.renderDocument(table.concat(quoted, '\n'), given).html}</blockquote>\n`)
      continue
    end

    if string.match(util.trim(line), '^<[%a!/][^>]*>') then
      local raw = { line }
      index += 1

      while index <= #lines and util.trim(lines[index]) ~= '' do
        table.insert(raw, lines[index])
        index += 1
      end

      table.insert(out, `{table.concat(raw, '\n')}\n`)
      continue
    end

    if index < #lines and string.find(line, '|', 1, true) and tableSeparator(lines[index + 1]) then
      table.insert(out, '<table><thead><tr>')
      for _, cell in cells(line) do
        table.insert(out, `<th>{inline(cell, given)}</th>`)
      end

      table.insert(out, '</tr></thead><tbody>')
      index += 2

      while index <= #lines and util.trim(lines[index]) ~= '' and string.find(lines[index], '|', 1, true) do
        table.insert(out, '<tr>')
        for _, cell in cells(lines[index]) do
          table.insert(out, `<td>{inline(cell, given)}</td>`)
        end

        table.insert(out, '</tr>')
        index += 1
      end

      table.insert(out, '</tbody></table>\n')
      continue
    end

    local paragraph = { line }
    index += 1

    while index <= #lines and util.trim(lines[index]) ~= '' and not startsBlock(lines[index]) do
      table.insert(paragraph, lines[index])
      index += 1
    end

    local joined = string.gsub(table.concat(paragraph, '\n'), '  \n', '<br>\n')
    table.insert(out, `<p>{inline(joined, given)}</p>\n`)
  end

  return { html = table.concat(out), toc = toc }
end

function markdown.render(text: unknown, options: Options?): string
  local given = options or NoOptions
  if given.inline then return inline(tostring(text or ''), given) end

  return markdown.renderDocument(text :: string, given).html
end

return markdown
