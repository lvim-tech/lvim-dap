-- The breakpoint store.
--
-- Breakpoints are kept as EXTMARKS, which is what lets them follow the line they were set on when
-- the file above them is edited — the property a line-number list cannot have. These cases state
-- the store's contract and that following behaviour.
--
-- Persistence is turned OFF for the suite and every buffer here is UNNAMED (persist() skips a
-- buffer with no name), so nothing can reach the real lvim-dap store.

local config = require("lvim-dap.config")
local bp = require("lvim-dap.breakpoints")

local persist_saved = config.persist.breakpoints
config.persist.breakpoints = false

--- A scratch buffer with `n` numbered lines, made current for the duration of `fn`.
---@param n integer
---@param fn fun(buf: integer)
local function on_buffer(n, fn)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, n do
        lines[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    local ok, err = pcall(fn, buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if not ok then
        error(err, 0)
    end
end

---@param buf integer
---@return integer[]
local function lines_of(buf)
    return vim.tbl_map(function(e)
        return e.line
    end, bp.get_buffer(buf))
end

describe("lvim-dap.breakpoints: placing and removing")

it("toggle places one, and toggling the same line takes it away", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 3)
        eq({ 3 }, lines_of(buf))
        bp.toggle(buf, 3)
        eq({}, lines_of(buf))
    end)
end)

it("reports the lines in order whatever order they were set in", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 7)
        bp.toggle(buf, 2)
        bp.toggle(buf, 5)
        eq({ 2, 5, 7 }, lines_of(buf))
    end)
end)

it("set() replaces rather than removes, so a condition can be edited", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 4, { condition = "i == 1" })
        eq("i == 1", bp.get_buffer(buf)[1].condition)
        bp.set(buf, 4, { condition = "i == 2" })
        eq({ 4 }, lines_of(buf), "still exactly one breakpoint")
        eq("i == 2", bp.get_buffer(buf)[1].condition, "with the new condition")
    end)
end)

it("remove() says whether there was anything to remove", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 6)
        eq(true, bp.remove(buf, 6))
        eq(false, bp.remove(buf, 6), "the second time there is nothing there")
        eq(false, bp.remove(buf, 9), "a line that never had one")
    end)
end)

it("clear() empties the buffer it is given", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 1)
        bp.toggle(buf, 2)
        bp.clear(buf)
        eq({}, lines_of(buf))
    end)
end)

describe("lvim-dap.breakpoints: the DAP-ready entries")

it("carries the condition, the hit condition and the log message", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 3, { condition = "x > 0", hit_condition = "5", log_message = "here: {x}" })
        local entry = bp.get_buffer(buf)[1]
        eq(3, entry.line)
        eq("x > 0", entry.condition)
        eq("5", entry.hitCondition, "the DAP spelling, not the option's snake_case")
        eq("here: {x}", entry.logMessage)
    end)
end)

it("leaves the optional fields unset when nothing was given", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 3)
        local entry = bp.get_buffer(buf)[1]
        eq(nil, entry.condition)
        eq(nil, entry.hitCondition)
        eq(nil, entry.logMessage)
    end)
end)

describe("lvim-dap.breakpoints: following the line it was set on")

it("moves down when a line is inserted above it", function()
    -- This is why the store is extmark-backed: a plain line number would still say 5 and point at
    -- the wrong statement as soon as anything above it is edited.
    on_buffer(10, function(buf)
        bp.toggle(buf, 5)
        eq({ 5 }, lines_of(buf))
        vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "inserted" })
        eq({ 6 }, lines_of(buf), "the breakpoint followed its line")
    end)
end)

it("stays put when a line is inserted below it", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 5)
        vim.api.nvim_buf_set_lines(buf, 7, 7, false, { "inserted" })
        eq({ 5 }, lines_of(buf))
    end)
end)

it("moves up when a line above it is deleted", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 5)
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
        eq({ 4 }, lines_of(buf))
    end)
end)

describe("lvim-dap.breakpoints: the whole-session view")

it("get() gathers the loaded buffers", function()
    on_buffer(10, function(buf)
        bp.toggle(buf, 2)
        local all = bp.get()
        truthy(type(all) == "table", "get() must answer with a table")
        local found = false
        for _, entries in pairs(all) do
            for _, e in ipairs(entries) do
                if e.line == 2 then
                    found = true
                end
            end
        end
        truthy(found, "the breakpoint just placed is not in get(): " .. vim.inspect(all))
    end)
end)

it("to_qf never errors on an empty session", function()
    bp.clear()
    local ok, err = pcall(bp.to_qf)
    truthy(ok, tostring(err))
end)

config.persist.breakpoints = persist_saved
