--[[
create by lj 2026-6-3
模块名
    nnluavm
功能
    对lua虚拟机相关操作集，目前主要考虑用于调试，尤其针对nnreload模块
]]

local getmetatable = debug.getmetatable
local getinfo = debug.getinfo
local getlocal = debug.getlocal
local setlocal = debug.setlocal
local getupvalue = debug.getupvalue
local setupvalue = debug.setupvalue
local getuservalue = debug.getuservalue
local setuservalue = debug.setuservalue
local type = type
local next = next
local rawset = rawset
local print = print

local M = {
}

-- 遍历整个lua虚拟机的所有变量：包括普通变量、表的键和值及字表递归、upvalue、局部变量、用户数据、元表、协程各栈帧等
-- 目前主要支持显示，后续可考虑扩展为支持通过其父变量的各类修改操作
---@param callback ?fun(var: any, ...)
---@return integer
function M.foreach(callback, options)
	callback = callback or function(var, _options)
		print(var, "path:", _options and _options.path and table.concat(_options.path, "->"))
	end
	local exclude = { [M] = true }
	local count = 0
	exclude[exclude] = true
	local foreach_var
	local START_FUN_LEVEL = 1 -- 0级一般为【yield】层，是否应该跳过到下一级？ lua文档定义：第 0 级是当前函数（getinfo 本身）；第 1 级是调用 getinfo 的函数（尾调用除外，尾调用不在堆栈中计算）；以此类推。如果 f 是一个大于活动函数数量的数字，则 getinfo 返回 fail。
	if options then -- options 可能包动态修改数据，避免不必要的无限递归
		exclude[options] = true
	end

	local function push_path(name)
		if options and options.path then
			options.path[#options.path + 1] = name
		end
	end
	local function pop_path()
		if options and options.path then
			options.path[#options.path] = nil
		end
	end

	-- 遍历协程的每一帧
	local function foreach_func_frame(co, level, frame_name)
		push_path(frame_name or level)
		local info = getinfo(co, level, "fn") -- n for name
		if info == nil then
			for i=START_FUN_LEVEL,level do -- 由于必须采用尾调用模式，这里需要一次pop所有栈的path
				pop_path()
			end
			return
		end
		local f = info.func
		foreach_var(f, info.name)
		local i = 1
		while true do
			local name, v = getlocal(co, level, i)
			if name == nil then
				if i > 0 then
					i = -1
				else
					break
				end
			end
			foreach_var(v, "local:" .. (name or i))
			if i > 0 then
				i = i + 1
			else
				i = i - 1
			end
		end
		return foreach_func_frame(co, level + 1) -- 这里只能使用尾调用，不然会死循环直接卡死
	end

	-- 遍历任意变量
	function foreach_var(var, name) -- local function
		if (nil == var) or exclude[var] then
			return
		end
		push_path(name)
		exclude[var] = true
		callback(var, options)
		count = count + 1
		local t = type(var)
		if t == "table" then
			local mt = getmetatable(var)
			if mt then
				foreach_var(mt, "metatable")
			end
			for k, v in next, var do -- 这里不直接写成：for k,v in pairs(var) do 是因避免__pairs元方法干扰
				foreach_var(k, "k")
				foreach_var(v, "v:" .. tostring(k))
			end
		elseif t == "userdata" then
			local mt = getmetatable(var)
			if mt then
				foreach_var(mt, "metatable")
			end
			local uv = getuservalue(var)
			if uv then
				foreach_var(uv, "uservalue")
			end
		elseif t == "thread" then -- 通过从当前协程开始可遍历到其他所有活跃协程
			foreach_func_frame(var, START_FUN_LEVEL, "thread")
		elseif t == "function" then
			local i = 1
			while true do
				local name, v = getupvalue(var, i)
				if name == nil then
					break
				else
					foreach_var(v, "upvalue:" .. name)
				end
				i = i + 1
			end
		end
		pop_path()
		return count
	end

	-- 补充所有类型元表遍历
	-- nil, number, boolean, string, thread, function, lightuserdata may have metatable
	for _, v in pairs { nil, 0, true, "", coroutine.running(), M.foreach, debug.upvalueid(M.foreach, 1) } do
		local mt = getmetatable(v)
		if mt then
			push_path(type(v))
			foreach_var(mt, "metatable")
			pop_path()
		end
	end

	foreach_func_frame(coroutine.running(), START_FUN_LEVEL, "thread")
	-- foreach_var(coroutine.running(), "coroutine.running()")
	foreach_var(debug.getregistry(), "debug.getregistry")
	if options and options.path then
		assert(0 == #options.path, table.concat( options.path, "|"))
	end
	return count
end
-- print(M.foreach(nil, {path = {}}))

function M.findloader(name)
	local msg = {}
	for _, loader in ipairs(package.searchers) do
		local f, extra = loader(name)
		local t = type(f)
		if t == "function" then
			return f, extra
		elseif t == "string" then
			table.insert(msg, f)
		end
	end
	error(string.format("module '%s' not found:%s", name, table.concat(msg)))
end

-- -- 原始类型中默认只有字符串类型有元表
-- for _, v in pairs { nil, 0, true, "", coroutine.running(), M.foreach, debug.upvalueid(M.foreach, 1), {} } do
-- 	local mt = getmetatable(v)
-- 	print(type(v), mt)
-- end

return M
