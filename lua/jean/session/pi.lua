---@alias PiOpts {pwd: string, prompt: string, resume_token: string|nil}

---@alias PiStartOpts {on_message: fun(msg: JeanMessage), on_exit: fun(result: {success: boolean, error?: string})}

---@class Pi
---@field pwd string
---@field prompt string
---@field resume_token string|nil
local Pi = {
  id = 'pi',
}

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

---Turn one decoded JSONL record into generic messages, emitting each via
---on_message.
---@param entry table
---@param pwd string
---@param edit_args table<string, PiEditArgs> args of in-flight edit calls, by toolCallId
---@param streamed table<number, boolean> contentIndexes of the current message whose text was streamed
---@param outcome {failed: boolean, error: string|nil} outcome of the latest assistant message
---@param on_message fun(msg: JeanMessage)
local function parse(entry, pwd, edit_args, streamed, outcome, on_message)
  if entry.type == 'session' then
    on_message({ type = 'resume_token', token = entry.id })
  elseif entry.type == 'message_update' and entry.assistantMessageEvent.type == 'text_delta' then
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
  elseif entry.type == 'agent_settled' then
    on_message({ type = 'done' })
  end
end

---@param opts PiOpts
---@return Pi
function Pi:new(opts)
  local instance = vim.tbl_extend('keep', {}, opts)
  setmetatable(instance, self)
  self.__index = self
  return instance
end

function Pi:stop()
  if self._process then
    self._process:kill('sigterm')
    self._process = nil
  end
end

---@param opts PiStartOpts
function Pi:start(opts)
  local cmd = { 'pi', '-p', '--mode', 'json', '--tools', 'read,edit,write' }
  if self.resume_token then
    vim.list_extend(cmd, { '--session-id', vim.trim(self.resume_token) })
  end

  local output = ''
  local edit_args = {}
  local streamed = {}
  local outcome = { failed = false, error = nil }
  self._process = vim.system(cmd, {
    cwd = self.pwd,
    text = true,
    clear_env = false,
    -- An empty value makes the auth-profiles extension ignore any
    -- PI_AUTH_PROFILE inherited by Neovim, so the project's own profile applies
    env = { PI_AUTH_PROFILE = '' },
    stdin = { self.prompt },
    stdout = function(_, stdout)
      if not stdout then
        return
      end

      output = output .. stdout
      local lines = vim.split(output, '\n')
      output = lines[#lines]
      lines[#lines] = nil

      for _, line in ipairs(lines) do
        local ok, entry = pcall(vim.json.decode, line)
        if ok then
          parse(entry, self.pwd, edit_args, streamed, outcome, opts.on_message)
        end
      end
    end,
  }, function(result)
    local errors = {}
    if outcome.failed then
      errors[#errors + 1] = outcome.error or 'pi request failed'
    end
    local stderr = vim.trim(result.stderr)
    if #stderr > 0 then
      errors[#errors + 1] = stderr
    end
    opts.on_exit({
      success = result.code == 0 and not outcome.failed,
      error = #errors > 0 and table.concat(errors, '\n') or nil,
    })
  end)
end

return Pi
