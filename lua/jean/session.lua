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
---@field last_buffer Buffer|nil
---@field last_buffer_winid number|nil
---@field pwd string
local Session = {}

function Session:new(opts)
  local instance = vim.tbl_extend('keep', {
    history = {},
  }, opts)
  setmetatable(instance, self)
  self.__index = self
  return instance
end

---@param win Window
---@param entry SessionHistoryEntry
function Session:_process_entry(win, entry)
  -- Disable editing in the buffer while producing output
  if entry.type == 'result' then
    win.buffer.o.modifiable = true
    win.buffer:append_lines({ '', require('jean.config').request_separator, '', '' })
    win.buffer:move_cursor_to_end()
  end

  if entry.type == 'system' then
    -- Technically on any message, but reduce churn:
    self.claude_session_id = entry.session_id
  end

  if entry.type == 'assistant' and entry.message and entry.message.content then
    for _, content in ipairs(entry.message.content) do
      if content.type == 'text' then
        win.buffer:append_lines(vim.split(content.text, '\n'))
        win.buffer:move_cursor_to_end()
      end
    end
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
  initial_win.buffer:append_lines({
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

  cli:start({
    -- TODO: On error, restore modifiable

    on_entry = vim.schedule_wrap(function(entry)
      local win = require('jean.window').for_session_id(self.id)
      if not win then
        -- Stop early
        cli:cancel()
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
