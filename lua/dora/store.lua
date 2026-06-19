local M = {}

---@type table<string, DoraState>
local buf_states = {}

---@param buf integer
---@param state DoraState
function M.set(buf, state)
    buf_states[tostring(buf)] = state
end

---@param buf integer
function M.remove(buf)
    buf_states[tostring(buf)] = nil
end

---@param buf? integer
---@return DoraState
function M.get(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    assert(buf ~= -1)
    local state = assert(buf_states[tostring(buf)])
    return state
end

---Call `fn` for every live dora state, in no particular order.
---@param fn fun(state: DoraState)
function M.each(fn)
    for _, state in pairs(buf_states) do
        fn(state)
    end
end

return M
