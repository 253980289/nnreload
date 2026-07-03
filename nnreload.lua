--[[
create by lj 2026-5-21
模块名
	nnreload
功能
	实现lua代码/模块热重载
设计
	直接在云风的https://github.com/cloudwu/luareload模块基础上修改而来
	概念
		【外部依赖变量】【外部变量】 全局变量及其子字段、外部模块及其子字段(比如require等方式间接引入的外部变量，非本地定义局部变量)
	策略
		只更新函数，其它类型作为状态保留原值，但变更新值为【外部依赖变量】时也会被更新
		禁止热更主代码中【外部依赖变量】修改、计算及函数调用
		热更只能发生在函数切换时，若函数已经运行且未结束是无法热更到的(即使热更了，此时内存可能是多个版本，未运行完的版本仍用的旧版本代码)
	参考
		https://blog.csdn.net/qq_33060405/article/details/148546715
		https://blog.codingnow.com/2016/11/lua_update.html
	优势
		对大部分动态函数(无论是主模块付值还是运行过程中付值)，无须重新执行付值代码即能智能跟踪自动替换为新版本(根据旧版本的upvalue值查找映射关系)
		对元表、协程的各个栈帧及栈帧内的局部变量均有考虑到并做处理
实现
	参见M.reload接口注释
使用必读
	本模块为纯lua代码实现，可独立使用，不依赖其他任何外部模块；其中nnluavm.lua主要要用于本模块的内部开发调试测试，在应用环境无须包含，可通过set_options接口控制(默认无依赖)
	本模块核心接口为M.reload，set_options接口为辅助可选接口
	崩溃级：
		避免所有变量重命名、类型变化、定义/含义变化、函数签名(参数数量、顺序、类型等)变化、函数依赖的upvalue签名(数量、类型、含义)变化
		避免新旧函数依赖的状态不一至
	热更失败/异常/逻辑错误级：
		避免使用全局变量
		避免在主模块中做局变量(包括函数)定义及require以外的事情(例如计算、函数调用、全局或外部变量付值、初始化等)
		避免使用匿名函数
		避免函数内部定义函数(包括匿名函数)，所有函数均统一定义在模块级
		避免需要更新的状态数据局部引用化：比如配置
		避免动态函数
		热更不支持对象类型作为表的key类型
		热更不支持持续无限循环运行的主协程函数(应尽量精简主函数并将需变更的逻辑抽取成子函数调用)
		热更不支持置空操作
开发记录
	相对cloudwu的reload模块的主要修改点：
		[_%a]%w*正则式问题：修正为【[_%a][_%w]*】：此问题会导致对包含下线划名字的全局变量或模块子字段不能正确解析
		solve_globals中未解析所有全局变量(部分支未执行set_var)及做事后检测：增加check_unsolve_globals及修改其内部实现
		solve_globals中对模块名匹配机制【^%[([_%w]+)%]】中未考虑包含点【.】的子模块名，修改为【^%[([_%w.]+)%]】
		删除未使用的接口：sandbox.value、get_G、get_M
		新增函数upvalue无法关联问题 #8 -- https://github.com/cloudwu/luareload/issues/8：按问题提交者的方案修正
		对于其他 thread 从 level 为 2 的栈帧开始更新会导致 level 为 0 和 1 的栈帧没有更新到（668 行）：直接将level从2改为1(0是不是为yield应跳过？)，同时内部不再+1
		修改条件以实现表字段仅替换函数而保留状态的更新规则：if (type(v) ~= "table") or
		新模块中一个变量在旧模块中对应多个不同变量(包括nil类型)，当变量为表或函数类型时，热更结果具有随机性(测试用例18)，原因是enum_var收集变量时顺序存在随机性，而在match_vars处理中存在对顺序的依赖性，在某类顺序中缺少检测机制导致，修改：增加检测机制明确问题【if not is_nil(map[new_var]) then】
		【优化代码】：结构、统一命名、增强命名精确度、修正歧义
		【增强】调试机制和接口
		旧版 debug.upvaluejoin 时未对upvalue类型做判断，当类型为函数时，不应该join旧值，因为函数应该保持新版本；虽然这个是缺陷，但由于后续的 update_funcs 全面替换中隐性弥补了此漏洞，导致更新结果仍然正确
		enum_var中将原版按value作唯一遍历索引改为按访问路径索引：因为同一value可能存在多条访问路径，而不同访问路径可能映射不同的旧值，而其中有些可能为nil，如果按单路径可能遗漏热更映射关系
		增加忽略【外部依赖变量】遍历、修改、调用和计算的兼容性支持选项
		修改 sandbox.isdummy 实现，排除字符串类型及排除safe_function关联关系
	第三方提交的问题：https://github.com/cloudwu/luareload/issues/15
		-实现中有数个 error 调用参数写错（145 行、162 行、176 行）：未调用的子函数接口，直接删除相关子函数接口
		-对于其他 thread 从 level 为 2 的栈帧开始更新会导致 level 为 0 和 1 的栈帧没有更新到（668 行）：修正
		-solve_global 的时候没有考虑到模块名可能包含"."的情况（524 行）：修正
		-solve_global 函数中第 527 行和第 532 行的 break 会导致直接中断对 global_dummy 的遍历，从逻辑上来说应该是改成 goto：修正(部分改为goto，其它增加error监控)
		reload 一个模块，其依赖的模块也会被 reload，导致所有依赖的模块都必须遵循 reload 的限制（123 行设置的 require 函数）：是否有可能通过类似创建dummy的方式控制屏蔽掉依赖的加载呢？如果屏蔽了，局部更新还算完整吗？
		-[BUG FIX]如果更新的文件中新定义了一个function，使用了global变量，会更新错误 #16 -- https://github.com/cloudwu/luareload/issues/16：应该在修复solve_global bug时同步修正掉了
热更策略歧义/风险
	当新旧值类型不一至时，应如何决策？报错？静默成功？不做任何处理？
	当旧值为nil时固定用新值替换的策略是否一定ok？当初值不为nil，运行时附值时，此时这种策略就可能是不对的。
	所有特别不期望热更的值(包括函数和状态值)可能需要在热更代码中针对性的附值为nil，而在正式代码中恢复其有效初始值
	所有名称、函数签名(参数数量、顺序、类型等)、函数依赖的upvalue签名(数量、类型、含义)等的变更均会产生重大热更风险
坑
	301. 不支持包含有初始函数的动态函数热更:动态初始函数：比如模块初始函数为空函数，在初始化时根据配置动态替换为实际版本，在热更时将可能被替换回初始版本
	302. 不支持包含有初始状态的动态状态存在置空状态的热更
热加载前提条件(所有热更方案无法解决问题(使用热加载需要代码规范约束配合的地方))
	依赖的upvalue变量未重命名：要求我们在期望热更阶段暂时保持原名字
	期望更新的upvalue同名变量类型需要一至(旧值为nil时可适配任意类型)
	协程主函数或运行过程中没有切换机会的函数代码(虚拟机按字节码执行，即使函数被更新，如果不被重调用，更新实际起不到作用)：要求我们协程主函数尽可能简单而无须更新，将业务逻辑尽可能放到可重复调用的子函数中去
	主模块中直接包含的执行逻辑(不可控)：要求我们主模块中仅仅做变量(包括函数)声明和定义，将执行逻辑(包括初始化)放到子函数中去由外部调用【用云风的原话描述为：有复杂的初始化流程必须提供一个模块的初始化函数，由外部驱动，而不能直接写在模块的加载流程中，这也回避了更新模块代码时的重复初始化过程。】
	?(此条还待对本模块进行考证)代码不同层级的变量使用相同的名字(内存将屏蔽外层，由于热更采用模块级共享upvalue命名空间的唯一名字映射机制，不允许不同变量采用同一名字)：要求我们所有可能成为upvalue的变量均采用全局唯一名字
	动态代码，对于动态变更的数据(包括函数)，热更可能无法确定真正期望的目标版本：要求我们尽可能减少动态函数，这类热更我们很可能只能通过hotfix针对性处理
	匿名函数因无法根据名字映射，所以无法更新
	某些特殊函数的upvalue名称可能为?或(no name)之类，很可能导致热加载异常：变量名需符合【^[_%w]】正常变量名规则，包括在去除调试符号(比如通过string.dump方式)的代码中，获取的upvalue名可能就不符合此规则
	new_var(包括new_field)不能为nil：无法实现新值为nil旧值非nil的更新模式：这种情况估计只能用针对性补丁方案吧
	所有变量改名改类型(nil值除外)的行为均可能产生问题
本模块热加载机制补充前提条件
	模块名不允许包含特殊字符：必须为 [_%w.]+ 模式，比如不允许包含连字符：fail_error("invalid module name: %s", path)
	__newindex = disable_write__newindex, 不允许在热加载主代码中对全局环境和外部模块进行修改
	__pairs = disable__pairs, 不允许在热加载主代码中对全局变量及其子字段和外部模块及其子字段进行for pairs遍历
	所有表字段名需符合 accept_key_type【number|string|boolean】 类型规则，所以暂时不支持以对象(函数,协程、表)作为表的key类型的热加载
	fail_error("type mismatch(同名变量新旧值类型不匹配): %s", table.concat(current, ","))
	fail_error("Ambiguity upvalue(存在多个同名变量upvalue歧义): %s .%s", tostring(new_var), name)
	fail_error("Ambiguity var(存在同一个新值变量对应多个不同旧值的歧义): %s", table.concat(item, ",", 2))
	不支持在热加载主代码中包含对【外部依赖变量】的运算：包括算术运算、字符串拼接等各类运算操作
	新模块中一个变量在旧模块中对应多个不同变量(包括nil类型)，当变量不为表或函数类型时，在热更后不报错，但结果不正确(测试用例110)：新值不再引用同一变量了，因为普通变量为值类型而非引用类型，无法确定其共享身份
目前版本明确不支持情形：
	101. 不支持模块名包含特殊字符(比如连字符
	102. 不支持全局变量附值
	103. 不支持外部依赖模块字段附值
	104. 不支持匿名函数更新
	105. 不支持在热加载主代码中对全局变量及其子字段进行for pairs遍历
	106. 不支持在热加载主代码中对外部模块及其子字段进行for pairs遍历
	107. 不支持以对象(函数,协程、表)作为表的key类型(accept_key_type【number|string|boolean】的热加载
	108. 不支持新旧模块同名路径中间节点类型(必须同为表或函数)不匹配，会导致无法定位(通过表字段和函数upvalue)原变量
	109. 不支持新旧模块同名变量类型不匹配（函数 vs 表）
	110. 不支持基本类型(非表、函数)变量的一至性检测：新模块共享同一个基本类型变量，但旧模块中它们是两个不同基本类型变量，需要应用层自己规避这类写法或热加载后自行检测
	111. 不支持多个同名变量upvalue歧义
	112. 不支持在热加载主代码中包含对【外部依赖变量】的运算：包括算术运算、字符串拼接等各类运算操作
	113. 不支持新模块共享同一个表或函数而旧模块中它们是两个不同表或函数(包括nil)但同类型变量，热更后会导致新值不一至，但能检测出异常
	114. 不支持主热更代码中外部依赖函数调用，相当于skynet主服务模块(包含skynet.start)是无法热更的
说明
	匿名函数与动态(运行时付值)函数是不同的，即使是动态函数，只要其付值对象是有名字的，那么就可能(前提是存在别的upvalue的引用关系)根据名字追踪到
TODO:
	可考虑并优先优化性问题：
		- 通过测试用例定位模块中的特殊分支及error分支，重点：solve_globals接口
		- 可观测机制支持(支持开关)：需要提供记录和显示热加载中所有变更点(新模块(require相关)、所有函数替换点(模块函数、upvalue函数、各栈中局部变量函数、元表中包含函数、全局变量函数))
		- 完整测试用例，便于高效回归测试：寻找更多不同场景以全面测试和评估本模块风险
		- 优化debug_log_change信息以输出更人性化精确变更信息
		- 测试用例104测试结果不稳定
		- 验证旧版本表的普通字段状态值不能保留原值，即也会被新版值替换，原因是merge_objects中判断修改【old_one[k] = v】条件中有【or type(v) ~= "table"】导致
		- 将不支持测试用例修正为报错形式
		- 将歧义测试用例修正为报错形式
		- 优化调试日志以增强排错能力
		- 增加nnhotfix模块接口以测试对比与本模块在热更上的效果
		- 考虑尽可能的支持兼容实际项目场景，减少实际项目的重构和规范来兼容热更的成本
			- 考虑通过配置支持对【外部依赖变量】修改、运算及函数调用以扩大实际项目应用的适应范围：是否正确合理和有必要性？
			- 考虑通过可选配置项控制支持【外部依赖变量】的函数更新，即支持全局变量、外部模块及其子变量中函数类型的更新，比如gdata.dispatch.req***系列函数更新：enable_external_dependent_variables_change_fun
			- 提供预演支持：只做热更检测，能显示所有流程和变更及异常，但并不真正热更，为真正的热更操作做评估准备以降低热更风险和提高热更准确性
			- 预演功能支持与正式功能混合使用，即模块能同时支持两种模式并能在两种模式间切换，或者说，set_options方法支持重入
		- 优化循环引用导致的热更性能差(has_circular_reference)：call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.reg.M.2.call
		- 验证观察者模式中函数数组是否会产生热更坑：错误(位)映射新旧函数
		增加不支持热更的测试用例
			函数更新而状态保留时有个坑：旧状态不配合新函数时将产生不可预料的结果
			字段名中包含【.】字符时，会因热更算法中依赖【.】作为路径分隔符而导致热更失败，目前项目配置中包含【.】
		针对项目真实代码场景测试
			工程化接口测试：支持配置排除范围和强制热更模式
			配置更新测试：包括删除配置项和局部化配置同步性等
	详细研读和理解本模块核心机制以便完全撑握其用法及注意事项，同时考虑进一步优化方案
	可考虑但暂不考虑的问题：
		考虑是否能借用本模块核心机制重新设计或应用到nnsandbox或nnhotfix模块中以融合各方特长 -- 目前重点考虑本模块而放弃前两者
		考虑如何100%避免部分热更的情形，即达到事务级别：要么完全成功，要么完全取消无副作用：需要大量测试 -- 似乎实现不了，持续执行的协程主函数没法更新
		增加nnsandbox模块接口以测试对比与本模块在热更上的效果
		考虑函数内部局部函数更新策略和必要性 -- 需要具体场景才好考虑，一般场景似乎没有必要性或不好实现
		本模块未支持对非基本类型key(accept_key_type)值处理
		热加载接口友好性：支持按代码热更(优化测试效率)、支持热加载模块时指定原名和映射名(优化reload.postfix机制)、无状态模式(替换掉reload.postfix，reload.print模式)
		本模块被设计为直接禁止写全局变量及其字段，但正常业务代码中这种情况是存在的：暂不考虑在此模块实现修改，而采用别的模块方案来实现，比如nnsandbox模块
		热加载预演支持：在沙箱环境热加载后仅仅用于观察其变更范围和影响，但并不执行真正的更新，可作为真正热加载前帮助分析实施风险：暂不考虑在此模块实现修改，而采用别的模块方案来实现，比如nnsandbox模块
		热加载回滚机制
		新代码存在运行时异常代码时并不能及时检测到
		local name = "[" .. name .. "]" -- 如果模块名本身包含特殊字符，例如 ] 或 [，可能会破坏路径解析。但模块名通常是标识符，风险较小。
		云大，匿名函数的 upvalue无法更新，一直是第一个函数的 #11 -- https://github.com/cloudwu/luareload/issues/11：研究发现这个应该是匿名函数问题，因匿名函数没有对应的映射名字，故找不到更新规则从而未能更新
]]

local M = {
	enable_invalid_reference_error = false, -- 表示当热更代码中检测到无效dummy引用(在原始环境中未找到或找到的对应值为nil)时是否报错失败，默认不报错而是直接将这些引用设置为nil
	circular_reference_path_len = 32,
}
-- 沙箱为单例(dummy_cache/_LOADED等共享)，reload过程不可重入，否则两个reload会互相污染沙箱状态导致映射错乱
local reloading = false

local sandbox = {}

local table = table
local debug = debug
local debug_setupvalue = debug.setupvalue
local debug_getupvalue = debug.getupvalue
local tostring = tostring
local string_format = string.format
local table_pack = table.pack
-- 用于表示“显式写入 nil”的哨兵值，本来用一个空table或空函数是最合适(能保证精确唯一区分)的，但由于逻辑中为简化处理通过类型比较跳过对本值的判断，所以此处不能用table和function类型作标识了，除非重构相关代码判断
local SENTINEL_NIL = "[SENTINEL_NIL__osd832,fsgsddk566585fdjhdu559594hfghjdgkdcom]"
local function is_nil(v)
	return (nil == v) or (v == SENTINEL_NIL)
end
local MT_MODULE_NAME = "MODULE__LSFDA32342" -- 随机名字以避免与外部名称冲突
local MT_GLOBAL_NAME = "GLOBAL__LSFDA32342"

-- 以下为内部日志调试机制
-- 调试模式暂时内部硬编码控制，若有需要再考虑提供对外接口控制
local reload_logs = {} -- 同时作为开关
-- 日志缓冲一次输出，避免与其他输出信息互相干扰
local function print_buffer(...)
	-- table.insert(reload_logs, nnserialize.vtostring_default(...)) -- 由于沙箱的特殊dummy机制，无法使用正常序列化功能(可能递归直接挂了吧)
	local args = table.pack(...)
	-- for i, v in ipairs(args) do -- 会因空洞而跳过
	local n = args.n
	for i = 1, n do
		local v = args[i]
		reload_logs[#reload_logs + 1] = tostring(v)
		if i < n then reload_logs[#reload_logs + 1] = "\t" end
	end
	reload_logs[#reload_logs + 1] = "\n"
end
-- 调试跟踪reload的实质变更
local debug_change_info = {step = "", key_path = ""} -- action:raset|upvaluejoin|set_value|set|setupvalue|REAL_LOADED[mod_name] = data.module.module	test_cross_B
local _debug_log_change = function( ... ) end
local debug_log_change = function(action, value_path, value, key_path, keep_key_path)
	_debug_log_change(string_format("[change][%s][%s]%s----->%s(%s)", debug_change_info.step, action, key_path or debug_change_info.key_path, value_path or "", value)) -- print-- 默认缓冲输出模式
	if keep_key_path and key_path then
		debug_change_info.key_path = key_path
	end
end
-- 调试自身执行步骤，一般用于排查自身bug
local _debug_log_step = function( ... ) end
local debug_log_step = function(step, ... )
	debug_change_info.step = step
	_debug_log_step("[step]", step, ...) -- print-- 默认缓冲输出模式
end
local function output_reload_step()
	if not next(reload_logs) then
		return
	end
	print("-------------------------------reload_logs:\n", table.concat(reload_logs))
	reload_logs = {}
end
local function get_option_log_fun(fun_or_boolean)
	return (("function" == type(fun_or_boolean)) and fun_or_boolean) or (fun_or_boolean and print) or (function( ... ) end)
end
-- fun_or_boolean 允许设置为true，这样输出不是同步而是缓冲最后单次输出
local function set_debug_log_change(fun_or_boolean)
	_debug_log_change = get_option_log_fun(fun_or_boolean)
end
local function set_debug_log_step(fun_or_boolean)
	_debug_log_step = get_option_log_fun(fun_or_boolean)
end
-- 这个级别是比较低的，一般表示本模块能够合理的兼容这类问题
local function _error_log(...)
	-- print("\x1B[31m[err]", ...)
	-- io.write("\x1B[0m")
	local params = table.pack("\x1B[31m[err]", ...)
	params[params.n + 1] = "\x1B[0m"
	print(table.unpack(params))
end
local error_log = function( ... ) end
function M.set_options(options)
	-- 调试输出相关
	set_debug_log_change(options.debug_log_change)
	set_debug_log_step(options.debug_log_step)
	M.debug_log_new_code = get_option_log_fun(options.debug_log_new_code)
	M.show_old_to_new_func_map = get_option_log_fun(options.show_old_to_new_func_map)
	error_log = get_option_log_fun(options.error_log)
	M.after_check_vm_dummy = options.after_check_vm_dummy
	-- 执行逻辑相关
	M.dry_run = options.dry_run -- 差别：缺少 update_funcs 中的 setupvalue 等所有操作
	M.enable_invalid_reference_error = options.enable_invalid_reference_error -- 热更代码主体直接引用了未定义的全局变量时是否直接报异常
	M.new_old_need_same_type = options.new_old_need_same_type -- 热更检测到新旧代码同名映射的变量类型不一至时是否直接报异常，若不报异常将直接静默替换为新值
	sandbox.set_ignore_external_dependent_variables_change(options.ignore_external_dependent_variables_change, options.enable_external_dependent_variables_change_fun)
	M.circular_reference_path_len = options.circular_reference_path_len or M.circular_reference_path_len
end

-- 错误级异常
local function fail_error(format, ...)
	error(string.format(format, ...))
end

-- 属于警示级异常
local function invalid_reference_error(format, ...)
	if M.enable_invalid_reference_error then
		error(string.format(format, ...))
	end
end

-- 属于防御级异常：表示此类情况正常不会发生
local function defense_error(format, ...)
	error(string.format(format, ...))
end

local function parse_var_by_path(path, parent)
	-- parent = parent or _G
	for w in string.gmatch(path, "[_%a][_%w]*") do
		if parent == nil then
			-- error("invalid path", path)
			break
		end
		parent = parent[w]
	end
	return parent
	-- return require("nntable").get_by_dot_key(parent, path) -- 等效的
end
-- print(parse_var_by_path("a.b", {a = {b = 1}}))

local function parse_module_name_by_path(path)
	local from, to, mod_name = string.find(path, "^%[([_%w.]+)%]") -- 添加【.】匹配符
	if from == nil then
		error("invalid module " .. path)
	end
	return mod_name, to + 1
end

local function parse_module_var_by_path(path)
	local mod_name, left = parse_module_name_by_path(path)
	if nil == mod_name then
		error("invalid module " .. path)
	end
	return parse_var_by_path(path:sub(left), debug.getregistry()._LOADED[mod_name]), mod_name
end

local function auto_parse_var_by_path(path)
	if "[" == path:sub(1, 1) then
		return parse_module_var_by_path(path)
	end
	return parse_var_by_path(path, _G)
end

-- 目前机制沙箱只能单例使用，不要并行使用，因为数据是同一份
do -- sandbox begin
	local function findloader(name)
		if M.postfix then
			name = name .. M.postfix
		end
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
		defense_error("module '%s' not found:%s", name, table.concat(msg))
	end
	local try_replace_fun_env = function(func, env)
		local i = 1
		while true do
			local name, value = debug_getupvalue(func, i)
			if name == "_ENV" then
				-- debug_upvaluejoin(func, i, function() return env end, 1)
				debug_setupvalue(func, i, env) -- 感觉这里join和set没什么区别
				return i, value
			elseif not name then
				return nil
			end
			i = i + 1
		end
	end
	local function disable_write__newindex( ... )
		fail_error("disable_write__newindex")
	end
	local function disable__pairs( ... )
		fail_error("disable__pairs")
	end
	local global_mt = {
		__newindex = disable_write__newindex,
		__pairs = disable__pairs,
		__metatable = "SANDBOX",
	}
	local _LOADED_DUMMY = {} -- 模块名->模块dummy的缓存映射表
	local _LOADED = {} -- 沙箱中require模块的记录表
	local weak = { __mode = "kv" }
	local dummy_cache -- 全局变量名和全局变量dummy及其子对象dummy的双向映射表
	local dummy_module_cache -- 模块名(采用[***]格式)和模块dummy对象及其子对象dummy的双向映射表
	local external_dependent_variables_change = {} -- string: fun, fun: string

	local module_dummy_mt = {
		__metatable = MT_MODULE_NAME,
		__newindex = disable_write__newindex,
		__pairs = disable__pairs,
		__tostring = function(self) return dummy_module_cache[self] end,
	}

	local function make_dummy_module(name)
		local wrap_mod_name = "[" .. name .. "]" -- 注意，通过此方式，能让模块名包含更多的特殊字符，比如【.】
		if dummy_module_cache[wrap_mod_name] then
			return dummy_module_cache[wrap_mod_name]
		else
			local obj = {}
			dummy_module_cache[wrap_mod_name] = obj
			dummy_module_cache[obj] = wrap_mod_name
			return setmetatable(obj, module_dummy_mt)
		end
	end

	function module_dummy_mt:__index(k)
		assert(type(k) == "string", "module field is not string")
		local parent_key = dummy_module_cache[self]
		local key = parent_key .. "." .. k
		if dummy_module_cache[key] then
			return dummy_module_cache[key]
		else
			local obj = {}
			dummy_module_cache[key] = obj
			dummy_module_cache[obj] = key
			return setmetatable(obj, module_dummy_mt)
		end
	end

	local function make_sandbox()
		return setmetatable({}, global_mt)
	end
	local function readall(file, for_bin, nolog)
		local f = io.open(file, for_bin and "rb" or "r") -- 返回新的文件句柄。 当出错时，返回 nil 加错误消息。
		if not f then--为了方便获取文件不存在情况的感知(调用可能会报异常，使用pcall可以感知)
			if not nolog then
				print(file, " open file failed!\n") -- 仅测试文件是否存在可用is_file_exist
			end
			return nil -- 出错或文件不存在
		end
		local data = f:read("*a") --"*a"
		f:close()
		return data
	end
	function sandbox.require(name)
		assert(type(name) == "string")
		if _LOADED_DUMMY[name] then
			return _LOADED_DUMMY[name]
		end
		local loader, arg = findloader(name)
		-- print(loader, arg)
		-- os.exit(0)
		-- :preload: -- 除了第一个搜索器（预加载）之外的所有搜索器都将模块被找到的文件路径作为额外值返回，如 package.searchpath 所返回。第一个搜索器始终返回字符串“:preload:”。
		if M.debug_log_new_code then
			M.debug_log_new_code((":preload:" == arg) and package.preload[name] or readall(arg))
		end
		-- local env, uv = debug.getupvalue(loader, 1)
		-- if env == "_ENV" then -- 某些自定义加载器可能并非按lua规范将_ENV作为第一个upvalue值
		-- 	print("set make_sandbox", name, loader)
		-- 	debug_setupvalue(loader, 1, make_sandbox())
		-- 	print("getmetatable", getmetatable(_ENV))
		-- end
		-- debug_log_step("loader:", loader)
		local index, old_env = try_replace_fun_env(loader, make_sandbox())
		-- debug_log_step("index, old_env", index, old_env, debug_getupvalue(loader, 1))
		local ret = loader(name, arg)
		if nil == ret then
			ret = true
		end
		-- print("ret", ret)
		_LOADED[name] = { module = ret, external_dependent_variables_change = external_dependent_variables_change }
		external_dependent_variables_change = {}
		-- if env == "_ENV" then
		if index then
			-- print("---------------------index", index)
			debug_setupvalue(loader, index, nil) -- env) -- 1, nil) -- TODO:为什么这里不能设置回原来的env，否则会导致报：lua: not enough memory
			_LOADED[name].loader = loader			-- 在后续会通过 debug_setupvalue(data.module.loader, 1, _ENV) 还原
			_LOADED[name].index = index -- 这个机制是否ok需验证，先保持原始设计，后续再考虑是否需要这样优化
			_LOADED[name].env = old_env
		end
		_LOADED_DUMMY[name] = make_dummy_module(name)
		return _LOADED_DUMMY[name]
	end

	local global_dummy_mt = {
		__metatable = MT_GLOBAL_NAME,
		__tostring = function(self) return dummy_cache[self] end,
		__newindex = disable_write__newindex,
		__pairs = disable__pairs,
	}

	local function make_dummy(k)
		if dummy_cache[k] then
			return dummy_cache[k]
		else
			-- print("make_dummy", k)
			local obj = {}
			dummy_cache[obj] = k
			dummy_cache[k] = obj
			return setmetatable(obj, global_dummy_mt)
		end
	end

	function global_dummy_mt:__index(k)
		local parent_key = dummy_cache[self]
		assert(type(k) == "string", "Global name must be a string")
		local key = parent_key .. "." .. k
		return make_dummy(key)
	end

	-- local _inext = ipairs {}

	-- the base lib function never return objects out of sandbox
	local safe_function = {
		require = sandbox.require, -- sandbox require
		pairs = pairs,      -- allow pairs during require
		next = next,
		ipairs = ipairs,
		-- _inext = _inext,
		print = print, -- for debug
	}

	function global_mt:__index(k)
		assert(type(k) == "string", "Global name must be a string")
		if safe_function[k] then
			return safe_function[k]
		else
			return make_dummy(k)
		end
	end

	function sandbox.init(need_create_dummy_modules)
		sandbox.clear()
		dummy_cache = setmetatable({}, weak)
		dummy_module_cache = setmetatable({}, weak)
		if need_create_dummy_modules then
			for _, name in ipairs(need_create_dummy_modules) do
				_LOADED_DUMMY[name] = make_dummy_module(name)
			end
		end
	end

	function sandbox.isdummy(v)
		-- if safe_function[v] then
		-- 	return true
		-- end
		-- lua中字符串均包含元表，所以应该排除
		-- if "string" == type(v) then
		-- 	return false
		-- end
		-- return getmetatable(v) ~= nil -- 因为沙箱中未提供setmetatable，所以沙箱中代码不可能产生有metatable的对象
		local mt = getmetatable(v)
		return (mt == MT_GLOBAL_NAME) or (mt == MT_MODULE_NAME)
	end

	function sandbox.module(name)
		return _LOADED[name]
	end

	function sandbox.clear()
		dummy_cache = nil
		dummy_module_cache = nil
		for k, v in pairs(_LOADED) do
			_LOADED[k] = nil
		end
		-- 原模块为什么不清这个_LOADED_DUMMY？
		for k, v in pairs(_LOADED_DUMMY) do
			_LOADED_DUMMY[k] = nil
		end
		external_dependent_variables_change = {}
	end

	local function set_ignore_change_meta(meta, enable)
		local function fake() return nil end -- setmetatable({}, meta) end
		meta.__call = enable and fake or nil
		meta.__newindex = enable and fake or nil
		meta.__pairs = enable and function() return fake end or nil -- 对__pairs调用需要返回一个函数
		meta.__add = enable and fake or nil
		meta.__sub = enable and fake or nil
		meta.__mul = enable and fake or nil
		meta.__div = enable and fake or nil
		meta.__mod = enable and fake or nil
		meta.__pow = enable and fake or nil
		meta.__unm = enable and fake or nil
		meta.__concat = enable and fake or nil
		meta.__eq = enable and fake or nil
		meta.__lt = enable and fake or nil
		meta.__le = enable and fake or nil
	end
	function sandbox.set_ignore_external_dependent_variables_change(enable, enable_change_fun)
		sandbox.enable_external_dependent_variables_change_fun = enable_change_fun
		for i,mt in ipairs({module_dummy_mt, global_dummy_mt, global_mt}) do
			set_ignore_change_meta(mt, enable)
			if not enable then
				mt.__newindex = disable_write__newindex
				mt.__pairs = disable__pairs
			end
			if enable_change_fun then
				local old__newindex = mt.__newindex
				mt.__newindex = function(t, k, v)
					local path = tostring(t) .. "." .. k
					-- print("__newindex", path, v)
					if "function" == type(v) then -- 注意：对【外部依赖变量】我们仅仅处理函数，其它类型一律不作更新
						external_dependent_variables_change[path] = v
						return
					end
					if sandbox.isdummy(v) and external_dependent_variables_change[tostring(v)] then
						v = external_dependent_variables_change[tostring(v)] -- 将dummy直接替换为实际变量值
						external_dependent_variables_change[path] = v
						return
					end
					return old__newindex(t, k, v)
				end
			end
		end
	end
end -- sandbox end

local accept_key_type = {
	number = true,
	string = true,
	boolean = true,
}

local function has_circular_reference(path)
	-- call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.call.M.2.reg.M.2.call
	-- reg.M.2.reg.fun.3.M.1.reg.M.2.call.M.2.reg.fun.3.M.1.reg.M.2.reg.fun.3.M.1.call.M.2.reg -- 如有需要，还有优化的空间
	if #path <= 5 then -- 直接跳过小循环
		return false
	end
	local to = #path
	local i = #path - 1
	while i > 0 do
		if path[i] == path[to] then
			local len = 2 -- to - i
			if i >= len then
				for j=1,len - 1 do
					if path[i - j] ~= path[to - j] then
						return false
					end
				end
				return true
			end
			break
		end
		i = i - 1
	end
	return false
end

-- 对参数变量递归遍历子对象和upvalue值，将所有dummy变量/函数/表及其他们各自对应的访问路径作为结构化记录全部存储并返回(会处理循环引用问题)
-- 简单说就是收集参数变量为根的所有子孙函数和子孙表(包括dummy)变量
-- all_vars: [{table|function|dummy}*]
local function enum_var(module, path, all_vars)
	all_vars = all_vars or {}
	path = path or {}
	local seened = {}
	local function iterate(value)
		if has_circular_reference(path) or (#path > M.circular_reference_path_len) then -- 简单判断为循环引用不再处理，后续可以优化为理论算法，目前暂时好像没问题
			return
		end
		local str_path = table.concat(path, ".")
		if sandbox.isdummy(value) then
			debug_log_step("ENUM dummy", value, type(value), getmetatable(value), str_path)
			table.insert(all_vars, { value, table.unpack(path) })
			return
		end
		local t = type(value)
		if t == "function" or t == "table" then
			debug_log_step("ENUM", value, str_path)
			table.insert(all_vars, { value, table.unpack(path) }) -- 模块自身根变量也在此收集在内了
			-- 这个seened算法有bug，它是按实际值来索引，但不能访问路径对应的原值可能是不一样的，比如有些路径的旧值可能对应nil值，如果这些访问路径对应旧值为nil的变量被先放入seened中(包括映射值为nil值的path)，那么后续其他映射值非nil的子变量路径将无法添加，所以这里准确的方式应该是按path来索引
			-- TODO:bug:按str_path算法有递归问题，比如模块成员函数upvalue为模块时，模块和该成员函数形成循环引用模式，造成无限递归，暂时按上面的circular_reference_path_len策略解决
			if seened[str_path] then -- 注意，重要：这里先插入再判断不是bug，而是因为即使同一变量引用可能存在不同访问路径，为了后续对不同访问路径访问同一变量引用的提供一至性检测(主要是在match_vars函数中)，这里需要按其访问路径全部收录
				-- already unfold
				return
			end
			seened[str_path] = true
		else
			return
		end
		local depth = #path + 1
		if t == "function" then
			local i = 1
			while true do
				local name, v = debug.getupvalue(value, i)
				if name == nil or name == "" then -- lua文档：对于 C 函数，此函数使用空字符串""作为所有上值的名字。
					break
				else
					if not name:find("^[_%w]") then -- lua文档：变量名“?”（问号）表示没有已知名称的变量（从没有调试信息保存的块中保存的变量）。 实际测试(通过string.dump)可以出现【(no name)】名字
						defense_error("Invalid upvalue name: %s", str_path) -- 重要，当发现特殊名称时，需要警觉，很可能会导致热加载失败
					end
					local vt = type(v)
					if vt == "function" or vt == "table" then
						path[depth] = name
						path[depth + 1] = i -- 示例：test.gtest_nnreload.test_reload.log.2.ggame_api(old_fun_upvalue_index:1) 这里这个2表示test_reload函数的第二个upvalue值名为log，【.ggame_api(old_fun_upvalue_index:1)】表示log函数的第一个upvalue值名为ggame_api
						iterate(v)
						path[depth] = nil
						path[depth + 1] = nil
					end
				end
				i = i + 1
			end
		else -- table
			for k, v in pairs(value) do
				if not accept_key_type[type(k)] then
					fail_error("Invalid table key type : %s %s", k, str_path)
				end
				path[depth] = k
				iterate(v)
				path[depth] = nil
			end
		end
	end
	iterate(module)
	return all_vars
end

-- 用于在旧版本中按新版本的访问路径查找对应变量，注意：对函数类型来说，其原始索引(id参数)被忽略，也即对新旧函数来说，其upvalue索引无须一一对应，只需名字匹配即可，这给热加载增加了适应范围和自由度，允许新版本因逻辑变量而导致的中间插入、删除或调整upvalue顺序
-- 注意重点：这里仅仅按新值的名字查找，未对类型做判断，找到的结果可为任意类型值，也即完全未保证与新值类型一至，这是很大的风险隐患，若后续未处理好，将造成重大bug
local function find_var_by_path(mod, name, id, ...)
	-- print("find_var_by_path", mod, name, id, ...)
	if mod == nil or name == nil then
		return mod
	end
	local t = type(mod)
	if t == "table" then
		return find_var_by_path(mod[name], id, ...)
	else
		assert(t == "function", "type mismatch")
		local i = 1
		while true do
			local n, value = debug.getupvalue(mod, i)
			if n == nil or name == "" then
				return
			end
			if n == name then
				return find_var_by_path(value, ...)
			end
			i = i + 1
		end
	end
end

local function set_debug_var_path(data, new_var, path, old_var_is_nil)
	data.debug_map[new_var] = data.debug_map[new_var] or {}
	table.insert(data.debug_map[new_var], old_var_is_nil and (#data.debug_map[new_var] + 1) or 1, path) -- 优先把旧值非nil的路径作为第一个以便后续读取时按第一个输出
end

local function set_var_map(data, new_var, old_var, path)
	local old_var_is_nil = is_nil(old_var)
	if not sandbox.isdummy(new_var) then
		-- print("set_var_map", path)
		if old_var_is_nil then
			old_var = data.map[new_var] or SENTINEL_NIL -- https://github.com/cloudwu/luareload/issues/8 尽可能设置一个旧值不是nil的值作为映射
		end
		data.map[new_var] = old_var
	end
	set_debug_var_path(data, new_var, path, old_var_is_nil)
end
local function get_debug_var_path(debug_map, new_var, index)
	-- print(new_var)
	return debug_map[new_var][index or 1]
end

-- 功能：找到新旧变量映射表，注意本模块始终只处理表和函数类型变量
-- 新旧变量匹配规则：仅支持表和函数类型匹配、类型必须保持一至、不同层级匹配的对象需要一至(比如通过不同函数的同名upvalue匹配的值应该为同一个)
-- dummy对象放到globals数组中，普通表和函数放到map中
-- map：new_var = old_var，new_var type:function|table|dummy, old_var type:function|table|SENTINEL_NIL
-- all_vars和map的关系：map为all_vars中非dummy的映射子集
-- map会包含除dummy外all_vars中所有其他值
local function match_vars(data)
	local all_vars, old_module, map, globals, all_external_dependent_variables_change_vars = data.all_vars, data.old_module, data.map, data.globals, data.all_external_dependent_variables_change_vars
	for _, item in ipairs(all_vars) do
		local new_var = item[1] -- type:function|table|dummy
		local path = data.require_module_path
		if item[2] then
			path = path .. "." .. table.concat(item, ".", 2)
		end
		if sandbox.isdummy(new_var) then
			table.insert(globals, item)
			set_debug_var_path(data, new_var, path)
			-- print("[set_emmy_path]", path)
		else
			local ok, old_var = pcall(find_var_by_path, old_module, table.unpack(item, 2))
			-- print("ok, old_var", ok, old_var)
			if not ok then
				defense_error("find_var_by_path failed(无法定位到原变量(路径类型不匹配)): %s", path) -- 基本不会触发，因为总是会走到父变量的【type mismatch】处中断
			end
			if old_var == nil then
				-- if not is_nil(map[new_var]) then -- 出现这种情况是不是可能说明这只是一个正常的新增函数，可以忽略呢？
				-- 	fail_error("Ambiguity var(不同访问路径共享的同一个新值变量对应旧值不同(包括nil和非nil值)的歧义): %s(nil)<-->%s(no nil)", path, get_var_path(data.debug_map, new_var))
				-- end
				set_var_map(data, new_var, old_var, path) -- 注意：原设计这里使用false，很容易导致后续流程中将所有false当作old_var替换成new_var
			else
				-- 在enum时有seened保证唯一性插入all_vars表，所以这里不存在会出现map[new_var]已经有值的情况了
				-- if nil ~= map[new_var] then
				if type(old_var) ~= type(new_var) then
					fail_error("type mismatch(同名变量新旧值类型不匹配): %s", path)
				end
				if not is_nil(map[new_var]) and (map[new_var] ~= old_var) then
					fail_error("Ambiguity var(不同访问路径共享的同一个新值变量对应旧值不同(均非nil值)的歧义): %s(%s)<-->%s(%s)", path, tostring(old_var), get_debug_var_path(data.debug_map, new_var), tostring(map[new_var]))
				end
				set_var_map(data, new_var, old_var, path)
			end
			debug_log_step("MATCH", old_var, path)
		end
	end
	for _, item in ipairs(all_external_dependent_variables_change_vars) do
		local new_var = item[1] -- type:function|table|dummy
		local path = table.concat(item, ".", 2) -- 将复合路径和单一路径合并
		local ok, old_var = pcall(auto_parse_var_by_path, item[2]) -- 第二项为复合路径，需要单独解析
		if not ok then
			defense_error("auto_parse_var_by_path failed(无法定位到原变量(路径类型不匹配)): %s", path)
		end
		ok, old_var = pcall(find_var_by_path, old_var, table.unpack(item, 3))
		-- print("ok, old_var", ok, old_var)
		if not ok then
			defense_error("find_var_by_path failed(无法定位到原变量(路径类型不匹配)): %s", path) -- 基本不会触发，因为总是会走到父变量的【type mismatch】处中断
		end
		if old_var == nil then
			-- if not is_nil(map[new_var]) then -- 出现这种情况是不是可能说明这只是一个正常的新增函数，可以忽略呢？
			-- 	fail_error("Ambiguity var(不同访问路径共享的同一个新值变量对应旧值不同(包括nil和非nil值)的歧义): %s(nil)<-->%s(no nil)", path, get_var_path(data.debug_map, new_var))
			-- end
			set_var_map(data, new_var, old_var, path) -- 注意：原设计这里使用false，很容易导致后续流程中将所有false当作old_var替换成new_var
		else
			-- 在enum时有seened保证唯一性插入all_vars表，所以这里不存在会出现map[new_var]已经有值的情况了
			-- if nil ~= map[new_var] then
			if type(old_var) ~= type(new_var) then
				fail_error("type mismatch(同名变量新旧值类型不匹配): %s", path)
			end
			if not is_nil(map[new_var]) and (map[new_var] ~= old_var) then
				fail_error("Ambiguity var(不同访问路径共享的同一个新值变量对应旧值不同(均非nil值)的歧义): %s(%s)<-->%s(%s)", path, tostring(old_var), get_debug_var_path(data.debug_map, new_var), tostring(map[new_var]))
			end
			set_var_map(data, new_var, old_var, path)
		end
		debug_log_step("MATCH", old_var, path)
	end
end

local function find_upvalue(func, name)
	if "function" ~= type(func) then
		return
	end
	local i = 1
	while true do
		local n, v = debug.getupvalue(func, i)
		if n == nil or name == "" then
			return
		end
		if n == name then
			return i, v
		end
		i = i + 1
	end
end

-- 对匹配的所有新旧函数变量创建同名upvalueid的映射表，为后续全局替换(merge_funcs)做准备：这里是否需要递归处理？
local function match_upvalues(map, upvalues)
	local count = 0
	for new_var, old_var in pairs(map) do -- old_var type:function|table|SENTINEL_NIL
		if (type(new_var) == "function") and (type(old_var) == type(new_var)) then -- 当old_var为SENTINEL_NIL(空)时，类型会不一至
			local i = 1
			while true do
				local name, value = debug.getupvalue(new_var, i)
				if name == nil or name == "" then -- 对于特殊名字(比如【?】或【(no name)】)是否也需要跳过?
					break
				end
				local old_index, old_value = find_upvalue(old_var, name)
				if old_index then
					local id = debug.upvalueid(new_var, i)
					if not upvalues[id] then
						count = count + 1
						upvalues[id] = {
							func = old_var,
							index = old_index,
							oldid = debug.upvalueid(old_var, old_index),
						}
						-- 如果这个upvalue值为函数，那么是不是可以再递归增加这个upvalues的映射关系？ 预测：在enum阶段应该就已经放入map了，所以这里无须再深入。
						-- 这里是否有必要再这样递归一下？不递归的话有什么区别吗？
						-- 下面这段if代码应该是不必要的，暂时保留以验证我理论分析的正确性
						if ("function" == type(value)) and (type(value) == type(old_value)) then
							assert(map[value], "在enum阶段应该就已经放入map了，所以这里不需要再递归了。")
							-- print("recursion match_upvalues")
							-- local _count = match_upvalues({value = old_value}, upvalues)
							-- assert(0 == _count, "recursion match_upvalues：监测此断言以验证此递归方案的必要性，如果永远为0，那估计就确实没必要了。")
							-- count = count + _count
						end
					else
						local oldid = debug.upvalueid(old_var, old_index)
						if oldid ~= upvalues[id].oldid then -- 达成场景：两个新函数共享同一同名upvalue值，但这两个新函数对应的旧函数的同名upvalue却不是共享同一值
							fail_error("Ambiguity upvalue(存在多个同名变量upvalue歧义): %s .%s", tostring(new_var), name)
						end
					end
				end
				i = i + 1
			end
		end
	end
	return count
end

-- 在沙箱中重新加载指定模块列表，并创建新旧模块相关变量映射表
	-- require模块
	-- enum模块所有表、函数及外部依赖变量
	-- 匹配变量：创建映射表、收集外部/全局依赖
	-- 创建upvalue映射表
local function reload_list(module_name_list)
	local REAL_LOADED = debug.getregistry()._LOADED
	local all = {} -- 用来存放沙箱环境中热加载产生的所有直接数据及分析数据，为后续合并到真实环境做数据基础
	for _, require_module_path in ipairs(module_name_list) do
		debug_log_step("sandbox.require", require_module_path)
		sandbox.require(require_module_path) -- 这里有个问题，对于写在list中的模块，会经历此完整处理流程；但在模块内部require的新模块，并未包含以下处理流程，这是否有问题：对新require的模块，其价值肯定会作为当前模块某个函数的upvalue值，这会通过enum_var(m.module)遍历到，也即后续也会走后续流程，不同的是，没有一个对旧环境的_LOADED表付值的过程，所以我们在solve_globals中修改原设计来实现这一目标
		local m = sandbox.module(require_module_path)
		debug_log_step("enum_var")
		local all_vars = enum_var(m.module) -- 后续所有操作均以这里遍历出的objs列表为基础
		local all_external_dependent_variables_change_vars = {}
		if sandbox.enable_external_dependent_variables_change_fun then
			_debug_log_step("external_dependent_variables_change:")
			for k,v in pairs(m.external_dependent_variables_change) do
				_debug_log_step(k,v)
				enum_var(v, {k}, all_external_dependent_variables_change_vars)
			end
		end
		local old_module = REAL_LOADED[require_module_path]
		local data = {
			globals = {},
			map = {},
			debug_map = {}, -- 对应map中变量的原始路径信息用于调试
			upvalues = {},
			old_module = old_module,
			module = m,
			all_vars = all_vars,
			all_external_dependent_variables_change_vars = all_external_dependent_variables_change_vars,
			require_module_path = require_module_path,
		}
		all[require_module_path] = data
		debug_log_step("match_vars")
		match_vars(data) -- find match table/func between old module and new one
		debug_log_step("match_upvalues")
		match_upvalues(data.map, data.upvalues)           -- find match func's upvalues
	end
	return all
end

-- 按指定路径设置表或函数的字段或upvalue，主要包括两种场景：原值为nil时，强制设置为新值(样版值)；外部依赖变量(dummy值)；
local function set_var(v, mod, name, tmore, fmore, ...)
	if mod == nil then
		return false
	end
	if type(mod) == "table" then
		if not tmore then -- no more
			assert(not M.new_old_need_same_type or (nil == mod[name]) or (type(mod[name]) == type(v)), "这个断言是否必要？set_var:新旧值类型不同。")
			debug_log_change("set_var:set", "", v, string_format("%s.%s", debug_change_info.key_path, name))
			if not M.dry_run then
				mod[name] = v
			end
			return true
		end
		return set_var(v, mod[name], tmore, fmore, ...)
	else
		assert("function" == type(mod), "set_var:mod type mismatch")
		local i = 1
		while true do
			local n, value = debug.getupvalue(mod, i)
			if n == nil or name == "" then
				return false
			end
			if n == name then
				if not fmore then
					debug_log_change("setupvalue", "", v, string_format("%s.%s", debug_change_info.key_path, name))
					if not M.dry_run then
						debug_setupvalue(mod, i, v) -- 需要验证此方案没有问题(理论猜测：此处仅仅将样映射的样版进行替换，其它引用同一样版的实例通过前面已经创建的upvalues映射表按此样版值进行替换，所以setupvalue和upvaluejoin缺一不可，它们是相互配合以达成全面替换目标的)
					end
					return true
				end
				return set_var(v, value, fmore, ...) -- skip tmore (id)
			end
			i = i + 1
		end
	end
end

-- 对map中的所有函数变量(new_var)按upvalues映射表(按upvalueid)全部重新upvaluejoin(old_value)：维持新版本函数的旧状态
local function merge_funcs(upvalues, map, debug_map) -- 不修改真实环境
	debug_log_step("merge_funcs")
	for new_var in pairs(map) do
		if type(new_var) == "function" then
			local i = 1
			while true do
				local name, v = debug.getupvalue(new_var, i)
				if name == nil or name == "" then
					break
				end
				local id = debug.upvalueid(new_var, i)
				local old_uv = upvalues[id]
				if old_uv then
					-- 如果新值为函数，不应该替换，只替换非函数状态值
					if "function" ~= type(v) then
						local old_key_path = debug_change_info.key_path
						debug_log_change("upvaluejoin", string_format("(old_fun_upvalue_index:%d)", old_uv.index), new_var, string_format("%s.%s(new_fun_upvalue_index:%d)", get_debug_var_path(debug_map, new_var), name, i))
						if not M.dry_run then
							debug.upvaluejoin(new_var, i, old_uv.func, old_uv.index)
						end
					end
				end
				i = i + 1
			end
		end
	end
end

local function is_same_path(dummy_read_path, dummy_new_write_path)
	dummy_read_path = string.gsub(dummy_read_path, "[%[%]]", "")
	dummy_read_path = string.gsub(dummy_read_path, "package.loaded.", "")
	return dummy_read_path == dummy_new_write_path
end
-- print(is_same_path("package.loaded.test_set_self.a", "test_set_self.a"))
-- print(is_same_path("[test_exist_module].val", "test_exist_module.val"))

-- 针对旧表字段为nil值的情况：将新值替换到旧值中
local function merge_tables_nil_value(map, debug_map) -- 会修改真实环境，但可能影响不大
	debug_log_step("merge_tables_nil_value")
	for new_var, old_var in pairs(map) do
		if type(new_var) == "table" and (type(new_var) == type(old_var)) then -- 当 old_var 为空时类型不一至
			for k, v in pairs(new_var) do
				local is_self_dummy = sandbox.isdummy(v) and is_same_path(tostring(v), get_debug_var_path(debug_map, v))
				if not is_self_dummy and (old_var[k] == nil) then
					debug_log_change("set", "", v, string_format("%s.%s", get_debug_var_path(debug_map, new_var), k))
					if not M.dry_run then
						old_var[k] = v
					end
				end
			end
		end
	end
end

-- 针对upvalue旧值为nil的情况更新
local function merge_upvalue_nil_value(data, mod_name)
	-- 对加载模块中没有对应旧变量的新变量值直接设置到旧模块中，因为没有映射值，所以这里都不是join而是直接的set
	debug_log_step("merge_upvalue_nil_value") 
	for _, item in ipairs(data.all_vars) do
		local new_v = item[1]
		if not sandbox.isdummy(new_v) then
			local path = table.concat(item, ".", 2)
			local old_v = data.map[new_v]
			-- 这里3个函数共享一个upvalue，但却只set_var了一个却又能保持3个函数仍同步，是因为这里仅仅将样版值set了，其它值将通过upvalues映射表同步
			if is_nil(old_v) then -- 只有当原值为nil时才会强制设置
				debug_change_info.key_path = string_format("package.loaded.%s", mod_name)
				local ok = set_var(new_v, data.old_module, table.unpack(item, 2)) -- 这里不同于merge_tables_nil_value用于子字段，而这里用于父表本身
			end
		end
	end
end

-- 根据之前沙箱运行记录的数据合并新旧变量：将沙箱应用到真实环境，主要包括模块、函数、表、
local function merge_all_vars(all) -- 对真实环境有弱污染，此步异常一般影响不大(可能多设置了一些不用的值或设置了一些原为nil的新值，具体影响程度要看具体逻辑)
	local REAL_LOADED = debug.getregistry()._LOADED
	for mod_name, data in pairs(all) do
		if data.old_module then
			local map = data.map
			-- 处理函数映射值的更新
			merge_funcs(data.upvalues, map, data.debug_map) -- 新函数旧状态保留
			merge_upvalue_nil_value(data, mod_name) -- 补充函数upvalue nil值更新
			-- 补充表字段nil值更新
			merge_tables_nil_value(map, data.debug_map)
		else -- reload的模块非【热更】加载，而是首次加载，理论上不应放到reload参数列表中
			error_log("MODULE", "_LOADED[mod_name]", mod_name, data.module.module)
			debug_log_step("merge_all_vars")
			debug_log_change("set", "data.module.module", data.module.module, string_format("package.loaded.%s", mod_name))
			if not M.dry_run then
				REAL_LOADED[mod_name] = data.module.module
			end
		end
	end
end

-- 设计一个程序自检机制：热更后，每个全局变量dummy变量均应得到解引用，否则将会残留到真实环境中，在后续运行时随时报错
local function check_unsolve_globals(all)
	-- 在 solve_globals 循环之后，检查是否有未解决的全局引用
	for mod_name, data in pairs(all) do
		if next(data.globals) ~= nil then
			local unresolved = {}
			for _, item in pairs(data.globals) do
				unresolved[#unresolved + 1] = tostring(item[1])
			end
			defense_error("invalid global references in module '%s': %s",
				mod_name, table.concat(unresolved, ", "))
		end
	end
end

local function debug_show_all_globals(all)
	for mod_name, data in pairs(all) do
		for gk, item in pairs(data.globals) do
			-- solve one global
			local v = item[1]
			local path = tostring(v)
			print("globals:", path)
		end
	end
end

-- 解引用所有热更模块内的dummy变量为真实环境值：主要包括全局变量和模块(模块也可理解为全局变量的子值)
local function solve_globals(all)
	debug_log_step("solve_globals")
	local REAL_LOADED = debug.getregistry()._LOADED
	local i = 0
	for mod_name, data in pairs(all) do
		for gk, item in pairs(data.globals) do
			-- solve one global
			local v = item[1]
			local path = tostring(v)
			local value
			local invalid
			-- print("path:", path, table.concat( item, ".", 2 ))
			-- if path == string_format("package.loaded.%s.%s", mod_name, table.concat( item, ".", 2 )) then
			-- 	os.exit(0)
			-- end
			if getmetatable(v) == MT_GLOBAL_NAME then
				value = parse_var_by_path(path, _G)
				-- 关键补充：检查最终的 G 是否为 nil
				if value == nil then
					invalid_reference_error("invalid global reference: %s", path)
					goto invalid_reference
				end
			else
				-- "MODULE" 依赖的dummy模块要么之前就加载过，要么在本次热更中有require，不然将产生不能解析的dummy，应报错
				-- 引用的模块必须存在，但允许访问的字段为nil
				local dummy_mod_name, left = parse_module_name_by_path(path)
				local mod_or_mod_field_value = REAL_LOADED[dummy_mod_name]
				if mod_or_mod_field_value == nil then -- 说明是在本次热更时新require的模块，所以在之前的包中为空
					-- 我们从 sandbox 获取
					local sm = sandbox.module(dummy_mod_name) -- TODO:dry_run模式中这个新模块内部还包含新的dummy模块时，会导致解析不全的问题，我们要把内部引用解析解除，即新require的模块中包含同在本次require的模块引用不再以dummy形式存在，而是以实体形式直接替换，即让dummy的概念明确为仅包含对外部的依赖变量
					assert(sm and sm.module)
					mod_or_mod_field_value = sm.module -- 获取真实值
					debug_log_change("set", "sandbox.module(dummy_mod_name).module", mod_or_mod_field_value, "package.loaded." .. dummy_mod_name)
					if not M.dry_run then
						REAL_LOADED[dummy_mod_name] = mod_or_mod_field_value -- 更新到 _LOADED，前面 reload_list 中未处理完整模块内部require新模块(首次加载)的情况，所以这里需要补充；与merge_all_vars中模块付值不同，此处的模块名并不在 reload 模块参数列表中
					end
				end
				mod_or_mod_field_value = parse_var_by_path(path:sub(left), mod_or_mod_field_value)
				if mod_or_mod_field_value == nil then
					invalid_reference_error("invalid module reference: %s", path)
					goto invalid_reference
				end
				local mt = getmetatable(mod_or_mod_field_value)
				if mt == MT_MODULE_NAME then
					-- print("goto next_for", path)
					goto next_for -- 当mod是从沙箱环境获取的值时，由于pairs并非按序解析，此时其依赖的变量还未被解析，应等下一轮继续
				else
					value = mod_or_mod_field_value
				end
			end
::invalid_reference:: -- 对于无法解析的变量一律直接设置为nil(此时value为nil)
			i = i + 1
			debug_change_info.key_path = "package.loaded." .. mod_name
			-- print("REAL_LOADED[mod_name]", REAL_LOADED[mod_name], table.unpack(item))
			if M.dry_run and sandbox.module(mod_name) then -- 是沙箱内部模块
				M.dry_run = false -- 强制写沙箱内部模块，这样才能让后续的遍历完全，但并不会影响到外部真实环境
				set_var(value, sandbox.module(mod_name).module, table.unpack(item, 2))
				M.dry_run = true
			else
				set_var(value, REAL_LOADED[mod_name], table.unpack(item, 2))
			end
			data.globals[gk] = nil
::next_for::
		end
	end
	return i
end

-- 遍历整个lua虚拟机，将所有引用(字段、upvalue、局部变量、用户数据)的旧函数替换为新函数
-- old_to_new_func_map: old_value->new_var
local function update_funcs(all)
	local old_to_new_func_map = {} -- 注意，这里做了两层处理：一，对map过滤掉table而仅剩下函数；2，将k,v反过来，即new->old变为old->new
	local debug_map = {} -- [new_var] = path
	for _, data in pairs(all) do
		for new_var, old_var in pairs(data.map) do
			if (type(new_var) == "function") and (type(old_var) == type(new_var)) then -- 当old_var为空时类型会不至
				old_to_new_func_map[old_var] = new_var
				debug_map[new_var] = data.debug_map[new_var]
			end
		end
	end
	local root = debug.getregistry()
	local co = coroutine.running()
	local exclude = { [old_to_new_func_map] = true, [co] = true, [debug_map] = true,}

	-- 排除沙箱环境自身遍历，增强调试信息易分析性，非必须
	exclude[M] = true
	exclude[all] = true
	for _, data in pairs(all) do
		exclude[data] = true
		for new_var, old_var in pairs(data.map) do
			-- globals = {},
			-- map = {},
			-- upvalues = {},
			-- old_module = old_module,
			-- module = m,
			-- all_vars = all_vars
			exclude[data.map] = true
			exclude[data.globals] = true
			exclude[data.upvalues] = true
			exclude[data.all_vars] = true
		end
	end

	local getmetatable = debug.getmetatable
	local getinfo = debug.getinfo
	local getlocal = debug.getlocal
	local setlocal = debug.setlocal
	local getupvalue = debug.getupvalue
	local setupvalue = debug_setupvalue
	local getuservalue = debug.getuservalue
	local setuservalue = debug.setuservalue
	local type = type
	local next = next
	local rawset = rawset

	exclude[exclude] = true

	local update_funcs_
	local START_FUN_LEVEL = 1 -- 0级一般为【yield】层，是否应该跳过到下一级？ lua文档定义：第 0 级是当前函数（getinfo 本身）；第 1 级是调用 getinfo 的函数（尾调用除外，尾调用不在堆栈中计算）；以此类推。如果 f 是一个大于活动函数数量的数字，则 getinfo 返回 fail。

	-- 更新指定协程的每一帧
	local function update_funcs_frame(co, level, count)
		debug_log_step("update_funcs_frame")
		debug_change_info.key_path = string_format("co(%s).level(%d)", tostring(co), level)
		count = count or 0
		local info = getinfo(co, level, "f")
		if info == nil then
			return count
		end
		local f = info.func
		count = count + update_funcs_(f)
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
			local new_var = old_to_new_func_map[v]
			if new_var then
				debug_log_change("setlocal", get_debug_var_path(debug_map, new_var), new_var, string_format("%s.%s", debug_change_info.key_path, name), true)
				if not M.dry_run then
					setlocal(co, level, i, new_var) -- 将关联的局部引用函数替换为新版本
				end
				count = count + 1
				count = count + update_funcs_(new_var)
			else
				count = count + update_funcs_(v)
			end
			if i > 0 then
				i = i + 1
			else
				i = i - 1
			end
		end
		return update_funcs_frame(co, level + 1, count) -- 这里只能使用尾调用，不然会死循环直接卡死
	end

	local function do_metatable(var)
		local mt = getmetatable(var)
		if mt then
			local old_key_path = debug_change_info.key_path
			debug_change_info.key_path = string_format("%s.%s", debug_change_info.key_path, "metatable")
			local count = update_funcs_(mt)
			debug_change_info.key_path = old_key_path
			return count
		end
		return 0
	end

	-- 直接替换旧函数为新函数
	function update_funcs_(var) -- local function
		local count = 0 -- 增加统计数量仅为了调试
		if exclude[var] then
			return count
		end
		debug_log_step("update_funcs_")
		local t = type(var)
		-- print("debug_change_info.key_path", debug_change_info.key_path, t)
		-- local old_step = debug_change_info.step
		-- debug_change_info.step = debug_change_info.step .. "|" .. t
		if t == "table" then
			exclude[var] = true
			count = count + do_metatable(var)
			local tmp
			local debug_tmp
			for k, v in next, var do -- 这里不直接写成：for k,v in pairs(root) do 是因避免__pairs元方法干扰
				local old_key_path = debug_change_info.key_path
				debug_change_info.key_path = string_format("%s.%s", debug_change_info.key_path, k)
				local new_var = old_to_new_func_map[v]
				if new_var then
					debug_log_change("rawset", get_debug_var_path(debug_map, new_var), new_var)
					if not M.dry_run then
						rawset(var, k, new_var) -- 实现表的函数字段更新，但不包含原值为nil的情况
					end
					count = count + 1
					count = count + update_funcs_(new_var) -- 新值里可能包含旧值的dummy变量引用，所以这里仍然需要递归
				else
					-- dry_run下此处遍历仍会执行：目的是发现 v 内部嵌套的、命中 old_to_new_func_map 的引用并记录调试日志(预演所有变更点)。
					-- 实际写操作(rawset/setupvalue/setlocal/setuservalue)由各分支内部的 if not M.dry_run 统一拦截，
					-- 故 dry_run 预演的变更范围与正式热更一致，不会遗漏，无问题。
					count = count + update_funcs_(v)
				end
				new_var = old_to_new_func_map[k]
				if new_var then
					if tmp == nil then
						tmp = {}
						debug_tmp = {}
					end
					tmp[k] = new_var
					debug_tmp[k] = debug_change_info.key_path
				else
					count = count + update_funcs_(k)
				end
				debug_change_info.key_path = old_key_path
			end
			if tmp then -- 包含需要更新的函数key
				for k, new_var in next, tmp do -- 按前面对tmp的付值，这里的v就是new_var，所以这里直接改为统一名称便于理解
					local old_key_path2 = debug_change_info.key_path
					debug_log_change("replace_table_key", get_debug_var_path(debug_map, new_var), new_var, debug_tmp[k], true)
					if not M.dry_run then
						var[k], var[new_var] = nil, var[k]
					end
					count = count + 1
					local _count = update_funcs_(new_var)
					debug_change_info.key_path = old_key_path2
					assert(0 == _count, "新值里还会有需要替换的值吗？(有一种可能就是新值里包含dummy值从而引入了旧值，需要大量测试验证。)")
					count = count + _count
				end
				tmp = nil
			end
		elseif t == "userdata" then
			exclude[var] = true
			count = count + do_metatable(var)
			local uv = getuservalue(var)
			if uv then
				local old_key_path = debug_change_info.key_path
				debug_change_info.key_path = string_format("%s.%s", debug_change_info.key_path, "uservalue")
				local new_var = old_to_new_func_map[uv]
				if new_var then
					debug_log_change("setuservalue", get_debug_var_path(debug_map, new_var), new_var, string_format("%s.%s", debug_change_info.key_path, "uservalue"), true)
					if not M.dry_run then
						setuservalue(var, new_var)
					end
					count = count + 1
					count = count + update_funcs_(new_var)
				else
					count = count + update_funcs_(uv)
				end
				debug_change_info.key_path = old_key_path
			end
		elseif t == "thread" then -- 通过从当前协程开始可遍历到其他所有活跃协程
			exclude[var] = true
			count = update_funcs_frame(var, START_FUN_LEVEL, count)
		elseif t == "function" then
			exclude[var] = true
			local i = 1
			while true do
				local name, v = getupvalue(var, i)
				if name == nil then
					break
				else
					local old_key_path = debug_change_info.key_path
					-- assert("" ~= name)
					debug_change_info.key_path = string_format("%s.%s[index3:%d]", debug_change_info.key_path, name, i)
					local new_var_fun = old_to_new_func_map[v]
					if new_var_fun then
						debug_log_change("setupvalue", get_debug_var_path(debug_map, new_var_fun), new_var_fun)
						if not M.dry_run then
							setupvalue(var, i, new_var_fun) -- 此时新旧代码仍然保持着两份变量定义引用，只是此时的值是一样的，若lua虚拟机中仍保持着新旧两个版本的运行代码，且运行代码中对该upvalue值有新的附值操作，将仍只能同步一个版本，此时将出现新旧版本不一至情况；-- 我们认为这种附值操作肯定在某个函数中执行，且该函数也包含该upvalue值，那么只要所有upvalue值同步过了，这里的改变也将同步
							-- 此时即使使用upvaluejoin将所有共享值强制同步，但如果该upvalue值是作为某函数的局部变量存在，且在热更前后持续保持运行状态(比如while true sleep之类)，将仍会发生逻辑错乱现象：更改该变量已无效(因为依赖该变量的函数均已重新指向/引用到新代码中新的变量了) -- 因局部变量本身无法更新，所以此问题不存在
						end
						count = count + 1
						debug_change_info.key_path = debug_change_info.key_path .. ".new_upvalue"
						count = count + update_funcs_(new_var_fun)
					else
						debug_change_info.key_path = debug_change_info.key_path .. ".upvalue"
						count = count + update_funcs_(v)
					end
					debug_change_info.key_path = old_key_path
				end
				i = i + 1
			end
		end
		-- debug_change_info.step = old_step
		return count
	end

	-- 补充所有类型元表更新
	-- nil, number, boolean, string, thread, function, lightuserdata may have metatable
	for _, v in pairs { nil, 0, true, "", co, update_funcs, debug.upvalueid(update_funcs, 1) } do
		do_metatable(v)
	end

	debug_change_info.key_path = "debug.getregistry()"
	update_funcs_(root)
	debug_change_info.key_path = ""
	update_funcs_frame(co, START_FUN_LEVEL) -- 这里会优先遍历本模块及沙箱环境代码而不是实际业务代码，对输出的调试信息分析不利，所以相对原版本调整到最后(即更新的数据尽可能在真实业务路径做，而不是在本模块连接上做)
	if M.show_old_to_new_func_map then
		M.show_old_to_new_func_map("old_to_new_func_map------------")
		for old_fun, new_fun in pairs(old_to_new_func_map) do
			M.show_old_to_new_func_map("new_fun_path:", get_debug_var_path(debug_map, new_fun), old_fun, new_fun)
		end
	end
end

--[[
执行步骤为：
	第一部分：(沙箱环境执行)
		准备沙箱环境
		执行热加载模块
			require模块
			收集更新集合：enum模块所有表、函数及外部依赖变量，仅针对函数、表和外部依赖变量(TODO：其它类型不支持是否算漏洞？)
			匹配变量：创建新旧变量映射表、收集外部模块/全局变量依赖
			创建upvalue映射表：仅针对新旧值同为函数类型变量
	第二部分：(真实环境执行)
		合并新旧模块 -- 添加新值
		还原加载器环境upvalue -- 还原环境
		解析全局变量及其子变量引用 -- 部分更新外部变量
		全局遍历替换函数：函数、表、协程栈帧、元表、用户对象 -- 关键重度更新
		沙箱环境清理
注意：
	热更操作分两部分：
		第一部分在沙箱环境操作，此步在xpcall保护模式执行，不向外抛异常，即可忽略此热更
		第二部分在真实环境正式将热更结果应用到真实环境，此部分别同样加xpcall保护，但这仅为了做好清理工作，后续仍然抛出异常，即此部分无法忽略，形成部分热更行为，已经破坏了真实环境，立即崩溃才是正确选择
]]
function M.reload(module_name_list)
	module_name_list = ("string" == type(module_name_list)) and {module_name_list} or module_name_list
	assert("table" == type(module_name_list))
	-- 沙箱为单例，reload过程不可重入，否则两个reload会互相污染沙箱状态(dummy_cache/_LOADED等)导致映射错乱
	if reloading then
		error("nnreload.reload is not reentrant: another reload is in progress")
	end
	if 0 == #module_name_list then
		return false, "module_name_list is empty!"
	end
	reloading = true
	debug_log_step("init")
	local REAL_LOADED = debug.getregistry()._LOADED
	local need_reload = {}
	for _, require_module_path in ipairs(module_name_list) do
		need_reload[require_module_path] = true
	end
	-- 需要准备沙箱环境中可能依赖的外部模块dummy
	local need_create_dummy_modules = {}
	for k in pairs(REAL_LOADED) do
		if not need_reload[k] then -- 排除掉要热更的模块，因为它们是需要真正加载的真实模块
			table.insert(need_create_dummy_modules, k)
		end
	end
	sandbox.init(need_create_dummy_modules) -- init dummy modoule existed

	debug_log_step("reload_list")
	local ok, all = xpcall(reload_list, debug.traceback, module_name_list)
	if not ok then
		debug_log_step("ERROR", all)
		sandbox.clear()
		reloading = false
		return ok, all
	end
	-- 到此为止，可以理解为真实环境还是未改变的，从下面开始即发生改变；即上面报错不影响真实环境，如果下面中间报错，将可能导致部分热更而造成数据和环境混乱的局面

	local ok2, err = xpcall(function() -- 这里保护主要为清理环境，后续异常会在清理环境后继续抛出，避免出现部分热更的情况，线上环境应考虑立即终止或重启服务
		debug_log_step("merge_all_vars")
		merge_all_vars(all)

		debug_log_step("restore the loader _ENV")
		for _, data in pairs(all) do
			if data.module.loader then
				debug_setupvalue(data.module.loader, data.module.index or 1, data.module.env or _ENV) -- 1, _ENV) -- 此修改需验证 -- 为什么要放到这里来恢复？
			end
		end

		-- debug_show_all_globals(all)
		debug_log_step("solve_globals")
		-- repeat
		-- 	local n = solve_globals(all)
		-- until n == 0
		local n = #module_name_list * math.max(10, #module_name_list) + 10 -- 这里实际设置多少合适暂时没有理论依据，先偷个懒写大一点
		for i=1,n do -- 可以报异常，但不允许死循环(将直接引发服务器崩溃)
			if 0 == solve_globals(all) then
				break
			end
			if i == n then
				error("solve_globals: too many iterations, may have unsolved globals")
			end
		end
		check_unsolve_globals(all)

		debug_log_step("update_funcs")
		update_funcs(all)
		all = nil -- 避免被nnluavm.foreach遍历到
	end, debug.traceback)
	sandbox.clear() -- 清理，同时避免被nnluavm.foreach遍历到
	output_reload_step()

	if not ok2 then
		error(err)
	end
	-- 只有成功才做进一步自检，非强依赖
	if M.after_check_vm_dummy then
		-- 这里仅仅做自检，不作实质热更步骤，一般用于开发本模块的调试测试阶段，无须用于生产环境
		-- print(coroutine.running())
		local nnluavm = require("nnluavm")
		local has_err = false
		nnluavm.foreach(function(var, options)
			-- local mt = getmetatable(var)
			-- if ((mt == MT_GLOBAL_NAME) or (mt == MT_MODULE_NAME)) then
			if sandbox.isdummy(var) then
				print(getmetatable(var), "path:", options and options.path and table.concat(options.path, "->"))
				has_err = true
			end
		end, {path = {}})
		if has_err then
			defense_error("热更后虚拟机中仍包含dummy变量")
		end
	end
	reloading = false
	return ok2, err
end

return M
