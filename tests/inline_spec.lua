local t = require('helpers')

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
  require('jean').setup({})
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
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(winid).relative ~= '' then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.cmd('silent! %bwipeout!')
  t.flush()
end

t.test('two queued threads in one buffer: each reply lands in its own thread', function()
  local Fake = setup()
  local bufnr = open_file({ 'one', 'two', 'three' })
  local win = vim.api.nvim_get_current_win()

  ask(1, 'about one')
  back_to(win)
  ask(3, 'about three')
  back_to(win)

  local T = require('jean.threads')
  local a, b = unpack(T.list())
  local provider = Fake.instances[1]
  t.eq(1, #provider.prompts)
  t.eq(('[jean thread %s · %s · near line 1 · "one"]\nabout one'):format(a.id, a.path), provider.prompts[1])
  t.eq({ { 'about three', 'queued', {} } }, responses(b))
  t.eq({ ' ⠋ you: about one', ' … you: about three' }, steady(chips(bufnr)))

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
  t.eq({ ' ● reply A', ' ✗ boom' }, chips(bufnr))
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
  local a, b = unpack(require('jean.threads').list())
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

---@return number[] ids of the open floating windows
local function floats()
  return vim.tbl_filter(function(winid)
    return vim.api.nvim_win_get_config(winid).relative ~= ''
  end, vim.api.nvim_list_wins())
end

---@param winid number
---@return string[]
local function window_lines(winid)
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false)
end

---Open a thread on row 1 with two finished exchanges and `g/` on it again
---@return FakeProvider provider, number win, Thread thread
local function reply_input_with_history()
  local Fake = setup()
  open_file({ 'one', 'two' })
  local win = vim.api.nvim_get_current_win()
  local provider
  for _, text in ipairs({ 'first', 'second' }) do
    ask(1, text)
    back_to(win)
    provider = Fake.instances[1]
    provider:emit({ type = 'text', text = 'answer ' .. text })
    provider:emit({ type = 'done' })
    t.flush()
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require('jean').prompt_inline()
  return provider, win, require('jean.threads').list()[1]
end

t.test('reply input shows the latest exchange above it', function()
  local provider, win, thread = reply_input_with_history()
  local input = vim.api.nvim_get_current_win()
  local all = floats()
  t.eq(2, #all)
  local context = vim.tbl_filter(function(winid)
    return winid ~= input
  end, all)[1]
  t.eq({ 'second', '', 'answer second' }, window_lines(context))
  t.eq({ '' }, window_lines(input))
  local input_config, context_config = vim.api.nvim_win_get_config(input), vim.api.nvim_win_get_config(context)
  t.eq(input_config.col, context_config.col)
  t.eq(true, context_config.row + context_config.height == input_config.row or context_config.row == input_config.row + input_config.height)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'third' })
  press('<cr>')
  t.eq('third', thread.exchanges[3].prompt)
  t.eq(true, vim.endswith(provider.prompts[3], '\nthird'))
  t.eq(1, #floats())
  teardown()
end)

t.test('reply input context closes with the input on cancel', function()
  reply_input_with_history()
  t.eq(2, #floats())
  press('<esc>')
  t.eq(0, #floats())
  teardown()
end)

t.test('reply input shows the partial response of a streaming exchange', function()
  local Fake = setup()
  open_file({ 'one' })
  local win = vim.api.nvim_get_current_win()
  ask(1, 'ask')
  back_to(win)
  Fake.instances[1]:emit({ type = 'text', text = 'so far' })
  t.flush()
  require('jean').prompt_inline()
  local input = vim.api.nvim_get_current_win()
  local context = vim.tbl_filter(function(winid)
    return winid ~= input
  end, floats())[1]
  t.eq({ 'ask', '', 'so far' }, window_lines(context))
  press('q')
  t.eq(0, #floats())
  teardown()
end)

t.test('a new thread input has no context', function()
  setup()
  open_file({ 'one' })
  require('jean').prompt_inline()
  t.eq(1, #floats())
  press('q')
  t.eq(0, #floats())
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
  local by_text, by_id, gone = unpack(require('jean.threads').list())

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
  t.eq({ ' … you: q3', ' ⚠ you: q4', ' ⠋ you: q2' }, labels)
  t.eq(3, #require('jean.threads').list())

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
  local thread = require('jean.threads').list()[1]
  vim.cmd.bwipeout(bufnr)
  t.eq(nil, thread.bufnr)

  rewrite(path, { 'top', 'a', 'b' })
  vim.cmd.edit(path)
  t.eq({ vim.api.nvim_get_current_buf(), 3 }, { thread.bufnr, thread.last_row })
  t.eq({ ' ⠋ you: hi' }, steady(chips(thread.bufnr)))
  teardown()
end)

t.test('overlapping reads through a yielding store bind each thread once', function()
  setup()
  local bufnr, path = open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(2, 'hi')
  back_to(win)
  local T = require('jean.threads')
  local memory = T.store()
  require('jean').setup({
    thread_store = {
      load = function(_, p)
        T.await(vim.schedule)
        return memory:load(p)
      end,
      save = function(_, thread)
        memory:save(thread)
      end,
      remove = function(_, thread)
        memory:remove(thread)
      end,
    },
  })
  vim.cmd.bwipeout(bufnr)
  vim.cmd.edit(path)
  bufnr = vim.api.nvim_get_current_buf()
  require('jean.inline').read_buffer(bufnr)
  t.flush()
  t.flush()

  local thread_ns = vim.api.nvim_create_namespace('jean.threads')
  t.eq(1, #T.list())
  t.eq(1, #vim.api.nvim_buf_get_extmarks(bufnr, thread_ns, 0, -1, {}))
  t.eq(bufnr, T.list()[1].bufnr)
  teardown()
end)

t.test('a threaded buffer whose file is deleted keeps its lines and threads', function()
  setup()
  local bufnr, path = open_file({ 'a', 'b' })
  local win = vim.api.nvim_get_current_win()
  ask(2, 'hi')
  back_to(win)
  os.remove(path)
  vim.cmd.checktime(bufnr)
  local thread = require('jean.threads').list()[1]
  t.eq({ 'a', 'b' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  t.eq({ bufnr, false, 2 }, { thread.bufnr, thread.detached, thread.last_row })
  t.eq({ ' ⠋ you: hi' }, steady(chips(bufnr)))
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
  t.eq(3, require('jean.threads').list()[1].last_row)
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
  local thread = require('jean.threads').list()[1]

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
  t.eq(2, #require('jean.threads').list())
  t.eq('running', require('jean.threads').list()[1].exchanges[1].status)
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
  local a, b = unpack(require('jean.threads').list())
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

t.test('chip previews the latest message of the thread', function()
  local Fake = setup()
  local bufnr = open_file({ 'one', 'two' })
  local win = vim.api.nvim_get_current_win()

  ask(1, 'first\nquestion')
  back_to(win)
  t.eq({ ' ⠋ you: first question' }, steady(chips(bufnr)))

  local provider = Fake.instances[1]
  provider:emit({ type = 'text_delta', text = '## The ' })
  t.flush()
  t.eq({ ' ⠋ The' }, steady(chips(bufnr)))
  provider:emit({ type = 'text_delta', text = '**answer**\nis here' })
  t.flush()
  t.eq({ ' ⠋ The **answer** is here' }, steady(chips(bufnr)))
  provider:emit({ type = 'text', text = '## The **answer**\nis here', streamed = true })
  provider:emit({ type = 'done' })
  t.flush()
  t.eq({ ' ● The **answer** is here' }, chips(bufnr))

  ask(1, 'and then?')
  back_to(win)
  t.eq({ ' ⠋ you: and then?' }, steady(chips(bufnr)))
  for _, label in ipairs(chips(bufnr)) do
    t.eq(nil, label:find('[jean thread', 1, true))
  end
  teardown()
end)

t.finish()
