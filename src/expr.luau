--!native
local Util=require './util'
local JessJson=require '@jess/json'
local M={}
local UNDEF={__dw_undefined=true};M.UNDEF=UNDEF

local function isSpace(c) return c==' ' or c=='\t' or c=='\r' or c=='\n' end
local function isDigit(c) local b=string.byte(c or '');return b and b>=48 and b<=57 end
local function isAlpha(c)
    local b=string.byte(c or '')
    return c=='_' or (b and ((b>=65 and b<=90) or (b>=97 and b<=122)))
end
local function isAlnum(c) return isAlpha(c) or isDigit(c) end

local function lex(text)
    local out={};local i=1;local n=#text
    local function add(kind,value) table.insert(out,{kind=kind,value=value}) end
    while i<=n do
        local c=string.sub(text,i,i)
        if isSpace(c) then i+=1;continue end
        if c=='"' or c=="'" then
            local q=c;i+=1;local b={}
            while i<=n do
                c=string.sub(text,i,i)
                if c==q then i+=1;break end
                if c=='\\' and i<n then
                    local d=string.sub(text,i+1,i+1)
                    local map={n='\n',r='\r',t='\t',['\\']='\\',['"']='"',["'"]="'"}
                    table.insert(b,map[d] or d);i+=2
                else table.insert(b,c);i+=1 end
            end
            add('string',table.concat(b));continue
        end
        if isDigit(c) then
            local j=i+1
            while j<=n and (isDigit(string.sub(text,j,j)) or string.sub(text,j,j)=='.') do j+=1 end
            local raw=string.sub(text,i,j-1);add('number',tonumber(raw));i=j;continue
        end
        if isAlpha(c) then
            local j=i+1
            while j<=n do
                local d=string.sub(text,j,j)
                if isAlnum(d) then j+=1
                elseif d==':' and string.sub(text,j,j+1)=='::' then j+=2
                else break end
            end
            add('id',string.sub(text,i,j-1));i=j;continue
        end
        local two=string.sub(text,i,i+1)
        if two=='==' or two=='!=' or two=='>=' or two=='<=' or two=='//' then add('op',two);i+=2;continue end
        if string.find('()[],.=|~+-*/%<>',c,1,true) then add('op',c);i+=1;continue end
        error(`template expression: unexpected character {c} in {text}`,0)
    end
    add('eof','eof');return out
end

local Parser={};Parser.__index=Parser
function Parser.new(text) return setmetatable({tokens=lex(text),at=1,text=text},Parser) end
function Parser:peek(value)
    local t=self.tokens[self.at];if value==nil then return t end
    if t.kind=='string' or t.kind=='number' then return false end
    return t.value==value
end
function Parser:take(value)
    local t=self.tokens[self.at]
    if value and t.value~=value then error(`template expression: expected {value}, got {t.value} in {self.text}`,0) end
    self.at+=1;return t
end
function Parser:accept(value) if self:peek(value) then self.at+=1;return true end;return false end

local function node(kind,a,b,c) return {kind=kind,a=a,b=b,c=c} end

function Parser:parseArgs()
    local args={};local named={}
    if self:accept(')') then return args,named end
    while true do
        if self:peek().kind=='id' and self.tokens[self.at+1] and self.tokens[self.at+1].value=='=' then
            local k=self:take().value;self:take('=');named[k]=self:parseOr()
        else table.insert(args,self:parseOr()) end
        if self:accept(')') then break end
        self:take(',')
    end
    return args,named
end

function Parser:parsePrimary()
    local t=self:peek();local v
    if t.kind=='string' then self:take();v=node('lit',t.value)
    elseif t.kind=='number' then self:take();v=node('lit',t.value)
    elseif t.kind=='id' then
        self:take()
        if t.value=='true' then v=node('lit',true)
        elseif t.value=='false' then v=node('lit',false)
        elseif t.value=='none' or t.value=='null' then v=node('lit',nil)
        else v=node('var',t.value) end
    elseif self:accept('(') then v=self:parseOr();self:take(')')
    elseif self:accept('[') then
        local items={}
        if not self:accept(']') then
            while true do table.insert(items,self:parseOr());if self:accept(']') then break end;self:take(',');if self:accept(']') then break end end
        end
        v=node('array',items)
    else error(`template expression: unexpected token {t.value} in {self.text}`,0) end
    while true do
        if self:accept('.') then v=node('get',v,self:take().value)
        elseif self:accept('[') then local key=self:parseOr();self:take(']');v=node('index',v,key)
        elseif self:accept('(') then local args,named=self:parseArgs();v=node('call',v,args,named)
        elseif self:accept('|') then
            local name=self:take().value;local args,named={},{}
            if self:accept('(') then args,named=self:parseArgs() end
            v=node('filter',v,name,{args=args,named=named})
        else break end
    end
    return v
end

function Parser:parseUnary()
    if self:accept('not') then return node('unary','not',self:parseUnary()) end
    if self:accept('-') then return node('unary','-',self:parseUnary()) end
    return self:parsePrimary()
end
function Parser:parseMul()
    local v=self:parseUnary()
    while self:peek('*') or self:peek('/') or self:peek('//') or self:peek('%') do local op=self:take().value;v=node('bin',op,v,self:parseUnary()) end
    return v
end
function Parser:parseAdd()
    local v=self:parseMul()
    while self:peek('+') or self:peek('-') or self:peek('~') do local op=self:take().value;v=node('bin',op,v,self:parseMul()) end
    return v
end
function Parser:parseCompare()
    local v=self:parseAdd()
    while true do
        local op=nil
        if self:peek('==') or self:peek('!=') or self:peek('>=') or self:peek('<=') or self:peek('>') or self:peek('<') or self:peek('in') then op=self:take().value
        elseif self:peek('not') and self.tokens[self.at+1] and self.tokens[self.at+1].value=='in' then self:take();self:take();op='not in'
        elseif self:accept('is') then
            local neg=self:accept('not')
            local name=self:take().value;local args,named={},{}
            if self:accept('(') then args,named=self:parseArgs() end
            v={kind='test',value=v,name=name,args=args,named=named,neg=neg};continue
        else break end
        v=node('bin',op,v,self:parseAdd())
    end
    return v
end
function Parser:parseAnd() local v=self:parseCompare();while self:accept('and') do v=node('bin','and',v,self:parseCompare()) end;return v end
function Parser:parseOr() local v=self:parseAnd();while self:accept('or') do v=node('bin','or',v,self:parseAnd()) end;return v end
function Parser:parse() local v=self:parseOr();if self:peek().kind~='eof' then error(`template expression: trailing token {self:peek().value} in {self.text}`,0) end;return v end

local function truthy(v)
    if v==nil or v==false or v==UNDEF or v==JessJson.null then return false end
    if type(v)=='table' and rawget(v,'__dw_safe') then v=v.value end
    if type(v)=='string' then return #v>0 end
    if type(v)=='number' then return v~=0 end
    if type(v)=='table' then return next(v)~=nil end
    return true
end;M.truthy=truthy
local function unwrap(v) if v==JessJson.null then return nil end;if type(v)=='table' and rawget(v,'__dw_safe') then return v.value end return v end;M.unwrap=unwrap
local function getAttr(v,k)
    v=unwrap(v)
    if v==nil or v==UNDEF then return UNDEF end
    if type(v)=='table' then local x=rawget(v,k);if x==nil then return UNDEF end;return x end
    return UNDEF
end
M.getAttr=getAttr

local function contains(container,item)
    container=unwrap(container);item=unwrap(item)
    if type(container)=='string' then return string.find(container,tostring(item),1,true)~=nil end
    if type(container)=='table' then
        for k,v in pairs(container) do if v==item or k==item then return true end end
    end
    return false
end

local function evalArgs(nodes, env)
    local out={};for i,n in ipairs(nodes or {}) do out[i]=M.evalNode(n,env) end
    return out
end
local function evalNamed(nodes, env)
    local out={};for k,n in pairs(nodes or {}) do out[k]=M.evalNode(n,env) end
    return out
end

function M.evalNode(n,env)
    if n.kind=='lit' then return n.a
    elseif n.kind=='var' then return env:get(n.a)
    elseif n.kind=='array' then local a={};for _,x in ipairs(n.a) do table.insert(a,M.evalNode(x,env)) end;return a
    elseif n.kind=='get' then return getAttr(M.evalNode(n.a,env),n.b)
    elseif n.kind=='index' then return getAttr(M.evalNode(n.a,env),unwrap(M.evalNode(n.b,env)))
    elseif n.kind=='unary' then
        local v=M.evalNode(n.b,env);if n.a=='not' then return not truthy(v) elseif n.a=='-' then return -(tonumber(unwrap(v)) or 0) end
    elseif n.kind=='call' then
        local callee=M.evalNode(n.a,env);return env:call(callee,evalArgs(n.b,env),evalNamed(n.c,env))
    elseif n.kind=='filter' then
        return env:filter(n.b,M.evalNode(n.a,env),evalArgs(n.c.args,env),evalNamed(n.c.named,env))
    elseif n.kind=='test' then
        local ok=env:test(n.name,M.evalNode(n.value,env),evalArgs(n.args,env),evalNamed(n.named,env));return n.neg and not ok or ok
    elseif n.kind=='bin' then
        if n.a=='and' then local l=M.evalNode(n.b,env);if not truthy(l) then return l end;return M.evalNode(n.c,env) end
        if n.a=='or' then local l=M.evalNode(n.b,env);if truthy(l) then return l end;return M.evalNode(n.c,env) end
        local l=unwrap(M.evalNode(n.b,env));local r=unwrap(M.evalNode(n.c,env));local op=n.a
        if op=='~' then return (l==nil or l==UNDEF) and '' or tostring(l) .. ((r==nil or r==UNDEF) and '' or tostring(r))
        elseif op=='+' then return (tonumber(l) or 0)+(tonumber(r) or 0)
        elseif op=='-' then return (tonumber(l) or 0)-(tonumber(r) or 0)
        elseif op=='*' then return (tonumber(l) or 0)*(tonumber(r) or 0)
        elseif op=='/' then return (tonumber(l) or 0)/(tonumber(r) or 1)
        elseif op=='//' then return math.floor((tonumber(l) or 0)/(tonumber(r) or 1))
        elseif op=='%' then return (tonumber(l) or 0)%(tonumber(r) or 1)
        elseif op=='==' then return l==r
        elseif op=='!=' then return l~=r
        elseif op=='>' then return l>r
        elseif op=='<' then return l<r
        elseif op=='>=' then return l>=r
        elseif op=='<=' then return l<=r
        elseif op=='in' then return contains(r,l)
        elseif op=='not in' then return not contains(r,l)
        end
    end
    return UNDEF
end

local cache={}
function M.compile(text)
    local hit=cache[text];if hit then return hit end
    local ast=Parser.new(Util.trim(text)):parse();cache[text]=ast;return ast
end
function M.eval(text,env) return M.evalNode(M.compile(text),env) end
return M
