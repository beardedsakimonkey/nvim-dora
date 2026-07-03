local M = {}

---@alias DoraPasteOperation 'copy'|'cut'

---@class DoraState
---@field buf integer
---@field win integer
---@field origin_buf integer
---@field alt_buf? integer
---@field cwd string
---@field ns integer
---@field cursor_ns integer
---@field show_hidden_files boolean
---@field sort_order DoraSortOrder
---@field hovered_files table<string, string>
---@field listings table<string, DoraListingEntry>
---@field expanded_dirs table<string, true>
---@field tree_rows DoraTreeRow[]
---@field rows DoraTreeRow[]
---@field filter_text? string
---@field filter_preview? string
---@field filter_window? DoraFilterWindow
---@field filter_editing boolean
---@field filter_inverted boolean when true, the filter keeps non-matching rows
---@field marked_paths table<string, DoraPasteOperation>
---@field paste_in_progress? boolean Guards against starting a second async paste while one runs
---@field preview? DoraPreviewWindow
---@field bookmarks DoraBookmarks

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
