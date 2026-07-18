-- lvim-dap.log: a tiny leveled file logger for the engine.
-- The DAP conversation is asynchronous and easy to get wrong (a dropped seq, a malformed
-- frame, an adapter that dies mid-handshake), and none of it is visible in the editor. So
-- every request/response/event and every transport lifecycle step is written here with a
-- wall-clock HH:MM:SS.mmm timestamp — correlatable with other logs / the adapter's own output;
-- when a debug session misbehaves this file is the ground truth.
-- Writing is gated by the level (default WARN) so a normal session costs nothing; turn it up
-- with `require("lvim-dap").set_log_level("trace")` (or via config.log_level) to capture a
-- full transcript. The file lives at stdpath("log")/lvim-dap.log and is opened lazily on the
-- first write above the threshold, so requiring this module never touches the filesystem.
--
---@module "lvim-dap.log"

local M = {}

---@alias lvim-dap.log.Level "trace"|"debug"|"info"|"warn"|"error"

---@type table<lvim-dap.log.Level, integer>
local LEVELS = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }

---@type integer  the active threshold (messages below it are dropped)
local threshold = LEVELS.warn

---@type file*?  lazily opened on the first write at/above the threshold
local handle = nil

---@type string
local path = vim.fs.normalize(vim.fn.stdpath("log") .. "/lvim-dap.log")

--- Open the log file for appending (lazily, once). Best-effort — a failure disables logging.
---@return file*?
local function ensure_open()
    if handle then
        return handle
    end
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        pcall(vim.fn.mkdir, dir, "p")
    end
    handle = io.open(path, "a")
    return handle
end

--- Set the minimum level that gets written. Accepts a level name or nil (keeps current).
---@param level lvim-dap.log.Level|nil
function M.set_level(level)
    if level and LEVELS[level] ~= nil then
        threshold = LEVELS[level]
    end
end

--- The current level name.
---@return lvim-dap.log.Level
function M.level()
    for name, n in pairs(LEVELS) do
        if n == threshold then
            return name
        end
    end
    return "warn"
end

--- The on-disk log path (for health / user reference).
---@return string
function M.path()
    return path
end

--- Write one line at `level`. Extra args are inspected and space-joined, so callers pass raw
--- tables/values without formatting them. A no-op when `level` is below the threshold.
---@param level lvim-dap.log.Level
---@param ... any
local function write(level, ...)
    if LEVELS[level] < threshold then
        return
    end
    local f = ensure_open()
    if not f then
        return
    end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v)
    end
    -- Wall clock, not hrtime: hrtime() is nanoseconds since an arbitrary origin — an opaque huge
    -- number that correlates with nothing. gettimeofday gives seconds + microseconds since the epoch.
    local sec, usec = vim.uv.gettimeofday()
    f:write(
        ("%s.%03d  %-5s  %s\n"):format(
            os.date("%H:%M:%S", sec),
            math.floor((usec or 0) / 1000),
            level:upper(),
            table.concat(parts, " ")
        )
    )
    f:flush()
end

---@param ... any
function M.trace(...)
    write("trace", ...)
end

---@param ... any
function M.debug(...)
    write("debug", ...)
end

---@param ... any
function M.info(...)
    write("info", ...)
end

---@param ... any
function M.warn(...)
    write("warn", ...)
end

---@param ... any
function M.error(...)
    write("error", ...)
end

--- Close the log file (on exit). Safe to call when never opened.
function M.close()
    if handle then
        pcall(function()
            handle:close()
        end)
        handle = nil
    end
end

return M
