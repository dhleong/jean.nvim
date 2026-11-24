local t = require('helpers')

local SOCKET = '/nonexistent/jean-test.sock'

---@param path string
local function buffer_for(path)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, path)
  return bufnr
end

local cwd = vim.fn.getcwd()
local project_a = '/nonexistent/project-a'
-- project.lua's vim-test strategy gives buffers under it their own root
vim.g['test#project_root'] = project_a
local in_a = buffer_for(project_a .. '/a.lua')
local in_cwd = buffer_for(vim.fs.joinpath(cwd, 'b.lua'))
local plan = buffer_for(vim.fs.joinpath(cwd, '.pi/build/2026-11-23-00-48-16/plan.md'))

t.test('without PI_RPC_SOCKET, sessions follow project roots', function()
  vim.env.PI_RPC_SOCKET = nil
  local Fake = t.use_fake_provider()
  local sessions = require('jean.session')

  t.eq(project_a, require('jean.project').root_for_buffer(in_a))
  t.eq(project_a, sessions.from_buffer(in_a).id)
  t.eq(cwd, sessions.from_buffer(in_cwd).id)
  t.eq(nil, Fake.instances[1].opts.socket_path)
end)

t.test('with PI_RPC_SOCKET at load, every buffer maps to one socket session', function()
  vim.env.PI_RPC_SOCKET = SOCKET
  local Fake = t.use_fake_provider()
  local sessions = require('jean.session')
  t.eq(nil, vim.env.PI_RPC_SOCKET)

  local session = sessions.from_buffer(in_a)
  t.eq('__PI_SOCKET__', session.id)
  t.eq(cwd, session.pwd)
  t.eq(session, sessions.from_buffer(in_cwd))
  t.eq(session, sessions.from_buffer(plan))
  t.eq(session, sessions.from_buffer(require('jean.window')._get_or_create(session).bufnr))

  t.eq(1, #Fake.instances)
  t.eq(SOCKET, Fake.instances[1].opts.socket_path)
end)

t.test('the socket session chat header shows its pwd, not its id', function()
  vim.env.PI_RPC_SOCKET = SOCKET
  t.use_fake_provider()
  local window = require('jean.window')
  local session = require('jean.session').from_buffer(in_a)

  t.eq('> *Root Dir*: ' .. cwd, vim.api.nvim_buf_get_lines(window._get_or_create(session).bufnr, 0, 1, false)[1])
end)

t.finish()
