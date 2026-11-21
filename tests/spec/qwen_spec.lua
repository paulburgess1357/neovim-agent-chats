local T = require('helpers.harness')
local fx = require('helpers.qwen')
local eq, ok, no = T.eq, T.ok, T.no

local function provider()
  return require('agent-chats.providers.qwen')
end

local has_procfs = require('agent-chats.util.proc').has_procfs

--- Discover + parse the single chat written by `build`.
local function parsed(build, opts)
  local home = fx.home()
  local chat = home:chat(opts or { cwd = '/work/alpha', branch = 'feature' })
  build(chat)
  chat:write()
  local entries = provider().discover()
  eq(1, #entries)
  return provider().parse(entries[1]), entries[1], chat, home
end

local function dead_pid()
  local job = vim.system({ 'true' })
  local pid = job.pid
  job:wait()
  return pid
end

describe('qwen discover', function()
  it('lists chat transcripts and nothing else', function()
    local home = fx.home()
    local a = home:chat({ cwd = '/work/alpha' }):turn('one', 'two'):write()
    local b = home:chat({ cwd = '/work/beta' }):user('three'):write()
    a:runtime(1)
    T.write(home.dir .. '/projects/-work-alpha/chats/notes.txt', 'not a chat')
    T.write(home.dir .. '/projects/-work-alpha/meta.json', '{}')
    T.write(home.dir .. '/projects/-work-alpha/chats/' .. fx.uuid() .. '.jsonl', '')
    local entries = provider().discover()
    table.sort(entries, function(x, y)
      return x.id < y.id
    end)
    eq(2, #entries)
    eq({ a.id, b.id }, { entries[1].id, entries[2].id })
    eq(a.path, entries[1].path)
    ok(entries[1].size > 0 and entries[1].mtime > 0)
  end)

  it('copes with a home that has no chats', function()
    fx.home()
    eq({}, provider().discover())
    ok(provider().available())
  end)

  it('follows QWEN_HOME and QWEN_RUNTIME_DIR when no home is set', function()
    local home = fx.home()
    local chat = home:chat({ cwd = '/work/alpha' }):turn('one', 'two'):write()
    local other = T.tmpdir()
    local old_home, old_rt = vim.env.QWEN_HOME, vim.env.QWEN_RUNTIME_DIR
    require('agent-chats.config').setup({ providers = { qwen = { home = false } } })
    vim.env.QWEN_HOME, vim.env.QWEN_RUNTIME_DIR = other, home.dir
    local got_home, entries = provider().home(), provider().discover()
    vim.env.QWEN_RUNTIME_DIR = nil
    local without = provider().discover()
    vim.env.QWEN_HOME, vim.env.QWEN_RUNTIME_DIR = old_home, old_rt
    eq(vim.fs.normalize(other), got_home)
    eq(chat.id, entries[1] and entries[1].id)
    eq({}, without)
  end)
end)

describe('qwen parse', function()
  it('reads title, prompts, reply, folder, branch and model', function()
    local p, _, chat = parsed(function(c)
      c:slash('/mcp')
      c:turn('Fix the flaky test', 'Fixed: the fixture leaked.')
      c:title('Fix flaky test')
      c:turn('Now update the docs', 'Docs updated.')
    end)
    eq('Fix flaky test', p.title)
    eq('Fix the flaky test', p.first_prompt)
    eq('Now update the docs', p.last_prompt)
    eq('Docs updated.', p.last_reply)
    eq('/work/alpha', p.cwd)
    eq('feature', p.branch)
    eq('qwen-test-1', p.model)
    eq('done', p.turn)
    no(p.pending_tool)
    ok(p.created < p.updated)
    ok(p.updated <= chat.ts)
    eq(p.updated, p.turn_at)
  end)

  it('has no title until Qwen records one', function()
    local p = parsed(function(c)
      c:turn('hello', 'hi')
    end)
    eq(nil, p.title)
    eq('hello', p.first_prompt)
  end)

  it('is working after a prompt, during a request and while a call is outstanding', function()
    local p = parsed(function(c)
      c:user('Run the build')
    end)
    eq('working', p.turn)
    no(p.pending_tool)

    p = parsed(function(c)
      c:turn('first', 'answer'):user('Run the build'):snapshots():request_start()
    end)
    eq('working', p.turn)

    p = parsed(function(c)
      c:user('Run the build'):request():tool_call('run_shell_command', { command = 'make -j8 all' })
    end)
    eq('working', p.turn)
    ok(p.pending_tool)
    eq('run_shell_command: make -j8 all', p.activity)
    no(p.asking)

    p = parsed(function(c)
      c:user('Run the build')
        :request()
        :tool_call('run_shell_command', { command = 'make' })
        :tool_result('ok')
    end)
    eq('working', p.turn)
    no(p.pending_tool)
    no(p.activity)

    p = parsed(function(c)
      c:user('Run it')
        :request()
        :tool_call('run_shell_command', { command = 'make' })
        :tool_result('ok')
      c:request():assistant('Built.')
    end)
    eq('done', p.turn)
    eq('Built.', p.last_reply)
  end)

  it('names the tool behind the tool_call wrapper', function()
    local p = parsed(function(c)
      c:user('Look')
        :tool_call('tool_call', { name = 'grep_search', arguments = { pattern = 'TODO' } })
    end)
    eq('grep_search: TODO', p.activity)
  end)

  it('tracks parallel calls until the last result is in', function()
    local p = parsed(function(c)
      c:user('Read both')
      c:tool_call('read_file', { absolute_path = '/work/alpha/a.lua' })
      local first = c.call_id
      c:tool_call('read_file', { absolute_path = '/work/alpha/b.lua' })
      c:tool_result('contents of a', { id = first })
    end)
    ok(p.pending_tool)
    eq('read_file: /work/alpha/b.lua', p.activity)
  end)

  it('settles calls that carry no ids', function()
    local p = parsed(function(c)
      c:user('Go'):tool_call('glob', { pattern = '*.lua' }, { no_id = true })
    end)
    ok(p.pending_tool)
    p = parsed(function(c)
      c:user('Go')
        :tool_call('glob', { pattern = '*.lua' }, { no_id = true })
        :tool_result('a.lua', { no_id = true })
    end)
    no(p.pending_tool)
  end)

  it('flags a question to the user', function()
    local p = parsed(function(c)
      c:user('Plan it'):tool_call('ask_user_question', { questions = {} })
    end)
    ok(p.asking)
    ok(p.pending_tool)
  end)

  it("treats a cancelled request as the user's move", function()
    local p = parsed(function(c)
      c:user('Do the long thing'):tool_call('run_shell_command', { command = 'sleep 600' })
      c:request_start():request_end('cancelled')
    end)
    eq('aborted', p.turn)
    no(p.pending_tool)
    eq('Do the long thing', p.last_prompt)

    p = parsed(function(c)
      c:user('Do it'):request_start():turn_result('cancelled')
    end)
    eq('aborted', p.turn)
  end)

  it('ends the turn on a failed request and on a settled turn', function()
    local p = parsed(function(c)
      c:user('Do it'):request_start():request_end('error')
    end)
    eq('done', p.turn)
    p = parsed(function(c)
      c:user('Do it'):request():assistant('ok'):turn_result('completed')
    end)
    eq('done', p.turn)
  end)

  it('ignores the requests of background subagents', function()
    local p = parsed(function(c)
      c:user('hi'):request():assistant('hello')
      c:request_start({ subagent = 'managed-auto-memory-extractor-ab12' })
    end)
    eq('done', p.turn)
    eq(p.updated, p.turn_at)
  end)

  it('counts mid-turn messages but not other speakers as prompts', function()
    local p = parsed(function(c)
      c:user('Start'):request():tool_call('run_shell_command', { command = 'make' })
      c:user('also run the tests', { mid = true })
    end)
    eq('also run the tests', p.last_prompt)
    eq('working', p.turn)
    ok(p.pending_tool)

    p = parsed(function(c)
      c:user('injected goal', { provenance = 'goal_runtime' })
      c:user('Real prompt'):request():assistant('Done.')
      c:user('scheduler tick', { provenance = 'system' })
    end)
    eq('Real prompt', p.first_prompt)
    eq('Real prompt', p.last_prompt)
    eq('working', p.turn)
  end)

  it('prefers the text the client displayed', function()
    local p = parsed(function(c)
      c:user('fix @a.lua\n--- Content from referenced files ---\nlots', { display = 'fix @a.lua' })
    end)
    eq('fix @a.lua', p.first_prompt)
  end)

  it('does not mistake slash commands for prompts or turns', function()
    local p = parsed(function(c)
      c:turn('First real prompt', 'Answer.'):slash('/model')
    end)
    eq('done', p.turn)
    eq('First real prompt', p.last_prompt)
  end)

  it('reads the parent session and the source', function()
    local p = parsed(function(c)
      c:source('side_task'):parent('parent-id'):turn('hi', 'hello')
    end)
    eq('parent-id', p.parent_id)
    eq('side_task', p.origin)
  end)

  it('finds the turn behind megabytes of telemetry', function()
    local p = parsed(function(c)
      c:turn('Summarise the repo', 'Here it is.'):title('Repo summary')
      for _ = 1, 4 do
        c:noise(60000)
      end
    end)
    eq('done', p.turn)
    eq('Here it is.', p.last_reply)
    eq('Repo summary', p.title)
  end)

  it('keeps what the head told it when the file grows past the tail window', function()
    local home = fx.home()
    local chat = home:chat({ cwd = '/work/alpha' })
    chat:turn('The very first prompt', 'First answer.'):title('Kept title'):write()
    local first = provider().parse(provider().discover()[1])
    eq('The very first prompt', first.first_prompt)
    first.path = chat.path

    chat:user('more')
    for i = 1, 40 do
      chat
        :tool_call('read_file', { absolute_path = '/work/alpha/f' .. i })
        :tool_result(string.rep('y', 8000))
    end
    chat:request():assistant('Second answer.'):write()
    local entry = provider().discover()[1]
    ok(entry.size > 200000)
    local again = provider().parse(entry, first)
    eq('The very first prompt', again.first_prompt)
    eq('/work/alpha', again.cwd)
    eq('Kept title', again.title)
    eq('Second answer.', again.last_reply)
    eq('done', again.turn)
  end)

  it('returns nothing for a file with no conversation', function()
    local home = fx.home()
    home:chat():slash('/mcp'):noise():write()
    local entries = provider().discover()
    eq(1, #entries)
    eq(nil, provider().parse(entries[1]))
  end)

  it('survives malformed lines', function()
    local home = fx.home()
    local chat = home:chat():user('Still here'):request():assistant('Yes.')
    table.insert(chat.lines, 2, '{"uuid":"x","type":"user","message":{"parts":')
    table.insert(chat.lines, 'not json at all')
    chat:write()
    local p = provider().parse(provider().discover()[1])
    eq('Still here', p.first_prompt)
    eq('Yes.', p.last_reply)
  end)
end)

describe('qwen live', function()
  it('reports running sessions without a turn state', function()
    local home = fx.home()
    local pid = vim.uv.os_getpid()
    local rec = home:registry(pid, { cwd = '/work/alpha', procStart = fx.proc_token(pid) })
    local all = provider().live()
    local live = all[rec.sessionId]
    eq(pid, live.pid)
    eq('/work/alpha', live.cwd)
    eq('tui', live.kind)
    eq(rec.name, live.name)
    no(live.name_explicit)
    eq(nil, live.turn)
    ok(math.abs(live.started - (os.time() - 60)) < 5)
    T.hasnt(vim.inspect(all), 'secret-ipc-token')
  end)

  it('tells a name the user chose from a derived one', function()
    local home = fx.home()
    local rec = home:registry(vim.uv.os_getpid(), { name = 'release prep' })
    ok(provider().live()[rec.sessionId].name_explicit)
  end)

  it('reads the per-slot record of a process with several sessions', function()
    local home = fx.home()
    local rec = home:registry(vim.uv.os_getpid(), {}, 'ab12cd34')
    ok(provider().live()[rec.sessionId])
  end)

  it('ignores records of processes that are gone', function()
    local home = fx.home()
    home:registry(dead_pid())
    T.write(home.dir .. '/sessions/garbage.json', '{')
    T.write(home.dir .. '/sessions/' .. vim.uv.os_getpid() .. '.json', '{ not json')
    eq({}, provider().live())
  end)

  it('ignores a record from another boot or an earlier process with the same pid', function()
    if not has_procfs then
      return
    end
    local home = fx.home()
    local pid = vim.uv.os_getpid()
    local _, boot, ticks = fx.proc_token(pid)
    home:registry(pid, { procStart = ('00000000-1111-2222-3333-444444444444:%d'):format(ticks) })
    eq({}, provider().live())
    home:registry(pid, { procStart = ('%s:%d'):format(boot, ticks + 1) })
    eq({}, provider().live())
    local rec = home:registry(pid, { procStart = ('%s:%d'):format(boot, ticks) })
    ok(provider().live()[rec.sessionId])
  end)

  it('falls back to the runtime file next to a chat', function()
    local home = fx.home()
    local pid = vim.uv.os_getpid()
    local a = home:chat({ cwd = '/work/alpha' }):turn('one', 'two'):write()
    local b = home:chat({ cwd = '/work/beta' }):turn('one', 'two'):write()
    local c = home:chat({ cwd = '/work/gamma' }):turn('one', 'two'):write()
    a:runtime(pid)
    b:runtime(dead_pid())
    c:runtime(pid, { session_id = 'someone-else' })
    local chats = { [a.id] = a:as_chat(), [b.id] = b:as_chat(), [c.id] = c:as_chat() }
    local live = provider().live(chats)
    eq({ a.id }, vim.tbl_keys(live))
    eq(pid, live[a.id].pid)
    eq('/work/alpha', live[a.id].cwd)
    eq(nil, live[a.id].turn)

    -- The registry record wins where there is one.
    home:registry(pid, { sessionId = a.id, cwd = '/work/alpha', name = 'named' })
    eq('named', provider().live(chats)[a.id].name)
  end)

  it('rejects a runtime file whose pid went to a younger process', function()
    if not has_procfs then
      return
    end
    local home = fx.home()
    local a = home:chat():turn('one', 'two'):write()
    a:runtime(vim.uv.os_getpid(), { started_at = os.time() - 86400 * 400 })
    eq({}, provider().live({ [a.id] = a:as_chat() }))
  end)

  it('locates the transcript of a running session', function()
    local home = fx.home()
    local chat = home:chat({ cwd = '/work/my.proj' }):user('hi'):write()
    eq(chat.path, provider().locate(chat.id, { cwd = '/work/my.proj' }).path)
    eq(nil, provider().locate(fx.uuid(), { cwd = '/work/my.proj' }))
    eq(nil, provider().locate(chat.id, {}))
  end)
end)

describe('qwen messages', function()
  it('normalises a conversation', function()
    local home = fx.home()
    local chat = home:chat()
    chat:slash('/mcp')
    chat:slash('/hidden', { hiddenInvocation = true })
    chat:user('Fix it'):snapshots():request()
    chat:tool_call(
      'run_shell_command',
      { command = 'make test' },
      { thought = 'Considering.', text = 'Running the tests.' }
    )
    chat:tool_result('2 passed')
    chat:tool_call(
      'edit',
      { file_path = '/work/project/a.lua', old_string = 'x = 1', new_string = 'x = 2' }
    )
    chat:tool_result('edit failed', { error = true })
    chat:compression(5000)
    chat:request():assistant('All done.', { thought = 'Wrapping up.' })
    chat:request('success', { subagent = 'managed-auto-memory-extractor-ab12' })
    chat:user('tick', { provenance = 'system' })
    chat:request_start():request_end('cancelled')
    chat:write()
    local msgs, cursor = provider().messages({ path = chat.path })
    local roles = vim.tbl_map(function(m)
      return m.role
    end, msgs)
    eq({
      'user',
      'user',
      'thinking',
      'assistant',
      'tool',
      'tool_result',
      'tool',
      'tool_result',
      'system',
      'thinking',
      'assistant',
      'system',
      'system',
    }, roles)
    eq('/mcp', msgs[1].text)
    eq('Fix it', msgs[2].text)
    eq('Running the tests.', msgs[4].text)
    eq('run_shell_command', msgs[5].name)
    eq('make test', msgs[5].summary)
    eq('sh', msgs[5].lang)
    eq('2 passed', msgs[6].text)
    eq(msgs[5].id, msgs[6].id)
    no(msgs[6].error)
    eq('diff', msgs[7].lang)
    eq('-x = 1\n+x = 2', msgs[7].input)
    ok(msgs[8].error)
    eq('edit failed', msgs[8].text)
    T.has(msgs[9].text, 'compressed')
    ok(msgs[9].time)
    eq('All done.', msgs[11].text)
    eq('tick', msgs[12].text)
    eq('Interrupted by user.', msgs[13].text)
    ok(msgs[2].time and msgs[2].time < msgs[11].time)
    eq(vim.uv.fs_stat(chat.path).size, cursor)
  end)

  it('continues from a cursor without repeating itself', function()
    local home = fx.home()
    local chat = home:chat():user('one'):assistant('two'):write()
    local first, cursor = provider().messages({ path = chat.path })
    eq(2, #first)
    local none, same = provider().messages({ path = chat.path }, { cursor = cursor })
    eq({}, none)
    eq(cursor, same)

    chat:user('three'):assistant('four'):write()
    local more, cursor2 = provider().messages({ path = chat.path }, { cursor = cursor })
    eq({ 'three', 'four' }, { more[1].text, more[2].text })
    ok(cursor2 > cursor)

    T.append(chat.path, '{"uuid":"x","type":"user","message":{"parts":[{"text":"par')
    local partial, cursor3 = provider().messages({ path = chat.path }, { cursor = cursor2 })
    eq({}, partial)
    eq(cursor2, cursor3)
  end)

  it('starts over when the file shrank', function()
    local home = fx.home()
    local chat = home:chat():user('one'):assistant('two'):write()
    eq(2, #provider().messages({ path = chat.path }, { cursor = 10 ^ 9 }))
    eq({}, (provider().messages({ path = home.dir .. '/missing.jsonl' })))
  end)
end)

describe('qwen commands', function()
  it('builds resume, new, fork and headless command lines', function()
    fx.home({
      providers = {
        qwen = { cmd = { 'qwen', '-m', 'big' }, headless_args = { '--approval-mode', 'yolo' } },
      },
    })
    local chat = { id = 'abc' }
    eq({ 'qwen', '-m', 'big', '--resume', 'abc' }, provider().resume_cmd(chat))
    eq({ 'qwen', '-m', 'big' }, provider().new_cmd({}))
    eq(
      { 'qwen', '-m', 'big', '--session-id', 'id1', '-i', 'do it' },
      provider().new_cmd({ id = 'id1', prompt = 'do it' })
    )
    eq({ 'qwen', '-m', 'big', '--resume', 'abc', '--fork-session' }, provider().fork_cmd(chat))
    eq(
      { 'qwen', '-m', 'big', '--resume', 'abc', '--approval-mode', 'yolo', 'next step' },
      provider().headless_cmd(chat, 'next step')
    )
    eq(
      { 'qwen', '-m', 'big', '--resume', 'abc', '-i', ' -v is broken' },
      provider().resume_prompt_cmd(chat, '-v is broken')
    )
  end)
end)
