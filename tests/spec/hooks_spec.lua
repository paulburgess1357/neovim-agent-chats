-- Status reported by the agents' own hooks: the script they run, the log it
-- writes, and how the index weighs that against everything else it knows.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local hk = require('helpers.hooks')
local eq, ok, no, has = T.eq, T.ok, T.no, T.has

local SID = '11111111-2222-4333-8444-555555555555'

local function store()
  return require('agent-chats.store')
end

local function events()
  return require('agent-chats.events')
end

local function key(chat)
  return 'claude:' .. chat.id
end

local function shells()
  local out = {}
  for _, sh in ipairs({ 'sh', 'dash', 'bash', 'busybox sh' }) do
    if vim.fn.executable(vim.split(sh, ' ')[1]) == 1 then
      out[#out + 1] = sh
    end
  end
  return out
end

--- A payload shaped like the ones Claude Code sends: what the agent sets
--- itself first, then the event's own fields in the order given (`fields`
--- is a list of `{ key, value }`). The order matters to the hook, and a Lua
--- table has none.
local function payload(event, fields)
  local parts = {}
  local function add(k, v)
    parts[#parts + 1] = vim.json.encode(k) .. ':' .. vim.json.encode(v)
  end
  add('session_id', SID)
  add('transcript_path', '/home/u/.claude/projects/-w-p/' .. SID .. '.jsonl')
  add('cwd', '/w/p')
  add('permission_mode', 'default')
  local rest = {}
  for _, f in ipairs(fields or {}) do
    if f[1] == 'agent_id' or f[1] == 'agent_type' then
      add(f[1], f[2])
    else
      rest[#rest + 1] = f
    end
  end
  add('hook_event_name', event)
  for _, f in ipairs(rest) do
    add(f[1], f[2])
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

describe('the hook script', function()
  it('appends one line per event, in every shell there is', function()
    fx.home()
    for _, sh in ipairs(shells()) do
      local dir = T.tmpdir()
      local res = hk.run('claude', payload('Stop'), { shell = sh, dir = dir })
      eq(0, res.code, sh)
      eq('', res.stdout, sh .. ' must print nothing')
      eq('', res.stderr, sh)
      local f = assert(io.open(dir .. '/claude/' .. SID .. '.log'), sh)
      local line = vim.json.decode(f:read('*l'))
      f:close()
      eq('Stop', line.e, sh)
      ok(type(line.t) == 'number' and math.abs(line.t - os.time()) < 5, sh)
      ok(type(line.pid) == 'number', sh)
    end
  end)

  it('keeps the fields that say what happened and nothing else', function()
    fx.home()
    hk.run('claude', payload('SessionStart', { { 'source', 'startup' }, { 'model', 'm' } }))
    hk.run(
      'claude',
      payload('UserPromptSubmit', { { 'prompt', 'a secret plan with "session_id":"other" in it' } })
    )
    hk.run(
      'claude',
      payload('PermissionRequest', {
        { 'agent_id', 'sub1' },
        { 'tool_name', 'Bash' },
        { 'tool_input', { command = 'make secret', agent_id = 'nested', tool_name = 'Nested' } },
      })
    )
    hk.run(
      'claude',
      payload('Notification', {
        { 'message', 'Claude needs your permission' },
        { 'notification_type', 'permission_prompt' },
      })
    )
    hk.run('claude', payload('SessionEnd', { { 'reason', 'prompt_input_exit' } }))
    local lines = hk.lines('claude', SID)
    eq(5, #lines)
    eq('SessionStart', lines[1].e)
    eq('startup', lines[1].src)
    eq('/w/p', lines[1].cwd)
    ok(lines[1].path:find(SID, 1, true))
    eq('UserPromptSubmit', lines[2].e)
    eq(nil, lines[2].path, 'the transcript is named once, not on every line')
    eq({ 'PermissionRequest', 'Bash', 'sub1' }, { lines[3].e, lines[3].tool, lines[3].agent })
    eq('permission_prompt', lines[4].type)
    eq('prompt_input_exit', lines[5].reason)

    local raw = table.concat(vim.fn.readfile(hk.log('claude', SID)), '\n')
    T.hasnt(raw, 'secret')
    T.hasnt(raw, 'needs your permission')
    T.hasnt(raw, 'nested')
  end)

  it('takes a subagent id only from where the agent puts it', function()
    fx.home()
    hk.run(
      'claude',
      payload('PostToolUse', {
        { 'tool_name', 'Task' },
        { 'tool_input', { agent_id = 'not-the-caller' } },
        { 'tool_response', 'x' },
      })
    )
    local line = hk.lines('claude', SID)[1]
    eq('Task', line.tool)
    eq(nil, line.agent)
  end)

  it('reads a payload written across several lines', function()
    fx.home()
    hk.run(
      'claude',
      ('{\n  "session_id": "%s",\n  "hook_event_name": "Stop",\n  "x": 1\n}\n'):format(SID)
    )
    eq('Stop', hk.lines('claude', SID)[1].e)
  end)

  it('never fails and never writes outside its folder', function()
    fx.home()
    local dir = events().dir()
    local function run(agent, text, args)
      local res = hk.run(agent, text, { args = args })
      eq(0, res.code)
      eq('', res.stdout .. res.stderr)
    end
    run('claude', 'not json at all')
    run('claude', '')
    run('claude', '{"session_id":"../../escape","hook_event_name":"Stop"}')
    run('claude', '{"session_id":"a b","hook_event_name":"Stop"}')
    run('claude', ('{"session_id":"%s","hook_event_name":"Sto p"}'):format(SID))
    run('../evil', ('{"session_id":"%s","hook_event_name":"Stop"}'):format(SID))
    eq({}, vim.fn.glob(dir .. '/**/*.log', false, true))
    eq(0, vim.fn.filereadable(vim.fs.dirname(dir) .. '/escape.log'))
  end)

  it('takes the event and the session from its arguments when the payload has neither', function()
    fx.home()
    local res = hk.run('other', '', { args = { 'Stop', 'abc-123' } })
    eq(0, res.code)
    eq('Stop', hk.lines('other', 'abc-123')[1].e)
  end)

  it('copes with a payload far larger than it reads', function()
    fx.home()
    local big =
      payload('PostToolUse', { { 'tool_name', 'Read' }, { 'tool_response', ('x'):rep(3000000) } })
    local res = hk.run('claude', big)
    eq(0, res.code)
    eq('Read', hk.lines('claude', SID)[1].tool)
  end)

  it('names the agent as its process, also when a shell sits in between', function()
    fx.home()
    local dir = require('agent-chats.events').dir()
    -- The way it is installed: `sh script agent || true`, so the shell the
    -- agent starts stays around as the script's parent.
    local function fire(script, event)
      local line = ("sh '%s' claude 2>/dev/null || true"):format(script)
      local res = vim
        .system({ 'sh', '-c', line }, {
          stdin = payload(event),
          env = { AGENT_CHATS_EVENTS_DIR = dir },
        })
        :wait(10000)
      eq(0, res.code)
    end
    fire(hk.script, 'Stop')
    eq(vim.uv.os_getpid(), hk.lines('claude', SID)[1].pid)

    -- The same where there is no /proc to read: `ps` is asked, but only
    -- for the first event of a session.
    if vim.fn.executable('ps') ~= 1 then
      return
    end
    local text = table.concat(vim.fn.readfile(hk.script), '\n')
    local copy =
      T.write(T.tmpdir() .. '/hook.sh', (text:gsub('"/proc/', '"/no-proc-here/')) .. '\n')
    vim.uv.fs_unlink(hk.log('claude', SID))
    fire(copy, 'Stop')
    fire(copy, 'Stop')
    local lines = hk.lines('claude', SID)
    eq(vim.uv.os_getpid(), lines[1].pid)
    eq(nil, lines[2].pid)
  end)

  it('keeps what it writes private', function()
    fx.home()
    hk.run('claude', payload('Stop'))
    local dir = events().dir()
    local function mode(path)
      return bit.band(assert(vim.uv.fs_stat(path)).mode, 511)
    end
    eq(448, mode(dir))
    eq(448, mode(dir .. '/claude'))
    eq(384, mode(hk.log('claude', SID)))
  end)
end)

describe('hook events', function()
  local RULES = {
    Prompt = 'working',
    Busy = 'active',
    Ask = 'waiting',
    Answer = 'resolved',
    Stop = 'done',
    Idle = 'idle',
    Interrupt = 'aborted',
    Start = 'start',
    End = 'ended',
    Odd = function(ev)
      if ev.type == 'q' then
        return 'waiting', 'a question'
      end
    end,
  }

  local function fold(list)
    for i, ev in ipairs(list) do
      ev.t = ev.t or (1000 + i)
    end
    return events()._fold(RULES, list)
  end

  it('follows a turn from prompt to finish', function()
    eq('working', fold({ { e = 'Prompt' } }).turn)
    eq('done', fold({ { e = 'Prompt' }, { e = 'Answer', tool = 'Read' }, { e = 'Stop' } }).turn)
    eq('aborted', fold({ { e = 'Prompt' }, { e = 'Interrupt' } }).turn)
    eq(nil, fold({ { e = 'Prompt' }, { e = 'Start' } }).turn)
  end)

  it('waits until the request is answered', function()
    local r = fold({ { e = 'Prompt' }, { e = 'Ask', tool = 'Bash' } })
    eq('waiting', r.turn)
    eq('permission to use Bash', r.waiting_for)
    eq(1002, r.at)
    eq(
      'working',
      fold({ { e = 'Prompt' }, { e = 'Ask', tool = 'Bash' }, { e = 'Answer', tool = 'Bash' } }).turn
    )
    -- Refused with a word for the agent: no tool ran, the next one settles it.
    eq(
      'working',
      fold({ { e = 'Prompt' }, { e = 'Ask', tool = 'Bash' }, { e = 'Answer', tool = 'Read' } }).turn
    )
  end)

  it('keeps waiting while other agents of the chat carry on', function()
    local r = fold({
      { e = 'Prompt' },
      { e = 'Ask', tool = 'Bash', agent = 'a' },
      { e = 'Answer', tool = 'Read', agent = 'b' },
      { e = 'Answer', tool = 'Task' },
    })
    eq('waiting', r.turn)
    eq(1002, r.at, 'another agent finishing a tool says nothing new about the request')
    eq(
      'working',
      fold({
        { e = 'Prompt' },
        { e = 'Ask', tool = 'Bash', agent = 'a' },
        { e = 'Answer', tool = 'Bash', agent = 'a' },
      }).turn
    )
  end)

  it('takes a bare notice back with the request it was about', function()
    eq('waiting', fold({ { e = 'Prompt' }, { e = 'Ask' } }).turn)
    -- The chat's own agent moving on answers it.
    eq('working', fold({ { e = 'Prompt' }, { e = 'Ask' }, { e = 'Answer', tool = 'Bash' } }).turn)
    -- So does an answer that names no tool (the agent saying "answered").
    eq('working', fold({ { e = 'Prompt' }, { e = 'Ask' }, { e = 'Answer', agent = 'a' } }).turn)
    -- A notice on top of a subagent's request goes when that request does.
    eq(
      'working',
      fold({
        { e = 'Prompt' },
        { e = 'Ask', tool = 'Bash', agent = 'a' },
        { e = 'Ask' },
        { e = 'Answer', tool = 'Bash', agent = 'a' },
      }).turn
    )
    -- Some other subagent finishing a tool answers nothing.
    eq(
      'waiting',
      fold({ { e = 'Prompt' }, { e = 'Ask' }, { e = 'Answer', tool = 'Read', agent = 'b' } }).turn
    )
  end)

  it('dates the turn by what its own agent said, not by requests coming and going', function()
    -- A notice at 1200, taken back at 1210 by the subagent it was about:
    -- the chat has been running since 1000, and that is all the hooks know.
    local r = fold({
      { e = 'Prompt', t = 1000 },
      { e = 'Ask', tool = 'Bash', agent = 'a', t = 1200 },
      { e = 'Answer', tool = 'Bash', agent = 'a', t = 1210 },
    })
    eq('working', r.turn)
    eq(1000, r.at)
    -- While it is open, the request is as new as it is.
    eq(1200, fold({ { e = 'Prompt', t = 1000 }, { e = 'Ask', tool = 'Bash', t = 1200 } }).at)
  end)

  it('does not take a tool cut short by an interrupt for the turn going on', function()
    local r = fold({
      { e = 'Prompt', t = 1000 },
      { e = 'Interrupt', t = 1010 },
      { e = 'Answer', tool = 'Bash', t = 1010.5 },
    })
    eq('aborted', r.turn)
    eq(1010, r.at)
    -- Long after, a tool finishing is a turn nobody announced.
    eq(
      'working',
      fold({ { e = 'Interrupt', t = 1010 }, { e = 'Answer', tool = 'Bash', t = 1100 } }).turn
    )
  end)

  it('does not date a finished turn again each time the session says it is idle', function()
    local r = fold({ { e = 'Busy', t = 1000 }, { e = 'Idle', t = 1050 }, { e = 'Idle', t = 2000 } })
    eq('done', r.turn)
    eq(1050, r.at)
    -- Idle with nothing known before says nothing about a turn.
    eq(nil, fold({ { e = 'Idle', t = 1000 } }).turn)
  end)

  it('files requests under the id the agent gives them', function()
    local r = fold({
      { e = 'Busy' },
      { e = 'Ask', req = 'p1' },
      { e = 'Ask', req = 'p2' },
      { e = 'Answer', req = 'p1' },
    })
    eq('waiting', r.turn)
    eq(
      'working',
      fold({ { e = 'Busy' }, { e = 'Ask', req = 'p1' }, { e = 'Answer', req = 'p1' } }).turn
    )
  end)

  it('lets a provider decide by what the event carries', function()
    local r = fold({ { e = 'Prompt' }, { e = 'Odd', type = 'q' } })
    eq('waiting', r.turn)
    eq('a question', r.waiting_for)
    eq('working', fold({ { e = 'Prompt' }, { e = 'Odd', type = 'other' } }).turn)
    eq('working', fold({ { e = 'Prompt' }, { e = 'NeverHeardOfIt' } }).turn)
  end)

  it('does not let a late, meaningless event make an old state look new', function()
    local r = fold({ { e = 'Prompt', t = 1000 }, { e = 'NeverHeardOfIt', t = 2000 } })
    eq('working', r.turn)
    eq(1000, r.at)
  end)

  it('keeps an interrupted turn interrupted when the session goes idle', function()
    eq('aborted', fold({ { e = 'Busy' }, { e = 'Interrupt' }, { e = 'Idle' } }).turn)
    eq('done', fold({ { e = 'Busy' }, { e = 'Idle' } }).turn)
  end)

  it('remembers the process and that the session closed', function()
    local r = fold({ { e = 'Prompt', pid = 42 }, { e = 'End', pid = 42 } })
    eq(nil, r.turn)
    eq(true, r.ended)
    eq(42, r.pid)
    eq(nil, fold({ { e = 'End' }, { e = 'Prompt' } }).ended)
  end)

  it('reads a log as it grows, whole lines only', function()
    fx.home()
    local path = hk.event('claude', SID, 'Prompt', { t = 1000 })
    eq('working', events().get('claude', RULES, SID).turn)
    -- A line caught half written is left for the next look.
    T.append(path, '{"t":1001,"e":"St')
    eq('working', events().get('claude', RULES, SID).turn)
    T.append(path, 'op"}\n')
    local r = events().get('claude', RULES, SID)
    eq('done', r.turn)
    eq(2, r.count)
    -- Replaced by a shorter one: start over.
    T.write(path, '{"t":1005,"e":"Ask","tool":"X"}\n')
    eq('waiting', events().get('claude', RULES, SID).turn)
    eq(nil, events().get('claude', RULES, 'no-such-session'))
    eq(nil, events().get('claude', RULES, '../' .. SID))
  end)

  it('skips lines it cannot read', function()
    fx.home()
    local path = hk.event('claude', SID, 'Prompt', { t = 1000 })
    T.append(path, 'garbage\n{"e":"Stop"}\n{"t":"x","e":"Stop"}\n[1,2]\n')
    hk.event('claude', SID, 'Ask', { t = 1003, tool = 'Bash' })
    local r = events().get('claude', RULES, SID)
    eq('waiting', r.turn)
    eq(2, r.count)
  end)

  it('uses the file time when the event time is in whole seconds', function()
    fx.home()
    local now = os.time()
    local path = hk.event('claude', SID, 'Prompt', { t = now })
    T.touch(path, now + 0.75)
    local r = events().get('claude', RULES, SID)
    ok(math.abs(r.at - (now + 0.75)) < 0.01, tostring(r.at))
  end)

  it('lists the sessions that reported lately, and forgets an agent on request', function()
    fx.home()
    local old = hk.event('claude', 'old-one', 'Stop')
    T.touch(old, os.time() - 5000)
    hk.event('claude', 'new-one', 'Stop')
    hk.event('qwen', 'other-agent', 'Stop')
    eq({ 'new-one' }, events().recent('claude', os.time() - 900))
    eq(2, (events().summary('claude')))
    eq(2, events().clear('claude'))
    eq(0, (events().summary('claude')))
    eq(1, (events().summary('qwen')))
  end)
end)

describe('status from hooks', function()
  --- A chat mid-turn whose last record is `age` seconds old, with a tool
  --- call outstanding.
  local function working(home, age)
    local chat = home:chat({ start = os.time() - (age or 60) - 5 })
    chat:user('Go'):tool_use('Bash', { command = 'make' })
    return chat:write()
  end

  local function running(home, chat, status, fields)
    local pid = vim.uv.os_getpid()
    home:registry(
      pid,
      vim.tbl_extend(
        'force',
        { sessionId = chat.id, status = status, cwd = chat.cwd },
        fields or {}
      )
    )
    return pid
  end

  it('shows a permission prompt the moment the agent asks', function()
    local home = fx.home()
    local chat = working(home, 60)
    running(home, chat, 'not-a-known-status')
    hk.event('claude', chat.id, 'UserPromptSubmit', { t = os.time() - 60 })
    hk.event('claude', chat.id, 'PermissionRequest', { t = os.time() - 2, tool = 'Bash' })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('attention', c.status)
    no(c.inferred)
    ok(c.exact)
    eq('hooks', c.source)
    eq('permission to use Bash', c.waiting_for)
  end)

  it('does not guess about a chat whose hooks say it is working', function()
    local home = fx.home({ status = { stall_after = 30 } })
    local chat = working(home, 300)
    running(home, chat, 'not-a-known-status')
    store().refresh_sync()
    eq('attention', store().get(key(chat)).status)
    ok(store().get(key(chat)).inferred, 'the guess, with nothing better to go on')

    hk.event('claude', chat.id, 'PostToolUse', { t = os.time() - 200, tool = 'Read' })
    store().refresh_sync({ full = false })
    local c = store().get(key(chat))
    eq('working', c.status)
    no(c.inferred)
    eq('hooks', c.source)
  end)

  it('does not second-guess a long tool call the hooks call running', function()
    local home = fx.home({ status = { stall_after = 30 } })
    -- The prompt, then the tool call written a moment later, then silence.
    local chat = working(home, 600)
    running(home, chat, 'not-a-known-status')
    hk.event('claude', chat.id, 'UserPromptSubmit', { t = os.time() - 605 })
    store().refresh_sync()
    local c = store().get(key(chat))
    ok((c.turn_at or 0) > os.time() - 605, 'the transcript is the newer of the two')
    eq('working', c.status)
    no(c.inferred)
    eq('hooks', c.source)
  end)

  it('believes whichever of registry and hooks spoke last', function()
    local home = fx.home()
    local chat = working(home, 60)
    local now = os.time()
    -- You approved it: the registry says so at once, the hooks only when
    -- the tool finishes.
    hk.event('claude', chat.id, 'PermissionRequest', { t = now - 20, tool = 'Bash' })
    running(home, chat, 'busy', { statusUpdatedAt = (now - 5) * 1000 })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('working', c.status)
    eq('registry', c.source)

    -- A prompt the registry has not caught up with.
    hk.event('claude', chat.id, 'PermissionRequest', { t = now - 1, tool = 'Edit' })
    store().refresh_sync({ full = false })
    c = store().get(key(chat))
    eq('attention', c.status)
    eq('hooks', c.source)
    eq('permission to use Edit', c.waiting_for)

    running(home, chat, 'waiting', { statusUpdatedAt = (now + 2) * 1000 })
    store().refresh_sync({ full = false })
    c = store().get(key(chat))
    eq('attention', c.status)
    eq('registry', c.source)
    eq('permission to use Edit', c.waiting_for, 'the hooks still say what for')
  end)

  it('lets the transcript correct hooks that missed an interrupt', function()
    local home = fx.home()
    local chat = home:chat({ start = os.time() - 100 }):user('Go')
    chat:tool_use('Bash', { command = 'make' }):write()
    running(home, chat, 'not-a-known-status')
    hk.event('claude', chat.id, 'UserPromptSubmit', { t = os.time() - 90 })
    store().refresh_sync()
    eq('working', store().get(key(chat)).status)

    -- Esc: no hook fires, the transcript says so.
    chat.ts = os.time() - 3
    chat:interrupt():write()
    store().refresh_sync({ full = false })
    local c = store().get(key(chat))
    eq('aborted', c.turn)
    eq('transcript', c.source)
    eq('idle', c.status)

    -- The next prompt is news again.
    hk.event('claude', chat.id, 'UserPromptSubmit', { t = os.time() })
    store().refresh_sync({ full = false })
    eq('working', store().get(key(chat)).status)
    eq('hooks', store().get(key(chat)).source)
  end)

  it('does not call an interrupted turn finished because the agent went idle', function()
    local home = fx.home()
    require('agent-chats.state').update(function(s)
      s.baseline = os.time() - 600
    end)
    local chat = home:chat({ start = os.time() - 100 }):user('Go')
    chat.ts = os.time() - 4
    chat:interrupt():write()
    running(home, chat, 'idle', { statusUpdatedAt = (os.time() - 3) * 1000 })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('aborted', c.turn)
    eq('idle', c.status, 'your move, but nothing to read')
  end)

  it('keeps a request open while the transcript shows other work', function()
    local home = fx.home()
    local chat = working(home, 60)
    running(home, chat, 'not-a-known-status')
    hk.event(
      'claude',
      chat.id,
      'PermissionRequest',
      { t = os.time() - 30, tool = 'Bash', agent = 'a' }
    )
    -- Another subagent of the same chat finishes and is recorded.
    chat.ts = os.time() - 5
    chat:tool_result('ok'):tool_use('Task', { description = 'more' }):write()
    store().refresh_sync()
    eq('attention', store().get(key(chat)).status)

    -- The turn ending is another matter: nothing can be waiting then.
    chat.ts = os.time() - 2
    chat:tool_result('ok'):assistant('All done.'):turn_done():write()
    store().refresh_sync({ full = false })
    local c = store().get(key(chat))
    eq('done', c.turn)
    eq('transcript', c.source)
  end)

  it('reports a finished turn from the Stop hook before the transcript says so', function()
    local home = fx.home()
    local chat = working(home, 60)
    -- You looked at it half a minute ago, after everything the transcript holds.
    require('agent-chats.state').mark_seen(key(chat), os.time() - 30)
    running(home, chat, 'not-a-known-status')
    hk.event('claude', chat.id, 'UserPromptSubmit', { t = os.time() - 60 })
    hk.event('claude', chat.id, 'Stop', { t = os.time() - 1 })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('done', c.turn)
    eq('hooks', c.source)
    eq('done', c.status, 'unread from the moment the hook said so')

    require('agent-chats.state').mark_seen(key(chat))
    store().touch()
    eq('idle', store().get(key(chat)).status)
  end)

  it('knows a session is running from its hook when nothing else lists it', function()
    local home = fx.home()
    local chat = working(home, 60)
    -- No registry at all: the process the hook ran under is the evidence.
    local sleeper = vim.system({ 'sleep', '30' })
    local claude = require('agent-chats.providers.claude')
    local names = claude.hooks.process
    claude.hooks.process = { sleep = true }
    hk.event('claude', chat.id, 'PermissionRequest', { tool = 'Bash', pid = sleeper.pid })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq(true, c.live)
    eq(sleeper.pid, c.pid)
    eq('attention', c.status)

    sleeper:kill(9)
    sleeper:wait(2000)
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    claude.hooks.process = names
    eq(false, store().get(key(chat)).live)
    eq('ended', store().get(key(chat)).status)
  end)

  it('does not take a process for the agent when it is something else', function()
    local home = fx.home()
    local chat = working(home, 60)
    local sleeper = vim.system({ 'sleep', '30' })
    hk.event('claude', chat.id, 'UserPromptSubmit', { pid = sleeper.pid })
    store().refresh_sync()
    sleeper:kill(9)
    eq(false, store().get(key(chat)).live)
  end)

  it('stops listing a session that said it closed', function()
    local home = fx.home()
    local chat = working(home, 60)
    hk.event('claude', chat.id, 'UserPromptSubmit', { pid = vim.uv.os_getpid() })
    hk.event('claude', chat.id, 'SessionEnd', { pid = vim.uv.os_getpid(), reason = 'other' })
    store().refresh_sync()
    eq(false, store().get(key(chat)).live)
  end)

  it('takes a request as answered once you type into the terminal of its chat', function()
    local home = fx.home()
    local chat = working(home, 60)
    running(home, chat, 'not-a-known-status')
    hk.event('claude', chat.id, 'PermissionRequest', { t = os.time() - 20, tool = 'Bash' })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('attention', c.status)

    -- The chat runs in a terminal of this Neovim, and you typed there
    -- before the question came: that answered nothing.
    local term = require('agent-chats.term')
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    c.term = buf
    term.note_typed(buf, os.time() - 30)
    store().refresh_sync({ full = false })
    c.term = buf
    eq('attention', store().get(key(chat)).status)

    -- After it: that was the answer. The approved command may run for long
    -- with no hook saying so.
    term.note_typed(buf, os.time() - 5)
    c.term = buf
    store().refresh_sync({ full = false })
    c = store().get(key(chat))
    eq('working', c.status)
    eq(true, c.answered)
    has(require('agent-chats.display').source(c), 'you answered its request')

    -- The next request is a new question.
    c.term = buf
    hk.event('claude', chat.id, 'PermissionRequest', { t = os.time() + 1, tool = 'Edit' })
    store().refresh_sync({ full = false })
    eq('attention', store().get(key(chat)).status)
  end)

  it('ignores hook reports when told to', function()
    local home = fx.home({ hooks = { enabled = false } })
    local chat = working(home, 5)
    running(home, chat, 'not-a-known-status')
    hk.event('claude', chat.id, 'PermissionRequest', { tool = 'Bash' })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('working', c.status)
    eq('transcript', c.source)
  end)

  it('behaves as before for a chat with no hook log', function()
    local home = fx.home()
    local chat = working(home, 5)
    running(home, chat, 'waiting', { waitingFor = 'permission to run Bash' })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('attention', c.status)
    eq('registry', c.source)
    eq('permission to run Bash', c.waiting_for)
  end)

  it('picks up a chat that starts reporting between full scans', function()
    local home = fx.home()
    local chat = home:chat({ start = os.time() - 5000 })
    chat:user('Go'):assistant('Done.'):turn_done():write(os.time() - 4000)
    running(home, chat, 'not-a-known-status')
    store().refresh_sync()
    eq('idle', store().get(key(chat)).status)
    hk.event('claude', chat.id, 'PermissionRequest', { tool = 'Bash' })
    store().refresh_sync({ full = false })
    eq('attention', store().get(key(chat)).status)
  end)
end)
