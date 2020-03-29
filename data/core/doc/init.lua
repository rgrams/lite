local Object = require "core.object"
local config = require "core.config"
local common = require "core.common"
local Selection = require "core.selection"


local Doc = Object:extend()


local function split_lines(text)
  local res = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(res, line)
  end
  return res
end


local function splice(t, at, remove, insert)
  insert = insert or {}
  local offset = #insert - remove
  local old_len = #t
  local new_len = old_len + offset
  if offset < 0 then
    for i = at - offset, old_len - offset do
      t[i + offset] = t[i]
    end
  elseif offset > 0 then
    for i = old_len, at, -1 do
      t[i + offset] = t[i]
    end
  end
  for i, item in ipairs(insert) do
    t[at + i - 1] = item
  end
end


function Doc:new(filename)
  self:reset()
  if filename then
    self:load(filename)
  end
end


function Doc:reset()
  self.lines = { "\n" }
  self.selections = { Selection(self) }
  self.undo_stack = { idx = 1 }
  self.redo_stack = { idx = 1 }
  self.clean_change_id = 1
end


function Doc:load(filename)
  local fp = assert( io.open(filename, "rb") )
  self:reset()
  self.filename = filename
  self.lines = {}
  for line in fp:lines() do
    if line:byte(-1) == 13 then
      line = line:sub(1, -2)
      self.crlf = true
    end
    table.insert(self.lines, line .. "\n")
  end
  if #self.lines == 0 then
    table.insert(self.lines, "\n")
  end
  fp:close()
end


function Doc:save(filename)
  filename = filename or assert(self.filename, "no filename set to default to")
  local fp = assert( io.open(filename, "wb") )
  for _, line in ipairs(self.lines) do
    if self.crlf then line = line:gsub("\n", "\r\n") end
    fp:write(line)
  end
  fp:close()
  self.filename = filename or self.filename
  self:clean()
end


function Doc:get_name()
  return self.filename or "unsaved"
end


function Doc:is_dirty()
  return self.clean_change_id ~= self:get_change_id()
end


function Doc:clean()
  self.clean_change_id = self:get_change_id()
end


function Doc:get_change_id()
  return self.undo_stack.idx
end


function Doc:set_selection(line1, col1, line2, col2, swap, idx)
  assert(not line2 == not col2, "expected 2 or 4 arguments")
  idx = idx or 1
  assert(idx > 0 and idx <= #self.selections, "out-of-range index: '" .. idx .. "'")
  local selection = self.selections[idx]
  selection:set(line1, col1, line2, col2, swap)
end


local function sort_positions(line1, col1, line2, col2)
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    return line2, col2, line1, col1, true
  end
  return line1, col1, line2, col2, false
end


function Doc:selection_contains(line)
  for i,selection in ipairs(self.selections) do
    if selection:contains(line) then
      return true
    end
  end
end


function Doc:get_selection_ranges(sort)
  local out = {}
  for i,selection in ipairs(self.selections) do
    table.insert(out, {selection:get(sort)})
  end
  return out
end


function Doc:get_selection(sort)
  return self.selections[1]:get(sort)
end


function Doc:has_selection()
  return self.selections[1]:exists()
end


function Doc:sanitize_selection()
  for i,selection in ipairs(self.selections) do
    selection:set(selection:get())
  end
end


function Doc:sanitize_position(line, col)
  line = common.clamp(line, 1, #self.lines)
  col = common.clamp(col, 1, #self.lines[line])
  return line, col
end


local function position_offset_func(self, line, col, fn, ...)
  line, col = self:sanitize_position(line, col)
  return fn(self, line, col, ...)
end


local function position_offset_byte(self, line, col, offset)
  line, col = self:sanitize_position(line, col)
  col = col + offset
  while line > 1 and col < 1 do
    line = line - 1
    col = col + #self.lines[line]
  end
  while line < #self.lines and col > #self.lines[line] do
    col = col - #self.lines[line]
    line = line + 1
  end
  return self:sanitize_position(line, col)
end


local function position_offset_linecol(self, line, col, lineoffset, coloffset)
  return self:sanitize_position(line + lineoffset, col + coloffset)
end


function Doc:position_offset(line, col, ...)
  if type(...) ~= "number" then
    return position_offset_func(self, line, col, ...)
  elseif select("#", ...) == 1 then
    return position_offset_byte(self, line, col, ...)
  elseif select("#", ...) == 2 then
    return position_offset_linecol(self, line, col, ...)
  else
    error("bad number of arguments")
  end
end


function Doc:get_text(line1, col1, line2, col2)
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
  if line1 == line2 then
    return self.lines[line1]:sub(col1, col2 - 1)
  end
  local lines = { self.lines[line1]:sub(col1) }
  for i = line1 + 1, line2 - 1 do
    table.insert(lines, self.lines[i])
  end
  table.insert(lines, self.lines[line2]:sub(1, col2 - 1))
  return table.concat(lines)
end


function Doc:get_char(line, col)
  line, col = self:sanitize_position(line, col)
  return self.lines[line]:sub(col, col)
end


local push_undo

local function insert(self, undo_stack, time, line, col, text)
  line, col = self:sanitize_position(line, col)

  -- split text into lines and merge with line at insertion point
  local lines = split_lines(text)
  local before = self.lines[line]:sub(1, col - 1)
  local after = self.lines[line]:sub(col)
  for i = 1, #lines - 1 do
    lines[i] = lines[i] .. "\n"
  end
  lines[1] = before .. lines[1]
  lines[#lines] = lines[#lines] .. after

  -- splice lines into line array
  splice(self.lines, line, 1, lines)

  -- push undo
  local line2, col2 = self:position_offset(line, col, #text)
  push_undo(self, undo_stack, time, "selection", self:get_selection())
  push_undo(self, undo_stack, time, "remove", line, col, line2, col2)
end


local function remove(self, undo_stack, time, line1, col1, line2, col2)
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)

  -- push undo
  local text = self:get_text(line1, col1, line2, col2)
  push_undo(self, undo_stack, time, "selection", self:get_selection())
  push_undo(self, undo_stack, time, "insert", line1, col1, text)

  -- get line content before/after removed text
  local before = self.lines[line1]:sub(1, col1 - 1)
  local after = self.lines[line2]:sub(col2)

  -- splice line into line array
  splice(self.lines, line1, line2 - line1 + 1, { before .. after })
end


function Doc:insert(...)
  insert(self, self.undo_stack, system.get_time(), ...)
  self:sanitize_selection()
  self.redo_stack = { idx = 1 }
end


function Doc:remove(...)
  remove(self, self.undo_stack, system.get_time(), ...)
  self:sanitize_selection()
  self.redo_stack = { idx = 1 }
end


function push_undo(self, undo_stack, time, type, ...)
  undo_stack[undo_stack.idx] = { type = type, time = time, ... }
  undo_stack[undo_stack.idx - config.max_undos] = nil
  undo_stack.idx = undo_stack.idx + 1
end


local function pop_undo(self, undo_stack, redo_stack)
  -- pop command
  local cmd = undo_stack[undo_stack.idx - 1]
  if not cmd then return end
  undo_stack.idx = undo_stack.idx - 1

  -- handle command
  if cmd.type == "insert" then
    insert(self, redo_stack, cmd.time, table.unpack(cmd))

  elseif cmd.type == "remove" then
    remove(self, redo_stack, cmd.time, table.unpack(cmd))

  elseif cmd.type == "selection" then
    local selection = self.selections[1]
    selection.a.line, selection.a.col = cmd[1], cmd[2]
    selection.b.line, selection.b.col = cmd[3], cmd[4]
  end

  -- if next undo command is within the merge timeout then treat as a single
  -- command and continue to execute it
  local next = undo_stack[undo_stack.idx - 1]
  if next and math.abs(cmd.time - next.time) < config.undo_merge_timeout then
    return pop_undo(self, undo_stack, redo_stack)
  end
end


function Doc:undo()
  pop_undo(self, self.undo_stack, self.redo_stack)
end


function Doc:redo()
  pop_undo(self, self.redo_stack, self.undo_stack)
end


function Doc:text_input(text)
  if self:has_selection() then
    self:delete_to()
  end
  for i,range in ipairs(self:get_selection_ranges()) do
    self:insert(range[1], range[2], text)
    self:move_to(#text)
  end
end


function Doc:replace(fn)
  for i,range in ipairs(self:get_selection_ranges(true)) do
    local line1, col1, line2, col2, swap = table.unpack(range)
    local old_text = self:get_text(line1, col1, line2, col2)
    local new_text, n = fn(old_text)
    if old_text ~= new_text then
      self:insert(line2, col2, new_text)
      self:remove(line1, col1, line2, col2)
      local had_selection = not (line1 == line2 and col1 == col2)
      if had_selection then
        line2, col2 = self:position_offset(line1, col2, #new_text)
        self:set_selection(line1, col1, line2, col2, swap, i)
      end
    end
  end
  return n
end


function Doc:delete_to(...)
  for i,range in ipairs(self:get_selection_ranges(true)) do
    local line1, col1, line2, col2, swap = table.unpack(range)
    local had_selection = not (line1 == line2 and col1 == col2)
    if had_selection then
      self:remove(line1, col1, line2, col2)
    else
      line2, col2 = self:position_offset(line1, col1, ...)
      self:remove(line1, col1, line2, col2)
      line1, col1 = sort_positions(line1, col1, line2, col2)
    end
    self:set_selection(line1, col1, nil, nil, nil, i)
  end
end


function Doc:move_to(...)
  for i,range in ipairs(self:get_selection_ranges(true)) do
    local line, col = range[1], range[2]
    line, col = self:position_offset(line, col, ...)
    self:set_selection(line, col, nil, nil, nil, i)
  end
end


function Doc:select_to(...)
  for i,range in ipairs(self:get_selection_ranges()) do
    local line, col, line2, col2 = table.unpack(range)
    line, col = self:position_offset(line, col, ...)
    self:set_selection(line, col, line2, col2, nil, i)
  end
end

return Doc
