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

function Buffer:move_cursor_to_end()
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ''
  local win = self:window()
  if win and win.winnr then
    vim.api.nvim_win_set_cursor(win.winnr, { line_count, #last_line })
  end
end

---Return the associated Session Window, if any
---@return Window|nil
function Buffer:session_window()
  return require('jean.window').for_session_id(self.vars.jean_session_id)
end

---Return "some" window
---@return Window|nil
function Buffer:window()
  local session_win = self:session_window()
  if session_win then
    return session_win
  end

  -- TODO: ...
end

return Buffer
