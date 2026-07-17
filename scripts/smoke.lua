-- Driver for the smoke suite. Each file under scripts/tests/ covers one area
-- and shares scripts/tests/helpers.lua. The files run in order in a single
-- Neovim instance, so state a test leaves behind (window history, trash history,
-- expanded directories) stays visible to later files. Run a single area with
-- DORA_TEST_FILE=scripts/tests/<file>.lua using the nvim invocation from
-- scripts/smoke.sh.
local test_files = {
    'scripts/tests/01_configure.lua',
    'scripts/tests/02_confirm_win.lua',
    'scripts/tests/03_prompt.lua',
    'scripts/tests/04_fs.lua',
    'scripts/tests/05_navigation.lua',
    'scripts/tests/06_file_ops.lua',
    'scripts/tests/07_paste.lua',
    'scripts/tests/08_rename_symlinks.lua',
    'scripts/tests/09_history.lua',
    'scripts/tests/10_keymap_hints.lua',
    'scripts/tests/11_sort_yank_info.lua',
    'scripts/tests/12_help_folds.lua',
    'scripts/tests/13_filter.lua',
    'scripts/tests/14_windows.lua',
    'scripts/tests/15_special_files.lua',
    'scripts/tests/16_lsp.lua',
    'scripts/tests/17_show_root.lua',
}

for _, file in ipairs(test_files) do
    dofile(file)
end

print('smoke ok\n')
