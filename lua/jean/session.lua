local GLOBAL_SESSION_ID = '__GLOBAL__'

---@class Session
---@field id string
---@field history JeanMessage[]
---@field resume_token string|nil
---@field resume_provider string|nil provider that issued resume_token
---@field last_context string|nil
---@field active_request {stop: fun(self)}|nil
---@field last_buffer Buffer|nil
---@field last_buffer_winid number|nil
---@field pwd string
---@field streaming_text boolean|nil text_delta chunks of a block are being rendered
local Session = {}

---@return Session
function Session:new(opts)
  local instance = vim.tbl_extend('keep', {
    history = {},
  }, opts)
  setmetatable(instance, self)
  self.__index = self
  return instance
end

local function read_file(file_path)
  local file_bufnr = vim.fn.bufnr(file_path)
  local file_lines = {}
  if file_bufnr ~= -1 then
    local buf = require('jean.buffer'):from_nr(file_bufnr)
    file_lines = buf:get_lines()
  else
    local file = io.open(file_path, 'r')
    if file then
      for line in file:lines() do
        table.insert(file_lines, line)
      end
      file:close()
    end
  end
  return file_bufnr, file_lines
end

---@param win Window
---@param message JeanMessage
function Session:_process_message(win, message)
  if message.type == 'text_delta' then
    if not self.streaming_text then
      self.streaming_text = true
      win:append_lines_and_follow('')
    end
    win:append_text_and_follow(message.text)
  elseif message.type == 'text' then
    if message.streamed then
      self.streaming_text = false
    else
      win:append_lines_and_follow(vim.split(message.text, '\n'))
    end
  elseif message.type == 'edit' then
    local bufnr, index
    if message.lnum then
      -- Use the lnum if we know it already
      bufnr = vim.fn.bufnr(message.file_path)
      index = message.lnum
    else
      -- Search for (the first line of) old_text in file_path if we don't
      local file_lines
      bufnr, file_lines = read_file(message.file_path)
      local first_line = vim.split(message.old_text, '\n')[1]
      index = vim.iter(ipairs(file_lines)):find(function(_, line)
        return line == first_line
      end)
    end

    if index then
      ---@type vim.quickfix.entry
      local entry = {
        bufnr = bufnr,
        filename = message.file_path,
        lnum = index,
      }
      vim.fn.setqflist({ entry }, 'a')
    end

    -- TODO: Consider adding the diff to the buffer, but folded
  elseif message.type == 'resume_token' then
    self.resume_token = message.token
    self.resume_provider = self.last_provider.id
  elseif message.type == 'done' then
    win.buffer.o.modifiable = true
    win:append_request_header()
    self.active_request = nil
  end
end

---@return boolean did_cancel *if* we canceled something
function Session:cancel_active_prompt()
  local request = self.active_request
  self.active_request = nil
  if request then
    request:stop()

    local win = self:window()
    if win then
      win.buffer.o.modifiable = true
      win:append_response('error', 'Execution canceled.')
    end
    return true
  else
    return false
  end
end

---@class SubmitPromptOpts
---@field spinner? boolean show the cursor-following spinner (default true)
---@field on_message? fun(message: JeanMessage)
---@field on_done? fun(result: {success: boolean, error?: string})

---@param prompt string
---@param opts? SubmitPromptOpts
function Session:submit_prompt(prompt, opts)
  opts = opts or {}
  local initial_win = self:window()
  if not initial_win then
    error('No window in which to submit prompt...')
    return
  end

  self.streaming_text = false

  -- Disable modification while we process
  initial_win.buffer.o.modifiable = false
  initial_win:append_response_header('success')

  -- Show a spinner by the cursor while the agent thinks
  local spinner = opts.spinner ~= false and require('jean.spinner'):new() or nil

  local context = require('jean.context').build(self)
  local to_send = prompt
  if self.last_context ~= context then
    if context then
      to_send = context .. '\n\n' .. to_send
    end
    self.last_context = context
  end

  local Provider = require('jean.config').create_provider(self)
  self.last_provider = Provider

  local request = Provider:new({
    resume_token = self.resume_provider == Provider.id and self.resume_token or nil,
    prompt = to_send,
    pwd = self.pwd,
  })
  self.active_request = request

  -- Reset the qflist.
  vim.fn.setqflist({}, 'r', {
    title = '[Jean] Changes',
    items = {},
  })

  request:start({
    on_message = vim.schedule_wrap(function(message)
      local win = self:window()
      if not win then
        -- Stop early
        self:cancel_active_prompt()
        return
      end

      if message.type ~= 'text_delta' then
        self.history[#self.history + 1] = message
      end
      self:_process_message(win, message)
      if opts.on_message then
        opts.on_message(message)
      end
    end),

    on_exit = vim.schedule_wrap(function(result)
      self.active_request = nil
      self.streaming_text = false

      -- Ensure we're readable
      initial_win.buffer.o.modifiable = true

      -- Clean up the spinner
      if spinner then
        spinner:destroy()
      end

      if result.error then
        initial_win:append_response('error', result.error)
      end

      if opts.on_done then
        opts.on_done(result)
      end

      -- Show the qflist if we added anything to it
      local qf = vim.fn.getqflist({ size = true })
      if qf.size > 0 then
        vim.cmd.copen()

        -- Reload any modified buffers
        vim.cmd.checktime()

        -- Dismiss the window
        if require('jean.config').dismiss_window_after_edits then
          initial_win:hide()
        end
      end
    end),
  })
end

function Session:window()
  return require('jean.window').for_session_id(self.id)
end

local M = {
  _sessions = {},
}

---@return Session
function M._get_or_create(id, pwd)
  local existing = M._sessions[id]
  if existing then
    return existing
  end

  if not pwd and id ~= GLOBAL_SESSION_ID then
    error('Missing pwd for non-global session')
  end

  local new = Session:new({ id = id, pwd = pwd or id })
  M._sessions[id] = new
  return new
end

function M.global()
  return M._get_or_create(GLOBAL_SESSION_ID, vim.env.HOME)
end

function M.from_buffer(bufnr)
  local nr = bufnr or 0

  local session_id = vim.b[nr].jean_session_id
  if session_id then
    local existing = M._sessions[session_id]
    if existing then
      return existing
    end
  end

  local root = require 'jean.project'.root_for_buffer(nr)
  if root then
    return M._get_or_create(root, root)
  end

  return M.global()
end

return M
