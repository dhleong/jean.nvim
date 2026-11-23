local t = require('helpers')

-- project.lua's vim-test lookup needs this set
vim.g['test#project_root'] = vim.fn.getcwd()

---Run a buffer-local normal-mode mapping of the current buffer
---@param lhs string
local function press(lhs)
  vim.fn.maparg(lhs, 'n', false, true).callback()
end

---Open a file with `lines` in the current window
---@param lines string[]
---@return number bufnr, string path
local function open_file(lines)
  local path = vim.fn.tempname() .. '.md'
  vim.fn.writefile(lines, path)
  vim.cmd.edit(path)
  return vim.api.nvim_get_current_buf(), path
end

---Write `lines` to `path` behind nvim's back
local function rewrite(path, lines)
  vim.fn.writefile(lines, path)
end

---Leave whatever float has focus, back to the file's window
---@param winid number
local function back_to(winid)
  if vim.api.nvim_get_current_win() ~= winid then
    press('q')
  end
  t.eq(winid, vim.api.nvim_get_current_win())
end

---`g/` on a row and submit `text`; the thread's mini float has focus afterwards
---@param row number 1-based
---@param text string
local function ask(row, text)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  require('jean').prompt_inline()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n'))
  press('<cr>')
end

---@type string[]
local notes

---@return FakeProvider
local function setup()
  local Fake = t.use_fake_provider()
  vim.cmd.runtime('plugin/jean.lua')
  notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  return Fake
end

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

---Chip labels with any spinner frame shown as `⠋`
---@param labels string[]
local function steady(labels)
  return vim.tbl_map(function(label)
    local status, rest = label:match('^ (%S+)(.*)$')
    return ' ' .. (vim.tbl_contains(SPINNER, status) and '⠋' or status) .. rest
  end, labels)
end

---@param bufnr number
---@return string[] chip labels, in row order
local function chips(bufnr)
  local ns = vim.api.nvim_create_namespace('jean.inline')
  return vim.tbl_map(function(mark)
    return mark[4].virt_text and mark[4].virt_text[1][1] or ''
  end, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true }))
end

---@param thread Thread
local function responses(thread)
  return vim.tbl_map(function(exchange)
    return {
      exchange.prompt,
      exchange.status,
      vim.tbl_map(function(block)
        return block.text
      end, exchange.blocks),
    }
  end, thread.exchanges)
end

local function teardown()
  vim.cmd('silent! %bwipeout!')
end

t.test('two queued threads in one buffer: each reply lands in its own thread', function()
  local Fake = setup()
  local bufnr = open_file({ 'one', 'two', 'three' })
  local win = vim.api.nvim_get_current_win()

  ask(1, 'about one')
  back_to(win)
  ask(3, 'about three')
  back_to(win)

  local T = require('jean.thread')
  local a, b = unpack(T.list())
  local provider = Fake.instances[1]
  t.eq(1, #provider.prompts)
  t.eq(('[jean thread %s · %s · near line 1 · "one"]\nabout one'):format(a.id, a.path), provider.prompts[1])
  t.eq({ { 'about three', 'queued', {} } }, responses(b))
  t.eq({ ' ⠋ about one', ' … about three' }, steady(chips(bufnr)))

  provider:emit({ type = 'text_delta', text = 'reply ' })
  provider:emit({ type = 'text', text = 'reply A', streamed = true })
  provider:emit({ type = 'done' })
  t.flush()
  t.eq(2, #provider.prompts)
  t.eq(true, vim.startswith(provider.prompts[2], ('[jean thread %s ·'):format(b.id)))

  provider:emit({ type = 'text', text = 'reply B' })
  provider:emit({ type = 'done', error = 'boom' })
  t.flush()

  t.eq({ { 'about one', 'done', { 'reply A' } } }, responses(a))
  t.eq({ { 'about three', 'error', { 'reply B' } } }, responses(b))
  t.eq('boom', b.exchanges[1].error)
  t.eq({ ' ● about one', ' ✗ about three' }, chips(bufnr))
  teardown()
end)

t.test('replying in a thread adds an exchange to it only, shown in its float', function()
  local Fake = setup()
  open_file({ 'one', 'two', 'three' })
  local win = vim.api.nvim_get_current_win()
  ask(1, 'first')
  back_to(win)
  ask(3, 'other')
  back_to(win)
  local provider = Fake.instances[1]
  provider:emit({ type = 'text', text = 'answer 1' })
  provider:emit({ type = 'done' })
  t.flush()
  provider:emit({ type = 'text', text = 'other answer' })
  provider:emit({ type = 'done' })
  t.flush()

  -- g/ on a line with a thread replies in it
  ask(1, 'second')
  back_to(win)
  local a, b = unpack(require('jean.thread').list())
  t.eq(true, vim.startswith(provider.prompts[3], ('[jean thread %s ·'):format(a.id)))
  provider:emit({ type = 'text', text = 'answer 2' })
  provider:emit({ type = 'done' })
  t.flush()

  t.eq({ { 'first', 'done', { 'answer 1' } }, { 'second', 'done', { 'answer 2' } } }, responses(a))
  t.eq({ { 'other', 'done', { 'other answer' } } }, responses(b))

  -- The float shows the whole history; `r` replies from it
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  require('jean').prev_thread()
  t.eq({ 'first', '', 'answer 1', '', 'second', '', 'answer 2' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  press('r')
  t.eq(win, vim.fn.win_getid(vim.fn.winnr('#')))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'third' })
  press('<cr>')
  t.eq('third', a.exchanges[3].prompt)
  t.eq(1, #b.exchanges)
  teardown()
end)

t.test('next/prev thread follow row order and wrap', function()
  setup()
  open_file({ 'a', 'b', 'c', 'd', 'e' })
  local win = vim.api.nvim_get_current_win()
  for _, row in ipairs({ 5, 1, 3 }) do
    ask(row, 'q' .. row)
    back_to(win)
  end

  local function go(fn)
    require('jean')[fn]()
    local mini = vim.api.nvim_get_current_win()
    t.eq(true, mini ~= win)
    back_to(win)
    return vim.api.nvim_win_get_cursor(win)[1]
  end
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  t.eq({ 3, 5, 1, 3 }, { go('next_thread'), go('next_thread'), go('next_thread'), go('next_thread') })
  t.eq({ 1, 5, 3 }, { go('prev_thread'), go('prev_thread'), go('prev_thread') })
  teardown()
end)

t.test('threads re-attach after the file is rewritten on disk', function()
  setup()
  local bufnr, path = open_file({ 'intro', 'hello world', '- **C2.** Should we ship?', 'delete me', 'outro' })
  local win = vim.api.nvim_get_current_win()
  for _, row in ipairs({ 2, 3, 4 }) do
    ask(row, 'q' .. row)
    back_to(win)
  end
  local by_text, by_id, gone = unpack(require('jean.thread').list())

  local lines = { 'new', 'new', 'intro', 'hello world', '- **C2.** Should we ship it now?', 'outro' }
  rewrite(path, lines)
  vim.cmd.checktime(bufnr)

  t.eq(lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  t.eq({ 4, false }, { by_text.last_row, by_text.detached })
  t.eq({ 5, false, lines[5] }, { by_id.last_row, by_id.detached, by_id.anchor_text })
  t.eq({ 4, true, 'delete me' }, { gone.last_row, gone.detached, gone.anchor_text })
  -- q4 is detached at its old row, which q2 now holds
  local labels = steady(chips(bufnr))
  table.sort(labels)
  t.eq({ ' … q3', ' ⚠ q4', ' ⠋ q2' }, labels)
  t.eq(3, #require('jean.thread').list())

  -- and attach it again by hand
  vim.api.nvim_win_set_cursor(win, { 6, 0 })
  require('jean').attach_thread()
  t.eq({ 6, false, 'outro' }, { gone.last_row, gone.detached, gone.anchor_text })
  teardown()
end)

t.test('threads load from the store when their file is read again', function()
  setup()
  local bufnr, path = open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(2, 'hi')
  back_to(win)
  local thread = require('jean.thread').list()[1]
  vim.cmd.bwipeout(bufnr)
  t.eq(nil, thread.bufnr)

  rewrite(path, { 'top', 'a', 'b' })
  vim.cmd.edit(path)
  t.eq({ vim.api.nvim_get_current_buf(), 3 }, { thread.bufnr, thread.last_row })
  t.eq({ ' ⠋ hi' }, steady(chips(thread.bufnr)))
  teardown()
end)

t.test('an unmodified threaded buffer reloads from disk without a prompt', function()
  setup()
  local bufnr, path = open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(2, 'hi')
  back_to(win)
  t.eq(true, vim.bo[bufnr].autoread)

  rewrite(path, { 'x', 'a', 'b' })
  vim.cmd.checktime(bufnr)
  t.eq({ 'x', 'a', 'b' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  t.eq(false, vim.bo[bufnr].modified)
  t.eq(3, require('jean.thread').list()[1].last_row)
  teardown()
end)

t.test('a modified threaded buffer is left alone, with one notification', function()
  setup()
  local bufnr, path = open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(2, 'hi')
  back_to(win)
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'mine' })
  rewrite(path, { 'theirs', 'a', 'b' })
  vim.cmd.checktime(bufnr)
  rewrite(path, { 'theirs again', 'a', 'b' })
  vim.cmd.checktime(bufnr)
  t.eq({ 'mine', 'a', 'b' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  t.eq(1, #notes)
  teardown()
end)

t.test('deleting the anchor line detaches the thread and keeps its anchor', function()
  setup()
  local bufnr = open_file({ 'a', 'Q4: keep me', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(2, 'hi')
  back_to(win)
  local thread = require('jean.thread').list()[1]

  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
  t.eq({ true, 'Q4: keep me', 'Q4' }, { thread.detached, thread.anchor_text, thread.anchor_key })
  t.eq(true, vim.startswith(chips(bufnr)[1], ' ⚠'))
  teardown()
end)

t.test('a second g/ elsewhere leaves the first thread running', function()
  local Fake = setup()
  open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(1, 'first')
  back_to(win)
  ask(2, 'second')
  back_to(win)
  local provider = Fake.instances[1]
  t.eq(0, provider.stops)
  t.eq(2, #require('jean.thread').list())
  t.eq('running', require('jean.thread').list()[1].exchanges[1].status)
  teardown()
end)

t.test('pi: two threads with the same text each get their own reply', function()
  setup()
  require('jean.config')._provider = 'pi'
  open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  local session = require('jean.session').from_buffer()
  local pi = session.provider
  local sent = {}
  ---@type PiConnection
  local conn = {
    buffer = '',
    callbacks = {},
    next_id = 0,
    ready = true,
    busy = false,
    send = function(line)
      sent[#sent + 1] = vim.json.decode(line)
    end,
    close = function() end,
  }
  pi._conn = conn
  local function feed(...)
    for _, record in ipairs({ ... }) do
      pi:_on_record(conn, record)
    end
    t.flush()
  end
  local function user(text)
    return { type = 'message_start', message = { role = 'user', content = { { type = 'text', text = text } } } }
  end
  local function assistant(text)
    return {
      type = 'message_end',
      message = { role = 'assistant', stopReason = 'stop', content = { { type = 'text', text = text } } },
    }
  end
  local function run(command, reply)
    feed(
      { type = 'response', command = 'prompt', id = command.id, success = true, data = {} },
      { type = 'agent_start' },
      user(command.message),
      assistant(reply),
      { type = 'agent_settled' }
    )
  end

  ask(1, 'same\nquestion')
  back_to(win)
  ask(2, 'same\nquestion')
  back_to(win)
  local a, b = unpack(require('jean.thread').list())
  t.eq(1, #sent)
  t.eq(true, vim.startswith(sent[1].message, ('[jean thread %s ·'):format(a.id)))
  t.eq(true, vim.endswith(sent[1].message, '\nsame\nquestion'))

  run(sent[1], 'for a')
  t.eq(2, #sent)
  t.eq(true, vim.startswith(sent[2].message, ('[jean thread %s ·'):format(b.id)))
  run(sent[2], 'for b')

  t.eq({ { 'same\nquestion', 'done', { 'for a' } } }, responses(a))
  t.eq({ { 'same\nquestion', 'done', { 'for b' } } }, responses(b))
  teardown()
end)

t.finish()
