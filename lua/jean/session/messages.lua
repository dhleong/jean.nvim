---Any message may also set `foreign = true`: it belongs to a run that a
---`user_prompt` started, not to jean's own prompt.
---@class JeanMessageBase
---@field foreign? boolean

---@class JeanTextMessage : JeanMessageBase
---@field type 'text'
---@field text string
---@field streamed? boolean its text was already delivered as text_delta chunks

---A chunk of the assistant text currently being produced. Chunks concatenate
---exactly and may contain or split around newlines.
---@class JeanTextDeltaMessage : JeanMessageBase
---@field type 'text_delta'
---@field text string

---An edit the agent made to a file.
---@class JeanEditMessage : JeanMessageBase
---@field type 'edit'
---@field file_path string
---@field old_text string the text that was replaced
---@field lnum? number 1-based line in file_path after the edit, if the provider knows it

---@class JeanResumeTokenMessage : JeanMessageBase
---@field type 'resume_token'
---@field token string opaque id a provider uses to resume the conversation

---A prompt the user sent to the agent outside jean. The messages that follow,
---up to its `done`, are the agent's response to it.
---@class JeanUserPromptMessage : JeanMessageBase
---@field type 'user_prompt'
---@field text string

---The agent finished responding to this prompt.
---@class JeanDoneMessage : JeanMessageBase
---@field type 'done'
---@field error? string why the prompt failed, if it did

---@alias JeanMessage JeanTextMessage|JeanTextDeltaMessage|JeanEditMessage|JeanResumeTokenMessage|JeanUserPromptMessage|JeanDoneMessage

---@class JeanProviderOpts
---@field pwd string
---@field on_message fun(msg: JeanMessage) may be called at any time, not only while a prompt is running
---@field socket? string PI_RPC_SOCKET of the pi that launched nvim, for providers that can use it

---A long-lived connection to an agent, created once per Session.
---@class JeanProvider
---@field new fun(self, opts: JeanProviderOpts): JeanProvider
---Start answering one prompt. Exactly one `done` message follows unless the
---prompt is stopped. Called only when no prompt is in flight: the Session
---queues prompts and sends the next after this one's `done` (or `stop`).
---The provider keeps its own resume token across prompts.
---@field prompt fun(self, text: string)
---Stop the in-flight prompt; no further messages for it are delivered.
---@field stop fun(self)
---Release resources; the provider is not used afterwards.
---@field destroy fun(self)
