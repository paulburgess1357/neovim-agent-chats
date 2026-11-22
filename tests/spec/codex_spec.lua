local T = require('helpers.harness')
local fx = require('helpers.codex')
local eq, ok, no = T.eq, T.ok, T.no

local function provider()
  return require('agent-chats.providers.codex')
end

--- Discover + parse the single rollout written by `build`.
local function parsed(build, opts)
  local home = fx.home()
  local r =
    home:rollout(vim.tbl_extend('force', { cwd = '/work/alpha', branch = 'feature' }, opts or {}))
  build(r, home)
  r:write()
  local entries = provider().discover()
  eq(1, #entries)
  return provider().parse(entries[1]), entries[1], r, home
end

local function roles(msgs)
  return vim.tbl_map(function(m)
    return m.role
  end, msgs)
end

describe('codex discover', function()
  it('lists rollouts by their session id and nothing else', function()
    local home = fx.home()
    local a = home:rollout({ start = os.time() - 86400 * 40 }):meta():write()
    local b = home:rollout():meta():write()
    T.write(home.dir .. '/sessions/2026/01/01/notes.txt', 'not a chat')
    T.write(
      home.dir .. '/sessions/2026/01/01/rollout-2026-01-01T00-00-00-' .. fx.uuid() .. '.jsonl',
      ''
    )
    T.write(home.dir .. '/sessions/stray.jsonl', '{}')
    local entries = provider().discover()
    table.sort(entries, function(x, y)
      return x.id < y.id
    end)
    eq({ a.id, b.id }, { entries[1].id, entries[2].id })
    eq(2, #entries)
    eq(a.path, entries[1].path)
    ok(entries[1].size > 0 and entries[1].mtime > 0)
    eq(b.path, provider().locate(b.id).path)
    eq(nil, provider().locate(fx.uuid()))
  end)

  it('copes with a home that has no chats', function()
    fx.home()
    eq({}, provider().discover())
    ok(provider().available())
  end)
end)

describe('codex parse', function()
  it('reads an events-generation rollout', function()
    local p, _, r = parsed(function(r, home)
      home:index(r.id, 'Old name')
      home:index(fx.uuid(), 'Someone else')
      home:index(r.id, 'Fix flaky test')
      r:meta({ source = 'vscode' }):context():task_started():noise()
      r:user_message('Fix the flaky test')
      r:agent_message('Looking at it.', 'commentary')
      r:function_call('exec_command', { cmd = 'make test' }):function_output('1 failed')
      r:agent_message('Fixed: the fixture leaked.')
      r:task_complete('Fixed: the fixture leaked.')
      r:task_started():user_message('Now update the docs'):agent_message('Docs updated.')
      r:task_complete('Docs updated.')
    end)
    eq('Fix flaky test', p.title)
    eq('Fix the flaky test', p.first_prompt)
    eq('Now update the docs', p.last_prompt)
    eq('Docs updated.', p.last_reply)
    eq('/work/alpha', p.cwd)
    eq('feature', p.branch)
    eq('vscode', p.origin)
    eq('gpt-test-1', p.model)
    eq('done', p.turn)
    no(p.pending_tool)
    eq(r.ts, p.updated)
    eq(p.updated, p.turn_at)
    ok(p.created < p.updated)
  end)

  it('reads an items-generation rollout', function()
    local p = parsed(function(r)
      r:meta():task_started():context():noise()
      r:item_user('Port the renderer')
      r:item_agent('Starting.', 'commentary')
      r:custom_call('exec', 'const r = await tools.exec_command({cmd: "ls"});')
        :custom_output('a.lua')
      r:item_command('ls', 'a.lua')
      r:item_agent('Ported.')
      r:task_complete('Ported.')
    end)
    eq(nil, p.title)
    eq('Port the renderer', p.first_prompt)
    eq('Port the renderer', p.last_prompt)
    eq('Ported.', p.last_reply)
    eq('cli', p.origin)
    eq('done', p.turn)
  end)

  it('is working mid-turn and names the outstanding tool call', function()
    local p = parsed(function(r)
      r:meta():task_started():item_user('Run the build')
    end)
    eq('working', p.turn)
    no(p.pending_tool)

    p = parsed(function(r)
      r:meta():task_started():user_message('Run the build')
      r:function_call('exec_command', { cmd = 'make -j8 all', workdir = '/work/alpha' })
    end)
    eq('working', p.turn)
    ok(p.pending_tool)
    eq('exec_command: make -j8 all', p.activity)
    no(p.asking)

    p = parsed(function(r)
      r:meta():task_started():item_user('Patch it')
      r:custom_call('exec', 'await tools.one();'):custom_output('ok')
      r:custom_call(
        'apply_patch',
        '*** Begin Patch\n*** Update File: src/a.lua\n@@\n-x\n+y\n*** End Patch'
      )
    end)
    ok(p.pending_tool)
    eq('apply_patch: src/a.lua', p.activity)

    p = parsed(function(r)
      r:meta()
        :task_started()
        :item_user('Run it')
        :custom_call('exec', 'await tools.one();')
        :custom_output('ok')
    end)
    eq('working', p.turn)
    no(p.pending_tool)
    no(p.activity)
  end)

  it('flags a question to the user', function()
    local p = parsed(function(r)
      r:meta()
        :task_started()
        :item_user('Plan it')
        :function_call('request_user_input', { questions = {} })
    end)
    ok(p.asking)
    ok(p.pending_tool)
  end)

  it("treats an abort as the user's move and an error as the end of the turn", function()
    local p = parsed(function(r)
      r:meta():task_started():user_message('Do the long thing')
      r:function_call('exec_command', { cmd = 'sleep 600' }):turn_aborted()
    end)
    eq('aborted', p.turn)
    no(p.pending_tool)
    eq('Do the long thing', p.last_prompt)

    p = parsed(function(r)
      r:meta():task_started():item_user('Go'):error('stream disconnected')
    end)
    eq('done', p.turn)
  end)

  it('never takes injected context for a prompt', function()
    local p = parsed(function(r)
      r:meta():task_started():context()
    end)
    eq(nil, p.first_prompt)
    eq(nil, p.last_prompt)
    eq('/work/alpha', p.cwd)

    -- With neither message record, the model input is the last resort.
    p = parsed(function(r)
      r:meta():task_started():context():raw_user('Only the raw prompt'):raw_assistant('Raw reply.')
    end)
    eq('Only the raw prompt', p.first_prompt)
    eq('Only the raw prompt', p.last_prompt)
    eq('Raw reply.', p.last_reply)
  end)

  it('reads past a large session_meta and megabytes of bookkeeping', function()
    local p = parsed(function(r)
      r:meta({ instructions = 300000 }):task_started():item_user('Summarise the repo')
      r:item_agent('Here it is.'):task_complete('Here it is.')
      for _ = 1, 4 do
        r:noise(60000)
      end
    end)
    eq('/work/alpha', p.cwd)
    eq('Summarise the repo', p.first_prompt)
    eq('done', p.turn)
    eq('Here it is.', p.last_reply)
  end)

  it('keeps what the head told it when the file grows past the tail window', function()
    local home = fx.home()
    local r = home:rollout({ cwd = '/work/alpha', branch = 'topic' })
    r:meta():task_started():item_user('The very first prompt'):item_agent('First answer.')
    r:task_complete('First answer.'):write()
    local first = provider().parse(provider().discover()[1])
    eq('The very first prompt', first.first_prompt)
    first.path = r.path

    r:task_started():item_user('Second prompt')
    for i = 1, 40 do
      r:custom_call('exec', 'await tools.read(' .. i .. ');'):custom_output(string.rep('y', 8000))
    end
    r:item_agent('Second answer.'):task_complete('Second answer.'):write()
    local entry = provider().discover()[1]
    ok(entry.size > 200000)
    local again = provider().parse(entry, first)
    eq('The very first prompt', again.first_prompt)
    eq('/work/alpha', again.cwd)
    eq('topic', again.branch)
    eq('Second answer.', again.last_reply)
    eq('done', again.turn)
    eq(first.created, again.created)
  end)

  it('picks up a rename from the index on the next parse', function()
    local home = fx.home()
    local r = home:rollout():meta():task_started():item_user('hi'):write()
    home:index(r.id, 'First')
    eq('First', provider().parse(provider().discover()[1]).title)
    home:index(r.id, 'Second')
    eq('Second', provider().parse(provider().discover()[1]).title)
  end)

  it('returns nothing for a rollout with no session and no conversation', function()
    local home = fx.home()
    home:rollout():noise():noise():write()
    local entries = provider().discover()
    eq(1, #entries)
    eq(nil, provider().parse(entries[1]))
  end)

  it('survives malformed lines', function()
    local home = fx.home()
    local r = home:rollout():meta():task_started():user_message('Still here'):agent_message('Yes.')
    table.insert(
      r.lines,
      2,
      '{"timestamp":"2026-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"user_mess'
    )
    table.insert(r.lines, 'not json at all')
    r:write()
    local p = provider().parse(provider().discover()[1])
    eq('Still here', p.first_prompt)
    eq('Yes.', p.last_reply)
    eq('working', p.turn)
  end)
end)

describe('codex messages', function()
  it('normalises an events-generation conversation', function()
    local home = fx.home()
    local r = home:rollout()
    r:meta():context():task_started():noise()
    r:user_message('Fix it')
    r:agent_reasoning('Considering the options.')
    r:agent_message('Running the tests.', 'commentary')
    r:function_call('exec_command', { cmd = 'make test' }):function_output('2 passed')
    r:custom_call(
      'apply_patch',
      '*** Begin Patch\n*** Update File: a.lua\n@@\n-x = 1\n+x = 2\n*** End Patch'
    )
    r:custom_output('Done!')
    r:function_call('shell', { command = { 'bash', '-lc', 'false' } })
    r:function_output('{"output":"boom","metadata":{"exit_code":1}}')
    r:agent_message('All done.'):task_complete('All done.')
    r:task_started():user_message('more'):turn_aborted():compacted()
    r:write()
    local msgs, cursor = provider().messages({ path = r.path })
    eq({
      'user',
      'thinking',
      'assistant',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'assistant',
      'user',
      'system',
      'system',
    }, roles(msgs))
    eq('Fix it', msgs[1].text)
    eq('exec_command', msgs[4].name)
    eq('make test', msgs[4].summary)
    eq('sh', msgs[4].lang)
    eq('2 passed', msgs[5].text)
    eq(msgs[4].id, msgs[5].id)
    eq('apply_patch', msgs[6].name)
    eq('a.lua', msgs[6].summary)
    eq('diff', msgs[6].lang)
    eq('Done!', msgs[7].text)
    eq('false', msgs[8].summary)
    eq('boom', msgs[9].text)
    ok(msgs[9].error)
    eq('Interrupted by user.', msgs[12].text)
    ok(msgs[1].time and msgs[1].time < msgs[10].time)
    eq(vim.uv.fs_stat(r.path).size, cursor.offset)
    no(cursor.items)
  end)

  it('normalises an items-generation conversation without repeating the model records', function()
    local home = fx.home()
    local r = home:rollout()
    r:meta():task_started():context():noise()
    r:item_user('Fix it')
    r:item_agent('Running the tests.', 'commentary')
    r:custom_call('exec', 'await tools.exec_command({cmd: "make test"});')
    r:item_command('make test', '2 passed'):custom_output('2 passed')
    r:item_command('false', 'boom', 1)
    r:item_file_change({
      ['/work/project/a.lua'] = { type = 'update', unified_diff = '@@ -1 +1 @@\n-x = 1\n+x = 2\n' },
      ['/work/project/b.lua'] = { type = 'add', content = 'return 1\n' },
    })
    r:item_file_change(
      { ['/work/project/c.lua'] = { type = 'delete', content = 'gone\n' } },
      'declined'
    )
    r:item_mcp('nvim-mcp', 'get_state', {}, 'state', false)
    r:item_mcp('nvim-mcp', 'send', { text = 'hi' }, 'no such buffer', true)
    r:item('Extension', {
      kind = 'web.search',
      query = 'neovim terminal',
      results = { { title = 'Terminal', url = 'https://neovim.io/t' } },
    })
    r:item('ImageView', { path = '/work/project/shot.png' })
    r:item('Reasoning', { summary_text = {}, raw_content = {} })
    r:item_agent('All done.'):task_complete('All done.')
    r:write()
    local msgs, cursor = provider().messages({ path = r.path })
    eq({
      'user',
      'assistant',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'tool',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'tool',
      'assistant',
    }, roles(msgs))
    eq('shell', msgs[3].name)
    eq('make test', msgs[3].summary)
    eq('2 passed', msgs[4].text)
    no(msgs[4].error)
    eq('boom\nexit code 1', msgs[6].text)
    ok(msgs[6].error)
    eq('apply_patch', msgs[7].name)
    eq('/work/project/a.lua, /work/project/b.lua', msgs[7].summary)
    eq('diff', msgs[7].lang)
    eq(
      '--- /work/project/a.lua\n+++ /work/project/a.lua\n@@ -1 +1 @@\n-x = 1\n+x = 2\n--- /dev/null\n+++ /work/project/b.lua\n+return 1',
      msgs[7].input
    )
    T.has(msgs[8].input, '-gone')
    eq('declined', msgs[9].text)
    ok(msgs[9].error)
    eq('nvim-mcp.get_state', msgs[10].name)
    eq('state', msgs[11].text)
    ok(msgs[13].error)
    eq('web.search', msgs[14].name)
    eq('neovim terminal', msgs[14].summary)
    T.has(msgs[15].text, 'https://neovim.io/t')
    eq('view_image', msgs[16].name)
    ok(cursor.items)
  end)

  it('reads a chat that changed generation part way', function()
    local home = fx.home()
    local r = home:rollout()
    r:meta()
      :task_started()
      :user_message('old one')
      :agent_message('old two')
      :task_complete('old two')
    r:task_started():item_user('new one'):item_agent('new two'):task_complete('new two'):write()
    local msgs = provider().messages({ path = r.path })
    eq(
      { 'old one', 'old two', 'new one', 'new two' },
      vim.tbl_map(function(m)
        return m.text
      end, msgs)
    )
  end)

  it('continues from a cursor without repeating itself', function()
    local home = fx.home()
    local r = home:rollout():meta():task_started():item_user('one'):item_agent('two'):write()
    local first, cursor = provider().messages({ path = r.path })
    eq(2, #first)
    local none, same = provider().messages({ path = r.path }, { cursor = cursor })
    eq({}, none)
    eq(cursor, same)

    r:item_user('three'):item_agent('four'):write()
    local more, cursor2 = provider().messages({ path = r.path }, { cursor = cursor })
    eq({ 'three', 'four' }, { more[1].text, more[2].text })
    ok(cursor2.offset > cursor.offset)

    -- A half-written last line is left for the next read.
    T.append(
      r.path,
      '{"timestamp":"2026-01-01T00:00:00.000Z","type":"event_msg","payload":{"type":"item_comp'
    )
    local partial, cursor3 = provider().messages({ path = r.path }, { cursor = cursor2 })
    eq({}, partial)
    eq(cursor2, cursor3)
  end)

  it('starts over when the file shrank', function()
    local home = fx.home()
    local r = home:rollout():meta():task_started():user_message('one'):agent_message('two'):write()
    local msgs = provider().messages(
      { path = r.path },
      { cursor = { offset = 10 ^ 9, items = true } }
    )
    eq(2, #msgs)
    eq({}, (provider().messages({ path = home.dir .. '/missing.jsonl' })))
  end)
end)

describe('codex commands', function()
  it('builds resume, new and headless command lines', function()
    fx.home({
      providers = {
        codex = {
          cmd = { 'codex', '--no-alt-screen' },
          headless_args = { '--skip-git-repo-check' },
        },
      },
    })
    local chat = { id = 'abc' }
    eq({ 'codex', '--no-alt-screen', 'resume', 'abc' }, provider().resume_cmd(chat))
    eq({ 'codex', '--no-alt-screen' }, provider().new_cmd({}))
    eq(
      { 'codex', '--no-alt-screen', 'do it' },
      provider().new_cmd({ id = 'ignored', prompt = 'do it' })
    )
    eq(
      { 'codex', '--no-alt-screen', 'exec', 'resume', '--skip-git-repo-check', 'abc', 'next step' },
      provider().headless_cmd(chat, 'next step')
    )
    eq(
      { 'codex', '--no-alt-screen', 'resume', 'abc', ' -v is broken' },
      provider().resume_prompt_cmd(chat, '-v is broken')
    )
    no(provider().preassign_id)
  end)

  it('reads elapsed times from ps', function()
    eq(125, provider()._parse_etime(' 02:05\n'))
    eq(3725, provider()._parse_etime('01:02:05'))
    eq(2 * 86400 + 3725, provider()._parse_etime('2-01:02:05'))
    eq(nil, provider()._parse_etime('garbage'))
  end)
end)

describe('codex live', function()
  if not require('agent-chats.util.proc').has_procfs then
    return
  end

  local fakes = {}
  local function fake(opts)
    local f = fx.fake(opts)
    fakes[#fakes + 1] = f
    return f
  end

  after_each(function()
    for _, f in ipairs(fakes) do
      f.stop()
    end
    fakes = {}
  end)

  --- A parsed chat table keyed by id, as the store hands it to `live`.
  local function chats_of(...)
    local out = {}
    for _, r in ipairs({ ... }) do
      local entry = provider().locate(r.id)
      local chat = provider().parse(entry)
      chat.id, chat.path, chat.mtime = r.id, r.path, entry.mtime
      out[r.id] = chat
    end
    return out
  end

  it('matches a process to the rollout it holds open', function()
    local home = fx.home()
    local cwd = T.tmpdir()
    local a = home:rollout({ cwd = cwd }):meta():task_started():item_user('a'):write()
    local b = home:rollout({ cwd = cwd }):meta():task_started():item_user('b'):write()
    local f = fake({ cwd = cwd, hold = a.path })
    local chats = chats_of(a, b)
    local live
    T.wait(3000, function()
      live = provider().live(chats)
      return live[a.id] ~= nil
    end)
    eq(f.pid, live[a.id].pid)
    eq(cwd, live[a.id].cwd)
    eq(nil, live[a.id].turn)
    eq(nil, live[b.id])
  end)

  it('matches `resume <id>` on the command line', function()
    local home = fx.home()
    local a = home:rollout({ cwd = '/nowhere/a' }):meta():task_started():item_user('a'):write()
    local f = fake({ args = { '--no-alt-screen', '-c', 'model="x"', 'resume', a.id } })
    eq(f.pid, provider().live(chats_of(a))[a.id].pid)
  end)

  it('matches a rollout named for the second the process started', function()
    local home = fx.home()
    local cwd = T.tmpdir()
    local now = home:rollout({ cwd = cwd, start = os.time() }):meta():write(os.time() - 100)
    local old = home:rollout({ cwd = cwd, start = os.time() - 7200 }):meta():write(os.time() - 7000)
    local f = fake({ cwd = cwd })
    local live = provider().live(chats_of(now, old))
    eq(f.pid, live[now.id].pid)
    eq(nil, live[old.id])
  end)

  it('falls back to the chat last written in its folder since it started', function()
    local home = fx.home()
    local cwd, other = T.tmpdir(), T.tmpdir()
    local stale =
      home:rollout({ cwd = cwd, start = os.time() - 7200 }):meta():write(os.time() - 7000)
    local elsewhere = home:rollout({ cwd = other, start = os.time() - 7200 }):meta():write()
    local f = fake({ cwd = cwd })
    -- Nothing in the folder was written since the process started.
    local chats = chats_of(stale, elsewhere)
    eq(nil, provider().live(chats)[stale.id])
    eq(nil, provider().live(chats)[elsewhere.id])

    local fresh = home:rollout({ cwd = cwd, start = os.time() - 3600 }):meta()
    fresh.ts = os.time() + 1
    fresh:task_started():item_user('typed after start'):write()
    local live = provider().live(chats_of(stale, elsewhere, fresh))
    eq(f.pid, live[fresh.id].pid)
    eq(nil, live[stale.id])
  end)

  it('reports a launcher and its child once, as the child', function()
    local home = fx.home()
    local a = home:rollout({ cwd = '/nowhere/a' }):meta():task_started():item_user('a'):write()
    local pidfile = T.tmpdir() .. '/pid'
    local child = T.tmpdir() .. '/codex'
    T.write(child, '#!/bin/sh\necho $$ > "$PIDFILE"\nread _\n')
    vim.uv.fs_chmod(child, 493)
    local f = fake({
      body = '"$CHILD" "$@"\n',
      args = { 'resume', a.id },
      env = { CHILD = child, PIDFILE = pidfile },
    })
    T.wait(3000, function()
      return vim.uv.fs_stat(pidfile) ~= nil
        and vim.trim(table.concat(vim.fn.readfile(pidfile))) ~= ''
    end)
    local child_pid = tonumber(vim.trim(table.concat(vim.fn.readfile(pidfile))))
    fakes[#fakes + 1] = {
      stop = function()
        pcall(vim.uv.kill, child_pid, 9)
      end,
    }
    local live
    T.wait(3000, function()
      live = provider().live(chats_of(a))
      return live[a.id] ~= nil and live[a.id].pid == child_pid
    end)
    ok(child_pid ~= f.pid)
  end)

  it('ignores codex processes that hold no conversation', function()
    local home = fx.home()
    local cwd = T.tmpdir()
    local a =
      home:rollout({ cwd = cwd, start = os.time() }):meta():task_started():item_user('a'):write()
    fake({ cwd = cwd, args = { 'app-server', '--listen', 'unix://' } })
    fake({ cwd = cwd, args = { '-c', 'x=1', 'mcp', 'list' } })
    eq(nil, provider().live(chats_of(a))[a.id])
  end)

  -- Found with Codex 0.171: it keeps `codex app-server --managed-daemon`
  -- running, sessions live in it, and their hooks run under it. A chat
  -- whose terminal had quit stayed "running outside this Neovim" for as
  -- long as the daemon lived, and could not be resumed.
  it('does not take the daemon its hooks ran under for the chat being open', function()
    local home = fx.home()
    local hk = require('helpers.hooks')
    local store = require('agent-chats.store')
    local cwd = T.tmpdir()
    local a = home
      :rollout({ cwd = cwd, start = os.time() - 120 })
      :meta()
      :task_started()
      :item_user('a')
      :write()
    local daemon = fake({ args = { 'app-server', '--listen', 'unix://', '--managed-daemon' } })
    -- (Reported after the daemon was born: an older report would be taken
    -- for one about a process that has since given its number away.)
    hk.event('codex', a.id, 'SessionStart', { src = 'startup', pid = daemon.pid })
    hk.event('codex', a.id, 'UserPromptSubmit', { pid = daemon.pid })
    hk.event('codex', a.id, 'Stop', { pid = daemon.pid })
    store.refresh_sync()
    store.refresh_sync({ full = false })
    local c = store.get('codex:' .. a.id)
    ok(c, 'the chat is listed')
    ok(c.live ~= true, 'nothing has it open: the daemon is not the chat')
    eq(nil, c.pid)
    -- A terminal that has it open is still seen: a chat process, named by
    -- `resume <id>`.
    local tui = fake({ cwd = cwd, args = { 'resume', a.id } })
    T.wait(3000, function()
      store.refresh_sync()
      local now = store.get('codex:' .. a.id)
      return now.live == true and now.pid == tui.pid
    end)
    tui.stop()
    T.wait(3000, function()
      store.refresh_sync()
      return store.get('codex:' .. a.id).live ~= true
    end)
    daemon.stop()
  end)
end)
