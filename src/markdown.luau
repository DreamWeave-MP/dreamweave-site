--!native
local Util=require './util'
local M={}

local function asciiWord(ch)
    if ch=='' then return false end
    local b=string.byte(ch);return (b>=48 and b<=57) or (b>=65 and b<=90) or (b>=97 and b<=122)
end
local function linkFinish(text,start)
    local depth=0
    for i=start,#text do local ch=string.sub(text,i,i);if ch=='(' then depth+=1 elseif ch==')' then if depth==0 then return i end;depth-=1 end end
end
local function underscoreClose(text,start)
    local search=start
    while true do local finish=string.find(text,'_',search,true);if not finish then return nil end
        local before=finish>1 and string.sub(text,finish-1,finish-1) or '';local after=finish<#text and string.sub(text,finish+1,finish+1) or ''
        if not (asciiWord(before) and asciiWord(after)) then return finish end;search=finish+1 end
end
local function splitHref(raw)
    raw=Util.trim(raw);local href,title=string.match(raw,'^(.-)%s+["\'](.-)["\']%s*$')
    if href then return Util.trim(href),title end
    return raw,nil
end
local function inline(text,options)
    options=options or {};local out={};local at=1
    while at<=#text do
        local two=string.sub(text,at,at+1);local ch=string.sub(text,at,at)
        if not string.find('![`*_~<\\',ch,1,true) then
            local nextSpecial=string.find(text,'[!%[`*_~<\\]',at+1);local stop=nextSpecial or (#text+1)
            table.insert(out,Util.escapeHtml(string.sub(text,at,stop-1)));at=stop;continue
        end
        if two=='![' then
            local close=string.find(text,'](',at+2,true);local finish=close and linkFinish(text,close+2) or nil
            if finish then
                local alt=string.sub(text,at+2,close-1);local href,title=splitHref(string.sub(text,close+2,finish-1));if options.resolveLink then href=options.resolveLink(href,true) or href end
                local tag='<img src="'..Util.escapeAttribute(href)..'" alt="'..Util.escapeAttribute(alt)..'"'
                if title then tag..=' title="'..Util.escapeAttribute(title)..'"' end;tag..='>'
                table.insert(out,tag);at=finish+1;continue
            end
        elseif ch=='[' then
            local close=string.find(text,'](',at+1,true);local finish=close and linkFinish(text,close+2) or nil
            if finish then
                local label=string.sub(text,at+1,close-1);local href,title=splitHref(string.sub(text,close+2,finish-1));if options.resolveLink then href=options.resolveLink(href,false) or href end
                local tag='<a href="'..Util.escapeAttribute(href)..'"';if title then tag..=' title="'..Util.escapeAttribute(title)..'"' end;tag..='>'..inline(label,options)..'</a>'
                table.insert(out,tag);at=finish+1;continue
            end
        elseif ch=='`' then
            local run=1;while string.sub(text,at+run,at+run)=='`' do run+=1 end;local marker=string.rep('`',run);local finish=string.find(text,marker,at+run,true)
            if finish then table.insert(out,'<code>'..Util.escapeHtml(string.sub(text,at+run,finish-1))..'</code>');at=finish+run;continue end
        elseif two=='**' or two=='__' then
            local finish=string.find(text,two,at+2,true);if finish then table.insert(out,'<strong>'..inline(string.sub(text,at+2,finish-1),options)..'</strong>');at=finish+2;continue end
        elseif two=='~~' then
            local finish=string.find(text,'~~',at+2,true);if finish then table.insert(out,'<del>'..inline(string.sub(text,at+2,finish-1),options)..'</del>');at=finish+2;continue end
        elseif ch=='*' or ch=='_' then
            local prev=at>1 and string.sub(text,at-1,at-1) or '';local foll=at<#text and string.sub(text,at+1,at+1) or '';local intraword=ch=='_' and asciiWord(prev) and asciiWord(foll)
            local finish=intraword and nil or (ch=='_' and underscoreClose(text,at+1) or string.find(text,ch,at+1,true))
            if finish then table.insert(out,'<em>'..inline(string.sub(text,at+1,finish-1),options)..'</em>');at=finish+1;continue end
        elseif ch=='<' then
            local finish=string.find(text,'>',at+1,true);if finish then
                local raw=string.sub(text,at,finish)
                local auto=string.match(raw,'^<(https?://[^>]+)>$')
                if auto then table.insert(out,'<a href="'..Util.escapeAttribute(auto)..'">'..Util.escapeHtml(auto)..'</a>') else table.insert(out,raw) end
                at=finish+1;continue
            end
        elseif ch=='\\' and at<#text then
            local e=string.sub(text,at+1,at+1);if string.find('\\`*_{}[]()#+-.!<>',e,1,true) then table.insert(out,Util.escapeHtml(e));at+=2;continue end
        end
        table.insert(out,Util.escapeHtml(ch));at+=1
    end
    return table.concat(out)
end
M.inline=inline

local function isFence(line) local m,lang=string.match(line,'^%s*(```+)%s*(.-)%s*$');if not m then m,lang=string.match(line,'^%s*(~~~+)%s*(.-)%s*$') end;return m,lang end
local function listItem(line)
    local indent,mark,value=string.match(line,'^(%s*)([-+*])%s+(.+)$');if mark then return 'ul',value,#indent end
    indent,mark,value=string.match(line,'^(%s*)(%d+[.)])%s+(.+)$');if mark then return 'ol',value,#indent end
end
local function heading(line) local hashes,body=string.match(line,'^%s*(#+)%s+(.+)$');if hashes and #hashes<=6 then body=string.gsub(body,'%s+#+%s*$','');return #hashes,body end end
local function hr(line) local s=string.gsub(line,'%s','');return s=='---' or s=='***' or s=='___' or string.match(s,'^%-+%-+%-+$')~=nil end
local function tableSep(line) return string.find(line,'|',1,true)~=nil and string.gsub(line,'[|:%- %t]','')=='' and string.find(line,'%-')~=nil end
local function cells(line) line=Util.trim(line);if string.sub(line,1,1)=='|' then line=string.sub(line,2) end;if string.sub(line,-1)=='|' then line=string.sub(line,1,-2) end;local out={};for c in string.gmatch(line..'|','(.-)|') do table.insert(out,Util.trim(c)) end;return out end
local function slug(title,seen)
    -- Zola's default anchor strategy is classic slugification. Preserve characters inside
    -- code spans long enough for '_' to become '-' (rather than deleting it as emphasis syntax).
    local plain=string.gsub(title,'<[^>]->','')
    plain=string.gsub(plain,'`','')
    plain=string.gsub(plain,'%*','')
    plain=string.gsub(plain,'~','')
    plain=string.lower(plain)
    local s=string.gsub(plain,'[^%w]+','-')
    s=string.gsub(s,'%-+','-');s=string.gsub(s,'^%-+','');s=string.gsub(s,'%-+$','')
    if s=='' then s='section' end
    local base=s;local n=1;while seen[s] do n+=1;s=base..'-'..n end;seen[s]=true;return s
end

function M.renderDocument(text,options)
    options=options or {};text=string.gsub(text,'\r\n?','\n')
    local lines={};for line in string.gmatch(text..'\n','(.-)\n') do table.insert(lines,line) end
    local out={};local toc={};local seen={};local i=1
    while i<=#lines do
        local line=lines[i];if Util.trim(line)=='' then i+=1;continue end
        local marker,lang=isFence(line)
        if marker then
            local body={};i+=1;while i<=#lines and not string.match(lines[i],'^%s*'..string.gsub(marker,'([%^%$%(%)%%%.%[%]%*%+%-%?])','%%%1')) do table.insert(body,lines[i]);i+=1 end;if i<=#lines then i+=1 end
            local cls=lang~='' and ' class="language-'..Util.escapeAttribute(Util.trim(lang))..'"' or ''
            table.insert(out,'<pre><code'..cls..'>'..Util.escapeHtml(table.concat(body,'\n'))..'\n</code></pre>\n');continue
        end
        local level,title=heading(line)
        if level then
            local id=slug(title,seen);local htmlTitle=inline(title,options);table.insert(toc,{level=level,id=id,title=string.gsub(title,'[`*_~]',''),permalink='#'..id})
            local anchor='';if options.insertAnchorLinks then anchor='<a class="zola-anchor" href="#'..id..'" aria-label="Anchor link for: '..Util.escapeAttribute(title)..'">§</a>' end
            if options.insertAnchorLinks=='left' then table.insert(out,`<h{level} id="{id}">{anchor}{htmlTitle}</h{level}>\n`) else table.insert(out,`<h{level} id="{id}">{htmlTitle}{anchor}</h{level}>\n`) end;i+=1;continue
        end
        if i<#lines then
            local next=Util.trim(lines[i+1]);if string.match(next,'^=+$') or string.match(next,'^%-+$') then
                local lv=string.sub(next,1,1)=='=' and 1 or 2;local id=slug(line,seen);table.insert(toc,{level=lv,id=id,title=line,permalink='#'..id});table.insert(out,`<h{lv} id="{id}">{inline(line,options)}</h{lv}>\n`);i+=2;continue
            end
        end
        if hr(line) then table.insert(out,'<hr>\n');i+=1;continue end
        local kind,first,indent=listItem(line)
        if kind then
            table.insert(out,`<{kind}>\n`);while i<=#lines do local k,item,ind=listItem(lines[i]);if k~=kind or ind~=indent then break end;table.insert(out,'<li>'..inline(item,options)..'</li>\n');i+=1 end;table.insert(out,`</{kind}>\n`);continue
        end
        if string.match(line,'^%s*>') then local q={};while i<=#lines do local x=string.match(lines[i],'^%s*>%s?(.*)$');if x==nil then break end;table.insert(q,x);i+=1 end;local inner=M.renderDocument(table.concat(q,'\n'),options);table.insert(out,'<blockquote>\n'..inner.html..'</blockquote>\n');continue end
        if string.match(Util.trim(line),'^<[%a!/][^>]*>') then local raw={line};i+=1;while i<=#lines and Util.trim(lines[i])~='' do table.insert(raw,lines[i]);i+=1 end;table.insert(out,table.concat(raw,'\n')..'\n');continue end
        if i<#lines and string.find(line,'|',1,true) and tableSep(lines[i+1]) then
            local headers=cells(line);i+=2;table.insert(out,'<table><thead><tr>');for _,c in ipairs(headers) do table.insert(out,'<th>'..inline(c,options)..'</th>') end;table.insert(out,'</tr></thead><tbody>')
            while i<=#lines and Util.trim(lines[i])~='' and string.find(lines[i],'|',1,true) do table.insert(out,'<tr>');for _,c in ipairs(cells(lines[i])) do table.insert(out,'<td>'..inline(c,options)..'</td>') end;table.insert(out,'</tr>');i+=1 end;table.insert(out,'</tbody></table>\n');continue
        end
        local para={line};i+=1
        while i<=#lines and Util.trim(lines[i])~='' do local n=lines[i];if isFence(n) or heading(n) or hr(n) or listItem(n) or string.match(n,'^%s*>') then break end;table.insert(para,n);i+=1 end
        local joined=table.concat(para,'\n');joined=string.gsub(joined,'  \n','<br>\n');table.insert(out,'<p>'..inline(joined,options)..'</p>\n')
    end
    return {html=table.concat(out),toc=toc}
end
function M.render(text,options)
    options=options or {}
    if options.inline then return inline(tostring(text or ''),options) end
    return M.renderDocument(text,options).html
end
return M
