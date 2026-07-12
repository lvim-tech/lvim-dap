-- lvim-dap: :checkhealth lvim-dap.
-- Reports the things that stop a debug session before the user sees anything: no adapter
-- registered (the plug-and-play seam is empty), an adapter whose executable is not on PATH, a
-- rival DAP client loaded alongside (double sessions / grabbed signs), and the runtime bits the
-- engine needs (Neovim version, lvim-utils for palette/merge). Read-only — never mutates state.
--
---@module "lvim-dap.health"

local config = require("lvim-dap.config")
local registry = require("lvim-dap.registry")
local log = require("lvim-dap.log")

local M = {}

--- Rival DAP clients: if loaded they also place signs / own sessions and collide with us.
---@type table<string, string>
local RIVALS = { dap = "nvim-dap" }

--- Report whether each registered adapter's executable is resolvable.
---@param health table
local function check_adapters(health)
    local rows = registry.list_adapters()
    if #rows == 0 then
        health.warn(
            "no adapters registered — opt into a preset (require('lvim-dap').use('python')) or register your own"
        )
        return
    end
    for _, r in ipairs(rows) do
        local spec = registry.adapters[r.type]
        if type(spec) == "table" and spec.type == "executable" and spec.command then
            if vim.fn.executable(spec.command) == 1 then
                health.ok(("adapter %s: `%s` found"):format(r.type, spec.command))
            else
                health.warn(("adapter %s: `%s` not on PATH"):format(r.type, spec.command))
            end
        else
            health.ok(("adapter %s (%s, %s)"):format(r.type, r.kind, r.source))
        end
    end
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-dap")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (vim.uv, vim.json)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_utils then
        health.ok("lvim-utils found (palette + merge)")
    else
        health.warn("lvim-utils not found — falling back to plain highlights and tbl_deep_extend")
    end

    for mod, label in pairs(RIVALS) do
        if package.loaded[mod] then
            health.warn(("%s is loaded — two DAP clients place signs / own sessions; run only one"):format(label))
        end
    end

    check_adapters(health)

    local loaded = registry.loaded()
    if #loaded > 0 then
        health.info("presets loaded: " .. table.concat(loaded, ", "))
    end

    health.info(("log level=%s  file=%s"):format(log.level(), log.path()))
    health.info(
        ("stepping granularity=%s  persist.breakpoints=%s"):format(
            config.stepping_granularity,
            tostring(config.persist.breakpoints)
        )
    )
end

return M
