local M = {}

local VALID_SORT_ORDERS = {
    name = true,
    name_reverse = true,
    modified = true,
    modified_reverse = true,
    created = true,
    created_reverse = true,
    size = true,
    size_reverse = true,
    extension = true,
    extension_reverse = true,
}

---@param order any
---@return DoraSortOrder
function M.normalize_order(order)
    if VALID_SORT_ORDERS[order] then
        return order
    end
    return 'name'
end

---@param name string
---@return string
local function extension(name)
    local dot
    local start = name:sub(1, 1) == '.' and 2 or 1
    for i = start, #name do
        if name:sub(i, i) == '.' then
            dot = i
        end
    end
    return dot and name:sub(dot + 1):lower() or ''
end

---@param value string
---@param index integer
---@return string chunk
---@return boolean is_number
---@return integer next_index
local function natural_chunk(value, index)
    local is_number = value:sub(index, index):match('%d') ~= nil
    local next_index = index + 1
    while next_index <= #value do
        local next_is_number = value:sub(next_index, next_index):match('%d') ~= nil
        if next_is_number ~= is_number then
            break
        end
        next_index = next_index + 1
    end
    return value:sub(index, next_index - 1), is_number, next_index
end

---@param a string
---@param b string
---@return boolean?
local function natural_name_less(a, b)
    local left = a:lower()
    local right = b:lower()
    local left_index = 1
    local right_index = 1
    while left_index <= #left and right_index <= #right do
        local left_chunk, left_is_number, next_left = natural_chunk(left, left_index)
        local right_chunk, right_is_number, next_right = natural_chunk(right, right_index)
        if left_is_number and right_is_number then
            local left_number = left_chunk:gsub('^0+', '')
            local right_number = right_chunk:gsub('^0+', '')
            left_number = left_number ~= '' and left_number or '0'
            right_number = right_number ~= '' and right_number or '0'
            if #left_number ~= #right_number then
                return #left_number < #right_number
            end
            if left_number ~= right_number then
                return left_number < right_number
            end
            if #left_chunk ~= #right_chunk then
                return #left_chunk < #right_chunk
            end
        elseif left_chunk ~= right_chunk then
            return left_chunk < right_chunk
        end
        left_index = next_left
        right_index = next_right
    end
    if #left ~= #right then
        return #left < #right
    end
    if a ~= b then
        return a < b
    end
    return nil
end

---@param a table?
---@param b table?
---@return integer
local function compare_time(a, b)
    local a_sec = a and a.sec or 0
    local b_sec = b and b.sec or 0
    if a_sec ~= b_sec then
        return a_sec < b_sec and -1 or 1
    end
    local a_nsec = a and a.nsec or 0
    local b_nsec = b and b.nsec or 0
    if a_nsec ~= b_nsec then
        return a_nsec < b_nsec and -1 or 1
    end
    return 0
end

---@param a DoraFile
---@param b DoraFile
---@param order DoraSortOrder
---@return boolean
local function file_less(a, b, order)
    if (a.type == 'directory') ~= (b.type == 'directory') then
        return a.type == 'directory'
    end
    if order == 'name_reverse' then
        return natural_name_less(b.name, a.name) == true
    elseif order == 'modified' or order == 'modified_reverse' then
        local cmp = compare_time(a.mtime, b.mtime)
        if cmp ~= 0 then
            if order == 'modified' then
                return cmp < 0
            end
            return cmp > 0
        end
    elseif order == 'created' or order == 'created_reverse' then
        local cmp = compare_time(a.birthtime, b.birthtime)
        if cmp ~= 0 then
            if order == 'created' then
                return cmp < 0
            end
            return cmp > 0
        end
    elseif order == 'size' or order == 'size_reverse' then
        local a_size = a.size or 0
        local b_size = b.size or 0
        if a_size ~= b_size then
            if order == 'size' then
                return a_size < b_size
            end
            return a_size > b_size
        end
    elseif order == 'extension' or order == 'extension_reverse' then
        local a_ext = extension(a.name)
        local b_ext = extension(b.name)
        if a_ext ~= b_ext then
            if order == 'extension' then
                return a_ext < b_ext
            end
            return a_ext > b_ext
        end
    end
    return natural_name_less(a.name, b.name) == true
end

---@param files DoraFile[]
---@param order DoraSortOrder
function M.files(files, order)
    order = M.normalize_order(order)
    table.sort(files, function(a, b)
        return file_less(a, b, order)
    end)
end

return M
