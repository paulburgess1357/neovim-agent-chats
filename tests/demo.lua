-- A staged scene for looking at the board: chats of three agents in every
-- state, built from synthetic data in a temporary folder. Nothing real is
-- read: `$HOME` and the XDG folders are moved there first.
--
--   nvim --clean --cmd 'set columns=150 lines=40' -c 'luafile tests/demo.lua'
--
-- With DEMO_DUMP set (headless) it prints screens as text and quits:
--
--   DEMO_DUMP=board   the board as it opens
--   DEMO_DUMP=all     every screen: summaries, a search, a conversation,
--                     the menu, a live terminal
--   DEMO_DUMP=readme  one screen of the board, for a picture of it, and no more
--   DEMO_INTRO=1      with the introduction a first opening shows
--
--   DEMO_DUMP=all nvim --clean --headless --cmd 'set columns=150 lines=40' \
--     -c 'luafile tests/demo.lua'
--
-- Run it at 150 columns and at 80: every screen has to read well at both.
--
-- With DEMO_SCRIPT=<file.lua> (headless) it runs that file on the staged
-- scene instead, for driving the board with keys and reading what it shows.
-- The file sees these, beside everything Neovim has:
--
--   setup(opts)     options laid over the demo's, e.g. { keys = { read = 'c' } }
--   open()          :Chats (make mappings of your own before it)
--   press(keys)     type keys, in Vim's notation: press('jj'), press('?'),
--                   press('Sparser<CR>'), press('ihello<Esc>')
--   screen(label)   print the screen, and the lines of every floating window
--   wait(ms)        let time pass (an agent starting, a search running)
--   say(text)       print a line of your own between the screens
--
-- Whatever is opened, replied to or started in this scene runs a stand-in
-- script, never a real agent.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path = table.concat({ root .. '/tests/?.lua', package.path }, ';')
vim.o.swapfile = false

-- A home of its own, so that folders read as `~/work/...` and nothing of
-- yours is looked at or written to.
local sandbox = vim.fn.tempname() .. '-agent-chats-demo'
vim.fn.mkdir(sandbox .. '/home', 'p')
vim.env.HOME = sandbox .. '/home'
for _, name in ipairs({ 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME' }) do
  vim.env[name] = ('%s/%s'):format(sandbox, name:lower())
end
for _, name in ipairs({ 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'QWEN_HOME', 'QWEN_RUNTIME_DIR' }) do
  vim.env[name] = nil
end
vim.cmd('runtime plugin/agent-chats.lua')
-- Processes as well: an agent you have running right now is found by its
-- process, and would turn up in the scene as a chat of yours. Only what this
-- scene starts itself is seen.
require('agent-chats.util.proc')._scope = vim.uv.os_getpid()

local fx = require('helpers.claude')
local cx = require('helpers.codex')
local qx = require('helpers.qwen')
local now = os.time()
-- Printing screens as text: with DEMO_DUMP, or from a script.
local dumping = vim.env.DEMO_DUMP ~= nil or vim.env.DEMO_SCRIPT ~= nil

-- Each helper makes a home and selects it; the last one selects all three.
local codex_home = cx.home()
local qwen_home = qx.home()
local home = fx.home({
  providers = {
    codex = { enabled = true, home = codex_home.dir },
    qwen = { enabled = true, home = qwen_home.dir },
  },
  watch = { enabled = true },
  board = { spinner = not dumping, intro = vim.env.DEMO_INTRO ~= nil },
  -- On, as it is for anyone who has changed nothing (the first line of the
  -- list says something only when they are off), and saying nothing while
  -- a screen is being drawn.
  notify = {
    enabled = true,
    handler = function()
      return dumping
    end,
  },
})
-- A new chat that has been told nothing yet goes by the name its agent
-- gives the session, as with the real one.
vim.env.FAKE_AGENT_NAME = 'plan-1a'

-- Stand-ins for the agents themselves: whatever is opened, replied to or
-- started from this board runs one of these, and never a real agent.
local T = require('helpers.harness')
local fake = require('helpers.fake')
local agent = fake.install(home)
for name, label in pairs({ codex = 'Codex', qwen = 'Qwen' }) do
  local exe = sandbox .. '/bin/' .. name
  T.write(exe, {
    '#!/bin/sh',
    ('echo "%s (a stand-in for the demo): $*"'):format(label),
    'echo "in $(pwd)"',
    'while IFS= read -r line; do echo "got: $line"; done',
  })
  vim.uv.fs_chmod(exe, 493)
  require('agent-chats.config').get().providers[name].cmd = { exe }
end

local function folder(name)
  local dir = vim.env.HOME .. '/work/' .. name
  vim.fn.mkdir(dir, 'p')
  return dir
end
local nvim_config, engine, plan = folder('nvim-config'), folder('engine'), folder('plan')

local stoppers = {}
local function alive()
  local job = vim.system({ 'sleep', '600' })
  stoppers[#stoppers + 1] = function()
    job:kill(9)
  end
  return job.pid
end

--- A Claude chat. `state`: "pending" (a tool call with no result), "working",
--- or finished (nil).
local function claude(o)
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
  if o.then_prompt then
    c:user(o.then_prompt):assistant(o.then_reply or 'Done.')
  end
  c.ts = now - o.age - 1
  c:turn_done()
  return c:write(now - o.age)
end

local a = claude({
  title = 'Fix flaky session restore',
  prompt = 'The session restore test fails one run in five. Find out why.',
  cwd = nvim_config,
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

local b = claude({
  title = 'Port the renderer to Vulkan',
  prompt = 'Port the renderer.',
  cwd = engine,
  branch = 'wt/vulkan',
  age = 41,
  state = 'working',
})
home:registry(alive(), { sessionId = b.id, status = 'busy', cwd = b.cwd })

-- A Codex chat mid-turn, held open by a stand-in process.
local picker = codex_home:rollout({ cwd = nvim_config, branch = 'tabs', start = now - 80 })
picker:meta():task_started()
picker:item_user('Add a picker for tab pages.'):item_command('make test', 'ok')
picker:write(now - 12)
codex_home:index(picker.id, 'Add a picker for tab pages')
local codex = cx.fake({ hold = picker.path, cwd = nvim_config })
stoppers[#stoppers + 1] = codex.stop

-- Finished and not looked at yet: two prompts, so the summary has a first
-- and a last one to tell apart.
local readme = qwen_home:chat({ cwd = plan, branch = 'main', start = now - 270 })
readme:turn(
  'Write a README for the plan repo, covering setup and the weekly workflow.',
  'A first draft is in README.md.'
)
readme:turn(
  'Shorter, and put the two setup commands first.',
  'The README is rewritten.\n\n- **Setup** comes first: the two commands, nothing else.\n- **Workflow** walks through a week in five lines.\n\nOne thing to check: the badge URL is a guess.'
)
readme:title('Write the README')
readme:write(now - 240)

local mixer = claude({
  title = 'Refactor the audio mixer',
  prompt = 'Split the mixer into a graph of nodes.',
  cwd = engine,
  branch = 'main',
  age = 1500,
  reply = 'The mixer is a graph of nodes now. All 48 tests pass.',
})
home:registry(alive(), { sessionId = mixer.id, status = 'idle', cwd = mixer.cwd })

local borrow = codex_home:rollout({ cwd = engine, branch = 'main', start = now - 7300 })
borrow:meta():task_started()
borrow:item_user('Explain the borrow checker error in src/audio/graph.rs.')
borrow:item_agent('`nodes` is borrowed mutably twice: once by the iterator, once by `connect`.')
borrow:task_complete('`nodes` is borrowed mutably twice.')
borrow:write(now - 7200)
codex_home:index(borrow.id, 'Explain the borrow checker error')

local checklist = claude({
  title = 'Review the release checklist',
  prompt = 'Review the release checklist for anything we skipped last time.',
  cwd = plan,
  branch = 'release',
  age = 86400 * 2,
  reply = 'Two steps were skipped last time: tagging, and the changelog entry.',
  then_prompt = 'Add both to the checklist, above the upload step.',
  then_reply = 'Both are in the checklist now, above "Upload the build".',
})

-- Its folder is gone: it can be read, not resumed.
local old = qwen_home:chat({ cwd = '/tmp/old-checkout', branch = 'main', start = now - 86400 * 5 })
old:turn('Migrate the config to vim.pack.', 'Migrated. The lock file is nvim-pack-lock.json.')
old:title('Migrate the config to vim.pack')
old:write(now - 86400 * 5 + 60)

local state = require('agent-chats.state')
local store = require('agent-chats.store')
state.update(function(s)
  s.baseline = now - 600
  s.seen['claude:' .. mixer.id] = now
end)
-- A reply waiting for the busy chat to finish its turn.
state.enqueue('claude:' .. b.id, 'Then run the benchmarks and post the numbers.')
-- A note: its words are on the row, behind its mark.
state.set_note('qwen:' .. readme.id, 'badge URL?')
-- The agents' status hooks are installed, as they are after the one-time
-- `:Chats hooks install` (in the sandbox: these are not your settings).
local hooks = require('agent-chats.hooks')
for _, name in ipairs({ 'codex', 'qwen' }) do
  local settings = (name == 'codex' and codex_home.dir or qwen_home.dir) .. '/settings.json'
  if name == 'qwen' then
    T.write(settings, '{}\n')
  end
  local plan_ = hooks.plan(name, 'install')
  if plan_ then
    hooks.apply(plan_)
  end
end
store.refresh_sync()

local function stop_everything()
  for _, stop in ipairs(stoppers) do
    pcall(stop)
  end
  pcall(fake.cleanup)
end
vim.api.nvim_create_autocmd('VimLeavePre', { callback = stop_everything })

--- The screen as text, row by row.
local function screen_rows()
  vim.wait(80)
  vim.cmd('redraw')
  local rows = {}
  for r = 1, vim.o.lines do
    local line = {}
    for col = 1, vim.o.columns do
      line[#line + 1] = vim.fn.screenstring(r, col)
    end
    rows[#rows + 1] = (table.concat(line):gsub('%s+$', ''))
  end
  return rows
end

if vim.env.DEMO_SCRIPT then
  local board = require('agent-chats.ui.board')
  local env = setmetatable({}, { __index = _G })
  function env.say(text_)
    io.stdout:write(tostring(text_) .. '\n')
  end
  function env.setup(opts)
    -- Over the demo's options, but with only the keys that are given: a
    -- key named in the options is bound whatever else is mapped on it.
    local base = vim.deepcopy(require('agent-chats.config').get())
    base.keys = nil
    require('agent-chats.config').setup(vim.tbl_deep_extend('force', base, opts or {}))
  end
  function env.open()
    vim.cmd('Chats')
    vim.wait(100)
  end
  function env.wait(ms)
    vim.wait(ms or 100)
  end
  function env.press(lhs)
    local codes = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    local ok_, err = pcall(vim.api.nvim_feedkeys, codes, 'xt', false)
    if not ok_ then
      env.say('press(' .. lhs .. ') failed: ' .. tostring(err))
    end
    vim.wait(60)
    -- Moving the cursor from a script fires no CursorMoved: the bar and
    -- the pane are brought up to date as they would be after a real key.
    if board.is_open() and vim.api.nvim_get_current_buf() == board._state.buf then
      board.render()
    end
  end
  function env.screen(label)
    io.stdout:write('\n=== ' .. (label or 'screen') .. ' ===\n')
    io.stdout:write(table.concat(screen_rows(), '\n') .. '\n')
    -- A floating window is not where `screenstring` looks for it.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= '' then
        local function words(chunks)
          local out = {}
          for _, chunk in ipairs(type(chunks) == 'table' and chunks or {}) do
            out[#out + 1] = chunk[1]
          end
          return vim.trim(table.concat(out))
        end
        io.stdout:write(
          ('--- floating window%s: %s ---\n'):format(
            win == vim.api.nvim_get_current_win() and ' (the cursor is in it)' or '',
            words(cfg.title)
          )
        )
        local buf = vim.api.nvim_win_get_buf(win)
        io.stdout:write(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n')
        if cfg.footer then
          io.stdout:write('--- its footer: ' .. words(cfg.footer) .. ' ---\n')
        end
      end
    end
    local messages = vim.trim(vim.fn.execute('messages'))
    if messages ~= '' then
      io.stdout:write('--- messages ---\n' .. messages .. '\n')
      vim.cmd('messages clear')
    end
  end
  local chunk, err = loadfile(vim.env.DEMO_SCRIPT)
  if not chunk then
    io.stdout:write('could not load ' .. vim.env.DEMO_SCRIPT .. ': ' .. tostring(err) .. '\n')
  else
    setfenv(chunk, env)
    local ok_, failure = xpcall(chunk, debug.traceback)
    if not ok_ then
      io.stdout:write('the script failed: ' .. tostring(failure) .. '\n')
    end
  end
  io.stdout:flush()
  stop_everything()
  vim.cmd('qa!')
end

vim.cmd('Chats')

if vim.env.DEMO_DUMP then
  local board = require('agent-chats.ui.board')
  local actions = require('agent-chats.actions')
  local function screen(label)
    io.stdout:write('\n=== ' .. label .. ' ===\n' .. table.concat(screen_rows(), '\n') .. '\n')
  end
  --- A float is not where `screenstring` looks for it: print its lines.
  local function lines(label, list)
    io.stdout:write('\n=== ' .. label .. ' ===\n' .. table.concat(list, '\n') .. '\n')
  end
  local function on(key)
    board.goto_chat(key)
    board.render()
  end

  if vim.env.DEMO_DUMP == 'readme' then
    -- The board alone, without the tab line and the status line around it.
    on('qwen:' .. readme.id)
    local rows = vim.list_slice(screen_rows(), 2, vim.o.lines - 2)
    -- Rows with nothing in either window say nothing.
    while #rows > 0 and rows[#rows]:match('^%s*│?%s*$') do
      rows[#rows] = nil
    end
    io.stdout:write(table.concat(rows, '\n') .. '\n')
    stop_everything()
    vim.cmd('qa!')
  end
  screen('the board as it opens (a chat that needs you)')
  if vim.env.DEMO_DUMP == 'all' then
    on('qwen:' .. readme.id)
    screen('an unread chat: first prompt, last prompt, last reply')
    -- Read (as going into it does): it keeps its place under the cursor.
    state.mark_seen('qwen:' .. readme.id)
    store.touch()
    screen('the same chat, read: it stays where it is until the cursor moves on')
    state.mark_unseen('qwen:' .. readme.id)
    store.touch()
    on('claude:' .. b.id)
    screen('a working chat with a reply queued')
    on('claude:' .. checklist.id)
    screen('an ended chat: Enter resumes it in its folder')
    on('qwen:' .. old.id)
    screen('a chat whose folder is gone')

    local menu = require('agent-chats.ui.menu')
    on('claude:' .. checklist.id)
    board.menu()
    lines('the menu on that ended chat', menu.lines())
    menu.close()
    on('claude:' .. b.id)
    board.menu()
    lines('the menu on the working chat with a reply queued', menu.lines())
    menu.close()
    for i, row in ipairs(board._state.rows) do
      if row.kind == 'group' then
        vim.api.nvim_win_set_cursor(board._state.win, { i, 1 })
        break
      end
    end
    board.render()
    board.menu()
    lines('the menu on a heading: the group, the list and the board', menu.lines())
    menu.close()

    -- Two chats in a group of your own: one that needs you, one that ended.
    state.set_group('claude:' .. a.id, 'Release')
    state.set_group('claude:' .. checklist.id, 'Release')
    store.touch()
    on('claude:' .. checklist.id)
    screen('a group of your own, above the others')
    board.menu()
    lines('the menu on a chat that is in a group', menu.lines())
    menu.close()
    state.set_group('claude:' .. a.id, nil)
    state.set_group('claude:' .. checklist.id, nil)
    store.touch()
    -- (Which way the switch for notifications is, its line in the menu says.)
    require('agent-chats.notify').set(false)
    on('claude:' .. checklist.id)
    board.menu()
    lines('with notifications switched off: the menu says which way the switch goes', menu.lines())
    menu.close()
    require('agent-chats.notify').set(true)

    board.set_group('folder')
    screen('grouped by folder')
    board.set_group('status')

    board.search('checklist')
    vim.wait(3000, function()
      return not board._state.search.running
    end, 20)
    screen('a search: a title, and passages inside conversations')
    board.clear()

    actions.read(store.get('qwen:' .. readme.id))
    vim.wait(300)
    screen('a conversation')
    -- With the key, as it is opened: the menu names the keys that work there.
    vim.api.nvim_feedkeys('?', 'xt', false)
    lines('the menu in a conversation', menu.lines())
    menu.close()
    board.focus()

    -- A new chat: one question, which agent, and then its own terminal.
    local real_select = vim.ui.select
    vim.ui.select = function(items, o, cb)
      local shown = { o.prompt }
      for i, item in ipairs(items) do
        shown[#shown + 1] = ('  %d: %s'):format(i, o.format_item(item))
      end
      lines('the question for a new chat', shown)
      cb(items[1])
    end
    require('agent-chats.config').get().open.start_insert = false
    actions.new({ cwd = vim.env.HOME .. '/work/plan' })
    vim.ui.select = real_select
    vim.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end, 20)
    vim.wait(200)
    store.refresh_sync({ full = false })
    board.focus()
    board.render()
    screen('back from the chat just started: its row, and the cursor on it')

    -- A chat in a terminal of this Neovim: the pane shows it live.
    require('agent-chats.config').get().open.start_insert = false
    on('claude:' .. checklist.id)
    actions.open(store.get('claude:' .. checklist.id))
    vim.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end, 20)
    vim.wait(200)
    store.refresh_sync({ full = false })
    screen('in a chat: its terminal, and the way back')
    board.focus()
    board.render()
    screen('back on the list: the pane follows, live')
  end
  stop_everything()
  vim.cmd('qa!')
end
