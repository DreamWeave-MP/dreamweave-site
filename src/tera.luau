--!native
local Util=require './util'
local Expr=require './expr'
local JsonOut=require './json'
local JessJson=require '@jess/json'
local UNDEF=Expr.UNDEF
local M={}

local SafeMT={}
local function safe(v) return setmetatable({__dw_safe=true,value=tostring(v or '')},SafeMT) end
local function isSafe(v) return type(v)=='table' and rawget(v,'__dw_safe')==true end
M.safe=safe

local function valueString(v, escape)
    if v==UNDEF or v==nil or v==JessJson.null then return '' end
    if isSafe(v) then return v.value end
    if type(v)=='boolean' then return v and 'true' or 'false' end
    if type(v)=='table' then return tostring(v) end
    local s=tostring(v)
    return escape and Util.escapeHtml(s) or s
end

local function tokenise(text)
    local tokens={};local at=1;local trimNext=false
    local function push(kind,content)
        if kind=='text' and content=='' then return end
        table.insert(tokens,{kind=kind,content=content})
    end
    while at<=#text do
        local p1=string.find(text,'{{',at,true);local p2=string.find(text,'{%',at,true);local p3=string.find(text,'{#',at,true)
        local start=nil;local kind=nil;local close=nil
        for _,x in ipairs({{p1,'expr','}}'},{p2,'stmt','%}'},{p3,'comment','#}'}}) do
            if x[1] and (not start or x[1]<start) then start=x[1];kind=x[2];close=x[3] end
        end
        if not start then
            local tail=string.sub(text,at);if trimNext then tail=string.gsub(tail,'^%s+','');trimNext=false end;push('text',tail);break
        end
        local raw=string.sub(text,at,start-1);if trimNext then raw=string.gsub(raw,'^%s+','');trimNext=false end
        local trimLeft=string.sub(text,start,start+2)=='{{-' or string.sub(text,start,start+2)=='{%-' or string.sub(text,start,start+2)=='{#-'
        if trimLeft then raw=string.gsub(raw,'%s+$','') end
        push('text',raw)
        local bodyStart=start+2+(trimLeft and 1 or 0)
        local finish=string.find(text,close,bodyStart,true)
        if not finish then error('unterminated template tag',0) end
        local trimRight=finish>bodyStart and string.sub(text,finish-1,finish-1)=='-'
        local bodyEnd=finish-1-(trimRight and 1 or 0)
        local body=Util.trim(string.sub(text,bodyStart,bodyEnd))
        if kind~='comment' then push(kind,body) end
        trimNext=trimRight;at=finish+#close
    end
    return tokens
end

local Parser={};Parser.__index=Parser
local function word(s) return string.match(s,'^([%w_]+)') or '' end
function Parser.new(text,name) return setmetatable({tokens=tokenise(text),at=1,name=name},Parser) end
function Parser:seq(stops)
    local nodes={}
    while self.at<=#self.tokens do
        local t=self.tokens[self.at]
        if t.kind=='stmt' and stops[word(t.content)] then return nodes,t.content end
        self.at+=1
        if t.kind=='text' or t.kind=='expr' then table.insert(nodes,{kind=t.kind,value=t.content})
        elseif t.kind=='stmt' then
            local tag=word(t.content);local rest=Util.trim(string.sub(t.content,#tag+1))
            if tag=='if' then
                local branches={};local body,stop=self:seq({elif=true,['else']=true,endif=true});table.insert(branches,{expr=rest,body=body})
                while stop and word(stop)=='elif' do
                    self.at+=1;local e=Util.trim(string.sub(stop,5));body,stop=self:seq({elif=true,['else']=true,endif=true});table.insert(branches,{expr=e,body=body})
                end
                local otherwise={}
                if stop and word(stop)=='else' then self.at+=1;otherwise,stop=self:seq({endif=true}) end
                if not stop then error(`{self.name}: unterminated if`,0) end;self.at+=1
                table.insert(nodes,{kind='if',branches=branches,otherwise=otherwise})
            elseif tag=='for' then
                local vars,expr=string.match(rest,'^(.-)%s+in%s+(.+)$');if not vars then error(`{self.name}: malformed for`,0) end
                local names={};for n in string.gmatch(vars,'[%w_]+') do table.insert(names,n) end
                local body,stop=self:seq({['else']=true,endfor=true});local otherwise={}
                if stop and word(stop)=='else' then self.at+=1;otherwise,stop=self:seq({endfor=true}) end
                if not stop then error(`{self.name}: unterminated for`,0) end;self.at+=1
                table.insert(nodes,{kind='for',names=names,expr=expr,body=body,otherwise=otherwise})
            elseif tag=='set' or tag=='set_global' then
                local name,expr=string.match(rest,'^([%w_]+)%s*=%s*(.+)$');if not name then error(`{self.name}: malformed {tag}`,0) end
                table.insert(nodes,{kind='set',name=name,expr=expr,global=(tag=='set_global')})
            elseif tag=='block' then
                local name=string.match(rest,'^([%w_]+)');local body,stop=self:seq({endblock=true});if not stop then error(`{self.name}: unterminated block`,0) end;self.at+=1
                table.insert(nodes,{kind='block',name=name,body=body})
            elseif tag=='extends' then
                local path=string.match(rest,'^["\'](.-)["\']$');table.insert(nodes,{kind='extends',path=path})
            elseif tag=='import' then
                local path,as=string.match(rest,'^["\'](.-)["\']%s+as%s+([%w_]+)$');table.insert(nodes,{kind='import',path=path,as=as})
            elseif tag=='include' then
                local path=string.match(rest,'^["\'](.-)["\']$');table.insert(nodes,{kind='include',path=path})
            elseif tag=='macro' then
                local name,argsText=string.match(rest,'^([%w_]+)%s*%((.*)%)$');if not name then error(`{self.name}: malformed macro`,0) end
                local args={}
                if Util.trim(argsText)~='' then
                    local depth=0;local quote=nil;local start=1
                    for i=1,#argsText+1 do
                        local c=string.sub(argsText,i,i)
                        if quote then if c==quote and string.sub(argsText,i-1,i-1)~='\\' then quote=nil end
                        elseif c=='"' or c=="'" then quote=c
                        elseif c=='(' or c=='[' then depth+=1
                        elseif c==')' or c==']' then depth-=1
                        elseif (c==',' or i>#argsText) and depth==0 then
                            local part=Util.trim(string.sub(argsText,start,i-1));local an,def=string.match(part,'^([%w_]+)%s*=%s*(.+)$')
                            if an then table.insert(args,{name=an,default=def}) else table.insert(args,{name=part}) end;start=i+1
                        end
                    end
                end
                local body,stop=self:seq({endmacro=true});if not stop then error(`{self.name}: unterminated macro`,0) end;self.at+=1
                table.insert(nodes,{kind='macro',name=name,args=args,body=body})
            elseif tag=='break' or tag=='continue' then table.insert(nodes,{kind=tag})
            else
                -- Zola shortcode end markers can leak into templates copied as data; unsupported
                -- statement tags should fail loudly rather than silently generate bad HTML.
                error(`{self.name}: unsupported template statement: {t.content}`,0)
            end
        end
    end
    return nodes,nil
end
function Parser:parse() local nodes,stop=self:seq({});if stop then error(`{self.name}: unexpected {stop}`,0) end;return nodes end

local Env={};Env.__index=Env
function Env.new(engine,globals,parent)
    return setmetatable({engine=engine,globals=globals or {},locals={},parent=parent},Env)
end
function Env:child() return Env.new(self.engine,self.globals,self) end
function Env:get(name)
    local sep=string.find(name,'::',1,true)
    if sep then
        local ns=string.sub(name,1,sep-1);local member=string.sub(name,sep+2)
        local base=self:get(ns)
        if type(base)=='table' then local x=rawget(base,member);if x~=nil then return x end end
        return UNDEF
    end
    local v=rawget(self.locals,name);if v~=nil then return v end
    if self.parent then local p=self.parent:get(name);if p~=UNDEF then return p end end
    v=rawget(self.globals,name);if v~=nil then return v end
    v=self.engine.functions[name];if v then return v end
    return UNDEF
end
function Env:set(name,v,global)
    if global then self.globals[name]=v else self.locals[name]=v end
end
function Env:call(callee,args,named)
    if type(callee)=='table' and rawget(callee,'__dw_callable') then return callee.fn(args,named,self) end
    error('attempt to call a non-callable template value',0)
end

local function attr(v,name)
    v=Expr.unwrap(v);if v==UNDEF or v==nil or type(v)~='table' then return UNDEF end
    local x=rawget(v,name);return x==nil and UNDEF or x
end
local function compareKey(v,attribute)
    if attribute then v=attr(v,attribute) end
    v=Expr.unwrap(v);if v==UNDEF or v==nil then return '' end;return v
end
local function sortedCopy(items,attribute)
    local out={};for _,v in ipairs(items or {}) do table.insert(out,v) end
    table.sort(out,function(a,b)
        local x,y=compareKey(a,attribute),compareKey(b,attribute)
        if type(x)==type(y) and (type(x)=='number' or type(x)=='string') then return x<y end
        return tostring(x)<tostring(y)
    end);return out
end
local function stripTags(s) return (string.gsub(tostring(s),'<[^>]->','')) end

function Env:filter(name,value,args,named)
    local v=Expr.unwrap(value)
    if name=='safe' then return safe(v==UNDEF and '' or v)
    elseif name=='escape' or name=='escape_xml' then return safe(Util.escapeHtml(v==UNDEF and '' or v))
    elseif name=='default' then if v==UNDEF or v==nil then return named.value or args[1] end;return value
    elseif name=='length' then if type(v)=='string' then return #v elseif type(v)=='table' then local n=0;for _ in pairs(v) do n+=1 end;return n end;return 0
    elseif name=='pluralize' then return tonumber(v)==1 and '' or 's'
    elseif name=='capitalize' then local s=tostring(v or '');return string.upper(string.sub(s,1,1))..string.sub(s,2)
    elseif name=='lower' then return string.lower(tostring(v or ''))
    elseif name=='upper' then return string.upper(tostring(v or ''))
    elseif name=='trim' then return Util.trim(tostring(v or ''))
    elseif name=='trim_start' then return (string.gsub(tostring(v or ''),'^%s+',''))
    elseif name=='trim_end' then return (string.gsub(tostring(v or ''),'%s+$',''))
    elseif name=='trim_start_matches' then local pat=named.pat or args[1] or '';local s=tostring(v or '');while pat~='' and string.sub(s,1,#pat)==pat do s=string.sub(s,#pat+1) end;return s
    elseif name=='replace' then
        local from=tostring(named.from or args[1] or '');local to=tostring(named.to or args[2] or '')
        from=string.gsub(from,'([%^%$%(%)%%%.%[%]%*%+%-%?])','%%%1');to=string.gsub(to,'%%','%%%%')
        return (string.gsub(tostring(v or ''),from,to))
    elseif name=='split' then return Util.split(tostring(v or ''),tostring(named.pat or args[1] or ','))
    elseif name=='join' then local sep=tostring(named.sep or args[1] or '');local out={};for _,x in ipairs(v or {}) do table.insert(out,tostring(Expr.unwrap(x))) end;return table.concat(out,sep)
    elseif name=='first' then return type(v)=='table' and (v[1] or UNDEF) or UNDEF
    elseif name=='last' then return type(v)=='table' and (v[#v] or UNDEF) or UNDEF
    elseif name=='reverse' then local out={};for i=#(v or {}),1,-1 do table.insert(out,v[i]) end;return out
    elseif name=='sort' then return sortedCopy(v,named.attribute)
    elseif name=='slice' then local out={};local start=tonumber(named.start or args[1] or 0) or 0;local finish=tonumber(named['end'] or args[2] or #(v or {})) or #(v or {});if start<0 then start=#v+start end;if finish<0 then finish=#v+finish end;for i=start+1,math.min(finish,#v) do table.insert(out,v[i]) end;return out
    elseif name=='concat' then local out={};for _,x in ipairs(v or {}) do table.insert(out,x) end;local w=named['with'] or args[1];if type(w)=='table' and not isSafe(w) then for _,x in ipairs(w) do table.insert(out,x) end elseif w~=nil and w~=UNDEF then table.insert(out,w) end;return out
    elseif name=='filter' then
        local out={};local a=named.attribute;local wanted=named.value
        for _,x in ipairs(v or {}) do local q=a and attr(x,a) or x;if wanted~=nil then if Expr.unwrap(q)==Expr.unwrap(wanted) then table.insert(out,x) end elseif Expr.truthy(q) then table.insert(out,x) end end;return out
    elseif name=='map' then local out={};local a=named.attribute;for _,x in ipairs(v or {}) do table.insert(out,a and attr(x,a) or x) end;return out
    elseif name=='group_by' then local out={};local a=named.attribute;for _,x in ipairs(v or {}) do local k=tostring(Expr.unwrap(a and attr(x,a) or x));out[k]=out[k] or {};table.insert(out[k],x) end;return out
    elseif name=='get' then local key=named.key or args[1];return attr(v,Expr.unwrap(key))
    elseif name=='truncate' then local length=tonumber(named.length or args[1] or 255) or 255;local ending=tostring(named['end'] or '…');local s=tostring(v or '');if #s<=length then return s end;local keep=math.max(0,length-#ending);return string.sub(s,1,keep)..ending
    elseif name=='striptags' then return stripTags(v)
    elseif name=='json_encode' then return JsonOut.encode(v,false)
    elseif name=='int' then return math.floor(tonumber(v) or 0)
    elseif name=='filesizeformat' then local n=tonumber(v) or 0;if n<1024 then return `{n} B` elseif n<1048576 then return string.format('%.1f kB',n/1024) elseif n<1073741824 then return string.format('%.1f MB',n/1048576) else return string.format('%.1f GB',n/1073741824) end
    elseif name=='slugify' then return Util.slugify(v)
    elseif name=='markdown' then local md=self.engine.markdown;if not md then return tostring(v or '') end;return safe(md.render(tostring(v or ''),{inline=named.inline==true}))
    elseif name=='date' then return tostring(v or '')
    end
    error(`unsupported template filter: {name}`,0)
end
function Env:test(name,value,args,named)
    local v=Expr.unwrap(value)
    if name=='defined' then return v~=UNDEF
    elseif name=='undefined' then return v==UNDEF
    elseif name=='starting_with' then return type(v)=='string' and string.sub(v,1,#tostring(args[1] or ''))==tostring(args[1] or '')
    elseif name=='ending_with' then local q=tostring(args[1] or '');return type(v)=='string' and string.sub(v,-#q)==q
    elseif name=='matching' then local re=jess.regex.new(tostring(args[1] or ''));return re:isMatch(tostring(v or ''))
    elseif name=='containing' then if type(v)=='string' then return string.find(v,tostring(args[1] or ''),1,true)~=nil elseif type(v)=='table' then for _,x in pairs(v) do if x==args[1] then return true end end end;return false
    elseif name=='even' then return (tonumber(v) or 0)%2==0
    elseif name=='odd' then return (tonumber(v) or 0)%2~=0
    elseif name=='string' then return type(v)=='string'
    elseif name=='number' then return type(v)=='number'
    elseif name=='iterable' then return type(v)=='table' or type(v)=='string'
    end
    error(`unsupported template test: {name}`,0)
end

local Engine={};Engine.__index=Engine
local function callable(fn) return {__dw_callable=true,fn=fn} end
function Engine.new(root,options)
    options=options or {}
    local self=setmetatable({root=root,templateRoot=jess.fs.join(root,options.templateDir or 'templates'),cache={},functions={},markdown=options.markdown,site=options.site},Engine)
    self.functions.range=callable(function(_,named)
        local start=tonumber(named.start or 0) or 0;local finish=tonumber(named['end'] or 0) or 0;local step=tonumber(named.step_by or 1) or 1;local out={};for i=start,finish-step,step do table.insert(out,i) end;return out
    end)
    self.functions.throw=callable(function(args) error(tostring(args[1] or 'template threw'),0) end)
    return self
end
function Engine:addFunction(name,fn) self.functions[name]=callable(fn) end
function Engine:parse(name)
    local hit=self.cache[name];if hit then return hit end
    local path=jess.fs.join(self.templateRoot,name);local text=Util.readRequired(path);local ast=Parser.new(text,name):parse();self.cache[name]=ast;return ast
end

local function collectMacros(nodes,out)
    for _,n in ipairs(nodes) do if n.kind=='macro' then out[n.name]=n end end;return out
end
local function findExtends(nodes) for _,n in ipairs(nodes) do if n.kind=='extends' then return n.path end end end
local function collectBlocks(nodes,out) out=out or {};for _,n in ipairs(nodes) do if n.kind=='block' then out[n.name]=n end end;return out end

function Engine:namespace(name,caller)
    local ast=self:parse(name);local macros=collectMacros(ast,{})
    local ns={}
    for macroName,macro in pairs(macros) do
        ns[macroName]=callable(function(args,named)
            self._macroDepth=(self._macroDepth or 0)+1
            if self._macroDepth>128 then error('template macro recursion near '..name..'::'..macroName,0) end
            local env=Env.new(self,caller.globals,caller)
            for i,spec in ipairs(macro.args) do
                local v=named[spec.name];if v==nil then v=args[i] end
                if v==nil and spec.default then v=Expr.eval(spec.default,env) end
                if v==nil then v=UNDEF end;env:set(spec.name,v,false)
            end
            self:prepare(ast,env)
            local ok,text=pcall(function() return self:renderNodes(macro.body,env,nil) end)
            self._macroDepth-=1
            if not ok then error(name..'::'..macroName..': '..tostring(text),0) end
            return safe(text)
        end)
    end
    return ns
end
function Engine:prepare(nodes,env)
    for _,n in ipairs(nodes) do
        if n.kind=='import' then env:set(n.as,self:namespace(n.path,env),false) end
    end
end
local function iterPairs(v)
    if type(v)~='table' then return {} end
    local array=true;local max=0;local count=0
    for k in pairs(v) do if type(k)~='number' then array=false;break end;max=math.max(max,k);count+=1 end
    local rows={}
    if array and max==count then for i,x in ipairs(v) do table.insert(rows,{i,x}) end
    else local keys={};for k in pairs(v) do table.insert(keys,k) end;table.sort(keys,function(a,b)return tostring(a)<tostring(b) end);for _,k in ipairs(keys) do table.insert(rows,{k,v[k]}) end end
    return rows
end

local function evalExpr(text,env)
    local ok,value=pcall(function() return Expr.eval(text,env) end)
    if not ok then error('template expression ['..tostring(text)..']: '..tostring(value),0) end
    return value
end

function Engine:renderNodes(nodes,env,blocks)
    local out={}
    for _,n in ipairs(nodes) do
        if n.kind=='text' then table.insert(out,n.value)
        elseif n.kind=='expr' then table.insert(out,valueString(evalExpr(n.value,env),true))
        elseif n.kind=='set' then env:set(n.name,evalExpr(n.expr,env),n.global)
        elseif n.kind=='import' or n.kind=='macro' or n.kind=='extends' then
        elseif n.kind=='include' then table.insert(out,self:renderTemplate(n.path,env,nil))
        elseif n.kind=='if' then
            local done=false
            for _,b in ipairs(n.branches) do if Expr.truthy(evalExpr(b.expr,env)) then local s,signal=self:renderNodes(b.body,env,blocks);table.insert(out,s);if signal then return table.concat(out),signal end;done=true;break end end
            if not done then local s,signal=self:renderNodes(n.otherwise,env,blocks);table.insert(out,s);if signal then return table.concat(out),signal end end
        elseif n.kind=='for' then
            local v=evalExpr(n.expr,env);local rows=iterPairs(Expr.unwrap(v));if #rows==0 then local s,signal=self:renderNodes(n.otherwise,env,blocks);table.insert(out,s);if signal then return table.concat(out),signal end
            else
                for idx,row in ipairs(rows) do
                    local e=env:child();if #n.names==1 then e:set(n.names[1],row[2],false) else e:set(n.names[1],row[1],false);e:set(n.names[2],row[2],false) end
                    e:set('loop',{index=idx,index0=idx-1,first=idx==1,last=idx==#rows,length=#rows},false)
                    local s,signal=self:renderNodes(n.body,e,blocks);table.insert(out,s);if signal=='break' then break elseif signal~='continue' and signal then return table.concat(out),signal end
                end
            end
        elseif n.kind=='block' then
            local override=blocks and blocks[n.name]
            if override and override~=n then
                local e=env:child();e:set('super',callable(function() return safe(self:renderNodes(n.body,env:child(),blocks)) end),false)
                local s,signal=self:renderNodes(override.body,e,blocks);table.insert(out,s);if signal then return table.concat(out),signal end
            else local s,signal=self:renderNodes(n.body,env:child(),blocks);table.insert(out,s);if signal then return table.concat(out),signal end end
        elseif n.kind=='break' then return table.concat(out),'break'
        elseif n.kind=='continue' then return table.concat(out),'continue'
        end
    end
    return table.concat(out),nil
end
function Engine:renderTemplate(name,envOrVars,overrides)
    local ast=self:parse(name);local env
    if getmetatable(envOrVars)==Env then env=envOrVars:child() else env=Env.new(self,envOrVars or {}) end
    self:prepare(ast,env)
    local parent=findExtends(ast)
    if parent then
        local blocks=overrides or {};for k,v in pairs(collectBlocks(ast,{})) do blocks[k]=v end
        return self:renderTemplate(parent,env,blocks)
    end
    local text=self:renderNodes(ast,env,overrides);return text
end
function Engine:render(name,vars) return self:renderTemplate(name,vars,nil) end
M.Engine=Engine;M.Env=Env;M.UNDEF=UNDEF
return M
