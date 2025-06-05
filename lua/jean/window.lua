local M = {
  _by_session = {},
}

---@param buf Buffer
local function configure_buffer(buf)
  buf.o.filetype = 'markdown'

  -- Initialize content
  buf:append_lines({ require('jean.config').request_separator, '', '' })
  buf:delete_lines(0, 1)

  ---@return Window|nil
  local function win()
    local session_id = buf.vars.jean_session_id
    return M._by_session[session_id]
  end

  vim.keymap.set('n', 'q', function()
    local window = win()
    if window then
      window:hide()
    end
  end, { buffer = buf.bufnr, desc = 'Hide the window' })

  vim.keymap.set('n', '<c-c>', function()
    local window = win()
    if window then
      local session = window:get_session()
      session:cancel_active_prompt()
    end
  end, { buffer = buf.bufnr, desc = 'Cancel any running prompt' })

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
end

---@class Window
---@field session_id string
---@field bufnr number
---@field winnr number|nil
---@field buffer Buffer
local Window = {}

---@return Window
function Window:new(opts)
  local instance = vim.tbl_extend('keep', {}, opts)
  setmetatable(instance, self)
  self.__index = self

  if not instance.bufnr then
    self.bufnr = vim.api.nvim_create_buf(false, true)
    self.buffer = require('jean.buffer'):from_nr(self.bufnr)
    self.buffer.vars.jean_session_id = opts.session_id

    configure_buffer(self.buffer)

    -- NOTE: The window isn't shown yet; wait until it is to move the cursor
    vim.schedule(function()
      instance:move_cursor_to_end()
    end)
  end

  return instance
end

---@return Session
function Window:get_session()
  return require('jean.session').from_buffer(self.bufnr)
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

  local session = self:get_session()
  session.last_buffer = require('jean.buffer'):from_nr(vim.fn.bufnr('%'))
  session.last_buffer_winid = vim.api.nvim_get_current_win()

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

---@param lines string|string[]
function Window:append_lines_and_follow(lines)
  self.buffer:append_lines(lines)
  self:move_cursor_to_end() -- TODO: Maybe only if already at end?
end

function Window:move_cursor_to_end()
  if self.winnr then
    local line_count = vim.api.nvim_buf_line_count(self.bufnr)
    local last_line = vim.api.nvim_buf_get_lines(self.bufnr, line_count - 1, line_count, false)[1] or ''
    vim.api.nvim_win_set_cursor(self.winnr, { line_count, #last_line })
  end
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
  local window = M._by_session[session_id]
  if window and window.winnr then
    return window
  end
end

---@param session Session
---@param opts? { startinsert: boolean }
function M.open(session, opts)
  local win = M._get_or_create(session)
  win:show()
  if not opts or opts.startinsert then
    vim.cmd.startinsert()
  end
  return win
end

return M
