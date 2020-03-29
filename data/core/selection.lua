local Object = require "core.object"
local core = require "core"


local Selection = Object:extend()


function Selection:new(doc, line1, col1, line2, col2)
  self.doc = doc
  self.a = { line = line1 or 1, col = col1 or 1 }
  self.b = { line = line2 or 1, col = col2 or 1 }
end


function Selection:set(line1, col1, line2, col2, swap)
  local l1, c1, l2, c2 = line1, col1, line2, col2
  assert(not line2 == not col2, "expected 2 or 4 arguments")
  if swap then line1, col1, line2, col2 = line2, col2, line1, col1 end
  line1, col1 = self.doc:sanitize_position(line1, col1)
  line2, col2 = self.doc:sanitize_position(line2 or line1, col2 or col1)
  self.a.line, self.a.col = line1, col1
  self.b.line, self.b.col = line2, col2
end


local function is_before(line1, col1, line2, col2)
  return line1 < line2 or (line1 == line2 and col1 < col2)
end


local function sort_positions(line1, col1, line2, col2)
  if not is_before(line1, col1, line2, col2) then
    return line2, col2, line1, col1, true
  end
  return line1, col1, line2, col2, false
end


function Selection:get(sort)
  if sort then
    return sort_positions(self.a.line, self.a.col, self.b.line, self.b.col)
  end
  return self.a.line, self.a.col, self.b.line, self.b.col
end


function Selection:contains(line, col)
  local l1, c1, l2, c2 = self:get(true)
  return is_before(l1, c1, line, col or math.huge) and is_before(line, col or 0, l2, c2)
end


function Selection:exists()
  return not (self.a.line == self.b.line and self.a.col == self.b.col)
end


return Selection
