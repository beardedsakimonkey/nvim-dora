local readme_path = 'README.md'
local config_path = 'lua/dora.lua'
local highlights_path = 'plugin/dora.lua'
local config_start_marker = '<!-- dora-config:start -->'
local config_end_marker = '<!-- dora-config:end -->'
local highlights_start_marker = '<!-- dora-highlights:start -->'
local highlights_end_marker = '<!-- dora-highlights:end -->'

local function fail(message)
    vim.api.nvim_err_writeln(message)
    vim.cmd.cquit()
end

local function read_file(path)
    local fd = assert(io.open(path, 'r'))
    local contents = assert(fd:read('*a'))
    assert(fd:close())
    return contents
end

local function write_file(path, contents)
    local fd = assert(io.open(path, 'w'))
    assert(fd:write(contents))
    assert(fd:close())
end

local function split_lines(contents)
    local lines = {}
    for line in (contents .. '\n'):gmatch('(.-)\n') do
        lines[#lines+1] = line
    end
    return lines
end

local function brace_delta(line)
    local _, opens = line:gsub('{', '')
    local _, closes = line:gsub('}', '')
    return opens - closes
end

local function extract_config_block(contents)
    local lines = split_lines(contents)
    local block = {}
    local depth

    for _, line in ipairs(lines) do
        if not depth then
            if line:match('^M%.config%s*=%s*{') then
                block[#block+1] = line:gsub('^M%.config%s*=%s*{', "require('dora').setup {", 1)
                depth = brace_delta(line)
            end
        else
            block[#block+1] = line
            depth = depth + brace_delta(line)
            if depth == 0 then
                return table.concat(block, '\n')
            end
        end
    end

    fail('could not find M.config block in ' .. config_path)
end

local function generate_config_section()
    return table.concat({
        '```lua',
        extract_config_block(read_file(config_path)),
        '```',
    }, '\n')
end

local function extract_highlight_groups(contents)
    local groups = {}

    for _, line in ipairs(split_lines(contents)) do
        local cmd = line:match("^vim%.cmd%s*'(.*)'%s*$")
            or line:match('^vim%.cmd%s*"(.*)"%s*$')
        if cmd and cmd:match('^hi%s+default%s+link%s+(Dora%S+)%s+%S+$') then
            groups[#groups+1] = cmd
        end
    end

    if #groups == 0 then
        fail('could not find highlight groups in ' .. highlights_path)
    end

    return groups
end

local function generate_highlights_section()
    return table.concat({
        '```vim',
        table.concat(extract_highlight_groups(read_file(highlights_path)), '\n'),
        '```',
    }, '\n')
end

local function replace_section(readme, start_marker, end_marker, generated)
    local start_at, start_end = readme:find(start_marker, 1, true)
    assert(start_at, 'missing ' .. start_marker)
    local end_at, end_end = readme:find(end_marker, start_end + 1, true)
    assert(end_at, 'missing ' .. end_marker)
    return table.concat({
        readme:sub(1, start_end),
        '\n',
        generated,
        '\n',
        readme:sub(end_at, end_end),
        readme:sub(end_end + 1),
    })
end

local readme = read_file(readme_path)
local updated = replace_section(
    readme,
    config_start_marker,
    config_end_marker,
    generate_config_section()
)
updated = replace_section(
    updated,
    highlights_start_marker,
    highlights_end_marker,
    generate_highlights_section()
)

if vim.env.DORA_DOCS_CHECK == '1' then
    if updated ~= readme then
        fail(readme_path .. ' generated docs are stale. Run: sh scripts/docs.sh')
    end
else
    write_file(readme_path, updated)
end
