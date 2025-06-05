---@class Tooltip
---@field buffer Buffer
---@field bufnr number
---@field winnr number
---@field _cursor_autocmd_id number
local Tooltip = {}

---@return Tooltip
function Tooltip:new()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local enter_window = false
  local winnr = vim.api.nvim_open_win(bufnr, enter_window, {
    relative = 'cursor',
    style = 'minimal',
    focusable = false,
    zindex = 99,
    width = 1,
    height = 1,
    row = -1,
    col = 0,
  })

  local instance = {
    buffer = require('jean.buffer'):from_nr(bufnr),
    bufnr = bufnr,
    winnr = winnr,
  }

  instance._cursor_autocmd_id = vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    callback = function()
      -- Being a bit defensive here; we *shouldn't* get called, but just in case
      if self.winnr == 0 then
        vim.api.nvim_del_autocmd(instance._cursor_autocmd_id)
        return
      end

      vim.api.nvim_win_set_config(winnr, {
        relative = 'cursor',
        row = -1,
        col = 0,
      })
    end,
  })

  setmetatable(instance, self)
  self.__index = self
  return instance
end

function Tooltip:destroy()
  if self.winnr == 0 then
    -- nop
    return
  end

  vim.api.nvim_win_close(self.winnr, true)
  vim.api.nvim_buf_delete(self.bufnr, { force = true })
  vim.api.nvim_del_autocmd(self._cursor_autocmd_id)
  self.winnr = 0
  self.bufnr = 0
end

return Tooltip
