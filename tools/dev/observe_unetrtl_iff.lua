-- Append to the private Battleship driver with --observer. Read-only I/O
-- taps survive MMU remaps and instruction-cache fetches. ISA_OPEN samples
-- IFF2 before DI and writes SAVE_IFF before OUT (#1FFD),#11; this observes
-- that saved state on every real open, including reopen after each delay.
-- BS_DLL_SYM must describe the exact DLL under test at ORG 0.
do
  local m = manager.machine
  local c = m.devices[":maincpu"]
  local p = c.spaces["program"]
  local offsets, samples, counts = {}, {}, {}
  local file = assert(os.getenv("BS_DLL_SYM"), "BS_DLL_SYM is required")
  for line in io.lines(file) do
    local n, v = line:match("^(%S+): EQU 0x(%x+)")
    if n then offsets[n] = tonumber(v, 16) end
  end
  local last_close, noted = nil, 0
  local tap = c.spaces["io"]:install_write_tap(0x1FFD, 0x1FFD, "unetrtl-iff", function(_, data)
    local pc = c.state["PC"].value
    local base = (pc & 0xC000) + 0x20
    if pc >= base + offsets["ISA.ISA_OPEN"] and pc < base + offsets["ISA.ISA_CLOSE"] then
      if data == 0x11 then
        local saved = p:read_u8(base + offsets["ISA.SAVE_IFF"])
        local sp = c.state["SP"].value
        local ret = p:read_u16(sp + 4)
        local key = string.format("SAVE_IFF=%d caller=%04X", saved, ret)
        counts[key] = (counts[key] or 0) + 1
        -- Keep every disabled reopen plus a few enabled controls.
        if #samples < 128 and (saved == 0 or noted < 5) then
          samples[#samples + 1] = string.format("%.9f SAVE_IFF=%d IFF1=%d IFF2=%d PC=%04X caller=%04X parent=%04X closed_s=%.9f",
            m.time:as_double(), saved, c.state["IFF1"].value, c.state["IFF2"].value,
            pc, ret, p:read_u16(sp + 6), last_close and m.time:as_double() - last_close or 0)
          noted = noted + 1
        end
      end
    elseif pc >= base + offsets["ISA.ISA_CLOSE"] and pc < base + offsets["UTIL.DELAY_1MS"] and data == 1 then
      last_close = m.time:as_double()
    end
    return data
  end)
  emu.register_stop(function()
    local out = assert(io.open(os.getenv("BS_REPORT") .. ".iff.txt", "w"))
    out:write("DLL symbols: " .. file .. "\n")
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out:write(k .. "=" .. counts[k] .. "\n") end
    out:write(table.concat(samples, "\n") .. "\n")
    out:close()
    tap:remove()
  end)
end
