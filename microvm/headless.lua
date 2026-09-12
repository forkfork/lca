-- Explicit command UI: never serialize session methods or fabricate callbacks.
local M={}
function M.ui(output)
 output=output or print
 return {
  block=output, muted=output, error=function(message) error(message) end,
  status=function(session)
   output(require('cjson').encode({cwd=session.cwd,model=session.model,
    session_id=session.id,turn_count=session:turn_count(),reasoning=session.reasoning_effort}))
  end,
 }
end
return M
