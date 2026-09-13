"""Resolve a usable CLI without credentials or network requests."""
import functools,os,shutil,subprocess
from pathlib import Path

@functools.lru_cache(maxsize=16)
def _resolve(configured,path,data_home):
 candidates=[configured,str(Path(data_home)/'lca/tools/aws'),'aws']
 found=[]
 for candidate in candidates:
  if not candidate:continue
  executable=shutil.which(candidate,path=path)
  if not executable or executable in found:continue
  found.append(executable)
  result=subprocess.run([executable,'lambda-microvms','get-microvm','--generate-cli-skeleton','input'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
  if result.returncode==0:return executable
 if not found:raise FileNotFoundError('AWS CLI is missing. Install a current AWS CLI to use cloud sessions; local LCA still works.')
 raise RuntimeError('Installed AWS CLI lacks Lambda MicroVM support. Update AWS CLI or set aws_cli to a current installation; local LCA still works.')

def resolve(cfg):
 return _resolve(cfg.get('aws_cli'),os.getenv('PATH',''),os.getenv('XDG_DATA_HOME',str(Path.home()/'.local/share')))
