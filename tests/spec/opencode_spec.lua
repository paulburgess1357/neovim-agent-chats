local T = require('helpers.harness')
local eq, ok, no, has = T.eq, T.ok, T.no, T.has

local function provider()
  return require('agent-chats.providers.opencode')
end

describe('opencode commands', function()
  it('builds resume, new, fork and headless command lines', function()
    require('agent-chats.config').setup({
      providers = {
        opencode = { cmd = { 'opencode', '--pure' }, headless_args = { '--agent', 'build' } },
      },
      watch = { enabled = false },
    })
    local chat = { id = 'ses_1' }
    eq({ 'opencode', '--pure', '-s', 'ses_1' }, provider().resume_cmd(chat))
    eq({ 'opencode', '--pure' }, provider().new_cmd({}))
    eq(
      { 'opencode', '--pure', '--prompt', 'do it' },
      provider().new_cmd({ id = 'x', prompt = 'do it' })
    )
    eq({ 'opencode', '--pure', '-s', 'ses_1', '--fork' }, provider().fork_cmd(chat))
    eq(
      { 'opencode', '--pure', 'run', '-s', 'ses_1', '--agent', 'build', 'next step' },
      provider().headless_cmd(chat, 'next step')
    )
    eq(
      { 'opencode', '--pure', '-s', 'ses_1', '--prompt', ' -v is broken' },
      provider().resume_prompt_cmd(chat, '-v is broken')
    )
  end)

  it('copes with a missing database', function()
    require('agent-chats.config').setup({
      providers = { opencode = { home = T.tmpdir() .. '/nothing/opencode' } },
      watch = { enabled = false },
    })
    provider()._query = nil
    provider()._reset()
    no(provider().available())
    eq({}, provider().discover())
    -- Not an empty conversation: one that could not be read.
    local read, why = pcall(provider().messages, { id = 'ses_x' })
    no(read)
    has(tostring(why), 'could not be read')
    eq(nil, provider().grep('anything'))
    local p = provider().parse({
      id = 'ses_x',
      mtime = 5,
      size = 0,
      data = { directory = '/work/a', title = 'T' },
    })
    eq('unknown', p.turn)
    eq('/work/a', p.cwd)
  end)
end)

if not require('agent-chats.util.sqlite').available() then
  io.stdout:write('  note  opencode: SQLite library not found; database-backed tests skipped\n')
  return
end

local fx = require('helpers.opencode')
local jobs = {}

local function spawn(...)
  local job = fx.spawn(...)
  jobs[#jobs + 1] = job
  return job
end

local function by_id(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[e.id] = e
  end
  return out
end

--- Discover and parse one session.
local function parsed(s, prev)
  local e = by_id(provider().discover())[s.id]
  ok(e, 'session not discovered')
  return provider().parse(e, prev), e
end

describe('opencode discover', function()
  it('lists one entry per session, leaving out archived ones', function()
    local home = fx.home()
    local a = home:session({ directory = '/work/alpha', title = 'Alpha' }):user('one'):reply('two')
    local b = home:session({ directory = '/work/beta' })
    home:session():user('gone'):archive()
    ok(provider().available())
    local entries = provider().discover()
    eq(2, #entries)
    local e = by_id(entries)
    eq(a.ts / 1000, e[a.id].mtime)
    eq(2, e[a.id].size)
    eq('/work/alpha', e[a.id].data.directory)
    eq('Alpha', e[a.id].data.title)
    eq(nil, e[a.id].path)
    eq(b.ts / 1000, e[b.id].mtime)
    eq(0, e[b.id].size)
  end)

  it('changes mtime and size when a part is added to an old session', function()
    local home = fx.home()
    local s = home:session({ start = os.time() - 30 * 86400 }):user('one'):reply('two')
    local other = home:session({ start = os.time() - 30 * 86400 }):user('x'):reply('y')
    local before = by_id(provider().discover())
    s:assistant():text('more')
    local after = by_id(provider().discover())
    ok(after[s.id].mtime > before[s.id].mtime)
    eq(before[s.id].size + 1, after[s.id].size)
    eq(before[other.id].mtime, after[other.id].mtime)
  end)

  it('notices a part rewritten in place while a turn is running', function()
    local home = fx.home()
    local s = home:session({ start = os.time() - 30 * 86400 }):user('go'):assistant():text('par')
    local p, e = parsed(s)
    eq('working', p.turn)
    s:rewrite({ type = 'text', text = 'partial answer' })
    local again = by_id(provider().discover())[s.id]
    ok(again.mtime > e.mtime)
    eq(e.size, again.size)
    eq('partial answer', provider().parse(again).last_reply)
  end)

  it('asks nothing of an untouched database', function()
    local home = fx.home()
    home:session():user('one'):reply('two')
    local first = provider().discover()
    local calls = 0
    provider()._query = function()
      calls = calls + 1
      return nil, 'should not be called'
    end
    eq(first, provider().discover())
    eq(0, calls)
    provider()._query = nil
  end)

  it('reads while a writer holds the database open', function()
    local home = fx.home()
    local s = home:session():user('one')
    local writer = assert(require('agent-chats.util.sqlite').open(home.db, { write = true }))
    assert(writer:exec("update session set title = 'Renamed' where id = '" .. s.id .. "'"))
    local e = by_id(provider().discover())[s.id]
    eq('Renamed', e.data.title)
    eq('one', provider().parse(e).first_prompt)
    writer:close()
  end)
end)

describe('opencode parse', function()
  it('reads title, prompts, reply, folder and model', function()
    local home = fx.home()
    local s = home:session({ directory = '/work/alpha', title = 'Fix the test' })
    s:user('Fix the flaky test'):assistant():reasoning('hm'):text('Looking.'):finish('tool-calls')
    s:assistant():text('Fixed it.'):finish('stop')
    s:user('Now the docs'):reply('Docs updated.')
    local p, e = parsed(s)
    eq('Fix the test', p.title)
    eq('Fix the flaky test', p.first_prompt)
    eq('Now the docs', p.last_prompt)
    eq('Docs updated.', p.last_reply)
    eq('/work/alpha', p.cwd)
    eq('model-1', p.model)
    eq('done', p.turn)
    eq(s.ts / 1000, p.turn_at)
    eq(e.mtime, p.updated)
    ok(p.created < p.updated)
    eq(nil, p.parent_id)
    no(p.pending_tool)
  end)

  it('has no title for a chat opencode has not named yet', function()
    local home = fx.home()
    local s = home:session({ title = 'New session - 2026-06-13T02:18:19.724Z' }):user('hi')
    eq(nil, parsed(s).title)
  end)

  it('links a subagent session to its parent', function()
    local home = fx.home()
    local parent = home:session():user('explore')
    local child = home:session({ parent = parent.id }):user('find files')
    eq(parent.id, parsed(child).parent_id)
  end)

  it('is working until the newest assistant message finishes with a final reason', function()
    local home = fx.home()
    local s = home:session():user('Run the build')
    eq('working', parsed(s).turn)
    s:assistant():text('On it.')
    eq('working', parsed(s).turn)
    s:finish('tool-calls')
    local p = parsed(s)
    eq('working', p.turn)
    no(p.pending_tool)
    s:assistant():text('Built.'):finish('stop')
    eq('done', parsed(s).turn)
    eq('unknown', parsed(home:session()).turn)
  end)

  it('reports an outstanding tool call', function()
    local home = fx.home()
    local s = home:session():user('Run it'):assistant()
    s:tool(
      'bash',
      { status = 'running', input = { command = 'make -j8 all' }, time = { start = 1 } }
    )
    local p = parsed(s)
    eq('working', p.turn)
    ok(p.pending_tool)
    eq('bash: make -j8 all', p.activity)
    no(p.asking)

    s:rewrite({
      type = 'tool',
      tool = 'bash',
      callID = 'c',
      state = { status = 'running', input = { command = 'make' }, title = 'Build everything' },
    })
    eq('bash: Build everything', parsed(s).activity)

    s:rewrite({
      type = 'tool',
      tool = 'bash',
      callID = 'c',
      state = { status = 'completed', input = { command = 'make' }, output = 'ok', title = 'Build' },
    })
    p = parsed(s)
    no(p.pending_tool)
    no(p.activity)

    s:tool('question', { status = 'pending', input = {} })
    ok(parsed(s).asking)
  end)

  it("treats an abort as the user's move and another error as a finished turn", function()
    local home = fx.home()
    local s = home:session():user('Long thing'):assistant()
    s:finish(nil, { error = { name = 'MessageAbortedError', data = { message = 'Aborted' } } })
    local p = parsed(s)
    eq('aborted', p.turn)
    eq('Long thing', p.last_prompt)
    eq(s.ts / 1000, p.turn_at)

    local t = home:session():user('Other'):assistant()
    t:finish(nil, { error = { name = 'APIError', data = { message = 'overloaded' } } })
    eq('done', parsed(t).turn)
  end)

  it('finds the prompts of a long turn beyond the message window', function()
    local home = fx.home()
    local s = home:session():user('The very first prompt'):reply('ok'):user('The latest prompt')
    for i = 1, 12 do
      s:assistant():text('step ' .. i):finish('tool-calls')
    end
    local p = parsed(s)
    eq('The very first prompt', p.first_prompt)
    eq('The latest prompt', p.last_prompt)
    eq('step 12', p.last_reply)
    eq('working', p.turn)

    -- A re-parse carries the first prompt over instead of looking it up.
    local e = by_id(provider().discover())[s.id]
    local statements = {}
    local db = assert(require('agent-chats.util.sqlite').open(home.db))
    provider()._query = function(sql, params)
      statements[#statements + 1] = sql
      return db:query(sql, params)
    end
    local again = provider().parse(e, vim.tbl_extend('force', p, { id = s.id }))
    provider()._query = nil
    db:close()
    eq('The very first prompt', again.first_prompt)
    eq('The latest prompt', again.last_prompt)
    eq(4, #statements)
  end)

  it('does not take harness-added text for a prompt', function()
    local home = fx.home()
    local s = home:session():user('Real prompt')
    s:part({ type = 'text', text = 'Called the Read tool with...', synthetic = true })
    s:reply('Done.')
    s:user('injected', { synthetic = true })
    local p = parsed(s)
    eq('Real prompt', p.first_prompt)
    eq('Real prompt', p.last_prompt)
  end)
end)

describe('opencode messages', function()
  it('normalises a conversation', function()
    local home = fx.home()
    local s =
      home:session():user('Fix it'):assistant():reasoning('Considering.'):text('Running tests.')
    s:tool('bash', {
      status = 'completed',
      input = { command = 'make test' },
      output = '2 passed',
      title = 'Run tests',
    })
    s:tool('edit', {
      status = 'error',
      input = { filePath = '/work/a.lua', oldString = 'x = 1', newString = 'x = 2' },
      error = 'no match',
    })
    s:tool('read', { status = 'running', input = { filePath = '/work/b.lua' } })
    s:part({ type = 'step-finish', reason = 'tool-calls' })
    s:finish('tool-calls')
    s:assistant():text('All done.'):finish('stop')
    s:user('again')
      :assistant()
      :finish(nil, { error = { name = 'MessageAbortedError', data = { message = 'Aborted' } } })
    local msgs, cursor = provider().messages({ id = s.id })
    eq(nil, cursor)
    local roles = vim.tbl_map(function(m)
      return m.role
    end, msgs)
    eq({
      'user',
      'thinking',
      'assistant',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'tool',
      'assistant',
      'user',
      'system',
    }, roles)
    eq('Fix it', msgs[1].text)
    eq('bash', msgs[4].name)
    eq('Run tests', msgs[4].summary)
    eq('make test', msgs[4].input)
    eq('sh', msgs[4].lang)
    eq('2 passed', msgs[5].text)
    eq(msgs[4].id, msgs[5].id)
    eq('diff', msgs[6].lang)
    eq('-x = 1\n+x = 2', msgs[6].input)
    ok(msgs[7].error)
    eq('no match', msgs[7].text)
    eq('/work/b.lua', msgs[8].summary)
    eq('Interrupted by user.', msgs[11].text)
    ok(msgs[1].time and msgs[1].time < msgs[9].time)
    eq({}, (provider().messages({ id = 'ses_unknown' })))
  end)
end)

describe('opencode grep', function()
  it('finds sessions by text and tool output, taking wildcards literally', function()
    local home = fx.home()
    local a = home:session():user('Deploy at 50%_done please'):reply('He said "stop" now')
    local b = home:session():user('Something else'):assistant()
    b:tool(
      'bash',
      { status = 'completed', input = { command = 'ls' }, output = 'needle.txt\nC:\\temp' }
    )
    local c = home:session():user('5000 done')
    eq({ [a.id] = true }, provider().grep('50%_done'))
    eq({ [a.id] = true }, provider().grep('deploy AT'))
    eq({ [a.id] = true }, provider().grep('said "stop"'))
    eq({ [b.id] = true }, provider().grep('needle.txt'))
    eq({ [b.id] = true }, provider().grep('C:\\temp'))
    eq({ [a.id] = true, [c.id] = true }, provider().grep('done'))
    eq({}, provider().grep('no such text anywhere'))
    eq(nil, provider().grep(''))
  end)
end)

describe('opencode cli fallback', function()
  it('gives the same answers through `opencode db`', function()
    local home = fx.home()
    local s =
      home:session({ directory = "/work/it's", title = "Quote's" }):user('First 100%'):assistant()
    s:tool('bash', { status = 'running', input = { command = 'make' } })
    local direct_entries = by_id(provider().discover())
    local direct = provider().parse(direct_entries[s.id])
    local direct_msgs = provider().messages({ id = s.id })

    local exe, log = home:fake_cli()
    require('agent-chats.config').get().providers.opencode.cmd = { exe, '--ignored-flag' }
    provider()._reset()
    provider()._query = provider()._cli_query
    local e = by_id(provider().discover())[s.id]
    eq(direct_entries[s.id], e)
    eq(direct, provider().parse(e))
    eq(direct_msgs, (provider().messages({ id = s.id })))
    eq({ [s.id] = true }, provider().grep('100%'))
    eq({}, provider().grep("it's not there"))

    local first = vim.json.decode(vim.fn.readfile(log)[1])
    eq('db', first.argv[1])
    eq({ '--format', 'json' }, { first.argv[3], first.argv[4] })
    eq(vim.fs.dirname(home.dir), first.xdg)

    local rows, err = provider()._cli_query('select nope from nowhere')
    eq(nil, rows)
    ok(err and err ~= '')
    provider()._query = nil
  end)

  it('routes every statement through a replaced query function', function()
    local home = fx.home()
    local s = home:session():user('hello')
    provider()._query = function()
      return nil, 'down'
    end
    eq({}, provider().discover())
    local read, why = pcall(provider().messages, { id = s.id })
    no(read)
    has(tostring(why), 'could not be read')
    eq(nil, provider().grep('hello'))
    eq('unknown', provider().parse({ id = s.id, mtime = 1, size = 1, data = {} }).turn)
    provider()._query = nil
    eq(1, #provider().discover())
  end)
end)

describe('opencode live', function()
  after_each(function()
    for _, job in ipairs(jobs) do
      fx.kill(job)
    end
    jobs = {}
  end)

  if not require('agent-chats.util.proc').has_procfs then
    io.stdout:write('  note  opencode: no /proc; process-mapping tests skipped\n')
    return
  end

  local function chat(id, cwd, updated, extra)
    return vim.tbl_extend(
      'force',
      { id = id, cwd = cwd, updated = updated, turn = 'done' },
      extra or {}
    )
  end

  it('maps a process to the session named on its command line', function()
    fx.home()
    local dir = T.tmpdir()
    local job = spawn(dir, { '--model', 'x/y', '-s', 'ses_named' })
    local forked = spawn(dir, { '--session=ses_forked', '--fork' })
    local server = spawn(dir, { 'serve', '-s', 'ses_served' })
    T.wait(2000, function()
      return provider().live({}).ses_named ~= nil
    end)
    local live = provider().live({ ses_other = chat('ses_other', '/elsewhere', os.time()) })
    eq(job.pid, live.ses_named.pid)
    eq(dir, live.ses_named.cwd)
    eq(nil, live.ses_named.turn)
    eq(nil, live.ses_forked)
    eq(nil, live.ses_served)
    eq(nil, live.ses_other)
    ok(forked.pid and server.pid)
  end)

  it('falls back to the most recent session in the process folder', function()
    fx.home()
    local dir = T.tmpdir()
    local now = os.time()
    local chats = {
      ses_old = chat('ses_old', dir, now - 5000),
      ses_new = chat('ses_new', dir, now + 2),
      ses_sub = chat('ses_sub', dir, now + 5, { parent_id = 'ses_new', turn = 'working' }),
      ses_subdone = chat('ses_subdone', dir, now + 6, { parent_id = 'ses_new' }),
      ses_away = chat('ses_away', '/elsewhere', now + 9),
    }
    eq(nil, provider().live(chats).ses_new)
    local job = spawn(dir, {})
    T.wait(2000, function()
      return provider().live(chats).ses_new ~= nil
    end)
    local live = provider().live(chats)
    eq(job.pid, live.ses_new.pid)
    eq(job.pid, live.ses_sub.pid)
    eq(nil, live.ses_subdone)
    eq(nil, live.ses_old)
    eq(nil, live.ses_away)

    -- A chat untouched since before the process began is not its chat...
    eq(nil, provider().live({ ses_old = chats.ses_old }).ses_old)
    -- ...unless the process was told to continue the last one.
    local dir2 = T.tmpdir()
    spawn(dir2, { '--continue' })
    local stale = { ses_stale = chat('ses_stale', dir2, now - 5000) }
    T.wait(2000, function()
      return provider().live(stale).ses_stale ~= nil
    end)
  end)

  it('never reports a session twice', function()
    fx.home()
    local dir = T.tmpdir()
    local now = os.time()
    local chats = { ses_a = chat('ses_a', dir, now + 3), ses_b = chat('ses_b', dir, now + 2) }
    local one = spawn(dir, {})
    local two = spawn(dir, {})
    -- A launcher whose child is also called opencode is one chat, not two.
    local dir3 = T.tmpdir()
    local extra, inner = fx.spawn(T.tmpdir(), { 'serve' })
    jobs[#jobs + 1] = extra
    local wrapper = spawn(dir3, { '-s', 'ses_wrapped' }, inner)
    T.wait(3000, function()
      local l = provider().live(chats)
      return l.ses_a ~= nil and l.ses_b ~= nil and l.ses_wrapped ~= nil
    end)
    local live = provider().live(chats)
    local pids = { [live.ses_a.pid] = true, [live.ses_b.pid] = true }
    ok(pids[one.pid] and pids[two.pid])
    eq(wrapper.pid, live.ses_wrapped.pid)
  end)
end)
