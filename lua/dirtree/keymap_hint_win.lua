local api = vim.api

local M = {}

local ARROW = '→'

---@class DirtreeKeymapHintRow
---@field lhs string
---@field desc string

---@param prefix string
---@param rows DirtreeKeymapHintRow[]
---@return integer buf
---@return integer win
function M.open(prefix, rows)
    local key_width = 1
    local desc_width = 1
    for _, row in ipairs(rows) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(row.lhs))
        desc_width = math.max(desc_width, vim.fn.strdisplaywidth(row.desc))
    end

    local width = math.max(24, math.min(72, key_width + desc_width + 7))
    local height = math.max(1, #rows)
    local origin_win = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dirtree/keymap_hint_win.' .. buf)
    local lines = {}

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    for _, row in ipairs(rows) do
        lines[#lines+1] = ('  %-' .. key_width .. 's  ' .. ARROW .. '  %s'):format(row.lhs, row.desc)
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for i, row in ipairs(rows) do
        local lnum = i - 1
        local arrow_col = 2 + key_width + 2
        local desc_col = arrow_col + #ARROW + 2
        api.nvim_buf_set_extmark(buf, ns, lnum, 2, {
            end_col = 2 + key_width,
            hl_group = 'DirtreeHelpKey',
        })
        api.nvim_buf_set_extmark(buf, ns, lnum, arrow_col, {
            end_col = arrow_col + #ARROW,
            hl_group = 'DirtreeKeymapHintArrow',
        })
        api.nvim_buf_set_extmark(buf, ns, lnum, desc_col, {
            end_col = #lines[i],
            hl_group = 'DirtreeHelpDesc',
        })
    end
    vim.bo[buf].modifiable = false

    local win = api.nvim_open_win(buf, false, {
        relative = 'win',
        win = origin_win,
        anchor = 'SE',
        row = api.nvim_win_get_height(origin_win) - 1,
        col = api.nvim_win_get_width(origin_win) - 2,
        width = width,
        height = height,
        style = 'minimal',
        noautocmd = true,
        focusable = false,
    })
    vim.wo[win].winhighlight = 'NormalFloat:Normal'
    vim.wo[win].cursorline = false
    return buf, win
end

return M
