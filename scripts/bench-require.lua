local uv = vim.uv or vim.loop

local iterations = tonumber(vim.env.DORA_BENCH_ITERS) or 1000
local warmup = tonumber(vim.env.DORA_BENCH_WARMUP) or 50

local cases = {
    {
        name = "require'dora'",
        fn = function()
            require'dora'
        end,
    },
    {
        name = "require'dora' + setup",
        fn = function()
            require'dora'.setup({show_hidden_files = false})
        end,
    },
    {
        name = "require'dora.core'",
        fn = function()
            require'dora.core'
        end,
    },
}

local function clear_dora_modules()
    for name in pairs(package.loaded) do
        if name == 'dora' or name:match('^dora%.') then
            package.loaded[name] = nil
        end
    end
end

local function percentile(sorted, pct)
    local index = math.ceil(#sorted * pct)
    index = math.max(1, math.min(index, #sorted))
    return sorted[index]
end

local function mean(samples)
    local total = 0
    for _, sample in ipairs(samples) do
        total = total + sample
    end
    return total / #samples
end

local function benchmark(case)
    for _ = 1, warmup do
        clear_dora_modules()
        case.fn()
    end

    collectgarbage'collect'

    local samples = {}
    for i = 1, iterations do
        clear_dora_modules()
        local start = uv.hrtime()
        case.fn()
        samples[i] = (uv.hrtime() - start) / 1e6
    end

    table.sort(samples)
    return {
        min = samples[1],
        mean = mean(samples),
        p50 = percentile(samples, 0.50),
        p95 = percentile(samples, 0.95),
        max = samples[#samples],
    }
end

print(('dora require benchmark (%d iterations, %d warmup)'):format(iterations, warmup))
print('case                             min ms  mean ms   p50 ms   p95 ms   max ms')
print('--------------------------------------------------------------------------')

for _, case in ipairs(cases) do
    local result = benchmark(case)
    print(('%-31s %7.3f  %7.3f  %7.3f  %7.3f  %7.3f'):format(
        case.name,
        result.min,
        result.mean,
        result.p50,
        result.p95,
        result.max
    ))
end
