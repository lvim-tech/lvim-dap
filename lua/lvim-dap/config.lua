-- lvim-dap.config: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (via lvim-utils.utils.merge),
-- so every require("lvim-dap.config") reader sees the effective values. Adapters/configurations
-- are NOT here — they live in the registry (registered, not configured), per the plug-and-play
-- design. What lives here is engine behaviour: logging, default stepping granularity, the sign
-- glyphs + highlight accents (engine-owned, so gutter marks work with no UI loaded), and opt-in
-- persistence.
--
---@module "lvim-dap.config"

---@class LvimDapSignsConfig
---@field breakpoint          string  glyph for a plain breakpoint
---@field breakpoint_condition string glyph for a conditional breakpoint
---@field breakpoint_rejected string  glyph for a breakpoint the adapter rejected
---@field log_point           string  glyph for a logpoint
---@field stopped             string  glyph for the stopped/current line

---@class LvimDapPersistConfig
---@field breakpoints boolean  persist breakpoints per project across sessions
---@field last_run    boolean  remember the last configuration run per project

---@class LvimDapConfig
---@field log_level            lvim-dap.log.Level   file-log verbosity (trace|debug|info|warn|error)
---@field stepping_granularity "statement"|"line"|"instruction"  default step granularity
---@field auto_use             string[]             bundled adapter presets to register on setup
---@field terminal             { command: string?, position: string }  runInTerminal window policy
---@field signs                LvimDapSignsConfig
---@field persist              LvimDapPersistConfig
---@field on_config?           fun(config: table): table|nil  last-chance config rewrite before run

---@type LvimDapConfig
return {
    log_level = "warn",
    stepping_granularity = "statement",
    -- Bundled presets (lvim-dap.adapters.<name>) auto-registered on setup(). Empty by default:
    -- the user opts in — nothing is hardcoded into the engine.
    auto_use = {},
    terminal = {
        command = nil, -- external terminal command template; nil = integrated terminal buffer
        position = "belowright",
    },
    signs = {
        breakpoint = "",
        breakpoint_condition = "",
        breakpoint_rejected = "",
        log_point = "",
        stopped = "➤",
    },
    persist = {
        breakpoints = false,
        last_run = false,
    },
    on_config = nil,
}
