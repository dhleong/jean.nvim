vim.api.nvim_create_user_command('JeanThreads', function()
  require('jean').threads()
end, { desc = 'Jean: list the threads in this project' })

vim.api.nvim_create_autocmd('BufReadPost', {
  group = vim.api.nvim_create_augroup('jean.threads', { clear = true }),
  desc = 'Jean: load the threads of the file',
  callback = function(args)
    require('jean.inline').read_buffer(args.buf)
  end,
})
