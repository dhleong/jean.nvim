---@class Buffer
---@field bufnr number
---@field session Session
---@field vars table
---@field o vim.bo
local Buffer = {}

---Table of getter properties for Buffer instances
---@type table<string, fun(number): any>
local Getters = {
  o = function(bufnr)
    return vim.bo[bufnr]
  end,
  session = function(bufnr)
    return require('jean.session').from_buffer(bufnr)
  end,
  vars = function(bufnr)
    return vim.b[bufnr]
  end,
}

---@return Buffer
function Buffer:from_nr(bufnr)
  local instance = { bufnr = bufnr }
  setmetatable(instance, self)
  return instance
end

function Buffer:__index(key)
  local getter = Getters[key]
  if getter then
    return getter(self.bufnr)
  else
    return rawget(Buffer, key)
  end
end

---@param lines string[]|string
function Buffer:append_lines(lines)
  if type(lines) == 'string' then
    lines = vim.split(lines, '\n')
  end
  local was_modifiable = self.o.modifiable
  self.o.modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  self.o.modifiable = was_modifiable
end

---@param start_line number
---@param end_line number
function Buffer:delete_lines(start_line, end_line)
  local was_modifiable = self.o.modifiable
  self.o.modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, start_line, end_line, false, {})
  self.o.modifiable = was_modifiable
end

---@return string[]
function Buffer:get_lines()
  return vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
end

---Returns a relative path string if this buffer's file lives under
---relative_root, else the absolute path to this buffer's file
---@path relative_root string
---@return string
function Buffer:get_relative_path(relative_root)
  local absolute_path = vim.api.nvim_buf_get_name(self.bufnr)
  if vim.startswith(absolute_path, relative_root) then
    return '.' .. string.sub(absolute_path, #relative_root + 1)
  end
  return absolute_path
end

---Return the associated Session Window, if any active and valid
---@return Window|nil
function Buffer:session_window()
  return require('jean.window').for_session_id(self.vars.jean_session_id)
end

return Buffer
