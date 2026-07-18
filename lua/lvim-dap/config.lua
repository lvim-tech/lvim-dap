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
---@field last_run    boolean  RESERVED (not yet implemented): remember the last run per project

---@class LvimDapConfig
---@field log_level            lvim-dap.log.Level   file-log verbosity (trace|debug|info|warn|error)
---@field stepping_granularity "statement"|"line"|"instruction"  default step granularity
---@field auto_use             string[]             bundled adapter presets to register on setup
---@field terminal             { command: string?, position: string, close_on_exit: boolean }  runInTerminal window policy
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
        -- External terminal command template (e.g. "alacritty -e"): when set, a `runInTerminal`
        -- request runs the debuggee in that emulator (spawned detached) instead of an integrated
        -- split. nil = the integrated terminal buffer (the default).
        command = nil,
        position = "belowright",
        -- Close the debuggee's terminal (window + buffer) when its session ends. The window is the
        -- engine's own — without this every debug run leaves another dead terminal split behind.
        -- Set false to keep it: with `runInTerminal` the program's output goes to that terminal and
        -- NOT to the Console panel, so keeping it is the only way to read it after the run.
        close_on_exit = true,
    },
    signs = {
        -- Nerd Font, all single-width (verified with strdisplaywidth). These were EMPTY strings, which
        -- meant a breakpoint's extmark carried no `sign_text` at all — so breakpoints were invisible in
        -- the gutter / statuscolumn: set one and nothing appeared.
        breakpoint = "\u{f111}", -- ● a plain breakpoint
        breakpoint_condition = "\u{f192}", -- ◉ a conditional one
        breakpoint_rejected = "\u{f057}", -- ✖ the adapter refused it
        log_point = "\u{f27b}", -- 󰍡 a logpoint (prints, never stops)
        stopped = "➤",
    },
    persist = {
        breakpoints = false,
        last_run = false, -- RESERVED: not yet implemented (run_last is in-memory only, per Neovim session)
    },
    on_config = nil,
}
