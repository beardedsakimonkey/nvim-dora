-- dora.configure(): in-place config merging and default keymap descriptions.
-- Part of the smoke suite (driven by scripts/smoke.lua). Run this file on
-- its own with DORA_TEST_FILE=scripts/tests/01_configure.lua (see scripts/smoke.sh).
local h = dofile('scripts/tests/helpers.lua')
local dora = h.dora
local descriptions = h.actions.descriptions
local config = h.config
local keymaps = h.keymaps
local prompt = h.prompt
local cwd = h.cwd
local assert_eq = h.assert_eq

assert_eq(config.lsp_timeout, 1000, 'LSP rename integration should default to a one-second timeout')
assert_eq(config.show_root, false, 'the browsed directory should not render as the tree root by default')

for lhs, rhs in pairs(config.keymaps) do
    local _, desc = keymaps.resolve(rhs)
    assert(desc, ('default keymap %s should have a description'):format(lhs))
end

do
    local old_config = dora.config
    local old_keymaps = dora.config.keymaps
    local old_show_hidden_files = dora.config.show_hidden_files
    local old_tree_indent = dora.config.tree_indent
    local old_q = dora.config.keymaps.q
    local old_smoke_key = dora.config.keymaps.__dora_smoke_configure

    dora.configure({
        show_hidden_files = false,
        tree_indent = 2,
        keymaps = {
            q = {'quit'},
            __dora_smoke_configure = 'help',
        },
    })

    assert_eq(dora.config, old_config, 'configure should preserve the config table')
    assert_eq(dora.config.keymaps, old_keymaps, 'configure should preserve the keymaps table')
    assert_eq(config.show_hidden_files, false, 'configure should update config values in-place')
    assert_eq(config.tree_indent, 2, 'configure should update tree indentation')
    assert_eq(config.keymaps.__dora_smoke_configure, 'help', 'configure should merge new keymaps')
    assert_eq(config.keymaps.q.desc, nil, 'configure should replace keymap specs instead of merging desc')
    local _, q_desc = keymaps.resolve(config.keymaps.q)
    assert_eq(q_desc, descriptions.quit, 'table overrides without desc should inherit the action description')

    dora.config.show_hidden_files = old_show_hidden_files
    dora.config.tree_indent = old_tree_indent
    dora.config.keymaps.q = old_q
    dora.config.keymaps.__dora_smoke_configure = old_smoke_key
end

local cwd = assert(vim.loop.cwd())

assert_eq(vim.fn.synIDtrans(vim.fn.hlID('DoraPromptBorder')), vim.fn.synIDtrans(vim.fn.hlID('FloatBorder')), 'prompt border should default to FloatBorder')
