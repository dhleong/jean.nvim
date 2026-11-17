---@class Claude : JeanProvider
---@field pwd string
---@field on_message fun(msg: JeanMessage)
---@field resume_token string|nil
local Claude = {
  id = 'claude',
}

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
  end
end

---@param opts JeanProviderOpts
---@return Claude
function Claude:new(opts)
  local instance = vim.tbl_extend('keep', {}, opts)
  setmetatable(instance, self)
  self.__index = self
  return instance
end

function Claude:stop()
  self._run = nil
  local process = self._process
  if process then
    self._process = nil
    process:kill('sigterm')
  end
end

function Claude:destroy()
  self:stop()
end

---@param text string
function Claude:prompt(text)
  self:stop()

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

  -- Messages are only delivered while this run is still the current one
  local run = {}
  local function emit(message)
    if self._run ~= run then
      return
    end
    if message.type == 'resume_token' then
      self.resume_token = message.token
    end
    self.on_message(message)
  end
  self._run = run

  local output = ''
  self._process = vim.system(cmd, {
    cwd = self.pwd,
    text = true,
    clear_env = false,
    stdin = { text },
    stdout = function(_, stdout)
      if not stdout then
        return
      end

      output = output .. stdout
      local lines = vim.split(output, '\n')
      output = lines[#lines]
      lines[#lines] = nil

      for _, line in ipairs(lines) do
        parse(vim.json.decode(line), emit)
      end
    end,
  }, function(result)
    if self._run == run then
      self._process = nil
    end
    ---@type string|nil
    local error = vim.trim(result.stderr)
    if #error == 0 then
      error = result.code ~= 0 and ('claude exited with code ' .. result.code) or nil
    end
    emit({ type = 'done', error = error })
  end)
end

return Claude
