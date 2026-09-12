-- Lifecycle readiness only. LCA starts later from AWS's shell, with fresh TLS
-- state and credentials. No model, RPC, workspace or execution service here.
local socket = require("socket")
local server = assert(socket.bind("0.0.0.0", 9000))
print("LCA environment ready; waiting for AWS shell ingress")
io.stdout:flush()
while true do
    local client = assert(server:accept())
    client:settimeout(5)
    local request = client:receive("*l") or ""
    for _ = 1, 64 do
        local header = client:receive("*l")
        if not header or header == "" then break end
    end
    local method, path = request:match("^(%S+) (%S+)")
    local ready = method == "POST" and
        path == "/aws/lambda-microvms/runtime/v1/ready"
    local resumed = method == "POST" and path == "/aws/lambda-microvms/runtime/v1/resume"
    if resumed then
        local root='/tmp/lca-handoff'
        if require('luv').fs_stat(root) then
            require('agent.background').atomic(root..'/resumed.json',{time=os.time()})
        end
    end
    local status = (ready or resumed) and "200 OK" or "404 Not Found"
    client:send("HTTP/1.1 " .. status .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    client:close()
end
