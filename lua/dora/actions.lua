-- Metadata for every built-in action (the M.* functions in dora/api.lua).
-- This is the single source of truth consumed by dora/keymaps.lua (mapping
-- descriptions, visual-mode variants) and dora/ui/help.lua (section grouping
-- and ordering). To add an action: implement it in api.lua, add a record
-- here, and (optionally) bind it in the default keymaps in dora.lua.
local M = {}

---@class DoraActionMeta
---@field name string Name of the action's function in dora/api.lua
---@field desc string Description shown in mappings, prefix hints, and `g?` help
---@field section string Help window section the action is listed under
---@field visual? string Action dispatched when the mapping is used in visual mode

-- Section display order in the help window.
M.SECTIONS = {'General', 'Navigation', 'Open', 'File Operations', 'View', 'Yank', 'Sort'}

-- Order matters: the help window lists each section's actions in this order.
---@type DoraActionMeta[]
M.ACTIONS = {
    -- General
    {name = 'help', desc = 'Show help', section = 'General'},
    {name = 'quit', desc = 'Quit dora', section = 'General'},

    -- Navigation
    {name = 'up_dir', desc = 'Up directory', section = 'Navigation'},
    {name = 'next_sibling', desc = 'Next sibling', section = 'Navigation', visual = 'next_sibling'},
    {name = 'prev_sibling', desc = 'Previous sibling', section = 'Navigation', visual = 'prev_sibling'},
    {name = 'parent_dir', desc = 'Parent directory', section = 'Navigation', visual = 'parent_dir'},
    {name = 'fold_out', desc = 'Fold out directory one level', section = 'Navigation', visual = 'fold_out_visual'},
    {name = 'fold_out_recursive', desc = 'Fold out directory all the way', section = 'Navigation', visual = 'fold_out_recursive_visual'},
    {name = 'fold_in', desc = 'Fold in directory one level', section = 'Navigation', visual = 'fold_in_visual'},
    {name = 'fold_in_recursive', desc = 'Fold in directory all the way', section = 'Navigation', visual = 'fold_in_recursive_visual'},
    {name = 'close_dir', desc = 'Close directory', section = 'Navigation', visual = 'close_dir_visual'},
    {name = 'home_dir', desc = 'Go to home directory', section = 'Navigation'},
    {name = 'next_paste_mark', desc = 'Go to next paste mark', section = 'Navigation', visual = 'next_paste_mark'},
    {name = 'prev_paste_mark', desc = 'Go to previous paste mark', section = 'Navigation', visual = 'prev_paste_mark'},
    {name = 'history_back', desc = 'Go backward in directory history', section = 'Navigation'},
    {name = 'history_forward', desc = 'Go forward in directory history', section = 'Navigation'},

    -- Open
    {name = 'open', desc = 'Open', section = 'Open', visual = 'open_visual'},
    {name = 'open_split', desc = 'Open in split', section = 'Open', visual = 'open_split_visual'},
    {name = 'open_vsplit', desc = 'Open in vertical split', section = 'Open', visual = 'open_vsplit_visual'},
    {name = 'open_tab', desc = 'Open in tab', section = 'Open', visual = 'open_tab_visual'},
    {name = 'open_split_stay', desc = 'Open in split without closing Dora', section = 'Open', visual = 'open_split_stay_visual'},
    {name = 'open_vsplit_stay', desc = 'Open in vertical split without closing Dora', section = 'Open', visual = 'open_vsplit_stay_visual'},
    {name = 'open_tab_stay', desc = 'Open in tab without closing Dora', section = 'Open', visual = 'open_tab_stay_visual'},
    {name = 'open_external', desc = 'Open in external program', section = 'Open', visual = 'open_external_visual'},

    -- File Operations
    {name = 'add', desc = 'Add file or folder', section = 'File Operations'},
    {name = 'add_under', desc = 'Add file or folder under directory', section = 'File Operations'},
    {name = 'create_symlink', desc = 'Create symlink to file', section = 'File Operations'},
    {name = 'rename', desc = 'Rename file', section = 'File Operations'},
    {name = 'rename_empty', desc = 'Rename file with empty prompt', section = 'File Operations'},
    {name = 'trash', desc = 'Move file to trash (macOS/Linux)', section = 'File Operations', visual = 'trash_visual'},
    {name = 'delete', desc = 'Delete file permanently', section = 'File Operations', visual = 'delete_visual'},
    {name = 'undo_trash', desc = 'Restore the most recently trashed files', section = 'File Operations'},
    {name = 'toggle_cut', desc = 'Toggle cut mark', section = 'File Operations', visual = 'toggle_cut_visual'},
    {name = 'clear_cut', desc = 'Clear all cut marks', section = 'File Operations'},
    {name = 'toggle_copy', desc = 'Toggle copy mark', section = 'File Operations', visual = 'toggle_copy_visual'},
    {name = 'clear_copy', desc = 'Clear all copy marks', section = 'File Operations'},
    {name = 'paste_under', desc = 'Paste under directory', section = 'File Operations'},
    {name = 'paste', desc = 'Paste', section = 'File Operations'},
    {name = 'shell_cmd', desc = 'Run shell command on file', section = 'File Operations'},

    -- View
    {name = 'filter', desc = 'Filter visible files', section = 'View'},
    {name = 'clear_filter', desc = 'Clear filter', section = 'View'},
    {name = 'file_info', desc = 'Show file info', section = 'View'},
    {name = 'toggle_hidden_files', desc = 'Toggle hidden files visible', section = 'View'},
    {name = 'toggle_preview', desc = 'Toggle file preview', section = 'View'},
    {name = 'reload', desc = 'Reload tree view', section = 'View'},

    -- Yank
    {name = 'yank_full_path', desc = 'Yank full path', section = 'Yank'},
    {name = 'yank_full_path_clipboard', desc = 'Yank full path to clipboard', section = 'Yank'},
    {name = 'yank_dir_path', desc = 'Yank parent directory', section = 'Yank'},
    {name = 'yank_dir_path_clipboard', desc = 'Yank parent directory to clipboard', section = 'Yank'},
    {name = 'yank_filename', desc = 'Yank filename', section = 'Yank'},
    {name = 'yank_filename_clipboard', desc = 'Yank filename to clipboard', section = 'Yank'},
    {name = 'yank_name_stem', desc = 'Yank name without extension', section = 'Yank'},
    {name = 'yank_name_stem_clipboard', desc = 'Yank name without extension to clipboard', section = 'Yank'},

    -- Sort
    {name = 'sort_by_name', desc = 'Sort by name', section = 'Sort'},
    {name = 'sort_by_name_desc', desc = 'Sort by name (descending)', section = 'Sort'},
    {name = 'sort_by_modified', desc = 'Sort by modified time', section = 'Sort'},
    {name = 'sort_by_modified_desc', desc = 'Sort by modified time (descending)', section = 'Sort'},
    {name = 'sort_by_created', desc = 'Sort by creation time', section = 'Sort'},
    {name = 'sort_by_created_desc', desc = 'Sort by creation time (descending)', section = 'Sort'},
    {name = 'sort_by_size', desc = 'Sort by size', section = 'Sort'},
    {name = 'sort_by_size_desc', desc = 'Sort by size (descending)', section = 'Sort'},
    {name = 'sort_by_extension', desc = 'Sort by extension', section = 'Sort'},
    {name = 'sort_by_extension_desc', desc = 'Sort by extension (descending)', section = 'Sort'},
}

-- Lookups derived from M.ACTIONS.
---@type table<string, string> action name -> description
M.descriptions = {}
---@type table<string, string> action name -> visual-mode variant action
M.visual_variants = {}
for _, action in ipairs(M.ACTIONS) do
    M.descriptions[action.name] = action.desc
    if action.visual then
        M.visual_variants[action.name] = action.visual
    end
end

return M
