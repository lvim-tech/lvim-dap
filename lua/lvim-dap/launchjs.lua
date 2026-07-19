-- lvim-dap.launchjs: read debug configurations from `.vscode/launch.json`.
-- VS Code projects ship their debug configs here; reading them on demand means a user's existing
-- project "just works" without re-declaring configs in Lua. The file is JSONC (comments +
-- trailing commas), so it is parsed with `vim.json.decode`'s comment skipping. Per-OS blocks
-- (`linux`/`osx`/`windows`) are lifted onto the config. Interactive `inputs` (${input:*}
-- promptString/pickString) are DEFERRED to a later phase (they need the lvim-ui input/select
-- pickers) and noted in findings — a config that references an unresolved input is still
-- returned, with the placeholder left verbatim.
--
---@module "lvim-dap.launchjs"

local log = require("lvim-dap.log")

local M = {}

--- The OS key VS Code uses for platform-specific overrides.
---@return string?
local function sysname()
    if vim.fn.has("linux") == 1 then
        return "linux"
    elseif vim.fn.has("mac") == 1 then
        return "osx"
    elseif vim.fn.has("win32") == 1 then
        return "windows"
    end
end

--- Merge a per-OS child block onto the top level.
---@param cfg table
---@param key string?
---@return table
local function lift(cfg, key)
    if key and type(cfg[key]) == "table" then
        local child = cfg[key]
        cfg[key] = nil
        return vim.tbl_extend("force", cfg, child)
    end
    return cfg
end

--- Strip JSONC extras (line/block comments + trailing commas) that `vim.json.decode` rejects,
--- without corrupting comment-like sequences inside string literals.
---@param s string
---@return string
local function strip_jsonc(s)
    local out = {}
    local i, n = 1, #s
    local in_str, esc = false, false
    -- Index in `out` of a comma awaiting a possible trailing-drop. Trailing-comma removal is done HERE,
    -- inside the string-aware scan — NOT as a final gsub over the whole text, which would also match a
    -- comma inside a STRING literal (e.g. `"delims": "a, ]"`) and silently corrupt the value. When the
    -- next non-whitespace, non-comment char outside a string is `]`/`}` we blank the pending comma; any
    -- other value char (including the opening quote of a next string) clears it as a real separator.
    ---@type integer?
    local pending_comma = nil
    while i <= n do
        local c = s:sub(i, i)
        if in_str then
            out[#out + 1] = c
            if esc then
                esc = false
            elseif c == "\\" then
                esc = true
            elseif c == '"' then
                in_str = false
            end
            i = i + 1
        elseif c == '"' then
            pending_comma = nil
            in_str = true
            out[#out + 1] = c
            i = i + 1
        elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
            local nl = s:find("\n", i, true)
            i = nl or (n + 1)
        elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
            local close = s:find("*/", i + 2, true)
            i = close and (close + 2) or (n + 1)
        elseif c == "," then
            out[#out + 1] = c
            pending_comma = #out
            i = i + 1
        elseif c:match("%s") then
            out[#out + 1] = c
            i = i + 1
        else
            if pending_comma and (c == "]" or c == "}") then
                out[pending_comma] = ""
            end
            pending_comma = nil
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

--- Parse a launch.json string into a list of configurations.
---@param jsonstr string
---@return table[]
function M.parse(jsonstr)
    local cleaned = strip_jsonc(jsonstr)
    local ok, data = pcall(vim.json.decode, cleaned, { luanil = { object = true, array = true } })
    if not ok or type(data) ~= "table" then
        log.warn("launchjs: parse failed:", data)
        return {}
    end
    local os_key = sysname()
    local configs = {}
    for _, cfg in ipairs(data.configurations or {}) do
        configs[#configs + 1] = lift(cfg, os_key)
    end
    return configs
end

--- Read `.vscode/launch.json` from `path` (or cwd) and return its configurations. Empty when
--- the file is absent.
---@param path string?
---@return table[]
function M.getconfigs(path)
    local resolved = path or (vim.fn.getcwd() .. "/.vscode/launch.json")
    if vim.fn.filereadable(resolved) == 0 then
        return {}
    end
    local ok, lines = pcall(vim.fn.readfile, resolved)
    if not ok then
        return {}
    end
    return M.parse(table.concat(lines, "\n"))
end

return M
