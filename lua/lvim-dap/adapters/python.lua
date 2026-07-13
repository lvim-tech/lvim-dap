-- lvim-dap.adapters.python: the bundled debugpy preset (a pluggable adapter module).
-- This is the SHAPE every adapter preset follows — bundled or third-party: a self-contained
-- module that exposes `adapters` (nvim-dap-shaped specs), `configurations` (per filetype), and
-- an optional `setup(opts)` for customization. The user opts in with
-- `require("lvim-dap").use("python", { python = "…" })` — ZERO core edits, exactly like
-- lvim-cmp's register_source. Nothing about debugpy is known to the engine; it is discovered
-- through the registry like any other adapter.
--
-- debugpy speaks DAP over stdio when launched as `python -m debugpy.adapter`, so it is an
-- "executable" adapter. The python interpreter used to DEBUG defaults to a project venv if
-- present, else the first `python3`/`python` on PATH (override via setup `{ python = … }`).
--
---@module "lvim-dap.adapters.python"

local M = {}

--- Resolve the interpreter that RUNS the debuggee (and hosts debugpy). Prefers an activated
--- venv, then a project-local .venv/venv, then PATH.
---@param override string?
---@return string
local function resolve_python(override)
    if override and override ~= "" then
        return override
    end
    if vim.env.VIRTUAL_ENV then
        local p = vim.env.VIRTUAL_ENV .. "/bin/python"
        if vim.fn.executable(p) == 1 then
            return p
        end
    end
    for _, dir in ipairs({ ".venv", "venv" }) do
        local p = vim.fn.getcwd() .. "/" .. dir .. "/bin/python"
        if vim.fn.executable(p) == 1 then
            return p
        end
    end
    return vim.fn.executable("python3") == 1 and "python3" or "python"
end

--- Register the debugpy adapter + default python configurations.
---@param opts { python?: string, adapter_python?: string }?
function M.setup(opts)
    opts = opts or {}
    local registry = require("lvim-dap.registry")
    local debug_python = resolve_python(opts.python)
    -- The interpreter that HOSTS debugpy.adapter (can differ from the debuggee's).
    local adapter_python = opts.adapter_python or debug_python

    registry.register_adapter("debugpy", {
        type = "executable",
        command = adapter_python,
        args = { "-m", "debugpy.adapter" },
        options = { source_filetype = "python" },
    })

    registry.register_configuration("python", {
        {
            type = "debugpy",
            request = "launch",
            name = "Launch file",
            program = "${file}",
            pythonPath = debug_python,
            -- internalConsole (NOT integratedTerminal): the debuggee's stdout then arrives as DAP
            -- `output` events, which lvim-dap-view renders in its CONSOLE panel — where the rest of
            -- the session already lives. `integratedTerminal` would instead open a separate terminal
            -- split, leaving the Console panel empty. Use the "(terminal)" config below when the
            -- program needs STDIN — that is the one thing internalConsole cannot give it.
            console = "internalConsole",
            cwd = "${workspaceFolder}",
        },
        {
            type = "debugpy",
            request = "launch",
            name = "Launch file (terminal, for stdin)",
            program = "${file}",
            pythonPath = debug_python,
            console = "integratedTerminal",
            cwd = "${workspaceFolder}",
        },
        {
            type = "debugpy",
            request = "launch",
            name = "Launch file (stop on entry)",
            program = "${file}",
            stopOnEntry = true,
            pythonPath = debug_python,
            cwd = "${workspaceFolder}",
        },
        {
            type = "debugpy",
            request = "attach",
            name = "Attach (remote)",
            connect = { host = "127.0.0.1", port = 5678 },
            pythonPath = debug_python,
        },
    })
end

-- Also expose the static shape so `use()` can register without calling setup (defaults).
M.adapters = {}
M.configurations = {}

return M
