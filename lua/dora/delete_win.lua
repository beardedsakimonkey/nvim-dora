local api = vim.api
local uv = vim.loop

local window = require'dora.window'
local fs = require'dora.fs'
local icons = require'dora.icons'
local config = require'dora'.config

local M = {}

local MAX_DELETE_PATHS = 10
local MAX_DELETE_WIDTH = 96
local RIGHT_PADDING = 1
-- Arrow joining a conflicting name to the free name a keep-both paste would use.
local RENAME_ARROW = ' → '
-- Marker shown where a name is elided to keep its row within the window.
local ELLIPSIS = '…'
-- A truncated name is never shrunk below this, leaving a character on each side
-- of the ellipsis.
local MIN_NAME_WIDTH = 3
-- Muted full-width rule separating the header from the file list.
local DIVIDER_CHAR = '─'
-- Per-conflict-row tag of what the chosen mode does to that entry.
local KEEP_SUFFIX = ' (keep)'
local OVERWRITE_SUFFIX = ' (overwrite)'
local OPERATION_HL = {cut = 'DoraCut', copy = 'DoraCopy'}

-- The mode-key hint shown beneath the warning, advertising both keys: `o`
-- overwrites the conflicting entries, `k` keeps both (renaming around them). The
-- text never changes -- only which mode's segment is bolded -- so it is built
-- once alongside the 0-indexed byte ranges each highlight needs.
local HINT = (function()
    local overwrite, keep, middot = 'o overwrite', 'k keep', '·'
    local sep = ' ' .. middot .. ' '
    local overwrite_col = #keep + #sep
    return {
        text = keep .. sep .. overwrite,
        keep_range = {0, #keep},                     -- bolded in keep mode
        overwrite_range = {overwrite_col, overwrite_col + #overwrite}, -- bolded in overwrite mode
        key_cols = {0, overwrite_col},               -- the `k` and `o` mnemonics
        middot_range = {#keep + 1, #keep + 1 + #middot},
    }
end)()

---@class DoraDeleteConfirmItem
---@field display string
---@field icon_start_col? integer
---@field icon_end_col? integer
---@field icon_hl? string
---@field dir_start_col? integer
---@field dir_end_col? integer
---@field suffix_start_col? integer
---@field suffix_end_col? integer
---@field file_start_col integer
---@field file_end_col integer
---@field file_hl string
---@field rename? string Free name a keep-both paste would use, shown after an arrow
---@field operation? DoraPasteOperation

---@class DoraDeleteOptions
---@field anchor? DoraFloatAnchor
---@field action? string
---@field dest? string Destination directory shown beneath the file list
---@field base? string Show listed paths relative to this directory
---@field renames? table<string, string> Source path -> free name shown for a kept-both paste
---@field allow_overwrite? boolean Offer `o`/`k` to toggle overwrite vs the default keep-both, passed to cb's second arg
---@field operations? table<string, DoraPasteOperation> Source path -> cut/copy, shown as a colored bar
---@field expanded? table<string, boolean> Directory paths shown with the expanded (open) icon, matching the tree

---@param path string
---@return string
local function file_hl(path)
    if uv.fs_readlink(path) then
        return 'DoraSymlink'
    end
    local stat = uv.fs_stat(path)
    if stat and stat.type == 'directory' then
        return 'DoraDirectory'
    end
    if uv.fs_access(path, 'X') then
        return 'DoraExecutable'
    end
    return 'DoraFile'
end

-- Byte length of the leading directory portion of a path, before its final
-- component. Trailing separators are ignored.
---@param path string
---@return integer
local function dir_prefix_len(path)
    return #fs.strip_trailing_sep(path) - #fs.basename(path)
end

-- Longest prefix of `s` whose display width does not exceed `max_cols`.
---@param s string
---@param max_cols integer
---@return string
local function prefix_cols(s, max_cols)
    local out, width = '', 0
    for i = 0, vim.fn.strchars(s) - 1 do
        local ch = vim.fn.strcharpart(s, i, 1)
        local w = vim.fn.strdisplaywidth(ch)
        if width + w > max_cols then
            break
        end
        out, width = out .. ch, width + w
    end
    return out
end

-- Longest suffix of `s` whose display width does not exceed `max_cols`.
---@param s string
---@param max_cols integer
---@return string
local function suffix_cols(s, max_cols)
    local out, width = '', 0
    for i = vim.fn.strchars(s) - 1, 0, -1 do
        local ch = vim.fn.strcharpart(s, i, 1)
        local w = vim.fn.strdisplaywidth(ch)
        if width + w > max_cols then
            break
        end
        out, width = ch .. out, width + w
    end
    return out
end

-- Middle-elide `s` to at most `max_width` display columns, keeping its start and
-- its tail -- a file extension, or a path's trailing separator -- visible on
-- either side of a single ellipsis.
---@param s string
---@param max_width integer
---@return string
local function truncate_name(s, max_width)
    max_width = math.max(1, max_width)
    if vim.fn.strdisplaywidth(s) <= max_width then
        return s
    end
    if max_width == 1 then
        return ELLIPSIS
    end
    local budget = max_width - 1
    local head = prefix_cols(s, math.ceil(budget / 2))
    local tail = suffix_cols(s, budget - vim.fn.strdisplaywidth(head))
    return head .. ELLIPSIS .. tail
end

-- Raw pieces of a confirmation row, kept as plain strings so a name can be
-- elided (see truncate_parts) before the byte columns are measured.
---@param path string
---@param base? string
---@param renames? table<string, string>
---@param operations? table<string, DoraPasteOperation>
---@param expanded? table<string, boolean>
---@return table
local function item_parts(path, base, renames, operations, expanded)
    -- Show the path relative to base, falling back to the absolute path for
    -- marks outside it (e.g. above the current root).
    local relative = base and (vim.fs.relpath(base, path) or path) or fs.basename(path)
    local dir_len = dir_prefix_len(relative)
    local hl = file_hl(path)
    local is_expanded = expanded and expanded[path] or nil
    local icon, icon_hl = icons.get(config.icons, fs.file_from_path(path), path, is_expanded)
    return {
        icon = icon,
        icon_hl = icon_hl or 'DoraIcon',
        dir_part = relative:sub(1, dir_len),
        basename = relative:sub(dir_len + 1),
        is_dir = hl == 'DoraDirectory',
        file_hl = hl,
        rename = renames and renames[path] or nil,
        operation = operations and operations[path] or nil,
    }
end

-- Assemble the display string and its byte-column highlight ranges from
-- (possibly truncated) raw pieces.
---@param parts table
---@return DoraDeleteConfirmItem
local function build_item(parts)
    local icon_prefix = parts.icon and parts.icon .. ' ' or ''
    local display = icon_prefix .. parts.dir_part .. parts.basename
    local suffix_start_col, suffix_end_col
    if parts.is_dir then
        suffix_start_col = #display
        display = display .. '/'
        suffix_end_col = #display
    end
    local dir_len = #parts.dir_part
    return {
        display = display,
        icon_start_col = parts.icon and 0 or nil,
        icon_end_col = parts.icon and #parts.icon or nil,
        icon_hl = parts.icon_hl,
        dir_start_col = dir_len > 0 and #icon_prefix or nil,
        dir_end_col = dir_len > 0 and #icon_prefix + dir_len or nil,
        suffix_start_col = suffix_start_col,
        suffix_end_col = suffix_end_col,
        file_start_col = #icon_prefix + dir_len,
        file_end_col = #icon_prefix + dir_len + #parts.basename,
        file_hl = parts.file_hl,
        rename = parts.rename,
        operation = parts.operation,
    }
end

-- Elide the relative path -- its directory prefix first, then the basename --
-- and, when its keep-both preview is shown, the rename, so the rendered line fits
-- within `target` display columns. The fixed parts (icon, the directory '/'
-- suffix, rename arrow, and mode suffix) never shrink. The directory prefix is
-- context, so it yields first; the basename and rename stay whole while they fit
-- and otherwise share the leftover space.
---@param parts table
---@param overwrite boolean Current mode, deciding which suffix and preview the line carries
---@param target integer Display columns the rendered line may occupy
---@return table
local function truncate_parts(parts, overwrite, target)
    local show_rename = parts.rename ~= nil and not overwrite
    local fixed = (parts.icon and vim.fn.strdisplaywidth(parts.icon) + 1 or 0)
        + (parts.is_dir and 1 or 0)
    if parts.rename ~= nil then
        fixed = fixed + vim.fn.strdisplaywidth(overwrite and OVERWRITE_SUFFIX or KEEP_SUFFIX)
    end
    if show_rename then
        fixed = fixed + vim.fn.strdisplaywidth(RENAME_ARROW)
    end
    local budget = target - fixed
    local dir_w = vim.fn.strdisplaywidth(parts.dir_part)
    local name_w = vim.fn.strdisplaywidth(parts.basename)
    local rename_w = show_rename and vim.fn.strdisplaywidth(parts.rename) or 0
    if dir_w + name_w + rename_w <= budget then
        return parts
    end
    -- The directory prefix yields first: keep the names at full width when they
    -- fit, shrinking the prefix into the leftover space and dropping it outright
    -- once the names alone fill the row.
    local dir_budget = budget - name_w - rename_w
    if dir_budget <= 0 then
        parts.dir_part = ''
    elseif dir_budget < dir_w then
        parts.dir_part = truncate_name(parts.dir_part, dir_budget)
    end
    local names_budget = budget - vim.fn.strdisplaywidth(parts.dir_part)
    if not show_rename then
        if name_w > names_budget then
            parts.basename = truncate_name(parts.basename, math.max(MIN_NAME_WIDTH, names_budget))
        end
        return parts
    end
    if name_w + rename_w <= names_budget then
        return parts
    end
    -- Both names overflow their shared space: let one that already fits half keep
    -- its width and hand the slack to the other, else split the budget evenly.
    local name_budget, rename_budget
    if name_w * 2 <= names_budget then
        name_budget, rename_budget = name_w, names_budget - name_w
    elseif rename_w * 2 <= names_budget then
        rename_budget, name_budget = rename_w, names_budget - rename_w
    else
        name_budget = math.floor(names_budget / 2)
        rename_budget = names_budget - name_budget
    end
    parts.basename = truncate_name(parts.basename, math.max(MIN_NAME_WIDTH, name_budget))
    parts.rename = truncate_name(parts.rename, math.max(MIN_NAME_WIDTH, rename_budget))
    return parts
end

---@param path string
---@param base? string
---@param renames? table<string, string>
---@param operations? table<string, DoraPasteOperation>
---@param expanded? table<string, boolean>
---@return DoraDeleteConfirmItem
local function item(path, base, renames, operations, expanded)
    return build_item(item_parts(path, base, renames, operations, expanded))
end

---@param paths string[]
---@param base? string
---@param renames? table<string, string>
---@param operations? table<string, DoraPasteOperation>
---@param expanded? table<string, boolean>
---@param limit integer Maximum number of paths to render before overflowing
---@param overwrite boolean Current mode, deciding which suffix and preview each line carries
---@param target? integer Display columns each line may occupy; names are elided to fit
---@return DoraDeleteConfirmItem[]
local function items(paths, base, renames, operations, expanded, limit, overwrite, target)
    local ret = {}
    for i = 1, math.min(#paths, limit) do
        local parts = item_parts(paths[i], base, renames, operations, expanded)
        if target then
            parts = truncate_parts(parts, overwrite, target)
        end
        ret[#ret+1] = build_item(parts)
    end
    return ret
end

-- How many paths to list before overflowing into "... and N more". A
-- superimposed confirmation aligns one line per removed row, so it lists every
-- path that fits; it only overflows when the float (including its border)
-- genuinely cannot show them all. Other confirmations (paste, centered) keep
-- the fixed cap.
---@param anchor? DoraFloatAnchor
---@param count integer Number of paths to confirm
---@return integer
local function path_limit(anchor, count)
    local capacity = window.superimpose_capacity(anchor)
    if not capacity then
        return MAX_DELETE_PATHS
    end
    if count <= capacity then
        return count
    end
    -- Reserve the final visible row for the overflow line.
    return capacity - 1
end

---@param count integer
---@param action? string
---@return string
local function get_title(count, action)
    action = action or 'Delete'
    if count == 1 then
        return action .. '?'
    end
    return string.format('%s %d files?', action, count)
end

---@param count integer
---@return string
local function conflicts_text(count)
    return string.format('%d conflict%s', count, count == 1 and '' or 's')
end

---@param overwrite boolean
---@return string
local function conflict_suffix(overwrite)
    return overwrite and OVERWRITE_SUFFIX or KEEP_SUFFIX
end

-- Number of leading spaces that horizontally centers `text` within `width`.
---@param text string
---@param width integer
---@return integer
local function center_pad(text, width)
    return math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
end

---@param text string
---@param width integer
---@return string
local function center(text, width)
    return string.rep(' ', center_pad(text, width)) .. text
end

---@param confirm_items DoraDeleteConfirmItem[]
---@param overflow integer
---@param dest_item? DoraDeleteConfirmItem
---@param overwrite boolean Drop the keep-both rename previews while overwriting
---@param warning? string Conflict count centered on the first line
---@param hint? string Mode-key hint centered below the warning, above a spacer
---@param width? integer Window width used to center the warning and hint
---@return string[] rendered_lines
---@return integer? dest_row 0-indexed row of the destination
local function lines(confirm_items, overflow, dest_item, overwrite, warning, hint, width)
    local ret = {}
    if warning then
        ret[#ret+1] = width and center(warning, width) or warning
    end
    if hint then
        ret[#ret+1] = width and center(hint, width) or hint
    end
    if warning or hint then
        -- Built only once the width is known; an empty placeholder keeps it out
        -- of the width measurement so it never drives the window wider.
        ret[#ret+1] = width and string.rep(DIVIDER_CHAR, width) or ''
    end
    local suffix = conflict_suffix(overwrite)
    for _, confirm_item in ipairs(confirm_items) do
        local line = confirm_item.display
        if confirm_item.rename then
            -- The rename preview only applies to a keep-both paste; an overwrite
            -- lands on the conflicting name itself. Either way the row is tagged
            -- with what the chosen mode does to it.
            if not overwrite then
                line = line .. RENAME_ARROW .. confirm_item.rename
            end
            line = line .. suffix
        end
        ret[#ret+1] = line
    end
    if overflow > 0 then
        ret[#ret+1] = string.format('... and %d more', overflow)
    end
    local dest_row
    if dest_item then
        ret[#ret+1] = '↓'
        dest_row = #ret
        ret[#ret+1] = dest_item.display
    end
    return ret, dest_row
end

-- A cut/copy mark recolors the filename red/green, matching how the marked file
-- appears in the tree; otherwise it keeps its file-type color.
---@param confirm_item DoraDeleteConfirmItem
---@return string
local function name_hl(confirm_item)
    return confirm_item.operation and OPERATION_HL[confirm_item.operation]
        or confirm_item.file_hl
end

---@param buf integer
---@param ns integer
---@param row integer 0-indexed
---@param confirm_item DoraDeleteConfirmItem
local function render_item(buf, ns, row, confirm_item)
    if confirm_item.icon_start_col then
        api.nvim_buf_set_extmark(buf, ns, row, confirm_item.icon_start_col, {
            end_col = confirm_item.icon_end_col,
            hl_group = confirm_item.icon_hl,
            priority = 10000,
        })
    end
    if confirm_item.dir_start_col then
        api.nvim_buf_set_extmark(buf, ns, row, confirm_item.dir_start_col, {
            end_col = confirm_item.dir_end_col,
            hl_group = 'DoraFilterPath',
            priority = 10000,
        })
    end
    api.nvim_buf_set_extmark(buf, ns, row, confirm_item.file_start_col, {
        end_col = confirm_item.file_end_col,
        hl_group = name_hl(confirm_item),
        priority = 10000,
    })
    if confirm_item.suffix_start_col then
        api.nvim_buf_set_extmark(buf, ns, row, confirm_item.suffix_start_col, {
            end_col = confirm_item.suffix_end_col,
            hl_group = 'DoraVirtText',
            priority = 10000,
        })
    end
end

---@param buf integer
---@param ns integer
---@param confirm_items DoraDeleteConfirmItem[]
---@param overflow integer
---@param dest_item? DoraDeleteConfirmItem
---@param overwrite boolean
---@param warning? string
---@param hint? string
---@param width integer
local function render(buf, ns, confirm_items, overflow, dest_item, overwrite, warning, hint, width)
    local rendered_lines, dest_row = lines(confirm_items, overflow, dest_item, overwrite, warning, hint, width)
    api.nvim_buf_set_lines(buf, 0, -1, false, rendered_lines)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    -- The centered warning and hint head the list, above a blank spacer, so the
    -- file rows start below them.
    local offset = 0
    if warning then
        local pad = center_pad(warning, width)
        api.nvim_buf_set_extmark(buf, ns, offset, pad, {
            end_col = pad + #warning,
            hl_group = 'DoraWarn',
            priority = 10000,
        })
        offset = offset + 1
    end
    if hint then
        -- Bold the active mode's segment, spotlight both mnemonic keys, and mute
        -- the middot; the rest reads normally. Bold and the key color set
        -- different attributes, so they layer on the active key.
        local pad = center_pad(hint, width)
        local active = overwrite and HINT.overwrite_range or HINT.keep_range
        api.nvim_buf_set_extmark(buf, ns, offset, pad + active[1], {
            end_col = pad + active[2],
            hl_group = 'DoraBold',
            priority = 10000,
        })
        for _, key_col in ipairs(HINT.key_cols) do
            api.nvim_buf_set_extmark(buf, ns, offset, pad + key_col, {
                end_col = pad + key_col + 1,
                hl_group = 'DoraInfoValue',
                priority = 10001,
            })
        end
        api.nvim_buf_set_extmark(buf, ns, offset, pad + HINT.middot_range[1], {
            end_col = pad + HINT.middot_range[2],
            hl_group = 'DoraMutedText',
            priority = 10000,
        })
        offset = offset + 1
    end
    if warning or hint then
        api.nvim_buf_set_extmark(buf, ns, offset, 0, {
            end_col = #rendered_lines[offset + 1],
            hl_group = 'DoraMutedText',
            priority = 10000,
        })
        offset = offset + 1
    end
    local suffix = conflict_suffix(overwrite)
    for i, confirm_item in ipairs(confirm_items) do
        local row = offset + i - 1
        render_item(buf, ns, row, confirm_item)
        if confirm_item.rename then
            local line_len = #rendered_lines[row + 1]
            local suffix_start = line_len - #suffix
            if not overwrite then
                -- The arrow reads in the normal color; the previewed name takes
                -- the marked file's color (cut/copy) so it reads like the row.
                local name_start = #confirm_item.display + #RENAME_ARROW
                api.nvim_buf_set_extmark(buf, ns, row, name_start, {
                    end_col = suffix_start,
                    hl_group = name_hl(confirm_item),
                    priority = 10000,
                })
            end
            -- Tag the row with its fate (keep/overwrite) in the warning color.
            api.nvim_buf_set_extmark(buf, ns, row, suffix_start, {
                end_col = line_len,
                hl_group = 'DoraWarn',
                priority = 10000,
            })
        end
    end
    if overflow > 0 then
        local row = offset + #confirm_items
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
            end_col = #rendered_lines[row + 1],
            hl_group = 'DoraMutedText',
        })
    end
    if dest_item and dest_row then
        render_item(buf, ns, dest_row, dest_item)
    end
end

---@param confirm_title string
---@param rendered_lines string[]
---@return integer
local function get_width(confirm_title, rendered_lines)
    local max_width = #confirm_title
    for _, line in ipairs(rendered_lines) do
        max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
    end
    return math.max(32, math.min(MAX_DELETE_WIDTH, max_width + RIGHT_PADDING))
end

---@param win integer
---@return DoraFloatAnchor
local function cursor_anchor(win)
    local cursor = api.nvim_win_get_cursor(win)
    return {
        win = win,
        line = cursor[1],
        col = cursor[2],
    }
end

-- Superimposes the first item's basename onto the anchor cell, so the lines
-- align with the rows they remove. The offset is the width of the directory
-- prefix shown before the basename (none for a bare basename), letting the icon
-- sit flush against the border like the rename prompt.
---@param anchor DoraFloatAnchor
---@param confirm_items DoraDeleteConfirmItem[]
---@return DoraFloatAnchor
local function superimpose_anchor(anchor, confirm_items)
    if anchor.superimpose == false then
        return anchor
    end
    local first = confirm_items[1]
    if not first then
        return anchor
    end
    local icon_len = first.icon_end_col and first.icon_end_col + 1 or 0
    local dir_prefix = first.display:sub(icon_len + 1, first.file_start_col)
    return vim.tbl_extend('force', anchor, {
        superimpose = true,
        col_offset = vim.fn.strdisplaywidth(dir_prefix),
    })
end

---@param paths string[]
---@param cb fun(confirmed: boolean, overwrite?: boolean)
---@param opts? DoraDeleteOptions
function M.delete(paths, cb, opts)
    if #paths == 0 then
        cb(false)
        return
    end
    opts = opts or {}
    local base = opts.base
    local renames = opts.renames
    local operations = opts.operations
    local expanded = opts.expanded
    -- Paste confirmations start in keep-both mode; `o` switches to overwrite and
    -- `k` switches back, retagging each row. A conflict count and a static
    -- both-keys hint head the list.
    local overwrite = false
    local warning = opts.allow_overwrite
        and conflicts_text(vim.tbl_count(renames or {})) or nil
    local hint = opts.allow_overwrite and HINT.text or nil
    -- A paste warns (regardless of overwrite mode) when it would clash with an
    -- existing entry, otherwise keeps the normal float border; a delete or
    -- single-file overwrite stays red to flag the destructive confirm.
    local border = 'DoraPromptBorderInvalid'
    if opts.action == 'Paste' then
        border = opts.allow_overwrite and 'DoraPromptBorderWarn' or 'DoraPromptBorder'
    end
    -- Render the destination like a listed entry: relative to base, or by its
    -- own name when it is base itself.
    local dest_item = opts.dest and item(opts.dest, opts.dest ~= base and base or nil, nil, nil, expanded) or nil
    local max_paths = path_limit(opts.anchor, #paths)
    local confirm_items = items(paths, base, renames, operations, expanded, max_paths, overwrite)
    local overflow = math.max(0, #paths - #confirm_items)
    local confirm_title = get_title(#paths, opts.action)
    -- Size the window to fit either mode (overwrite tags are shorter than the
    -- keep-both previews) so toggling never resizes it. A fixed width keeps the
    -- centered warning and hint from shifting — stability over a snug fit.
    local win_width = math.max(
        get_width(confirm_title, lines(confirm_items, overflow, dest_item, false, warning, hint)),
        get_width(confirm_title, lines(confirm_items, overflow, dest_item, true, warning, hint)))
    -- Clamp to the room the float actually gets — layout would otherwise narrow
    -- it below win_width on a slim terminal — so the divider, centered header,
    -- and elided rows all agree on a single width.
    win_width = math.min(win_width, math.max(20, vim.o.columns - 4))
    -- Names are elided to this width so no row spills past the window edge.
    -- win_width itself stays fixed for the window's lifetime, so the centered
    -- header never shifts.
    local target = win_width - RIGHT_PADDING
    if dest_item then
        dest_item = build_item(truncate_parts(
            item_parts(opts.dest, opts.dest ~= base and base or nil, nil, nil, expanded), false, target))
    end
    local rendered_lines = lines(confirm_items, overflow, dest_item, overwrite, warning, hint, win_width)
    local origin_win = api.nvim_get_current_win()
    local guicursor = vim.o.guicursor
    local autocmds = {}
    local closed = false
    local buf = api.nvim_create_buf(false, true)
    local ns = api.nvim_create_namespace('dora/delete_win.' .. buf)

    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = true
    local function refresh()
        confirm_items = items(paths, base, renames, operations, expanded, max_paths, overwrite, target)
        -- win_width is fixed for the window's lifetime, so the centered header
        -- never moves as the mode (and the list content) changes.
        rendered_lines = lines(confirm_items, overflow, dest_item, overwrite, warning, hint, win_width)
        vim.bo[buf].modifiable = true
        render(buf, ns, confirm_items, overflow, dest_item, overwrite, warning, hint, win_width)
        vim.bo[buf].modifiable = false
    end

    refresh()
    vim.bo[buf].modifiable = false

    local function layout()
        return window.layout({
            title = confirm_title,
            width = win_width,
            height = #rendered_lines,
            anchor = opts.anchor and superimpose_anchor(opts.anchor, confirm_items)
                or cursor_anchor(origin_win),
        })
    end

    local win = api.nvim_open_win(buf, true, layout())
    vim.o.guicursor = 'a:block-DoraHiddenCursor'
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:' .. border
    vim.wo[win].wrap = false

    ---@param confirmed boolean
    local function finish(confirmed)
        if closed then
            return
        end
        closed = true
        for _, au in ipairs(autocmds) do
            pcall(api.nvim_del_autocmd, au)
        end
        vim.o.guicursor = guicursor
        window.close(buf, win)
        if window.valid_win(origin_win) then
            pcall(api.nvim_set_current_win, origin_win)
        end
        cb(confirmed, overwrite)
    end

    -- Switch between keep-both and overwrite without leaving the confirmation.
    -- The window geometry is fixed (same line count, mode-independent width), so
    -- only the buffer content is re-rendered.
    local function set_overwrite(value)
        if overwrite == value or not window.valid_win(win) then
            return
        end
        overwrite = value
        refresh()
    end

    for _, lhs in ipairs({'y', 'Y', '<CR>'}) do
        vim.keymap.set('n', lhs, function() finish(true) end, {buffer = buf, silent = true, nowait = true})
    end
    for _, lhs in ipairs({'n', 'N', 'q', '<Esc>', '<C-c>'}) do
        vim.keymap.set('n', lhs, function() finish(false) end, {buffer = buf, silent = true, nowait = true})
    end
    if opts.action == 'Paste' then
        for _, lhs in ipairs({'p', 'P'}) do
            vim.keymap.set('n', lhs, function() finish(false) end, {buffer = buf, silent = true, nowait = true})
        end
    end
    -- A keep-both confirm renames around conflicts; `o` overwrites the existing
    -- destinations instead and `k` switches back to keeping both.
    if opts.allow_overwrite then
        for _, lhs in ipairs({'o', 'O'}) do
            vim.keymap.set('n', lhs, function() set_overwrite(true) end, {buffer = buf, silent = true, nowait = true})
        end
        for _, lhs in ipairs({'k', 'K'}) do
            vim.keymap.set('n', lhs, function() set_overwrite(false) end, {buffer = buf, silent = true, nowait = true})
        end
    end
    vim.keymap.set('n', 'd', '<Nop>', {buffer = buf, silent = true, nowait = true})

    autocmds[#autocmds+1] = api.nvim_create_autocmd('CursorMoved', {
        buffer = buf,
        callback = function()
            if window.valid_win(win) then
                api.nvim_win_set_cursor(win, {1, 0})
            end
        end,
    })
    autocmds[#autocmds+1] = api.nvim_create_autocmd('VimResized', {
        callback = function()
            if window.valid_win(win) then
                refresh()
                api.nvim_win_set_config(win, layout())
            end
        end,
    })
    autocmds[#autocmds+1] = api.nvim_create_autocmd('WinLeave', {
        buffer = buf,
        callback = function() finish(false) end,
    })
    autocmds[#autocmds+1] = api.nvim_create_autocmd('WinClosed', {
        callback = function(args)
            if tonumber(args.match) == win then
                finish(false)
            end
        end,
    })
end

return M
