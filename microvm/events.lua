-- Display-only journal: no network, credentials, or dependency on an attached UI.
local uv=require('luv');local json=require('cjson');local M={}
local function copy(value,depth)
 depth=depth or 0
 if type(value)=='string' then return #value>16000 and value:sub(1,16000)..' [display truncated]' or value end
 if type(value)=='boolean' or type(value)=='number' then return value end
 if type(value)~='table' or depth>5 then return nil end
 local out={};local count=0
 for k,v in pairs(value) do
  if type(k)=='string' or type(k)=='number' then
   count=count+1;if count>128 then break end
   out[k]=copy(v,depth+1)
  end
 end
 return out
end
M.copy=copy
function M.open(root,id,begin)
 assert(id:match('^[%w-]+$'))
 uv.fs_mkdir(root..'/events',448)
 local path=root..'/events/'..id..'.jsonl'
 local file,err=io.open(path,'w');if not file then return nil,err end
 file:setvbuf('no');uv.fs_chmod(path,384)
 local self={id=id,seq=0,bytes=0,pending='',last=uv.hrtime(),file=file}
 function self:write(kind,data,force)
  if self.failed then return end
  if self.bytes>8*1024*1024 and not force then
   if not self.limited then self.limited=true;self:write('gap',{text='Live display limit reached; completed conversation remains available.'},true) end
   return
  end
  local ok,why=pcall(function()
   local item=copy(data or {});self.seq=self.seq+1;item.kind=kind;item.id=id;item.seq=self.seq;item.time=uv.hrtime()/1e9
   local line=json.encode(item)..'\n'
   if #line>131072 then line=json.encode({id=id,seq=self.seq,kind='gap',text='Oversized live event omitted; full details remain in the session log.'})..'\n' end
   assert(file:write(line));self.bytes=self.bytes+#line
  end)
  if not ok then self.failed=tostring(why);print('Live display unavailable: '..self.failed) end
 end
 function self:flush()
  if self.pending~='' then local text=self.pending;self.pending='';self:write('token',{text=text}) end
  self.last=uv.hrtime()
 end
 function self:emit(kind,data) self:flush();self:write(kind,data,kind=='finish') end
 function self:token(text)
  self.pending=self.pending..text
  if #self.pending>=4096 or uv.hrtime()-self.last>=80000000 then self:flush() end
 end
 function self:tick() if uv.hrtime()-self.last>=80000000 then self:flush() end end
 function self:close() self:flush();file:close() end
 self:emit('begin',begin)
 -- Keep current and two previous journals. Workspace checkpoints exclude them.
 local entries={};local scan=uv.fs_scandir(root..'/events')
 while scan do local name=uv.fs_scandir_next(scan);if not name then break end
  if name:match('^[%w-]+%.jsonl$') and name~=id..'.jsonl' then
   local stat=uv.fs_stat(root..'/events/'..name);if stat then entries[#entries+1]={name=name,time=stat.mtime.sec+stat.mtime.nsec/1e9} end
  end
 end
 table.sort(entries,function(a,b)return a.time>b.time end)
 for i=3,#entries do os.remove(root..'/events/'..entries[i].name) end
 return self
end
return M
