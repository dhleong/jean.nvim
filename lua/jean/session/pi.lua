---One connection speaking pi's RPC protocol: to a running pi through its
---PI_RPC_SOCKET, or to a `pi --mode rpc` process of our own.
---@class PiConnection
---@field send fun(line: string)
---@field close fun()
---@field buffer string output not yet terminated by a newline
---@field callbacks table<string, fun(response: table)> by request id
---@field next_id number
---@field ready boolean get_state answered, so `busy` is known
---@field on_ready? fun() runs once ready
---@field busy boolean pi is in a run

---A prompt jean sent. It's `started` once pi echoes its user message: events
---before that belong to runs jean didn't start. It ends when pi settles or
---another user message starts.
---@class PiPrompt
---@field text string
---@field started boolean
---@field sent boolean the prompt command went to pi
---@field edit_args table<string, PiEditArgs>
---@field streamed table<number, boolean>
---@field outcome {failed: boolean, error: string|nil}

---A run jean didn't start, being mirrored.
---@class PiForeignRun
---@field text string
---@field edit_args table<string, PiEditArgs>
---@field streamed table<number, boolean>
---@field outcome {failed: boolean, error: string|nil}

---Spawning pi is lazy: on the first prompt, and again on the next prompt after
---the connection was lost. With a PI_RPC_SOCKET it connects right away to
---mirror runs, reconnecting with backoff while the socket exists.
---@class Pi : JeanProvider
---@field pwd string
---@field on_message fun(msg: JeanMessage)
---@field resume_token string|nil
---@field socket string|nil PI_RPC_SOCKET to connect to instead of spawning pi
---@field _conn PiConnection|nil
---@field _prompt PiPrompt|nil
---@field _foreign PiForeignRun|nil
---@field _cancelled string[] texts of sent prompts stopped before pi echoed them
---@field _rejected boolean another client holds the socket
---@field _backoff number|nil ms before the next reconnect attempt
---@field _reconnect uv.uv_timer_t|nil
local Pi = {
  id = 'pi',
}

---@type table<vim.SystemObj, true> spawned pi processes still running
local processes = {}

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('jean.session.pi', {}),
  callback = function()
    for process in pairs(processes) do
      process:kill('sigterm')
    end
  end,
})

local DIALOG_METHODS = { select = true, confirm = true, input = true, editor = true }

---@class PiEditArgs
---@field path string
---@field edits {oldText: string, newText: string}[]

---Split a unified diff into the line number (in the new file) of the first
---changed line of each hunk.
---@param patch string
---@return number[]
local function hunk_lnums(patch)
  local lnums = {}
  local next_lnum ---@type number|nil
  local seeking = false
  for _, line in ipairs(vim.split(patch, '\n')) do
    local start = line:match('^@@ %-%d+,?%d* %+(%d+)')
    if start then
      next_lnum = tonumber(start)
      seeking = true
    elseif next_lnum then
      local prefix = line:sub(1, 1)
      if seeking and (prefix == '+' or prefix == '-') then
        lnums[#lnums + 1] = next_lnum
        seeking = false
      end
      if prefix == ' ' or prefix == '+' then
        next_lnum = next_lnum + 1
      end
    end
  end
  return lnums
end

---Turn one decoded event of jean's run into generic messages, emitting each
---via on_message.
---@param entry table
---@param pwd string
---@param edit_args table<string, PiEditArgs> args of in-flight edit calls, by toolCallId
---@param streamed table<number, boolean> contentIndexes of the current message whose text was streamed
---@param outcome {failed: boolean, error: string|nil} outcome of the latest assistant message
---@param on_message fun(msg: JeanMessage)
local function parse(entry, pwd, edit_args, streamed, outcome, on_message)
  if entry.type == 'message_update' and entry.assistantMessageEvent.type == 'text_delta' then
    streamed[entry.assistantMessageEvent.contentIndex] = true
    on_message({ type = 'text_delta', text = entry.assistantMessageEvent.delta })
  elseif entry.type == 'message_end' and entry.message.role == 'assistant' then
    outcome.failed = entry.message.stopReason == 'error'
    outcome.error = outcome.failed and entry.message.errorMessage or nil
    for i, content in ipairs(entry.message.content) do
      if content.type == 'text' and content.text ~= '' then
        on_message({ type = 'text', text = content.text, streamed = streamed[i - 1] })
      end
    end
    for index in pairs(streamed) do
      streamed[index] = nil
    end
  elseif entry.type == 'tool_execution_start' and entry.toolName == 'edit' then
    edit_args[entry.toolCallId] = entry.args
  elseif entry.type == 'tool_execution_end' and entry.toolName == 'edit' then
    -- Use the end event: by the time the edit starts the file may already be
    -- changing, so searching for old_text would be racy.
    local args = edit_args[entry.toolCallId]
    edit_args[entry.toolCallId] = nil
    if entry.isError or not args then
      return
    end

    local file_path = args.path
    if not vim.startswith(file_path, '/') then
      file_path = vim.fs.joinpath(pwd, file_path)
    end

    local details = entry.result.details
    local lnums = details.patch and hunk_lnums(details.patch) or {}
    if #lnums == 0 then
      lnums = { details.firstChangedLine }
    end
    for i, lnum in ipairs(lnums) do
      local edit = args.edits[i] or args.edits[1]
      on_message({
        type = 'edit',
        file_path = file_path,
        old_text = edit.oldText,
        lnum = lnum,
      })
    end
  end
end

---@param content string|{type: string, text?: string}[]
---@return string
local function content_text(content)
  if type(content) == 'string' then
    return content
  end
  local texts = {}
  for _, block in ipairs(content) do
    if block.type == 'text' then
      texts[#texts + 1] = block.text
    end
  end
  return table.concat(texts)
end

---@param opts JeanProviderOpts
---@return Pi
function Pi:new(opts)
  local instance = vim.tbl_extend('keep', {}, opts)
  instance._cancelled = {}
  instance._rejected = false
  setmetatable(instance, self)
  self.__index = self
  if instance.socket then
    instance:_open()
  end
  return instance
end

---@param prompt PiPrompt
function Pi:_finish_started(prompt)
  self:_finish(prompt.outcome.failed and (prompt.outcome.error or 'pi request failed') or nil)
end

---@param error string|nil
function Pi:_finish(error)
  self._prompt = nil
  self.on_message({ type = 'done', error = error })
end

---End the mirrored run, if there is one.
function Pi:_finish_foreign()
  local foreign = self._foreign
  if foreign then
    self._foreign = nil
    self:_emit_foreign({
      type = 'done',
      error = foreign.outcome.failed and (foreign.outcome.error or 'pi request failed') or nil,
    })
  end
end

---Deliver a message of a run jean didn't start
---@param message JeanMessage
function Pi:_emit_foreign(message)
  message.foreign = true
  self.on_message(message)
end

---@param conn PiConnection
---@param command table
---@param callback fun(response: table)
function Pi:_request(conn, command, callback)
  conn.next_id = conn.next_id + 1
  command.id = 'jean-' .. conn.next_id
  conn.callbacks[command.id] = callback
  conn.send(vim.json.encode(command) .. '\n')
end

---@param conn PiConnection
---@param record table
function Pi:_on_record(conn, record)
  local prompt = self._prompt
  local user_message = record.type == 'message_start' and record.message.role == 'user'
  if prompt and prompt.started and user_message then
    -- A follow-up, or the user typing in pi: jean's run ends here
    self:_finish_started(prompt)
    prompt = nil
  end

  if record.type == 'response' then
    if record.command == 'connect' and not record.success then
      -- Another client holds the socket; it closes this connection next
      self._rejected = true
      if prompt then
        self:_finish(record.error)
      end
      return
    end
    local callback = record.id and conn.callbacks[record.id]
    if callback then
      conn.callbacks[record.id] = nil
      callback(record)
    end
  elseif record.type == 'extension_ui_request' then
    if DIALOG_METHODS[record.method] then
      conn.send(vim.json.encode({ type = 'extension_ui_response', id = record.id, cancelled = true }) .. '\n')
    end
  elseif record.type == 'agent_start' then
    conn.busy = true
  elseif record.type == 'agent_settled' then
    conn.busy = false
    self:_finish_foreign()
    if prompt and prompt.started then
      self:_finish_started(prompt)
    end
  elseif prompt and prompt.started then
    parse(record, self.pwd, prompt.edit_args, prompt.streamed, prompt.outcome, self.on_message)
  elseif user_message then
    local text = content_text(record.message.content)
    local cancelled = vim.iter(ipairs(self._cancelled)):find(function(_, cancelled_text)
      return cancelled_text == text
    end)
    if prompt and text == prompt.text then
      self:_finish_foreign()
      prompt.started = true
    elseif cancelled then
      table.remove(self._cancelled, cancelled)
      self:_finish_foreign()
    else
      self:_finish_foreign()
      self._foreign = { text = text, edit_args = {}, streamed = {}, outcome = { failed = false, error = nil } }
      self:_emit_foreign({ type = 'user_prompt', text = text })
    end
  elseif self._foreign then
    local foreign = self._foreign
    parse(record, self.pwd, foreign.edit_args, foreign.streamed, foreign.outcome, function(message)
      self:_emit_foreign(message)
    end)
  end
end

---@param conn PiConnection
---@param data string
function Pi:_on_data(conn, data)
  if self._conn ~= conn then
    return
  end
  local lines = vim.split(conn.buffer .. data, '\n', { plain = true })
  conn.buffer = table.remove(lines)
  for _, line in ipairs(lines) do
    local ok, record = pcall(vim.json.decode, (line:gsub('\r$', '')))
    if ok and self._conn == conn then
      self:_on_record(conn, record)
    end
  end
end

---@param conn PiConnection
---@param error string why the connection ended
function Pi:_on_closed(conn, error)
  if self._conn ~= conn then
    return
  end
  self._conn = nil
  self._cancelled = {}
  self:_finish_foreign()
  if self._prompt then
    self:_finish(error)
  end
  self:_schedule_reconnect()
end

function Pi:_cancel_reconnect()
  local timer = self._reconnect
  if timer then
    self._reconnect = nil
    timer:stop()
    timer:close()
  end
end

---Retry connecting to the socket with growing delays, until it's gone or
---another client took it.
function Pi:_schedule_reconnect()
  if not self.socket or self._rejected or self._reconnect or not vim.uv.fs_stat(self.socket) then
    return
  end
  local delay = self._backoff or 1000
  self._backoff = math.min(delay * 2, 30000)
  local timer = assert(vim.uv.new_timer())
  self._reconnect = timer
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      self:_cancel_reconnect()
      if not self._conn then
        self:_open()
      end
    end)
  )
end

---@return PiConnection
function Pi:_open()
  self:_cancel_reconnect()
  self._rejected = false
  ---@type PiConnection
  local conn = {
    buffer = '',
    callbacks = {},
    next_id = 0,
    ready = false,
    busy = false,
  }
  self._conn = conn

  if self.socket then
    local pipe = assert(vim.uv.new_pipe())
    local pending = {} ---@type string[]|nil
    conn.send = function(line)
      if pending then
        pending[#pending + 1] = line
      else
        pipe:write(line)
      end
    end
    conn.close = function()
      if not pipe:is_closing() then
        pipe:close()
      end
    end
    pipe:connect(self.socket, function(connect_err)
      if connect_err then
        conn.close()
        self:_on_closed(conn, 'pi disconnected: ' .. connect_err)
        return
      end
      for _, line in ipairs(pending) do
        pipe:write(line)
      end
      pending = nil
      pipe:read_start(function(read_err, data)
        if data then
          self:_on_data(conn, data)
        else
          conn.close()
          self:_on_closed(conn, read_err and 'pi disconnected: ' .. read_err or 'pi disconnected')
        end
      end)
    end)
  else
    local cmd = { 'pi', '--mode', 'rpc', '--tools', 'read,edit,write' }
    if self.resume_token then
      vim.list_extend(cmd, { '--session-id', self.resume_token })
    end
    local stderr = ''
    local process ---@type vim.SystemObj
    process = vim.system(cmd, {
      cwd = self.pwd,
      text = true,
      clear_env = false,
      -- An empty value makes the auth-profiles extension ignore any
      -- PI_AUTH_PROFILE inherited by Neovim, so the project's own profile applies
      env = { PI_AUTH_PROFILE = '' },
      stdin = true,
      stdout = function(_, data)
        if data then
          self:_on_data(conn, data)
        end
      end,
      stderr = function(_, data)
        if data then
          stderr = stderr .. data
        end
      end,
    }, function(result)
      processes[process] = nil
      stderr = vim.trim(stderr)
      self:_on_closed(conn, #stderr > 0 and stderr or 'pi exited with code ' .. result.code)
    end)
    processes[process] = true
    conn.send = function(line)
      process:write(line)
    end
    conn.close = function()
      process:kill('sigterm')
    end
  end

  self:_request(conn, { type = 'get_state' }, function(response)
    conn.ready = true
    self._backoff = nil
    if response.success then
      conn.busy = response.data.isStreaming
      if response.data.sessionId and response.data.sessionId ~= self.resume_token then
        self.resume_token = response.data.sessionId
        self.on_message({ type = 'resume_token', token = self.resume_token })
      end
    end
    local on_ready = conn.on_ready
    conn.on_ready = nil
    if on_ready then
      on_ready()
    end
  end)
  return conn
end

function Pi:stop()
  local conn = self._conn
  local prompt = self._prompt
  if prompt and conn and conn.ready then
    conn.send(vim.json.encode({ type = 'abort' }) .. '\n')
  end
  if prompt and prompt.sent and not prompt.started then
    self._cancelled[#self._cancelled + 1] = prompt.text
  end
  self._prompt = nil
end

function Pi:destroy()
  self:_cancel_reconnect()
  self:stop()
  local conn = self._conn
  if conn then
    self._conn = nil
    conn.close()
  end
end

---@param text string
function Pi:prompt(text)
  ---@type PiPrompt
  local prompt = {
    text = text,
    started = false,
    sent = false,
    edit_args = {},
    streamed = {},
    outcome = { failed = false, error = nil },
  }
  self._prompt = prompt

  local conn = self._conn or self:_open()
  local function send()
    if self._prompt ~= prompt then
      return
    end
    prompt.sent = true
    self:_request(conn, {
      type = 'prompt',
      message = text,
      streamingBehavior = conn.busy and 'followUp' or nil,
    }, function(response)
      if self._prompt ~= prompt then
        return
      end
      if not response.success then
        self:_finish(response.error)
      elseif response.data.disposition == 'handled' then
        self:_finish()
      end
    end)
  end
  if conn.ready then
    send()
  else
    conn.on_ready = send
  end
end

return Pi
