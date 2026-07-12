-- lvim-dap.rpc: the DAP base-protocol wire codec (encode + streaming decode).
-- DAP frames a JSON body exactly like LSP: an HTTP-style `Content-Length: N\r\n\r\n` header
-- followed by N bytes of UTF-8 JSON. Two problems this module solves:
--   • DECODE is a STREAM, not a message — luv hands us arbitrary byte chunks off the pipe: a
--     chunk may hold half a header, several whole messages, or a body split across reads. So
--     the parser is a resumable coroutine that accumulates bytes and yields one complete body
--     at a time; `create_read_loop` wraps it into an `on_read(err, chunk)` callback for luv.
--   • Byte counting is on the ENCODED length: Content-Length is a count of BYTES, not chars,
--     so we measure `#json` (Lua strings are byte strings) — a multibyte value never desyncs.
-- `string.buffer` (LuaJIT) is used when present for O(1) growth; a pure-Lua fallback keeps the
-- module dependency-free. Nothing here knows about sessions or DAP semantics — it is a pure
-- codec, unit-testable on its own.
--
---@module "lvim-dap.rpc"

local M = {}

--- Extract the Content-Length value from a header block (case-insensitive key).
---@param header string
---@return integer?
local function content_length(header)
    for line in header:gmatch("(.-)\r\n") do
        local key, value = line:match("^%s*(%S+)%s*:%s*(%d+)%s*$")
        if key and key:lower() == "content-length" then
            return tonumber(value)
        end
    end
end

---@type fun()  the resumable parse loop body (selected once at load)
local parse_loop
local has_strbuffer, strbuffer = pcall(require, "string.buffer")

if has_strbuffer then
    -- LuaJIT string.buffer path: skip/get consume from the front in O(1).
    parse_loop = function()
        local buf = strbuffer.new()
        while true do
            local msg = buf:tostring()
            local header_end = msg:find("\r\n\r\n", 1, true)
            if header_end then
                local header = buf:get(header_end + 1)
                buf:skip(2) -- past the blank-line boundary
                local len = content_length(header)
                if not len then
                    error("lvim-dap.rpc: Content-Length missing in header: " .. header)
                end
                while #buf < len do
                    buf:put(coroutine.yield())
                end
                coroutine.yield(buf:get(len))
            else
                buf:put(coroutine.yield())
            end
        end
    end
else
    -- Pure-Lua fallback: concatenate and slice. Slower on big payloads but correct.
    parse_loop = function()
        local buffer = ""
        while true do
            local header_end, body_start = buffer:find("\r\n\r\n", 1, true)
            if header_end then
                local len = content_length(buffer:sub(1, header_end + 1))
                if not len then
                    error("lvim-dap.rpc: Content-Length missing in header")
                end
                local chunks = { buffer:sub(body_start + 1) }
                local have = #chunks[1]
                while have < len do
                    local chunk = coroutine.yield() or error("lvim-dap.rpc: stream ended mid-body")
                    chunks[#chunks + 1] = chunk
                    have = have + #chunk
                end
                local last = chunks[#chunks]
                chunks[#chunks] = last:sub(1, len - have - 1)
                local rest = have > len and last:sub(len - have) or ""
                local body = table.concat(chunks)
                buffer = rest .. (coroutine.yield(body) or error("lvim-dap.rpc: stream ended after body"))
            else
                buffer = buffer .. (coroutine.yield() or error("lvim-dap.rpc: stream ended mid-header"))
            end
        end
    end
end

--- Build a luv read callback that decodes the byte stream and calls `on_body(body_string)` for
--- each complete DAP message. `on_eof` fires when the stream closes (chunk == nil). Decode
--- errors are routed to `on_error(msg)` rather than thrown into the loop.
---@param on_body fun(body: string)
---@param on_eof? fun()
---@param on_error? fun(msg: string)
---@return fun(err?: string, chunk?: string)
function M.create_read_loop(on_body, on_eof, on_error)
    local parse = coroutine.wrap(parse_loop)
    parse() -- prime to the first yield
    return function(err, chunk)
        if err then
            if on_error then
                on_error(err)
            end
            return
        end
        if not chunk then
            if on_eof then
                on_eof()
            end
            return
        end
        while true do
            local ok, body = pcall(parse, chunk)
            if not ok then
                if on_error then
                    on_error(tostring(body))
                end
                return
            end
            if body then
                on_body(body)
                chunk = "" -- drain any further whole messages already buffered
            else
                break
            end
        end
    end
end

--- Frame a JSON payload string with its Content-Length header, ready to write to the transport.
---@param json string  the already-encoded JSON body
---@return string
function M.frame(json)
    return table.concat({ "Content-Length: ", tostring(#json), "\r\n\r\n", json })
end

return M
