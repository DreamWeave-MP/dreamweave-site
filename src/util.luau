--!native
local M = {}

function M.trim(s)
    return (string.gsub(string.gsub(s, '^%s+', ''), '%s+$', ''))
end

function M.escapeHtml(s)
    s = tostring(s)
    s = string.gsub(s, '&', '&amp;')
    s = string.gsub(s, '<', '&lt;')
    s = string.gsub(s, '>', '&gt;')
    s = string.gsub(s, '"', '&quot;')
    s = string.gsub(s, "'", '&#x27;')
    return s
end

function M.escapeAttribute(s) return M.escapeHtml(s) end

function M.copy(t)
    local out = {}
    for k,v in pairs(t or {}) do out[k]=v end
    return out
end

function M.arrayCopy(t)
    local out={}
    for i,v in ipairs(t or {}) do out[i]=v end
    return out
end

function M.isArray(t)
    if type(t) ~= 'table' then return false end
    local n=0
    for k,_ in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
        if k > n then n=k end
    end
    for i=1,n do if rawget(t,i)==nil then return false end end
    return true
end

function M.joinUrl(base, path)
    if string.match(path, '^https?://') or string.sub(path,1,1)=='#' then return path end
    local b=base
    while #b>0 and string.sub(b,-1)=='/' do b=string.sub(b,1,-2) end
    local p=path
    while #p>0 and string.sub(p,1,1)=='/' do p=string.sub(p,2) end
    if p=='' then return b..'/' end
    return b..'/'..p
end

function M.slugify(value)
    local s=string.lower(tostring(value))
    s=string.gsub(s, '[^%w%._~-]+', '-')
    s=string.gsub(s, '%-+', '-')
    s=string.gsub(s, '^%-+', '')
    s=string.gsub(s, '%-+$', '')
    return s
end

function M.pathExtension(path)
    return string.match(path, '%.([^%./]+)$')
end

function M.readRequired(path)
    local s=jess.fs.read(path)
    if s==nil then error(`read {path}: file does not exist`,0) end
    return s
end

function M.walk(root, files, prefix)
    files=files or {};prefix=prefix or ''
    if not jess.fs.isDir(root) then return files end
    local names=jess.fs.list(root);table.sort(names)
    for _,name in ipairs(names) do
        local path=jess.fs.join(root,name)
        local rel=prefix=='' and name or prefix..'/'..name
        if jess.fs.isDir(path) then M.walk(path,files,rel)
        elseif jess.fs.isFile(path) then table.insert(files,{path=path,relative=rel}) end
    end
    return files
end


function M.ensureParent(path)
    local parent=jess.fs.parent(path)
    if parent and parent~='' then jess.fs.createDir(parent) end
end

function M.write(path,data)
    M.ensureParent(path)
    return jess.fs.write(path,data)
end

function M.copyFile(from,to)
    M.ensureParent(to)
    return jess.fs.copy(from,to)
end

function M.copyTree(from,to)
    local count=0
    for _,entry in ipairs(M.walk(from)) do
        local dest=jess.fs.join(to,entry.relative)
        M.copyFile(entry.path,dest);count+=1
    end
    return count
end

local function segmentPattern(seg)
    local out={'^'}
    for i=1,#seg do
        local c=string.sub(seg,i,i)
        if c=='*' then table.insert(out,'[^/]*')
        elseif c=='?' then table.insert(out,'[^/]')
        elseif string.find('^$()%.[]+-',c,1,true) then table.insert(out,'%'..c)
        else table.insert(out,c) end
    end
    table.insert(out,'$');return table.concat(out)
end

function M.globMatch(path,glob)
    path=string.gsub(path,'\\','/');glob=string.gsub(glob,'\\','/')
    path=string.gsub(path,'^%./','');glob=string.gsub(glob,'^%./','')
    local ps,gs={},{}
    for x in string.gmatch(path..'/','(.-)/') do table.insert(ps,x) end
    for x in string.gmatch(glob..'/','(.-)/') do table.insert(gs,x) end
    local memo={}
    local function go(i,j)
        local key=i..':'..j;if memo[key]~=nil then return memo[key] end
        local ok=false
        if i>#gs then ok=j>#ps
        elseif gs[i]=='**' then ok=go(i+1,j) or (j<=#ps and go(i,j+1))
        elseif j<=#ps and string.match(ps[j],segmentPattern(gs[i])) then ok=go(i+1,j+1) end
        memo[key]=ok;return ok
    end
    return go(1,1)
end

function M.split(s, sep)
    sep=sep or ','
    local out={}
    if sep=='' then for i=1,#s do out[i]=string.sub(s,i,i) end;return out end
    local at=1
    while true do
        local i,j=string.find(s,sep,at,true)
        if not i then table.insert(out,string.sub(s,at));break end
        table.insert(out,string.sub(s,at,i-1));at=j+1
    end
    return out
end

return M
