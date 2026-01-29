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
  "table",
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

local SCREEN_W, SCREEN_H = 40, 24
local screenX, screenY = 0, 0
local running = true

local mmu = {
  ram = {},
  immutable = {},

  reset = function(self)
    self.ram[_c.KBDCR] = 0
    self.ram[_c.DSPCR] = 0x04
    self.ram[_c.DSP]   = 0
    self.ram[_c.KBD]   = 0x80
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
      if ((t.ram[_c.DSPCR] or 0) & 0x04) == 0x04 then
        t.ram[_c.DSP] = (v & 0x7F) | 0x80
        t.ram[_c.DSPCR] = (t.ram[_c.DSPCR] or 0) & (~0x04)
      end
      return
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
mmu:reset()
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

MC.initscr()
MC.cbreak()
MC.noecho()
MC.nonl()
MC.clear()
MC.refresh()

posix.fcntl(stdin_fd, posix.F_SETFL, orig_flags | posix.O_NONBLOCK)

local screen = {}
for y = 1, SCREEN_H do
  screen[y] = (" "):rep(SCREEN_W)
end

local function redraw_all()
  MC.clear()
  for y = 0, SCREEN_H - 1 do
    MC.mvaddstr(y, 0, screen[y + 1])
  end
  MC.refresh()
end

local function scroll_up_1()
  table.remove(screen, 1)
  table.insert(screen, (" "):rep(SCREEN_W))
  redraw_all()
end

local function newline()
  screenX = 0
  screenY = screenY + 1
  if screenY >= SCREEN_H then
    scroll_up_1()
    screenY = SCREEN_H - 1
  end
end

local function put_char(byte)
  local line = screen[screenY + 1]
  screen[screenY + 1] = line:sub(1, screenX) .. string.char(byte) .. line:sub(screenX + 2)
  MC.move(screenY, screenX)
  MC.addstr(string.char(byte))
  screenX = screenX + 1
  if screenX >= SCREEN_W then
    newline()
  end
end

local function read_byte_nonblocking()
  local s = posix.read(stdin_fd, 1)
  if not s or #s == 0 then return nil end
  return s:byte(1)
end

local function checkForInput()
  if mmu[_c.KBDCR] ~= 0x27 then return end
  local c = read_byte_nonblocking()
  if not c or c <= 0 or c >= 256 then return end

  c = c & 0x7F
  if c >= 0x61 and c <= 0x7A then c = c & 0x5F end
  if c >= 0x60 then return end

  mmu[_c.KBD] = c | 0x80
  mmu[_c.KBDCR] = 0xA7
end

local function updateScreen()
  local dsp = mmu.ram[_c.DSP]
  if (dsp & 0x80) ~= 0x80 then return end

  dsp = dsp & 0x7F
  local ch = dsp
  if dsp >= 0x60 and dsp <= 0x7F then ch = dsp & 0x5F end

  if ch == 0x0D or ch == 0x0A then
    newline()
  else
    if ch >= 0x20 and ch <= 0x5F then
      put_char(ch)
    end
  end

  MC.move(screenY, screenX)
  mmu.ram[_c.DSP] = dsp
  mmu.ram[_c.DSPCR] = (mmu.ram[_c.DSPCR] or 0) | 0x04
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
  redraw_all()
  MC.move(screenY, screenX)
  MC.refresh()

  while running do
    cpu:step()
    checkForInput()
    updateScreen()
  end
end

local ok = xpcall(main, err_handler)
restore_terminal()
if not ok then os.exit(2) end
