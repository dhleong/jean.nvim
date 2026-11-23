local t = require('helpers')

---@return Session, FakeProvider
local function new_session()
  local Fake = t.use_fake_provider()
  local session = require('jean.session')._get_or_create(vim.fn.getcwd(), vim.fn.getcwd())
  require('jean.window')._get_or_create(session)
  return session, Fake.instances[1]
end

---Submit a prompt whose callbacks record what they see
---@param session Session
---@param text string
---@param opts? SubmitPromptOpts
local function submit(session, text, opts)
  local seen = { started = false, messages = {}, results = {} }
  local handle = session:submit_prompt(
    text,
    vim.tbl_extend('force', {
      spinner = false,
      on_start = function()
        seen.started = true
      end,
      on_message = function(message)
        seen.messages[#seen.messages + 1] = message
      end,
      on_done = function(result)
        seen.results[#seen.results + 1] = result
      end,
    }, opts or {})
  )
  seen.cancel = handle.cancel
  return seen
end

---@param session Session
local function window_lines(session)
  return vim.api.nvim_buf_get_lines(session:window().bufnr, 0, -1, false)
end

local function index_of(lines, line, from)
  for i = from or 1, #lines do
    if lines[i] == line then
      return i
    end
  end
  error('missing line ' .. vim.inspect(line) .. ' in ' .. vim.inspect(lines), 2)
end

t.test('queued prompts are sent one at a time, each reply to its own callbacks', function()
  local session, provider = new_session()
  local a = submit(session, 'A')
  local b = submit(session, 'B')
  t.eq({ 'A' }, provider.prompts)
  t.eq(true, a.started)
  t.eq(false, b.started)

  provider:emit({ type = 'text', text = 'reply A' })
  provider:emit({ type = 'done' })
  t.flush()
  t.eq({ { type = 'text', text = 'reply A' }, { type = 'done' } }, a.messages)
  t.eq({ { success = true } }, a.results)
  t.eq({ 'A', 'B' }, provider.prompts)
  t.eq(true, b.started)
  t.eq({}, b.messages)

  provider:emit({ type = 'text', text = 'reply B' })
  provider:emit({ type = 'done', error = 'boom' })
  t.flush()
  t.eq({ { type = 'text', text = 'reply B' }, { type = 'done', error = 'boom' } }, b.messages)
  t.eq({ { success = false, error = 'boom' } }, b.results)
  t.eq(2, #a.messages)
  t.eq({}, session.queue)
  t.eq(true, vim.bo[session:window().bufnr].modifiable)
end)

t.test('cancelling a queued prompt drops it without sending', function()
  local session, provider = new_session()
  local a = submit(session, 'A')
  local b = submit(session, 'B')
  local c = submit(session, 'C')

  t.eq(true, b.cancel())
  t.eq(false, b.cancel())
  t.eq({ { success = false, error = 'Execution canceled.' } }, b.results)
  t.eq(0, provider.stops)
  t.eq({ 'A' }, provider.prompts)

  provider:emit({ type = 'done' })
  t.flush()
  t.eq({ { success = true } }, a.results)
  t.eq({ 'A', 'C' }, provider.prompts)
  t.eq(true, c.started)
  t.eq(false, b.started)
end)

t.test('cancelling the running prompt stops the provider and starts the next', function()
  local session, provider = new_session()
  local a = submit(session, 'A')
  local b = submit(session, 'B')

  -- Emitted before the stop but delivered after it: must not reach B
  provider:emit({ type = 'text', text = 'late A' })
  t.eq(true, a.cancel())
  t.flush()

  t.eq(1, provider.stops)
  t.eq({ { success = false, error = 'Execution canceled.' } }, a.results)
  t.eq({ 'A', 'B' }, provider.prompts)
  t.eq({}, a.messages)
  t.eq({}, b.messages)
  t.eq(false, vim.bo[session:window().bufnr].modifiable)

  provider:emit({ type = 'done' })
  t.flush()
  t.eq({ { success = true } }, b.results)
end)

t.test('cancel_active_prompt cancels only the running prompt', function()
  local session, provider = new_session()
  t.eq(false, session:cancel_active_prompt())
  local a = submit(session, 'A')
  local b = submit(session, 'B')

  t.eq(true, session:cancel_active_prompt())
  t.eq({ { success = false, error = 'Execution canceled.' } }, a.results)
  t.eq({}, b.results)
  t.eq({ 'A', 'B' }, provider.prompts)
end)

t.test('a foreign run reaches no prompt callback, only the chat window', function()
  local session, provider = new_session()
  local a = submit(session, 'A')
  local b = submit(session, 'B')
  provider:emit({ type = 'text', text = 'reply A' })
  provider:emit({ type = 'done' })
  t.flush()

  -- B is sent but pi is still busy with a run someone typed in pi
  provider:emit({ type = 'user_prompt', text = 'typed in pi', foreign = true })
  provider:emit({ type = 'text', text = 'foreign reply', foreign = true })
  provider:emit({ type = 'done', foreign = true })
  t.flush()
  t.eq({}, b.messages)
  t.eq({}, b.results)
  t.eq(2, #a.messages)
  t.eq(false, vim.bo[session:window().bufnr].modifiable)

  provider:emit({ type = 'text', text = 'reply B' })
  provider:emit({ type = 'done' })
  t.flush()
  t.eq({ { type = 'text', text = 'reply B' }, { type = 'done' } }, b.messages)

  local lines = window_lines(session)
  local foreign = index_of(lines, 'typed in pi')
  index_of(lines, 'foreign reply', foreign)
  index_of(lines, 'reply B', foreign)
end)

t.test('context is built when a prompt is sent, unless disabled', function()
  local session, provider = new_session()
  submit(session, 'A')
  submit(session, 'B')
  submit(session, 'C', { context = false })

  local file = vim.fs.joinpath(vim.fn.getcwd(), 'some/file.lua')
  vim.cmd.edit(file)
  session:capture_context_source()
  t.eq({ 'A' }, provider.prompts)

  provider:emit({ type = 'done' })
  t.flush()
  t.eq(
    table.concat({ '# Context', 'User is looking at: ./some/file.lua', 'Current line #1', '', '# Request', '', 'B' }, '\n'),
    provider.prompts[2]
  )

  provider:emit({ type = 'done' })
  t.flush()
  t.eq('C', provider.prompts[3])
end)

t.test('a provider that fails to start ends its prompt and the queue goes on', function()
  local session, provider = new_session()
  local prompt = provider.prompt
  provider.prompt = function()
    error('no such executable')
  end
  local a = submit(session, 'A')
  provider.prompt = prompt
  local b = submit(session, 'B')

  t.eq(false, a.results[1].success)
  assert(a.results[1].error:find('no such executable'), a.results[1].error)
  t.eq({ 'B' }, provider.prompts)
  t.eq(true, b.started)
end)

t.test('jean.submit renders queued prompts in order in the chat window', function()
  -- Keep project.lua's vim-test strategy from failing without vim-test
  vim.g['test#project_root'] = '/nonexistent'
  t.use_fake_provider()
  local jean = require('jean')
  jean.submit('first')
  jean.submit('second')
  local session = require('jean.session').from_buffer()
  local provider = require('fake_provider').instances[1]
  t.eq(1, #provider.prompts)
  assert(vim.endswith(provider.prompts[1], '\n\nfirst'), provider.prompts[1])

  local lines = window_lines(session)
  local first = index_of(lines, 'first')
  index_of(lines, '### Response', first)
  assert(not vim.tbl_contains(lines, 'second'), 'second rendered before it was sent')
  t.eq(false, vim.bo[session:window().bufnr].modifiable)

  provider:emit({ type = 'text_delta', text = 'answer' })
  provider:emit({ type = 'text_delta', text = ' one' })
  provider:emit({ type = 'text', text = 'answer one', streamed = true })
  provider:emit({ type = 'done' })
  t.flush()
  t.eq({ provider.prompts[1], 'second' }, provider.prompts)
  t.eq(false, vim.bo[session:window().bufnr].modifiable)

  provider:emit({ type = 'text', text = 'answer two' })
  provider:emit({ type = 'done' })
  t.flush()
  t.eq(true, vim.bo[session:window().bufnr].modifiable)

  lines = window_lines(session)
  local separator = require('jean.config').request_separator
  first = index_of(lines, 'first')
  local response = index_of(lines, '### Response', first)
  local answer = index_of(lines, 'answer one', response)
  local request = index_of(lines, separator, answer)
  local second = index_of(lines, 'second', request)
  local response2 = index_of(lines, '### Response', second)
  local answer2 = index_of(lines, 'answer two', response2)
  index_of(lines, separator, answer2)
  t.eq('', lines[#lines])
end)

t.finish()
