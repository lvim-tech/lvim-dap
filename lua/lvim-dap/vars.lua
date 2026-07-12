-- lvim-dap.vars: launch-configuration value resolution (the ${...} placeholders + callables).
-- A configuration is data with holes: `program = "${file}"`, `cwd = "${workspaceFolder}"`,
-- `env = { TOKEN = "${env:TOKEN}" }`, and values that are FUNCTIONS to be called at run time
-- (`port = function() return pick() end`). Just before a session starts, every leaf is resolved
-- here — recursively, preserving table shape. This matches nvim-dap's placeholder set so ported
-- configs behave identically. Interactive placeholders (${command:pickProcess|pickFile}) and
-- launch.json ${input:*} are DEFERRED (they need the lvim-ui pickers) and recorded in findings;
-- an unresolved placeholder is left verbatim rather than guessed.
--
---@module "lvim-dap.vars"

local M = {}

--- The static ${...} → value map, evaluated against the current buffer/cwd at resolve time.
---@return table<string, fun(match?: string): string>
local function placeholders()
    return {
        ["${file}"] = function()
            return vim.fn.expand("%:p")
        end,
        ["${fileBasename}"] = function()
            return vim.fn.expand("%:t")
        end,
        ["${fileBasenameNoExtension}"] = function()
            return vim.fn.fnamemodify(vim.fn.expand("%:t"), ":r")
        end,
        ["${fileDirname}"] = function()
            return vim.fn.expand("%:p:h")
        end,
        ["${fileExtname}"] = function()
            return vim.fn.expand("%:e")
        end,
        ["${relativeFile}"] = function()
            return vim.fn.expand("%:.")
        end,
        ["${workspaceFolder}"] = function()
            return vim.fn.getcwd()
        end,
        ["${workspaceFolderBasename}"] = function()
            return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
        end,
    }
end

--- Resolve one value: call callables, substitute placeholders in strings, recurse into tables.
---@param value any
---@param subs table<string, fun(match?: string): string>
---@return any
local function resolve(value, subs)
    if type(value) == "function" then
        value = value()
    end
    if type(value) == "table" then
        local out = {}
        for k, v in pairs(value) do
            out[resolve(k, subs)] = resolve(v, subs)
        end
        return out
    end
    if type(value) ~= "string" then
        return value
    end
    local ret = value
    for key, fn in pairs(subs) do
        if ret:find(key, 1, true) then
            ret = ret:gsub(vim.pesc(key), function()
                return fn()
            end)
        end
    end
    -- ${env:VAR}
    ret = ret:gsub("${env:([%w_]+)}", function(name)
        return os.getenv(name) or ""
    end)
    return ret
end

--- Resolve every placeholder/callable in a configuration table (returns a new table).
---@param config table
---@return table
function M.expand(config)
    return resolve(config, placeholders())
end

return M
