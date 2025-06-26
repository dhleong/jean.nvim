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

---@class EditToolInput
---@field file_path string
---@field old_string string

---@class ToolUse
---@field name "Edit"|"MultiEdit"|"Read"|"Write"|"WebFetch"|"WebSearch"
---@field input EditToolInput|table

---@param win Window
---@param tool ToolUse
function Session:_process_tool_use(win, tool)
  if tool.name == 'Edit' then
    -- Search for (the first line of) old_string in file_path and add the line to qf
    local bufnr, file_lines = read_file(tool.input.file_path)
    local old_string_lines = vim.split(tool.input.old_string, '\n')
    local first_line = old_string_lines[1]
    local index, found = vim.iter(ipairs(file_lines)):find(function(_, line)
      return line == first_line
    end)

    if found then
      ---@type vim.quickfix.entry
      local entry = {
        bufnr = bufnr,
        filename = tool.input.file_path,
        lnum = index,
      }
      vim.fn.setqflist({ entry }, 'a')
    end

    -- TODO: Consider adding the diff to the buffer, but folded
  end
end

---@param win Window
---@param entry SessionHistoryEntry
function Session:_process_entry(win, entry)
  -- Disable editing in the buffer while producing output
  if entry.type == 'result' then
    win.buffer.o.modifiable = true
    win:append_request_header()
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
      win:append_response('error', 'Execution canceled.')
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
  initial_win:append_response_header('success')

  -- Show a spinner by the cursor while Claude thinks
  local spinner = require('jean.spinner'):new()

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

  -- Reset the qflist.
  vim.fn.setqflist({}, 'r', {
    title = '[Jean] Changes',
    items = {},
  })

  cli:start({
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

    on_exit = vim.schedule_wrap(function(result)
      self.last_cli = nil

      -- Ensure we're readable
      initial_win.buffer.o.modifiable = true

      -- Clean up the spinner
      spinner:destroy()

      if result.error then
        initial_win:append_response('error', result.error)
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
