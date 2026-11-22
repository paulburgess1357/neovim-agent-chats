-- What a review of the whole plugin found, each with the case that showed
-- it: text that was lost, a reply that could reach the wrong place, a row
-- that was wrong for a moment.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local ox = require('helpers.opencode')
local fake = require('helpers.fake')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt

local api = vim.api
local uv = vim.uv

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
local function term()
  return require('agent-chats.term')
end
local function input()
  return require('agent-chats.ui.input')
end

local function key(c)
  return 'claude:' .. c.id
end

--- A finished Claude chat in `opts.cwd` (the folder the tests run in).
local function chat(home, opts)
  opts = opts or {}
  local c = home:chat({ cwd = opts.cwd or uv.cwd(), start = os.time() - (opts.age or 600) - 5 })
  c:user(opts.prompt or 'Please fix the parser')
  c:title(opts.title or 'Fix the parser')
  c:assistant(opts.reply or 'The parser is fixed.')
  c:turn_done()
  return c:write(os.time() - (opts.age or 600))
end

local function seen_everything()
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
end

--- Everything `vim.notify` is told while `fn` runs.
local function notes(fn)
  local said = {}
  local real = vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local good, err = pcall(fn)
  vim.wait(20)
  vim.notify = real
  assert(good, err)
  return table.concat(said, '\n')
end

local function feed(lhs)
  api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), 'xt', false)
end

--- A home with one ended chat, the board open, the stand-in agent installed.
local function scene(extra, opts)
  local home = fx.home(vim.tbl_deep_extend('force', { board = { spinner = false } }, extra or {}))
  local c = chat(home, opts)
  seen_everything()
  store().refresh_sync()
  store().start = function() end
  local agent = fake.install(home)
  board().open()
  return home, c, agent
end

--- Open `c` in a terminal here and wait until the index knows its process.
local function host(c, agent)
  local buf = actions().open(store().get(key(c)))
  T.wait(3000, function()
    store().refresh_sync({ full = false })
    local now = store().get(key(c))
    return now.term == buf and now.pid ~= nil
  end)
  T.wait(3000, function()
    return agent.read():find('argv:', 1, true) ~= nil
  end)
  vim.cmd('stopinsert')
  return buf
end

after_each(function()
  vim.env.FAKE_AGENT_COOKED = nil
  fake.cleanup()
  pcall(function()
    input().cancel()
  end)
  -- A chat's terminal asks for typing mode when it opens. In a script that
  -- only takes effect at the next key: not one of the next test's.
  pcall(vim.cmd, 'stopinsert')
end)

describe('review: the state file', function()
  it('does not freeze the editor over a folder it cannot write to, and says so once', function()
    if uv.getuid() == 0 then
      io.stdout:write('  note  running as root; the read-only folder test is skipped\n')
      return
    end
    local home = fx.home()
    local dir = home.root .. '/readonly'
    vim.fn.mkdir(dir, 'p')
    uv.fs_chmod(dir, 365) -- r-xr-xr-x
    require('agent-chats.config').get().state_file = dir .. '/state.json'
    state().reset()
    local started = uv.hrtime()
    local said = notes(function()
      for _ = 1, 3 do
        state().update(function(s)
          s.baseline = 1
        end)
      end
    end)
    local took = (uv.hrtime() - started) / 1e9
    uv.fs_chmod(dir, 493)
    ok(took < 1, ('three changes took %.2fs'):format(took))
    -- Said once, with what it means; and the change is there for this session.
    local _, times = said:gsub('cannot write', '')
    eq(1, times)
    has(said, 'kept only until Neovim is closed')
    eq(1, state().get().baseline)
  end)

  it('takes a lock left by an instance that died without waiting for it', function()
    local home = fx.home()
    local path = home.root .. '/state.json'
    -- A process id that is not in use: one that has just exited.
    local gone = vim.system({ 'true' }):wait() and nil
    local job = vim.system({ 'sleep', '0' })
    local pid = job.pid
    job:wait()
    T.write(path .. '.lock', tostring(pid))
    local started = uv.hrtime()
    state().update(function(s)
      s.baseline = 7
    end)
    ok((uv.hrtime() - started) / 1e9 < 0.5, 'did not wait for the dead instance')
    eq(7, vim.json.decode(table.concat(vim.fn.readfile(path), '\n')).baseline)
    eq(nil, uv.fs_stat(path .. '.lock'))
    eq(nil, gone)
  end)

  it('reads ~ in state_file as the home folder', function()
    fx.home()
    require('agent-chats.config').get().state_file = '~/somewhere/agent-chats.json'
    state().reset()
    eq(vim.fs.normalize(vim.env.HOME) .. '/somewhere/agent-chats.json', state().path())
  end)
end)

describe('review: typing a reply into a terminal', function()
  it('does not take the terminal echoing a paste for the agent showing it', function()
    -- An agent that is still starting has not taken the terminal over: the
    -- terminal itself echoes what is pasted, brackets and all.
    vim.env.FAKE_AGENT_COOKED = '1'
    local _, c, agent = scene({ reply = { echo_wait = 300 } })
    local buf = host(c, agent)
    local result
    local said = notes(function()
      ok(term().send(buf, 'which line is it on', function(sent, why)
        result = { sent, why }
      end))
      T.wait(3000, function()
        return result ~= nil
      end)
    end)
    eq({ false, 'unseen' }, result)
    has(T.buf_text(buf), '^[[200~which line is it on')
    -- Enter was not pressed: nothing reached the agent as a message.
    hasnt(agent.read(), 'input: ')
    eq('', said)
  end)

  it('takes a very short reply as shown only on a line of its own', function()
    local _, c, agent = scene({ reply = { echo_wait = 300 } })
    -- A dialog that shows a "2" of its own and takes no paste.
    T.write(agent.bin, table.concat({
      '#!/usr/bin/env bash',
      'stty -echo -icanon min 1 time 0 2>/dev/null',
      'echo "argv: $*" >> "$FAKE_AGENT_LOG"',
      'sid=""; prev=""',
      'for a in "$@"; do if [ "$prev" = "--resume" ]; then sid="$a"; fi; prev="$a"; done',
      'printf \'{"pid":%d,"sessionId":"%s","cwd":"%s","status":"idle","kind":"interactive","name":"fake"}\' $$ "$sid" "$PWD" > "$FAKE_AGENT_HOME/sessions/$$.json"',
      'trap \'rm -f "$FAKE_AGENT_HOME/sessions/$$.json"\' EXIT',
      'echo "Allow this?  1. Yes   2. No   (closes in 12s)"',
      'while IFS= read -r -N1 ch; do',
      '  if [ "$ch" = $\'\\r\' ] || [ "$ch" = $\'\\n\' ]; then echo "dialog answered" >> "$FAKE_AGENT_LOG"; fi',
      'done',
    }, '\n') .. '\n')
    uv.fs_chmod(agent.bin, 493)
    local buf = host(c, agent)
    T.wait(3000, function()
      return T.buf_text(buf):find('Allow this?', 1, true) ~= nil
    end)
    local result
    notes(function()
      term().send(buf, '2', function(sent, why)
        result = { sent, why }
      end)
      T.wait(3000, function()
        return result ~= nil
      end)
    end)
    eq({ false, 'unseen' }, result)
    hasnt(agent.read(), 'dialog answered')
  end)

  it('sends a very short reply that the agent shows in its input box', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    local result
    term().send(buf, 'ok', function(sent, why)
      result = { sent, why }
    end)
    T.wait(3000, function()
      return result ~= nil
    end)
    eq({ true }, result)
    T.wait(3000, function()
      return agent.read():find('input: ok', 1, true) ~= nil
    end)
  end)

  it('knows the text an input box holds from the line that frames it', function()
    eq('2', term()._core('│ > 2                      │'))
    eq('yes', term()._core('❯ yes'))
    eq('1. Yes   2. No', term()._core('  1. Yes   2. No  '))
    eq('', term()._core('│                          │'))
  end)

  it('sends nothing that would end the paste early or drive the terminal', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    local done
    term().send(buf, 'one\27[201~two\1three\ttab\nnext line', function(sent)
      done = sent
    end)
    T.wait(3000, function()
      return done ~= nil
    end)
    eq(true, done)
    T.wait(3000, function()
      return agent.read():find('paste: end', 1, true) ~= nil
    end)
    -- One paste, with everything that is text in it.
    has(agent.read(), 'paste: begin\ninput: onetwothree\ttab\ninput: next line\npaste: end')
    -- (The tab in it is shown as spaces, and the text is still found.)
  end)

  it('keeps the claim of a reply on its way when a second one is refused', function()
    local _, c, agent = scene()
    host(c, agent)
    local first, second
    actions().deliver(store().get(key(c)), 'the first reply', nil, function(sent)
      first = sent
    end)
    notes(function()
      actions().deliver(store().get(key(c)), 'the second reply', nil, function(sent)
        second = sent
      end)
    end)
    eq(false, second)
    -- The first is still on its way, and still counts as that: a queued
    -- reply must go on waiting behind it.
    ok(state().claim(key(c)) ~= nil, 'the first reply is still claimed')
    T.wait(3000, function()
      return first ~= nil
    end)
    eq(true, first)
  end)

  it('types nothing into a terminal whose shell has the agent suspended', function()
    if vim.fn.executable('bash') ~= 1 then
      return
    end
    local home, c, agent = scene({ open = { start_insert = false } })
    -- A terminal of the user's own: a shell, in which the agent is started
    -- by hand.
    local work = home.root .. '/shellwork'
    vim.fn.mkdir(work, 'p')
    vim.cmd('botright new')
    local buf = api.nvim_get_current_buf()
    vim.fn.jobstart({ 'bash', '--norc', '--noprofile', '-i' }, {
      term = true,
      cwd = work,
      env = { PS1 = 'shell$ ', HISTFILE = '/dev/null' },
    })
    local chan = vim.bo[buf].channel
    T.wait(3000, function()
      return T.buf_text(buf):find('shell$', 1, true) ~= nil
    end)
    api.nvim_chan_send(chan, agent.bin .. ' --resume ' .. c.id .. '\r')
    T.wait(4000, function()
      store().refresh_sync({ full = false })
      return store().get(key(c)).term == buf
    end, 'the chat is found in the shell terminal')
    -- In the foreground it is what reads the terminal.
    ok(term().reads(buf, store().get(key(c))))
    -- Ctrl-Z: the agent is stopped and the shell reads again.
    api.nvim_chan_send(chan, '\26')
    T.wait(3000, function()
      return term().reads(buf, store().get(key(c))) == false
    end, 'the agent is seen to be suspended')
    local sent
    local said = notes(function()
      actions().deliver(store().get(key(c)), 'touch RAN_BY_THE_SHELL', nil, function(done)
        sent = done
      end)
      T.wait(3000, function()
        return sent ~= nil
      end)
    end)
    eq(false, sent)
    has(said, 'not what that terminal is reading now')
    vim.wait(300)
    eq({}, vim.fn.readdir(work))
    hasnt(agent.read(), 'input: touch')
    api.nvim_chan_send(chan, 'kill %1; exit\r')
    vim.wait(200)
  end)
end)

describe('review: a queued reply and your own typing', function()
  local function type_keys(buf, text)
    api.nvim_chan_send(vim.bo[buf].channel, text)
    for ch in text:gmatch('.') do
      term().note_key(buf, ch)
    end
  end

  it('waits while the terminal holds something you typed, and goes once that is sent', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    local queue = require('agent-chats.queue')
    queue.setup()
    type_keys(buf, 'half a thought')
    T.wait(3000, function()
      return T.buf_text(buf):find('half a thought', 1, true) ~= nil
    end)
    ok(term().has_unsent(buf))
    state().enqueue(key(c), 'the queued reply')
    local said = notes(function()
      queue.sweep()
      queue.sweep()
    end)
    -- Said once, however often it is looked at.
    local _, times = said:gsub('something you typed and have not sent', '')
    eq(1, times)
    eq(1, #state().queue(key(c)))
    hasnt(agent.read(), 'the queued reply')
    -- Enter sends what was typed; the queued reply goes after it.
    api.nvim_chan_send(vim.bo[buf].channel, '\r')
    term().note_key(buf, '\r')
    no(term().has_unsent(buf))
    T.wait(3000, function()
      return agent.read():find('input: half a thought', 1, true) ~= nil
    end)
    queue.sweep()
    T.wait(4000, function()
      queue.sweep()
      return agent.read():find('input: the queued reply', 1, true) ~= nil
    end)
  end)

  it('holds back what is sent at once, too, and what was written is kept', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    type_keys(buf, 'half a thought')
    T.wait(3000, function()
      return T.buf_text(buf):find('half a thought', 1, true) ~= nil
    end)
    board().focus()
    actions().queue(store().get(key(c)))
    api.nvim_buf_set_lines(0, 0, -1, false, { 'and the docs too' })
    local said = notes(function()
      input().submit()
      vim.wait(100)
    end)
    has(said, 'holds something you typed there and have not sent')
    has(said, 'What you wrote is kept')
    hasnt(agent.read(), 'and the docs too')
    -- Cleared there, the reply goes: it is in the box again.
    api.nvim_chan_send(vim.bo[buf].channel, '\21')
    term().note_key(buf, '\21')
    board().focus()
    actions().queue(store().get(key(c)))
    eq('and the docs too', T.buf_text(api.nvim_get_current_buf()))
    input().submit()
    T.wait(3000, function()
      return agent.read():find('and the docs too', 1, true) ~= nil
    end)
  end)

  it('is not held by a key that answered a dialog, nor by text that was deleted again', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    -- One key, as a dialog is answered: typed and gone.
    term().note_key(buf, '1')
    no(term().has_unsent(buf))
    -- A word typed and taken back with Backspace.
    for ch in ('hello'):gmatch('.') do
      term().note_key(buf, ch)
    end
    for _ = 1, 5 do
      term().note_key(buf, '\127')
    end
    no(term().has_unsent(buf))
    -- Keys that are on no screen (commands of an agent's own editor).
    for ch in ('ciwdd'):gmatch('.') do
      term().note_key(buf, ch)
    end
    no(term().has_unsent(buf))
    -- Ctrl-U throws a line away.
    type_keys(buf, 'thrown away')
    T.wait(3000, function()
      return T.buf_text(buf):find('thrown away', 1, true) ~= nil
    end)
    ok(term().has_unsent(buf))
    term().note_key(buf, '\21')
    no(term().has_unsent(buf))
  end)
end)

describe('review: text that must not be lost', function()
  it('starts nothing with a first prompt that is longer than a program can be given', function()
    local home = fx.home({ board = { spinner = false } })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    board().open()
    -- (From a script: the board itself asks for no first prompt.)
    local long = string.rep('all of this is my prompt. ', 6000)
    local said = notes(function()
      actions().new({ provider = 'claude', prompt = long })
    end)
    has(said, 'too long for a program to be given when it starts')
    eq('', agent.read())
    eq(0, vim.tbl_count(term().terms))
  end)

  it('keeps the notes for a chat that is passed on when the agent exits at once', function()
    local _, c, agent = scene()
    T.write(agent.bin, '#!/bin/sh\necho "not logged in" >&2\nexit 3\n')
    uv.fs_chmod(agent.bin, 493)
    local real = vim.ui.select
    vim.ui.select = function(items, _, cb)
      cb(items[1])
    end
    local good, err = pcall(function()
      actions().pass(store().get(key(c)))
      T.wait(3000, function()
        return input().is_open()
      end, 'the notes are there to be read')
      api.nvim_buf_set_lines(0, 0, -1, false, { 'Notes worth keeping.' })
      local said = notes(function()
        input().submit()
        vim.wait(1500, function()
          return false
        end, 50)
      end)
      has(said, 'exited as soon as it was started (code 3)')
      has(said, 'Your notes are kept')
      board().focus()
      actions().pass(store().get(key(c)))
      T.wait(3000, function()
        return input().is_open()
      end)
      eq('Notes worth keeping.', T.buf_text(api.nvim_get_current_buf()))
      input().cancel()
    end)
    vim.ui.select = real
    assert(good, err)
  end)

  it('keeps a reply when the chat resumed for it exits at once', function()
    local _, c, agent = scene()
    T.write(agent.bin, '#!/bin/sh\nexit 2\n')
    uv.fs_chmod(agent.bin, 493)
    local said = notes(function()
      actions().deliver(store().get(key(c)), 'and the docs too', { how = 'terminal' })
      vim.wait(1500, function()
        return false
      end, 50)
    end)
    has(said, 'your reply to “Fix the parser” was not sent')
    has(said, 'What you wrote is kept')
    board().focus()
    actions().queue(store().get(key(c)))
    eq('and the docs too', T.buf_text(api.nvim_get_current_buf()))
    input().cancel()
  end)

  it('keeps a reply whose background run failed', function()
    local _, c, agent = scene()
    T.write(agent.bin, '#!/bin/sh\necho "quota exceeded" >&2\nexit 1\n')
    uv.fs_chmod(agent.bin, 493)
    local said = notes(function()
      actions().deliver(store().get(key(c)), 'try again later', { how = 'background' })
      T.wait(3000, function()
        return not term().in_background(store().get(key(c)))
      end)
      vim.wait(100)
    end)
    has(said, 'failed (exit 1). quota exceeded')
    has(said, 'What you wrote is kept')
    board().focus()
    actions().queue(store().get(key(c)))
    eq('try again later', T.buf_text(api.nvim_get_current_buf()))
    input().cancel()
  end)

  it('does not count an agent you closed yourself as one that failed', function()
    local _, c, agent = scene()
    local said = notes(function()
      local buf = actions().deliver(store().get(key(c)), 'and the docs too', { how = 'terminal' })
      T.wait(3000, function()
        return agent.read():find('argv:', 1, true) ~= nil
      end)
      for b in pairs(term().terms) do
        vim.fn.jobstop(vim.bo[b].channel)
      end
      vim.wait(300)
      return buf
    end)
    hasnt(said, 'was not sent')
  end)

  it('says why an argument cannot be given to a program, by its size', function()
    eq(nil, term().too_long({ 'agent', 'a short prompt' }))
    has(term().too_long({ 'agent', string.rep('x', 200000) }), 'the limit is 127 KB')
  end)
end)

describe('review: a prompt on the command line', function()
  it('is never read as an option or as a command of the program', function()
    local common = require('agent-chats.providers.common')
    eq(' logout', common.arg('logout'))
    eq(' --help', common.arg('--help'))
    eq('fix the parser', common.arg('fix the parser'))
    fx.home()
    for _, name in ipairs({ 'claude', 'codex', 'qwen', 'opencode' }) do
      local cmd = require('agent-chats.providers.' .. name).new_cmd({ prompt = 'update' })
      eq(' update', cmd[#cmd], name)
    end
  end)
end)

describe('review: rows that were wrong for a moment', function()
  it('lists a resumed chat as open from the moment it is resumed', function()
    local _, c = scene()
    eq('ended', store().get(key(c)).status)
    actions().open(store().get(key(c)))
    -- Before any new look at the agents' files.
    ok(store().get(key(c)).status ~= 'ended', 'still listed as ended')
  end)

  it('knows a chat is over when its terminal is wiped out by hand', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    ok(store().get(key(c)).status ~= 'ended')
    board().focus()
    vim.cmd('bwipeout! ' .. buf)
    T.wait(3000, function()
      return store().get(key(c)).status == 'ended'
    end, 'the chat is listed as ended')
    eq(nil, store().get(key(c)).term)
  end)

  it('looks before :Chats next when nothing watches in the background', function()
    local home, c = scene()
    eq(false, store().is_watching())
    -- Since the last look: a chat that waits for an answer.
    local w = home:chat({ cwd = uv.cwd(), start = os.time() - 30 })
    w:user('Deploy it'):title('Deploy it'):assistant('I need to run this.'):write(os.time() - 5)
    home:registry(uv.os_getpid(), { sessionId = w.id, cwd = uv.cwd(), status = 'waiting' })
    local said = notes(function()
      actions().next()
    end)
    hasnt(said, 'No chat needs you right now.')
    eq('claude:' .. w.id, (board().current() or {}).key)
    home:unregister(uv.os_getpid())
    no(c == nil)
  end)
end)

describe('review: a folder typed in by hand', function()
  it('is made whole from the folder Neovim is in at that moment', function()
    local home = fx.home({ board = { spinner = false } })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    local base = home.root .. '/base'
    vim.fn.mkdir(base .. '/sub/dir', 'p')
    local before = uv.cwd()
    vim.cmd.cd(base)
    local real_select, real_input = vim.ui.select, vim.ui.input
    local asked = {}
    vim.ui.select = function(items, o, cb)
      asked[#asked + 1] = o.prompt
      if #asked == 1 then
        -- Which agent? Not here: in another folder.
        return cb(items[#items])
      elseif #asked == 2 then
        -- Which folder? One that is typed in.
        for _, item in ipairs(items) do
          if item.other then
            return cb(item)
          end
        end
      end
      -- Which agent, again: Neovim has moved elsewhere by then.
      vim.cmd.cd(before)
      cb(items[1])
    end
    vim.ui.input = function(_, cb)
      cb('sub/dir')
    end
    local good, err = pcall(function()
      board().open()
      actions().new()
      T.wait(3000, function()
        return agent.read():find('cwd:', 1, true) ~= nil
      end)
    end)
    vim.ui.select, vim.ui.input = real_select, real_input
    vim.cmd.cd(before)
    assert(good, err)
    eq(3, #asked)
    -- The question says where the chat will start: the folder that was typed.
    has(asked[3], 'sub/dir. Which agent?')
    has(agent.read(), 'cwd: ' .. vim.fs.normalize(base) .. '/sub/dir\n')
  end)
end)

describe('review: two opencode chats in one folder', function()
  local jobs = {}
  local function sqlite()
    if not require('agent-chats.util.sqlite').available() then
      io.stdout:write('  note  no SQLite library; the opencode test is skipped\n')
      return false
    end
    return true
  end
  after_each(function()
    for _, job in ipairs(jobs) do
      ox.kill(job)
    end
    jobs = {}
  end)
  --- A stand-in `opencode` process in `dir`, once it is there to be found.
  local function spawn(dir, args)
    local job = ox.spawn(dir, args)
    jobs[#jobs + 1] = job
    T.wait(3000, function()
      for _, p in ipairs(require('agent-chats.util.proc').find({ opencode = true })) do
        if p.pid == job.pid then
          return true
        end
      end
      return false
    end, 'the process is running')
    return job
  end
  local function refreshed(home)
    store().refresh_sync()
    return function(session)
      return store().get('opencode:' .. session.id)
    end, home
  end

  it('gives each process the chat that begins with the prompt it was started with', function()
    if not sqlite() then
      return
    end
    local home = ox.home()
    local dir = home.root .. '/repo'
    local first = spawn(dir, { '--prompt', 'first task' })
    local second = spawn(dir, { '--prompt', 'second task' })
    -- Both chats are born after both processes: the time tells nothing.
    local b = home:session({ directory = dir, title = 'Second task', start = os.time() + 1 })
    b:user('second task'):reply('The second task is done.')
    local a = home:session({ directory = dir, title = 'First task', start = os.time() + 2 })
    a:user('first task'):reply('The first task is done.')
    local get = refreshed(home)
    eq(first.pid, get(a).pid)
    eq(second.pid, get(b).pid)
    eq(nil, get(a).unsure)
    eq(nil, get(b).unsure)
  end)

  it('never gives two processes the same chat, and marks a guess as one', function()
    if not sqlite() then
      return
    end
    local home = ox.home()
    local dir = home.root .. '/repo'
    local one = spawn(dir, {})
    local two = spawn(dir, {})
    local a = home:session({ directory = dir, title = 'One', start = os.time() + 1 })
    a:user('do one'):reply('One is done.')
    local get = refreshed(home)
    -- One chat, two processes it could be in.
    ok(get(a).pid == one.pid or get(a).pid == two.pid)
    eq(true, get(a).unsure)
    local b = home:session({ directory = dir, title = 'Two', start = os.time() + 2 })
    b:user('do two'):reply('Two is done.')
    -- (A chat is matched to a process on the look after the one that
    -- finds it.)
    refreshed(home)
    get = refreshed(home)
    ok(get(a).pid ~= nil and get(b).pid ~= nil, 'each chat is in a process')
    ok(get(a).pid ~= get(b).pid, 'two chats in one process')
    eq(true, get(a).unsure)
    eq(true, get(b).unsure)
  end)

  it('types nothing from the list into a terminal that is only a guess', function()
    if not sqlite() then
      return
    end
    local home = ox.home({ board = { spinner = false }, open = { start_insert = false } })
    local dir = home.root .. '/repo'
    vim.fn.mkdir(dir, 'p')
    local agent = fake.install_as(home.root, 'opencode')
    store().refresh_sync()
    store().start = function() end
    board().open()
    -- Two chats opened with no first prompt, in one folder.
    actions().new({ provider = 'opencode', cwd = dir, prompt = '' })
    board().focus()
    actions().new({ provider = 'opencode', cwd = dir, prompt = '' })
    T.wait(3000, function()
      local _, n = agent.read():gsub('argv:', '')
      return n == 2
    end)
    local a = home:session({ directory = dir, title = 'One', start = os.time() + 1 })
    a:user('do one'):reply('One is done.')
    local b = home:session({ directory = dir, title = 'Two', start = os.time() + 2 })
    b:user('do two'):reply('Two is done.')
    T.wait(3000, function()
      store().refresh_sync()
      local x, y = store().get('opencode:' .. a.id), store().get('opencode:' .. b.id)
      return x and y and x.term and y.term
    end)
    local chat_a = store().get('opencode:' .. a.id)
    eq(true, chat_a.unsure)
    board().focus()
    local said = notes(function()
      actions().queue(chat_a)
    end)
    no(input().is_open())
    has(said, 'More than one opencode runs in this folder')
    has(said, 'Open the chat and type there')
    -- And nothing that types gets past it either.
    local sent
    notes(function()
      actions().deliver(chat_a, 'for chat one', nil, function(done)
        sent = done
      end)
    end)
    eq(false, sent)
    hasnt(agent.read(), 'for chat one')
  end)

  it('does not take the chat of a process that is gone for the chat of another', function()
    if not sqlite() then
      return
    end
    local home = ox.home()
    local dir = home.root .. '/repo'
    local stays = spawn(dir, {})
    local goes = spawn(dir, { '--prompt', 'a quick one' })
    local b = home:session({ directory = dir, title = 'A quick one', start = os.time() + 1 })
    b:user('a quick one'):reply('Done.')
    local get = refreshed(home)
    eq(goes.pid, get(b).pid)
    ox.kill(goes)
    T.wait(3000, function()
      return not require('agent-chats.util.proc').alive(goes.pid)
    end)
    store().refresh_sync()
    store().refresh_sync()
    -- The other process, still idle in that folder, has not taken it up.
    local now = store().get('opencode:' .. b.id)
    ok(now.pid ~= stays.pid, 'given to the process that stayed')
    ok(now.live ~= true, 'still listed as running')
  end)
end)

describe('review: a chat that is listed under a stand-in at first', function()
  local function sqlite()
    if not require('agent-chats.util.sqlite').available() then
      io.stdout:write('  note  no SQLite library; the opencode test is skipped\n')
      return false
    end
    return true
  end

  --- A new opencode chat started from the board, and the row it has.
  local function started(prompt)
    local home = ox.home({ board = { spinner = false }, open = { start_insert = false } })
    local dir = home.root .. '/repo'
    vim.fn.mkdir(dir, 'p')
    local agent = fake.install_as(home.root, 'opencode')
    store().refresh_sync()
    store().start = function() end
    board().open()
    actions().new({ provider = 'opencode', cwd = dir, prompt = prompt })
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    local standin
    for _, c in pairs(store().chats) do
      if c.unstarted then
        standin = c
      end
    end
    assert(standin, 'the new chat has a row')
    return home, dir, agent, standin
  end

  it('is at work on the prompt it was started with', function()
    if not sqlite() then
      return
    end
    local _, _, _, standin = started('the first task')
    eq('working', standin.status)
  end)

  it('takes what was written for it along when its agent has named it', function()
    if not sqlite() then
      return
    end
    local home, dir, _, standin = started('the first task')
    local old = standin.key
    -- A reply queued on the row, and one written and not sent.
    state().enqueue(old, 'queued on the stand-in')
    board().focus()
    notes(function()
      -- It is at work on its prompt: the box is for a reply to wait behind
      -- that. Written, and not queued after all.
      vim.ui.select = function(_, _, cb)
        cb('another')
      end
      actions().queue(standin)
      api.nvim_buf_set_lines(0, 0, -1, false, { 'a draft on the stand-in' })
      input().cancel()
    end)
    -- The agent makes its session.
    local s = home:session({ directory = dir, title = 'The first task', start = os.time() + 1 })
    s:user('the first task'):assistant():text('On it.')
    local real = 'opencode:' .. s.id
    T.wait(3000, function()
      store().refresh_sync()
      local c = store().chats[real]
      return c ~= nil and c.term ~= nil
    end)
    eq(nil, store().chats[old])
    -- Never listed twice on the way.
    local rows = 0
    for _, c in ipairs(store().list()) do
      rows = rows + ((c.cwd == dir) and 1 or 0)
    end
    eq(1, rows)
    eq(0, #state().queue(old))
    eq('queued on the stand-in', state().queue(real)[1].text)
    -- Whoever still holds the old row is led on.
    eq(real, store().get(old).key)
    board().focus()
    -- "Queue another reply": the box has what was written for the stand-in.
    actions().queue(store().get(real))
    eq('a draft on the stand-in', T.buf_text(api.nvim_get_current_buf()))
    input().cancel()
  end)
end)

describe('review: a new git worktree', function()
  local function git(dir, args)
    local cmd = { 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t' }
    local res = vim.system(vim.list_extend(cmd, args), { text = true }):wait()
    assert(res.code == 0, table.concat(args, ' ') .. ': ' .. (res.stderr or ''))
    return vim.trim(res.stdout or '')
  end

  it('takes a submodule for the repository it is, not for the project around it', function()
    if vim.fn.executable('git') ~= 1 then
      return
    end
    local root = T.tmpdir()
    local sub, super = root .. '/sub', root .. '/super'
    vim.fn.mkdir(sub, 'p')
    vim.fn.mkdir(super, 'p')
    git(sub, { 'init', '-q', '-b', 'main' })
    git(sub, { 'commit', '-q', '--allow-empty', '-m', 'init' })
    git(super, { 'init', '-q', '-b', 'main' })
    git(super, { '-c', 'protocol.file.allow=always', 'submodule', '--quiet', 'add', sub, 'lib' })
    local info = require('agent-chats.util.git').read(super .. '/lib')
    eq(vim.fs.normalize(super .. '/lib'), info.repo)
    eq(false, info.worktree)
  end)

  it('starts the new branch where the chosen folder is, also in a linked worktree', function()
    if vim.fn.executable('git') ~= 1 then
      return
    end
    local root = T.tmpdir()
    local repo, tree = root .. '/repo', root .. '/feature'
    vim.fn.mkdir(repo, 'p')
    git(repo, { 'init', '-q', '-b', 'main' })
    git(repo, { 'commit', '-q', '--allow-empty', '-m', 'on main' })
    git(repo, { 'worktree', 'add', '-q', '-b', 'feature', tree })
    git(tree, { 'commit', '-q', '--allow-empty', '-m', 'on feature' })
    local feature = git(tree, { 'rev-parse', 'HEAD' })
    ok(feature ~= git(repo, { 'rev-parse', 'HEAD' }))
    local home = fx.home({ board = { spinner = false } })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    local real_select, real_input = vim.ui.select, vim.ui.input
    local asked = 0
    vim.ui.select = function(items, _, cb)
      asked = asked + 1
      if asked == 1 then
        -- Which agent? In another folder.
        return cb(items[#items])
      elseif asked == 2 then
        -- Which folder? A new worktree of the repository this one is in.
        for _, item in ipairs(items) do
          if item.worktree then
            return cb(item)
          end
        end
      end
      cb(items[1])
    end
    vim.ui.input = function(_, cb)
      cb('from-feature')
    end
    local good, err = pcall(function()
      board().open()
      actions().new({ cwd = tree })
      T.wait(5000, function()
        return agent.read():find('cwd:', 1, true) ~= nil
      end)
    end)
    vim.ui.select, vim.ui.input = real_select, real_input
    assert(good, err)
    local made = agent.read():match('cwd: ([^\n]+)')
    eq(feature, git(made, { 'rev-parse', 'HEAD' }))
  end)
end)

-----------------------------------------------------------------------------
-- Keys, the menu, the boxes, the options
-----------------------------------------------------------------------------

local function keys()
  return require('agent-chats.keys')
end
local function menu()
  return require('agent-chats.ui.menu')
end
local function config()
  return require('agent-chats.config')
end

--- What the list has on `lhs`: "ours", "yours", or nil.
local function on_list(lhs)
  local m = vim.fn.maparg(lhs, 'n', false, true)
  if next(m) == nil then
    return nil
  end
  return (m.buffer == 1 and (m.desc or ''):find('Agent chats', 1, true)) and 'ours' or 'yours'
end

describe('review: a key that gave way', function()
  after_each(function()
    pcall(vim.keymap.del, 'n', 'C')
  end)

  local function reading()
    return vim.bo.filetype == 'agent-chats-conversation'
  end

  it('is the board’s again once the mapping it gave way to is gone', function()
    local _, c = scene()
    board().goto_chat(key(c))
    eq('ours', on_list('C'))
    -- A mapping that turns up while the board is open and removes itself
    -- when it has run (what a lazy-loading stub does).
    local ran = 0
    vim.keymap.set('n', 'C', function()
      vim.keymap.del('n', 'C')
      ran = ran + 1
    end, { desc = 'a stub that removes itself' })
    feed('C')
    vim.wait(50)
    eq(1, ran)
    no(reading())
    board().render()
    -- The bar names C again, and C is there to be pressed.
    eq('C', keys().key('read'))
    eq('ours', on_list('C'))
    feed('C')
    ok(reading(), 'C opens the conversation again')
  end)

  it('stops giving way when the key is named in the options while the board is open', function()
    local home, c = scene()
    board().goto_chat(key(c))
    local opts = vim.deepcopy(config().get())
    opts.keys = { read = 'C' }
    config().setup(opts)
    fake.install(home)
    ok(config().explicit('read'))
    -- A mapping of the user's on that key, made after: the option wins.
    local mine = 0
    vim.keymap.set('n', 'C', function()
      mine = mine + 1
    end, { desc = 'my C' })
    board().render()
    feed('C')
    vim.wait(50)
    eq(0, mine)
    ok(reading(), 'C opens the conversation: it was named in the options')
  end)
end)

describe('review: the menu', function()
  it('lists the subagents of a chat that has not moved for days', function()
    local home = fx.home({ board = { spinner = false } })
    local c = home:chat({ cwd = uv.cwd(), start = os.time() - 4 * 86400 })
    c:user('Map the code'):title('Map the code'):assistant('Mapped.'):turn_done()
    c:write(os.time() - 3 * 86400)
    c:subagent('a1b2c3')
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    board().goto_chat(key(c))
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'Show its subagents')
    menu().close()
  end)

  it('opens with a key Neovim will not take, and names no such key', function()
    local home, c = scene()
    local opts = vim.deepcopy(config().get())
    local long = '<leader>' .. string.rep('x', 60)
    opts.keys = { read = long }
    notes(function()
      config().setup(opts)
      fake.install(home)
      board().render()
    end)
    board().goto_chat(key(c))
    eq({}, keys().wanted('read'))
    local good, err = pcall(board().menu)
    ok(good, tostring(err))
    ok(menu().is_open())
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'Read the conversation')
    hasnt(shown, 'xxxx')
    hasnt(shown, 'a key of yours')
    menu().close()
  end)

  it('moves in the conversation with the conversation’s keys', function()
    local home = fx.home({ board = { spinner = false } })
    local c = home:chat({ cwd = uv.cwd(), start = os.time() - 700 })
    c:user('The first prompt'):title('Two prompts'):assistant('The first answer.')
    c:user('The second prompt'):assistant('The second answer.'):turn_done()
    c:write(os.time() - 600)
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local buf = actions().read(store().get(key(c)))
    T.wait(3000, function()
      return T.buf_text(buf):find('The second answer.', 1, true) ~= nil
    end)
    feed('gg')
    feed('?')
    ok(menu().is_open())
    -- J is "next prompt" here. In the menu it does that, in the conversation.
    feed('J')
    no(menu().is_open())
    eq(buf, api.nvim_get_current_buf())
    has(api.nvim_get_current_line(), '## You')
    local first = api.nvim_win_get_cursor(0)[1]
    feed('?')
    ok(menu().pick('next_prompt'))
    ok(api.nvim_win_get_cursor(0)[1] > first, 'the menu’s line moves on as well')
  end)

  it('cuts a long title at its end, not at its start', function()
    local _, c =
      scene(nil, { title = 'A title that goes on and on and on, far past what any menu is wide' })
    board().goto_chat(key(c))
    feed('?')
    local cfg = api.nvim_win_get_config(0)
    local title = cfg.title[1][1]
    ok(vim.fn.strdisplaywidth(title) <= cfg.width, 'the title fits the menu')
    has(title, ' A title that goes on')
    menu().close()
  end)

  it('puts the key of "group" beside the grouping it would pick', function()
    local home = scene()
    local opts = vim.deepcopy(config().get())
    opts.keys = { group = 'gb', pin = ' ' }
    notes(function()
      config().setup(opts)
      fake.install(home)
      board().render()
    end)
    feed('?')
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'gb     Group by folder')
    -- The groupings after it are there as well, with no key: it is the
    -- next one the key picks.
    has(shown, '\n         Group by agent')
    menu().close()
    -- And a key written as a blank is named.
    eq('Space', keys().name(' '))
  end)

  it('keeps its title and its keys when floats have no border', function()
    local had = vim.o.winborder
    vim.o.winborder = 'none'
    local good, err = pcall(function()
      local _, c = scene()
      board().goto_chat(key(c))
      feed('?')
      local cfg = api.nvim_win_get_config(0)
      ok(type(cfg.border) == 'table' and cfg.border[1] ~= '', 'the menu has a border')
      has(cfg.title[1][1], 'Fix the parser')
      menu().close()
      actions().queue(store().get(key(c)))
      cfg = api.nvim_win_get_config(0)
      ok(type(cfg.border) == 'table' and cfg.border[1] ~= '', 'the box has a border')
      has(cfg.footer[1][1], '<C-s> send')
      input().cancel()
    end)
    vim.o.winborder = had
    assert(good, err)
  end)
end)

describe('review: the options', function()
  it('keeps the defaults of a section that is given as something else', function()
    local said = notes(function()
      fx.home({ transcript = false })
    end)
    has(said, 'conversation must be a table of options')
    eq('table', type(config().get().conversation))
    said = notes(function()
      fx.home({ board = { 'float' }, icons = { '*' } })
    end)
    has(said, 'board must be a table of named options')
    has(said, 'icons must be a table of named options')
    eq(nil, config().get().board[1])
    -- And the board opens.
    store().refresh_sync()
    store().start = function() end
    board().open()
    ok(board().is_open())
  end)

  it('stops the watcher when it is switched off', function()
    fx.home()
    -- A watcher that an earlier setup() started.
    local s = store()
    local is_watching, stop = s.is_watching, s.stop
    local stopped = false
    s.is_watching = function()
      return not stopped
    end
    s.stop = function()
      stopped = true
    end
    local opts = vim.deepcopy(config().get())
    opts.keys = nil
    opts.watch.enabled = false
    local good, err = pcall(require('agent-chats').setup, opts)
    s.is_watching, s.stop = is_watching, stop
    assert(good, err)
    ok(stopped, 'still watching')
  end)

  it('names the command that is this plugin’s', function()
    fx.home()
    local had = vim.g.agent_chats_command
    vim.g.agent_chats_command = 'Chats'
    eq(':Chats menu', config().command('menu'))
    -- Where :Chats is another plugin's.
    vim.g.agent_chats_command = 'AgentChats'
    eq(':AgentChats menu', config().command('menu'))
    eq(':AgentChats', config().command())
    vim.g.agent_chats_command = had
  end)

  it('completes after a command name that is cut short', function()
    fx.home()
    if vim.fn.exists(':AgentChats') ~= 2 then
      vim.cmd('runtime plugin/agent-chats.lua')
    end
    if vim.fn.exists(':AgentChats') ~= 2 then
      return
    end
    local complete = require('agent-chats').complete
    eq({ 'claude' }, complete('', 'AgentC new '))
    eq({ 'install' }, complete('ins', 'tab Chats hooks ins'))
    ok(vim.tbl_contains(complete('', 'Chats '), 'search'))
  end)

  it('reports the hooks of the agents that were named, and no others', function()
    fx.home()
    local all = require('agent-chats').hooks('status')
    local codex = require('agent-chats').hooks('status', { 'codex' })
    ok(#all >= 1)
    eq(0, #codex)
    local claude = require('agent-chats').hooks('status', { 'claude' })
    eq(1, #claude)
    has(claude[1], 'Claude')
  end)
end)

describe('review: checkhealth on keys', function()
  after_each(function()
    for _, lhs in ipairs({ '?', 'g?' }) do
      pcall(vim.keymap.del, 'n', lhs)
    end
    pcall(vim.keymap.del, 't', [[<C-\><C-b>]])
  end)

  it('says how the menu is reached when its keys are yours, and how to take a key', function()
    fx.home()
    vim.keymap.set('n', '?', function() end, { desc = 'my ?' })
    vim.keymap.set('n', 'g?', function() end, { desc = 'my g?' })
    vim.keymap.set('t', [[<C-\><C-b>]], function() end, { desc = 'my terminal key' })
    local lines = {}
    for _, line in ipairs(require('agent-chats.health').keys()) do
      lines[#lines + 1] = line.text
      eq(nil, line.advice)
    end
    local all = table.concat(lines, '\n')
    has(all, ':Chats menu opens it, and it has no key')
    hasnt(all, '"menu": that is in the menu')
    has(all, [[<C-\><C-b> is yours while typing in a terminal]])
    -- The advice is a line of its own: checkhealth prints nothing else of it.
    has(lines[#lines], 'name it in the options')
  end)
end)

describe('review: a box to write in', function()
  it('leaves typing in a terminal alone when the cursor has already left for it', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    board().focus()
    actions().queue(store().get(key(c)))
    ok(input().is_open())
    api.nvim_buf_set_lines(0, 0, -1, false, { 'half a reply' })
    -- Into the chat's terminal, as a click or a window command goes; there,
    -- typing.
    local win = vim.fn.win_findbuf(buf)[1]
    ok(win, 'the terminal is on screen')
    local mode
    notes(function()
      api.nvim_set_current_win(win)
      T.typing(function()
        -- The box closes behind the cursor, a moment later.
        vim.wait(100)
        mode = api.nvim_get_mode().mode
      end)
    end)
    no(input().is_open())
    eq('t', mode)
  end)
end)

describe('review: what is remembered of buffers', function()
  it('forgets the keys of conversations that are closed', function()
    local _, c = scene()
    local mine
    for i = 1, 60 do
      local name, value = debug.getupvalue(keys().set, i)
      if name == 'mine' then
        mine = value
      end
      if not name then
        break
      end
    end
    assert(mine, 'keys.lua keeps its mappings in `mine`')
    for _ = 1, 6 do
      local buf = actions().read(store().get(key(c)))
      T.wait(3000, function()
        return T.buf_text(buf):find('The parser is fixed.', 1, true) ~= nil
      end)
      feed('q')
    end
    local gone = 0
    for buf in pairs(mine) do
      gone = gone + (api.nvim_buf_is_valid(buf) and 0 or 1)
    end
    -- At most the one that was closed last: it goes when the next is opened.
    ok(gone <= 1, gone .. ' closed buffers are still remembered')
  end)
end)

-----------------------------------------------------------------------------
-- The board and its views
-----------------------------------------------------------------------------

local function list()
  return T.buf_text(board()._state.buf)
end

--- The bar above the list, as it reads.
local function bar()
  local raw = vim.wo[board()._state.win].winbar
  return (raw:gsub('%%#%w+#', ''):gsub('%%%*', ''):gsub('%%=', ' | '))
end

describe('review: the pane beside the list', function()
  it('shows a chat’s terminal without anyone being told the cursor went there', function()
    local home, c, agent = scene()
    local other = chat(home, { title = 'Another chat', age = 900 })
    store().refresh_sync()
    local buf = host(c, agent)
    board().focus()
    board().goto_chat(key(other))
    board().render()
    ok(api.nvim_win_get_buf(board()._state.pane_win) ~= buf)
    -- The common "start typing when I enter a terminal".
    local entered = 0
    local au = api.nvim_create_autocmd('BufEnter', {
      callback = function(ev)
        if vim.bo[ev.buf].buftype == 'terminal' then
          entered = entered + 1
        end
      end,
    })
    board().goto_chat(key(c))
    board().render()
    api.nvim_del_autocmd(au)
    eq(buf, api.nvim_win_get_buf(board()._state.pane_win), 'its terminal is in the pane')
    eq(board()._state.win, api.nvim_get_current_win())
    eq(0, entered, 'BufEnter was fired for a terminal the cursor did not enter')
  end)

  it('does not take "unread" away from a chat the cursor only passed over', function()
    local home, c, agent = scene()
    local other = chat(home, { title = 'Another chat', age = 900 })
    store().refresh_sync()
    local buf = host(c, agent)
    board().focus()
    board().goto_chat(key(other))
    board().render()
    -- A turn ends in the hosted chat while the cursor is elsewhere: unread.
    local pid = store().get(key(c)).pid
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = uv.cwd() })
    store().refresh_sync({ full = false })
    c.ts = os.time() + 2
    c:user('one more'):assistant('there it is'):turn_done():write(os.time() + 3)
    home:registry(pid, { sessionId = c.id, status = 'idle', cwd = uv.cwd() })
    store().refresh_sync()
    eq('done', store().get(key(c)).status)
    -- The cursor comes past its row: its terminal is in the pane for a blink.
    board().goto_chat(key(c))
    board().render()
    eq(buf, api.nvim_win_get_buf(board()._state.pane_win))
    store().refresh_sync()
    eq('done', store().get(key(c)).status, 'read after a glance')
    -- Left there for a while, it has been looked at.
    board()._state.shown_since = uv.hrtime() - 5e9
    store().refresh_sync()
    eq('idle', store().get(key(c)).status)
  end)
end)

describe('review: where closing the board leads', function()
  it('goes back to where the board was last asked for, not where it was first opened', function()
    local _ = scene()
    board().close()
    vim.cmd('edit one.txt')
    local one = api.nvim_get_current_tabpage()
    board().open()
    vim.cmd('tabnew three.txt')
    local three = api.nvim_get_current_tabpage()
    ok(one ~= three)
    -- "Run it again from anywhere."
    board().open()
    eq(board()._state.tab, api.nvim_get_current_tabpage())
    feed('q')
    no(board().is_open())
    eq(three, api.nvim_get_current_tabpage())
    vim.cmd('silent! tabonly! | silent! %bwipeout!')
  end)

  it('leaves the cursor where it is when the board is closed from another tab', function()
    scene()
    vim.cmd('tabnew elsewhere.txt')
    vim.cmd('tabnew here.txt')
    local here = api.nvim_get_current_tabpage()
    board().close()
    no(board().is_open())
    eq(here, api.nvim_get_current_tabpage())
    vim.cmd('silent! tabonly! | silent! %bwipeout!')
  end)

  it('keeps a board that is opened in the tick its window was closed', function()
    scene()
    local timers = function()
      return board()._state.timer
    end
    eq(nil, timers(), 'no spinner in this test')
    vim.cmd('quit')
    board().open()
    ok(board().is_open())
    vim.wait(100)
    ok(board().is_open(), 'closed by the closing of the board before it')
  end)
end)

describe('review: the floating board', function()
  local function float(extra)
    local home, c, agent =
      scene(vim.tbl_deep_extend('force', { board = { layout = 'float' } }, extra or {}))
    return home, c, agent
  end

  it('moves between the list and the pane with window commands', function()
    local _, c = float()
    local S = board()._state
    eq('float', S.layout)
    board().goto_chat(key(c))
    ok(S.pane_win and api.nvim_win_is_valid(S.pane_win), 'the pane is there')
    feed('<C-w>l')
    vim.wait(30)
    ok(board().is_open(), 'the board closed')
    eq(S.pane_win, api.nvim_get_current_win())
    feed('<C-w>h')
    vim.wait(30)
    ok(board().is_open())
    eq(S.win, api.nvim_get_current_win())
    feed('<C-w>w')
    vim.wait(30)
    eq(S.pane_win, api.nvim_get_current_win())
    feed('<C-w>p')
    vim.wait(30)
    eq(S.win, api.nvim_get_current_win())
    -- Nothing above or below: the cursor stays in the board.
    feed('<C-w>j')
    vim.wait(30)
    ok(board().is_open())
  end)

  it('gives the list the whole board back when the summary is closed with :q', function()
    float()
    local S = board()._state
    local whole = board()._float_dims().width
    ok(api.nvim_win_get_width(S.win) < whole)
    api.nvim_set_current_win(S.pane_win)
    vim.cmd('quit')
    vim.wait(50)
    ok(board().is_open())
    eq(whole, api.nvim_win_get_width(S.win))
  end)

  it('gives the pane the border of the list, also when that is none', function()
    local had = vim.o.winborder
    vim.o.winborder = 'single'
    local good, err = pcall(function()
      float({ board = { border = 'none' } })
      local S = board()._state
      local function bordered(win)
        local b = api.nvim_win_get_config(win).border
        return type(b) == 'table' and b[1] ~= '' and b[1] ~= ' '
      end
      no(bordered(S.win))
      no(bordered(S.pane_win), 'the pane took the border of every float')
    end)
    vim.o.winborder = had
    assert(good, err)
  end)
end)

describe('review: rows and headings', function()
  it('keeps the queued replies on a row whose labels do not fit', function()
    local _, c = scene()
    state().enqueue(key(c), 'later')
    state().set_labels(key(c), { 'a-label-that-is-long-enough-to-fill-any-row', 'second' })
    local S = board()._state
    api.nvim_win_set_width(S.win, 60)
    board().render()
    local row
    for _, l in ipairs(api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
      if l:find('Fix the parser', 1, true) then
        row = l
      end
    end
    assert(row, list())
    has(row, '»1')
    hasnt(row, 'a-label-that-is-long')
    -- And with no mark that fits beside a dozen cells of title, the title
    -- has the room.
    has(row, 'Fix the parser')
  end)

  it('draws a chat whose folder has a line break in its name', function()
    local home = fx.home({ board = { spinner = false } })
    local c = home:chat({ cwd = '/work/odd\nname', start = os.time() - 700 })
    c:user('In an odd folder'):title('In an odd folder'):assistant('Yes.'):turn_done()
    c:write(os.time() - 600)
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local good, err = pcall(board().open)
    ok(good, tostring(err))
    ok(board().is_open())
    has(list(), 'In an odd folder')
    board().set_group('folder')
    has(list(), 'In an odd folder')
  end)

  it('cuts a folder heading to the list, and keeps its count', function()
    local home = fx.home({ board = { spinner = false } })
    local deep = '/work/' .. string.rep('a-rather-long-folder-name/', 4) .. 'the-project'
    local c = home:chat({ cwd = deep, start = os.time() - 700 })
    c:user('Deep down'):title('Deep down'):assistant('Yes.'):turn_done()
    c:write(os.time() - 600)
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local S = board()._state
    api.nvim_win_set_width(S.win, 44)
    board().set_group('folder')
    for _, l in ipairs(api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
      ok(api.nvim_strwidth(l) <= 44, ('%d cells: %s'):format(api.nvim_strwidth(l), l))
      if l:find('the-project', 1, true) then
        has(l, 'the-project  1')
      end
    end
    has(list(), 'the-project  1')
  end)

  it('keeps the cursor of a second window on the list with its chat', function()
    local home = fx.home({ board = { spinner = false } })
    local a = chat(home, { title = 'Alpha', age = 100 })
    local b = chat(home, { title = 'Bravo', age = 200 })
    local c = chat(home, { title = 'Charlie', age = 300 })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local S = board()._state
    vim.cmd('split')
    local second = api.nvim_get_current_win()
    ok(second ~= S.win)
    board().goto_chat(key(c))
    for i, row in ipairs(S.rows) do
      if row.chat and row.chat.key == key(c) then
        api.nvim_win_set_cursor(second, { i, 1 })
      end
    end
    -- Rows above it come and go.
    state().toggle_pin(key(b))
    state().toggle_archive(key(a), store().get(key(a)).updated)
    board().render()
    local at = S.rows[api.nvim_win_get_cursor(second)[1]]
    eq(key(c), at and at.chat and at.chat.key)
  end)

  it('measures a row by its text, whatever window the cursor is in', function()
    local text = require('agent-chats.util.text')
    vim.cmd('new')
    vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = true, true, true
    api.nvim_win_set_width(0, 20)
    local long = string.rep('word ', 30)
    eq(150, text.width(long))
    vim.cmd('bwipeout!')
    -- An ellipsis that is two cells wide still fits what it is cut to.
    local had = vim.o.ambiwidth
    local good, err = pcall(function()
      vim.o.ambiwidth = 'double'
      local cut = text.truncate('a title that will not fit', 10)
      ok(api.nvim_strwidth(cut) <= 10, cut)
      ok(api.nvim_strwidth(text.truncate_left('a title that will not fit', 10)) <= 10)
    end)
    vim.o.ambiwidth = had
    assert(good, err)
  end)

  it('redraws once for the answer git gives about a folder of many chats', function()
    if vim.fn.executable('git') ~= 1 then
      return
    end
    local home = fx.home({ board = { spinner = false } })
    local repo = T.tmpdir()
    vim.system({ 'git', '-C', repo, 'init', '-q' }):wait()
    for i = 1, 12 do
      local c = home:chat({ cwd = repo, start = os.time() - 700 - i })
      c:user('Task ' .. i):title('Task ' .. i):assistant('Done.'):turn_done()
      c:write(os.time() - 600 - i)
    end
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local real, drawn = board().render, 0
    board().render = function(...)
      drawn = drawn + 1
      return real(...)
    end
    local good, err = pcall(function()
      board().set_group('folder')
      local before = drawn
      T.wait(3000, function()
        return require('agent-chats.util.git').cached(repo) ~= nil
      end)
      vim.wait(100)
      ok(drawn - before <= 2, (drawn - before) .. ' redraws for one answer')
    end)
    board().render = real
    assert(good, err)
  end)
end)

describe('review: searching', function()
  it('finds and marks a text typed with a blank behind it', function()
    local home = fx.home({ board = { spinner = false } })
    chat(home, { title = 'About the tokenizer', reply = 'Here the tokenizer is described.' })
    chat(home, { title = 'Something else', age = 900 })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    board().search('tokenizer ', { conversations = false })
    eq('tokenizer', board().query())
    has(list(), 'About the tokenizer')
    hasnt(list(), 'Something else')
    local S = board()._state
    local ns = api.nvim_get_namespaces()['agent-chats-board']
    local marked = 0
    for _, m in ipairs(api.nvim_buf_get_extmarks(S.buf, ns or -1, 0, -1, { details = true })) do
      if m[4].hl_group == 'AgentChatsMatch' then
        marked = marked + 1
      end
    end
    ok(marked >= 1, 'the text is marked where it shows')
  end)

  it('opens the question empty, also when a search is on', function()
    local home = fx.home({ board = { spinner = false } })
    chat(home, { title = 'Tagging the release' })
    chat(home, { title = 'Upload the build', age = 900 })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    feed('Stagging<CR>')
    eq('tagging', board().query())
    -- What is typed next is the text to look for, not more of the last.
    feed('Supload<CR>')
    eq('upload', board().query())
    has(list(), 'Upload the build')
  end)

  it('does not offer to fold a group while a search is on', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { title = 'Fix the parser' })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    board().search('parser', { conversations = false })
    local S = board()._state
    for i, row in ipairs(S.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(S.win, { i, 1 })
        break
      end
    end
    api.nvim_exec_autocmds('CursorMoved', { buffer = S.buf })
    vim.wait(30)
    hasnt(bar(), 'fold')
    feed('?')
    hasnt(table.concat(menu().lines(), '\n'), 'old this group')
    menu().close()
    no(c == nil)
  end)

  it('leaves / to Vim inside a conversation, where n and N follow it', function()
    local _, c = scene()
    local buf = actions().read(store().get(key(c)))
    T.wait(3000, function()
      return T.buf_text(buf):find('The parser is fixed.', 1, true) ~= nil
    end)
    eq(buf, api.nvim_get_current_buf())
    local slash = vim.fn.maparg('/', 'n', false, true)
    ok(next(slash) == nil or slash.buffer ~= 1, '/ is mapped on the conversation')
    -- The search over every chat keeps its other key.
    eq(1, vim.fn.maparg('S', 'n', false, true).buffer)
    feed('gg')
    feed('/parser is fixed<CR>')
    has(api.nvim_get_current_line(), 'The parser is fixed.')
    eq(nil, board()._state.search)
  end)
end)

describe('review: the bar', function()
  it('says why there is no reply before it names the less used keys', function()
    local home = fx.home({ board = { spinner = false } })
    local away = chat(home, { title = 'Runs elsewhere', age = 120 })
    home:registry(uv.os_getpid(), { sessionId = away.id, status = 'busy' })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    state().enqueue(key(away), 'for later')
    local S = board()._state
    api.nvim_win_set_width(S.win, 58)
    board().goto_chat(key(away))
    board().render()
    -- Before "queued replies" and "pass": those are in the menu, and why
    -- Enter only reads this chat is nowhere else.
    eq(' Enter read   (it runs outside this Neovim) | ? menu ', bar())
    api.nvim_win_set_width(S.win, 44)
    board().render()
    eq(' Enter read   (runs elsewhere) | ? menu ', bar())
    home:unregister(uv.os_getpid())
  end)
end)

-----------------------------------------------------------------------------
-- What someone new to the board ran into
-----------------------------------------------------------------------------

describe('review: what a search finds', function()
  --- A chat in which a command was run.
  local function with_tool(home, opts)
    local c = home:chat({ cwd = uv.cwd(), start = os.time() - 700 })
    c:user(opts.prompt or 'Run the tests'):title(opts.title or 'Running the tests')
    c:tool_use('Bash', { command = 'make test', description = 'Run the suite' })
    c:tool_result('3 passed')
    c:assistant(opts.reply or 'All of them pass. ' .. string.rep('And so on, at some length. ', 6))
    c:turn_done()
    return c:write(os.time() - 600)
  end

  local function searched(query)
    board().search(query)
    T.wait(3000, function()
      local s = board()._state.search
      return s and s.read and not s.running
    end)
  end

  it('finds the line a tool call has in the conversation', function()
    local home = fx.home({ board = { spinner = false } })
    local c = with_tool(home, {})
    chat(home, { title = 'Something else', age = 900 })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    searched('make test')
    has(list(), 'Running the tests')
    hasnt(list(), 'No chat has')
    -- Shown as something the agent did, by its name.
    has(list(), 'Claude: Bash · make test')
    no(c == nil)
  end)

  it('opens the conversation of a chat it found at the first passage, not at its end', function()
    local home = fx.home({ board = { spinner = false } })
    local c = home:chat({ cwd = uv.cwd(), start = os.time() - 700 })
    c:user('Tell me about the wombat'):title('Animals'):assistant('The wombat digs.')
    for i = 1, 30 do
      c:user('And number ' .. i .. '?'):assistant('Number ' .. i .. ' is another animal.')
    end
    c:turn_done()
    c:write(os.time() - 600)
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    searched('wombat')
    board().goto_chat(key(c))
    eq('chat', board().row().kind)
    feed('C')
    T.wait(3000, function()
      return vim.bo.filetype == 'agent-chats-conversation'
        and api.nvim_get_current_line():find('wombat', 1, true) ~= nil
    end, 'the cursor is on the passage')
  end)

  it('keeps the words it found in view on a narrow list', function()
    local home = fx.home({ board = { spinner = false } })
    local c = home:chat({ cwd = uv.cwd(), start = os.time() - 700 })
    c:user('Plan it'):title('Planning')
    c:assistant(
      'The workflow walks through a whole week in five lines of plain text, and then the zebra appears at the very end of it.'
    )
    c:turn_done()
    c:write(os.time() - 600)
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local S = board()._state
    api.nvim_win_set_width(S.win, 40)
    searched('zebra')
    local passage
    for i, row in ipairs(S.rows) do
      if row.kind == 'hit' then
        passage = api.nvim_buf_get_lines(S.buf, i - 1, i, false)[1]
      end
    end
    assert(passage, list())
    has(passage, 'zebra')
    ok(api.nvim_strwidth(passage) <= 40, passage)
  end)
end)

describe('review: what is said, and where', function()
  it('does not say twice what a chat is waiting to run', function()
    local waiting = require('agent-chats.display').waiting
    eq(
      { 'permission to run: rm -rf .cache/sessions' },
      waiting({
        waiting_for = 'permission to run: rm -rf .cache/sessions',
        activity = 'Bash: rm -rf .cache/sessions',
      })
    )
    -- What it is doing is said when it is something else.
    eq(
      { 'your answer to a question', 'Edit: src/main.lua' },
      waiting({ waiting_for = 'your answer to a question', activity = 'Edit: src/main.lua' })
    )
  end)

  it('fits the welcome to a narrow pane, each key with its words beside it', function()
    fx.home()
    local lines = require('agent-chats.ui.preview').intro(38)
    for _, l in ipairs(lines) do
      ok(api.nvim_strwidth(l) <= 38, ('%d cells: %s'):format(api.nvim_strwidth(l), l))
    end
    local all = table.concat(lines, '\n')
    -- What does not fit beside a key goes on under its words, not under the key.
    has(
      all,
      '    Enter  go into a chat and type\n           (one that ended is\n           resumed, in its folder)'
    )
    -- Said near the top, where a small window still shows it.
    local once
    for i, l in ipairs(lines) do
      if l:find('shown once', 1, true) then
        once = i
      end
    end
    ok(once and once <= 12, 'line ' .. tostring(once))
  end)

  it('names a chat’s terminal as it names its conversation', function()
    local _, c, agent = scene()
    local buf = host(c, agent)
    local name = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ':t')
    eq(('Agent chat: Fix the parser · Claude [%d]'):format(buf), name)
    hasnt(api.nvim_buf_get_name(buf), '://')
  end)
end)

describe('review: the summary in a narrow pane', function()
  it('goes on under its own words, and does not break in the middle of a path', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { title = 'Runs elsewhere', age = 120 })
    home:registry(uv.os_getpid(), { sessionId = c.id, status = 'busy' })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    state().enqueue(key(c), 'Then run the benchmarks and post the numbers.')
    local chat_now = store().get(key(c))
    chat_now.activity = 'Edit: ~/work/engine/src/main.lua'
    local lines = require('agent-chats.ui.preview').lines(chat_now, nil, board()._state.rows, 40)
    local all = table.concat(lines, '\n')
    -- The path is whole, on a line of its own.
    has(all, '\n  ~/work/engine/src/main.lua\n')
    -- A fact goes on under its value, not under its label.
    has(all, "Status  known from the agent's own list\n        of running sessions")
    has(all, 'Queued  1 reply, not sent: nothing can\n        send it to this chat from here')
    -- Without a width (whoever asks for the lines as they are): one line each.
    local plain = table.concat(
      require('agent-chats.ui.preview').lines(chat_now, nil, board()._state.rows),
      '\n'
    )
    has(plain, "Status  known from the agent's own list of running sessions")
    home:unregister(uv.os_getpid())
  end)
end)

-----------------------------------------------------------------------------
-- Asked for after a first look at the board
-----------------------------------------------------------------------------

describe('notifications: one switch, in the menu', function()
  local notify = function()
    return require('agent-chats.notify')
  end
  local function first_line()
    return api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1]
  end
  --- What is announced when `c` finishes a turn: the event, or nil.
  local function finishes(c)
    local event
    notes(function()
      event =
        notify().handle({ chat = store().get(key(c)), from = 'working', to = 'done', fresh = true })
    end)
    return event
  end

  it('is a line of the menu: Enter on it switches them', function()
    local _, c = scene({ notify = { enabled = true } })
    -- On: nothing on the first line is about them, and no key is.
    hasnt(first_line(), 'notif')
    no(vim.fn.maparg('M', 'n', false, true).buffer == 1)
    ok(notify().enabled())
    ok(finishes(c), 'a chat that finishes is announced')
    feed('?')
    -- The line says what choosing it does, with no key beside it.
    has(table.concat(menu().lines(), '\n'), '\n         Turn notifications off')
    -- Two steps up from where the menu opens (it goes round), and Enter.
    feed('k')
    feed('k')
    has(api.nvim_get_current_line(), 'Turn notifications off')
    local said = notes(function()
      feed('<CR>')
    end)
    no(menu().is_open())
    has(said, 'Notifications are off')
    no(notify().enabled())
    eq(nil, finishes(c), 'nothing is announced while they are off')
    -- The events for whoever listens are not part of the switch.
    local heard = 0
    local au = api.nvim_create_autocmd('User', {
      pattern = 'AgentChatsDone',
      callback = function()
        heard = heard + 1
      end,
    })
    finishes(c)
    api.nvim_del_autocmd(au)
    eq(1, heard)
    feed('?')
    has(table.concat(menu().lines(), '\n'), '\n         Turn notifications on')
    said = notes(function()
      ok(menu().pick('notify'))
    end)
    has(said, 'Notifications are on')
    ok(finishes(c))
  end)

  it('says on the first line that they are off, and nothing while they are on', function()
    scene({ notify = { enabled = true } })
    hasnt(first_line(), 'notif')
    notes(function()
      notify().set(false)
    end)
    has(first_line(), 'S search   notifications off')
    -- Not a key, and not a switch: the words only.
    hasnt(first_line(), 'M ')
    hasnt(first_line(), 'notify:')
    notes(function()
      notify().set(true)
    end)
    hasnt(first_line(), 'notif')
  end)

  it('is one switch for every Neovim, and is kept', function()
    local home = scene({ notify = { enabled = true } })
    notes(function()
      notify().set(false)
    end)
    -- Another Neovim (or this one, started again) reads it from the state file.
    state().reset()
    no(notify().enabled())
    board().render()
    has(first_line(), 'notifications off')
    local saved = vim.json.decode(table.concat(vim.fn.readfile(home.root .. '/state.json'), '\n'))
    eq('off', saved.notify)
    -- The option does not switch it back: what was said on the board holds.
    local opts = vim.deepcopy(config().get())
    opts.keys = nil
    opts.notify.enabled = true
    config().setup(opts)
    no(notify().enabled())
  end)

  it('follows the option until it is used, and can switch on what the option has off', function()
    scene({ notify = { enabled = false } })
    eq(nil, state().notify())
    no(notify().enabled())
    has(first_line(), 'notifications off')
    feed('?')
    notes(function()
      ok(menu().pick('Turn notifications on'))
    end)
    ok(notify().enabled())
    hasnt(first_line(), 'notif')
  end)

  it('is a command as well', function()
    scene({ notify = { enabled = true } })
    -- :Chats notify [on|off]
    if vim.fn.exists(':Chats') ~= 2 then
      vim.cmd('runtime plugin/agent-chats.lua')
    end
    notes(function()
      vim.cmd('Chats notify off')
    end)
    no(notify().enabled())
    notes(function()
      vim.cmd('Chats notify on')
    end)
    ok(notify().enabled())
    notes(function()
      vim.cmd('Chats notify')
    end)
    no(notify().enabled())
    local said = notes(function()
      vim.cmd('Chats notify loud')
    end)
    has(said, 'takes "on" or "off"')
    no(notify().enabled())
    eq({ 'on', 'off' }, require('agent-chats').complete('', 'Chats notify '))
  end)

  it('gives way on a narrow list, where the keys that are used all day stay', function()
    scene({ notify = { enabled = false } })
    local S = board()._state
    has(first_line(), 'notifications off')
    api.nvim_win_set_width(S.win, 39)
    board().render()
    hasnt(first_line(), 'notifications')
    has(first_line(), 'S search')
    ok(api.nvim_strwidth(first_line()) <= 39)
  end)

  it('has a key where you give it one, which the menu then names', function()
    local _, c = scene({ notify = { enabled = true }, keys = { notify = 'M' } })
    ok(vim.fn.maparg('M', 'n', false, true).buffer == 1)
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'M      Turn notifications off')
    -- In the menu the key picks its line, as every key shown there does.
    local said = notes(function()
      feed('M')
    end)
    no(menu().is_open())
    has(said, 'Notifications are off')
    notes(function()
      feed('M')
    end)
    ok(notify().enabled())
    ok(finishes(c))
    -- The first line names no key for it all the same.
    hasnt(first_line(), 'M ')
  end)
end)

describe('what is said to a chat is typed in the chat', function()
  it('has no key and no box on the list: Enter goes there', function()
    local _, c, agent = scene()
    board().goto_chat(key(c))
    -- R and F are Vim's own again (nothing of the board's is on them).
    eq('', vim.fn.maparg('R', 'n'))
    eq('', vim.fn.maparg('F', 'n'))
    eq(nil, actions().reply)
    eq(nil, actions().fork)
    feed('<CR>')
    T.wait(3000, function()
      return agent.read():find('--resume ' .. c.id, 1, true) ~= nil
    end)
    eq('terminal', vim.bo.buftype)
    no(input().is_open())
  end)

  it('says so to a setup that still names a key for a reply or a fork', function()
    local said = notes(function()
      fx.home({ keys = { reply = 'r', fork = 'f' } })
    end)
    has(said, 'keys.reply is gone: Enter goes into the chat, and the reply is typed there')
    has(said, 'keys.fork is gone: forking a chat was taken out')
    eq(nil, config().get().keys.reply)
    eq(nil, config().get().keys.fork)
  end)
end)
