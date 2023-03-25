--[[

Simple Lua benchmark that tests some CPU and I/O speed of a platform.

Some results collected below
                            dummy       float_mul   write file  read file   note
Intel i5-4590S 3GHz         28.1MC/s    26.9MC/s    36MB/s      256MB/s     Lua 5.1, Win7, SSD ADATA SU800
NodeMCU @ 80MHz             126kC/s     83kC/s	    44kB/s      574kB/s     Lua 5.1, NodeMCU 3.0.0.0 float
NodeMCU @ 160MHz            252kC/s     168kC/s	    48kB/s      973kB/s     Lua 5.1, NodeMCU 3.0.0.0 float
Linksys EA4500              2.03MC/s    1.5MC/s	    21MB/s      49MB/s      Lua 5.1, OpenWrt 22.03.3
Pixel 1 Lua 5.1             12.3MC/s    10.3MC/s    75MB/s      440MB/s     Lua 5.1, Android 10, Termux 1.37.0
Pixel 1 Lua 5.4             15.9MC/s    15.6MC/s    67MB/s      280MB/s     Lua 5.4, Android 10, Termux 1.37.0

]]--

-- multiple of these switches can be true at the same time
-- but not mutually contradictory, like IsWindows and IsLinux
local IsNodeMCU = false
local IsLinux = false
local IsOpenWrt = false
local IsAndroid = false
local IsWindows = false

local string_trim = function(str)
    str = str:gsub("%s+$", "")
    return str
end

local function exec(cmd)
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

local function cat (filepath)
    local f = io.open(filepath)
    if f == nil then return "" end
    local text = f:read("*a")
    f:close()
    return text
end

local function getKeyValue(text,key)
    local val = text:match('\n'..key..'="([^"]*)"')
    return val
end

local function getEtcOs(key)
    EtcOsReleaseText = EtcOsReleaseText or '\n' .. cat("/etc/os-release")
    return getKeyValue(EtcOsReleaseText,key)
end

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

local function testFloatMul()
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
local testWriteFileText = "0123456789ABCDEFGHIJKLMNOPQRSTUV0123456789ABCDEFGHIJKLMNOPQRSTU\n"

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

local function testReadFile()
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


print("dummy call " .. testDummyCall() .. " kC/s")
print("float mul  " .. testFloatMul() .. " kC/s")
print("write file " .. testWriteFile() .. " kB/s")
print("read file  " .. testReadFile() .. " kB/s")
