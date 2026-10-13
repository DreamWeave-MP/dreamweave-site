--!native
local Util=require './util'
local Tera=require './tera'
local Expr=require './expr'
local Markdown=require './markdown'
local Sass=require './sass'
local JsonOut=require './json'
local Json=require '@jess/json'
local Yaml=require '@jess/yaml'
local Toml=require '@jess/toml'
local Bytes=require '@dream/bytes'
local M={}

local function norm(path)
    path=string.gsub(path,'\\','/');path=string.gsub(path,'^@/','');path=string.gsub(path,'^/+','');return path
end
local function dirname(path) local x=string.match(path,'^(.*)/[^/]+$');return x or '' end
local function basename(path) return string.match(path,'([^/]+)$') or path end
local function stem(path) return string.gsub(basename(path),'%.[^%.]+$','') end
local function titleCase(s) s=string.gsub(s,'[-_]+',' ');return (string.gsub(s,'(%a)([%w]*)',function(a,b)return string.upper(a)..b end)) end
local function decodeToml(text) local v=Toml.decode(text);return v end
local function parseFrontmatter(text,path)
    text=string.gsub(text,'\r\n?','\n')
    if string.sub(text,1,4)=='+++\n' then
        local e=string.find(text,'\n+++',5,true);if not e then error(`{path}: unterminated TOML frontmatter`,0) end
        local meta=decodeToml(string.sub(text,5,e-1));local body=string.sub(text,e+5);if string.sub(body,1,1)=='\n' then body=string.sub(body,2) end;return meta,body
    elseif string.sub(text,1,4)=='---\n' then
        local e=string.find(text,'\n---',5,true);if not e then error(`{path}: unterminated YAML frontmatter`,0) end
        local meta=Yaml.decode(string.sub(text,5,e-1));local body=string.sub(text,e+5);if string.sub(body,1,1)=='\n' then body=string.sub(body,2) end;return meta,body
    end
    return {},text
end

local Site={};Site.__index=Site
function Site.new(root,options)
    options=options or {}
    local configPath=jess.fs.isFile(jess.fs.join(root,'config.toml')) and jess.fs.join(root,'config.toml') or jess.fs.join(root,'zola.toml')
    local config=decodeToml(Util.readRequired(configPath));config.extra=config.extra or {};config.markdown=config.markdown or {};config.default_language=config.default_language or 'en';config.title=config.title or 'Site';config.description=config.description or ''
    if options.offline then config.build_search_index=false;config.generate_feeds=false;config.feed_filenames=nil;config.extra.dreamweave_offline=true end
    local self=setmetatable({root=root,config=config,pages={},sections={},pagesBySource={},sectionsBySource={},taxonomies={},options=options,dataCache={},ignoreCache={}},Site)
    self.engine=Tera.Engine.new(root,{markdown=Markdown,site=self})
    self:registerFunctions();self:scan();self:connect();self:renderContent()
    return self
end
function Site:registerFunctions()
    self.engine:addFunction('load_data',function(args,named)
        local literal=named.literal
        local format=named.format
        local text;local cacheKey=nil
        if literal~=nil and literal~=Expr.UNDEF then text=tostring(Expr.unwrap(literal))
        else
            local rel=tostring(Expr.unwrap(named.path or args[1] or ''))
            if not format then format=Util.pathExtension(rel) end
            cacheKey=rel..'|'..string.lower(tostring(format or ''))
            local hit=rawget(self.dataCache,cacheKey);if hit~=nil then return hit end
            local path=jess.fs.join(self.root,rel);text=jess.fs.read(path)
            if text==nil then if named.required==false then return false end;error(`load_data: {rel} does not exist`,0) end
        end
        format=string.lower(tostring(format or ''))
        local result
        if format=='json' then result=Json.decode(text)
        elseif format=='toml' then result=decodeToml(text)
        elseif format=='yaml' or format=='yml' then result=Yaml.decode(text)
        elseif format=='plain' or format=='txt' or format=='' then result=text
        else error(`load_data: unsupported format {format}`,0) end
        if cacheKey then self.dataCache[cacheKey]=result end
        return result
    end)
    self.engine:addFunction('get_url',function(args,named)
        local path=tostring(Expr.unwrap(named.path or args[1] or ''));local result
        if string.match(path,'^https?://') or string.sub(path,1,1)=='#' then result=path
        elseif string.sub(path,1,2)=='@/' then
            local fragment=string.match(path,'(#.*)$') or ''
            local key=norm(string.gsub(path,'#.*$',''));local item=self.pagesBySource[key] or self.sectionsBySource[key];if not item then error(`get_url: unknown content path {path}`,0) end;result=item.permalink..fragment
        else result=Util.joinUrl(self.config.base_url or '',path) end
        if named.trailing_slash==false and string.sub(result,-1)=='/' then result=string.sub(result,1,-2)
        elseif named.trailing_slash==true and not string.find(result,'[%?#]') and string.sub(result,-1)~='/' and not string.match(result,'/[^/]+%.[%w]+$') then result..='/' end
        if named.cachebust==true and not string.match(path,'^https?://') then
            local localPath=jess.fs.join(self.root,'static',norm(path));local bytes=jess.fs.read(localPath);if bytes then result..=(string.find(result,'?',1,true) and '&' or '?')..'h='..string.sub(Bytes.sha256(bytes),1,12) end
        end
        return Tera.safe(result)
    end)
    self.engine:addFunction('get_page',function(args,named) local k=norm(tostring(Expr.unwrap(named.path or args[1] or '')));return self.pagesBySource[k] or Expr.UNDEF end)
    self.engine:addFunction('get_section',function(args,named) local k=norm(tostring(Expr.unwrap(named.path or args[1] or '')));local v=self.sectionsBySource[k] or Expr.UNDEF;if self.options.debug then print('DBG get_section',k, v==Expr.UNDEF and 'UNDEF' or v.relative_path) end;return v end)
    self.engine:addFunction('get_taxonomy_url',function(args,named)
        local kind=tostring(Expr.unwrap(named.kind or args[1] or 'tags'));local name=named.name or args[2]
        if name then return Tera.safe(Util.joinUrl(self.config.base_url,kind..'/'..Util.slugify(Expr.unwrap(name))..'/')) end
        return Tera.safe(Util.joinUrl(self.config.base_url,kind..'/'))
    end)
    self.engine:addFunction('resize_image',function(args,named)
        local path=tostring(Expr.unwrap(named.path or args[1] or ''))
        local width=math.max(0,math.floor(tonumber(Expr.unwrap(named.width or 0)) or 0))
        local height=math.max(0,math.floor(tonumber(Expr.unwrap(named.height or 0)) or 0))
        local op=tostring(Expr.unwrap(named.op or 'fit'))
        local rel=path;if string.sub(rel,1,7)=='static/' then rel=string.sub(rel,8) elseif string.sub(rel,1,8)=='content/' then rel=string.sub(rel,9) end
        rel=norm(rel)
        local originalUrl=Util.joinUrl(self.config.base_url,rel)
        local backend=self.options.imageBackend
        if not backend then return {url=originalUrl,width=width>0 and width or 1,height=height>0 and height or (width>0 and math.max(1,math.floor(width*0.5625)) or 1)} end

        local sourcePath=jess.fs.join(self.root,path)
        if not jess.fs.isFile(sourcePath) then sourcePath=jess.fs.join(self.root,rel) end
        local source=jess.fs.read(sourcePath)
        if source==nil then return {url=originalUrl,width=width>0 and width or 1,height=height>0 and height or 1} end
        local ok,img=pcall(function() return backend.read(sourcePath) end)
        if not ok or type(img)~='table' or not img.width or not img.height then
            return {url=originalUrl,width=width>0 and width or 1,height=height>0 and height or (width>0 and math.max(1,math.floor(width*0.5625)) or 1)}
        end

        local targetW,targetH=width,height
        if op=='fit_width' then
            targetW=width>0 and width or img.width
            targetH=math.max(1,math.floor(img.height*targetW/img.width+0.5))
        elseif op=='fit_height' then
            targetH=height>0 and height or img.height
            targetW=math.max(1,math.floor(img.width*targetH/img.height+0.5))
        elseif targetW<=0 and targetH<=0 then
            targetW,targetH=img.width,img.height
        elseif targetW<=0 then
            targetW=math.max(1,math.floor(img.width*targetH/img.height+0.5))
        elseif targetH<=0 then
            targetH=math.max(1,math.floor(img.height*targetW/img.width+0.5))
        end
        local key=Bytes.sha256(source..'\0'..path..'\0'..tostring(targetW)..'x'..tostring(targetH)..'\0'..op)
        local outRel='processed_images/'..string.sub(key,1,32)..'.png'
        local outPath=jess.fs.join(self.options.public or jess.fs.join(self.root,'public'),outRel)
        if not jess.fs.isFile(outPath) then
            local resized=img:resize(targetW,targetH,false)
            jess.fs.createDir(jess.fs.parent(outPath))
            local wok=pcall(function() backend.write(outPath,resized) end)
            if not wok then return {url=originalUrl,width=img.width,height=img.height} end
        end
        return {url=Util.joinUrl(self.config.base_url,outRel),width=targetW,height=targetH}
    end)
end

function Site:isIgnored(relative)
    local hit=rawget(self.ignoreCache,relative);if hit~=nil then return hit end
    local ignored=false
    for _,pattern in ipairs(self.config.ignored_content or {}) do
        if Util.globMatch(relative,pattern) or Util.globMatch('content/'..relative,pattern) then ignored=true;break end
    end
    self.ignoreCache[relative]=ignored
    return ignored
end

function Site:scan()
    local contentRoot=jess.fs.join(self.root,'content');if not jess.fs.isDir(contentRoot) then return end
    for _,entry in ipairs(Util.walk(contentRoot)) do
        if string.match(entry.relative,'%.md$') and not self:isIgnored(entry.relative) then
            local meta,body=parseFrontmatter(Util.readRequired(entry.path),entry.relative);meta.extra=meta.extra or {};meta.taxonomies=meta.taxonomies or {}
            local rel=entry.relative;local dir=dirname(rel);local file=basename(rel);local isSection=file=='_index.md';local slug=meta.slug or (isSection and (dir=='' and '' or basename(dir)) or stem(file))
            local route
            if meta.path then route=norm(meta.path)
            elseif isSection then route=dir
            elseif file=='index.md' then route=dir
            else route=(dir~='' and dir..'/' or '')..slug end
            route=string.gsub(route,'^/+','');route=string.gsub(route,'/+$','')
            local path='/'..route..(route~='' and '/' or '');local permalink=Util.joinUrl(self.config.base_url or '',route..(route~='' and '/' or ''))
            local item={relative_path=rel,source_path='@/'..rel,colocated_path=(file=='index.md' or file=='_index.md') and (dir~='' and dir..'/' or '') or (dir~='' and dir..'/' or ''),slug=slug,path=path,permalink=permalink,title=meta.title or (isSection and (dir=='' and self.config.title or titleCase(slug)) or titleCase(slug)),description=meta.description or '',extra=meta.extra,taxonomies=meta.taxonomies,date=meta.date,updated=meta.updated,weight=meta.weight or 0,sort_by=meta.sort_by,template=meta.template,page_template=meta.page_template,transparent=meta.transparent or false,render=meta.render~=false,draft=meta.draft==true,in_search_index=meta.in_search_index~=false,generate_feeds=meta.generate_feeds==true,redirect_to=meta.redirect_to,aliases=meta.aliases or {},authors=meta.authors or {},lang=meta.lang or self.config.default_language,raw=body,content='',summary='',toc={},ancestors={},pages={},subsections={},assets={},word_count=0,reading_time=0}
            if isSection then table.insert(self.sections,item);self.sectionsBySource[rel]=item else table.insert(self.pages,item);self.pagesBySource[rel]=item end
        end
    end
end

function Site:connect()
    table.sort(self.sections,function(a,b)return a.relative_path<b.relative_path end);table.sort(self.pages,function(a,b)return a.relative_path<b.relative_path end)
    local function sectionSource(dir) return dir=='' and '_index.md' or dir..'/_index.md' end
    for _,item in ipairs(self.sections) do
        local dir=dirname(item.relative_path);local ancestors={};local cursor=dirname(dir)
        if dir~='' then
            local pieces={};local acc='';for part in string.gmatch(dir,'[^/]+') do acc=acc=='' and part or acc..'/'..part;table.insert(pieces,sectionSource(acc)) end
            table.insert(ancestors,'_index.md');for i=1,#pieces-1 do table.insert(ancestors,pieces[i]) end
        end;item.ancestors=ancestors
    end
    for _,page in ipairs(self.pages) do
        local dir=dirname(page.relative_path);local ancestors={'_index.md'};local acc=''
        for part in string.gmatch(dir,'[^/]+') do acc=acc=='' and part or acc..'/'..part;local s=sectionSource(acc);if self.sectionsBySource[s] then table.insert(ancestors,s) end end
        page.ancestors=ancestors
        local parent=self.sectionsBySource[sectionSource(dir)] or self.sectionsBySource['_index.md'];page.parent=parent
        if parent then table.insert(parent.pages,page) end
        for tag,values in pairs(page.taxonomies or {}) do self.taxonomies[tag]=self.taxonomies[tag] or {};for _,name in ipairs(values) do self.taxonomies[tag][name]=self.taxonomies[tag][name] or {};table.insert(self.taxonomies[tag][name],page) end end
    end
    for _,sec in ipairs(self.sections) do
        local dir=dirname(sec.relative_path);if sec.relative_path~='_index.md' then local parent=self.sectionsBySource[sectionSource(dirname(dir))];if parent then table.insert(parent.subsections,sec.relative_path) end end
    end
    for _,sec in ipairs(self.sections) do
        local sortBy=sec.sort_by or 'none'
        if sortBy=='title' then table.sort(sec.pages,function(a,b)return a.title<b.title end)
        elseif sortBy=='weight' then table.sort(sec.pages,function(a,b) if a.weight~=b.weight then return a.weight<b.weight end return a.title<b.title end)
        elseif sortBy=='date' then table.sort(sec.pages,function(a,b)return tostring(a.date or '')>tostring(b.date or '') end) end
        table.sort(sec.subsections)
    end
end

local function parseShortArgs(text,env)
    local named={};local depth=0;local quote=nil;local start=1
    for i=1,#text+1 do local c=string.sub(text,i,i)
        if quote then if c==quote and string.sub(text,i-1,i-1)~='\\' then quote=nil end
        elseif c=='"' or c=="'" then quote=c elseif c=='(' or c=='[' then depth+=1 elseif c==')' or c==']' then depth-=1
        elseif (c==',' or i>#text) and depth==0 then local part=Util.trim(string.sub(text,start,i-1));if part~='' then local k,v=string.match(part,'^([%w_]+)%s*=%s*(.+)$');if k then named[k]=Expr.eval(v,env) end end;start=i+1 end
    end;return named
end
function Site:baseVars(item,isPage)
    local vars={config=self.config,lang=self.config.default_language,current_url=item and item.permalink or self.config.base_url}
    vars.page=isPage and item or false;vars.section=(not isPage) and item or false;return vars
end
-- A call written in a page's text: `{{ name(arguments) }}` alone, or `{% name(arguments) %}`
-- opening a body that `{% end %}` closes.
local InlineShortcode = '{{%s*([%w_]+)%s*%((.-)%)%s*}}'
local BlockShortcode = '{%%%s*([%w_]+)%s*%((.-)%)%s*%%}'
local BlockEnd = '{%%%s*end%s*%%}'

--- Whether a `{` stands in the run of name characters, spaces and braces that ends just before
--- `stop`, looked for no further back than `start`. Once the text from `stop` on has changed,
--- that run is the only place before it where an inline shortcode could have come to start.
local function opensBefore(text: string, start: number, stop: number): boolean
  for index = stop - 1, start, -1 do
    local byte = string.byte(text, index)
    if byte == 123 then return true end

    local named = (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
    if not named and byte ~= 32 and (byte < 9 or byte > 13) then return false end
  end

  return false
end

--- `text` with its shortcodes rendered through their templates for `item`: at most 200 block
--- shortcodes first, then at most 500 inline ones, what each renders to read again for more.
function Site:shortcodes(text: string, item, isPage: boolean): string
  local vars = self:baseVars(item, isPage)
  local environment = Tera.Env.new(self.engine, vars)

  local function renderOne(name: string, argumentText: string?, body: string?): string
    local arguments = parseShortArgs(argumentText or '', environment)
    for key, value in pairs(vars) do
      if arguments[key] == nil then arguments[key] = value end
    end

    if body then arguments.body = body end

    return self.engine:render(`shortcodes/{name}.html`, arguments)
  end

  -- Neither kind can be found in text without its opening braces, and most pages have none.
  if string.find(text, '{%', 1, true) then
    for _ = 1, 200 do
      local first, last, name, arguments = string.find(text, BlockShortcode, 1)
      if not first then break end

      local endFirst, endLast = string.find(text, BlockEnd, last + 1)
      if not endFirst then break end

      local body = string.sub(text, last + 1, endFirst - 1)
      text = string.sub(text, 1, first - 1) .. renderOne(name, arguments, body) .. string.sub(text, endLast + 1)
    end
  end

  if not string.find(text, '{{', 1, true) then return text end

  -- Each inline shortcode is replaced by what it renders to and the text is searched again from
  -- its top, so that a shortcode a template wrote out, or one the rendered text completed, is
  -- expanded too. A match can only start before the text just rendered where `opensBefore`
  -- finds a brace, and inside it where it holds one; otherwise the next match is the next in
  -- the text not yet read, and what lies before it is kept aside in `done`, not joined and
  -- searched once more for every shortcode on the page.
  local done = {}
  local at = 1

  for _ = 1, 500 do
    local first, last, name, arguments = string.find(text, InlineShortcode, at)
    if not first then break end

    local rendered = renderOne(name, arguments, nil)

    if string.find(rendered, '{', 1, true) or opensBefore(text, at, first) then
      text = table.concat(done) .. string.sub(text, at, first - 1) .. rendered .. string.sub(text, last + 1)
      table.clear(done)
      at = 1
    else
      table.insert(done, string.sub(text, at, first - 1))
      table.insert(done, rendered)
      at = last + 1
    end
  end

  if at == 1 then return text end

  table.insert(done, string.sub(text, at))
  return table.concat(done)
end
function Site:resolveContentLink(href)
    if string.sub(href,1,2)=='@/' then local fragment=string.match(href,'(#.*)$') or '';local key=norm(string.gsub(href,'#.*$',''));local item=self.pagesBySource[key] or self.sectionsBySource[key];if item then return item.permalink..fragment end end
    return href
end
local WordSqueeze = table.freeze { collapse = ' ', trimStart = ' ', trimEnd = ' ' }

--- How many runs of characters that are not whitespace `text` holds outside its tags.
local function countWords(text: string): number
  local words = Bytes.translate((string.gsub(text, '<[^>]->', ' ')), '\t\n\v\f\r', '     ', WordSqueeze)
  if words == '' then return 0 end

  return Bytes.count(words, ' ') + 1
end

--- Renders every item's Markdown: its shortcodes expanded, then its content, its table of
--- contents, its summary when it has a fold, and its word count.
function Site:renderContent()
  local options = {
    insertAnchorLinks = self.config.markdown.insert_anchor_links,
    resolveLink = function(href: string): string return self:resolveContentLink(href) end,
  }

  local function render(item, isPage: boolean)
    local expanded = self:shortcodes(item.raw, item, isPage)
    local marker = string.find(expanded, '<!-- more -->', 1, true)
    local summarySource = if marker then string.sub(expanded, 1, marker - 1) else nil

    -- In this pattern only two of the dashes are dashes. It matches `<`, any number of `!`, one
    -- `-`, `more` with space around it, any number of `-` and `>`: not the `<!-- more -->` that
    -- marks the fold, which stays in the text. A match starts `<-` or `<!`, so text with neither
    -- is not searched.
    if string.find(expanded, '<-', 1, true) or string.find(expanded, '<!', 1, true) then
      expanded = string.gsub(expanded, '<!--%s*more%s*-->', '')
    end

    local document = Markdown.renderDocument(expanded, options)
    item.content, item.toc = document.html, document.toc
    if summarySource then item.summary = Markdown.renderDocument(summarySource, options).html end

    local words = countWords(expanded)
    item.word_count = words
    item.reading_time = math.max(1, math.ceil(words / 200))
  end

  for _, section in ipairs(self.sections) do
    render(section, false)
  end

  for _, page in ipairs(self.pages) do
    render(page, true)
  end
end

function Site:pageTemplate(page)
    if page.template then return page.template end
    local parent=page.parent;if parent and parent.page_template then return parent.page_template end
    return 'page.html'
end
function Site:outputPath(item)
    local rel=string.gsub(item.path,'^/','');return rel=='' and 'index.html' or rel..'index.html'
end
function Site:renderItem(item,isPage)
    local vars=self:baseVars(item,isPage);local template;if isPage then template=self:pageTemplate(item) elseif item.template then template=item.template elseif item.relative_path=='_index.md' and jess.fs.isFile(jess.fs.join(self.root,'templates','index.html')) then template='index.html' else template='section.html' end;return self.engine:render(template,vars)
end
function Site:copyContentAssets(public)
    local root=jess.fs.join(self.root,'content');local count=0
    for _,entry in ipairs(Util.walk(root)) do local base=jess.fs.fileName(entry.relative);if not self:isIgnored(entry.relative) and not string.match(entry.relative,'%.md$') and base~='mod.toml' and base~='mod.lock' then Util.copyFile(entry.path,jess.fs.join(public,entry.relative));count+=1 end end;return count
end
function Site:buildTaxonomies(public)
    local count=0
    for kind,termsMap in pairs(self.taxonomies) do
        local terms={};for name,pages in pairs(termsMap) do table.insert(terms,{name=name,slug=Util.slugify(name),permalink=Util.joinUrl(self.config.base_url,kind..'/'..Util.slugify(name)..'/'),pages=pages}) end;table.sort(terms,function(a,b)return a.name<b.name end)
        if #terms>0 then local html=self.engine:render('taxonomy_list.html',{config=self.config,taxonomy={name=kind},terms=terms,current_url=Util.joinUrl(self.config.base_url,kind..'/'),page=false,section=false,lang=self.config.default_language});Util.write(jess.fs.join(public,kind,'index.html'),html);count+=1 end
        for _,term in ipairs(terms) do local html=self.engine:render('taxonomy_single.html',{config=self.config,taxonomy={name=kind},term=term,pages=term.pages,current_url=term.permalink,page=false,section=false,lang=self.config.default_language});Util.write(jess.fs.join(public,kind,term.slug,'index.html'),html);count+=1 end
    end;return count
end

local function xmlEscape(value)
    local s=tostring(value or '')
    s=string.gsub(s,'&','&amp;');s=string.gsub(s,'<','&lt;');s=string.gsub(s,'>','&gt;');s=string.gsub(s,'"','&quot;');s=string.gsub(s,"'",'&apos;')
    return s
end
local function feedDate(value,atom)
    if not value then return nil end
    local s=tostring(value)
    if string.match(s,'^%d%d%d%d%-%d%d%-%d%d$') then return atom and (s..'T00:00:00+00:00') or s..' 00:00:00 +0000' end
    return s
end
-- The elements whose text is no part of a page's prose, from the opening tag to the first
-- closing one, in any case.
local ElementOptions = table.freeze { caseInsensitive = true, unicode = false, dotAll = true }
local ScriptElement = Bytes.regex('<script[^>]*>.*?</script>', ElementOptions)
local StyleElement = Bytes.regex('<style[^>]*>.*?</style>', ElementOptions)
local PreElement = Bytes.regex('<pre[^>]*>.*?</pre>', ElementOptions)

type Regex = typeof(ScriptElement)

--- `text` with every `element` in it made one space.
local function blankElements(text: string, element: Regex): string
  -- `find` counts from zero, and the end it gives is the offset after the match.
  local first, last = element:find(text, 0)
  if not first then return text end

  local kept = {}
  local at = 0

  while first do
    table.insert(kept, string.sub(text, at + 1, first))
    at = last
    first, last = element:find(text, at)
  end

  table.insert(kept, string.sub(text, at + 1))
  return table.concat(kept, ' ')
end

local CollapseSpaces = table.freeze { collapse = ' ' }
local CollapseLines = table.freeze { collapse = '\n', trimStart = '\n', trimEnd = '\n' }

--- `text` with every run of whitespace in a line made one space, each line trimmed, and the
--- lines left empty dropped.
local function squeezeLines(text: string): string
  -- A line between two newlines has at most one space at each end once its runs are collapsed,
  -- so taking the space beside every newline trims every line.
  local spaced = Bytes.translate(`\n{text}\n`, '\t\v\f\r', '    ', CollapseSpaces)
  spaced = string.gsub(spaced, ' \n', '\n')
  spaced = string.gsub(spaced, '\n ', '\n')

  return Bytes.translate(spaced, '', '', CollapseLines)
end

--- A page's HTML as the text a search index holds: no markup, no code blocks, entities read
--- back, and no more than `limit` bytes when one is given.
local function cleanSearchBody(html: unknown, limit: number?): string
  local body = blankElements(tostring(html or ''), ScriptElement)
  body = blankElements(body, StyleElement)
  body = blankElements(body, PreElement)
  body = string.gsub(body, '<[^>]->', ' ')
  body = string.gsub(body, '&lt;', '<')
  body = string.gsub(body, '&gt;', '>')
  body = string.gsub(body, '&quot;', '"')
  body = string.gsub(body, '&#x27;', "'")
  body = string.gsub(body, '&amp;', '&')
  body = squeezeLines(body)
  if limit and #body > limit then body = string.sub(body, 1, limit) end

  return body
end
function Site:searchItems()
    local cfg=self.config.search or {};local out=JsonOut.array()
    local function add(item)
        if item.in_search_index==false or item.draft or item.redirect_to then return end
        local row=JsonOut.object({}, {'url','title','description','body','path'})
        row.url=item.permalink
        if cfg.include_title~=false then row.title=item.title or '' end
        if cfg.include_description==true then row.description=item.description or '' end
        if cfg.include_content~=false then row.body=cleanSearchBody(item.content,cfg.truncate_content_length) end
        if cfg.include_path==true then row.path=item.path end
        table.insert(out,row)
    end
    for _,section in ipairs(self.sections) do add(section) end
    for _,page in ipairs(self.pages) do add(page) end
    table.sort(out,function(a,b)return tostring(a.url)<tostring(b.url) end)
    return out
end
function Site:buildSearch(public)
    if self.config.build_search_index~=true then return 0 end
    local cfg=self.config.search or {};local format=cfg.index_format or 'elasticlunr_javascript'
    -- DreamWeave's current consumers use fuse_json. Fail rather than silently emit the wrong contract.
    if format~='fuse_json' then error('site.jpk currently supports search.index_format = "fuse_json"; got '..tostring(format),0) end
    local name='search_index.'..tostring(self.config.default_language or 'en')..'.json'
    Util.write(jess.fs.join(public,name),JsonOut.encode(self:searchItems(),false))
    return 1
end
function Site:feedPages()
    local pages={}
    for _,p in ipairs(self.pages) do if p.render and not p.draft and p.date then table.insert(pages,p) end end
    table.sort(pages,function(a,b) local ad=tostring(a.date or '');local bd=tostring(b.date or '');if ad~=bd then return ad>bd end return tostring(a.permalink)<tostring(b.permalink) end)
    return pages
end
function Site:atomFeed(feedUrl,pages,section,term)
    local o={'<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="',xmlEscape(self.config.default_language or 'en'),'">\n<title>',xmlEscape(self.config.title or '')}
    if term then table.insert(o,' - '..xmlEscape(term.name)) elseif section and section.title then table.insert(o,' - '..xmlEscape(section.title)) end
    table.insert(o,'</title>\n');if self.config.description and self.config.description~='' then table.insert(o,'<subtitle>'..xmlEscape(self.config.description)..'</subtitle>\n') end
    table.insert(o,'<link rel="self" type="application/atom+xml" href="'..xmlEscape(feedUrl)..'"/>\n<link rel="alternate" type="text/html" href="'..xmlEscape(section and section.permalink or self.config.base_url)..'"/>\n<generator uri="https://www.getzola.org/">Zola</generator>\n')
    local latest=pages[1] and (pages[1].updated or pages[1].date);if latest then table.insert(o,'<updated>'..xmlEscape(feedDate(latest,true))..'</updated>\n') end
    table.insert(o,'<id>'..xmlEscape(feedUrl)..'</id>\n')
    for _,p in ipairs(pages) do
        table.insert(o,'<entry xml:lang="'..xmlEscape(p.lang or self.config.default_language or 'en')..'">\n<title>'..xmlEscape(p.title or '')..'</title>\n')
        if p.date then table.insert(o,'<published>'..xmlEscape(feedDate(p.date,true))..'</published>\n') end
        if p.updated or p.date then table.insert(o,'<updated>'..xmlEscape(feedDate(p.updated or p.date,true))..'</updated>\n') end
        local authors=p.authors or {};if #authors==0 then authors={self.config.author or 'Unknown'} end
        for _,a in ipairs(authors) do table.insert(o,'<author><name>'..xmlEscape(a)..'</name></author>\n') end
        table.insert(o,'<link rel="alternate" type="text/html" href="'..xmlEscape(p.permalink)..'"/>\n<id>'..xmlEscape(p.permalink)..'</id>\n')
        if p.summary and p.summary~='' then table.insert(o,'<summary type="html">'..xmlEscape(p.summary)..'</summary>\n') else table.insert(o,'<content type="html" xml:base="'..xmlEscape(p.permalink)..'">'..xmlEscape(p.content)..'</content>\n') end
        table.insert(o,'</entry>\n')
    end
    table.insert(o,'</feed>\n');return table.concat(o)
end
function Site:rssFeed(feedUrl,pages,section,term)
    local title=self.config.title or '';if term then title..=' - '..tostring(term.name) elseif section and section.title then title..=' - '..tostring(section.title) end
    local o={'<?xml version="1.0" encoding="UTF-8"?>\n<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0"><channel>\n<title>',xmlEscape(title),'</title>\n<link>',xmlEscape(section and section.permalink or self.config.base_url),'</link>\n<description>',xmlEscape(self.config.description or ''),'</description>\n<generator>Zola</generator>\n<language>',xmlEscape(self.config.default_language or 'en'),'</language>\n<atom:link href="',xmlEscape(feedUrl),'" rel="self" type="application/rss+xml"/>\n'}
    for _,p in ipairs(pages) do local author=(p.authors and p.authors[1]) or self.config.author or 'Unknown';table.insert(o,'<item><title>'..xmlEscape(p.title or '')..'</title>');if p.date then table.insert(o,'<pubDate>'..xmlEscape(feedDate(p.date,false))..'</pubDate>') end;table.insert(o,'<author>'..xmlEscape(author)..'</author><link>'..xmlEscape(p.permalink)..'</link><guid>'..xmlEscape(p.permalink)..'</guid><description xml:base="'..xmlEscape(p.permalink)..'">'..xmlEscape((p.summary and p.summary~='') and p.summary or p.content)..'</description></item>\n') end
    table.insert(o,'</channel></rss>\n');return table.concat(o)
end
function Site:buildFeeds(public)
    if self.config.generate_feeds~=true then return 0 end
    local filenames=self.config.feed_filenames or {'atom.xml'};local pages=self:feedPages();local count=0
    for _,name in ipairs(filenames) do local url=Util.joinUrl(self.config.base_url or '',name);local data;if string.lower(name)=='rss.xml' then data=self:rssFeed(url,pages,nil,nil) else data=self:atomFeed(url,pages,nil,nil) end;Util.write(jess.fs.join(public,name),data);count+=1 end
    return count
end
function Site:buildAliases(public)
    local count=0
    for _,item in ipairs(self.pages) do for _,alias in ipairs(item.aliases or {}) do local rel=norm(alias);if rel~='' then local dest=string.match(rel,'%.html$') and rel or (string.gsub(rel,'/+$','')..'/index.html');local html='<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0; url='..Util.escapeAttribute(item.permalink)..'"><link rel="canonical" href="'..Util.escapeAttribute(item.permalink)..'">';Util.write(jess.fs.join(public,dest),html);count+=1 end end end
    return count
end
function Site:buildSitemap(public)
    local entries={}
    for _,s in ipairs(self.sections) do if s.render and not s.draft and not s.redirect_to then table.insert(entries,s) end end
    for _,p in ipairs(self.pages) do if p.render and not p.draft and not p.redirect_to then table.insert(entries,p) end end
    table.sort(entries,function(a,b)return tostring(a.permalink)<tostring(b.permalink) end)
    local out={'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'}
    for _,x in ipairs(entries) do table.insert(out,'<url><loc>'..xmlEscape(x.permalink)..'</loc>');if x.updated then table.insert(out,'<lastmod>'..xmlEscape(x.updated)..'</lastmod>') end;table.insert(out,'</url>\n') end
    table.insert(out,'</urlset>\n');Util.write(jess.fs.join(public,'sitemap.xml'),table.concat(out));return 1
end
function Site:buildRobots(public)
    local path=jess.fs.join(public,'robots.txt');if jess.fs.isFile(path) then return 0 end
    Util.write(path,'User-agent: *\nDisallow:\nAllow: /\nSitemap: '..Util.joinUrl(self.config.base_url or '','sitemap.xml')..'\n');return 1
end
function Site:build404(public)
    if not jess.fs.isFile(jess.fs.join(self.root,'templates','404.html')) then return 0 end
    local html=self.engine:render('404.html',{config=self.config,page=false,section=false,lang=self.config.default_language,current_url=Util.joinUrl(self.config.base_url or '','404.html')})
    Util.write(jess.fs.join(public,'404.html'),html);return 1
end

function Site:build(public)
    self.options.public=public
    jess.fs.createDir(public);local rendered=0
    if jess.fs.isDir(jess.fs.join(self.root,'static')) then Util.copyTree(jess.fs.join(self.root,'static'),public) end
    self:copyContentAssets(public)
    for _,s in ipairs(self.sections) do if s.render and not s.draft and not s.redirect_to then local ok,html=pcall(function() return self:renderItem(s,false) end);if not ok then error('section '..tostring(s.relative_path)..': '..tostring(html),0) end;Util.write(jess.fs.join(public,self:outputPath(s)),html);rendered+=1 end end
    for _,p in ipairs(self.pages) do if p.render and not p.draft and not p.redirect_to then local ok,html=pcall(function() return self:renderItem(p,true) end);if not ok then error('page '..tostring(p.relative_path)..': '..tostring(html),0) end;Util.write(jess.fs.join(public,self:outputPath(p)),html);rendered+=1 end end
    local tax=self:buildTaxonomies(public)
    if jess.fs.isDir(jess.fs.join(self.root,'sass')) then Sass.compileDirectory(jess.fs.join(self.root,'sass'),public) end
    local feeds=self:buildFeeds(public);local search=self:buildSearch(public);local aliases=self:buildAliases(public);local special=self:buildSitemap(public)+self:buildRobots(public)+self:build404(public)
    return {pages=rendered,taxonomies=tax,sections=#self.sections,content_pages=#self.pages,feeds=feeds,search=search,aliases=aliases,special=special}
end
M.Site=Site
function M.load(root,options) return Site.new(root,options) end
function M.build(root,public,options) return Site.new(root,options):build(public) end
return M
