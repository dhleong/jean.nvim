---@class Buffer
---@field bufnr number
---@field session Session
---@field vars table
---@field o vim.bo
local Buffer = {}

function Buffer:from_nr(bufnr)
  local instance = {
    bufnr = bufnr,
    o = vim.bo[bufnr],
    vars = setmetatable({}, {
      __index = function(_, k)
        return vim.b[bufnr][k]
      end,
      __newindex = function(_, k, v)
        vim.b[bufnr][k] = v
      end,
    }),
  }
  setmetatable(instance, self)
  -- self.__index = self
  return instance
end

function Buffer:__index(key)
  print('__index', key)
  if key == 'session' then
    return require 'jean.session'.from_buffer(self.bufnr)
  else
    return rawget(Buffer, key)
  end
end

---@param lines string[]
function Buffer:append_lines(lines)
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

function Buffer:move_cursor_to_end()
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ''
  local win = require 'jean.window'.for_session_id(self.vars.jean_session_id)
  if win then
    vim.api.nvim_win_set_cursor(win.winnr, { line_count, #last_line })
  end
end

return Buffer
