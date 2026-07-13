-- lvim-dap.breakpoints: the user's breakpoints — the source of truth, independent of any session.
-- Breakpoints belong to BUFFERS, not to a debug session: a user sets them before launching and
-- they must survive edits, session restarts, and (opt-in) Neovim restarts. So each breakpoint is
-- an EXTMARK — it tracks the line as the buffer is edited (insert a line above and the mark, and
-- its gutter sign, move with the code), which `vim.fn.sign_place` cannot do. The extmark itself
-- carries the gutter sign (`sign_text`/`sign_hl_group`), so placement and anchoring are one object.
-- Metadata that a mark can't hold (condition / hitCondition / logMessage, and the adapter's
-- verified/rejected state) lives in a parallel table keyed by the mark id.
--
-- Four kinds, distinguished only by their fields + sign glyph: plain, conditional (`condition`),
-- logpoint (`logMessage` — prints instead of stopping), and rejected (the adapter refused it).
-- Exception breakpoints are session-level filter toggles, not buffer marks, and live in the engine.
--
-- Persistence is opt-in (`config.persist.breakpoints`): breakpoints are keyed by PROJECT ROOT +
-- relative path in a per-plugin `lvim-utils.store` json db, restored on BufReadPost. Nothing here
-- talks to a session; `init.lua` reads `get()` and pushes them via `session:set_breakpoints` on
-- `initialized` and on every toggle.
--
---@module "lvim-dap.breakpoints"

local config = require("lvim-dap.config")
local log = require("lvim-dap.log")

local M = {}

---@type integer  extmark namespace for breakpoints (signs ride on the marks)
local ns = vim.api.nvim_create_namespace("lvim-dap-breakpoints")

--- Per-buffer metadata for marks that carry more than a line. bufnr → mark_id → meta.
---@type table<integer, table<integer, { condition?: string, hitCondition?: string, logMessage?: string, verified?: boolean, message?: string }>>
local meta = {}

--- The project root markers used to key persisted breakpoints.
local ROOT_MARKERS = { ".git", "pyproject.toml", "go.mod", "package.json", "Cargo.toml", "build.zig" }

---@type table|false|nil  the lazily-opened store (json backend); false = tried and unavailable
local store = nil

--- The persistence store handle (opened lazily when persist is on). nil when disabled/unavailable.
---@return table?
local function get_store()
    if not config.persist.breakpoints then
        return nil
    end
    if store ~= nil then
        return store
    end
    local ok, mod = pcall(require, "lvim-utils.store")
    if not ok then
        store = false
        return nil
    end
    local ok2, handle = pcall(mod.new, {
        backend = "json",
        name = "lvim-dap",
        fields = { breakpoints = {} },
    })
    store = ok2 and handle or false
    return store or nil
end

--- The project root for a buffer (marker search, else cwd), used as the persistence key.
---@param bufnr integer
---@return string
local function project_root(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local root = name ~= "" and vim.fs.root(name, ROOT_MARKERS) or nil
    return vim.fs.normalize(root or vim.fn.getcwd())
end

--- Choose the sign name for a breakpoint from its fields/state.
---@param m { condition?: string, logMessage?: string, verified?: boolean }
---@return string
local function sign_for(m)
    if m.verified == false then
        return "LvimDapBreakpointRejected"
    elseif m.logMessage and m.logMessage ~= "" then
        return "LvimDapLogPoint"
    elseif m.condition and m.condition ~= "" then
        return "LvimDapBreakpointCondition"
    end
    return "LvimDapBreakpoint"
end

--- Glyph + hl for a sign name, from the live config/highlight groups.
---@param sign_name string
---@return string glyph, string hl
local function sign_style(sign_name)
    local map = {
        LvimDapBreakpoint = { config.signs.breakpoint, "LvimDapBreakpoint" },
        LvimDapBreakpointCondition = { config.signs.breakpoint_condition, "LvimDapBreakpointCondition" },
        LvimDapBreakpointRejected = { config.signs.breakpoint_rejected, "LvimDapBreakpointRejected" },
        LvimDapLogPoint = { config.signs.log_point, "LvimDapLogPoint" },
    }
    local e = map[sign_name] or map.LvimDapBreakpoint
    return e[1], e[2]
end

--- Place (or re-place) the extmark+sign for a breakpoint at a 1-based line.
---@param bufnr integer
---@param line integer  1-based
---@param m table  metadata
---@param id? integer  existing mark id to reuse
---@return integer mark_id
local function place(bufnr, line, m, id)
    local glyph, hl = sign_style(sign_for(m))
    -- An EMPTY glyph is not a sign: nvim then stores the extmark with no `sign_text`, and every gutter
    -- reader (the native signcolumn, a custom statuscolumn) skips it — the breakpoint exists but is
    -- INVISIBLE. Refuse to place a signless mark: fall back to the default glyph, so a misconfigured
    -- icon degrades to a visible breakpoint instead of a silent one.
    if glyph == nil or glyph == "" then
        glyph = "\u{f111}"
    end
    return vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
        id = id,
        sign_text = glyph,
        sign_hl_group = hl,
        right_gravity = false,
    })
end

--- All breakpoint marks in a buffer as `{ id, line }` (line is the CURRENT extmark line, 1-based).
---@param bufnr integer
---@return { id: integer, line: integer }[]
local function marks_in(bufnr)
    local raw = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    local out = {}
    for _, mk in ipairs(raw) do
        out[#out + 1] = { id = mk[1], line = mk[2] + 1 }
    end
    return out
end

--- The breakpoint mark (id + line) at a given line in a buffer, if any.
---@param bufnr integer
---@param line integer  1-based
---@return { id: integer, line: integer }?
local function mark_at(bufnr, line)
    for _, mk in ipairs(marks_in(bufnr)) do
        if mk.line == line then
            return mk
        end
    end
end

--- Persist the current breakpoints for a buffer's project (no-op when persistence is off).
---@param bufnr integer
local function persist(bufnr)
    local s = get_store()
    if not s then
        return
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return
    end
    local root = project_root(bufnr)
    local rel = vim.fs.normalize(name):gsub("^" .. vim.pesc(root .. "/"), "")
    local all = s.breakpoints or {}
    all[root] = all[root] or {}
    local list = {}
    for _, mk in ipairs(marks_in(bufnr)) do
        local m = (meta[bufnr] or {})[mk.id] or {}
        list[#list + 1] = {
            line = mk.line,
            condition = m.condition,
            hitCondition = m.hitCondition,
            logMessage = m.logMessage,
        }
    end
    if #list == 0 then
        all[root][rel] = nil
    else
        all[root][rel] = list
    end
    s.breakpoints = all -- assignment auto-persists (store live table)
end

--- Toggle a breakpoint at a buffer line. With `opts.replace` an existing one is replaced (so the
--- condition/log can be edited) instead of removed. `opts` holds condition/hit_condition/log_message.
---@param bufnr? integer
---@param line? integer  1-based
---@param opts? { condition?: string, hit_condition?: string, log_message?: string, replace?: boolean }
function M.toggle(bufnr, line, opts)
    opts = opts or {}
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    line = line or vim.api.nvim_win_get_cursor(0)[1]
    local existing = mark_at(bufnr, line)
    if existing then
        if not opts.replace then
            vim.api.nvim_buf_del_extmark(bufnr, ns, existing.id)
            if meta[bufnr] then
                meta[bufnr][existing.id] = nil
            end
            persist(bufnr)
            return
        end
    end
    local m = {
        condition = opts.condition,
        hitCondition = opts.hit_condition,
        logMessage = opts.log_message,
    }
    local id = place(bufnr, line, m, existing and existing.id or nil)
    meta[bufnr] = meta[bufnr] or {}
    meta[bufnr][id] = m
    persist(bufnr)
end

--- Set (force-place, replacing) a breakpoint at a line.
---@param bufnr? integer
---@param line? integer
---@param opts? table
function M.set(bufnr, line, opts)
    opts = vim.tbl_extend("force", opts or {}, { replace = true })
    M.toggle(bufnr, line, opts)
end

--- Remove any breakpoint at a line. Returns true if one was removed.
---@param bufnr integer
---@param line integer
---@return boolean
function M.remove(bufnr, line)
    local existing = mark_at(bufnr, line)
    if not existing then
        return false
    end
    vim.api.nvim_buf_del_extmark(bufnr, ns, existing.id)
    if meta[bufnr] then
        meta[bufnr][existing.id] = nil
    end
    persist(bufnr)
    return true
end

--- Clear all breakpoints (in `bufnr`, or every loaded buffer).
---@param bufnr? integer
function M.clear(bufnr)
    local bufs = bufnr and { bufnr } or vim.api.nvim_list_bufs()
    for _, b in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
            meta[b] = nil
            persist(b)
        end
    end
end

--- The breakpoints for one buffer as DAP-ready entries (current lines, sorted).
---@param bufnr integer
---@return { line: integer, condition?: string, hitCondition?: string, logMessage?: string, verified?: boolean, message?: string }[]
function M.get_buffer(bufnr)
    local list = {}
    for _, mk in ipairs(marks_in(bufnr)) do
        local m = (meta[bufnr] or {})[mk.id] or {}
        list[#list + 1] = {
            line = mk.line,
            condition = m.condition,
            hitCondition = m.hitCondition,
            logMessage = m.logMessage,
            verified = m.verified,
            message = m.message,
        }
    end
    table.sort(list, function(a, b)
        return a.line < b.line
    end)
    return list
end

--- All breakpoints, grouped by bufnr (only buffers that have any).
---@return table<integer, table[]>
function M.get()
    local result = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
            local list = M.get_buffer(b)
            if #list > 0 then
                result[b] = list
            end
        end
    end
    return result
end

--- Update a breakpoint's verified state from an adapter `breakpoint` event / setBreakpoints
--- response (matched by line within a buffer path).
---@param path string
---@param line integer
---@param verified boolean
---@param message? string
function M.set_verified(path, line, verified, message)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 then
        return
    end
    local mk = mark_at(bufnr, line)
    if not mk then
        return
    end
    meta[bufnr] = meta[bufnr] or {}
    local m = meta[bufnr][mk.id] or {}
    m.verified = verified
    m.message = message
    meta[bufnr][mk.id] = m
    place(bufnr, line, m, mk.id) -- re-place to update the sign (rejected glyph)
end

--- Build a quickfix list of all breakpoints.
---@return table[]
function M.to_qf()
    local items = {}
    for bufnr, list in pairs(M.get()) do
        for _, bp in ipairs(list) do
            local text = (vim.api.nvim_buf_get_lines(bufnr, bp.line - 1, bp.line, false)[1] or ""):gsub("^%s+", "")
            local extra = {}
            if bp.condition then
                extra[#extra + 1] = "cond: " .. bp.condition
            end
            if bp.logMessage then
                extra[#extra + 1] = "log: " .. bp.logMessage
            end
            if bp.verified == false then
                extra[#extra + 1] = "rejected" .. (bp.message and (": " .. bp.message) or "")
            end
            items[#items + 1] = {
                bufnr = bufnr,
                lnum = bp.line,
                col = 1,
                text = #extra > 0 and (text .. "  [" .. table.concat(extra, ", ") .. "]") or text,
            }
        end
    end
    return items
end

--- Restore persisted breakpoints for a buffer (called on BufReadPost). No-op when persistence off.
---@param bufnr integer
function M.restore_buffer(bufnr)
    local s = get_store()
    if not s then
        return
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return
    end
    local root = project_root(bufnr)
    local rel = vim.fs.normalize(name):gsub("^" .. vim.pesc(root .. "/"), "")
    local list = ((s.breakpoints or {})[root] or {})[rel]
    if not list then
        return
    end
    for _, bp in ipairs(list) do
        if not mark_at(bufnr, bp.line) then
            local m = { condition = bp.condition, hitCondition = bp.hitCondition, logMessage = bp.logMessage }
            local id = place(bufnr, bp.line, m)
            meta[bufnr] = meta[bufnr] or {}
            meta[bufnr][id] = m
        end
    end
    log.debug("breakpoints: restored", #list, "for", rel)
end

--- Re-persist a buffer's breakpoints at their CURRENT lines. Public because the lines drift under
--- editing (that is the whole point of anchoring them to extmarks) while the on-disk copy is only
--- rewritten when a breakpoint is toggled — so without this, editing above a breakpoint and restarting
--- restored it at its OLD line, i.e. onto the wrong statement.
---@param bufnr integer
function M.persist_buffer(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        persist(bufnr)
    end
end

--- Install the restore autocmd (idempotent). Called from init.setup when persistence is enabled.
function M.setup_persistence()
    if not config.persist.breakpoints then
        return
    end
    local group = vim.api.nvim_create_augroup("lvim-dap.breakpoints.restore", { clear = true })
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,
        callback = function(ev)
            M.restore_buffer(ev.buf)
        end,
    })
    -- Writing the file is when the buffer's lines become the truth on disk — so it is exactly when the
    -- breakpoints' (extmark-tracked, possibly shifted) lines must be re-persisted.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(ev)
            M.persist_buffer(ev.buf)
        end,
    })
    -- Restore already-loaded buffers too (setup may run after files open).
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            M.restore_buffer(b)
        end
    end
end

return M
