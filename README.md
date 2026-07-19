# lvim-dap

A Debug Adapter Protocol (DAP) client for Neovim — the debugging engine of the lvim-tech set.

lvim-dap is pure Lua with no native backend: it speaks the DAP JSON-RPC wire protocol directly to
a debug adapter over the adapter's **stdio**, a **TCP socket**, or a **named pipe**, and drives the
full request/response + event loop (sessions, threads, stack frames, scopes, variables, stepping,
breakpoints, evaluate/REPL, exceptions). The companion **lvim-dap-view** renders the UI.

Its defining trait is a **plug-and-play adapter registry**: a debug adapter is *added*, never
wired into the core. Registering an adapter + its configurations is one call — zero core edits —
and adapter/configuration tables use the widely-known shape, so existing per-language debug setups
port over unchanged.

## Highlights

- **Plug-and-play adapters** — `register_adapter` / `register_configuration`, bundled presets you
  opt into with `use("python")`, and third-party adapters discovered the same way
  (`:LvimDap adapters`, `:checkhealth lvim-dap`).
- **Three transports** — executable (stdio), server (TCP, incl. `${port}` free-port allocation and
  spawned-server + connect retries), and pipe.
- **Breakpoints** — line, conditional, hit-condition, and logpoints (extmark-anchored, so they
  track edits and survive buffer unload/`:bd` within the session), plus exception filters. Optional
  per-project persistence across restarts.
- **Full inspection** — threads → stack frames → scopes → variables (lazy), `evaluate` in
  repl/hover/watch contexts, `setVariable`, run-to-cursor, stepping (incl. reverse where supported).
- **Multi-session** — `startDebugging` child sessions and `runInTerminal`, with a focused-session
  model.
- **Self-theming gutter signs** — breakpoint/stopped signs are engine-owned and work with no UI
  loaded; colours track the lvim-utils palette.
- **`.vscode/launch.json`** — read on demand (JSONC + per-OS blocks).

## Requirements

- Neovim >= 0.10
- A debug adapter for your language on `PATH` (e.g. debugpy for Python, delve for Go,
  js-debug for Node, codelldb/lldb for C/C++/Rust). Install these with your OS package manager
  or the lvim-tech **lvim-installer**.
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette, merge, persistence store)

## Installation

With the lvim-tech **lvim-installer**, or Neovim's native `vim.pack`:

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-dap" },
})
```

## Quick start

```lua
local dap = require("lvim-dap")
dap.setup()

-- Opt into a bundled adapter preset (registers the adapter + default configurations):
dap.use("python") -- debugpy

-- Then debug:
vim.keymap.set("n", "<F9>", dap.toggle_breakpoint)
vim.keymap.set("n", "<F5>", dap.continue)
vim.keymap.set("n", "<F10>", dap.step_over)
vim.keymap.set("n", "<F11>", dap.step_into)
vim.keymap.set("n", "<S-F11>", dap.step_out)
```

## Registering your own adapter

An adapter is a self-contained registration — no core changes:

```lua
local dap = require("lvim-dap")

-- executable (stdio) adapter
dap.register_adapter("debugpy", {
    type = "executable",
    command = "python",
    args = { "-m", "debugpy.adapter" },
})

-- server (TCP) adapter with an auto-allocated free port
dap.register_adapter("pwa-node", {
    type = "server",
    host = "127.0.0.1",
    port = "${port}",
    executable = { command = "js-debug-adapter", args = { "${port}" } },
})

-- configurations for a filetype
dap.register_configuration("python", {
    {
        type = "debugpy",
        request = "launch",
        name = "Launch file",
        program = "${file}",
    },
})
```

The assignment forms also work, so a table-shaped setup ports directly:

```lua
require("lvim-dap").adapters.debugpy = { type = "executable", command = "python", args = { "-m", "debugpy.adapter" } }
require("lvim-dap").configurations.python =
    { { type = "debugpy", request = "launch", name = "File", program = "${file}" } }
```

Adapters may also be a **factory** `function(callback, config)` that resolves an adapter table
asynchronously, and may carry an `enrich_config` hook — the standard adapter contract.

### Bundled presets

`require("lvim-dap").use("<name>")` loads `lvim-dap.adapters.<name>` and registers it. Bundled:

| name     | adapter | filetype |
|----------|---------|----------|
| `python` | debugpy | python   |

A third party ships a module of the same shape (`{ adapters = {...}, configurations = {...},
setup = function(opts) ... end }`) and the user calls `use("their.module")`.

## Configuration variables

Configuration string values expand the usual placeholders just before a session starts:
`${file}`, `${fileBasename}`, `${fileBasenameNoExtension}`, `${fileDirname}`, `${fileExtname}`,
`${relativeFile}`, `${workspaceFolder}`, `${workspaceFolderBasename}`, `${env:VAR}`. A value may
also be a `function` returning the value.

## Commands

`:LvimDap <subcommand>` — `continue`, `run`, `run_last`, `step_over`, `step_into`, `step_out`,
`step_back`, `up`, `down`, `pause`, `toggle_breakpoint`, `clear_breakpoints`, `breakpoints`
(quickfix), `run_to_cursor`, `terminate`, `disconnect`, `close`, `adapters` (list registered
adapters), `log` (open the log file).

## API

Run control: `run(config, opts)`, `run_last()`, `continue(opts)`, `run_to_cursor()`, `restart`,
`pause(thread_id)`, `terminate(opts)`, `disconnect(opts, cb)`, `close()`.
Stepping: `step_over`, `step_into`, `step_out`, `step_back`, `reverse_continue`.
Breakpoints: `toggle_breakpoint(cond?, hit?, log?)`, `set_breakpoint(...)`, `clear_breakpoints(all?)`,
`list_breakpoints(open?)`, `set_exception_breakpoints(filters, opts?)`.
Frames: `up()`, `down()`, `focus_frame()`, `set_variable(ref, name, value, cb?)`.
Introspection: `session()`, `sessions()`, `set_session(s)`, `status()`, `list_adapters()`.
Eval: `evaluate(expr, context?, cb?)`.
Registration: `register_adapter`, `register_configuration`, `register_provider`, `use`.
Hooks: `listeners.before/after.<event|request>[owner] = fn`, `listeners.on_session`,
`listeners.on_config` — the seam lvim-dap-view and user code subscribe to.

## Default configuration

Every option at its default value (mirrors `lua/lvim-dap/config.lua`):

```lua
require("lvim-dap").setup({
    log_level = "warn", -- trace | debug | info | warn | error (file log at stdpath("log")/lvim-dap.log)
    stepping_granularity = "statement", -- statement | line | instruction
    auto_use = {}, -- bundled presets to register on setup, e.g. { "python" }
    terminal = {
        command = nil, -- external terminal template, e.g. "alacritty -e"; nil = integrated split
        position = "belowright", -- where the integrated terminal split opens
        close_on_exit = true, -- close the integrated terminal (window + buffer) when the session ends
    },
    signs = {
        breakpoint = "",
        breakpoint_condition = "",
        breakpoint_rejected = "",
        log_point = "",
        stopped = "➤",
    },
    persist = {
        breakpoints = false, -- persist breakpoints per project root across sessions
        last_run = false, -- RESERVED: not yet implemented (run_last is in-memory only)
    },
    on_config = nil, -- fun(config): config — last-chance rewrite of a configuration before it runs
})
```

## Health

`:checkhealth lvim-dap` reports Neovim version, lvim-utils availability, each registered adapter's
executable resolution, loaded presets, and any conflicting DAP client.

## License

BSD-3-Clause. See [LICENSE](./LICENSE).
