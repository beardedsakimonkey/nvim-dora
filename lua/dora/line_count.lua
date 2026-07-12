-- Asynchronous, bounded-concurrency line counting for file annotations.
-- Counts are cached against the metadata gathered by the directory scan, so
-- unchanged files are not reread when a listing is invalidated and rebuilt.
local uv = vim.uv

local M = {}

local READ_CHUNK_BYTES = 64 * 1024
local MAX_CONCURRENT_READS = 4
local MAX_CACHE_ENTRIES = 4096

---@class DoraLineCountJob
---@field key string
---@field path string
---@field callbacks table<DoraState, fun(count: integer?)>

---@type table<string, {key: string, count: integer|false}>
local cache = {}
local cache_size = 0
---@type table<string, DoraLineCountJob>
local pending = {}
---@type DoraLineCountJob[]
local queue = {}
local queue_head = 1
local active_reads = 0
---@type table<string, {count: integer, latest_key: string}>
local inflight_by_path = {}

---@param path string
---@param file DoraFile
---@return string
local function cache_key(path, file)
    local mtime = file.mtime or {}
    return table.concat({path, file.size or 0, mtime.sec or 0, mtime.nsec or 0}, '\0')
end

---@param path string
---@param key string
---@param count integer|false
local function cache_set(path, key, count)
    if not cache[path] then
        if cache_size >= MAX_CACHE_ENTRIES then
            local evicted = next(cache)
            if evicted then
                cache[evicted] = nil
                cache_size = cache_size - 1
            end
        end
        cache_size = cache_size + 1
    end
    cache[path] = {key = key, count = count}
end

local pump

---@param job DoraLineCountJob
---@param count integer|false
---@param cache_result boolean
local function remove_inflight(job, count, cache_result)
    local path_jobs = assert(inflight_by_path[job.path])
    if cache_result and path_jobs.latest_key == job.key then
        cache_set(job.path, job.key, count)
    end
    path_jobs.count = path_jobs.count - 1
    if path_jobs.count == 0 then
        inflight_by_path[job.path] = nil
    end
    pending[job.key] = nil
end

---@param job DoraLineCountJob
---@param count integer|false false means the file was binary or unreadable
local function finish(job, count)
    -- The file may have changed again while this read was in flight. Do not
    -- let an older completion replace the cache entry for a newer scan.
    remove_inflight(job, count, true)
    active_reads = active_reads - 1
    local callbacks = job.callbacks
    vim.schedule(function()
        for _, callback in pairs(callbacks) do
            pcall(callback, count ~= false and count or nil)
        end
    end)
    pump()
end

---@param job DoraLineCountJob
local function read_file(job)
    uv.fs_open(job.path, 'r', 0, function(open_err, fd)
        if open_err or not fd then
            finish(job, false)
            return
        end

        local offset = 0
        local newline_count = 0
        local last_byte

        local function done(count)
            uv.fs_close(fd)
            finish(job, count)
        end

        local function read_chunk()
            uv.fs_read(fd, READ_CHUNK_BYTES, offset, function(read_err, chunk)
                if read_err then
                    done(false)
                    return
                end
                if not chunk or #chunk == 0 then
                    local count = offset == 0 and 0
                        or newline_count + (last_byte == '\n' and 0 or 1)
                    done(count)
                    return
                end
                -- A NUL byte is a strong enough signal that a file is binary;
                -- stop immediately instead of streaming the rest for a number
                -- that would not be useful in the browser.
                if chunk:find('\0', 1, true) then
                    done(false)
                    return
                end
                local search_from = 1
                while true do
                    local newline_at = chunk:find('\n', search_from, true)
                    if not newline_at then
                        break
                    end
                    newline_count = newline_count + 1
                    search_from = newline_at + 1
                end
                offset = offset + #chunk
                last_byte = chunk:sub(-1)
                read_chunk()
            end)
        end

        read_chunk()
    end)
end

pump = function()
    while active_reads < MAX_CONCURRENT_READS and queue_head <= #queue do
        local job = queue[queue_head]
        queue_head = queue_head + 1
        if next(job.callbacks) then
            active_reads = active_reads + 1
            read_file(job)
        else
            -- Its dora session was closed or its listing was discarded before
            -- this job reached the concurrency window.
            remove_inflight(job, false, false)
        end
    end
    if queue_head > #queue then
        queue = {}
        queue_head = 1
    end
end

-- Return a cached count when available; otherwise enqueue a background read
-- and notify the subscriber when it completes. Repeated renders replace the
-- callback for that session instead of accumulating duplicate callbacks.
---@param path string
---@param file DoraFile
---@param subscriber DoraState
---@param on_ready fun(count: integer?)
---@return integer? count
---@return boolean ready true for both a count and a deliberately skipped file
function M.get(path, file, subscriber, on_ready)
    local key = cache_key(path, file)
    local cached = cache[path]
    if cached and cached.key == key then
        return cached.count ~= false and cached.count or nil, true
    end

    local job = pending[key]
    if job then
        job.callbacks[subscriber] = on_ready
        return nil, false
    end

    job = {
        key = key,
        path = path,
        callbacks = {[subscriber] = on_ready},
    }
    local path_jobs = inflight_by_path[path]
    if path_jobs then
        path_jobs.count = path_jobs.count + 1
        path_jobs.latest_key = key
    else
        inflight_by_path[path] = {count = 1, latest_key = key}
    end
    pending[key] = job
    queue[#queue+1] = job
    pump()
    return nil, false
end

-- Drop a session's interest in queued work. Active reads are allowed to finish
-- and populate the cache, but queued jobs with no remaining subscribers are
-- discarded before they perform any I/O.
---@param subscriber DoraState
function M.unsubscribe(subscriber)
    for _, job in pairs(pending) do
        job.callbacks[subscriber] = nil
    end
end

return M
