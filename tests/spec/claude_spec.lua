local T = require('helpers.harness')
local fx = require('helpers.claude')
local eq, ok, no = T.eq, T.ok, T.no

local function provider()
  return require('agent-chats.providers.claude')
end

--- Discover + parse the single chat written by `build`.
local function parsed(build)
  local home = fx.home()
  local chat = home:chat({ cwd = '/work/alpha', branch = 'feature' })
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

describe('claude discover', function()
  it('lists session transcripts and nothing else', function()
    local home = fx.home()
    local a = home:chat({ cwd = '/work/alpha' }):user('one'):assistant('two'):write()
    local b = home:chat({ cwd = '/work/beta' }):user('three'):write()
    a:subagent('abc123')
    T.write(home.dir .. '/projects/-work-alpha/notes.txt', 'not a chat')
    T.write(home.dir .. '/projects/-work-alpha/' .. fx.uuid() .. '.jsonl', '')
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
end)

describe('claude parse', function()
  it('reads title, prompts, reply, folder and branch', function()
    local p, _, chat = parsed(function(c)
      c:noise()
      c:user('Fix the flaky test')
      c:attachment()
      c:title('Fix flaky session test')
      c:assistant('Looking at it.', 'tool_use')
      c:tool_use('Bash', { command = 'make test' })
      c:tool_result('1 failed')
      c:assistant('Fixed: the fixture leaked.')
      c:turn_done()
      c:user('Now update the docs')
      c:last_prompt('Now update the docs')
      c:assistant('Docs updated.')
      c:turn_done()
    end)
    eq('Fix flaky session test', p.title)
    eq('Fix the flaky test', p.first_prompt)
    eq('Now update the docs', p.last_prompt)
    eq('Docs updated.', p.last_reply)
    eq('/work/alpha', p.cwd)
    eq('feature', p.branch)
    eq('claude-test-1', p.model)
    eq('cli', p.origin)
    eq('done', p.turn)
    no(p.pending_tool)
    eq(chat.ts, p.updated)
    ok(p.created < p.updated)
    eq(p.updated, p.turn_at)
  end)

  it('prefers a name the user gave the chat', function()
    local p = parsed(function(c)
      c:user('hello')
        :title('Auto title')
        :custom_title('My name')
        :assistant('hi')
        :title('Auto title 2')
    end)
    eq('My name', p.title)
  end)

  it('is working after a prompt and while a tool call is outstanding', function()
    local p = parsed(function(c)
      c:user('Run the build')
    end)
    eq('working', p.turn)
    no(p.pending_tool)

    p = parsed(function(c)
      c:user('Run the build')
        :assistant('On it.', 'tool_use')
        :tool_use('Bash', { command = 'make -j8 all' })
    end)
    eq('working', p.turn)
    ok(p.pending_tool)
    eq('Bash: make -j8 all', p.activity)
    no(p.asking)

    p = parsed(function(c)
      c:user('Run the build'):tool_use('Bash', { command = 'make' }):tool_result('ok')
    end)
    eq('working', p.turn)
    no(p.pending_tool)
    no(p.activity)
  end)

  it('tracks parallel tool calls until the last result is in', function()
    local p = parsed(function(c)
      c:user('Read both files')
      c:tool_use('Read', { file_path = '/work/alpha/a.lua' })
      local first = c.tool_id
      c:tool_use('Read', { file_path = '/work/alpha/b.lua' })
      c:tool_result('contents of a', { id = first })
    end)
    ok(p.pending_tool)
    eq('Read: /work/alpha/b.lua', p.activity)
  end)

  it('flags a question to the user', function()
    local p = parsed(function(c)
      c:user('Plan it'):tool_use('AskUserQuestion', { questions = {} })
    end)
    ok(p.asking)
    ok(p.pending_tool)
  end)

  it("treats an interrupt as the user's move", function()
    local p = parsed(function(c)
      c:user('Do the long thing'):tool_use('Bash', { command = 'sleep 600' }):interrupt()
    end)
    eq('aborted', p.turn)
    no(p.pending_tool)
    eq('Do the long thing', p.last_prompt)
  end)

  it('does not mistake local commands for prompts or turns', function()
    local p = parsed(function(c)
      c:user('First real prompt'):assistant('Answer.'):turn_done():local_command('/model')
    end)
    eq('done', p.turn)
    eq('First real prompt', p.last_prompt)
    eq('First real prompt', p.first_prompt)
  end)

  it('ignores meta and harness-originated user records as prompts', function()
    local p = parsed(function(c)
      c:user('hidden context', { meta = true })
      c:user('Real prompt')
      c:assistant('Done.')
      c:turn_done()
      c:user('<task-notification>build finished</task-notification>')
      c:user('A background task finished', { origin = 'task-notification' })
    end)
    eq('Real prompt', p.first_prompt)
    eq('Real prompt', p.last_prompt)
    eq('working', p.turn)
  end)

  it('strips wrappers from pasted prompts', function()
    local p = parsed(function(c)
      c:user(
        '<pasted_content id="ab12">\nbuild me a thing\n</pasted_content>\n<system-reminder>ignore</system-reminder>'
      )
    end)
    eq('build me a thing', p.first_prompt)
  end)

  it('finds the turn behind megabytes of bookkeeping', function()
    local p = parsed(function(c)
      c:user('Summarise the repo'):title('Repo summary'):assistant('Here it is.'):turn_done()
      -- More than the first tail read, all of it noise.
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
    chat
      :user('The very first prompt')
      :title('Kept title')
      :assistant('First answer.')
      :turn_done()
      :write()
    local first = provider().parse(provider().discover()[1])
    eq('The very first prompt', first.first_prompt)
    first.path = chat.path

    -- A long stretch of conversation pushes the start out of the tail.
    for i = 1, 40 do
      chat:tool_use('Read', { file_path = '/work/alpha/f' .. i }):tool_result(string.rep('y', 8000))
    end
    chat:assistant('Second answer.'):turn_done():write()
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
    home:chat():noise():noise():write()
    local entries = provider().discover()
    eq(1, #entries)
    eq(nil, provider().parse(entries[1]))
  end)

  it('survives malformed lines', function()
    local home = fx.home()
    local chat = home:chat():user('Still here'):assistant('Yes.')
    table.insert(chat.lines, 2, '{"parentUuid":null,"type":"user","message":{"content":')
    table.insert(chat.lines, 'not json at all')
    chat:write()
    local p = provider().parse(provider().discover()[1])
    eq('Still here', p.first_prompt)
    eq('Yes.', p.last_reply)
  end)
end)

describe('claude live', function()
  it('maps the registry status of running sessions', function()
    local home = fx.home()
    local pid = vim.uv.os_getpid()
    local rec = home:registry(pid, { status = 'busy', cwd = '/work/alpha' })
    local live = provider().live()
    eq('working', live[rec.sessionId].turn)
    eq(pid, live[rec.sessionId].pid)
    eq('project-1a', live[rec.sessionId].name)
    no(live[rec.sessionId].name_explicit)
    eq('/work/alpha', live[rec.sessionId].cwd)
    eq('interactive', live[rec.sessionId].kind)

    rec = home:registry(pid, { status = 'idle' })
    eq('done', provider().live()[rec.sessionId].turn)

    rec = home:registry(
      pid,
      { status = 'waiting', waitingFor = 'permission', nameSource = 'user', name = 'release prep' }
    )
    live = provider().live()[rec.sessionId]
    eq('waiting', live.turn)
    eq('permission', live.waiting_for)
    ok(live.name_explicit)
    eq('release prep', live.name)
    ok(math.abs(live.turn_at - os.time()) < 5)
  end)

  it('reports no state for a status it does not know', function()
    local home = fx.home()
    local rec = home:registry(vim.uv.os_getpid(), { status = 'something-new' })
    local live = provider().live()[rec.sessionId]
    ok(live)
    eq(nil, live.turn)
  end)

  it('ignores records of processes that are gone', function()
    local home = fx.home()
    home:registry(dead_pid(), { status = 'busy' })
    T.write(home.dir .. '/sessions/garbage.json', '{')
    T.write(home.dir .. '/sessions/' .. vim.uv.os_getpid() .. '.json', '{ not json')
    eq({}, provider().live())
  end)

  it('ignores a record left behind by an earlier process with the same pid', function()
    if not require('agent-chats.util.proc').has_procfs then
      return
    end
    local home = fx.home()
    home:registry(vim.uv.os_getpid(), { status = 'busy', procStart = '1' })
    eq({}, provider().live())
  end)

  it('locates the transcript of a running session', function()
    local home = fx.home()
    local chat = home:chat({ cwd = '/work/my.proj' }):user('hi'):write()
    local entry = provider().locate(chat.id, { cwd = '/work/my.proj' })
    eq(chat.path, entry.path)
    eq(nil, provider().locate(fx.uuid(), { cwd = '/work/my.proj' }))
    eq(nil, provider().locate(chat.id, {}))
  end)
end)

describe('claude subagents', function()
  it('lists them with their type, description and state', function()
    local home = fx.home()
    local chat = home:chat({ cwd = '/work/alpha' }):user('Explore'):write()
    chat:subagent(
      'aaa111',
      { agentType = 'Explore', description = 'Find session files', finished = true }
    )
    chat:subagent(
      'bbb222',
      { agentType = 'general-purpose', description = 'Write tests', finished = false }
    )
    local parent =
      { key = 'claude:' .. chat.id, id = chat.id, path = chat.path, cwd = chat.cwd, live = true }
    local subs = provider().subagents(parent)
    eq(2, #subs)
    local by = {}
    for _, s in ipairs(subs) do
      by[s.id] = s
    end
    eq('Find session files', by.aaa111.title)
    eq('Explore', by.aaa111.agent_type)
    eq('done', by.aaa111.turn)
    eq(false, by.aaa111.live)
    eq('working', by.bbb222.turn)
    eq(true, by.bbb222.live)
    eq(parent.key, by.bbb222.parent)
    eq(parent.key .. '/bbb222', by.bbb222.key)
    ok(by.bbb222.subagent)

    local msgs = provider().messages(by.aaa111)
    eq({ 'user', 'assistant' }, { msgs[1].role, msgs[2].role })
  end)

  it('is empty for a chat with none', function()
    local home = fx.home()
    local chat = home:chat():user('hi'):write()
    eq({}, provider().subagents({ key = 'claude:x', path = chat.path }))
  end)
end)

describe('claude messages', function()
  it('normalises a conversation', function()
    local home = fx.home()
    local chat = home:chat()
    chat:noise(2000)
    chat:user('Fix it')
    chat:attachment()
    chat:thinking('Considering the options.')
    chat:assistant('Running the tests.', 'tool_use')
    chat:tool_use('Bash', { command = 'make test', description = 'Run tests' })
    chat:tool_result('2 passed')
    chat:tool_use(
      'Edit',
      { file_path = '/work/project/a.lua', old_string = 'x = 1', new_string = 'x = 2' }
    )
    chat:tool_result('edit failed', { error = true })
    chat:assistant('All done.')
    chat:turn_done()
    chat:local_command('/model')
    chat:interrupt()
    chat:write()
    local msgs, cursor = provider().messages({ path = chat.path })
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
      'assistant',
      'user',
      'system',
    }, roles)
    eq('Fix it', msgs[1].text)
    eq('Bash', msgs[4].name)
    eq('make test', msgs[4].summary)
    eq('sh', msgs[4].lang)
    eq('2 passed', msgs[5].text)
    eq(msgs[4].id, msgs[5].id)
    eq('diff', msgs[6].lang)
    eq('-x = 1\n+x = 2', msgs[6].input)
    ok(msgs[7].error)
    eq('/model', msgs[9].text)
    eq('Interrupted by user.', msgs[10].text)
    ok(msgs[1].time and msgs[1].time < msgs[8].time)
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

    -- A half-written last line is left for the next read.
    T.append(chat.path, '{"parentUuid":null,"type":"user","message":{"content":"par')
    local partial, cursor3 = provider().messages({ path = chat.path }, { cursor = cursor2 })
    eq({}, partial)
    eq(cursor2, cursor3)
  end)

  it('starts over when the file shrank', function()
    local home = fx.home()
    local chat = home:chat():user('one'):assistant('two'):write()
    local msgs = provider().messages({ path = chat.path }, { cursor = 10 ^ 9 })
    eq(2, #msgs)
    eq({}, (provider().messages({ path = home.dir .. '/missing.jsonl' })))
  end)
end)

describe('claude commands', function()
  it('builds resume, new and headless command lines', function()
    fx.home({
      providers = {
        claude = {
          cmd = { 'claude', '--model', 'opus' },
          headless_args = { '--permission-mode', 'acceptEdits' },
        },
      },
    })
    local chat = { id = 'abc' }
    eq({ 'claude', '--model', 'opus', '--resume', 'abc' }, provider().resume_cmd(chat))
    eq({ 'claude', '--model', 'opus' }, provider().new_cmd({}))
    eq(
      { 'claude', '--model', 'opus', '--session-id', 'id1', 'do it' },
      provider().new_cmd({ id = 'id1', prompt = 'do it' })
    )
    eq({
      'claude',
      '--model',
      'opus',
      '-p',
      '--resume',
      'abc',
      '--permission-mode',
      'acceptEdits',
      'next step',
    }, provider().headless_cmd(chat, 'next step'))
    eq(
      { 'claude', '--model', 'opus', '--resume', 'abc', ' -v is broken' },
      provider().resume_prompt_cmd(chat, '-v is broken')
    )
  end)
end)
