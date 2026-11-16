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

---@alias JeanMessage JeanTextMessage|JeanTextDeltaMessage|JeanEditMessage|JeanResumeTokenMessage|JeanDoneMessage
