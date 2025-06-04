local M = {
  _by_session = {},
}

---@param buf Buffer
local function configure_buffer(buf)
  buf.o.filetype = 'markdown'

  -- Initialize content
  buf:append_lines({ require('jean.config').request_separator, '', '' })
  buf:delete_lines(0, 1)

  vim.keymap.set('n', 'q', function()
    local session_id = buf.vars.jean_session_id
    local window = M._by_session[session_id]
    if window then
      window:hide()
    end
  end, { buffer = buf.bufnr, desc = 'Hide the window' })

  vim.keymap.set({ 'i', 'n' }, '<cr>', function()
    if vim.fn.mode() ~= 'n' then
      vim.cmd.stopinsert()
    end

    -- Extract the new prompt, if any
    local separator = require('jean.config').request_separator
    local all_lines = buf:get_lines()
    ---@type string[]|nil
    local prompt_lines = nil
    for i = #all_lines, 1, -1 do
      local line = all_lines[i]
      if line == separator then
        prompt_lines = vim.list_slice(all_lines, i + 1)
        break
      end
    end

    if not prompt_lines then
      return
    end
    local text = vim.trim(table.concat(prompt_lines, '\n'))
    if not text or #text == 0 then
      return
    end

    buf.session:submit_prompt(text)
  end, { buffer = buf.bufnr, desc = 'Submit prompt' })

  vim.schedule(function()
    -- Move cursor to end *later* since the window "doesn't exist" yet
    buf:move_cursor_to_end()
  end)
end

---@class Window
---@field session_id string
---@field bufnr number
---@field winnr number|nil
---@field buffer Buffer
local Window = {}

function Window:new(opts)
  local instance = vim.tbl_extend('keep', {}, opts)
  setmetatable(instance, self)
  self.__index = self

  if not instance.bufnr then
    self.bufnr = vim.api.nvim_create_buf(false, true)
    self.buffer = require('jean.buffer'):from_nr(self.bufnr)
    self.buffer.vars.jean_session_id = opts.session_id

    configure_buffer(self.buffer)
  end

  return instance
end

function Window:hide()
  if self.winnr and vim.api.nvim_win_is_valid(self.winnr) then
    vim.api.nvim_win_hide(self.winnr)
    self.winnr = nil
  end
end

function Window:show()
  if self.winnr and vim.api.nvim_win_is_valid(self.winnr) then
    -- Already open
    return
  end

  local width = math.floor(vim.o.columns * 0.4)
  local height = math.floor(vim.o.lines * 0.9)
  local top = (vim.o.lines - height) / 2

  local left = 1
  if vim.fn.col('.') <= width then
    left = vim.o.columns - 1 - width
  end

  local enter_window = true
  self.winnr = vim.api.nvim_open_win(self.bufnr, enter_window, {
    relative = 'editor',
    width = width,
    height = height,
    row = top,
    col = left,
  })
end

---@param session Session
---@return Window
function M._get_or_create(session)
  if not session.id then
    error('No session id?')
  end

  local existing = M._by_session[session.id]
  if existing then
    return existing
  end

  local new = Window:new({ session_id = session.id })
  M._by_session[session.id] = new
  return new
end

---@param session_id string
---@return Window|nil
function M.for_session_id(session_id)
  return M._by_session[session_id]
end

---@param session Session
function M.open(session)
  local win = M._get_or_create(session)
  win:show()
  vim.cmd.startinsert()
end

return M
