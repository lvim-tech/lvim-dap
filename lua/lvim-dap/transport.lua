-- lvim-dap.transport: the three ways to reach a debug adapter, behind one uniform client.
-- A DAP adapter is a separate process (or an already-listening server), and nvim-dap-shaped
-- adapter tables name which of three transports to use:
--   • "executable" — spawn `command args` and speak DAP over its stdin/stdout pipes. The
--     common case (debugpy, delve, codelldb-as-child). Ready as soon as the pipes open.
--   • "server"     — connect over TCP to `host:port`. `port == "${port}"` means "pick a free
--     port and substitute it" (into both the connect target AND the spawned server's args, the
--     js-debug pattern). An optional `executable` is spawned first to BE that server; connect
--     then retries until it accepts (the server needs a moment to bind).
--   • "pipe"       — connect to a named pipe / unix socket; like server but path-addressed.
-- Every transport returns the SAME client shape — `{ write(data), close(cb) }` — and pumps the
-- adapter's output through `lvim-dap.rpc` into the caller's `on_body`. So `session.lua` is
-- transport-agnostic: it hands over callbacks and gets one client back, whichever kind it is.
--
---@module "lvim-dap.transport"

local uv = vim.uv or vim.loop
local rpc = require("lvim-dap.rpc")
local log = require("lvim-dap.log")

local M = {}

---@class lvim-dap.TransportClient
---@field write fun(data: string)  frame + send a JSON body
---@field close fun(cb?: fun())     terminate the connection/process

---@class lvim-dap.transport.Callbacks
---@field on_body fun(body: string)        one decoded DAP message
---@field on_exit? fun(code?: integer)     the adapter process/connection ended
---@field on_ready fun(err?: string)       transport is connected (or failed to connect)
---@field on_stderr? fun(chunk: string)    adapter stderr line(s), for diagnostics
---@field on_client? fun(client: lvim-dap.TransportClient)  the resolved client (async server/pipe connect)

--- Allocate a free TCP port by binding to port 0 and reading back the OS-assigned number.
---@return integer?
local function free_port()
    local server = uv.new_tcp()
    if not server then
        return nil
    end
    local ok = pcall(function()
        server:bind("127.0.0.1", 0)
    end)
    local port
    if ok then
        local addr = server:getsockname()
        port = addr and addr.port or nil
    end
    server:close()
    return port
end

--- Substitute a resolved `${port}` into every string leaf of a value (args, host, port).
---@param value any
---@param port integer
---@return any
local function substitute_port(value, port)
    if type(value) == "table" then
        local out = {}
        for k, v in pairs(value) do
            out[k] = substitute_port(v, port)
        end
        return out
    elseif type(value) == "string" then
        return (value:gsub("${port}", tostring(port)))
    end
    return value
end

--- Wire a readable uv stream into the rpc decoder → `on_body`.
---@param stream uv.uv_stream_t
---@param cbs lvim-dap.transport.Callbacks
local function pump(stream, cbs)
    -- Both a real EOF and a decode error end the stream irrecoverably; funnel both through one
    -- guarded `finish` so the session is torn down exactly once. A decode error on a framed stream is
    -- unrecoverable BY DEFINITION — the parser coroutine is now dead, so every further chunk would only
    -- re-error — so we treat it as EOF: stop reading and fire on_exit (→ Session:close, which fails the
    -- pending requests and runs on_close). Before this, a stray non-DAP line on an adapter's stdout only
    -- logged and the session hung forever with a live adapter process.
    local finished = false
    local function finish()
        if finished then
            return
        end
        finished = true
        pcall(function()
            stream:read_stop()
        end)
        if cbs.on_exit then
            cbs.on_exit()
        end
    end
    stream:read_start(rpc.create_read_loop(cbs.on_body, finish, function(msg)
        log.error("transport: decode error:", msg)
        finish()
    end))
end

--- Build the `{ write, close }` client over a duplex stream (+ optional owned process handle).
---@param sink uv.uv_stream_t      where writes go (stdin pipe / the socket)
---@param proc? uv.uv_process_t    the spawned process, if we own one
---@param extra? uv.uv_handle_t[]  stray handles to close on teardown (stdout/stderr pipes)
---@return lvim-dap.TransportClient
local function make_client(sink, proc, extra)
    return {
        write = function(data)
            local framed = rpc.frame(data)
            if not sink:is_closing() then
                sink:write(framed)
            end
        end,
        close = function(cb)
            for _, h in ipairs(extra or {}) do
                if h and not h:is_closing() then
                    pcall(function()
                        h:read_stop()
                    end)
                    pcall(function()
                        h:close()
                    end)
                end
            end
            if sink and not sink:is_closing() then
                pcall(function()
                    sink:close()
                end)
            end
            if proc and not proc:is_closing() then
                pcall(function()
                    proc:kill(15)
                end)
                pcall(function()
                    proc:close()
                end)
            end
            if cb then
                vim.schedule(cb)
            end
        end,
    }
end

--- Spawn an adapter executable and speak DAP over its stdio pipes.
---@param command string
---@param args string[]?
---@param opts { cwd?: string, env?: table<string,string>, detached?: boolean }?
---@param cbs lvim-dap.transport.Callbacks
---@return lvim-dap.TransportClient?
local function spawn(command, args, opts, cbs)
    opts = opts or {}
    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    if not (stdin and stdout and stderr) then
        cbs.on_ready("failed to allocate pipes")
        return nil
    end

    local env
    if opts.env then
        -- Merge into a MAP first (overrides win), then flatten to the `KEY=value` list libuv wants.
        -- Appending environ() then the overrides produced DUPLICATE keys (`KEY=a` and `KEY=b`) — execve
        -- then picks one platform-dependently, so an override could silently not take effect.
        local merged = vim.tbl_extend("force", vim.fn.environ(), opts.env)
        env = {}
        for k, v in pairs(merged) do
            env[#env + 1] = k .. "=" .. tostring(v)
        end
    end

    local handle, pid
    handle, pid = uv.spawn(command, {
        args = args,
        stdio = { stdin, stdout, stderr },
        cwd = opts.cwd,
        env = env,
        detached = opts.detached or false,
    }, function(code, _signal)
        log.info("transport: adapter exited, code:", code)
        if cbs.on_exit then
            vim.schedule(function()
                cbs.on_exit(code)
            end)
        end
    end)

    if not handle then
        stdin:close()
        stdout:close()
        stderr:close()
        cbs.on_ready(("failed to spawn `%s`: %s"):format(command, tostring(pid)))
        return nil
    end

    log.info("transport: spawned", command, "pid", pid)
    pump(stdout, cbs)
    if cbs.on_stderr then
        stderr:read_start(function(_, chunk)
            if chunk then
                cbs.on_stderr(chunk)
            end
        end)
    end
    local client = make_client(stdin, handle, { stdout, stderr })
    cbs.on_ready(nil)
    return client
end

--- executable transport.
---@param adapter table  dap.ExecutableAdapter
---@param cbs lvim-dap.transport.Callbacks
---@return lvim-dap.TransportClient?
function M.executable(adapter, cbs)
    local options = adapter.options or {}
    return spawn(adapter.command, adapter.args or {}, {
        cwd = options.cwd,
        env = options.env,
        detached = options.detached,
    }, cbs)
end

--- Connect a TCP socket to host:port, retrying while the server comes up.
---@param host string
---@param port integer
---@param max_retries integer
---@param cbs lvim-dap.transport.Callbacks
---@param proc? uv.uv_process_t  a server process we spawned and now own
---@param extra? uv.uv_handle_t[]  the server process's stdout/stderr pipes, closed on teardown
local function tcp_connect(host, port, max_retries, cbs, proc, extra)
    local attempt = 0
    local function try()
        attempt = attempt + 1
        -- A FRESH handle per attempt. libuv will not re-connect a uv_tcp_t whose connect FAILED: the
        -- second `connect` on it never calls back at all, so retrying on the same socket hangs forever —
        -- no connection, no error. That silently broke every `server` adapter that is not listening the
        -- instant we dial (i.e. every spawned one: js-debug, codelldb, delve, anything with `${port}`),
        -- which is exactly what the retry loop exists for.
        local sock = uv.new_tcp()
        if not sock then
            cbs.on_ready("failed to allocate socket")
            return
        end
        sock:connect(host, port, function(err)
            if err then
                pcall(function()
                    sock:close()
                end)
                if attempt <= max_retries then
                    vim.defer_fn(try, 250)
                else
                    cbs.on_ready(("couldn't connect to %s:%s: %s"):format(host, port, err))
                end
                return
            end
            log.info("transport: connected", host, port)
            pump(sock, cbs)
            -- The client owns the socket for writes; the process (if any) + its stdout/stderr pipes for
            -- teardown — otherwise those pipes stay read_start'd and open until VimLeave (leaked per run).
            local client = make_client(sock, proc, extra)
            cbs.on_ready(nil)
            if cbs.on_client then
                cbs.on_client(client)
            end
        end)
    end
    try()
end

--- server transport: optionally spawn `adapter.executable`, resolve `${port}`, connect TCP.
--- Because the socket connects asynchronously, the resolved client is delivered via
--- `cbs.on_client(client)` (not the return value); `on_ready(err)` still reports success/failure.
---@param adapter table  dap.ServerAdapter
---@param cbs lvim-dap.transport.Callbacks
function M.server(adapter, cbs)
    local options = adapter.options or {}
    local max_retries = options.max_retries or 14
    local host = adapter.host or "127.0.0.1"
    local port = adapter.port

    -- Resolve ${port} to a real free port, substituted into both connect + server args.
    local resolved_port = port
    if port == "${port}" then
        resolved_port = free_port()
        if not resolved_port then
            cbs.on_ready("couldn't allocate a free port for ${port}")
            return
        end
    end
    resolved_port = tonumber(resolved_port)
    if not resolved_port then
        cbs.on_ready('server adapter needs a numeric `port` (or "${port}")')
        return
    end

    local proc, extra
    if adapter.executable then
        local exe = substitute_port(adapter.executable, resolved_port)
        -- Spawn the server; its own stdout is not the DAP channel (the socket is), so we only
        -- watch for early exit + surface stderr for diagnostics.
        local stdout = uv.new_pipe(false)
        local stderr = uv.new_pipe(false)
        local h, pid = uv.spawn(exe.command, {
            args = exe.args,
            stdio = { nil, stdout, stderr },
            cwd = exe.cwd,
            detached = exe.detached or false,
        }, function(code)
            log.info("transport: server process exited, code:", code)
        end)
        if not h then
            -- Close the just-allocated pipes so a failed spawn does not leak two handles.
            if stdout then
                stdout:close()
            end
            if stderr then
                stderr:close()
            end
            cbs.on_ready(("failed to spawn server `%s`: %s"):format(exe.command, tostring(pid)))
            return
        end
        proc = h
        -- Hand the pipes to the client for teardown (make_client read_stops + closes `extra`).
        extra = { stdout, stderr }
        log.info("transport: spawned server", exe.command, "pid", pid, "port", resolved_port)
        if stdout then
            stdout:read_start(function() end)
        end
        if stderr and cbs.on_stderr then
            stderr:read_start(function(_, chunk)
                if chunk then
                    cbs.on_stderr(chunk)
                end
            end)
        end
    end

    tcp_connect(host, resolved_port, max_retries, cbs, proc, extra)
end

--- pipe transport: connect to a named pipe / unix socket (optionally spawning `executable`).
---@param adapter table  dap.PipeAdapter
---@param cbs lvim-dap.transport.Callbacks
function M.pipe(adapter, cbs)
    local pipe_path = adapter.pipe
    local proc
    if adapter.executable then
        local exe = adapter.executable
        local h, pid = uv.spawn(exe.command, { args = exe.args, cwd = exe.cwd }, function() end)
        if not h then
            cbs.on_ready(("failed to spawn pipe server `%s`: %s"):format(exe.command, tostring(pid)))
            return
        end
        proc = h
    end
    local timeout = (adapter.options or {}).timeout or 5000
    local elapsed = 0
    local function try()
        -- Fresh handle per attempt — see tcp_connect: a uv handle whose connect failed is dead, and
        -- re-connecting it never calls back, so the retry loop would hang instead of retrying.
        local sock = uv.new_pipe(false)
        if not sock then
            cbs.on_ready("failed to allocate pipe")
            return
        end
        sock:connect(pipe_path, function(err)
            if err then
                pcall(function()
                    sock:close()
                end)
                elapsed = elapsed + 100
                if elapsed < timeout then
                    vim.defer_fn(try, 100)
                else
                    cbs.on_ready(("couldn't connect to pipe %s: %s"):format(pipe_path, err))
                end
                return
            end
            pump(sock, cbs)
            local client = make_client(sock, proc)
            cbs.on_ready(nil)
            if cbs.on_client then
                cbs.on_client(client)
            end
        end)
    end
    try()
end

return M
