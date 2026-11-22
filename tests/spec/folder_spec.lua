-- Where a chat's agent is started. Opening an ended chat, sending it a
-- reply that was queued and passing it on all start an agent: always in
-- the chat's own folder, for every agent, whatever Neovim's own working
-- folder is.
--
-- Each agent's stand-in here is a script under the agent's name that writes
-- down its arguments and the folder it was started in.

local T = require('helpers.harness')
local fake = require('helpers.fake')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt

local api = vim.api

local function board()
  return require('agent-chats.ui.board')
end
local function store()
  return require('agent-chats.store')
end
local function state()
  return require('agent-chats.state')
end
local function actions()
  return require('agent-chats.actions')
end

--- A stand-in for the command of agent `name`: it records its arguments and
--- its folder, then waits for input like an agent at its prompt.
local function stand_in(name)
  local dir = T.tmpdir()
  local exe, log = dir .. '/' .. name, dir .. '/started.log'
  T.write(log, '')
  T.write(exe, {
    '#!/bin/sh',
    ('echo "argv: $*" >> %s'):format(vim.fn.shellescape(log)),
    ('echo "cwd: $(pwd)" >> %s'):format(vim.fn.shellescape(log)),
    -- A background reply has no terminal to wait on.
    'for a in "$@"; do case "$a" in -p|exec|run) exit 0 ;; esac; done',
    'read _',
  })
  vim.uv.fs_chmod(exe, 493)
  require('agent-chats.config').get().providers[name].cmd = { exe }
  return {
    exe = exe,
    read = function()
      return table.concat(vim.fn.readfile(log), '\n')
    end,
    clear = function()
      T.write(log, '')
    end,
  }
end

--- A folder that exists, with a name that needs quoting.
local function folder(name)
  local dir = T.tmpdir() .. '/' .. (name or 'the project')
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- Everything `vim.notify` is told while `fn` runs.
local function notes(fn)
  local said = {}
  local real = vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local good, err = pcall(fn)
  vim.notify = real
  assert(good, err)
  return table.concat(said, '\n')
end

-- One entry per agent: how to make a home and a finished chat in `dir`,
-- and the arguments each way of starting it has to use.
local AGENTS = {
  {
    name = 'claude',
    make = function(dir, opts)
      local home = require('helpers.claude').home(opts)
      local c = home:chat({ cwd = dir, start = os.time() - 700 })
      c:user('Do the task'):title('The task'):assistant('Done.'):turn_done()
      c:write(os.time() - 600)
      return home, c.id, c
    end,
    resume = '--resume %s',
    reply = '--resume %s carry on',
    background = '-p --resume %s carry on',
  },
  {
    name = 'codex',
    make = function(dir, opts)
      local home = require('helpers.codex').home(opts)
      local r = home:rollout({ cwd = dir, start = os.time() - 700 })
      r:meta():task_started()
      r:item_user('Do the task'):item_agent('Done.'):task_complete('Done.')
      r:write(os.time() - 600)
      return home, r.id, r
    end,
    resume = 'resume %s',
    reply = 'resume %s carry on',
    background = 'exec resume %s carry on',
  },
  {
    name = 'qwen',
    make = function(dir, opts)
      local home = require('helpers.qwen').home(opts)
      local c = home:chat({ cwd = dir, start = os.time() - 700 })
      c:turn('Do the task', 'Done.'):write(os.time() - 600)
      return home, c.id, c
    end,
    resume = '--resume %s',
    reply = '--resume %s -i carry on',
    background = '--resume %s carry on',
  },
}
if require('agent-chats.util.sqlite').available() then
  AGENTS[#AGENTS + 1] = {
    name = 'opencode',
    make = function(dir, opts)
      local home = require('helpers.opencode').home(opts)
      local s = home:session({ directory = dir, title = 'The task', start = os.time() - 700 })
      s:user('Do the task'):assistant():text('Done.'):finish('stop')
      return home, s.id, s
    end,
    resume = '-s %s',
    reply = '-s %s --prompt carry on',
    background = 'run -s %s carry on',
  }
else
  io.stdout:write('  note  opencode: SQLite library not found; its folder tests are skipped\n')
end

local elsewhere
local came_from = vim.uv.cwd()

before_each(function()
  -- Neovim itself works somewhere else entirely: nothing may be started there.
  elsewhere = elsewhere or folder('where neovim is')
  vim.cmd.cd(vim.fn.fnameescape(elsewhere))
end)

after_each(function()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
  require('agent-chats.ui.input').cancel()
  -- The other specs run where the suite was started.
  vim.cmd.cd(vim.fn.fnameescape(came_from))
end)

--- Make a home with one finished chat of `agent` in `dir`, seen and indexed.
local function scene(agent, dir, opts)
  local _, id, made =
    agent.make(dir, vim.tbl_deep_extend('force', { board = { spinner = false } }, opts or {}))
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
  local cmd = stand_in(agent.name)
  store().refresh_sync()
  store().start = function() end
  local key = agent.name .. ':' .. id
  local chat = store().get(key)
  ok(chat, agent.name .. ': the chat is in the index')
  return key, id, cmd, made
end

--- Wait until the stand-in has written both lines of a start, and return them.
local function started(cmd)
  T.wait(3000, function()
    local log = cmd.read()
    return log:find('argv: ', 1, true) ~= nil and log:find('cwd: ', 1, true) ~= nil
  end, 'the agent was started')
  return cmd.read()
end

describe('the folder a chat is started in', function()
  for _, agent in ipairs(AGENTS) do
    it(('%s: opening an ended chat resumes it in its own folder'):format(agent.name), function()
      local dir = folder()
      local key, id, cmd = scene(agent, dir)
      eq(dir, store().get(key).cwd)
      board().open()
      local buf = actions().open(store().get(key))
      ok(buf, 'a terminal was opened')
      local log = started(cmd)
      has(log, 'argv: ' .. agent.resume:format(id))
      has(log, 'cwd: ' .. dir)
      hasnt(log, elsewhere)
      -- The terminal says where it is, too: the end of the path at the least.
      has(vim.wo[board()._state.pane_win].winbar, 'the project')
    end)

    it(('%s: a reply to an ended chat resumes it there'):format(agent.name), function()
      local dir = folder()
      local key, id, cmd = scene(agent, dir, { reply = { ended = 'terminal' } })
      actions().deliver(store().get(key), 'carry on')
      local log = started(cmd)
      has(log, 'argv: ' .. agent.reply:format(id))
      has(log, 'cwd: ' .. dir)
      fake.cleanup()
      -- The agent has exited: let the index hear of it, as it would have
      -- by the time anyone could press a key.
      vim.wait(50)
      store().refresh_sync({ full = false })

      -- And in the background, with no terminal at all.
      cmd.clear()
      local done
      actions().deliver(store().get(key), 'carry on', { how = 'background' }, function(sent)
        done = sent
      end)
      eq(true, done)
      log = started(cmd)
      has(log, 'argv: ' .. agent.background:format(id))
      has(log, 'cwd: ' .. dir)
    end)

    it(('%s: passing it on starts the new chat in the same folder'):format(agent.name), function()
      local dir = folder()
      local key, _, cmd = scene(agent, dir)
      board().open()
      local real = vim.ui.select
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      actions().pass(store().get(key))
      local input = require('agent-chats.ui.input')
      T.wait(3000, function()
        return input.is_open()
      end)
      vim.ui.select = real
      has(T.buf_text(api.nvim_get_current_buf()), 'Folder: ' .. dir)
      input.submit()
      local log = started(cmd)
      has(log, 'cwd: ' .. dir)
      hasnt(log, elsewhere)
    end)

    it(
      ('%s: a chat with no folder left is read, and nothing is started'):format(agent.name),
      function()
        local dir = folder('soon gone')
        local key, _, cmd = scene(agent, dir)
        -- The folder is moved away after the chat was made.
        assert(vim.uv.fs_rename(dir, dir .. ' (moved)'))
        board().open()
        board().goto_chat(key)
        local said = notes(function()
          eq(nil, actions().open(store().get(key)))
        end)
        has(said, 'is gone')
        has(said, 'cannot be resumed')
        has(said, 'It can still be read')
        eq(
          'agent-chats-conversation',
          vim.bo[api.nvim_win_get_buf(board()._state.pane_win)].filetype,
          'its conversation is shown instead'
        )
        board().focus()
        -- A reply would have to resume it: not sent, and kept.
        said = notes(function()
          local done
          actions().deliver(store().get(key), 'carry on', { how = 'terminal' }, function(sent)
            done = sent
          end)
          eq(false, done)
        end)
        has(said, 'cannot be resumed')
        vim.wait(200)
        eq('', cmd.read(), 'no agent was started anywhere')
        -- The board said so before any key was pressed.
        local pane = T.buf_text(board()._state.preview_buf)
        has(pane, 'Its folder is gone, so it cannot be resumed.')
        has(pane, dir .. ' · ')
        has(pane, 'gone')
      end
    )
  end

  it('keeps the folder a chat started in when its agent moves about', function()
    local dir, other = folder('started here'), folder('went there')
    -- Claude: later records of the same chat carry another folder.
    local home = require('helpers.claude').home()
    local c = home:chat({ cwd = dir, start = os.time() - 700 })
    c:user('Do the task'):title('The task'):assistant('On it.')
    c.cwd = other
    c:user('And over there?'):assistant('Done there too.'):turn_done()
    c:write(os.time() - 600)
    store().refresh_sync()
    local key = 'claude:' .. c.id
    eq(dir, store().get(key).cwd)
    -- It grows while it is watched: still where it started.
    c.ts = os.time() - 100
    c:user('One more'):assistant('Done.'):turn_done():write(os.time() - 90)
    store().refresh_sync({ full = false })
    store().refresh_sync()
    eq(dir, store().get(key).cwd)
    -- Its process is found in the other folder: the chat is still that one's.
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'idle', cwd = other })
    store().refresh_sync({ full = false })
    eq(true, store().get(key).live)
    eq(dir, store().get(key).cwd)

    -- Codex: a later turn runs in another folder.
    local cx = require('helpers.codex')
    local codex = cx.home()
    local r = codex:rollout({ cwd = dir, start = os.time() - 700 })
    r:meta():task_started()
    r:item_user('Do the task'):item_agent('On it.'):task_complete('On it.')
    r.cwd = other
    r:task_started()
    r:item_user('And over there?'):item_agent('Done.'):task_complete('Done.')
    r:write(os.time() - 600)
    store().refresh_sync()
    eq(dir, store().get('codex:' .. r.id).cwd)

    -- Qwen: the same.
    local qx = require('helpers.qwen')
    local qwen = qx.home()
    local q = qwen:chat({ cwd = dir, start = os.time() - 700 })
    q:turn('Do the task', 'On it.')
    q.cwd = other
    q:turn('And over there?', 'Done.'):write(os.time() - 600)
    store().refresh_sync()
    eq(dir, store().get('qwen:' .. q.id).cwd)
  end)

  it('resumes a chat of a git worktree in that worktree, not in the main checkout', function()
    if vim.fn.executable('git') ~= 1 then
      io.stdout:write('  note  git not found; the worktree test is skipped\n')
      return
    end
    local repo = folder('repo')
    local function git(args, cwd)
      local res =
        vim.system(vim.list_extend({ 'git', '-C', cwd or repo }, args), { text = true }):wait()
      assert(res.code == 0, table.concat(args, ' ') .. ': ' .. (res.stderr or ''))
    end
    git({ 'init', '-q', '-b', 'main' })
    git({
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit',
      '-q',
      '--allow-empty',
      '-m',
      'init',
    })
    local tree = vim.fs.dirname(repo) .. '/repo.worktrees/feature'
    git({ 'worktree', 'add', '-q', '-b', 'feature', tree })
    local agent = AGENTS[1]
    local key, id, cmd = scene(agent, tree)
    board().open()
    board().goto_chat(key)
    -- Before it is opened: the row and the summary say which folder.
    has(T.buf_text(board()._state.buf), 'feature')
    local pane = T.buf_text(board()._state.preview_buf)
    has(pane, 'Enter resumes it in ' .. vim.fn.fnamemodify(tree, ':~') .. '.')
    has(pane, 'Folder  ' .. vim.fn.fnamemodify(tree, ':~'))
    actions().open(store().get(key))
    local log = started(cmd)
    has(log, 'argv: ' .. agent.resume:format(id))
    has(log, 'cwd: ' .. tree)
    no(log:find('cwd: ' .. repo .. '\n', 1, true), 'not the main checkout')
    -- Grouped by worktree, the heading names the repository and the branch.
    board().focus()
    board().set_group('worktree')
    T.wait(3000, function()
      return T.buf_text(board()._state.buf):find('repo › feature', 1, true) ~= nil
    end)
    -- And once git has been asked, the summary says whose worktree it is.
    board().render()
    T.wait(2000, function()
      board().goto_chat(key)
      board().focus()
      local shown = api.nvim_win_get_buf(board()._state.pane_win)
      return T.buf_text(shown):find('a worktree of', 1, true) ~= nil
        or vim.bo[shown].buftype == 'terminal'
    end)
  end)

  it('starts a new chat in the folder it names, and says which before it does', function()
    local dir = folder('fresh start')
    local home = require('helpers.claude').home({ board = { spinner = false } })
    local cmd = stand_in('claude')
    store().refresh_sync()
    store().start = function() end
    board().open()
    -- The question names the folder; the agent that is picked starts there.
    local asked
    local real = vim.ui.select
    vim.ui.select = function(items, o, cb)
      asked = o.prompt
      cb(items[1])
    end
    local good, err = pcall(actions().new, { cwd = dir })
    vim.ui.select = real
    assert(good, err)
    eq(('New chat in %s. Which agent?'):format(vim.fn.fnamemodify(dir, ':~')), asked)
    local log = started(cmd)
    has(log, 'cwd: ' .. dir)
    has(log, 'argv: --session-id ')
    ok(home)
  end)
end)
