--!native
local Util=require './util'
local M={}

local function trim(s) return Util.trim(s) end
local function indentOf(line)
    local prefix=string.match(line,'^(%s*)') or ''
    local n=0
    for i=1,#prefix do n+=string.sub(prefix,i,i)=='\t' and 2 or 1 end
    return n
end
local function dirname(path) return string.match(path,'^(.*)/[^/]+$') or '' end
local function escapePattern(s) return (string.gsub(s,'([^%w])','%%%1')) end
local function plainReplace(s,needle,repl)
    if needle=='' then return s end
    local out={};local at=1
    while true do
        local i,j=string.find(s,needle,at,true)
        if not i then table.insert(out,string.sub(s,at));break end
        table.insert(out,string.sub(s,at,i-1));table.insert(out,repl);at=j+1
    end
    return table.concat(out)
end

local function resolveImport(currentRoot,name)
    name=trim(name)
    name=string.gsub(name,';+$','')
    name=string.match(name,'^["\'](.-)["\']$') or name
    if string.match(name,'^url%(') or string.match(name,'^https?://') or string.match(name,'%.css$') then return nil end
    local base=jess.fs.join(currentRoot,name)
    local candidates={base..'.sass',base..'.scss'}
    local dir=dirname(base);local file=jess.fs.fileName(base)
    table.insert(candidates,jess.fs.join(dir,'_'..file..'.sass'))
    table.insert(candidates,jess.fs.join(dir,'_'..file..'.scss'))
    for _,p in ipairs(candidates) do if jess.fs.isFile(p) then return p end end
    return nil
end

--- A stylesheet's text with every `@import` of a Sass file replaced by that file's own text,
--- expanded the same way. `stack` holds the files being expanded, so one that imports itself is
--- caught.
local function loadExpanded(path: string, stack: { [string]: boolean }?): string
  local open = stack or {}
  if open[path] then error(`sass import cycle: {path}`, 0) end

  open[path] = true
  local text = string.gsub(Util.readRequired(path), '\r\n?', '\n')
  local root = dirname(path)
  local out = {}

  for _, line in string.split(text, '\n') do
    local imported = string.match(line, '^%s*@import%s+(.+)$')
    local resolved = if imported then resolveImport(root, imported) else nil
    table.insert(out, if resolved then loadExpanded(resolved, open) else line)
  end

  open[path] = nil
  return table.concat(out, '\n')
end

local function normalizeSelectorLines(lines)
    local out={};local i=1
    while i<=#lines do
        local line=lines[i]
        local t=trim(line)
        if string.sub(t,-1)==',' and not string.match(t,'^[%-%w]+%s*:') then
            local ind=indentOf(line);local parts={string.sub(t,1,-2)};i+=1
            while i<=#lines do
                local n=lines[i];if indentOf(n)~=ind then break end
                local nt=trim(n);if nt=='' or string.sub(nt,1,2)=='//' then break end
                if string.match(nt,'^[%-%w]+%s*:%s+') then break end
                if string.sub(nt,-1)==',' then table.insert(parts,string.sub(nt,1,-2));i+=1 else table.insert(parts,nt);i+=1;break end
            end
            table.insert(out,string.rep(' ',ind)..table.concat(parts,', '))
        else table.insert(out,line);i+=1 end
    end
    return out
end

--- The source as a tree by indentation: each line that is not blank or a comment is a node
--- under the nearest line above it that is indented less.
local function parseTree(text: string)
  local root = { indent = -1, text = '__root__', children = {} }
  local stack = { root }

  for _, line in normalizeSelectorLines(string.split(text, '\n')) do
    local trimmed = trim(line)
    if trimmed == '' or string.sub(trimmed, 1, 2) == '//' then continue end

    local indent = indentOf(line)
    local node = { indent = indent, text = trimmed, children = {} }
    while #stack > 1 and indent <= stack[#stack].indent do
      table.remove(stack)
    end

    table.insert(stack[#stack].children, node)
    table.insert(stack, node)
  end

  return root
end

local function envNew(parent) return {parent=parent,values={}} end
local function envSet(env,k,v) env.values[k]=v end
local function envGet(env,k)
    local e=env
    while e do local v=e.values[k];if v~=nil then return v end;e=e.parent end
    return nil
end

local function hexRgb(s)
    local hex=string.match(s,'^#([0-9a-fA-F]+)$');if not hex then return nil end
    if #hex==3 then
        return tonumber(string.sub(hex,1,1)..string.sub(hex,1,1),16),tonumber(string.sub(hex,2,2)..string.sub(hex,2,2),16),tonumber(string.sub(hex,3,3)..string.sub(hex,3,3),16)
    elseif #hex==6 then return tonumber(string.sub(hex,1,2),16),tonumber(string.sub(hex,3,4),16),tonumber(string.sub(hex,5,6),16) end
end
local function fmtByte(n) return math.max(0,math.min(255,math.floor(n+0.5))) end
local function rgbHex(r,g,b) return string.format('#%02x%02x%02x',fmtByte(r),fmtByte(g),fmtByte(b)) end
local function splitArgs(s)
    local out={};local depth=0;local quote=nil;local start=1
    for i=1,#s+1 do local c=string.sub(s,i,i)
        if quote then if c==quote and string.sub(s,i-1,i-1)~='\\' then quote=nil end
        elseif c=='"' or c=="'" then quote=c elseif c=='(' then depth+=1 elseif c==')' then depth-=1
        elseif (c==',' or i>#s) and depth==0 then table.insert(out,trim(string.sub(s,start,i-1)));start=i+1 end
    end
    return out
end
local function evalColorFunction(value,env)
    local fn,args=string.match(value,'^([%w_-]+)%((.*)%)$');if not fn then return nil end
    local a=splitArgs(args)
    local function resolve(x)
        x=trim(x);if string.sub(x,1,1)=='$' then return envGet(env,string.sub(x,2)) or x end;return x
    end
    if fn=='mix' and #a>=2 then
        local c1,c2=resolve(a[1]),resolve(a[2]);local r1,g1,b1=hexRgb(c1);local r2,g2,b2=hexRgb(c2)
        if r1 and r2 then local p=0.5;if a[3] then p=(tonumber(string.match(resolve(a[3]),'([%d%.]+)%%')) or 50)/100 end;return rgbHex(r1*p+r2*(1-p),g1*p+g2*(1-p),b1*p+b2*(1-p)) end
    elseif fn=='rgba' and #a>=2 then
        local c=resolve(a[1]);local r,g,b=hexRgb(c);local alpha=tonumber(resolve(a[2]));if r and alpha then return string.format('rgba(%d, %d, %d, %s)',r,g,b,tostring(alpha)) end
    end
    return nil
end
--- `value` with its `#{...}` interpolations and its `$variables` replaced from `env`, and worked
--- out when what is left is one of the colour functions.
local function substitute(value, env): string
  local text = tostring(value or '')

  -- Interpolation can contain a variable or one of the tiny color functions used by
  -- DreamWeave's giscus theme.
  if string.find(text, '#{', 1, true) then
    text = string.gsub(text, '#{(.-)}', function(inner: string): string
      local expression = trim(inner)
      if string.sub(expression, 1, 1) == '$' then return tostring(envGet(env, string.sub(expression, 2)) or '') end

      return evalColorFunction(expression, env) or expression
    end)
  end

  -- Plain Sass variable references.
  if string.find(text, '$', 1, true) then
    text = string.gsub(text, '%$([%w_-]+)', function(name: string): string
      local bound = envGet(env, name)
      return if bound ~= nil then tostring(bound) else `${name}`
    end)
  end

  -- Only text that ends on a closing parenthesis can be a call.
  if string.byte(text, -1) ~= 41 then return text end

  return evalColorFunction(text, env) or text
end

local function splitSelectors(s)
    local out={};for x in string.gmatch(s..',','(.-),') do x=trim(x);if x~='' then table.insert(out,x) end end;return out
end
--- Every selector `child` lists under every selector of `parent`: after it and a space, or
--- with the parent's own wherever the child's writes `&`.
local function combineSelectors(parent: { string }?, child: string): { string }
  local children = splitSelectors(child)
  if not parent or #parent == 0 then return children end

  return [
    for outer in parent
    for inner in children
    => if string.find(inner, '&', 1, true) then plainReplace(inner, '&', outer) else `{outer} {inner}`
  ]
end

local function property(text)
    local name,value=string.match(text,'^([%-%w]+)%s*:%s+(.+)$')
    if not name then name,value=string.match(text,'^(%-%-[%w-]+)%s*:%s*(.+)$') end
    return name,value
end
local function variable(text)
    return string.match(text,'^%$([%w_-]+)%s*:%s*(.*)$')
end

local function parseMixinHeader(text)
    local name,args=string.match(text,'^=([%w_-]+)%s*%((.*)%)$')
    if not name then name=string.match(text,'^=([%w_-]+)$');args='' end
    if not name then return nil end
    local params={}
    for _,part in ipairs(splitArgs(args or '')) do
        if part~='' then local n,d=string.match(part,'^%$([%w_-]+)%s*:%s*(.+)$');if not n then n=string.match(part,'^%$([%w_-]+)$') end;table.insert(params,{name=n,default=d}) end
    end
    return name,params
end
local function parseInclude(text)
    local name,args=string.match(text,'^%+([%w_-]+)%s*%((.*)%)$');if not name then name=string.match(text,'^%+([%w_-]+)$');args='' end;return name,args
end

local function collect(root,state,currentSelectors)
    for _,node in ipairs(root.children) do
        local mix,params=parseMixinHeader(node.text)
        if mix then state.mixins[mix]={params=params,node=node}
        else
            local selectors=currentSelectors
            local p=property(node.text);local v=variable(node.text)
            if not p and not v and string.sub(node.text,1,1)~='@' and string.sub(node.text,1,1)~='+' then selectors=combineSelectors(currentSelectors,node.text) end
            if string.match(node.text,'^@extend%s+') and currentSelectors then
                local target=trim(string.match(node.text,'^@extend%s+(.+)$') or '')
                state.extends[target]=state.extends[target] or {}
                for _,s in ipairs(currentSelectors) do table.insert(state.extends[target],s) end
            end
            collect(node,state,selectors)
        end
    end
end

local function expandExtends(selectors,state)
    local out={};local seen={}
    local function add(s) if not seen[s] then seen[s]=true;table.insert(out,s) end end
    for _,sel in ipairs(selectors or {}) do
        add(sel)
        for target,extenders in pairs(state.extends) do
            local pos=string.find(sel,target,1,true)
            if pos then
                local before=string.sub(sel,1,pos-1);local after=string.sub(sel,pos+#target)
                for _,ext in ipairs(extenders) do add(before..ext..after) end
            end
        end
    end
    return out
end

local function emitRule(out,selectors,declarations,state,indent)
    if not selectors or #selectors==0 or #declarations==0 then return end
    selectors=expandExtends(selectors,state)
    local pre=string.rep('  ',indent or 0)
    table.insert(out,pre..table.concat(selectors,', ')..' {\n')
    for _,d in ipairs(declarations) do table.insert(out,pre..'  '..d..'\n') end
    table.insert(out,pre..'}\n')
end

local renderChildren
local function renderAtRule(node,state,env,parentSelectors,out,depth)
    local header=substitute(node.text,env)
    table.insert(out,string.rep('  ',depth)..header..' {\n')
    if header=='@font-face' then
        local decl={}
        for _,ch in ipairs(node.children) do local n,v=property(ch.text);if n then table.insert(decl,n..': '..substitute(v,env)..';') end end
        for _,d in ipairs(decl) do table.insert(out,string.rep('  ',depth+1)..d..'\n') end
    else
        renderChildren(node.children,state,env,parentSelectors,out,depth+1)
    end
    table.insert(out,string.rep('  ',depth)..'}\n')
end

local function renderMixin(includeName,argText,state,env,parentSelectors,out,depth)
    local m=state.mixins[includeName];if not m then error('sass: unknown mixin '..tostring(includeName),0) end
    local localEnv=envNew(env);local args=splitArgs(argText or '')
    local named={};local positional={}
    for _,a in ipairs(args) do
        if trim(a)~='' then
            local k,v=string.match(a,'^%$?([%w_-]+)%s*:%s*(.+)$')
            if k then named[k]=substitute(v,env) else table.insert(positional,a) end
        end
    end
    local pi=1
    for _,p in ipairs(m.params) do
        local v=named[p.name]
        if v==nil and positional[pi]~=nil then v=positional[pi];pi+=1 end
        if v==nil then v=p.default end
        if v==nil then error('sass: missing mixin argument $'..tostring(p.name),0) end
        envSet(localEnv,p.name,substitute(v,env))
    end
    renderChildren(m.node.children,state,localEnv,parentSelectors,out,depth)
end

renderChildren=function(children,state,env,parentSelectors,out,depth)
    local declarations={}
    local function flush() emitRule(out,parentSelectors,declarations,state,depth);declarations={} end
    for _,node in ipairs(children) do
        local defName=parseMixinHeader(node.text)
        if defName then
            flush()
            continue
        end
        local varName,varValue=variable(node.text)
        local propName,propValue=property(node.text)
        local mixName,mixArgs=parseInclude(node.text)
        if varName then
            flush();envSet(env,varName,substitute(varValue,env))
        elseif propName then
            table.insert(declarations,propName..': '..substitute(propValue,env)..';')
        elseif string.match(node.text,'^@extend%s+') then
            -- Already incorporated into selector expansion during the collection pass.
        elseif string.sub(node.text,1,1)=='@' then
            flush();renderAtRule(node,state,env,parentSelectors,out,depth)
        elseif mixName then
            flush();renderMixin(mixName,mixArgs,state,env,parentSelectors,out,depth)
        else
            flush();local child=combineSelectors(parentSelectors,substitute(node.text,env));renderChildren(node.children,state,envNew(env),child,out,depth)
        end
    end
    flush()
end

local function compileText(text)
    local tree=parseTree(text);local state={mixins={},extends={}}
    collect(tree,state,nil)
    local env=envNew(nil);local out={}
    renderChildren(tree.children,state,env,nil,out,0)
    return table.concat(out)
end

function M.compile(text)
    return compileText(tostring(text or ''))
end

function M.compileFile(path)
    return compileText(loadExpanded(path))
end

function M.compileDirectory(root,public)
    local count=0
    for _,entry in ipairs(Util.walk(root)) do
        local name=jess.fs.fileName(entry.relative)
        local ext=string.match(name,'%.([^%.]+)$')
        if (ext=='sass' or ext=='scss') and string.sub(name,1,1)~='_' then
            -- Indented .sass is the supported source dialect. SCSS is intentionally only accepted
            -- when it happens to contain indentation-compatible syntax; DreamWeave doesn't need a
            -- brace parser yet, despite threats from management.
            local outrel=string.gsub(entry.relative,'%.s[ac]ss$','.css')
            Util.write(jess.fs.join(public,outrel),M.compileFile(entry.path));count+=1
        end
    end
    return count
end

return M
