--[[

Simple Lua benchmark that tests some CPU and I/O speed of a platform.

I had some slow responses from NodeMCU HTTP GET taking between 0.5~10 seconds, so I was
wondering how fast ESP8266 was and compare to PC, router and phone. Turns out its quite
slow, @ 80MHz CPU is 200x slower than 2014 PC and 16x slower than 2012 router.

On NodeMCU disable init.lua, reset and run or compile to bench.lc with full heap, otherwise
compiler will run out of memory. Then reenable init.lua and reset.

Some results collected below
                            dummy   	float_mul	write file	read file	note
Intel i5-4590S 3GHz			28.1MC/s	26.9MC/s	36MB/s		256MB/s		Lua 5.1, Win7, SSD ADATA SU800
NodeMCU @ 80MHz             126kC/s    	83kC/s		44kB/s		574kB/s		Lua 5.1, NodeMCU 3.0.0.0 float
NodeMCU @ 160MHz            252kC/s    	168kC/s		48kB/s		973kB/s		Lua 5.1, NodeMCU 3.0.0.0 float
Linksys EA4500              2.03MC/s   	1.5MC/s		21MB/s		49MB/s		Lua 5.1, OpenWrt 22.03.3
Pixel 1						12.3MC/s	10.3MC/s	75MB/s		440MB/s		Lua 5.1, Android 10, Termux 1.37.0

TODO: cleanup this script

]]--

-- multiple of these switches can be true at the same time
-- but not mutually contradictory, like IsWindows and IsLinux
local IsNodeMCU = false
local IsLinux = false
local IsOpenWrt = false
local IsAndroid = false
local IsWindows = false


--[[
String enhancement library
--]]

-- Generate random string from provided set of characters
-- Set is string, e.g. "abcdef" or "a-f", if '-' is needed place first or last
--~ string.random = function (num, set)
--~ 	if not gRandomSeeded then
--~ 		math.randomseed(os.time() + math.floor(os.clock()*1e6))
--~ 		gRandomSeeded = true
--~ 	end
--~ 	local function expandRange (r)
--~ 		local s = ""
--~ 		for c=r:byte(1),r:byte(3) do s=s..string.char(c) end
--~ 		return s
--~ 	end
--~ 	set = (set or "0-9a-z"):gsub(".%-.", expandRange)
--~ 	local s = ""
--~ 	for i = 1, num do
--~ 		local ri = math.random(0,#set)
--~ 		s = s .. set:sub(ri, ri)
--~ 	end
--~ 	return s
--~ end

-- Convert string into array, see JavaScript String.split
-- Default comma separator
-- It wont work if separator contains '%'
string_split = function (str, sep)
	sep = string.gsub(sep or ',', '%%', '%%')
	str = str .. sep
	local pattern = "(.-)" .. sep:gsub('%.', '%%.')
	local t = {}
	for s in string.gmatch(str, pattern) do
		table.insert(t, s)
	end
	return t
end

-- Simple repr()
function repr(val)
	local map = {
		["boolean"] = tostring,
		["string"]  = function(v) return '"'..string.gsub(v,'"','\\"')..'"' end,
		["number"]  = tostring,
		["table"] 	= function() return "{}" end,
		["function"] = tostring,
		["nil"] 	= tostring
	}
	if map[type(val)] == nil then return '<' .. type(val) .. '>' end
	return map[type(val)](val)
end

-- convenient wrapper for string.format
function sprintf (str, ...)	
	if _VERSION >= "Lua 5.2" then
		return string.format(str,table.unpack(arg))
	end
	return string.format(str,unpack(arg))
end

-- sprintf + expansion of variables
-- expandVars(str) 			-> expand (A) environment and globals, e.g. $_G.varname or `_E.varname:format`
-- expandVars(str,vars)		-> expand (A) + local variables from table 'vars', e.g. `varname:format`

function expandVars (str, ...)
	local vars = {}
	while (arg.n == 1) and (type(arg[1]) == "table") and (type(arg[1][1]) ~= "nil") do arg = arg[1] end
	if type(arg[1]) == "table" then
		vars = arg[1]
		table.remove(arg, 1)
		arg.n = arg.n - 1
	end
	local function formatSingle(fmt, val)
--debugPrintf("formatSingle:", fmt, val)
		if string.find(fmt, '[xXdD]') then val=math.floor(tonumber(val)) end
		return string.format(fmt, val)
	end
	local function expandSingle(str)
		local fmt = "%s"
		if str:sub(1,1) == '`' then
			str = str:sub(2,#str-1)
		else
			str = str:sub(2,#str)
		end
		local key = str
		local a = string_split(str, ':')
		if #a > 1 then key = a[1] fmt = '%'..a[2] end
--debugPrintf("format:", fmt)
		if vars[key] ~= nil then return formatSingle(fmt, vars[key]) end
--~ 		if key:sub(1,3) == '_G.' then key = key:sub(4,#str) return formatSingle(fmt, _G[key]) end
		if _G[key] ~= nil then return formatSingle(fmt, _G[key]) end
--~ 		if key:sub(1,3) == '_E.' then key = key:sub(4,#str) return formatSingle(fmt, os.getenv(key)) end
		if os.getenv(key) ~= nil then return formatSingle(fmt, os.getenv(key)) end
		return "<nil>"
	end
	str = string.gsub(str, "%$[A-Za-z0-9_.:]+", expandSingle)
	str = string.gsub(str, "`.+`", expandSingle)
	if arg.n > 0 then
		if _VERSION >= "Lua 5.2" then
			str = string.format(str,table.unpack(arg))
		end
		str = string.format(str,unpack(arg))
	end
	return str
end


function printf (str, ...)
	str = expandVars(str, arg)
--~ 	if not ISCGI then
	if IsNodeMCU then
		print(str)
	else
		io.write(str)
	end
--~ 	else
--~ 		if Html == nil then Html = {} end
--~ 		Html[#Html+1] = str
--~ 	end
end


string_trim = function(str)
	str = str:gsub("%s+$", "")
	return str
end

function exec(cmd)
	local handle = io.popen(cmd)
	local output = string_trim(handle:read("*a"))
	handle:close()
	handle = io.popen("echo $?")
	local retval = tonumber(handle:read("*a"))
	handle:close()
	if 0 == retval then
		return output
	end
	return ""
end

function cat (filepath)
--print("cat " .. filepath)
	local f = io.open(filepath)
	if f == nil then return "" end
	local text = f:read("*a")
	f:close()
	return text
end

function getKeyValue(text,key)
	local val = text:match('\n'..key..'="([^"]*)"')
	return val
end

function getEtcOs(key)
	EtcOsReleaseText = EtcOsReleaseText or '\n' .. cat("/etc/os-release")
	return getKeyValue(EtcOsReleaseText,key)
end


-- fs.remove = os.remove = io.remove
-- fs.open = io.open
-- fs.close = io.close


local function init ()
    if not os then
        if tmr then 
            function getMicroTime() return tmr.now() end
            IsNodeMCU = true
            fs = file
        else
            error("Unsupported platform. Aborting")
        end
    elseif os ~= nil then
        function getMicroTime() return math.floor(os.clock()*1000000) end
        fs = { remove=os.remove, open=io.open }
        if os.getenv("WinDir") then
            IsWindows = true
        else
            local osname = exec("uname -o")
            if osname == "Android" then
                IsAndroid = true
            else
                IsLinux = true
				IsOpenWrt = getEtcOs("NAME") == "OpenWrt"
            end
        end
    end
end

init()

local testWriteFileText = "0123456789ABCDEFGHIJKLMNOPQRSTUV0123456789ABCDEFGHIJKLMNOPQRSTU\n"
local function testWriteFile(size)
    local start = getMicroTime()
    f:close()
    return getMicroTime() - start
end

--[[
    main
]]--

function testDummyCall()
    local duration
    local start, count = getMicroTime(), 0
    local function dummy() end
    repeat
        for i=1,1000 do dummy() end -- loop/call overhead
        count = count + 1
        duration = getMicroTime() - start
    until duration >= 200000
    return math.floor(count*1000000/duration)
end

function testFloatMul()
    local duration
    local start, count = getMicroTime(), 0
    local function float_mul(x) return 3.14159 * x end
    repeat
        for i=1,1000 do float_mul(i) end
        count = count + 1
        duration = getMicroTime() - start
    until duration >= 200000
    return math.floor(count*1000000/duration)
end

local TEST_FILENAME = "testfile"
local IoBlkSz = 4096
local IoFileSize = 0

function testWriteFile()
    local duration
    fs.remove(TEST_FILENAME)
    local maxsize = 1024*1024
	if not (IsOpenWrt or IsNodeMCU) then maxsize = maxsize * 128 end
    IoBlkSz = IsNodeMCU and 4096 or 65536
    local f = fs.open(TEST_FILENAME, "a")
    local start = getMicroTime()
    for i=1,IoBlkSz,#testWriteFileText do
        f:write(testWriteFileText)
    end
--	f:flush()
    duration = getMicroTime() - start
    if IsNodeMCU and duration < 20000 then
        print("Something wrong with file.write, aborting test")
        f:close()
        fs.remove(TEST_FILENAME)
        return 0
    end
    IoFileSize = IoBlkSz
--~     if duration < 1000 then
--~         -- increase single write block to 64k
--~         local small = testWriteFileText
--~         for i=1,63 do testWriteFileText=testWriteFileText..small end
--~         small = testWriteFileText
--~         for i=1,15 do testWriteFileText=testWriteFileText..small end
--~         IoBlkSz = 1024*1024
--~     end
    start = getMicroTime()
    repeat
        for i=1,IoBlkSz,#testWriteFileText do
            f:write(testWriteFileText)
        end
        duration = getMicroTime() - start
        IoFileSize = IoFileSize + IoBlkSz
    until (IoFileSize >= maxsize) or (duration >= 2000000)
    f:flush()
    f:close()
	duration = getMicroTime() - start
    return math.floor(IoFileSize*1000/duration) -- kB/s
end

   
-- read file

function testReadFile()
    local f = fs.open(TEST_FILENAME, "r")
    if not f then
        print("Test file does not exist")
        return 0
    end
    IoBlkSz = 1024
    f:flush()
    --local size = 0
    local start = getMicroTime()
    for i=1,IoFileSize,IoBlkSz do
        local blk = f:read(IoBlkSz)
        blk = nil
    end
    local duration = getMicroTime() - start
--    fs.remove(TEST_FILENAME)
    return math.floor(IoFileSize*1000/duration) -- kB/s"
end


printf("dummy call %d kC/s\n", testDummyCall())
printf("float mul  %d kC/s\n", testFloatMul())
printf("write file %d kB/s\n", testWriteFile())
printf("read file  %d kB/s\n", testReadFile())
