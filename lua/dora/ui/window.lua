-- Shared float helpers: window/buffer validity checks and the layout that
-- anchors dora's floats to a buffer row, centering them in the editor when
-- the anchor is offscreen.
local api = vim.api

local M = {}

---@param win integer?
---@return boolean
function M.valid_win(win)
    return win ~= nil and api.nvim_win_is_valid(win)
end

---@param buf integer?
---@return boolean
function M.valid_buf(buf)
    return buf ~= nil and api.nvim_buf_is_valid(buf)
end

---@return string?
function M.border()
    return vim.o.winborder == '' and 'rounded' or nil
end

---@class DoraFloatAnchor
---@field win integer
---@field line integer
---@field col integer
---@field superimpose? boolean Place the window content directly over the anchor cell instead of below it
---@field col_offset? integer Display cells of window content to the left of the anchor cell

---@class DoraFloatLayoutOptions
---@field title? string
---@field title_pos? 'left'|'center'|'right'
---@field width integer
---@field height integer
---@field min_width? integer
---@field anchor? DoraFloatAnchor

-- Maximum content rows a superimposed float can show when its content begins
-- at screen row `pos_row`. Neovim keeps an editor-relative float's border above
-- the command line and clamps a negative (clipped) top row to 0, so a full
-- bottom border always costs one row that this budget reserves.
---@param pos_row integer 1-indexed screen row of the float's first content line
---@return integer
local function superimpose_rows(pos_row)
    return math.max(1, vim.o.lines - vim.o.cmdheight - math.max(2, pos_row))
end

-- Rows available to a superimposed confirmation anchored at `anchor`, so the
-- caller can show only as many lines as will actually fit. Returns nil when the
-- anchor would not superimpose (hidden, or opted out with superimpose = false).
---@param anchor? DoraFloatAnchor
---@return integer?
function M.superimpose_capacity(anchor)
    if not anchor or anchor.superimpose == false or not M.valid_win(anchor.win) then
        return nil
    end
    local pos = vim.fn.screenpos(anchor.win, anchor.line, anchor.col + 1)
    if pos.row == 0 or pos.col == 0 then
        return nil
    end
    return superimpose_rows(pos.row)
end

---@param opts DoraFloatLayoutOptions
---@return table
---Returns a config for vim.api.nvim_win_set_config(). Anchored to the
---given position when it's visible, centered in the editor otherwise.
function M.layout(opts)
    local height = math.min(opts.height, math.max(1, vim.o.lines - 4))
    local anchor = opts.anchor
    local pos = anchor ~= nil and M.valid_win(anchor.win)
        and vim.fn.screenpos(anchor.win, anchor.line, anchor.col + 1)
        or nil
    local row, col, width
    if anchor and pos and pos.row ~= 0 and pos.col ~= 0 then
        width = math.min(opts.width, math.max(opts.min_width or 20, vim.o.columns - 2))
        -- row/col address the bordered area, whose content starts one cell
        -- down and right. The content column lands on the anchor cell whether
        -- or not the float superimposes; negative positions clip the border
        -- (and any content left of the anchor) rather than break alignment.
        col = math.min(pos.col - 2 - (anchor.col_offset or 0),
            math.max(0, vim.o.columns - width - 2))
        if anchor.superimpose then
            row = pos.row - 2
            -- The top border is clipped above the viewport, so the content runs
            -- downward from the anchor. Use the full room below it (minus the
            -- bottom border) rather than the conservative editor-wide clamp,
            -- which would drop rows from a selection spanning the viewport.
            height = math.min(opts.height, superimpose_rows(pos.row))
        else
            row = math.max(0, pos.row)
        end
    else
        width = math.min(opts.width, math.max(opts.min_width or 20, vim.o.columns - 4))
        row = math.max(0, math.floor((vim.o.lines - height - 2) / 2))
        col = math.floor((vim.o.columns - width) / 2)
    end
    return {
        relative = 'editor',
        anchor = 'NW',
        row = row,
        col = col,
        width = width,
        height = height,
        border = M.border(),
        title = opts.title,
        title_pos = opts.title and (opts.title_pos or 'left') or nil,
        style = 'minimal',
        noautocmd = true,
    }
end

---@param buf integer?
---@param win integer?
function M.close(buf, win)
    if M.valid_win(win) then
        pcall(api.nvim_win_close, win, true)
    end
    if M.valid_buf(buf) then
        pcall(api.nvim_buf_delete, buf, {force = true})
    end
end

return M
