local GLOBAL_SESSION_ID = '__GLOBAL__'

---@alias ClaudeAssistantMessage table<string, any>

---@class SessionHistoryEntry
---@field type "system"|"assistant"|"result"
---@field message ClaudeAssistantMessage|nil
---@field session_id string

---@class Session
---@field id string
---@field history SessionHistoryEntry[]
---@field claude_session_id string|nil
---@field last_context string|nil
---@field last_cli Claude|nil
---@field last_buffer Buffer|nil
---@field last_buffer_winid number|nil
---@field pwd string
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

---@param win Window
---@param tool table -- TODO: Add types here
function Session:_process_tool_use(win, tool)
  if tool.name == 'Edit' then
    -- TODO: Search for old_string in file_path and add the line to qf
    -- TODO: Consider adding the diff to the buffer, but folded
  end
end

---@param win Window
---@param entry SessionHistoryEntry
function Session:_process_entry(win, entry)
  -- Disable editing in the buffer while producing output
  if entry.type == 'result' then
    win.buffer.o.modifiable = true
    win:append_lines_and_follow({ '', require('jean.config').request_separator, '', '' })
    self.last_cli = nil
  end

  if entry.type == 'system' then
    -- Technically on any message, but reduce churn:
    self.claude_session_id = entry.session_id
  end

  if entry.type == 'assistant' and entry.message and entry.message.content then
    for _, content in ipairs(entry.message.content) do
      if content.type == 'text' then
        win:append_lines_and_follow(vim.split(content.text, '\n'))
      elseif content.type == 'tool_use' then
        self:_process_tool_use(win, content)
      end
    end
  end
end

---@return boolean did_cancel *if* we canceled something
function Session:cancel_active_prompt()
  local cli = self.last_cli
  self.last_cli = nil
  if cli then
    cli:stop()

    local win = self:window()
    if win then
      win.buffer.o.modifiable = true
      win:append_lines_and_follow({
        '',
        'Execution canceled.',
        '',
        require('jean.config').request_separator,
        '',
        '',
      })
    end
    return true
  else
    return false
  end
end

---@param prompt string
function Session:submit_prompt(prompt)
  local initial_win = self:window()
  if not initial_win then
    error('No window in which to submit prompt...')
    return
  end

  -- Disable modification while we process
  initial_win.buffer.o.modifiable = false
  initial_win:append_lines_and_follow({
    '',
    '## Response',
    '> ' .. table.concat(vim.split(prompt, '\n'), '> '),
    '',
  })
  -- TODO: Can we do some kind of progress spinner?

  local context = require('jean.context').build(self)
  local to_send = prompt
  if self.last_context ~= context then
    if context then
      to_send = context .. '\n\n' .. to_send
    end
    self.last_context = context
  end

  local Claude = require('jean.session.claude')
  local cli = Claude:new({
    claude_session_id = self.claude_session_id,
    prompt = to_send,
    pwd = self.pwd,
  })
  self.last_cli = cli

  cli:start({
    -- TODO: On error, restore modifiable

    on_entry = vim.schedule_wrap(function(entry)
      local win = self:window()
      if not win then
        -- Stop early
        self:cancel_active_prompt()
        return
      end

      self.history[#self.history + 1] = entry
      self:_process_entry(win, entry)
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

  local clients = vim.lsp.get_clients({ bufnr = nr })
  if not clients or #clients == 0 then
    -- TODO: Other strategies?
    return M.global()
  end
  for _, client in ipairs(clients) do
    if client.root_dir then
      return M._get_or_create(client.root_dir, client.root_dir)
    end
  end

  local pwd = vim.fn.getcwd()
  return M._get_or_create(pwd, pwd)
end

return M
