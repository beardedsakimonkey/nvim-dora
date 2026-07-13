-- The toggleable preview split: shows the head of the hovered file, or a
-- listing of the hovered directory, in a lightweight scratch buffer
-- (highlighted without running ftplugins), and swaps in the real buffer when
-- a file preview is focused.
local icons = require'dora.icons'
local window = require'dora.ui.window'
local util = require'dora.util'
local config = require'dora'.config

local api = vim.api
local uv = vim.uv

local M = {}

-- A hovered file is read in chunks only until there are enough lines to fill
-- the tallest possible window, so hovering a huge file stays instant.
-- MAX_READ_BYTES bounds files whose first lines are pathologically long
-- (e.g. minified JS); the preview shows what fit.
local READ_CHUNK_BYTES = 16 * 1024
local MAX_READ_BYTES = 512 * 1024

local NS = api.nvim_create_namespace('dora/preview_win')

---@class DoraPreviewWindow
---@field win integer
---@field augroup integer
---@field path? string Path currently shown; nil for the blank no-selection buffer
---@field loadable boolean Focusing the window should load `path` as a real buffer
---@field full boolean The real buffer was loaded by focusing the window

---@param path string
---@param max_lines integer
---@return string[]? lines nil when the file could not be read
---@return string? err
---@return boolean? binary
local function read_head_lines(path, max_lines)
    local fd, open_err = uv.fs_open(path, 'r', 0)
    if not fd then
        return nil, open_err
    end
    local chunks = {}
    local bytes = 0
    local newlines = 0
    while bytes < MAX_READ_BYTES and newlines < max_lines do
        local chunk, read_err = uv.fs_read(fd, READ_CHUNK_BYTES, bytes)
        if not chunk then
            uv.fs_close(fd)
            return nil, read_err
        end
        if #chunk == 0 then
            break
        end
        chunks[#chunks+1] = chunk
        bytes = bytes + #chunk
        newlines = newlines + select(2, chunk:gsub('\n', ''))
    end
    uv.fs_close(fd)
    local text = table.concat(chunks)
    if text:find('\0', 1, true) then
        return nil, nil, true
    end
    local lines = vim.split(text, '\n', {plain = true})
    if #lines > max_lines then
        for i = #lines, max_lines + 1, -1 do
            lines[i] = nil
        end
    elseif lines[#lines] == '' then
        -- The file's trailing newline terminates the last line rather than
        -- starting an empty one.
        lines[#lines] = nil
    end
    for i, line in ipairs(lines) do
        lines[i] = line:gsub('\r$', '')
    end
    return lines
end

---@param path? string
---@param lines string[]
---@param placeholder? string Muted label shown instead of file content
---@return integer buf
local function create_scratch(path, lines, placeholder)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    if placeholder then
        api.nvim_buf_set_lines(buf, 0, -1, false, {placeholder})
        api.nvim_buf_set_extmark(buf, NS, 0, 0, {
            end_col = #placeholder,
            hl_group = 'DoraMutedText',
        })
    else
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
    vim.bo[buf].modifiable = false
    if path then
        -- Show what's previewed in the statusline. A stale twin can linger
        -- briefly (e.g. another dora window previewing the same file), in
        -- which case the buffer just stays unnamed.
        pcall(api.nvim_buf_set_name, buf, 'dora-preview://' .. path)
    end
    return buf
end

-- Highlight the partial preview without loading the file: attach treesitter
-- when a parser exists, falling back to regex syntax. Setting 'filetype'
-- instead would run ftplugins and attach LSP servers to a scratch buffer.
---@param buf integer
---@param path string
---@param lines string[]
local function apply_highlight(buf, path, lines)
    local ok, ft = pcall(vim.filetype.match, {filename = path, contents = lines})
    if not ok or not ft then
        return
    end
    local lang = vim.treesitter.language.get_lang(ft)
    if not (lang and pcall(vim.treesitter.start, buf, lang)) then
        vim.bo[buf].syntax = ft
    end
end

-- A hovered directory previews as a point-in-time listing rendered like the
-- main view (same hidden-file filter, sort order, labels, and colors, minus
-- the per-entry symlink/executable decorations), truncated at the tallest
-- possible window like file previews. No cache and no watcher: the listing
-- is rescanned only when the cursor returns to the directory.
---@param state DoraState
---@param path string
---@return integer buf
local function create_directory_scratch(state, path)
    -- Required lazily: view.lua requires this module at load time.
    local view = require'dora.view'
    local raw, files, label = view.scan_directory(state, path)
    if not raw and not label then
        label = '(cannot preview)'
    end
    if label or #files == 0 then
        return create_scratch(path, {}, label or view.EMPTY_LABEL)
    end
    local lines = {}
    -- Extmark specs to apply once the buffer exists:
    -- row, start col, end col, highlight group, priority.
    ---@type [integer, integer, integer, string, integer][]
    local extmarks = {}
    for i = 1, math.min(#files, vim.o.lines) do
        local file = files[i]
        local icon, icon_hl = icons.get(config.icons, file, vim.fs.joinpath(path, file.name))
        local line = icon and icon .. ' ' .. file.name or file.name
        if icon then
            extmarks[#extmarks+1] = {i, 0, #icon, icon_hl or 'DoraIcon', 10000}
        end
        local line_hl = 'DoraFile'
        if file.type == 'directory' then
            line_hl = 'DoraDirectory'
            extmarks[#extmarks+1] = {i, #line, #line + 1, 'DoraVirtText', 10000}
            line = line .. '/'
        elseif file.type == 'link' then
            line_hl = 'DoraSymlink'
        elseif icons.special_types[file.type] then
            line_hl = icons.special_types[file.type].hl
        end
        extmarks[#extmarks+1] = {i, 0, #line, line_hl, 100}
        lines[i] = line
    end
    local buf = create_scratch(path, lines)
    for _, mark in ipairs(extmarks) do
        api.nvim_buf_set_extmark(buf, NS, mark[1] - 1, mark[2], {
            end_col = mark[3],
            hl_group = mark[4],
            priority = mark[5],
        })
    end
    return buf
end

---@param state DoraState
---@param preview DoraPreviewWindow
---@param path? string
local function show(state, preview, path)
    preview.path = path
    preview.full = false
    preview.loadable = false
    local buf
    if not path then
        buf = create_scratch(nil, {})
    else
        -- fs_stat resolves symlinks, so a link to a file previews its target
        -- and a link to a directory lists it. Only regular files are read:
        -- opening e.g. a fifo would block.
        local stat = uv.fs_stat(path)
        if not stat then
            buf = create_scratch(path, {}, '(cannot preview)')
        elseif stat.type == 'directory' then
            buf = create_directory_scratch(state, path)
        elseif stat.type ~= 'file' then
            buf = create_scratch(path, {}, '(' .. stat.type .. ')')
        else
            local lines, err, binary = read_head_lines(path, vim.o.lines)
            if binary then
                preview.loadable = true
                buf = create_scratch(path, {}, '(binary)')
            elseif not lines then
                buf = create_scratch(path, {}, '(' .. (err or 'cannot preview') .. ')')
            else
                preview.loadable = true
                buf = create_scratch(path, lines)
                apply_highlight(buf, path, lines)
            end
        end
    end
    if not pcall(api.nvim_win_set_buf, preview.win, buf) then
        pcall(api.nvim_buf_delete, buf, {force = true})
    end
end

-- Re-preview the hovered row. A no-op while the row's path is unchanged, so a
-- buffer loaded by focusing the preview stays put until the cursor moves to
-- another entry.
---@param state DoraState
---@param row DoraTreeRow?
function M.update(state, row)
    local preview = state.preview
    if not preview then
        return
    end
    if not window.valid_win(preview.win) then
        M.close(state)
        return
    end
    local path = row and row.path or nil
    if path == preview.path then
        return
    end
    show(state, preview, path)
end

---@param state DoraState
function M.close(state)
    local preview = state.preview
    if not preview then
        return
    end
    state.preview = nil
    pcall(api.nvim_del_augroup_by_id, preview.augroup)
    if window.valid_win(preview.win) then
        pcall(api.nvim_win_close, preview.win, true)
    end
end

---@param state DoraState
---@param row DoraTreeRow?
function M.toggle(state, row)
    if state.preview then
        M.close(state)
        return
    end
    local dora_win = api.nvim_get_current_win()
    local win = api.nvim_open_win(create_scratch(nil, {}), false, {
        split = config.preview_split,
        win = dora_win,
    })
    local augroup = api.nvim_create_augroup('dora/preview_win.' .. state.buf, {clear = true})
    ---@type DoraPreviewWindow
    local preview = {win = win, augroup = augroup, loadable = false, full = false}
    state.preview = preview

    -- Focusing the preview swaps the partial scratch for the real buffer so
    -- the whole file can be scrolled (and edited). `nested` lets filetype
    -- detection and other plugins attach as on a normal :edit.
    api.nvim_create_autocmd('WinEnter', {
        group = augroup,
        nested = true,
        callback = function()
            if state.preview ~= preview or api.nvim_get_current_win() ~= win
                    or preview.full or not preview.loadable then
                return
            end
            local path = preview.path
            ---@cast path -nil  -- loadable is only set alongside a path
            local ok, err = pcall(vim.cmd --[[@as function]], 'keepalt edit ' .. vim.fn.fnameescape(path))
            if not ok then
                util.err(err)
                return
            end
            preview.full = true
        end,
    })
    -- Track manual closes (:q in the preview) so toggle can reopen cleanly.
    api.nvim_create_autocmd('WinClosed', {
        group = augroup,
        pattern = tostring(win),
        callback = function()
            if state.preview == preview then
                state.preview = nil
                pcall(api.nvim_del_augroup_by_id, augroup)
            end
        end,
    })
    -- The preview belongs to its dora window; closing that window (e.g. :q,
    -- which hides rather than wipes the dora buffer) takes the preview with
    -- it. Changing the window layout is restricted while WinClosed runs, so
    -- defer the close.
    api.nvim_create_autocmd('WinClosed', {
        group = augroup,
        pattern = tostring(dora_win),
        callback = function()
            vim.schedule(function()
                if state.preview == preview then
                    M.close(state)
                end
            end)
        end,
    })
    M.update(state, row)
end

return M
