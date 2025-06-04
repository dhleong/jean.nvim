local M = {}

---@param session Session
---@return string|nil
function M.build(session)
  local buf = session.last_buffer
  if not buf then
    return nil
  end

  local lines = {
    '# Context',
    'User is looking at: ' .. buf:get_relative_path(session.pwd),
  }

  local winid = session.last_buffer_winid
  if winid then
    local linenr = vim.fn.line('.', winid)
    if linenr ~= 0 then
      lines[#lines + 1] = 'Current line #' .. linenr
    end
  end

  vim.list_extend(lines, {
    '',
    '# Request',
  })
  return table.concat(lines, '\n')
end

return M
