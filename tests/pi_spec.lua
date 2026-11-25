local t = require('helpers')

---A Pi provider on a fake, ready connection: what it sends is decoded into
---`sent`, what it emits is collected into `messages`.
local function new_pi()
  local Pi = require('jean.session.pi')
  local messages = {}
  local pi = Pi:new({
    pwd = '/proj',
    on_message = function(message)
      messages[#messages + 1] = message
    end,
  })
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
  end
  return pi, feed, messages, sent
end

local function user(text)
  return { type = 'message_start', message = { role = 'user', content = { { type = 'text', text = text } } } }
end

local function delta(text)
  return {
    type = 'message_update',
    assistantMessageEvent = { type = 'text_delta', delta = text, contentIndex = 0 },
  }
end

local function assistant(text)
  return {
    type = 'message_end',
    message = { role = 'assistant', stopReason = 'stop', content = { { type = 'text', text = text } } },
  }
end

local function accepted(command)
  return { type = 'response', command = 'prompt', id = command.id, success = true, data = {} }
end

t.test('a prompt starts at its echo and ends when pi settles', function()
  local pi, feed, messages, sent = new_pi()
  pi:prompt('hello')
  t.eq({ { type = 'prompt', message = 'hello', id = 'jean-1' } }, sent)

  feed(accepted(sent[1]), { type = 'agent_start' }, user('hello'), delta('Hi'), assistant('Hi'))
  t.eq({ { type = 'text_delta', text = 'Hi' }, { type = 'text', text = 'Hi', streamed = true } }, messages)

  feed({ type = 'agent_settled' })
  t.eq({ type = 'done' }, messages[3])
  t.eq(3, #messages)
end)

t.test('a user message while jean runs ends it and starts a foreign run', function()
  local pi, feed, messages, sent = new_pi()
  pi:prompt('hello')
  feed(accepted(sent[1]), { type = 'agent_start' }, user('hello'), assistant('partial'))
  feed(user('typed in pi'), assistant('to the user'), { type = 'agent_settled' })

  t.eq({
    { type = 'text', text = 'partial' },
    { type = 'done' },
    { type = 'user_prompt', text = 'typed in pi', foreign = true },
    { type = 'text', text = 'to the user', foreign = true },
    { type = 'done', foreign = true },
  }, messages)
end)

t.test('a prompt sent while pi is busy follows up after the foreign run', function()
  local pi, feed, messages, sent = new_pi()
  feed({ type = 'agent_start' }, user('typed in pi'), delta('working'))

  pi:prompt('hello')
  t.eq('followUp', sent[1].streamingBehavior)
  feed(accepted(sent[1]), assistant('working'))
  -- The follow-up is delivered within the same agent run
  feed(user('hello'), assistant('Hi'), { type = 'agent_settled' })

  t.eq({
    { type = 'user_prompt', text = 'typed in pi', foreign = true },
    { type = 'text_delta', text = 'working', foreign = true },
    { type = 'text', text = 'working', streamed = true, foreign = true },
    { type = 'done', foreign = true },
    { type = 'text', text = 'Hi' },
    { type = 'done' },
  }, messages)
end)

t.test('the next prompt after one ended by a user message is a follow-up', function()
  local pi, feed, messages, sent = new_pi()
  pi:prompt('first')
  feed(accepted(sent[1]), { type = 'agent_start' }, user('first'), user('typed in pi'))
  t.eq({ type = 'done' }, messages[1])

  pi:prompt('second')
  t.eq('followUp', sent[2].streamingBehavior)
  feed(accepted(sent[2]), assistant('to the user'), user('second'), assistant('reply'), { type = 'agent_settled' })
  t.eq({
    { type = 'done' },
    { type = 'user_prompt', text = 'typed in pi', foreign = true },
    { type = 'text', text = 'to the user', foreign = true },
    { type = 'done', foreign = true },
    { type = 'text', text = 'reply' },
    { type = 'done' },
  }, messages)
end)

t.test('the echo of a stopped prompt is not mistaken for a foreign run', function()
  local pi, feed, messages, sent = new_pi()
  pi:prompt('first')
  pi:stop()
  t.eq('abort', sent[2].type)
  pi:prompt('second')
  feed({ type = 'agent_start' }, user('first'), user('second'), assistant('reply'), { type = 'agent_settled' })
  t.eq({ { type = 'text', text = 'reply' }, { type = 'done' } }, messages)
end)

t.test('a prompt held by an extension starts when its batch is released', function()
  local pi, feed, messages, sent = new_pi()
  pi:prompt('first')
  feed(accepted(sent[1]), { type = 'agent_start' }, user('first'))
  feed({
    type = 'message_end',
    message = { role = 'assistant', stopReason = 'error', errorMessage = '429 rate_limit_error', content = {} },
  }, { type = 'agent_settled' })
  t.eq({ type = 'done', error = '429 rate_limit_error' }, messages[1])

  -- message-hold swallows the prompt (pi-editor still answers "started"),
  -- then sends it hours later wrapped in one message with a continuation note
  pi:prompt('second')
  feed(accepted(sent[2]))
  feed(
    { type = 'agent_start' },
    user('(Continuing after the usage limit.)\n\n[11:34] second'),
    assistant('reply'),
    { type = 'agent_settled' }
  )
  t.eq({ { type = 'text', text = 'reply' }, { type = 'done' } }, vim.list_slice(messages, 2))
end)

t.finish()
