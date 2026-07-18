-- lvim-dap.registry: the plug-and-play adapter + configuration registry (the extensibility core).
-- The whole point of this engine is that a debug adapter is ADDED, never wired-in: exactly the
-- philosophy of lvim-db's driver registry and lvim-cmp's `register_source`. Three tables, one
-- open registration seam:
--   • adapters[type]            → a dap.Adapter table OR a factory `fun(cb, config, parent)` that
--                                 resolves one (the nvim-dap adapter shape, verbatim — executable |
--                                 server | pipe, ${port}, spawned-server, enrich_config).
--   • configurations[filetype]  → a list of launch/attach configs (the nvim-dap shape).
--   • providers.configs[name]   → a function returning configs for the current buffer (the seam
--                                 launch.json plugs into, and any dynamic source).
-- A NEW adapter is therefore a self-contained module that calls `register_adapter` +
-- `register_configuration` once — ZERO core edits. Bundled presets under `lvim-dap.adapters.*`
-- are just such modules the user opts into via `use(name)`; a third party registers identically
-- and is DISCOVERED the same way (`list_adapters`, health, `:LvimDap adapters`). lvim-dap-view
-- reads THIS registry to show what can be launched. The engine itself only ever asks the
-- registry `get_adapter(type)` / `configs_for(bufnr)` — it never hardcodes a single adapter.
--
---@module "lvim-dap.registry"

local log = require("lvim-dap.log")

local M = {}

---@alias lvim-dap.AdapterFactory fun(callback: fun(adapter: table), config: table, parent?: table)

--- Registered adapters, keyed by `type` (the value referenced by a configuration's `type`).
---@type table<string, table|lvim-dap.AdapterFactory>
M.adapters = {}

--- Registered configurations, keyed by filetype.
---@type table<string, table[]>
M.configurations = {}

--- Config providers, keyed by an owner id. Each returns configs for a buffer. `dap.global`
--- (the registered `configurations[filetype]`) and `dap.launch.json` are built in; more may be
--- added by consumers.
---@type { configs: table<string, fun(bufnr: integer): table[]> }
M.providers = { configs = {} }

--- Names of adapters loaded via `use()` (bundled or third-party module id) — for reporting.
---@type table<string, boolean>
local loaded_modules = {}

--- Provenance by adapter TYPE: which preset name registered each type via `use()`. Distinct from
--- `loaded_modules` (keyed by the PRESET name, e.g. "python") — a preset's adapter type differs from
--- its name (e.g. `use("python")` registers the "debugpy" type), which is why `list_adapters` needs
--- this map to mark preset-loaded adapters as "preset" rather than mislabelling them "custom".
---@type table<string, string>
local preset_types = {}

--- Register a debug adapter under `type`. `spec` is a nvim-dap-shaped adapter table (with a
--- `type` field of "executable" | "server" | "pipe") or a factory function that resolves one.
--- Re-registering the same key replaces it (last wins), so a user can override a bundled preset.
---@param type string
---@param spec table|lvim-dap.AdapterFactory
function M.register_adapter(type, spec)
    assert(type and type ~= "", "register_adapter: `type` must be a non-empty string")
    assert(
        vim.is_callable(spec) or _G.type(spec) == "table",
        "register_adapter: `spec` must be an adapter table or a factory function"
    )
    M.adapters[type] = spec
    log.info("registry: registered adapter", type)
end

--- Register (append) configurations for a filetype. Duplicate `name`s already present are
--- replaced in place so re-running setup does not stack duplicates; new ones are appended.
---@param filetype string
---@param configs table[]  a list of dap.Configuration tables
function M.register_configuration(filetype, configs)
    assert(filetype and filetype ~= "", "register_configuration: `filetype` must be a non-empty string")
    assert(vim.islist(configs), "register_configuration: `configs` must be a list of configurations")
    local list = M.configurations[filetype] or {}
    for _, cfg in ipairs(configs) do
        assert(cfg.type, "configuration must have a `type` referencing a registered adapter")
        assert(cfg.name, "configuration must have a `name`")
        assert(cfg.request == "launch" or cfg.request == "attach", "configuration `request` must be launch|attach")
        local replaced = false
        for i, existing in ipairs(list) do
            if existing.name == cfg.name then
                list[i] = cfg
                replaced = true
                break
            end
        end
        if not replaced then
            list[#list + 1] = cfg
        end
    end
    M.configurations[filetype] = list
    log.info("registry: registered", #configs, "config(s) for filetype", filetype)
end

--- Add / replace a config PROVIDER by owner id. The engine merges every provider's output when
--- selecting a configuration to run — the extensible seam launch.json (and any dynamic source)
--- plugs into.
---@param id string
---@param provider fun(bufnr: integer): table[]
function M.register_provider(id, provider)
    assert(id and id ~= "", "register_provider: `id` must be non-empty")
    assert(vim.is_callable(provider), "register_provider: `provider` must be callable")
    M.providers.configs[id] = provider
end

--- Load a bundled preset (`lvim-dap.adapters.<name>`) or any module id that follows the preset
--- protocol, and register what it exposes. A preset module returns a table:
---   `{ adapters = { <type> = spec, … }, configurations = { <ft> = { … } }, setup = fun(opts) }`
--- or simply implements `setup(opts)` and self-registers. `opts` is forwarded to `setup`.
--- Idempotent-friendly: a preset is expected to register (which replaces), so calling twice is safe.
---@param name string     bundled name ("python") or a full module id
---@param opts? table     forwarded to the preset's setup
---@return boolean ok, string? err
function M.use(name, opts)
    local modname = name:find("%.") and name or ("lvim-dap.adapters." .. name)
    local ok, mod = pcall(require, modname)
    if not ok then
        log.error("registry: failed to load preset", modname, mod)
        return false, tostring(mod)
    end
    -- Snapshot the adapter types present BEFORE the preset registers so we can attribute the ones it
    -- adds to this preset (a preset registers via `setup`, whose adapter type — "debugpy" — differs
    -- from the preset name — "python"; this is the only reliable seam to record which is which).
    local before = {}
    for atype in pairs(M.adapters) do
        before[atype] = true
    end
    if type(mod) == "table" then
        for atype, spec in pairs(mod.adapters or {}) do
            M.register_adapter(atype, spec)
        end
        for ft, configs in pairs(mod.configurations or {}) do
            M.register_configuration(ft, configs)
        end
        if vim.is_callable(mod.setup) then
            mod.setup(opts)
        end
    elseif vim.is_callable(mod) then
        mod(opts)
    end
    for atype in pairs(M.adapters) do
        if not before[atype] then
            preset_types[atype] = name
        end
    end
    loaded_modules[name] = true
    return true
end

--- The adapter registered for `type` (table or factory), or nil.
---@param type string
---@return table|lvim-dap.AdapterFactory|nil
function M.get_adapter(type)
    return M.adapters[type]
end

--- The registered configuration list for `filetype` (never nil).
---@param filetype string
---@return table[]
function M.configs_for_filetype(filetype)
    return M.configurations[filetype] or {}
end

--- Every configuration applicable to `bufnr`, gathered from all providers (registered configs +
--- launch.json + any custom), in a stable provider order.
---@param bufnr integer
---@return table[]
function M.configs_for(bufnr)
    local all = {}
    local ids = vim.tbl_keys(M.providers.configs)
    table.sort(ids)
    for _, id in ipairs(ids) do
        local ok, configs = pcall(M.providers.configs[id], bufnr)
        if ok and vim.islist(configs) then
            vim.list_extend(all, configs)
        elseif not ok then
            log.warn("registry: provider", id, "errored:", configs)
        end
    end
    return all
end

--- A report of registered adapters: `{ { type, kind, source, filetypes, config_count } }`.
--- `kind` is the transport ("executable"/"server"/"pipe") or "factory"; `source` marks presets
--- loaded via `use`. Drives `:LvimDap adapters`, health, and the view's launch chooser.
---@return { type: string, kind: string, source: string, filetypes: string[], config_count: integer }[]
function M.list_adapters()
    -- filetypes + counts by scanning the configs that reference each adapter type.
    local fts_by_type, count_by_type = {}, {}
    for ft, configs in pairs(M.configurations) do
        for _, cfg in ipairs(configs) do
            local t = cfg.type
            count_by_type[t] = (count_by_type[t] or 0) + 1
            fts_by_type[t] = fts_by_type[t] or {}
            fts_by_type[t][ft] = true
        end
    end
    local out = {}
    for atype, spec in pairs(M.adapters) do
        local kind = vim.is_callable(spec) and "factory" or (type(spec) == "table" and spec.type or "?")
        local fts = vim.tbl_keys(fts_by_type[atype] or {})
        table.sort(fts)
        out[#out + 1] = {
            type = atype,
            kind = kind,
            source = preset_types[atype] and "preset" or "custom",
            filetypes = fts,
            config_count = count_by_type[atype] or 0,
        }
    end
    table.sort(out, function(a, b)
        return a.type < b.type
    end)
    return out
end

--- The set of preset/module ids loaded via `use()`.
---@return string[]
function M.loaded()
    local names = vim.tbl_keys(loaded_modules)
    table.sort(names)
    return names
end

return M
