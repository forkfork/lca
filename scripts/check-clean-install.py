#!/usr/bin/env python3
"""Build an isolated copy/tree and retain build, module-origin and test evidence."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

parser=argparse.ArgumentParser()
parser.add_argument('output',type=Path)
parser.add_argument('--luarocks',default=os.environ.get('LUAROCKS','luarocks'))
a=parser.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[1];source=out/'source';source.mkdir();tree=out/'rocks'
files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
for name in filter(None,files):
 p=root/name
 if p.is_file():
  dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
env=os.environ.copy()
for key in list(env):
 if key.startswith('LUA_PATH') or key.startswith('LUA_CPATH'):env.pop(key)
# Fresh LuaRocks dependencies go into this tree, not the user's installation.
config=out/'luarocks-config.lua'
config.write_text('rocks_trees = { '+repr(str(tree))+' }\n')
env['LUAROCKS_CONFIG']=str(config)
def run(label,command,cwd,environment):
 with (out/(label+'.log')).open('w') as log:
  r=subprocess.run(command,cwd=cwd,env=environment,stdout=log,stderr=subprocess.STDOUT)
 if r.returncode:
  print((out/(label+'.log')).read_text()[-12000:]);raise SystemExit(r.returncode)
 print('PASS '+label,flush=True)
run('install',[a.luarocks,'--lua-version=5.5','--tree='+str(tree),'make','lca-dev-1.rockspec','--deps-mode=one'],source,env)
lua_paths=[str(tree/'share/lua/5.5/?.lua'),str(tree/'share/lua/5.5/?/init.lua')]
# LuaRocks' loader belongs to the selected build tool, not the application.
rocks_binary=Path(shutil.which(a.luarocks) or a.luarocks).resolve()
tool_modules=rocks_binary.parent.parent/'share/lua/5.5'
if (tool_modules/'luarocks/loader.lua').is_file():
 lua_paths.append(str(tool_modules/'?.lua'))
env['LUA_PATH']=';'.join(lua_paths)+';;'
env['LUA_CPATH']=str(tree/'lib/lua/5.5/?.so')+';;'
# Check origins outside the source directory: no checkout fallback can pass.
probe='require("luarocks.loader")\nlocal expected='+json.dumps(str(tree))+'\n'+'''for _,m in ipairs({'agent.jobs','agent.job_supervisor','agent.crypto','agent.file_lock','luv','cjson','socket','ssl'}) do
 local path=package.searchpath(m,package.path) or package.searchpath(m,package.cpath)
 assert(path and path:sub(1,#expected)==expected,m..' escaped isolated tree: '..tostring(path))
 require(m);print(m,path)
end'''
run('module-origins',['lua5.5','-e',probe],out,env)
run('cli',[str(tree/'bin/lca'),'--help'],out,env)
run('full-suite',[sys.executable,'scripts/test.py','--lua','lua5.5'],source,env)
print('Evidence: '+str(out))
