-- lvim-dap: a Debug Adapter Protocol client for Neovim (a clean-room lvim-tech engine).
-- Pure Lua, no native backend: it speaks DAP JSON-RPC over a debug adapter's stdio / a TCP
-- socket / a named pipe, drives the request-response + event loop, and exposes an nvim-dap-shaped
-- public API so existing per-language setups port over by a require-path change only.
--
-- The defining trait is the PLUG-AND-PLAY ADAPTER REGISTRY (lvim-dap.registry): a debug adapter
-- is ADDED, never wired-in. `register_adapter` / `register_configuration` (or the nvim-dap-style
-- `require("lvim-dap").adapters.<type> = {…}` assignment) register a self-contained adapter with
-- ZERO core edits; bundled presets under `lvim-dap.adapters.*` are opted into with `use("python")`;
-- a third party registers identically and is discovered the same way (`:LvimDap adapters`, health).
-- lvim-dap-view reads the registry + the listener bus to render the debugger UI.
--
-- This module is the public facade: registration passthrough, run control (run/continue/step_*/
-- terminate), session bookkeeping, the reverse-request handlers (runInTerminal, startDebugging),
-- the gutter signs, and the :LvimDap command. Heavy protocol work lives in lvim-dap.session.
--
---@module "lvim-dap"

local config = require("lvim-dap.config")
local registry = require("lvim-dap.registry")
local listeners = require("lvim-dap.listeners")
local Session = require("lvim-dap.session")
local breakpoints = require("lvim-dap.breakpoints")
local vars = require("lvim-dap.vars")
local launchjs = require("lvim-dap.launchjs")
local async = require("lvim-dap.async")
local log = require("lvim-dap.log")

local ok_utils, utils = pcall(require, "lvim-utils.utils")
local ok_hl, highlight = pcall(require, "lvim-utils.highlight")

local M = {}

--- Deep-merge `src` into `dst` IN PLACE — maps recurse, lists/scalars replace wholesale. A local
--- stand-in for `lvim-utils.utils.merge`, used only on the setup fallback path when lvim-utils is
--- absent, so the live `config` table is mutated (never rebound) and every reader sees the overrides.
---@param dst table
---@param src table
local function merge_in_place(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" and not vim.islist(v) then
            merge_in_place(dst[k], v)
        else
            dst[k] = v
        end
    end
end

--- Root sessions keyed by id (the view's session tree; children hang off `session.children`).
---@type table<integer, lvim-dap.Session>
local sessions = {}

--- EVERY live session (roots AND startDebugging children), keyed by id. A child (js-debug's real
--- debugger) is not in `sessions`, so global operations that only walked `sessions` skipped it: a
--- breakpoint toggled mid-run never reached the child, `terminate({all})`/VimLeavePre left its
--- socket open, and `first_stopped` could not find a stopped child. This flat registry is the single
--- list every such operation iterates; `sessions` stays roots-only for the tree view.
---@type table<integer, lvim-dap.Session>
local all_sessions = {}

--- The focused session (drives step/continue/eval when several run).
---@type lvim-dap.Session?
local session = nil

--- The last-run { config, opts }, for run_last().
---@type { config: table, opts: table }?
local last_run = nil

--- Namespace for the stopped-line extmark/sign.
local STOPPED_SIGN = "LvimDapStopped"
local registered = false

-- ── public registration passthrough (the plug-and-play seam) ─────────────────

M.registry = registry
M.listeners = listeners

--- Register a debug adapter (nvim-dap-shaped table or a factory). ZERO core edits needed.
---@param type string
---@param spec table|lvim-dap.AdapterFactory
function M.register_adapter(type, spec)
    registry.register_adapter(type, spec)
end

--- Register (append) configurations for a filetype.
---@param filetype string
---@param configs table[]
function M.register_configuration(filetype, configs)
    registry.register_configuration(filetype, configs)
end

--- Register a config provider by owner id (the seam launch.json / dynamic sources use).
---@param id string
---@param provider fun(bufnr: integer): table[]
function M.register_provider(id, provider)
    registry.register_provider(id, provider)
end

--- Opt into a bundled adapter preset (`lvim-dap.adapters.<name>`) or any preset-shaped module id.
---@param name string
---@param opts? table
---@return boolean ok, string? err
function M.use(name, opts)
    return registry.use(name, opts)
end

--- The registered adapters report (drives `:LvimDap adapters`, health, the view chooser).
---@return table[]
function M.list_adapters()
    return registry.list_adapters()
end

-- nvim-dap COMPAT: `require("lvim-dap").adapters.debugpy = {…}` and `.configurations.python = {…}`
-- assignment forms, proxied onto the registry so ported setups work unchanged.
M.adapters = setmetatable({}, {
    __index = function(_, k)
        return registry.adapters[k]
    end,
    __newindex = function(_, k, v)
        registry.register_adapter(k, v)
    end,
})
M.configurations = setmetatable({}, {
    __index = function(_, k)
        return registry.configurations[k]
    end,
    __newindex = function(_, k, v)
        registry.configurations[k] = {} -- replace wholesale (nvim-dap assignment semantics)
        registry.register_configuration(k, v)
    end,
})

-- ── signs (engine-owned; work with no UI loaded) ─────────────────────────────

--- Define the highlight groups + signs from the live palette. Idempotent.
local function define_signs()
    if ok_hl then
        highlight.bind(function()
            local ok_c, c = pcall(require, "lvim-utils.colors")
            local p = ok_c and c or {}
            return {
                LvimDapBreakpoint = { fg = p.red or "#cb4f4f" },
                LvimDapBreakpointCondition = { fg = p.yellow or "#af9e6b" },
                LvimDapBreakpointRejected = { fg = p.fg_dim or p.fg or "#5a6158" },
                LvimDapLogPoint = { fg = p.blue or "#42728b" },
                LvimDapStopped = { fg = p.green or "#75783a", bold = true },
                LvimDapStoppedLine = {
                    bg = (ok_hl and highlight.blend and highlight.blend(p.green or "#75783a", p.bg or "#23292d", 0.15))
                        or nil,
                },
            }
        end)
    end
    local defs = {
        [STOPPED_SIGN] = { text = config.signs.stopped, texthl = "LvimDapStopped", linehl = "LvimDapStoppedLine" },
        LvimDapBreakpoint = { text = config.signs.breakpoint, texthl = "LvimDapBreakpoint" },
        LvimDapBreakpointCondition = {
            text = config.signs.breakpoint_condition,
            texthl = "LvimDapBreakpointCondition",
        },
        LvimDapBreakpointRejected = { text = config.signs.breakpoint_rejected, texthl = "LvimDapBreakpointRejected" },
        LvimDapLogPoint = { text = config.signs.log_point, texthl = "LvimDapLogPoint" },
    }
    for name, opts in pairs(defs) do
        pcall(vim.fn.sign_define, name, opts)
    end
end

--- The first NORMAL code window in the current tabpage: not a float (`relative == ""`) and holding
--- an ordinary buffer (`buftype == ""`). The `buftype` test is the root-cause seam — it rejects
--- EVERY panel/terminal/prompt/help window generically, without a hard-coded filetype list, so the
--- stopped-frame jump never loads the source INTO a debugger dock, a tree, a terminal, or any float.
---@return integer?
local function first_code_win()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
        local buf = vim.api.nvim_win_get_buf(win)
        if ok_cfg and cfg.relative == "" and vim.bo[buf].buftype == "" then
            return win
        end
    end
    return nil
end

--- Place the stopped-line sign at a frame's source location and move the cursor there.
---@param s lvim-dap.Session
local function jump_to_frame(s)
    local frame = s.current_frame
    if not frame or not frame.source or not frame.source.path then
        return
    end
    vim.fn.sign_unplace("lvim-dap-stopped")
    local path = frame.source.path
    local bufnr = vim.fn.bufadd(path)
    -- `bufload` can THROW (a stale swap file → E325/ATTENTION aborted, or other load failures); this
    -- runs inside the scheduled frame_updated listener, so an unguarded throw would surface as an
    -- autocmd error and skip the sign/cursor logic. A load failure means there is nothing to jump to.
    local loaded = pcall(vim.fn.bufload, bufnr)
    if not loaded or not vim.api.nvim_buf_is_loaded(bufnr) then
        return
    end
    pcall(vim.fn.sign_place, 0, "lvim-dap-stopped", STOPPED_SIGN, bufnr, { lnum = frame.line, priority = 22 })
    -- Reuse a window already showing the buffer; else load it into a normal code window (never a
    -- float/panel/terminal — see first_code_win); only if none exists, fall back to the current one.
    local win = vim.fn.bufwinid(bufnr)
    if win == -1 then
        win = first_code_win() or vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, bufnr)
    end
    pcall(vim.api.nvim_win_set_cursor, win, { frame.line, math.max((frame.column or 1) - 1, 0) })
end

--- Clear the stopped sign (on continue/terminate).
local function clear_stopped_sign()
    pcall(vim.fn.sign_unplace, "lvim-dap-stopped")
end

-- ── reverse request handlers ─────────────────────────────────────────────────

--- Close the debuggee terminal a session opened (its window AND its buffer). No-op when the session
--- opened none, or when the user opted to keep it (`terminal.close_on_exit = false` — to read the
--- program's last output, which with `runInTerminal` never reaches the Console panel).
---@param s lvim-dap.Session
local function close_terminal(s)
    if not s then
        return
    end
    local buf = s.term_buf
    s.term_buf = nil
    if not buf or config.terminal.close_on_exit == false then
        return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

--- Answer `runInTerminal`: run the debuggee command in a terminal buffer and report its PID.
--- The window is OURS (we open it), so its lifecycle is ours too — `close_terminal` tears it down
--- when the session ends (`config.terminal.close_on_exit`); otherwise every debug run left another
--- dead terminal split behind, forever.
---@param s lvim-dap.Session
---@param request table
local function handle_run_in_terminal(s, request)
    local args = request.arguments or {}
    local cmd = args.args or {}

    -- External terminal: when `config.terminal.command` is set (e.g. "alacritty -e"), run the
    -- debuggee in the user's OWN terminal emulator instead of an integrated split — the emulator is
    -- spawned detached with `<template> <cmd>`. A detached emulator hides the debuggee's real PID from
    -- us, so no `processId` is reported (best-effort, which the DAP allows for the external kind).
    if config.terminal.command and config.terminal.command ~= "" then
        local argv = vim.list_extend(vim.split(config.terminal.command, " ", { trimempty = true }), cmd)
        local ok_job, job = pcall(vim.fn.jobstart, argv, { cwd = args.cwd, env = args.env, detach = true })
        local started = ok_job and type(job) == "number" and job > 0
        s:respond(request, {}, started, started and nil or "failed to start external terminal")
        return
    end

    -- Integrated terminal: open a split we own and run the command in a terminal buffer.
    -- `jobstart(cmd, { term = true })` is the non-deprecated form of termopen; it THROWS on an invalid
    -- argv (an empty `args.args`, ENOENT), so pcall it and, on any failure, tear the just-created split
    -- down rather than leaving a dead empty terminal behind for the rest of the session.
    local prev = vim.api.nvim_get_current_win()
    vim.cmd(config.terminal.position .. " new")
    local term_win = vim.api.nvim_get_current_win()
    local term_buf = vim.api.nvim_get_current_buf()
    local ok_job, job = pcall(vim.fn.jobstart, cmd, { cwd = args.cwd, env = args.env, term = true })
    local pid = (ok_job and type(job) == "number" and job > 0) and vim.fn.jobpid(job) or nil
    if not pid then
        s.term_buf = nil
        pcall(vim.api.nvim_win_close, term_win, true)
        pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
        if vim.api.nvim_win_is_valid(prev) then
            vim.api.nvim_set_current_win(prev)
        end
        s:respond(request, nil, false, "failed to start terminal")
        return
    end
    s.term_buf = term_buf
    -- The terminal dies WITH the session that spawned it. `Session:close()` is the single funnel every
    -- ending path runs through (a `terminated` event, an explicit terminate/disconnect, a dead adapter),
    -- so its on_close hook — not the event listeners, which some of those paths never emit — is what
    -- guarantees no orphan terminal is ever left behind.
    s.on_close["lvim-dap.terminal"] = function(closed)
        vim.schedule(function()
            close_terminal(closed)
        end)
    end
    vim.api.nvim_set_current_win(prev)
    s:respond(request, { processId = pid }, true)
end

--- Answer `startDebugging`: launch a CHILD session sharing the parent's adapter.
---@param s lvim-dap.Session
---@param request table
local function handle_start_debugging(s, request)
    local args = request.arguments or {}
    -- The child configuration IS `arguments.configuration` (+ `arguments.request`) — the adapter sends
    -- it complete. Merging the PARENT config underneath (as before) leaks parent-only keys (`program`,
    -- `stopOnEntry`, `args`, `console`, …) into a child that is typically an `attach`, which adapters
    -- that validate their config or branch on key presence then choke on. Take the child's own config.
    local child_config = vim.deepcopy(args.configuration or {})
    child_config.request = args.request or child_config.request or "attach"
    child_config.name = child_config.name or ((s.config.name or "debug") .. " (child)")
    s:respond(request, nil, true)
    M.run(child_config, { parent = s, adapter = s.adapter })
end

--- Wire the reverse handlers onto a session.
---@param s lvim-dap.Session
local function wire_reverse(s)
    s.reverse_handlers = {
        runInTerminal = handle_run_in_terminal,
        startDebugging = handle_start_debugging,
    }
end

-- ── session bookkeeping ──────────────────────────────────────────────────────

--- Set the focused session, firing on_session listeners.
---@param s lvim-dap.Session?
function M.set_session(s)
    if session and s and session.id == s.id then
        return
    end
    local old = session
    if not s then
        local _, any = next(sessions)
        s = any
    end
    if s and not s.parent then
        sessions[s.id] = s
    end
    session = s
    for _, fn in pairs(listeners.on_session) do
        pcall(fn, old, s)
    end
end

--- The first stopped session (else the focused one, else any).
---@return lvim-dap.Session?
local function first_stopped()
    if session and session.stopped_thread_id then
        return session
    end
    for _, s in pairs(all_sessions) do
        if s.stopped_thread_id then
            return s
        end
    end
    return session or select(2, next(all_sessions))
end

--- Register the on-close reset + the frame-jump listener once.
local function ensure_wired()
    if registered then
        return
    end
    registered = true
    listeners.after.frame_updated["lvim-dap.jump"] = function(s)
        vim.schedule(function()
            jump_to_frame(s)
        end)
    end
    listeners.after.event_continued["lvim-dap.sign"] = function()
        vim.schedule(clear_stopped_sign)
    end
    listeners.after.event_terminated["lvim-dap.sign"] = function()
        vim.schedule(clear_stopped_sign)
    end
    -- Adapter `breakpoint` events carry verified/rejected state → reflect it in the gutter. Resolve the
    -- mark by the adapter's breakpoint `id` FIRST (recorded from the setBreakpoints response): an
    -- adapter commonly MOVES a breakpoint to the next executable line and reports that moved line here,
    -- which has no mark, so matching by line alone would silently drop the update. Fall back to the line
    -- for adapters that omit ids.
    listeners.after.event_breakpoint["lvim-dap.verify"] = function(_, body)
        local bp = body and body.breakpoint
        if not bp then
            return
        end
        vim.schedule(function()
            if bp.id and breakpoints.set_verified_by_id(bp.id, bp.verified ~= false, bp.message) then
                return
            end
            if bp.source and bp.source.path and bp.line then
                breakpoints.set_verified(bp.source.path, bp.line, bp.verified ~= false, bp.message)
            end
        end)
    end
end

-- ── breakpoints + exceptions (engine ↔ session bridge) ───────────────────────

--- The currently selected exception filter ids (nil = use the adapter's advertised defaults).
---@type string[]?
local exception_filters = nil

--- Push one buffer's breakpoints to a session (or, with no session, to every active session).
---@param bufnr integer
---@param s? lvim-dap.Session
local function broadcast_breakpoints(bufnr, s)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        return
    end
    local bps = breakpoints.get_buffer(bufnr)
    -- Target EVERY live session (children included) so a mid-run toggle reaches js-debug's child, which
    -- is the session actually debugging the program — walking only roots left it armed with the old set.
    local targets = s and { s } or vim.tbl_values(all_sessions)
    for _, sess in ipairs(targets) do
        if not sess.closed then
            -- Callback-style: `set_breakpoints` never yields when an `on_result` is given, so no
            -- coroutine is needed (an `async.run` here would only imply an await that never happens).
            sess:set_breakpoints(path, bps, function(_, body)
                -- Reflect the adapter's verified verdict per returned breakpoint.
                if body and body.breakpoints then
                    for i, rbp in ipairs(body.breakpoints) do
                        local src = bps[i]
                        if src then
                            -- Record the adapter's breakpoint id so a later `breakpoint` EVENT for a
                            -- MOVED line matches back by id (see the event_breakpoint listener).
                            breakpoints.set_verified(path, src.line, rbp.verified ~= false, rbp.message, rbp.id)
                        end
                    end
                end
            end)
        end
    end
end

--- Push ALL user breakpoints (every buffer) to a session — used on `initialized`.
---@param s lvim-dap.Session
local function push_all_breakpoints(s)
    for bufnr, bps in pairs(breakpoints.get()) do
        local path = vim.api.nvim_buf_get_name(bufnr)
        if path ~= "" then
            s:set_breakpoints(path, bps, function(_, body)
                if body and body.breakpoints then
                    for i, rbp in ipairs(body.breakpoints) do
                        if bps[i] then
                            breakpoints.set_verified(path, bps[i].line, rbp.verified ~= false, rbp.message, rbp.id)
                        end
                    end
                end
            end)
        end
    end
end

--- The default exception filter ids from a session's advertised capabilities (those flagged
--- `default = true`).
---@param s lvim-dap.Session
---@return string[]
local function default_exception_filters(s)
    local out = {}
    for _, f in ipairs((s.capabilities or {}).exceptionBreakpointFilters or {}) do
        if f.default then
            out[#out + 1] = f.filter
        end
    end
    return out
end

--- Push the selected (or default) exception filters to a session — used on `initialized`.
---@param s lvim-dap.Session
local function push_exception_filters(s)
    local filters = exception_filters or default_exception_filters(s)
    s:set_exception_breakpoints(filters)
end

-- ── run control ──────────────────────────────────────────────────────────────

--- Start a debug session for a fully-resolved adapter + configuration.
---@param adapter table
---@param resolved_config table
---@param opts table
local function launch(adapter, resolved_config, opts)
    log.info("run:", resolved_config.name, "via adapter", resolved_config.type)
    Session.launch(adapter, resolved_config, opts, function(err, s)
        if err or not s then
            vim.notify("lvim-dap: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        all_sessions[s.id] = s
        wire_reverse(s)
        -- On the `initialized` event: push every user breakpoint (per source) + the selected
        -- exception filters, THEN the session finishes configuration (configurationDone).
        s.on_initialized = function(sess)
            push_all_breakpoints(sess)
            push_exception_filters(sess)
        end
        s.on_close["lvim-dap.reset"] = function(closed)
            sessions[closed.id] = nil
            all_sessions[closed.id] = nil
            -- Detach a closed child from its parent's tree so dead sessions don't accumulate there.
            if closed.parent then
                closed.parent.children[closed.id] = nil
            end
            if session and session.id == closed.id then
                M.set_session(nil)
            end
            clear_stopped_sign()
        end
        if opts.parent then
            opts.parent.children[s.id] = s
            s.parent = opts.parent
        end
        M.set_session(s)
        s:initialize(resolved_config)
    end)
end

--- Resolve an adapter (table or factory), expand config vars, and launch.
---@param config_in table
---@param opts table?
function M.run(config_in, opts)
    assert(type(config_in) == "table", "lvim-dap.run: config must be a table")
    opts = opts or {}
    opts.filetype = opts.filetype or vim.bo.filetype
    -- Only ROOT runs are replayable by run_last. A startDebugging CHILD run carries a live parent
    -- Session (`opts.parent`) + its resolved adapter table (`opts.adapter`) — replaying that later
    -- would re-run the child config against a DEAD parent and bypass the registry. Never record it.
    if not opts.parent then
        last_run = { config = config_in, opts = opts }
    end
    ensure_wired()

    async.run(function()
        -- on_config listeners (+ the config.on_config hook) get last say over the config.
        local cfg = vim.deepcopy(config_in)
        for _, fn in pairs(listeners.on_config) do
            cfg = fn(cfg) or cfg
        end
        if config.on_config then
            cfg = config.on_config(cfg) or cfg
        end
        cfg = vars.expand(cfg)

        local adapter = opts.adapter or registry.get_adapter(cfg.type)
        if adapter == nil then
            vim.notify(
                ("lvim-dap: no adapter registered for `%s` (registered: %s)"):format(
                    cfg.type,
                    table.concat(vim.tbl_keys(registry.adapters), ", ")
                ),
                vim.log.levels.ERROR
            )
            return
        end
        if vim.is_callable(adapter) then
            ---@cast adapter function
            adapter(function(resolved)
                launch(resolved, cfg, opts)
            end, cfg, opts.parent)
        else
            ---@cast adapter table
            launch(adapter, cfg, opts)
        end
    end)
end

--- Re-run the last configuration.
function M.run_last()
    if last_run then
        M.run(last_run.config, last_run.opts)
    else
        vim.notify("lvim-dap: no previous configuration to run", vim.log.levels.INFO)
    end
end

--- Gather all configs for the current buffer and pick one (via lvim-ui.select) to run.
---@param opts table?
local function select_config_and_run(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local filetype = vim.bo[bufnr].filetype
    local configs = registry.configs_for(bufnr)
    if #configs == 0 then
        vim.notify(
            ("lvim-dap: no configuration for `%s` — register one (see :LvimDap adapters)"):format(filetype),
            vim.log.levels.INFO
        )
        return
    end
    if #configs == 1 then
        M.run(configs[1], opts)
        return
    end
    local ok_ui, ui = pcall(require, "lvim-ui")
    if ok_ui and ui.select then
        ui.select({
            title = "Debug configuration",
            items = vim.tbl_map(function(c)
                return { label = c.name, icon = "" }
            end, configs),
            callback = function(confirmed, index)
                if confirmed and configs[index] then
                    M.run(configs[index], opts)
                end
            end,
        })
    else
        M.run(configs[1], opts)
    end
end

--- Continue: with no session, choose+run a config; otherwise resume the stopped thread.
---@param opts table?
function M.continue(opts)
    opts = opts or {}
    if not session then
        M.set_session(first_stopped())
    end
    if not session or opts.new then
        select_config_and_run(opts)
    elseif session.stopped_thread_id then
        clear_stopped_sign()
        session:step("continue")
    else
        local stopped = first_stopped()
        if stopped and stopped.stopped_thread_id then
            stopped:step("continue")
        else
            vim.notify("lvim-dap: session active but not stopped", vim.log.levels.INFO)
        end
    end
end

--- Step helpers — each targets the first stopped session.
---@param opts table?
function M.step_over(opts)
    local s = first_stopped()
    if s then
        clear_stopped_sign()
        s:step("next", vim.tbl_extend("keep", opts or {}, { granularity = config.stepping_granularity }))
    end
end

---@param opts table?
function M.step_into(opts)
    local s = first_stopped()
    if s then
        clear_stopped_sign()
        s:step("stepIn", opts)
    end
end

---@param opts table?
function M.step_out(opts)
    local s = first_stopped()
    if s then
        clear_stopped_sign()
        s:step("stepOut", opts)
    end
end

---@param opts table?
function M.step_back(opts)
    local s = first_stopped()
    if s and s.capabilities.supportsStepBack then
        s:step("stepBack", opts)
    else
        vim.notify("lvim-dap: adapter does not support stepping back", vim.log.levels.WARN)
    end
end

---@param opts table?
function M.reverse_continue(opts)
    local s = first_stopped()
    if s and s.capabilities.supportsStepBack then
        s:step("reverseContinue", opts)
    end
end

--- Pause a thread on the focused session.
---@param thread_id integer?
function M.pause(thread_id)
    if session then
        session:pause(thread_id)
    end
end

-- ── breakpoints (public) ─────────────────────────────────────────────────────

--- Toggle a breakpoint on the current line. Optional condition / hit-condition / log-message make
--- it a conditional breakpoint or a logpoint. Broadcasts to every live session.
---@param condition? string
---@param hit_condition? string
---@param log_message? string
function M.toggle_breakpoint(condition, hit_condition, log_message)
    local bufnr = vim.api.nvim_get_current_buf()
    breakpoints.toggle(bufnr, nil, {
        condition = condition,
        hit_condition = hit_condition,
        log_message = log_message,
        replace = condition ~= nil or hit_condition ~= nil or log_message ~= nil,
    })
    broadcast_breakpoints(bufnr)
end

--- Set (force) a breakpoint on the current line with optional condition/hit/log.
---@param condition? string
---@param hit_condition? string
---@param log_message? string
function M.set_breakpoint(condition, hit_condition, log_message)
    local bufnr = vim.api.nvim_get_current_buf()
    breakpoints.set(bufnr, nil, {
        condition = condition,
        hit_condition = hit_condition,
        log_message = log_message,
    })
    broadcast_breakpoints(bufnr)
end

--- Clear all breakpoints (in the current buffer, or everywhere with `all`).
--- With `all`, EVERY buffer that had breakpoints must be re-broadcast (empty) to every live session,
--- not just the current one — otherwise a cleared file's breakpoints stay armed inside the adapter and
--- the debuggee keeps stopping at now-invisible lines.
---@param all? boolean
function M.clear_breakpoints(all)
    local affected = all and vim.tbl_keys(breakpoints.get()) or { vim.api.nvim_get_current_buf() }
    if all then
        breakpoints.clear(nil) -- every buffer (NB: `all and nil or x` would wrongly pick x)
    else
        breakpoints.clear(affected[1])
    end
    for _, b in ipairs(affected) do
        broadcast_breakpoints(b)
    end
end

--- Populate the quickfix list with all breakpoints (and open it unless `open == false`).
---@param open? boolean
function M.list_breakpoints(open)
    local items = breakpoints.to_qf()
    vim.fn.setqflist({}, " ", { items = items, title = "DAP Breakpoints" })
    if open ~= false then
        if #items == 0 then
            vim.notify("lvim-dap: no breakpoints set", vim.log.levels.INFO)
        else
            vim.cmd("copen")
        end
    end
end

--- Set exception breakpoint filters live on the focused session (and remember the selection so
--- new sessions inherit it). `filters` is a list of filter ids from the adapter's capabilities.
---@param filters string[]
---@param options? table[]
function M.set_exception_breakpoints(filters, options)
    exception_filters = filters
    -- Apply to EVERY live session (children included), not just the focused one — otherwise the other
    -- concurrent/child sessions keep the old exception behaviour, diverging from the UI's checkbox state.
    for _, s in pairs(all_sessions) do
        if not s.closed then
            s:set_exception_breakpoints(filters, options)
        end
    end
end

--- The exception filter descriptors advertised by the focused session's adapter (for the UI).
---@return table[]
function M.exception_filters()
    if not session then
        return {}
    end
    return (session.capabilities or {}).exceptionBreakpointFilters or {}
end

--- The currently selected exception filter ids (defaults resolved from the session when unset).
---@return string[]
function M.selected_exception_filters()
    if exception_filters then
        return exception_filters
    end
    return session and default_exception_filters(session) or {}
end

--- Run to the cursor line: set a temporary breakpoint there (removed on the next stop) and
--- continue. Only meaningful while stopped.
function M.run_to_cursor()
    local s = first_stopped()
    if not s or not s.stopped_thread_id then
        vim.notify("lvim-dap: run_to_cursor needs a stopped session", vim.log.levels.INFO)
        return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(bufnr)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    -- Snapshot real breakpoints, then push ONLY a temp bp at the cursor; restore on next stop.
    local saved = breakpoints.get_buffer(bufnr)
    local temp = { { line = lnum } }
    async.run(function()
        s:set_breakpoints(path, temp)
        -- Restore the real breakpoints on the NEXT stop or terminate — but also on the session's own
        -- close funnel: if the adapter process dies without ever emitting a `terminated` event, the two
        -- event listeners would never fire and would stay registered globally, leaking stale closures
        -- that the NEXT session's first stop then runs against this dead session. `Session:close()`
        -- pcall-runs on_close hooks, so it is the designed seam that catches every ending path.
        local restore = function()
            listeners.before.event_stopped["lvim-dap.run_to_cursor"] = nil
            listeners.before.event_terminated["lvim-dap.run_to_cursor"] = nil
            s.on_close["lvim-dap.run_to_cursor"] = nil
            if not s.closed then
                s:set_breakpoints(path, saved)
            end
        end
        listeners.before.event_stopped["lvim-dap.run_to_cursor"] = restore
        listeners.before.event_terminated["lvim-dap.run_to_cursor"] = restore
        s.on_close["lvim-dap.run_to_cursor"] = restore
        s:step("continue")
    end)
end

-- ── frame navigation ─────────────────────────────────────────────────────────

--- Move to an adjacent stack frame (delta > 0 = up toward callers).
---@param delta integer
local function frame_delta(delta)
    local s = first_stopped()
    if not s or not s.stopped_thread_id then
        return
    end
    local thread = s.threads[s.stopped_thread_id]
    local frames = thread and thread.frames
    if not frames or not s.current_frame then
        return
    end
    local idx
    for i, f in ipairs(frames) do
        if f.id == s.current_frame.id then
            idx = i
            break
        end
    end
    if not idx then
        return
    end
    local target = frames[idx + delta]
    if target then
        s.current_frame = target
        async.run(function()
            s:fetch_scopes(target)
            listeners.dispatch("after", "frame_updated", s)
        end)
    end
end

--- Focus the caller frame (up the stack).
function M.up()
    frame_delta(1)
end

--- Focus the callee frame (down the stack).
function M.down()
    frame_delta(-1)
end

--- Re-focus / jump to the current frame (re-centers the editor on the stopped line).
function M.focus_frame()
    local s = first_stopped()
    if s then
        listeners.dispatch("after", "frame_updated", s)
    end
end

--- Set a variable's value in its container (setVariable). `on_done` fires with the new value.
---@param container_ref integer  the parent variablesReference
---@param name string
---@param value string
---@param on_done? fun(err: table?, body: any)
function M.set_variable(container_ref, name, value, on_done)
    local s = first_stopped()
    if not s then
        return
    end
    -- Callback-style request (an `on_done` is passed / the reply is fire-and-forget), so it does not
    -- yield — no coroutine wrapper needed.
    s:request("setVariable", { variablesReference = container_ref, name = name, value = value }, on_done)
end

--- Terminate the focused session (or all, per opts).
---@param opts { all?: boolean, on_done?: fun() }?
function M.terminate(opts)
    opts = opts or {}
    if opts.all then
        -- Every live session, children included — each child owns its own transport connection, so
        -- terminating only roots left js-debug's child process running after "terminate all".
        for _, s in pairs(all_sessions) do
            s:terminate()
        end
        return
    end
    local s = session or select(2, next(all_sessions))
    if s then
        s:terminate(opts)
    else
        vim.notify("lvim-dap: no active session", vim.log.levels.INFO)
    end
end

--- Disconnect the focused session.
---@param opts table?
---@param cb fun()?
function M.disconnect(opts, cb)
    if session then
        session:disconnect(opts, cb)
    elseif cb then
        cb()
    end
end

--- Close the focused session immediately.
function M.close()
    if session then
        session:close()
        M.set_session(nil)
    end
end

--- Evaluate an expression on the focused session (repl context by default).
---@param expression string
---@param context string?
---@param on_result fun(err: table?, body: any)?
function M.evaluate(expression, context, on_result)
    local s = first_stopped()
    if not s then
        vim.notify("lvim-dap: no active session to evaluate in", vim.log.levels.INFO)
        return
    end
    -- With no callback the previous code awaited inside a coroutine and DISCARDED `err, body` — the
    -- call did nothing observable. Default a callback that reports the result (repl semantics); a
    -- callback-style evaluate does not yield, so no coroutine wrapper is needed.
    local cb = on_result
        or function(err, body)
            if err then
                vim.notify("lvim-dap: " .. tostring(err.message), vim.log.levels.WARN)
            elseif body then
                vim.notify(("%s = %s"):format(expression, body.result or ""), vim.log.levels.INFO)
            end
        end
    s:evaluate(expression, context, cb)
end

--- The focused session.
---@return lvim-dap.Session?
function M.session()
    return session
end

--- All root sessions.
---@return table<integer, lvim-dap.Session>
function M.sessions()
    return sessions
end

--- A short status string for a statusline / hud consumer.
---@return string
function M.status()
    if not session then
        return ""
    end
    local state = session.stopped_thread_id and "stopped" or (session.initialized and "running" or "starting")
    return ("%s (%s)"):format(session.config.name or "debug", state)
end

--- Set the file-log verbosity at runtime.
---@param level lvim-dap.log.Level
function M.set_log_level(level)
    log.set_level(level)
    config.log_level = level
end

-- ── command ──────────────────────────────────────────────────────────────────

--- Pretty-print the registered adapters (`:LvimDap adapters`).
local function print_adapters()
    local rows = registry.list_adapters()
    if #rows == 0 then
        vim.notify("lvim-dap: no adapters registered (use require('lvim-dap').use('python'))", vim.log.levels.INFO)
        return
    end
    local lines = { "Registered adapters:" }
    for _, r in ipairs(rows) do
        lines[#lines + 1] = ("  %-14s %-10s %-8s  filetypes: %s  (%d config%s)"):format(
            r.type,
            r.kind,
            r.source,
            table.concat(r.filetypes, ", "),
            r.config_count,
            r.config_count == 1 and "" or "s"
        )
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

---@type table<string, fun()>
local COMMANDS = {
    continue = function()
        M.continue()
    end,
    run = function()
        M.continue({ new = true })
    end,
    run_last = M.run_last,
    step_over = M.step_over,
    step_into = M.step_into,
    step_out = M.step_out,
    step_back = M.step_back,
    up = M.up,
    down = M.down,
    pause = function()
        M.pause()
    end,
    toggle_breakpoint = function()
        M.toggle_breakpoint()
    end,
    clear_breakpoints = function()
        M.clear_breakpoints()
    end,
    breakpoints = function()
        M.list_breakpoints(true)
    end,
    run_to_cursor = M.run_to_cursor,
    terminate = function()
        M.terminate()
    end,
    disconnect = function()
        M.disconnect()
    end,
    close = M.close,
    adapters = print_adapters,
}

local function setup_command()
    vim.api.nvim_create_user_command("LvimDap", function(cmd)
        local sub = cmd.fargs[1]
        if not sub then
            M.continue()
            return
        end
        local fn = COMMANDS[sub]
        if fn then
            fn()
        elseif sub == "log" then
            vim.cmd("edit " .. vim.fn.fnameescape(log.path()))
        else
            vim.notify("lvim-dap: unknown subcommand " .. sub, vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        desc = "lvim-dap",
        complete = function(arg)
            local subs = vim.tbl_keys(COMMANDS)
            subs[#subs + 1] = "log"
            return vim.tbl_filter(function(s)
                return s:find(arg, 1, true) == 1
            end, subs)
        end,
    })
end

-- ── setup ────────────────────────────────────────────────────────────────────

--- Configure the engine, register built-in providers, opt into any `auto_use` presets, define
--- signs, and create the :LvimDap command.
---@param opts LvimDapConfig?
function M.setup(opts)
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    else
        -- Fallback merge when lvim-utils is absent: it MUST write into the existing `config` table in
        -- place (same semantics as lvim-utils.utils.merge — recurse maps, replace lists/scalars).
        -- Rebinding the local (`config = vim.tbl_deep_extend(...)`) would leave every OTHER module —
        -- breakpoints, session, the earlier upvalue captures — reading the original, un-merged table,
        -- so e.g. `persist.breakpoints` would silently stay false.
        merge_in_place(config, opts or {})
    end
    log.set_level(config.log_level)

    -- Built-in config providers: the registered per-filetype configs + launch.json.
    registry.register_provider("dap.global", function(bufnr)
        local ft = vim.b[bufnr] and vim.b[bufnr].dap_srcft or vim.bo[bufnr].filetype
        return registry.configs_for_filetype(ft)
    end)
    registry.register_provider("dap.launch.json", function()
        local ok, configs = pcall(launchjs.getconfigs)
        return ok and configs or {}
    end)

    for _, name in ipairs(config.auto_use or {}) do
        M.use(name)
    end

    define_signs()
    setup_command()
    ensure_wired()
    breakpoints.setup_lifecycle()
    breakpoints.setup_persistence()

    -- Best-effort clean shutdown of live sessions on exit.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("lvim-dap.exit", { clear = true }),
        callback = function()
            -- Close EVERY live session (children own their own connections too) so nothing survives quit.
            for _, s in pairs(all_sessions) do
                pcall(function()
                    s:close()
                end)
            end
            log.close()
        end,
    })
end

return M
