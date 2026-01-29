#!/usr/bin/env lua5.4

local function addRelPath(dir)
  local spath =
      debug.getinfo(1, "S").source
        :sub(2)
        :gsub("^([^/])", "./%1")
        :gsub("[^/]*$", "")
  dir = dir and (dir .. "/") or ""
  spath = spath .. dir

  package.path =
      spath .. "?.lua;"
    .. spath .. "?/init.lua;"
    .. package.path
end

addRelPath("..")

local _ENV = require("std.normalize") {
  "std.strict",
  "const",
  "io",
  "os",
  "debug",
  "string",
}

local MC    = require("minicurses")
local posix = require("posix")

local _6502 = require("6502")
local cpu = _6502:new()

-- Per Apple-1 Operation Manual (1976)
local _c = const {
  DSPCR = 0xd013,
  DSP   = 0xd012,
  KBDCR = 0xd011,
  KBD   = 0xd010,
}

local screenX, screenY = 0, 0
local running = true

local mmu = {
  ram = {},
  immutable = {},

  reset = function()
    mmu.ram[_c.KBDCR] = 0
    mmu.ram[_c.DSPCR] = 0
    mmu.ram[_c.DSP]   = 0
    mmu.ram[_c.KBD]   = 0x80
  end,
}

local mmu_metatable = {
  __index = function(t, address)
    if address == _c.KBD then
      t.ram[_c.KBDCR] = 0x27
      return t.ram[_c.KBD]
    end
    return t.ram[address] or 0
  end,

  __newindex = function(t, address, v)
    if address == _c.DSP then
      if (t.ram[_c.DSPCR] & 0x04) == 0x04 then
        t.ram[_c.DSP] = v
        return
      end
    end

    if address == _c.KBDCR then
      if t.ram[_c.KBDCR] == 0 then
        v = 0x27
      end
      t.ram[_c.KBDCR] = v
      return
    end

    if t.immutable[address] then
      assert(false, "Tried to write to ROM")
      return
    end

    t.ram[address] = v
  end,
}

setmetatable(mmu, mmu_metatable)
cpu.ram = mmu

-- Load the monitor ROM @ 0xFF00
do
  local f = assert(io.open("monitor.rom", "rb"), "Can't open monitor.rom")
  local data = f:read("*a")
  f:close()
  assert(#data == 256)
  for i = 0, #data - 1 do
    cpu:writemem(0xFF00 + i, data:byte(i + 1))
    mmu.immutable[0xFF00 + i] = true
  end
end

-- Load the basic ROM @ 0xE000
do
  local f = assert(io.open("basic.rom", "rb"), "Can't open basic.rom")
  local data = f:read("*a")
  f:close()
  assert(#data == 4096)
  for i = 0, #data - 1 do
    cpu:writemem(0xE000 + i, data:byte(i + 1))
    mmu.immutable[0xE000 + i] = true
  end
end

cpu:init()
mmu.ram[_c.KBDCR] = 0
mmu.ram[_c.DSPCR] = 0
mmu.ram[_c.DSP]   = 0
mmu.ram[_c.KBD]   = 0x80

cpu:rst()

local stdin_fd = posix.fileno(io.stdin)
local orig_flags = posix.fcntl(stdin_fd, posix.F_GETFL, 0)

local function restore_terminal()
  pcall(function()
    posix.fcntl(stdin_fd, posix.F_SETFL, orig_flags)
  end)
  pcall(function()
    MC.endwin()
  end)
end

local LINES, COLS = MC.initscr()
MC.cbreak()
MC.noecho()
MC.nonl()
MC.clear()
MC.refresh()

-- emulate stdscr:nodelay(true)
posix.fcntl(stdin_fd, posix.F_SETFL, orig_flags | posix.O_NONBLOCK)

local function read_byte_nonblocking()
  local s, err = posix.read(stdin_fd, 1)
  if not s then    -- EAGAIN / EWOULDBLOCK: no input available
    return nil
  end
  if #s == 0 then
    return nil
  end
  return s:byte(1)
end

local function checkForInput()
  local ret = false

  if mmu[_c.KBDCR] == 0x27 then -- can handle input
    local c = read_byte_nonblocking()
    if c and c > 0 and c < 256 then
      c = c & 0x7F
      if c >= 0x61 and c <= 0x7A then c = c & 0x5F end -- lower -> upper
      if c < 0x60 then
        mmu[_c.KBD] = c | 0x80 -- write kbd
        mmu[_c.KBDCR] = 0xA7  -- write KbdCr
        ret = true
      end
    end
  end

  return ret
end

local function updateScreen()
  local dsp = mmu[_c.DSP]

  -- High bit indicates something waiting to display
  if (dsp & 0x80) == 0x80 then
    dsp = dsp & 0x7F
    local tmp = dsp

    if dsp >= 0x60 and dsp <= 0x7F then
      tmp = tmp & 0x5F
    end

    if tmp == 0x0D then
      -- return key
      screenX = 0
      screenY = screenY + 1
    else
      if tmp >= 0x20 and tmp <= 0x5F then
         MC.move(screenY, screenX)
         MC.addstr(string.char(tmp))
         screenX = screenX + 1
      end
    end

    if screenX == 40 then
      screenX = 0
      screenY = screenY + 1
    end

    if screenY == 24 then
      MC.scrl(1)
      screenY = 23
    end

    -- draw cursor
    MC.move(screenY, screenX)

    mmu[_c.DSP] = dsp -- write to dsp (clears hi bit)
  end

  MC.refresh()
end

local function err_handler(errmsg)
  restore_terminal()
  local msg = tostring(errmsg or "(nil error object)")
  io.stderr:write("Caught an error: ", msg, "\n")
  io.stderr:write(debug.traceback(msg, 2), "\n")
  os.exit(2)
end

local function main()
  while running do
    -- local pc = cpu.pc -- left here if you want to inspect it later
    -- local o  = cpu:readmem(cpu.pc)

    cpu:step()
    checkForInput()
    updateScreen()
  end
end

local ok = xpcall(main, err_handler)
if not ok then
   os.exit(2)
end
restore_terminal()
if not ok then os.exit(2) end
