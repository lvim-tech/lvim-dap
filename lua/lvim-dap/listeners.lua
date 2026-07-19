-- lvim-dap.listeners: the public event/request hook bus (the engine↔view seam).
-- Every DAP event and request flows through here so consumers subscribe without patching the
-- session: `listeners.before.<name>[owner] = fn` runs before the engine's own handling,
-- `listeners.after.<name>[owner]` after it. `owner` is a stable string id so a subscriber can
-- replace/remove its own hook. lvim-dap-view is the primary consumer (it repaints panels off
-- `after.event_stopped`, `after.event_terminated`, …); user code ported from nvim-dap keeps the
-- exact `listeners.before/after` shape. `on_session` fires when the focused session changes;
-- `on_config` lets a hook rewrite a configuration just before it runs (the ${...} expansion
-- registers here). Keyed sub-tables auto-vivify so `listeners.after.event_stopped["me"] = fn`
-- just works.
--
---@module "lvim-dap.listeners"

local log = require("lvim-dap.log")

--- Auto-vivifying map: reading any event/request key yields a fresh owner→handler table.
---@return table
local function autoviv()
    return setmetatable({}, {
        __index = function(t, k)
            rawset(t, k, {})
            return rawget(t, k)
        end,
    })
end

local M = {
    ---@type table<string, table<string, function>>
    before = autoviv(),
    ---@type table<string, table<string, function>>
    after = autoviv(),
    ---@type table<string, fun(config: table): table>
    on_config = {},
    ---@type table<string, fun(old: table?, new: table?)>
    on_session = {},
}

--- Invoke every handler registered for `phase.name`, passing `...`. A handler returning true is
--- logged as having consumed the event (the engine still runs; this mirrors nvim-dap semantics).
---@param phase "before"|"after"
---@param name string
---@param ... any
function M.dispatch(phase, name, ...)
    local bucket = rawget(M[phase], name)
    if not bucket then
        return
    end
    for owner, handler in pairs(bucket) do
        -- A broken view/user hook must not take the dispatch down (pcall), but its error must not vanish
        -- either — surface it to the log with the owner + which hook, so a silently-dead subscriber is
        -- diagnosable instead of just "the panel stopped updating".
        local ok, err = pcall(handler, ...)
        if not ok then
            log.error("listeners:", phase .. "." .. name, "handler", tostring(owner), "failed:", err)
        end
    end
end

return M
