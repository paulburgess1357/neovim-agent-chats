-- A staged scene for looking at the board: chats in every state, built from
-- synthetic data in a temporary folder. Nothing real is read.
--
--   nvim --clean --cmd 'set columns=150 lines=40' -c 'luafile tests/demo.lua'
--
-- With DEMO_DUMP=1 (headless) it prints the screen and quits instead.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = table.concat({ root .. '/tests/?.lua', package.path }, ';')
vim.o.swapfile = false
vim.cmd('runtime plugin/agent-chats.lua')

local fx = require('helpers.claude')
local now = os.time()
local home = fx.home({ watch = { enabled = true }, board = { spinner = vim.env.DEMO_DUMP == nil } })
local sleepers = {}

local function alive()
  local job = vim.system({ 'sleep', '600' })
  sleepers[#sleepers + 1] = job
  return job.pid
end

local function chat(o)
  local c = home:chat({ cwd = o.cwd, branch = o.branch, start = now - o.age - 30 })
  c:user(o.prompt):title(o.title)
  c:tool_use('Bash', { command = o.cmd or 'make test' })
  if o.state == 'pending' then
    c.ts = now - o.age
    return c:write(now - o.age)
  end
  c:tool_result('ok')
  if o.state == 'working' then
    c:tool_use('Edit', { file_path = o.cwd .. '/src/main.lua', old_string = 'a', new_string = 'b' })
    return c:write(now - o.age)
  end
  c:assistant(o.reply or 'Done.')
  c.ts = now - o.age - 1
  c:turn_done()
  return c:write(now - o.age)
end

local a = chat({
  title = 'Fix flaky session restore',
  prompt = 'The session restore test fails one run in five. Find out why.',
  cwd = '/work/nvim-config',
  branch = 'main',
  age = 95,
  state = 'pending',
  cmd = 'rm -rf .cache/sessions',
})
home:registry(alive(), {
  sessionId = a.id,
  status = 'waiting',
  waitingFor = 'permission to run: rm -rf .cache/sessions',
  cwd = a.cwd,
})
local b = chat({
  title = 'Port the renderer to Vulkan',
  prompt = 'Port the renderer.',
  cwd = '/work/engine',
  branch = 'wt/vulkan',
  age = 41,
  state = 'working',
})
home:registry(alive(), { sessionId = b.id, status = 'busy', cwd = b.cwd })
local c = chat({
  title = 'Add a picker for tab pages',
  prompt = 'Add a picker.',
  cwd = '/work/nvim-config',
  branch = 'tabs',
  age = 12,
  state = 'working',
})
home:registry(alive(), { sessionId = c.id, status = 'busy', cwd = c.cwd })
local d = chat({
  title = 'Write the README',
  prompt = 'Write a README for the plan repo, covering setup and the weekly workflow.',
  cwd = '/work/plan',
  branch = 'main',
  age = 240,
  reply = 'The README is written.\n\n- **Setup** covers the two commands needed.\n- **Workflow** walks through a week.\n\nOne thing to check: the badge URL is a guess.',
})
home:registry(alive(), { sessionId = d.id, status = 'idle', cwd = d.cwd })
local e = chat({
  title = 'Refactor the audio mixer',
  prompt = 'Refactor.',
  cwd = '/work/engine',
  branch = 'main',
  age = 1500,
  reply = 'Refactored.',
})
home:registry(alive(), { sessionId = e.id, status = 'idle', cwd = e.cwd })
chat({
  title = 'Explain the borrow checker error',
  prompt = 'Explain.',
  cwd = '/work/engine',
  branch = 'main',
  age = 7200,
})
local g = chat({
  title = 'Review the release checklist',
  prompt = 'Review.',
  cwd = '/work/plan',
  branch = 'release',
  age = 86400 * 2,
})
chat({
  title = 'Migrate the config to vim.pack',
  prompt = 'Migrate.',
  cwd = '/work/nvim-config',
  branch = 'main',
  age = 86400 * 5,
})

local state = require('agent-chats.state')
local store = require('agent-chats.store')
state.update(function(s)
  s.baseline = now - 600
  s.seen['claude:' .. e.id] = now
  s.pins['claude:' .. g.id] = true
  s.labels['claude:' .. g.id] = { 'release' }
  s.notes['claude:' .. a.id] = 'check before approving'
end)
store.refresh_sync()

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    for _, job in ipairs(sleepers) do
      job:kill(9)
    end
  end,
})

vim.cmd('Chats')

if vim.env.DEMO_DUMP then
  local board = require('agent-chats.ui.board')
  local function dump(label)
    vim.wait(80)
    vim.cmd('redraw')
    io.stdout:write('\n=== ' .. label .. ' ===\n')
    for r = 1, vim.o.lines do
      local line = {}
      for col = 1, vim.o.columns do
        line[#line + 1] = vim.fn.screenstring(r, col)
      end
      io.stdout:write((table.concat(line):gsub('%s+$', '')) .. '\n')
    end
  end
  dump('by status')
  if vim.env.DEMO_DUMP == 'all' then
    board.goto_chat('claude:' .. d.id)
    dump('a finished chat')
    board.set_group('folder')
    dump('by folder')
    board.set_group('status')
    require('agent-chats.actions').transcript(store.get('claude:' .. d.id))
    vim.wait(300)
    dump('conversation')
    board.focus()
    require('agent-chats.ui.help').open()
    dump('help')
  end
  for _, job in ipairs(sleepers) do
    job:kill(9)
  end
  vim.cmd('qa!')
end
