local GLOBAL_SESSION_ID = '__GLOBAL__'
local PI_SOCKET_SESSION_ID = '__PI_SOCKET__'

-- A pi that launched this nvim (pi-editor) passes its RPC socket; then every
-- buffer under that pi's cwd talks to it through one session. pi-editor may
-- start nvim in a worktree, so prefer the cwd pi reports (PI_CWD) over nvim's.
local pi_socket = vim.env.PI_RPC_SOCKET ~= '' and vim.env.PI_RPC_SOCKET or nil
local pi_socket_pwd = pi_socket and vim.fs.normalize(vim.env.PI_CWD ~= '' and vim.env.PI_CWD or vim.fn.getcwd())
-- Not inherited by processes nvim spawns
vim.env.PI_RPC_SOCKET = nil
vim.env.PI_CWD = nil

---@param bufnr number
---@return boolean
local function under_pi_cwd(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local path = name ~= '' and vim.fs.normalize(vim.fn.fnamemodify(name, ':p')) or vim.fs.normalize(vim.fn.getcwd())
  return path == pi_socket_pwd or vim.startswith(path, pi_socket_pwd .. '/')
end

---@alias JeanPromptResult {success: boolean, error?: string}

---A prompt submitted to a Session: waiting in its queue, or being answered
---once `sent`.
---@class QueuedPrompt
---@field text string
---@field context boolean prepend jean's context when sent
---@field echo boolean render `text` in the chat window when sent
---@field show_spinner boolean
---@field spinner {destroy: fun(self)}|nil
---@field sent boolean
---@field on_start? fun()
---@field on_message? fun(message: JeanMessage)
---@field on_done? fun(result: JeanPromptResult)

---@class JeanPromptHandle
---@field cancel fun(): boolean remove the prompt from the queue, stopping it if it runs; false if it already finished

---@class Session
---@field id string
---@field history JeanMessage[]
---@field last_context string|nil
---@field provider JeanProvider
---@field provider_class table class `provider` was created from
---@field queue QueuedPrompt[] prompts in submission order; only the head is ever sent
---@field socket_path string|nil PI_RPC_SOCKET for the provider
---@field _stops number how often the provider was stopped, to drop messages it emitted before
---@field last_buffer Buffer|nil
---@field last_buffer_winid number|nil
---@field pwd string
---@field streaming_text boolean|nil text_delta chunks of a block are being rendered
local Session = {}

---@return Session
function Session:new(opts)
  local instance = vim.tbl_extend('keep', {
    history = {},
    queue = {},
    _stops = 0,
  }, opts)
  setmetatable(instance, self)
  self.__index = self
  instance:_create_provider()
  return instance
end

function Session:_create_provider()
  self.last_context = nil
  self.provider_class = require('jean.config').create_provider(self)
  self.provider = self.provider_class:new({
    pwd = self.pwd,
    socket_path = self.socket_path,
    on_message = function(message)
      local stops = self._stops
      vim.schedule(function()
        if message.foreign or stops == self._stops then
          self:_on_message(message)
        end
      end)
    end,
  })
end

---Replace the provider if the configured one changed since it was created
---@return JeanProvider
function Session:_ensure_provider()
  if require('jean.config').create_provider(self) ~= self.provider_class then
    self.provider:destroy()
    self:_create_provider()
  end
  return self.provider
end

---@return QueuedPrompt|nil the prompt the provider is answering
function Session:_running()
  local head = self.queue[1]
  return head and head.sent and head or nil
end

---@param message JeanMessage
function Session:_on_message(message)
  local prompt = not message.foreign and self:_running() or nil
  if message.type ~= 'text_delta' then
    self.history[#self.history + 1] = message
  end
  if prompt and prompt.on_message then
    prompt.on_message(message)
  end

  local done = message.type == 'done'
  if done and prompt then
    table.remove(self.queue, 1)
  end

  local win = self:window()
  if win then
    self:_process_message(win, message)
  elseif done then
    self.streaming_text = false
  end

  if done and prompt then
    if prompt.spinner then
      prompt.spinner:destroy()
    end
    if prompt.on_done then
      prompt.on_done({ success = not message.error, error = message.error })
    end
    self:_send_next()
  end
end

local function check_for_buffer_edits()
  vim.cmd.checktime()
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
  if message.type == 'user_prompt' then
    self.streaming_text = false
    local last_line = vim.api.nvim_buf_get_lines(win.bufnr, -2, -1, false)[1]
    if self:_running() or last_line ~= '' then
      win:append_request_header()
    end
    win.buffer.o.modifiable = false
    win:append_text_and_follow(message.text)
    win:append_response_header('success')
  elseif message.type == 'text_delta' then
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
  elseif message.type == 'done' then
    -- A foreign run can end while jean's own prompt is still being answered
    local running = self:_running()
    self.streaming_text = false

    -- Make the buffer editable again so the user can type the next request,
    -- unless jean's own prompt is still being answered. A queued prompt is
    -- sent next and makes it read-only again.
    win.buffer.o.modifiable = not running

    if message.error then
      win:append_response('error', message.error)
      if running then
        win:append_response_header('success')
      end
    elseif running then
      win:append_response_header('success')
    else
      win:append_request_header()
    end

    local qf = vim.fn.getqflist({ size = true })
    if qf.size > 0 then
      vim.cmd.copen()
      check_for_buffer_edits()

      if require('jean.config').dismiss_window_after_edits then
        win:hide()
      end
    end
  end
end

---@return boolean did_cancel *if* we canceled something
function Session:cancel_active_prompt()
  local prompt = self:_running()
  return prompt ~= nil and self:_cancel(prompt)
end

---@param prompt QueuedPrompt
---@return boolean
function Session:_cancel(prompt)
  local index = vim.iter(ipairs(self.queue)):find(function(_, queued)
    return queued == prompt
  end)
  if not index then
    return false
  end
  table.remove(self.queue, index)

  if prompt.sent then
    self._stops = self._stops + 1
    self.provider:stop()
    if prompt.spinner then
      prompt.spinner:destroy()
    end

    local win = self:window()
    if win then
      self.streaming_text = false
      win.buffer.o.modifiable = true
      win:append_response('error', 'Execution canceled.')
    end
  end
  if prompt.on_done then
    prompt.on_done({ success = false, error = 'Execution canceled.' })
  end
  self:_send_next()
  return true
end

---@class SubmitPromptOpts
---@field spinner? boolean show the cursor-following spinner (default true)
---@field context? boolean prepend jean's context about the user's buffer (default true)
---@field echo? boolean render the prompt text in the chat window when it's sent (default false)
---@field on_start? fun() the prompt was sent to the provider
---@field on_message? fun(message: JeanMessage) a message of this prompt's run
---@field on_done? fun(result: JeanPromptResult) the run ended, or the prompt was cancelled

---Queue a prompt. Prompts are answered one at a time in submission order, and
---each one's callbacks only see messages of its own run.
---
---The chat window renders each prompt's response when the prompt is sent.
---With `echo`, the session also renders the prompt text then, so it lands
---after the responses to earlier prompts. Without it, the caller already put
---the text in the window's request area (the chat window's own input), which
---only works while nothing else is being answered.
---@param prompt string
---@param opts? SubmitPromptOpts
---@return JeanPromptHandle
function Session:submit_prompt(prompt, opts)
  opts = opts or {}
  if not self:window() then
    error('No window in which to submit prompt...')
  end

  ---@type QueuedPrompt
  local queued = {
    text = prompt,
    context = opts.context ~= false,
    echo = opts.echo == true,
    show_spinner = opts.spinner ~= false,
    sent = false,
    on_start = opts.on_start,
    on_message = opts.on_message,
    on_done = opts.on_done,
  }
  self.queue[#self.queue + 1] = queued
  self:_send_next()
  return {
    cancel = function()
      return self:_cancel(queued)
    end,
  }
end

---Send the head of the queue to the provider, unless it's already been sent
function Session:_send_next()
  local prompt = self.queue[1]
  if not prompt or prompt.sent then
    return
  end
  prompt.sent = true

  local win = assert(self:window())
  self.streaming_text = false
  if prompt.echo then
    local last_line = vim.api.nvim_buf_get_lines(win.bufnr, -2, -1, false)[1]
    if last_line ~= '' then
      win:append_request_header()
    end
    win:append_text_and_follow(prompt.text)
  end

  -- Disable modification while we process
  win.buffer.o.modifiable = false
  win:append_response_header('success')

  -- Before the context check: swapping the provider resets last_context
  local provider = self:_ensure_provider()
  local to_send = prompt.text
  if prompt.context then
    local context = require('jean.context').build(self)
    if self.last_context ~= context then
      if context then
        to_send = context .. '\n\n' .. to_send
      end
      self.last_context = context
    end
  end

  -- Reset the qflist.
  vim.fn.setqflist({}, 'r', {
    title = '[Jean] Changes',
    items = {},
  })

  if prompt.show_spinner then
    -- Show a spinner by the cursor while the agent thinks
    prompt.spinner = require('jean.spinner'):new()
  end
  if prompt.on_start then
    prompt.on_start()
  end

  -- A provider that can't start (e.g. its CLI is missing) must not stall the queue
  local ok, err = pcall(provider.prompt, provider, to_send)
  if not ok then
    self:_on_message({ type = 'done', error = tostring(err) })
  end
end

function Session:window()
  return require('jean.window').for_session_id(self.id)
end

---Remember the current window as the one a prompt is about, ignoring jean's own windows
function Session:capture_context_source()
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if vim.b[bufnr].jean_nvim_managed then
    return
  end
  self.last_buffer = require('jean.buffer'):from_nr(bufnr)
  self.last_buffer_winid = winid
end

local M = {
  _sessions = {},
}

---@param socket_path? string
---@return Session
function M._get_or_create(id, pwd, socket_path)
  local existing = M._sessions[id]
  if existing then
    return existing
  end

  if not pwd and id ~= GLOBAL_SESSION_ID then
    error('Missing pwd for non-global session')
  end

  local new = Session:new({ id = id, pwd = pwd or id, socket_path = socket_path })
  M._sessions[id] = new
  return new
end

function M.global()
  return M._get_or_create(GLOBAL_SESSION_ID, vim.env.HOME)
end

function M.from_buffer(bufnr)
  local nr = bufnr or 0
  if nr == 0 then
    nr = vim.api.nvim_get_current_buf()
  end

  -- jean's own buffers (the chat window) belong to the session that owns them
  local session_id = vim.b[nr].jean_session_id
  if session_id and M._sessions[session_id] then
    return M._sessions[session_id]
  end

  if pi_socket and under_pi_cwd(nr) then
    return M._get_or_create(PI_SOCKET_SESSION_ID, pi_socket_pwd, pi_socket)
  end

  local root = require 'jean.project'.root_for_buffer(nr)
  if root then
    return M._get_or_create(root, root)
  end

  return M.global()
end

return M
