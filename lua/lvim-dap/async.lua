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
