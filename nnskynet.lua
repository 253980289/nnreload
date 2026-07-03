--[[
create by lj 2025-12-3
模块
    nnskynet
模块说明
    便于非skynet环境测试的桩
功能

修改历史

]]
if SERVICE_NAME then
    return require("skynet")
end
local _id = 0
local co_create = coroutine.create
local fork_queue = {}
local M = {
}
local function run_next_coroutine()
    if 0 == #fork_queue then
        return 0
    end
    table.sort(fork_queue, function(a, b)
        return a.sleep > b.sleep
    end)
    local task = table.remove(fork_queue)
    coroutine.resume(task.co) -- 如果协程执行完成，将不会再回到fork_queue中
    return 1
end
function M.run(times)
    while run_next_coroutine() > 0 do
        if times then
            times = times - 1
            if times <= 0 then
                break
            end
        end
    end
end
function M.main()
    M.run()
    -- os.exit(0)
end

M.error = print

M.now = os.clock

M.start = function(f)
    f()
end

M.dispatch = function(type, dispatch)
    -- dispatch()
end

M.ret = print

M.pack = function(...)
    return ...
end

M.sleep = function(_sleep)
    -- 为了尽可能保证有序性及避免因稳定排序导致的部分协程永远得不到调用的问题发生
    for i,v in ipairs(fork_queue) do
        v.sleep = v.sleep - 1
        -- if v.sleep < 0 then
        --     v.sleep = 0
        -- end
    end
    table.insert(fork_queue, { co = coroutine.running(), sleep = _sleep })
    coroutine.yield()
end

M.fork = function(func, ...)
    local function guard_fun( ... )
        local ret = table.pack(xpcall(func, debug.traceback, ...))
        if not ret[1] then
            print(ret[2])
            -- os.exit(0)
            error(ret[2])
        end
        return table.unpack(ret, 2, ret.n)
    end
    local n = select("#", ...)
    local co
    if n == 0 then
        co = co_create(guard_fun)
    else
        local args = { ... }
        co = co_create(function() guard_fun(table.unpack(args, 1, n)) end)
    end
    table.insert(fork_queue, { co = co, sleep = 0 })
    return co
end

M.genid = function(...)
    _id = _id + 1
    return _id
end

M.self = function(...)
    return 1
end

function M.yield(...)
    M.sleep(0)
end

-- 兼容我们框架接口
function M.fork_by_name(name, fun, ...)
    return M.fork(fun, ...)
end

M.print = print
M.service = M
M.dlog = function( ... )
    print(string.format("[%s]", coroutine.running()), ...)
end
M.log = M
M.dispatch_lua_msg = function( ... ) end
M.skynet = M
M.sleep_second = function(second, thread)
    return M.sleep(second * 100)
end
M.sleep_millisecond = function(millisecond, thread)
    return M.sleep(millisecond / 10)
end
M.utils = M

local function test(...)
    local skynet = M
    skynet.fork(function( ... )
        for i=1,10 do
            print(1, i)
            skynet.sleep(i)
        end
    end)
    skynet.fork(function( ... )
        for i=1,10 do
            print(2, i)
            skynet.sleep(i)
        end
    end)
    skynet.main()
end
-- test()
-- local co = coroutine.create(function( ... )
--     return false, "fake error"
-- end)
-- print(coroutine.resume(co))
-- print(coroutine.status(co))

return M
