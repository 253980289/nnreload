if false then
    -- 测试包含点的子模块
    local reload = require("nnreload")
    local _LOADED = debug.getregistry()._LOADED
    -- 1. 子模块（名称含点，返回数字）
    package.preload["sub.mod"] = function()
        return 99
    end

    -- 2. 旧版本主模块：捕获变量名为 `s`
    package.preload["main"] = function()
        local s = require("sub.mod")
        return {
            get = function() return s end
        }
    end

    -- 3. 首次加载（普通环境）
    require("sub.mod")
    require("main")
    local old_main = package.loaded["main"]
    print("Old get:", old_main.get())   --> 99

    -- 4. 修改主模块为新版本：捕获变量名改为 `sub`
    package.preload["main"] = function()
        local sub = require("sub.mod")
        return {
            get = function() return sub end
        }
    end

    -- 5. 清空子模块的记录，使重载时沙箱再次加载它
    _LOADED["sub.mod"] = nil

    -- 6. 重载主模块
    local ok, err = reload.reload({"main"})
    print("Reload ok:", ok)

    if ok then
        local new_main = _LOADED["main"]
        local result = new_main.get()
        if type(result) == "number" then
            print("New get:", result)          -- 正常应得到 99
        else
            -- bug 存在时，result 将是 dummy 对象（table），不会得到数字
            print("BUG: expected number, got", type(result))
            -- 可选：检查元表进一步确认
            if getmetatable(result) ~= nil then
                print("  (dummy metatable detected)")
            end
        end
    else
        print("Reload failed:", err)
    end
    print(_LOADED["sub.mod"])
    os.exit(0)
end



local reload = require "reload"
reload.postfix = "_update"	-- for test
reload.print = print

print(debug.getinfo)
local mymod = require "mymod"

mymod.foobar(42)

local tmp = {}
local foo = mymod.foo2()
tmp[foo] = foo
print("FOO before", foo)
foo()
local obj = mymod.new()

obj:show()

local co
function test()
	co = mymod.start()
	print("BEFORE update foo", foo)
	reload.reload({ "mymod" })
	print("AFTER update foo", foo)
end

test()
foo()

print("FOO after", foo)
assert(tmp[foo] == foo)

obj:show()
-- print(mymod.a_b, mymod.getinfo)
-- mymod.foo4()
-- coroutine.resume(co)
-- print(pcall(mymod.new_runtime_error_fun))
