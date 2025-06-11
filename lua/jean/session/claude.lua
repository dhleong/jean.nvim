---@alias ClaudeOpts {pwd: string, prompt: string, claude_session_id: string|nil}

---@alias ClaudeStartOpts {on_entry: fun(entry: table), on_exit: fun(result: {success: boolean, error?: string})}

---@class Claude
---@field pwd string
---@field prompt string
---@field claude_session_id string|nil
local Claude = {}

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
  if self.claude_session_id then
    vim.list_extend(cmd, { '--resume', vim.trim(self.claude_session_id) })
  end

  -- TODO: Diff UI? MultiEdit might be hard...
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
        local entry = vim.json.decode(line)
        entry.raw = line
        opts.on_entry(entry)
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
