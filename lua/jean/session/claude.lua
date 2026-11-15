---@alias ClaudeOpts {pwd: string, prompt: string, resume_token: string|nil}

---@alias ClaudeStartOpts {on_message: fun(msg: JeanMessage), on_exit: fun(result: {success: boolean, error?: string})}

---@class Claude
---@field pwd string
---@field prompt string
---@field resume_token string|nil
local Claude = {}

---Turn one decoded stream-json entry into generic messages, emitting each
---via on_message.
---@param entry table
---@param on_message fun(msg: JeanMessage)
local function parse(entry, on_message)
  if entry.type == 'system' and entry.session_id then
    on_message({ type = 'resume_token', token = entry.session_id })
  elseif entry.type == 'assistant' and entry.message and entry.message.content then
    for _, content in ipairs(entry.message.content) do
      if content.type == 'text' then
        on_message({ type = 'text', text = content.text })
      elseif content.type == 'tool_use' and content.name == 'Edit' then
        on_message({
          type = 'edit',
          file_path = content.input.file_path,
          old_text = content.input.old_string,
        })
      elseif content.type == 'tool_use' and content.name == 'MultiEdit' then
        for _, edit in ipairs(content.input.edits) do
          on_message({
            type = 'edit',
            file_path = content.input.file_path,
            old_text = edit.old_string,
          })
        end
      end
    end
  elseif entry.type == 'result' then
    on_message({ type = 'done' })
  end
end

---@param opts ClaudeOpts
---@return Claude
function Claude:new(opts)
  local instance = vim.tbl_extend('keep', {}, opts)
  setmetatable(instance, self)
  self.__index = self
  return instance
end

function Claude:stop()
  if self._process then
    self._process:kill('sigterm')
    self._process = nil
  end
end

---@param opts ClaudeStartOpts
function Claude:start(opts)
  local cmd = { 'claude', '--print', '--verbose', '--output-format=stream-json' }
  if self.resume_token then
    vim.list_extend(cmd, { '--resume', vim.trim(self.resume_token) })
  end

  -- TODO: Diff UI?
  vim.list_extend(cmd, {
    '--allowedTools',
    table.concat({
      'Read',
      'Edit',
      'MultiEdit',
      'WebFetch',
      'WebSearch',
      'Write',
    }, ','),
  })

  local output = ''
  self._process = vim.system(cmd, {
    cwd = self.pwd,
    text = true,
    clear_env = false,
    stdin = { self.prompt },
    stdout = function(err, stdout)
      if not stdout then
        return
      end

      output = output .. stdout
      local lines = vim.split(output, '\n')
      output = lines[#lines]
      lines[#lines] = nil

      for _, line in ipairs(lines) do
        parse(vim.json.decode(line), opts.on_message)
      end
    end,
  }, function(result)
    ---@type string|nil
    local error = vim.trim(result.stderr)
    if #error == 0 then
      error = nil
    end
    opts.on_exit({
      success = result.code == 0,
      error = error,
    })
  end)
end

return Claude
