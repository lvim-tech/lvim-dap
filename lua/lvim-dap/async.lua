-- lvim-dap.async: the coroutine harness the run pipeline executes in.
-- Config resolution is inherently blocking-looking but must not block: a launch config can
-- carry a value that is a function, or a coroutine, or a ${command:pickProcess} that opens a
-- picker and resolves later; `session:request(...)` likewise wants to read as `local err, res
-- = session:request(...)` while actually awaiting an async reply. Both need a coroutine to
-- yield in. `run` starts one; `request`/`await` helpers in the session resume it when the
-- reply arrives. This mirrors nvim-dap's `dap.async` — deliberately minimal: a scheduler this
-- small has no error swallowing surprises, and every await point is explicit.
--
---@module "lvim-dap.async"

local log = require("lvim-dap.log")

local M = {}

--- Raised inside the run coroutine when the user CANCELS an awaited prompt. It travels up as an
--- ordinary Lua error (so every intermediate frame unwinds) and `M.resume` recognises it as a
--- deliberate abort — no notification, no "coroutine failed" log line.
M.ABORT = "lvim-dap.async: aborted by the user"

--- Resume `co`, SURFACING a failure instead of swallowing it. Every resume must go through here.
--- `coroutine.resume` returns `false, err` on an error inside the coroutine — a bare call therefore
--- DISCARDS it. Only the initial `run` step used to check, so any error raised AFTER the first await
--- (i.e. in every reply handler — the bulk of the engine's logic) vanished without a trace: no log, no
--- notification, the debug session simply stopped doing anything.
---@param co thread
---@param ... any  values passed into the coroutine's pending `yield`
function M.resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        if err == M.ABORT then
            -- A cancelled prompt is a user decision, not a failure: stop quietly.
            log.debug("async: run aborted at a prompt")
            return
        end
        log.error("async: coroutine failed:", err)
        vim.schedule(function()
            vim.notify("lvim-dap: " .. tostring(err), vim.log.levels.ERROR)
        end)
    end
end

--- Run `fn` inside a fresh coroutine. Uncaught errors are logged (and surfaced via notify),
--- never silently dropped. Returns the coroutine so callers can resume it from a reply handler.
---@param fn fun()
---@return thread
function M.run(fn)
    local co = coroutine.create(fn)
    M.resume(co)
    return co
end

--- True when called from within a (non-main) coroutine — i.e. it is legal to yield here.
---@return boolean
function M.in_coroutine()
    local co, is_main = coroutine.running()
    return co ~= nil and not is_main
end

--- AWAIT a value from the canonical `lvim-ui` input, as if it were a blocking prompt.
---
--- This exists because a launch config's function values must RETURN a value ("which executable?",
--- "which pid?") while every themed UI in the ecosystem is CALLBACK-style. Without an await point the
--- only way to return a value was `vim.fn.input`, i.e. the bare command line — unthemed, uncentered,
--- outside the canonical UI. Config resolution already runs inside `M.run`'s coroutine (see
--- `vars.resolve`), so the value can simply be yielded for and resumed with.
---
--- Opening the prompt is deferred through `vim.schedule` so the coroutine is guaranteed to be
--- SUSPENDED before any callback could resume it.
---
--- CANCELLING ABORTS THE RUN. `vars.resolve` calls a config's function values and stores what they
--- return, so a nil would silently drop `program` (or `processId`) and the adapter would be launched
--- half-configured — a confusing failure two steps later. Raising `M.ABORT` instead unwinds the whole
--- resolution and ends the run exactly where the user cancelled it, which is what they asked for.
--- Callers therefore never need to nil-check; they can `return async.ui_input({...})` directly.
---@param opts table  UiOpts for `lvim-ui.input` (title, default, completion, …)
---@return string  the entered value (never nil — a cancel does not return)
function M.ui_input(opts)
    if not M.in_coroutine() then
        log.error("async: ui_input called outside a coroutine — cannot await")
        error(M.ABORT, 0)
    end
    local co = coroutine.running()
    vim.schedule(function()
        local ok, ui = pcall(require, "lvim-ui")
        if not ok or type(ui.input) ~= "function" then
            log.error("async: lvim-ui is unavailable — no prompt could be shown")
            M.resume(co, nil)
            return
        end
        ui.input(vim.tbl_extend("force", opts or {}, {
            callback = function(confirmed, value)
                M.resume(co, confirmed and value or nil)
            end,
        }))
    end)
    local value = coroutine.yield()
    if value == nil then
        error(M.ABORT, 0)
    end
    return value
end

--- Ensure subsequent code runs on the main loop (not a luv fast event), yielding+rescheduling
--- the current coroutine when necessary. A no-op outside a coroutine or when already on-loop.
function M.schedule_back()
    if vim.in_fast_event() and M.in_coroutine() then
        local co = coroutine.running()
        vim.schedule(function()
            M.resume(co)
        end)
        coroutine.yield()
    end
end

return M
