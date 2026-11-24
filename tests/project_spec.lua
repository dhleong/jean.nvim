local t = require('helpers')

t.test('vim-test strategy yields to the next strategy without g:test#project_root', function()
  vim.g['test#project_root'] = nil
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(vim.fn.getcwd(), 'a.lua'))

  t.eq(vim.fn.getcwd(), require('jean.project').root_for_buffer(bufnr))
end)

t.finish()
