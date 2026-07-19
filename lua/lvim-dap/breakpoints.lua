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

--- Per-buffer metadata for marks that carry more than a line. bufnr → mark_id → meta. `dap_id` is
--- the adapter's breakpoint id from the last setBreakpoints response — the seam a later `breakpoint`
--- EVENT (which reports the adapter's possibly-MOVED line, not the user's) is matched back by.
---@type table<integer, table<integer, { condition?: string, hitCondition?: string, logMessage?: string, verified?: boolean, message?: string, dap_id?: integer }>>
local meta = {}

--- In-memory breakpoint snapshots keyed by absolute PATH, taken on BufUnload. Extmarks die with the
--- buffer's marktree, so `:bd` + reopen (same bufnr) would otherwise silently lose every breakpoint
--- even with persistence OFF. This survives that within the Neovim session, independent of the json
--- store. Kept after wipeout too (harmless — a wiped buffer never re-fires restore, and it lets
--- `:bw` + reopen restore as well, matching nvim-dap's "breakpoints outlive the buffer" behaviour).
---@type table<string, { line: integer, condition?: string, hitCondition?: string, logMessage?: string }[]>
local unloaded = {}

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

--- Sign name → the `config.signs` field holding its glyph. Static (built once, not per placement);
--- the glyph itself is read LIVE from `config.signs` so a runtime override still takes effect. The
--- highlight group name equals the sign name for all four kinds.
---@type table<string, string>
local SIGN_GLYPH_KEY = {
    LvimDapBreakpoint = "breakpoint",
    LvimDapBreakpointCondition = "breakpoint_condition",
    LvimDapBreakpointRejected = "breakpoint_rejected",
    LvimDapLogPoint = "log_point",
}

--- Glyph + hl for a sign name, from the live config/highlight groups.
---@param sign_name string
---@return string glyph, string hl
local function sign_style(sign_name)
    local key = SIGN_GLYPH_KEY[sign_name]
    if not key then
        return config.signs.breakpoint, "LvimDapBreakpoint"
    end
    return config.signs[key], sign_name
end

--- Place (or re-place) the extmark+sign for a breakpoint at a 1-based line.
---@param bufnr integer
---@param line integer  1-based
---@param m table  metadata
---@param id? integer  existing mark id to reuse
---@return integer? mark_id  nil when the buffer is not loaded (nothing placed)
local function place(bufnr, line, m, id)
    -- Guard the mark API against a line that no longer exists. `restore_buffer` places at the PERSISTED
    -- line and `set_verified` at an adapter-reported one, either of which can exceed the buffer's
    -- CURRENT line count (the file shrank since — edited elsewhere, a git checkout). `nvim_buf_set_extmark`
    -- would then throw E5108 ("line value outside range") from inside a BufReadPost autocmd. Clamping to
    -- the last line (the root-cause fix, not a pcall swallow) keeps the breakpoint visible and lets it
    -- re-persist at its live line on the next write.
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        return nil
    end
    local max = vim.api.nvim_buf_line_count(bufnr)
    if line > max then
        line = max
    end
    if line < 1 then
        line = 1
    end
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

--- The breakpoint mark (id + line) at a given line in a buffer, if any. Uses the extmark API's
--- positional lookup (one call, no table build) instead of scanning every mark in the buffer.
---@param bufnr integer
---@param line integer  1-based
---@return { id: integer, line: integer }?
local function mark_at(bufnr, line)
    -- A row outside the buffer holds no mark (marks are anchored within it): return nil rather than
    -- letting the API reject an out-of-range position (an adapter can report a line past EOF).
    if line < 1 or line > vim.api.nvim_buf_line_count(bufnr) then
        return nil
    end
    local raw = vim.api.nvim_buf_get_extmarks(bufnr, ns, { line - 1, 0 }, { line - 1, -1 }, { limit = 1 })
    local mk = raw[1]
    if mk then
        return { id = mk[1], line = mk[2] + 1 }
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
    if not id then
        return
    end
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

--- Apply a verified/rejected verdict (+ optional adapter id) to one resolved mark and re-place it.
---@param bufnr integer
---@param mk { id: integer, line: integer }
---@param verified boolean
---@param message? string
---@param dap_id? integer
local function apply_verified(bufnr, mk, verified, message, dap_id)
    meta[bufnr] = meta[bufnr] or {}
    local m = meta[bufnr][mk.id] or {}
    m.verified = verified
    m.message = message
    if dap_id ~= nil then
        m.dap_id = dap_id
    end
    meta[bufnr][mk.id] = m
    place(bufnr, mk.line, m, mk.id) -- re-place to update the sign (rejected glyph)
end

--- Update a breakpoint's verified state from a setBreakpoints RESPONSE, matched by the USER `line`
--- (the mark is there on the response path). `dap_id` records the adapter's breakpoint id so a later
--- `breakpoint` EVENT for a MOVED line can be matched back by id (see `set_verified_by_id`).
---@param path string
---@param line integer
---@param verified boolean
---@param message? string
---@param dap_id? integer
function M.set_verified(path, line, verified, message, dap_id)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 then
        return
    end
    local mk = mark_at(bufnr, line)
    if not mk then
        return
    end
    apply_verified(bufnr, mk, verified, message, dap_id)
end

--- Update a breakpoint's verified state matched by the adapter's breakpoint `id` (the `breakpoint`
--- EVENT path). Scans `meta` for the recorded `dap_id` — so an adapter that MOVED the breakpoint to
--- another line, and reports that moved line in the event, still updates the right mark (matching by
--- the event's line would find no mark and silently drop the update). Returns true when one matched.
---@param dap_id integer
---@param verified boolean
---@param message? string
---@return boolean
function M.set_verified_by_id(dap_id, verified, message)
    for bufnr, marks in pairs(meta) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            for mark_id, m in pairs(marks) do
                if m.dap_id == dap_id then
                    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark_id, {})
                    if pos and pos[1] then
                        apply_verified(bufnr, { id = mark_id, line = pos[1] + 1 }, verified, message, dap_id)
                        return true
                    end
                end
            end
        end
    end
    return false
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
        -- Clamp BEFORE the dedupe check, not just inside place(): two persisted lines past a now-shorter
        -- file's EOF (90 and 100 into a 50-line file) both dedupe-miss at their ORIGINAL lines, then both
        -- place() clamps them onto line 50 → two marks on one line, duplicated on the wire. Dedupe at the
        -- clamped target instead.
        local target = math.min(bp.line, vim.api.nvim_buf_line_count(bufnr))
        if target >= 1 and not mark_at(bufnr, target) then
            local m = { condition = bp.condition, hitCondition = bp.hitCondition, logMessage = bp.logMessage }
            local id = place(bufnr, target, m)
            if id then
                meta[bufnr] = meta[bufnr] or {}
                meta[bufnr][id] = m
            end
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

--- Snapshot a buffer's breakpoints (marks + their meta) into `unloaded[path]` before its marktree
--- dies, and drop the buffer's `meta` (extmarks are already gone / going). Named buffers only.
---@param bufnr integer
local function snapshot_unloaded(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
        local marks = marks_in(bufnr)
        if #marks > 0 then
            local list = {}
            for _, mk in ipairs(marks) do
                local m = (meta[bufnr] or {})[mk.id] or {}
                list[#list + 1] = {
                    line = mk.line,
                    condition = m.condition,
                    hitCondition = m.hitCondition,
                    logMessage = m.logMessage,
                }
            end
            unloaded[vim.fs.normalize(name)] = list
        end
    end
    meta[bufnr] = nil
end

--- Re-place breakpoints captured for this buffer's path on BufUnload (independent of the json store).
---@param bufnr integer
local function restore_unloaded(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return
    end
    local key = vim.fs.normalize(name)
    local list = unloaded[key]
    if not list then
        return
    end
    unloaded[key] = nil
    for _, bp in ipairs(list) do
        local target = math.min(bp.line, vim.api.nvim_buf_line_count(bufnr))
        if target >= 1 and not mark_at(bufnr, target) then
            local m = { condition = bp.condition, hitCondition = bp.hitCondition, logMessage = bp.logMessage }
            local id = place(bufnr, target, m)
            if id then
                meta[bufnr] = meta[bufnr] or {}
                meta[bufnr][id] = m
            end
        end
    end
end

--- Install the buffer-lifecycle autocmds (idempotent). Called UNCONDITIONALLY from init.setup — NOT
--- gated on persistence. Two jobs:
---   • BufUnload snapshots breakpoints by PATH so `:bd` + reopen (same bufnr) does not silently lose
---     them — extmarks die with the buffer's marktree, so without this the gutter just goes empty with
---     no signal. BufReadPost restores from that snapshot. This works with persistence OFF.
---   • Dropping `meta[buf]` (on unload AND wipeout) is also the leak/mis-attach fix: Neovim REUSES
---     buffer numbers and restarts extmark ids per namespace, so a fresh mark id in a REUSED bufnr
---     could otherwise resolve against the old buffer's metadata (a plain breakpoint silently
---     inheriting a stale condition, then pushed to the adapter).
function M.setup_lifecycle()
    local group = vim.api.nvim_create_augroup("lvim-dap.breakpoints.lifecycle", { clear = true })
    vim.api.nvim_create_autocmd("BufUnload", {
        group = group,
        callback = function(ev)
            snapshot_unloaded(ev.buf)
        end,
    })
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,
        callback = function(ev)
            restore_unloaded(ev.buf)
        end,
    })
    -- Wipeout of a buffer that was never unloaded first is rare but possible; clear its meta too.
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(ev)
            meta[ev.buf] = nil
        end,
    })
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
