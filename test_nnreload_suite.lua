--[[
create by lj 2026-5-28
模块名
    test_reload_suite
功能
    nnreload 模块的专用测试用例
设计
]]

-- test_reload_suite.lua
-- 批量回归测试 nnreload 热重载功能，依赖的
-- 用法：lua test_reload_suite.lua

local debug = debug
local print_ = print
local getmetatable = getmetatable
local tostring = tostring
local string_find = string.find
local string_format = string.format
local error = error
local nnskynet = require("nnskynet") -- 模拟的纯lua环境依赖测试接口，非真实依赖
local reload = require("nnreload") -- nnhotfix|reload|nnreload
-- reload.print = print
local fail_detailed_report = false
local dry_run-- = true
local run_base_case = true
local run_craft_supported_case = true -- 测试号[41, 60]的用例表示需要特殊技巧配合才能支持的场景
local run_compatibility_supported_case = true -- 测试号[61, 100]的用例表示兼容但不推荐的场景
local run_not_supported_case-- = true -- 测试号[101, 200]的用例表示目前仍不支持的热更场景
local run_ambiguity_case-- = true -- 测试号[201, 300]的用例表示目前存在歧义的热更场景(需要注意细节点)
local run_bug_case-- = true -- 坑：测试号[301, 400]的用例表示需要特别规避的不支持的热更场景
local run_try_case = true -- 新实验用例，结果不确定
local options = {
        -- for debug
        -- debug_log_change = print,
        -- debug_log_step = print,
        -- debug_log_new_code = print,
        -- error_log = print,
        -- show_old_to_new_func_map = print,
        after_check_vm_dummy = true,

        -- for function
        dry_run = dry_run,
        enable_invalid_reference_error = false,
        new_old_need_same_type = false,
        ignore_external_dependent_variables_change = true,
        enable_external_dependent_variables_change_fun = true,
        -- circular_reference_path_len = 32,
    }
local function clone_options()
    local tb_dst = {}
    for k,v in pairs(options) do
        tb_dst[k] = v
    end
    return tb_dst
end
if reload.set_options then
    reload.set_options(options)
end

local error_for_test = dry_run and function( ... ) print("[error]", ...) end or error
-- 辅助：捕获 print 输出
local function capture_print(fn, ...)
    local orig_print = print
    local out = {}
    print = function(...)
        local args = table.pack(...)
        -- for i, v in ipairs(args) do -- 会因空洞而跳过
        local n = args.n
        for i = 1, n do
            local v = args[i]
            out[#out + 1] = tostring(v)
            if i < n then out[#out + 1] = "\t" end
        end
        out[#out + 1] = "\n"
    end
    local ok, result = xpcall(fn, debug.traceback, ...)
    print = orig_print
    if not ok then error_for_test(result) end
    return table.concat(out)
end
-- test_nnreload_suite_clean.lua
-- 独立测试用例，每个用例包含原始模块代码和热更新代码
-- 用法：lua test_nnreload_suite_clean.lua

local function assert_equals(actual, expected, msg)
    if actual ~= expected then
        error_for_test(string_format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, msg)
    if not cond then error_for_test(msg) end
end

local function assert_false(cond, msg)
    if cond then error_for_test(msg) end
end

local function assert_find(str, pattern, msg)
    if not str or not string_find(str, pattern, 1, true) then
        error_for_test(string_format("%s: pattern '%s' not found in '%s'", msg, pattern, tostring(str)))
    end
end

local function assert_not_find(str, pattern, msg)
    if string_find(str, pattern, 1, true) then
        error_for_test(string_format("%s: pattern '%s' found in '%s'", msg, pattern, str))
    end
end

-- 断言值为 nil
local function assert_nil(value, message)
    if value ~= nil then
        error_for_test(string_format("assert_nil failed: %s (got %s)", message or "", tostring(value)))
    end
end

-- 清理指定模块的缓存
local function clear_module(name)
    package.loaded[name] = nil
    local reg = debug.getregistry()
    if reg._LOADED then
        reg._LOADED[name] = nil
    end
end

-- 注册模块（使用原始代码）
local function register_module(name, code)
    local chunk, err = load(code, "=" .. name)
    if not chunk then error_for_test(err) end
    -- package.preload[name] = function()
    --     return chunk()   -- 直接返回预编译的 chunk，无需再 load
    -- end
    package.preload[name] = chunk -- 问题的关键是如果这里附值为一个间接调用函数，更改其_ENV值并不能同步更改其内部函数的_ENV值，导致这里带入了测试环境的真实_ENV值，从而直接破坏沙箱环境的隔离性，引发失败故障
    -- local load_ = load
    -- local getupvalue = debug.getupvalue
    -- print("_ENV", _ENV)
    -- package.preload[name] = function()
    --     local chunk, err = load_(code, "=" .. name)
    --     print("getupvalue:", getupvalue(chunk, 1))
    --     return chunk()
    -- end
    -- print("package.preload[name]", package.preload[name])
end

-- 执行热重载
local function do_reload(mod_name)
    if "string" == type(mod_name) then
        mod_name = {mod_name}
    end
    local ok, err = reload.reload(mod_name)
    if not ok then error_for_test("reload failed: " .. tostring(err)) end
end

-- 运行单个测试
local tests = {}
local function run_test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    tests[#tests + 1] = { name = name, ok = ok, err = err }
    if ok then --  or dry_run
        print_("[PASS] " .. name)
    else
        print_("[FAIL] " .. name .. "\n  " .. tostring(err):gsub("\n", "\n  "))
    end
end

local function print_test_report()
    -- if dry_run then
    --     return
    -- end
    print_("\n========== 测试报告 ==========")
    local pass, fail = 0, 0
    local failed = {}
    for _, t in ipairs(tests) do
        if t.ok then pass = pass + 1 else
            fail = fail + 1; failed[#failed + 1] = t
        end
    end
    print_(string_format("总计: %d  通过: %d  失败: %d", #tests, pass, fail))
    if fail > 0 then
        if fail_detailed_report then
            print_("\n---------- 失败详情 ----------")
            for _, t in ipairs(failed) do
                print_(string_format("✗ %s\n  %s", t.name, t.err:gsub("\n", "\n  ")))
            end
        end
    else
        print_("\n🎉 所有测试通过！")
    end
end

if run_base_case then
    print("-----------------测试号[001, 100]的用例表示本模块支持的基本正常热更场景----------------------")
    run_test("1. 基本更新规则：upvalue字段替换函数保留状态", function()
        local main_name = "main_mod1"
        register_module(main_name, [[
            local val = 1
            local M = {
            }
            function M.fun( ... )
                val = val + 1
                return 1
            end
            function M.get()
                return val
            end
            return M
        ]])
        clear_module(main_name)
        local new_main = require(main_name)
        -- env_dependent.print(new_main)
        -- print("new_main", new_main.get(), new_main.fun(), new_main.get()) -- 有点不对，状态和函数都改了
        -- 此种情况这个val是否应该更新？
        register_module(main_name, [[
            local val = 3
            local M = {
            }
            function M.fun( ... )
                val = val + 2
                return 2
            end
            return M
        ]])
        do_reload({main_name})
        new_main = require(main_name)
        -- print("new_main", new_main.get(), new_main.fun(), new_main.get()) -- 有点不对，状态和函数都改了
        assert_equals(new_main.get(), 1, "保留状态")
        assert_equals(new_main.fun(), 2, "替换函数")
        assert_equals(new_main.get(), 3, "替换函数")
    end)

    run_test("2. 基本更新规则：表字段替换函数保留状态", function()
        local main_name = "main_mod2"
        register_module(main_name, [[
            local M = {
                val = 1,
            }
            function M.fun( ... )
                M.val = M.val + 1
                return 1
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- env_dependent.print(new_main)
        -- print("new_main", new_main.val, new_main.fun(), new_main.val) -- 有点不对，状态和函数都改了
        -- 此种情况这个val是否应该更新？
        register_module(main_name, [[
            local M = {
                val = 3,
            }
            function M.fun( ... )
                M.val = M.val + 2
                return 2
            end
            return M
        ]])
        do_reload({main_name})
        m = require(main_name)
        -- env_dependent.print(m)
        -- print("new_main", new_main.val, new_main.fun(), new_main.val) -- 有点不对，状态和函数都改了
        assert_equals(m.val, 1, "保留状态")
        assert_equals(m.fun(), 2, "替换函数")
        assert_equals(m.val, 3, "替换函数")
    end)

    run_test("3. 基本变量与函数更新", function()
        local mod_name = "test_basic"
        -- 原始模块
        register_module(mod_name, [[
            local a = 10
            local function get() return a end
            local function set(x) a = x end
            return { get = get, set = set }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        m.set(42)
        assert_equals(m.get(), 42, "热更前取值")

        -- 更新模块
        register_module(mod_name, [[
            local a = 100   -- 新初始值，但应被旧值覆盖
            local function get() return a end
            local function set(x) a = x end
            return { get = get, set = set }
        ]])
        do_reload(mod_name)
        assert_equals(m.get(), 42, "热更后仍保留旧 upvalue 值")
    end)

    run_test("4. 协程栈内局部函数引用更新", function()
        local mod_name = "test_coro"
        register_module(mod_name, [[
            local func = function() print("old") end
            local function start()
                local co = coroutine.create(function()
                    local f = func
                    coroutine.yield()
                    f()
                end)
                coroutine.resume(co)
                return co
            end
            return { start = start, set_func = function(f) func = f end }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        local co = m.start() -- 协程 yield 前保存了旧 func

        -- 更新模块
        register_module(mod_name, [[
            local func = function() print("new") end
            local function start()
                local co = coroutine.create(function()
                    local f = func
                    coroutine.yield()
                    f()
                end)
                coroutine.resume(co)
                return co
            end
            return { start = start, set_func = function(f) func = f end }
        ]])
        do_reload(mod_name)

        local out = capture_print(function() coroutine.resume(co) end) -- 第二次 resume 执行 f()
        assert_find(out, "new", "协程中的局部函数应被更新")
    end)

    run_test("5. 元表方法更新", function()
        local mod_name = "test_meta"
        register_module(mod_name, [[
            local mt = { __index = { show = function(self) print("old") end } }
            local function new() return setmetatable({}, mt) end
            return { new = new }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        local obj = m.new()
        local out1 = capture_print(function() obj:show() end)
        assert_find(out1, "old", "旧方法")

        -- 更新模块
        register_module(mod_name, [[
            local mt = { __index = { show = function(self) print("new") end } }
            local function new() return setmetatable({}, mt) end
            return { new = new }
        ]])
        do_reload(mod_name)
        local out2 = capture_print(function() obj:show() end)
        assert_find(out2, "new", "旧对象的元表方法应被更新")
    end)

    run_test("6. 带下划线的全局变量解析", function()
        _G.test_global_abc = 999
        local mod_name = "test_underscore"
        register_module(mod_name, [[
            local function get() return test_global_abc end
            return { get = get }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        assert_equals(m.get(), 999, "热更前读取全局正常")

        -- 更新模块（无变化，但需要触发重新解析）
        register_module(mod_name, [[
            local function get() return test_global_abc end
            return { get = get }
        ]])
        do_reload(mod_name)
        assert_equals(m.get(), 999, "热更后仍能正确解析")
        _G.test_global_abc = nil
    end)

    run_test("7. 新增函数能访问旧 upvalue", function()
        local mod_name = "test_newfunc_upvalue"
        register_module(mod_name, [[
            local state = 100
            local function get() return state end
            local function set(x) state = x end
            return { get = get, set = set }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        m.set(200)

        -- 更新模块：增加一个新函数 dump，打印 state
        register_module(mod_name, [[
            local state = 100
            local function get() return state end
            local function set(x) state = x end
            local function dump() print("state =", state) end
            return { get = get, set = set, dump = dump }
        ]])
        do_reload(mod_name)
        local out = capture_print(function() m.dump() end)
        assert_find(out, "state =\t200", "新函数应获取到更新前的 state 值")
    end)

    run_test("8. 热更含有运行时错误的函数：不做检测", function()
        local mod_name = "test_runtime_error"
        register_module(mod_name, [[
            local function safe() return "ok" end
            return { safe = safe }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)

        -- 更新模块：加入一个会出错的新函数
        register_module(mod_name, [[
            local function safe() return "ok" end
            local function bad() local nil_value = nil; return nil_value.nok end
            return { safe = safe, bad = bad }
        ]])
        do_reload(mod_name) -- 热更应成功
        local ok, err = pcall(m.bad)
        assert_false(ok, "bad 函数应抛出错误")
        assert_find(tostring(err), "attempt to index a nil value (local 'nil_value')", "错误信息匹配")
    end)

    run_test("9. 不同层 upvalue 同名（自动遮蔽）不崩溃", function()
        local mod_name = "test_shadow"
        register_module(mod_name, [[
            local b = 1
            local function run()
                local b = 10   -- 遮蔽外层
                print("inner b =", b)
            end
            return { run = run }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        local out1 = capture_print(function() m.run() end)
        assert_find(out1, "inner b =\t10", "旧版输出正确")

        -- 更新模块：修改外层 b 初始值和内层遮蔽值
        register_module(mod_name, [[
            local b = 5
            local function run()
                local b = 11
                print("inner b =", b)
            end
            return { run = run }
        ]])
        do_reload(mod_name)
        local out2 = capture_print(function() m.run() end)
        assert_find(out2, "inner b =\t11", "内层遮蔽值应更新为11")
        -- 注意：外层 b 的热更不影响内层，但内层是函数内的局部变量，随函数替换而更新
    end)

    run_test("10. 模块名包含点 '.' （子模块）的热重载", function()
        local sub_name = "sub.mod"
        local main_name = "main.mod"
        -- 子模块
        package.preload[sub_name] = function() return {val = 99} end
        -- 原始主模块（变量名 s）
        package.preload[main_name] = function()
            local s = require(sub_name)
            return { get = function() return s end, get2 = function() return s end}
        end
        clear_module(sub_name)
        clear_module(main_name)
        local main = require(main_name)
        assert_equals(main.get().val, 99, "旧版模块返回值")

        -- 更新主模块（变量名改为 sub）
        package.preload[main_name] = function()
            local s = require(sub_name)
            -- print("s", s.val)
            return { get = function() return s end, get2 = function() return s end }
        end
        package.preload[sub_name] = function() return {val = 100} end
        -- clear_module(sub_name) -- 让沙箱重新加载子模块
        do_reload({main_name, sub_name})
        -- print("package.loaded[sub_name]", package.loaded[sub_name].val)
        local new_main = package.loaded[main_name]
        local val = new_main.get().val
        assert_equals(type(val), "number", "返回值应为数字，不是 dummy")
        assert_equals(val, 99, "值保持不变")
        assert_equals(new_main.get2().val, 99, "值保持不变")
    end)

    run_test("11. 未解决的全局引用检测：热加载代码主代码中包含未定义的全局变量时将被强制置nil(风险：可能热更代码有问题)", function()
        local mod_name = "test_unsolved"
        package.preload[mod_name] = function()
            return { use = function() return not_exist_var end, var = not_exist_var } -- use是函数内运行时代码，并不在reload期间执行，不报异常是合理的
        end
        clear_module(mod_name)
        local m = require(mod_name)
        local ok, err = pcall(do_reload, { mod_name })
        -- print("m.use()", m.use()) -- 并不报错，仅返回nil，是正常的
        -- print_(m.var)
        -- print("reload.enable_invalid_reference_error", reload.enable_invalid_reference_error)
        -- os.exit(0)
        if reload.enable_invalid_reference_error then
            assert_false(ok, "应检测到未解决的全局变量")
            assert_find(tostring(err), "invalid global reference", "错误信息匹配")
        else
            assert_true(ok, "跳过未解决的全局变量")
        end
    end)

    run_test("12. 验证从外部依赖模式附值自身时是否有bug", function()
        local main_name = "test_set_self"
        register_module(main_name, [[
            local M = {
                a = 1,
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- env_dependent.print(m)

        register_module(main_name, string_format([[
            local M = {
                a = package.loaded["%s"] and package.loaded["%s"].a or 1
            }
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        assert_equals(m.a, 1, "期望热更后a保持原值")
    end)

    run_test("13. 验证solve_globals【_LOADED[name] = mod】【goto next_for】两处修改的作用 (pairs会导致测试结论不稳定)", function()
        local modC = "test_cross_C"
        local modB = "test_cross_B"
        local modA = "test_cross_A"

        register_module(modA, [[
            return { }
        ]])
        require(modA)

        -- 模块 C：提供基础数据
        register_module(modC, [[
            return { value = 100 }
        ]])
        -- 模块 B：引用 C，并导出 b_ref = C（沙箱中为 dummy）
        register_module(modB, [[
            local C = require("]] .. modC .. [[")
            return { b_ref = C }  -- 路径 "[test_cross_C]"
        ]])
        -- 模块 A：引用 B，并访问 B.b_ref（沙箱中为 "[test_cross_B].b_ref"）
        register_module(modA, [[
            local B = require("]] .. modB .. [[")
            return { a_ref = B.b_ref }
        ]])

        -- 同时热更 A 和 B，注意：由于 pairs 遍历 all 表的顺序不确定，
        -- 有可能 A 的 globals 在 B 之前处理，此时 B 的旧表中 b_ref 仍为 dummy，
        -- 从而在解析 "[test_cross_B].b_ref" 时触碰到 "MODULE" 元表，引发 error。
        -- 若未触发，则说明本次运行顺序恰好先处理了 B，测试通过但未覆盖错误分支。
        do_reload({ modA, modB }) -- modB之前没有require过，这里作为参数不合适，这里仅仅为了验证模块的兼容性
        if not dry_run then
            local A = debug.getregistry()._LOADED[modA]
            assert_equals(A.a_ref.value, 100, "热更后取值")
            local C = debug.getregistry()._LOADED[modC]
            assert_equals(C.value, 100, "热更模块内部包含require新模块也应能正确完整加载；同时验证了【_LOADED[name] = mod】修改的效果")
        end
    end)

    run_test("14. 动态函数更新（运行时赋值的函数）", function()
        local mod_name = "test_dynamic"
        register_module(mod_name, [[
            local dynamic_func = nil
            local function setter(f) dynamic_func = f end
            local function caller(x)
                if dynamic_func then dynamic_func(x) end
            end
            -- 初始化动态函数
            local function old_impl(x) print("old", x) end
            setter(old_impl)
            return { caller = caller, setter = setter }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        local out1 = capture_print(function() m.caller(123) end)
        assert_find(out1, "old", "初始调用输出 old")

        -- 更新模块：定义新的动态函数，但旧 upvalue 应被替换
        register_module(mod_name, [[
            local dynamic_func = nil
            local function setter(f) dynamic_func = f end
            local function caller(x)
                if dynamic_func then dynamic_func(x) end
            end
            -- 新实现
            local function new_impl(x) print("new", x) end
            setter(new_impl)   -- 这行在热更时不会执行，但 upvalue 映射会处理
            return { caller = caller, setter = setter }
        ]])
        do_reload(mod_name)
        local out2 = capture_print(function() m.caller(123) end)
        assert_find(out2, "new", "热更后应调用新动态函数")
    end)

    run_test("15. 主代码引用到模块子字段不存在 —— 访问外部模块中不存在的字段 'invalid module reference'", function()
        local dep_name = "test_exist_module"
        local main_name = "test_missing_field"

        -- 依赖模块只提供字段 x，没有 y
        register_module(dep_name, [[
            return { x = 1 }
        ]])
        clear_module(dep_name)
        require(dep_name)

        -- 主模块引用 dep.y（不存在）
        register_module(main_name, [[
            local dep = require("]] .. dep_name .. [[")
            return { val = dep.y }   -- dep.y 产生 dummy 路径 "[test_exist_module].y"
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- print("m.val", m.val) -- 原始实现仅仅这里返回nil，并不报错

        local ok, err = pcall(reload.reload, { main_name })
        -- print_(ok, err)
        if reload.enable_invalid_reference_error then
            assert_false(ok, "应检测到无效模块子字段")
            assert_find(tostring(err), "invalid module reference", "错误信息应包含 'invalid module reference'")
        else
            assert_true(ok, "检测到无效模块子字段时直接附值为nil不报错")
        end
    end)

    run_test("16: 验证函数 upvalue 为函数时可被全局替换（match_upvalues 递归假设）", function()
        local mod_name = "test_func_upvalue"
        -- 旧模块：inner 返回 1，outer 调用 inner
        register_module(mod_name, [[
            local inner = function() return 1 end
            local inner2 = function() return inner() end
            local outer = function()
                return inner2()
            end
            return { outer = outer }
        ]])
        clear_module(mod_name)
        local old = require(mod_name)
        assert_equals(old.outer(), 1, "旧模块应返回 1")

        -- 热更新：inner 改为返回 2，outer 不变
        register_module(mod_name, [[
            local inner = function() return 2 end
            local inner2 = function() return inner() end
            local outer = function()
                return inner2()
            end
            return { outer = outer }
        ]])
        do_reload({ mod_name })
        -- 原模块引用应已指向新 outer，且 outer 调用新 inner
        assert_equals(old.outer(), 2, "应调用新的 inner 返回 2")
    end)

    run_test("17. 验证setupvalue方案没问题：场景1，某个表类型upvalue值，旧值为nil，新值非nil，且此表被多个函数共享为upvalue值，热更后看是否完全同步一至", function()
        local mod_name = "test_mod_setupvalue"
        register_module(mod_name, [[
            local t = {key = 1}
            local M = {
            }
            function M.fun( ... )
                print(t)
                return 1
            end
            function M.get()
                return t
            end
            function M.set(_t)
                t = _t
            end
            return M
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        m.set(nil)
        assert_equals(m.get(), nil, "旧版模块返回值")
        register_module(mod_name, [[
            local t = {key = 2}
            local M = {
            }
            function M.fun( ... )
                return tostring(t)
            end
            function M.get()
                return t
            end
            function M.set(_t)
                -- print(t)
                t = _t
                return t
            end
            return M
        ]])
        do_reload({mod_name})
        if not dry_run then
            assert_equals(m.get().key, 2, "新表会直接替换原值为nil的upvalue")
            local t = {key = 3}
            m.set(t)
            -- print(m.set(t))
            -- print(m.get(), m.fun())
            assert_equals(m.get().key, 3, "即使旧值为nil的upvalue，热更后仍能保持正常的同步共享")
            assert_equals(m.fun(), tostring(t), "即使旧值为nil的upvalue，热更后仍能保持正常的同步共享")
        end
    end)

    run_test("18. 验证新增基本字段不应丢失", function()
        local main_name = "test_add_base_field"
        register_module(main_name, [[
            local M = {
                a = 1,
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- env_dependent.print(m)

        register_module(main_name, string_format([[
            local M = {
                a = 1,
                b = 2,
            }
            function M.fun()
                return M.b
            end
            return M
        ]]))

        do_reload(main_name)
        if not dry_run then
            assert_equals(m.b, 2, "期望热更后b未丢失")
            assert_equals(m.fun(), 2, "期望热更后能访问到新增字段b")
        end
    end)

    run_test("19. 验证新增函数不应丢失", function()
        local main_name = "test_add_fun"
        register_module(main_name, [[
            local M = {
                a = 1,
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- env_dependent.print(m)

        register_module(main_name, string_format([[
            local M = {
                a = 1,
                b = print
            }
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        assert_equals(m.b, print, "期望热更后b未丢失")
    end)

    run_test("20. 验证新函数应能完全替换旧函数不应丢失", function()
        local main_name = "test_update_new_fun"
        register_module(main_name, [[
            local M = {
                a = function(...)
                    return 1, ...
                end
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- env_dependent.print(m)

        register_module(main_name, string_format([[
            local M = {
                a = function(...)
                    return 2, ...
                end
            }
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        assert_equals(m.a(), 2, "期望热更后a为新函数")
    end)

    run_test("21. 验证新值为外部依赖变量的附值能成功", function()
        local main_name = "test_set_as_external_dependent_variables"
        register_module(main_name, [[
            local M = {
                a = next,
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        assert_equals(next, m.a, "正常首次加载")
        register_module(main_name, string_format([[
            local M = {
                a = require("nnskynet").print
            }
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        assert_true("function" == type(m.a), "附值应成功")
        assert_equals(m.a, require("nnskynet").print, "期望热更后a保持原值")
    end)

    if reload.set_options then
        local tmp = clone_options()
        run_test("22. 本模块支持动态配置，即在无须重启的情况下，支持预演和实施及不同热更策略配置混用模式", function()
            local main_name = "test_set_options"
            register_module(main_name, [[
                test_gloable_var_set = 1
                return { val = 1 }
            ]])
            clear_module(main_name)
            local m = require(main_name)

            tmp.ignore_external_dependent_variables_change = true
            tmp.enable_external_dependent_variables_change_fun = true
            reload.set_options(tmp)
            local ok, err = reload.reload({ main_name })
            assert_true(ok, "这里ok")
            tmp.ignore_external_dependent_variables_change = false
            tmp.enable_external_dependent_variables_change_fun = false
            reload.set_options(tmp)
            local ok2, err2 = reload.reload({ main_name })
            assert_false(ok2, "这里报错")
        end)
        reload.set_options(options)
    end
end

if run_craft_supported_case then
    print("-----------------测试号[41, 60]的用例表示需要特殊技巧配合才能支持的场景----------------------")
    -- run_test("41. 技巧反例：不支持注册的匿名函数热更", function()
    --     local main_name = "test_registr_noname_fun"
    --     register_module(main_name, [[
    --         local M = {funcs = {}}
    --         function M.reg()
    --             table.insert(M.funcs, function()
    --                 M.data = 1
    --             end)
    --         end
    --         function M.call()
    --             for i,fun in ipairs(M.funcs) do
    --                 fun()
    --             end
    --         end
    --         return M
    --     ]])
    --     clear_module(main_name)
    --     local m = require(main_name)
    --     m.reg()
    --     m.call()
    --     assert_equals(m.data, 1, "热更前应为1")
    --     register_module(main_name, [[
    --         local M = {funcs = {}}
    --         function M.reg()
    --             table.insert(M.funcs, function()
    --                 M.data = 2
    --             end)
    --         end
    --         function M.call()
    --             for i,fun in ipairs(M.funcs) do
    --                 fun()
    --             end
    --         end
    --         return M
    --     ]])
    --     do_reload(main_name)
    --     m.call()
    --     assert_equals(m.data, 2, "热更后期望为2")
    -- end)

    run_test("42. 技巧：可通过将注册函数定义为具名且成为函数upvalue值来达到观察者模式中注册函数热更的目标(用例41为反例)", function()
        local main_name = "test_registr_fun"
        register_module(main_name, [[
            local M = {funcs = {}}
            local function fun()
                M.data = 1
            end
            function M.reg()
                table.insert(M.funcs, fun)
            end
            function M.call()
                for i,fun in ipairs(M.funcs) do
                    fun()
                end
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        m.reg()
        m.call()
        assert_equals(m.data, 1, "热更前应为1")
        register_module(main_name, [[
            local M = {funcs = {}}
            local function fun()
                M.data = 2
            end
            function M.reg()
                table.insert(M.funcs, fun)
            end
            function M.call()
                for i,fun in ipairs(M.funcs) do
                    fun()
                end
            end
            return M
        ]])
        do_reload(main_name)
        m.call()
        assert_equals(m.data, 2, "热更后期望为2")
    end)

    -- run_test("43. 技巧反例：不支持持续运行的协程主函数热更", function()
    --     local ggame_api = require("nnskynet")
    --     local main_name = "test_coroutine_main_fun"
    --     register_module(main_name, [[
    --         local ggame_api = require("nnskynet")
    --         local M = {data = 1}

    --         function M.run( ... )
    --             ggame_api.service.fork(function()
    --                 while true do
    --                     M.data = 1
    --                     ggame_api.utils.sleep_millisecond(5000)
    --                 end
    --             end)
    --         end
    --         return M
    --     ]])
    --     clear_module(main_name)
    --     local m = require(main_name)
    --     m.run()
    --     ggame_api.run(3)
    --     register_module(main_name, [[
    --         local ggame_api = require("nnskynet")
    --         local M = {data = 1}

    --         function M.run( ... )
    --             ggame_api.service.fork(function()
    --                 while true do
    --                     M.data = 2 -- 这里无法更新到
    --                     ggame_api.utils.sleep_millisecond(5000)
    --                 end
    --             end)
    --         end
    --         return M
    --     ]])
    --     do_reload(main_name)
    --     ggame_api.run(3)
    --     assert_equals(m.data, 2, "期望能被更新")
    -- end)

    run_test("44. 技巧：通过将主协程函数变化代码抽取成独立函数调用的机制来适配支持热更(用例43为反例)", function()
        local ggame_api = require("nnskynet")
        local main_name = "test_coroutine_main_fun_adaptation"
        register_module(main_name, [[
            local ggame_api = require("nnskynet")
            local M = {data = 1}
            local function fun() -- 将协程可变部分独立抽取成子函数以实现热更
                M.data = 1
                ggame_api.utils.sleep_millisecond(5000)
            end

            function M.run( ... )
                ggame_api.service.fork(function()
                    while true do -- 协程主函数只保留最小稳定逻辑代码
                        fun()
                    end
                end)
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        m.run()
        ggame_api.run(3)
        register_module(main_name, [[
            local ggame_api = require("nnskynet")
            local M = {data = 1}
            local function fun()
                M.data = 2
                ggame_api.utils.sleep_millisecond(5000)
            end

            function M.run( ... )
                ggame_api.service.fork(function()
                    while true do
                        fun()
                    end
                end)
            end
            return M
        ]])
        do_reload(main_name)
        ggame_api.run(3)
        assert_equals(m.data, 2, "期望能被更新")
    end)
end

if run_compatibility_supported_case then
    print("-----------------测试号[61, 100]的用例表示兼容但不推荐的场景----------------------")
    run_test("61. 兼容但不推荐全局变量附值", function()
        local main_name = "test_gloable_var_set"
        register_module(main_name, [[
            test_gloable_var_set = 1
            return { val = 1 }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        do_reload({ main_name })
    end)

    run_test("62. 兼容但不推荐外部依赖模块字段附值", function()
        local main_name = "test_module_var_set"
        register_module(main_name, [[
            require("nnskynet").test = 1
            return { val = 1 }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        do_reload({ main_name })
    end)

    run_test("63. 兼容但不推荐在热加载主代码中对全局变量及其子字段进行for pairs遍历", function()
        local main_name = "test_dummy_gloable_var_for_paris"
        register_module(main_name, [[
            for k,v in pairs(test_dummy_gloable_var_for_paris or {}) do
                print(k,v)
            end
            return { val = 1 }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        do_reload(main_name)
        clear_module(main_name)
    end)

    run_test("64. 兼容但不推荐在热加载主代码中对外部模块及其子字段进行for pairs遍历", function()
        local main_name = "test_dummy_module_for_paris"
        register_module(main_name, [[
            for k,v in pairs(require("nnskynet") or {}) do
                -- print(k,v)
            end
            return { val = 1 }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        do_reload(main_name)
    end)
    
    run_test("65. 兼容但不推荐在热加载主代码中包含对【外部依赖变量】的运算：包括算术运算、字符串拼接等各类运算操作", function()
        local dep_name = "mod_dep"   -- 模块名包含连字符
        local main_name = "test_external_dependent_variables_operation"

        -- 先加载特殊名称的依赖模块
        register_module(dep_name, [[
            return { data = "hello" }
        ]])
        require(dep_name)  -- 确保在 _LOADED 中

        -- 主模块依赖该模块
        register_module(main_name, [[
            local dep = require("mod_dep")
            return { result = dep.data }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        -- 热更主模块
        register_module(main_name, [[
            local dep = require("mod_dep")
            local result = dep.data .. " world"
            return { result = result }
        ]])
        -- register_module(main_name, [[
        --     return { result = test_external_dependent_variables_operation + 1 }
        -- ]])

        do_reload({ main_name })
        assert_equals(m.result, "hello", "直接忽略运算结果按nil计算，这样将保持原值")
    end)


    run_test("66. 兼容但不推荐主热更代码中外部依赖函数调用，相当于skynet主服务模块(包含skynet.start)是无法热更的", function()
        local main_name = "test_external_dependent_fun_call"
        register_module("skynet", [[
            local M = {
                start = function() end,
            }
            return M
        ]])
        register_module(main_name, [[
            local skynet = require("skynet")
            local M = {
                a = 1,
            }
            skynet.start()
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        register_module(main_name, string_format([[
            local skynet = require("skynet")
            local M = {
                a = 2,
            }
            skynet.start()
            return M
        ]], main_name, main_name))
        do_reload({ main_name })
    end)

    run_test("67. 兼容但不推荐全局/外部依赖函数更新(项目中不规范代码风格)", function()
        local main_name = "test_real_project"
        register_module(main_name, string_format([[
            _G.gdata = {dispatch = {}}
            local gdata = gdata
            local M = {
                a = 1,
            }
            require("nnskynet")["%s"] = 1
            function gdata.dispatch.req_login(...)
                return M.a + 1
            end
            require("nnskynet")["%s_fun"] = gdata.dispatch.req_login
            return M
        ]], main_name, main_name))
        clear_module(main_name)
        local m = require(main_name)
        -- nnskynet.print(m)
        register_module(main_name, string_format([[
            _G.gdata = {dispatch = {}}
            local gdata = gdata
            local M = {
                a = 2,
            }
            require("nnskynet")["%s"] = 2
            function gdata.dispatch.req_login(...)
                return M.a + 2
            end
            require("nnskynet")["%s_fun"] = gdata.dispatch.req_login
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        assert_equals(nnskynet[main_name .. ""], 1, "状态保持原值")
        assert_equals(gdata.dispatch.req_login(), 3, "全局函数被更新")
        assert_equals(nnskynet[main_name .. "_fun"](), 3, "外部模块函数被更新")
    end)
    _G.gdata = nil

    run_test("68. 兼容但不推荐全局/外部依赖函数更新而状态保持(项目中不规范代码风格)", function()
        local main_name = "test_real_project_upvalue"
        register_module(main_name, string_format([[
            _G.gdata = {dispatch = {}}
            local gdata = gdata
            local M = {
            }
            local a = 1
            function gdata.dispatch.req_login(...)
                a = a + 1
                return a
            end
            return M
        ]], main_name, main_name))
        clear_module(main_name)
        local m = require(main_name)
        assert_equals(gdata.dispatch.req_login(), 2, "热更前正常")
        register_module(main_name, string_format([[
            _G.gdata = {dispatch = {}}
            local gdata = gdata
            local M = {
            }
            local a = 1
            function gdata.dispatch.req_login(...)
                a = a + 2
                return a
            end
            return M
        ]], main_name, main_name))
        do_reload({ main_name })
        assert_equals(gdata.dispatch.req_login(), 4, "全局函数被更新，状态保持")
    end)
    _G.gdata = nil
end

if run_not_supported_case then
    print("------------以下测试号大于100的用例表示目前仍不支持的热更场景--------------------")
    run_test("101. 不支持模块名包含特殊字符(比如连字符)", function()
        local dep_name = "mod-name"   -- 包含连字符，不符合 [_%w.]+ 模式
        local main_name = "test_bad_module_format"

        -- 注册一个名称含特殊字符的依赖模块
        register_module(dep_name, [[
            return { data = 42 }
        ]])
        clear_module(dep_name)
        local dep = require(dep_name)   -- 确保真实环境中已加载
        -- print(dep.data) -- 特殊名字模块在普通require时工作正常，但不支持热更模块

        -- 主模块引用该依赖模块
        register_module(main_name, [[
            local dep = require("]] .. dep_name .. [[")
            return { ref = dep }   -- 沙箱中 dep 是模块 dummy，路径为 "[mod-name]"
        ]])
        clear_module(main_name)
        require(main_name)

        do_reload({ main_name })
        clear_module(main_name) -- 不清理的话，可能影响到后续测试
    end)

    run_test("102. 不支持匿名函数更新", function()
        local mod_name = "test_named_anon"
        -- 原始模块：只在第一次调用 ensure 时赋值，后续不再改变
        register_module(mod_name, [[
            local initialized = false
            local funcs = {}
            local function named() return "named_old" end
            
            local function ensure()
                if not initialized then
                    funcs.named = named
                    funcs.anon = function() return "anon_old" end
                    initialized = true
                end
            end
            
            local function get_named() return funcs.named() end
            local function get_anon() return funcs.anon() end
            
            return { ensure = ensure, get_named = get_named, get_anon = get_anon }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        m.ensure()  -- 第一次调用，赋值旧版函数
        
        -- 更新模块：修改命名函数和匿名函数的定义，但 ensure 中的条件不再满足（因为 initialized 已为 true）
        register_module(mod_name, [[
            local initialized = false
            local funcs = {}
            local function named() return "named_new" end
            
            local function ensure()
                if not initialized then
                    print("热更时这里并不会执行：new initialized")
                    funcs.named = named -- 这个附值是通过upvalue映射更新的，因为新旧两个ensure函数有这个同名函数为upvalue值，如果不同名，则也不会更新
                    funcs.anon = function() return "anon_new" end
                    initialized = true
                end
            end
            
            local function get_named() return funcs.named() end
            local function get_anon() return funcs.anon() end
            
            return { ensure2 = ensure, ensure = ensure, get_named = get_named, get_anon = get_anon }
        ]])
        do_reload(mod_name)
        
        -- 热更后，funcs 表是旧对象，其字段值应该被更新：
        --   - funcs.named 是命名函数，会被 upvalue 映射更新为 named_new
        --   - funcs.anon 是匿名函数（无变量名绑定），不会被更新，仍是 anon_old
        m.ensure()
        -- print("m.get_named(), m.get_anon()", m.get_named(), m.get_anon())
        assert_equals(m.get_named(), "named_new", "命名函数应更新")
        assert_equals(m.get_anon(), "anon_new", "匿名函数未能更新")
    end)

    run_test("103. 不支持以对象(函数,协程、表)作为表的key类型(accept_key_type【number|string|boolean】的热加载", function()
        local main_name = "test_table_key_name"
        register_module(main_name, [[
            local t = {}
            return { [t] = 1 }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        do_reload(main_name)
    end)

    run_test("104. 不支持新旧模块同名路径中间节点类型(必须同为表或函数)不匹配，会导致无法定位(通过表字段和函数upvalue)原变量：此时应该报错还是静默跳过此相关热更处理好？", function()
        local main_name = "test_find_path_mismatch"
        -- 旧模块：M.x 是数字
        register_module(main_name, [[
            local M = { x = 10 }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)

        -- 热更，新模块：M.x 变成表，且包含字段 y
        register_module(main_name, [[
            local M = { x = { y = 1 } }
            return M
        ]])

        do_reload(main_name)
    end)

    run_test("105. 不支持新旧模块同名变量类型不匹配（函数 vs 表）：此时应该报错还是静默跳过此相关热更处理好？", function()
        local main_name = "test_type_mismatch"
        register_module(main_name, [[
            local M = { func = function() end }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)

        register_module(main_name, [[
            local M = { func = {} }  -- 原来是函数，现在变成了表
            return M
        ]])

        do_reload(main_name)
    end)

    run_test("110. 不支持基本类型(非表、函数)变量的一至性检测：新模块共享同一个基本类型变量，但旧模块中它们是两个不同基本类型变量，需要应用层自己规避这类写法或热加载后自行检测", function()
        local main_name = "test_ambiguity_base_type"
        register_module(main_name, [[
            local M = {
                a = nil,      -- 路径 M.a 为 nil
                b = 1 -- 路径 M.b 是一个值
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- nnskynet.print(m)

        register_module(main_name, [[
            local shared = 2
            local M = {
                a = shared,   -- 路径 M.a 指向 shared
                b = shared    -- 路径 M.b 也指向 shared，因原值非nil且新值不是表或函数，所以并不会放入map中进行热更，导致map中只会出现一次shared访问路径
            }
            return M
        ]])

        do_reload(main_name)
        assert_equals(m.a, m.b, "期望热更后保持a,b相等")
    end)

    run_test("111. 不支持多个同名变量upvalue歧义)", function()
        local main_name = "test_ambiguity_upvalue"
        -- 旧模块：有两个函数 f1, f2，它们的 upvalue "u" 指向不同的函数
        register_module(main_name, [[
            local upvalue = 1
            local function f1()
                return upvalue
            end
            local upvalue = 2 -- 这里重定义了一个同名upvalue值(属于不规范代码)
            local function f2()
                return upvalue
            end
            return { f1 = f1, f2 = f2 }
        ]])
        clear_module(main_name)
        local m = require(main_name)

        register_module(main_name, [[
            local upvalue = 3
            local function f1()
                return upvalue
            end
            local function f2()
                return upvalue
            end
            return { f1 = f1, f2 = f2 }
        ]])
        do_reload(main_name)
    end)

    run_test("113. 不支持新模块共享同一个表或函数而旧模块中它们是两个不同表或函数(包括nil)但同类型变量，热更后会导致新值不一至，但能检测出异常", function()
        local main_name = "test_ambiguity_table"
        register_module(main_name, [[
            local M = {
                a = nil,
                b = {}
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- nnskynet.print(m)

        register_module(main_name, [[
            local shared = {val = 1}
            local M = {
                a = shared,
                b = shared,
            }
            return M
        ]])

        do_reload({ main_name })
        assert_equals(m.a, m.b, "期望热更后a,b相等")
    end)
end


if run_ambiguity_case then
    print("-----------------测试号[201, 300]的用例表示目前存在歧义的热更场景(需要注意细节点)----------------------")

    run_test("201. 歧义：新旧值类型不同(均非nil值)且新值为外部依赖变量的附值策略：静默替换", function()
        local main_name = "test_set_as_external_dependent_variables_no_same_type"
        register_module(main_name, [[
            local M = {
                a = 1,
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        -- nnskynet.print(m)
        register_module(main_name, string_format([[
            local M = {
                a = require("nnskynet").print
            }
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        assert_equals(m.a, 1, "应用可能期望热更后a保持原值")
        assert_equals(m.a, require("nnskynet").print, "应用可能期望热更后替换为新值")
    end)

    run_test("202. 歧义：当新值为外部依赖变量且类型为普通类型时的附值策略：也会替换", function()
        local main_name = "test_set_as_external_dependent_variables_same_type"
        register_module(main_name, [[
            local M = {
                a = require("nnskynet").a,
            }
            return M
        ]])
        clear_module(main_name)
        nnskynet.a = 1
        local m = require(main_name)
        -- nnskynet.print(m)
        nnskynet.a = 2
        register_module(main_name, string_format([[
            local M = {
                a = require("nnskynet").a
            }
            return M
        ]], main_name, main_name))

        do_reload({ main_name })
        nnskynet.a = nil
        assert_equals(m.a, 1, "应用可能期望热更后a为旧值")
        assert_equals(m.a, 2, "应用可能期望热更后a为新值")
    end)

    run_test("203. 歧义：主模块状态值在主代码中被更新为【外部依赖变量】时，是保持旧值还是更新为【外部依赖变量】解析值？", function()
        local mod_name = "test_ambiguity_external_dependent_variables"
        -- 原始模块
        register_module(mod_name, [[
            gloable_var = 2
            return { use = function() return not_exist_var end, var = 1 }
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        assert_equals(m.var, 1, "热更前取值")
        -- 更新模块
        register_module(mod_name, [[
            -- print("gloable_var", gloable_var)
            return { use = function() return not_exist_var end, var = gloable_var }
        ]])
        do_reload({ mod_name })
        assert_equals(m.var, 1, "应用可能期望热更后取原值")
        assert_equals(m.var, 2, "应用可能期望热更后取新值")
    end)

    run_test("204. 歧义：主模块中包含动态函数附值时，是否应该热更该动态函数？考虑两种场景：1、动态函数旧版本在运行过程中未被修改过且仍为之前初值，新版本初值有修改，此时应该更新；2、动态函数旧版本在运行过程中被修改过，而新版本初始又分有更新(无认保持旧值还是更新为新值都可能产生问题)和无更新(保持旧值合理)两种情况；", function()
        local mod_name = "test_dynamic_function"
        register_module(mod_name, [[
            local M = {}
            function M.f()
                return 1
            end
            function M.change_f(new_f)
                M.f = new_f
            end
            return M
        ]])
        clear_module(mod_name)
        local m = require(mod_name)
        m.change_f(function()
            return 3
        end)
        register_module(mod_name, [[
            local M = {}
            function M.f()
                return 2
            end
            function M.change_f(new_f)
                M.f = new_f
            end
            return M
        ]])
        do_reload({ mod_name })
        -- print(m.f())
        assert_equals(m.f(), 3, "应用可能期望热更后保持旧值")
        assert_equals(m.f(), 2, "应用可能期望热更后保持新值")
    end)

    run_test("205. 歧义：函数数组会热更", function()
        local main_name = "test_fun_array_error"
        register_module(main_name, [[
            local M = {
                [1] = function() return 1 end,
                [2] = function() return 2 end,
            }
            function M.call( ... )
                return M[1]()
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        register_module(main_name, [[
            local M = {
                [2] = function() return 1 end,
                [1] = function() return 2 end,
            }
            function M.call( ... )
                return M[1]()
            end
            return M
        ]])
        do_reload(main_name)
        assert_equals(m.call(), 1, "到底是要更新还是不要更新其实是有歧义的")
        assert_equals(m.call(), 2, "到底是要更新还是不要更新其实是有歧义的")
    end)
end

if run_bug_case then
    print("------------坑：测试号[301, 400]的用例表示需要特别规避的不支持的热更场景--------------------")
    run_test("301. 不支持包含有初始函数的动态函数热更", function()
        local main_name = "test_has_init_value_dynamic_fun"
        register_module(main_name, [[
            ---@class gtimeout
            local M = {timeout_id = {}, num = 0, warn = function( ... ) end} -- num代表调用本接口创建并仍未真正回收(但可能已经canel过非应用层活跃)的skynet底层task数量，timeout_id内仅包含待执行的活跃task
            ---@alias gtimeout_id integer

            function M.set_warn(fun_warn)
                M.warn = fun_warn or function( ... ) end
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        m.set_warn(function() return 1 end)
        -- nnskynet.print(m)
        assert_equals(m.warn(), 1, "动态函数有效")
        register_module(main_name, string_format([[
            ---@class gtimeout
            local M = {timeout_id = {}, num = 0, warn = function( ... ) end} -- num代表调用本接口创建并仍未真正回收(但可能已经canel过非应用层活跃)的skynet底层task数量，timeout_id内仅包含待执行的活跃task
            ---@alias gtimeout_id integer

            function M.set_warn(fun_warn)
                M.warn = fun_warn or function( ... ) end
            end
            return M
        ]], main_name, main_name))
        do_reload({ main_name })
        -- nnskynet.print(m.warn() or nil)
        assert_equals(m.warn(), 1, "期望热更后保持原始函数，但反而被替换为了初始函数")
    end)

    run_test("302. 不支持包含有初始状态的动态状态存在置空状态的热更", function()
        local main_name = "test_table_update"
        register_module(main_name, [[
            local M = {
                a = 1,
            }
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        assert_equals(m.a, 1, "原始初值ok")
        m.a = nil
        -- nnskynet.print(m)
        register_module(main_name, string_format([[
            local M = {
                a = 1
            }
            return M
        ]], main_name, main_name))
        do_reload(main_name)
        -- nnskynet.print(m)
        assert_equals(m.a, nil, "状态应保留为nil")
    end)

    run_test("303. 不支持：持续运行的协程代码若在热更后再次创建将产生两份不同代码混杂运行，造成数据和逻辑不稳定和不一至", function()
        local ggame_api = require("nnskynet")
        local main_name = "test_old_new_code_coexist"
        register_module(main_name, [[
            local ggame_api = require("nnskynet")
            local M = {data = 2, data1 = "test_noname_reload2", data2 = "test_has_name_reload2"}

            local function log( ... )
                ggame_api.log.dlog(M.data, ...)
            end

            function M.test_reload( ... )
                M.data = 2
                ggame_api.service.dispatch_lua_msg() -- for test
                local i = 0
                ggame_api.service.fork_by_name("test_reload_noname_thread", function()
                    while true do
                        i = i + 1
                        M.data1 = "test_noname_reload2"
                        -- log(M.data1, i)
                        ggame_api.utils.sleep_millisecond(5000)
                    end
                end)
                local j = 0
                local function test_reload_has_name_thread( ... )
                    while true do
                        j = j + 1
                        M.data2 = "test_has_name_reload2"
                        -- log(M.data2, j)
                        ggame_api.utils.sleep_millisecond(5000)
                    end
                end
                ggame_api.service.fork_by_name("test_reload_has_name_thread", test_reload_has_name_thread)
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        m.test_reload()
        ggame_api.run(3)
        register_module(main_name, [[
            local ggame_api = require("nnskynet")
            local M = {data = 3, data1 = "test_noname_reload3", data2 = "test_has_name_reload3"}

            local function log( ... )
                ggame_api.log.dlog(M.data, ...)
            end

            function M.test_reload( ... )
                M.data = 3
                ggame_api.service.dispatch_lua_msg() -- for test
                local i = 0
                ggame_api.service.fork_by_name("test_reload_noname_thread", function()
                    while true do
                        i = i + 1
                        M.data1 = "test_noname_reload3"
                        -- log(M.data1, i)
                        ggame_api.utils.sleep_millisecond(5000)
                    end
                end)
                local j = 0
                local function test_reload_has_name_thread( ... )
                    while true do
                        j = j + 1
                        M.data2 = "test_has_name_reload3"
                        -- log(M.data2, j)
                        ggame_api.utils.sleep_millisecond(5000)
                    end
                end
                ggame_api.service.fork_by_name("test_reload_has_name_thread", test_reload_has_name_thread)
            end
            return M
        ]])
        do_reload(main_name)
        -- print("热更后：------------------------------------------------------")
        m.test_reload() -- 产生新的协程和新的代码
        -- print("m.data, m.data1, m.data2", m.data, m.data1, m.data2)
        ggame_api.run(1) -- 结果具有随机性，测试发现当设置为2,6,10,14,...时能成功
        assert_equals(m.data1, "test_noname_reload3", "两份不同代码同时产生不同值，造成数据不一至和不稳定")
        assert_equals(m.data2, "test_has_name_reload3", "两份不同代码同时产生不同值，造成数据不一至和不稳定")
    end)

    run_test("304. 不支持：函数更新而状态保留时有个坑：旧状态不配合新函数时将产生不可预料的结果", function()
        local main_name = "test_old_state_and_new_fun"
        register_module(main_name, [[
            local M = {funcs = {}}
            function M.fun(param)
                M.data = param .. 1
            end
            function M.reg(fun, param)
                table.insert(M.funcs, {fun = fun, param = param})
            end
            function M.call()
                for i,v in ipairs(M.funcs) do
                    v.fun(v.param)
                end
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        m.reg(m.fun, "param")
        m.call()
        assert_equals(m.data, "param1", "热更前应为1")
        register_module(main_name, [[
            local M = {funcs = {}}
            function M.fun(param)
                M.data = param + 1
            end
            function M.reg(fun, param)
                table.insert(M.funcs, {fun = fun, param = param})
            end
            function M.call()
                for i,v in ipairs(M.funcs) do
                    v.fun(v.param)
                end
            end
            return M
        ]])
        do_reload(main_name)
        m.call() -- 将报错
        -- assert_equals(m.data, 2, "热更后期望为2")
    end)
end


if run_try_case then
    print("-----------------以下为新实验用例，结果不确定----------------------")

    run_test("new. 表字段名包含【.】时热更情况", function()
        local main_name = "test_table_filed_name_with_dot"
        register_module(main_name, [[
            local M = {a = {}}
            function M.fun(param)
                return M["a.b"]
            end
            function M.a.b()
                return 1
            end
            return M
        ]])
        clear_module(main_name)
        local m = require(main_name)
        assert_equals(m.fun(), nil, "热更前应为nil")
        assert_equals(m.a.b(), 1, "热更前应为1")
        register_module(main_name, [[
            local M = {
                a = {},
                ["a.b"] = 1
            }
            function M.fun(param)
                return M["a.b"]
            end
            function M.a.b()
                return 2
            end
            return M
        ]])
        do_reload(main_name)
        assert_equals(m.fun(), 1, "热更后期望为1")
        assert_equals(m.a.b(), 2, "热更后期望为2")
    end)
end

print_test_report()
