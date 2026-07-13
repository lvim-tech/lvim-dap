-- lvim-dap.session: one live debug conversation — the DAP request/response + event loop.
-- A Session owns a transport client (from lvim-dap.transport) and drives the protocol over it:
--   • REQUESTS carry a monotonically increasing `seq`; the reply (matched by `request_seq`)
--     resolves the stored callback. Inside a coroutine `request()` may be awaited directly
--     (`local err, body = session:request(...)`); outside one it takes a callback.
--   • EVENTS (stopped, continued, output, terminated, …) are dispatched to a `Session:event_X`
--     handler AND broadcast on the listener bus (before → engine handler → after), which is how
--     lvim-dap-view stays in sync.
--   • The HANDSHAKE is spec order: initialize → (capabilities) → launch|attach → wait for the
--     `initialized` EVENT → push breakpoints → configurationDone. Only then is the adapter live.
--   • REVERSE REQUESTS from the adapter (runInTerminal, startDebugging) are answered here too.
-- State the UI reads — capabilities, threads, current_frame, stopped_thread_id — lives on the
-- object. The session is transport-agnostic: executable/server/pipe all arrive as the same
-- client, so nothing below cares which kind it is.
--
---@module "lvim-dap.session"

local uv = vim.uv or vim.loop
local transport = require("lvim-dap.transport")
local listeners = require("lvim-dap.listeners")
local async = require("lvim-dap.async")
local log = require("lvim-dap.log")

---@class lvim-dap.StackFrame
---@field id integer
---@field name string
---@field line integer
---@field column integer
---@field source? { path?: string, name?: string, sourceReference?: integer }
---@field scopes? table[]

---@class lvim-dap.Thread
---@field id integer
---@field name string
---@field stopped? boolean
---@field frames? lvim-dap.StackFrame[]

---@class lvim-dap.Session
---@field id integer
---@field adapter table
---@field config table
---@field capabilities table
---@field client lvim-dap.TransportClient?
---@field initialized boolean
---@field closed boolean
---@field threads table<integer, lvim-dap.Thread>
---@field stopped_thread_id integer?
---@field current_frame lvim-dap.StackFrame?
---@field filetype string
---@field on_close table<string, fun(s: lvim-dap.Session)>
---@field parent lvim-dap.Session?
---@field children table<integer, lvim-dap.Session>
---@field seq integer
---@field message_callbacks table<integer, fun(err: table?, body: any)>
---@field handlers table<string, function>
---@field reverse_handlers? table<string, fun(s: lvim-dap.Session, request: table)>
---@field on_initialized? fun(s: lvim-dap.Session)
---@field term_buf? integer
local Session = {}
Session.__index = Session

---@type integer  process-wide session id counter
local id_counter = 0

--- Decode a JSON body, tolerating an empty payload.
---@param body string
---@return table?
local function decode(body)
    if body == "" then
        return {}
    end
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok then
        log.error("session: JSON decode failed:", decoded, "for", body)
        return nil
    end
    return decoded
end

--- Construct a session bound to `adapter`/`config`, with a transport client wired to it.
--- `on_ready(err)` fires once the transport is connected (or failed); the caller then calls
--- `session:initialize(config)`.
---@param adapter table
---@param config table
---@param opts table?
---@return lvim-dap.Session
function Session.new(adapter, config, opts)
    id_counter = id_counter + 1
    ---@type lvim-dap.Session
    local self = setmetatable({
        id = id_counter,
        adapter = adapter,
        config = config,
        capabilities = {},
        client = nil,
        initialized = false,
        closed = false,
        seq = 0,
        message_callbacks = {}, -- request seq → reply callback
        handlers = {},
        threads = {},
        stopped_thread_id = nil,
        current_frame = nil,
        filetype = (opts and opts.filetype) or vim.bo.filetype,
        on_close = {},
        parent = opts and opts.parent or nil,
        children = {},
    }, Session)
    return self
end

--- Start the transport for `adapter` and build a session; `on_connect(err, session)` fires when
--- the adapter is reachable. Handles all three transport kinds.
---@param adapter table
---@param config table
---@param opts table?
---@param on_connect fun(err: string?, session: lvim-dap.Session?)
---@return lvim-dap.Session
function Session.launch(adapter, config, opts, on_connect)
    local self = Session.new(adapter, config, opts)

    ---@type lvim-dap.transport.Callbacks
    local cbs = {
        on_body = function(body)
            vim.schedule(function()
                self:handle_body(body)
            end)
        end,
        on_exit = function(code)
            log.info("session", self.id, "transport exited, code:", code)
            if not self.closed then
                self:close()
            end
        end,
        on_stderr = function(chunk)
            log.debug("session", self.id, "adapter stderr:", chunk)
        end,
        on_ready = function(err)
            if err then
                on_connect(err, nil)
            end
        end,
        on_client = function(client)
            self.client = client
            on_connect(nil, self)
        end,
    }

    if adapter.type == "executable" then
        local client = transport.executable(adapter, cbs)
        if client then
            self.client = client
            on_connect(nil, self)
        end
    elseif adapter.type == "server" then
        transport.server(adapter, cbs)
    elseif adapter.type == "pipe" then
        transport.pipe(adapter, cbs)
    else
        on_connect("invalid adapter type: " .. tostring(adapter.type), nil)
    end
    return self
end

-- ── request / response plumbing ──────────────────────────────────────────────

--- Send a DAP request. With `on_result` it is callback-style; without one, inside a coroutine,
--- it AWAITS and returns `err, body`. `err` is the adapter's error response (or nil).
---@param command string
---@param arguments any?
---@param on_result fun(err: table?, body: any)?
---@return table? err, any body
function Session:request(command, arguments, on_result)
    if self.closed or not self.client then
        if on_result then
            on_result({ message = "session closed" }, nil)
        end
        return { message = "session closed" }, nil
    end
    self.seq = self.seq + 1
    local seq = self.seq
    local payload = {
        seq = seq,
        type = "request",
        command = command,
        -- An empty Lua table encodes to JSON `[]` (array); DAP arguments must be an object, so
        -- default to an empty DICT — some adapters (debugpy) reject `[]` for e.g. configurationDone.
        arguments = arguments or vim.empty_dict(),
    }

    local co = coroutine.running()
    local awaiting = on_result == nil and async.in_coroutine()
    self.message_callbacks[seq] = function(err, body)
        if awaiting then
            -- through async.resume, so an error raised in the awaiting code is LOGGED + surfaced
            -- rather than silently killing the coroutine mid-handshake
            async.resume(co, err, body)
        elseif on_result then
            on_result(err, body)
        end
    end

    log.trace("session", self.id, "→ request", command, "seq", seq)
    self.client.write(vim.json.encode(payload))

    if awaiting then
        return coroutine.yield()
    end
end

--- Same as `request` but fails the callback if no reply arrives within `timeout_ms`.
---@param command string
---@param arguments any?
---@param timeout_ms integer
---@param on_result fun(err: table?, body: any)
function Session:request_with_timeout(command, arguments, timeout_ms, on_result)
    local done = false
    local timer = uv.new_timer()
    self:request(command, arguments, function(err, body)
        if done then
            return
        end
        done = true
        if timer then
            timer:stop()
            timer:close()
        end
        on_result(err, body)
    end)
    if timer then
        timer:start(timeout_ms, 0, function()
            if done then
                return
            end
            done = true
            timer:stop()
            timer:close()
            vim.schedule(function()
                on_result({ message = "request timed out: " .. command }, nil)
            end)
        end)
    end
end

--- Answer a reverse request from the adapter.
---@param request table  the incoming request message
---@param body any?
---@param success boolean?
---@param message string?
function Session:respond(request, body, success, message)
    self.seq = self.seq + 1
    local payload = {
        seq = self.seq,
        type = "response",
        request_seq = request.seq,
        success = success ~= false,
        command = request.command,
        body = body,
        message = message,
    }
    if self.client then
        self.client.write(vim.json.encode(payload))
    end
end

--- Route one decoded DAP message: response → resolve callback; event → dispatch; request →
--- reverse handler.
---@param body string
function Session:handle_body(body)
    local msg = decode(body)
    if not msg then
        return
    end
    if msg.type == "response" then
        local cb = self.message_callbacks[msg.request_seq]
        self.message_callbacks[msg.request_seq] = nil
        if cb then
            local err = (msg.success == false) and { message = msg.message, body = msg.body } or nil
            log.trace("session", self.id, "← response", msg.command, msg.success and "ok" or "ERR")
            cb(err, msg.body)
        end
    elseif msg.type == "event" then
        self:dispatch_event(msg.event, msg.body)
    elseif msg.type == "request" then
        self:handle_reverse_request(msg)
    end
end

--- Dispatch a DAP event: listeners.before → Session:event_<name> → listeners.after.
---@param event string
---@param payload any
function Session:dispatch_event(event, payload)
    log.trace("session", self.id, "← event", event)
    local key = "event_" .. event
    listeners.dispatch("before", key, self, payload)
    local handler = self["event_" .. event]
    if type(handler) == "function" then
        local ok, err = pcall(handler, self, payload)
        if not ok then
            log.error("session", self.id, "event handler", event, "failed:", err)
        end
    end
    listeners.dispatch("after", key, self, payload)
end

--- Handle a reverse request. `runInTerminal` and `startDebugging` are wired by the engine
--- (init.lua sets `self.reverse_handlers`); anything else is politely refused.
---@param request table
function Session:handle_reverse_request(request)
    local handler = (self.reverse_handlers or {})[request.command]
        or (self.adapter.reverse_request_handlers or {})[request.command]
    if handler then
        handler(self, request)
    else
        log.warn("session", self.id, "unhandled reverse request:", request.command)
        self:respond(request, nil, false, "unsupported reverse request: " .. request.command)
    end
end

-- ── handshake ────────────────────────────────────────────────────────────────

--- Run the initialize → launch/attach → configurationDone handshake. Must run in a coroutine
--- (uses awaiting requests).
---@param config table
function Session:initialize(config)
    async.run(function()
        local err, caps = self:request("initialize", {
            clientID = "lvim-dap",
            clientName = "lvim-dap",
            adapterID = config.type,
            locale = "en",
            linesStartAt1 = true,
            columnsStartAt1 = true,
            pathFormat = "path",
            supportsVariableType = true,
            supportsVariablePaging = true,
            supportsRunInTerminalRequest = true,
            supportsProgressReporting = true,
            supportsStartDebuggingRequest = true,
        })
        if err then
            log.error("session", self.id, "initialize failed:", err.message)
            vim.notify("lvim-dap: initialize failed: " .. tostring(err.message), vim.log.levels.ERROR)
            self:close()
            return
        end
        self.capabilities = caps or {}
        log.info("session", self.id, "initialized; request:", config.request)

        -- launch / attach. The `initialized` EVENT (not this response) is the signal to send
        -- breakpoints + configurationDone; it may arrive before OR after this returns.
        self:request(config.request, config, function(lerr)
            if lerr then
                log.error("session", self.id, config.request, "failed:", lerr.message)
                vim.notify(
                    "lvim-dap: " .. config.request .. " failed: " .. tostring(lerr.message),
                    vim.log.levels.ERROR
                )
                self:close()
            end
        end)
    end)
end

--- The `initialized` event: configure breakpoints, then configurationDone. The engine sets
--- `self.on_initialized` (init.lua) to push user breakpoints; we then finish configuration.
---@param _ any
function Session:event_initialized(_)
    async.run(function()
        if self.on_initialized then
            local ok, err = pcall(self.on_initialized, self)
            if not ok then
                log.error("session", self.id, "on_initialized hook failed:", err)
            end
        end
        if self.capabilities.supportsConfigurationDoneRequest then
            self:request("configurationDone", nil, function(err)
                if err then
                    log.warn("session", self.id, "configurationDone error:", err.message)
                end
            end)
        end
        self.initialized = true
        log.info("session", self.id, "configuration done")
    end)
end

-- ── stop / thread / frame state ──────────────────────────────────────────────

--- The `stopped` event: record the stopped thread, refresh threads + the stopped thread's
--- stack, focus the top frame, and pre-fetch its scopes. The view repaints from `after`.
---@param stopped table  dap.StoppedEvent body
function Session:event_stopped(stopped)
    async.run(function()
        self.stopped_thread_id = stopped.threadId
        self:update_threads()
        if not stopped.threadId then
            return
        end
        local frames = self:fetch_stack(stopped.threadId)
        local thread = self.threads[stopped.threadId]
        if thread then
            thread.stopped = true
            thread.frames = frames
        end
        local top = frames and frames[1]
        if top then
            self.current_frame = top
            self:fetch_scopes(top)
        end
        -- Frame + scopes are now populated (unlike the raw `stopped` event, which fires before
        -- the async fetch). The engine jumps the editor and the view repaints off THIS hook.
        listeners.dispatch("after", "frame_updated", self, stopped)
    end)
end

--- Fetch the thread list into `self.threads` (preserving `stopped`/`frames` where possible).
function Session:update_threads()
    local err, body = self:request("threads")
    if err or not body then
        return
    end
    local by_id = {}
    for _, t in ipairs(body.threads or {}) do
        local existing = self.threads[t.id]
        by_id[t.id] = {
            id = t.id,
            name = t.name,
            stopped = existing and existing.stopped or false,
            frames = existing and existing.frames or nil,
        }
    end
    self.threads = by_id
end

--- Request the stack trace for a thread. Awaits — call in a coroutine.
---@param thread_id integer
---@return lvim-dap.StackFrame[]?
function Session:fetch_stack(thread_id)
    local err, body = self:request("stackTrace", { threadId = thread_id })
    if err or not body then
        return nil
    end
    return body.stackFrames
end

--- Request the scopes for a frame and stash them on the frame. Awaits.
---@param frame lvim-dap.StackFrame
---@return table[]?
function Session:fetch_scopes(frame)
    local err, body = self:request("scopes", { frameId = frame.id })
    if err or not body then
        return nil
    end
    frame.scopes = body.scopes
    return body.scopes
end

--- Request the child variables of a variablesReference. Awaits.
---@param ref integer
---@return table[]?
function Session:fetch_variables(ref)
    local err, body = self:request("variables", { variablesReference = ref })
    if err or not body then
        return nil
    end
    return body.variables
end

--- The `continued` event: clear stopped state for the affected thread(s).
---@param event table  dap.ContinuedEvent body
function Session:event_continued(event)
    if event.allThreadsContinued ~= false then
        for _, t in pairs(self.threads) do
            t.stopped = false
            t.frames = nil
        end
    elseif event.threadId and self.threads[event.threadId] then
        self.threads[event.threadId].stopped = false
        self.threads[event.threadId].frames = nil
    end
    if self.stopped_thread_id == event.threadId or event.allThreadsContinued ~= false then
        self.stopped_thread_id = nil
        self.current_frame = nil
    end
end

--- The `thread` event: keep the thread map roughly in sync (full refresh happens on stop).
---@param event table
function Session:event_thread(event)
    if event.reason == "started" and event.threadId then
        self.threads[event.threadId] = self.threads[event.threadId]
            or { id = event.threadId, name = "Thread " .. event.threadId }
    elseif event.reason == "exited" and event.threadId then
        self.threads[event.threadId] = nil
    end
end

--- The `capabilities` event: merge late-advertised capabilities.
---@param body table
function Session:event_capabilities(body)
    if body and body.capabilities then
        self.capabilities = vim.tbl_extend("force", self.capabilities, body.capabilities)
    end
end

--- The `terminated` event: the debuggee ended. Close unless a restart is requested.
---@param _ any
function Session:event_terminated(_)
    log.info("session", self.id, "terminated event")
    if not self.closed then
        self:close()
    end
end

--- The `exited` event carries the debuggee exit code (informational).
function Session.event_exited(_, body)
    if body and body.exitCode ~= nil then
        log.info("debuggee exited with code", body.exitCode)
    end
end

-- ── run control ──────────────────────────────────────────────────────────────

--- Issue a stepping/continue request for the current (or given) thread.
---@param step "next"|"stepIn"|"stepOut"|"stepBack"|"continue"|"reverseContinue"
---@param params table?
function Session:step(step, params)
    local thread_id = (params and params.threadId) or self.stopped_thread_id
    if not thread_id and step ~= "continue" then
        log.warn("session", self.id, "step", step, "with no stopped thread")
    end
    local args = vim.tbl_extend("keep", params or {}, { threadId = thread_id })
    -- Optimistically clear stopped state; a subsequent stopped event re-sets it.
    self.stopped_thread_id = nil
    self.current_frame = nil
    self:request(step, args, function(err)
        if err then
            log.warn("session", self.id, step, "error:", err.message)
        end
    end)
end

--- Pause a thread.
---@param thread_id integer?
function Session:pause(thread_id)
    self:request("pause", { threadId = thread_id or self.stopped_thread_id }, function(err)
        if err then
            log.warn("session", self.id, "pause error:", err.message)
        end
    end)
end

--- Evaluate an expression in a context (repl/hover/watch). Awaitable / callback.
---@param expression string
---@param context "repl"|"hover"|"watch"|"clipboard"|nil
---@param on_result fun(err: table?, body: any)?
---@return table? err, any body
function Session:evaluate(expression, context, on_result)
    return self:request("evaluate", {
        expression = expression,
        frameId = self.current_frame and self.current_frame.id or nil,
        context = context or "repl",
    }, on_result)
end

--- Push line breakpoints for a buffer via setBreakpoints. `bps` is a list of
--- `{ line, condition?, hitCondition?, logMessage? }`. Awaitable / callback.
---@param path string   source path
---@param bps table[]
---@param on_result fun(err: table?, body: any)?
function Session:set_breakpoints(path, bps, on_result)
    local source = { path = path, name = vim.fn.fnamemodify(path, ":t") }
    local breakpoints = {}
    for _, bp in ipairs(bps) do
        breakpoints[#breakpoints + 1] = {
            line = bp.line,
            condition = bp.condition,
            hitCondition = bp.hitCondition,
            logMessage = bp.logMessage,
        }
    end
    return self:request("setBreakpoints", {
        source = source,
        breakpoints = breakpoints,
        lines = vim.tbl_map(function(b)
            return b.line
        end, breakpoints),
    }, on_result)
end

--- Set exception breakpoint filters.
---@param filters string[]
---@param options table[]?
---@param on_result fun(err: table?, body: any)?
function Session:set_exception_breakpoints(filters, options, on_result)
    return self:request("setExceptionBreakpoints", {
        filters = filters or {},
        exceptionOptions = options,
    }, on_result)
end

--- Terminate: prefer the `terminate` request if supported, else disconnect with terminateDebuggee.
---@param opts { on_done?: fun() }?
function Session:terminate(opts)
    opts = opts or {}
    local on_done = opts.on_done or function() end
    if self.closed then
        on_done()
        return
    end
    if self.capabilities.supportsTerminateRequest then
        self:request_with_timeout("terminate", vim.empty_dict(), 3000, function()
            if not self.closed then
                self:close()
            end
            on_done()
        end)
    else
        self:disconnect({ terminateDebuggee = true }, on_done)
    end
end

--- Disconnect the session.
---@param opts table?  DisconnectArguments
---@param cb fun()?
function Session:disconnect(opts, cb)
    if self.closed then
        if cb then
            cb()
        end
        return
    end
    self:request_with_timeout("disconnect", opts or { terminateDebuggee = true }, 2000, function()
        if not self.closed then
            self:close()
        end
        if cb then
            cb()
        end
    end)
end

--- Tear down the transport and fire `on_close` hooks. Idempotent.
function Session:close()
    if self.closed then
        return
    end
    self.closed = true
    log.info("session", self.id, "closing")
    -- FAIL every in-flight request before tearing the transport down. Their replies can never arrive
    -- now, and each pending callback is either an awaiting COROUTINE — which would otherwise be
    -- suspended forever, leaking it and abandoning whatever it was mid-way through (a handshake, a
    -- stack fetch) — or a caller's `on_result`, which would simply never be told. An adapter that dies
    -- mid-request is the normal case here, not an exotic one.
    local pending = self.message_callbacks
    self.message_callbacks = {}
    for _, cb in pairs(pending) do
        pcall(cb, { message = "session closed" }, nil)
    end
    if self.client then
        self.client.close()
        self.client = nil
    end
    for _, hook in pairs(self.on_close) do
        pcall(hook, self)
    end
end

return Session
