---@class JeanTextMessage
---@field type 'text'
---@field text string
---@field streamed? boolean its text was already delivered as text_delta chunks

---A chunk of the assistant text currently being produced. Chunks concatenate
---exactly and may contain or split around newlines.
---@class JeanTextDeltaMessage
---@field type 'text_delta'
---@field text string

---An edit the agent made to a file.
---@class JeanEditMessage
---@field type 'edit'
---@field file_path string
---@field old_text string the text that was replaced
---@field lnum? number 1-based line in file_path after the edit, if the provider knows it

---@class JeanResumeTokenMessage
---@field type 'resume_token'
---@field token string opaque id a provider uses to resume the conversation

---The agent finished responding to this prompt.
---@class JeanDoneMessage
---@field type 'done'
---@field error? string why the prompt failed, if it did

---@alias JeanMessage JeanTextMessage|JeanTextDeltaMessage|JeanEditMessage|JeanResumeTokenMessage|JeanDoneMessage

---@class JeanProviderOpts
---@field pwd string
---@field on_message fun(msg: JeanMessage) may be called at any time, not only while a prompt is running

---A long-lived connection to an agent, created once per Session.
---@class JeanProvider
---@field new fun(self, opts: JeanProviderOpts): JeanProvider
---Start answering one prompt. Exactly one `done` message follows unless the
---prompt is stopped. The provider keeps its own resume token across prompts.
---@field prompt fun(self, text: string)
---Stop the in-flight prompt; no further messages for it are delivered.
---@field stop fun(self)
---Release resources; the provider is not used afterwards.
---@field destroy fun(self)
