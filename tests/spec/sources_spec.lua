-- The provider contract seen from outside: a made-up agent with any subset
-- of the three status sources, and the built-in fallbacks between them.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local hk = require('helpers.hooks')
local eq, ok, no, has = T.eq, T.ok, T.no, T.has

local function store()
  return require('agent-chats.store')
end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

--- The first Lua block under a heading of the README.
local function readme_example(heading)
  local text = table.concat(vim.fn.readfile(root .. '/README.md'), '\n')
  local from = assert(text:find('\n## ' .. heading, 1, true), 'no such heading: ' .. heading)
  return assert(text:match('```lua\n(.-)\n```', from), 'no lua block under ' .. heading)
end

--- A provider with only what the contract requires. `extra` adds to it.
local function minimal(extra)
  local now = os.time()
  return vim.tbl_extend('force', {
    name = 'demo',
    label = 'Demo',
    home = function()
      return '/nonexistent'
    end,
    available = function()
      return true
    end,
    discover = function()
      return { { id = 'one', mtime = now - 20, size = 1 } }
    end,
    parse = function()
      return {
        title = 'A demo chat',
        cwd = '/work/demo',
        turn = 'working',
        pending_tool = true,
        updated = now - 20,
      }
    end,
    messages = function()
      return { { role = 'user', text = 'hello demo' } }, nil
    end,
    resume_cmd = function(c)
      return { 'demo', 'resume', c.id }
    end,
    new_cmd = function()
      return { 'demo' }
    end,
  }, extra or {})
end

after_each(function()
  require('agent-chats.providers').reset()
end)

describe('a provider from outside', function()
  it('needs none of the status sources', function()
    fx.home()
    require('agent-chats').register(minimal())
    store().refresh_sync()
    local c = store().get('demo:one')
    eq(nil, c.live, 'nothing can tell whether it runs')
    eq('working', c.status, 'so a fresh transcript is believed')
    eq('transcript', c.source)
  end)

  it('can report through hooks alone', function()
    fx.home()
    require('agent-chats').register(minimal({
      hooks = {
        events = { prompt = 'working', ask = 'waiting', answer = 'resolved', stop = 'done' },
      },
    }))
    hk.event('demo', 'one', 'ask', { tool = 'shell' })
    store().refresh_sync()
    local c = store().get('demo:one')
    eq('attention', c.status)
    no(c.inferred)
    eq('hooks', c.source)
    eq('permission to use shell', c.waiting_for)
    hk.event('demo', 'one', 'answer', { tool = 'shell' })
    store().refresh_sync({ full = false })
    eq('working', store().get('demo:one').status)
  end)

  it('can be asked, no more often than it wants', function()
    fx.home()
    local asked, state = 0, 'working'
    require('agent-chats').register(minimal({
      query_interval = 100000,
      query = function(chats)
        asked = asked + 1
        ok(chats.one ~= nil or asked == 1, 'it is handed the chats it knows')
        return { one = { pid = vim.uv.os_getpid(), turn = state, waiting_for = 'you' } }
      end,
    }))
    store().refresh_sync()
    local c = store().get('demo:one')
    eq(true, c.live)
    eq('query', c.source)
    eq('working', c.status)
    state = 'waiting'
    store().refresh_sync({ full = false })
    eq(1, asked, 'the last answer is reused until the interval is over')
    eq('working', store().get('demo:one').status)
  end)

  it('combines what it is told with what it finds, the newer report winning', function()
    fx.home()
    local now = os.time()
    require('agent-chats').register(minimal({
      hooks = { events = { ask = 'waiting', stop = 'done' } },
      live = function(_, reported)
        ok(type(reported) == 'table')
        return { one = { pid = vim.uv.os_getpid(), turn = 'working', turn_at = now - 10 } }
      end,
    }))
    hk.event('demo', 'one', 'ask', { t = now - 30, tool = 'shell' })
    store().refresh_sync()
    eq('registry', store().get('demo:one').source)
    eq('working', store().get('demo:one').status)
    hk.event('demo', 'one', 'ask', { t = now - 2, tool = 'shell' })
    store().refresh_sync({ full = false })
    eq('hooks', store().get('demo:one').source)
    eq('attention', store().get('demo:one').status)
  end)

  it('survives a source that throws', function()
    fx.home()
    require('agent-chats').register(minimal({
      query = function()
        error('the daemon is down')
      end,
      hooks = {
        events = {
          ask = function()
            error('bad rule')
          end,
        },
      },
    }))
    hk.event('demo', 'one', 'ask')
    local good, err = pcall(store().refresh_sync)
    ok(good, tostring(err))
    eq('working', store().get('demo:one').status)
  end)

  it('has its title re-read when it says something outside the transcript changed', function()
    fx.home()
    local title, parses = 'First name', 0
    require('agent-chats').register(minimal({
      rev = function()
        return title
      end,
      parse = function()
        parses = parses + 1
        return { title = title, turn = 'done', updated = os.time() - 20 }
      end,
    }))
    store().refresh_sync()
    store().refresh_sync()
    eq(1, parses)
    title = 'Second name'
    store().refresh_sync()
    eq(2, parses)
    eq('Second name', store().get('demo:one').title)
  end)

  it('runs the example the README gives', function()
    fx.home()
    local home = T.tmpdir()
    local real_home = vim.env.HOME
    vim.env.HOME = home
    T.write(home .. '/.pal/chats/abc.jsonl', {
      vim.json.encode({ role = 'user', text = 'Tidy the changelog', cwd = '/work/notes' }),
      vim.json.encode({ role = 'assistant', text = 'Tidied.' }),
    })
    local chunk = assert(loadstring(readme_example('Adding another agent'), 'README example'))
    local good, err = pcall(chunk)
    vim.env.HOME = real_home
    ok(good, tostring(err))

    store().refresh_sync()
    local c = assert(store().get('pal:abc'))
    eq('Tidy the changelog', c.first_prompt)
    eq('Tidied.', c.last_reply)
    eq('/work/notes', c.cwd)
    eq('done', c.turn)
    local p = require('agent-chats.providers').get('pal')
    eq({ 'pal', '--resume', 'abc' }, p.resume_cmd(c))
    local messages = p.messages(c)
    eq({ 'user', 'Tidy the changelog' }, { messages[1].role, messages[1].text })
    -- And its hooks, as the README says they would be wired.
    local res = hk.run('pal', '', { args = { 'ask', 'abc' } })
    eq(0, res.code)
    store().refresh_sync({ full = false })
    eq('attention', store().get('pal:abc').status)
    local board = require('agent-chats.ui.board')
    store().start = function() end
    board.open()
    has(T.buf_text(board._state.buf), 'Tidy the changelog')
    board.close()
  end)
end)

describe('falling back', function()
  it('finds running Claude sessions by their processes when it keeps no registry', function()
    local home = fx.home()
    local chat = home:chat({ start = os.time() - 30 }):user('Go'):write()
    vim.fn.delete(home.dir .. '/sessions', 'd')
    local bin = T.tmpdir() .. '/claude'
    T.write(bin, '#!/bin/sh\nread _\n')
    vim.uv.fs_chmod(bin, 493)
    local job = vim.system({ bin, '--resume', chat.id }, { stdin = true })
    local proc = require('agent-chats.util.proc')
    T.wait(3000, function()
      local st = proc.stat(job.pid)
      return st ~= nil and st.comm == 'claude'
    end)
    store().refresh_sync()
    local c = store().get('claude:' .. chat.id)
    eq(true, c.live)
    eq(job.pid, c.pid)
    eq('working', c.status)
    job:kill(9)
    job:wait(2000)
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    eq(false, store().get('claude:' .. chat.id).live)
  end)

  it('asks Qwen itself only when its registry is not where it is looked for', function()
    local qx = require('helpers.qwen')
    local home = qx.home()
    local chat = home:chat({ start = os.time() - 30 })
    chat:user('Go'):write()
    local counter = home.root .. '/asked'
    local bin = home.root .. '/qwen'
    T.write(
      bin,
      ('#!/bin/sh\necho x >> %s\nprintf \'{"pid":%d,"sessionId":"%s","cwd":"/w","name":"named"}\\n\'\n'):format(
        counter,
        vim.uv.os_getpid(),
        chat.id
      )
    )
    vim.uv.fs_chmod(bin, 493)
    require('agent-chats.config').get().providers.qwen.cmd = { bin }

    store().refresh_sync()
    eq(0, vim.fn.filereadable(counter), 'the registry is there: no need to ask')
    eq(false, store().get('qwen:' .. chat.id).live)

    vim.fn.delete(home.dir .. '/sessions', 'd')
    store().reset()
    store().refresh_sync()
    local c = store().get('qwen:' .. chat.id)
    eq(true, c.live)
    eq(vim.uv.os_getpid(), c.pid)
    eq('named', c.name)
    store().refresh_sync({ full = false })
    eq(1, #vim.fn.readfile(counter), 'asked once, not on every refresh')
  end)

  it('compares Qwen with its own listing for :checkhealth', function()
    local qx = require('helpers.qwen')
    local home = qx.home()
    local qwen = require('agent-chats.providers.qwen')
    eq({}, qwen.check(), 'no command to ask')
    local bin = home.root .. '/qwen'
    T.write(bin, '#!/bin/sh\nexit 0\n')
    vim.uv.fs_chmod(bin, 493)
    require('agent-chats.config').get().providers.qwen.cmd = { bin }
    eq('ok', qwen.check()[1].level)
    T.write(
      bin,
      ('#!/bin/sh\nprintf \'{"pid":%d,"sessionId":"s1"}\\n\'\n'):format(vim.uv.os_getpid())
    )
    local lines = qwen.check()
    eq('warn', lines[1].level)
    has(lines[1].text, 'lists 1 running session')
  end)
end)

describe('a chat started by another chat', function()
  it('makes its parent say so when it is the one waiting', function()
    local qx = require('helpers.qwen')
    local home = qx.home()
    local parent = home:chat({ start = os.time() - 60 })
    parent:user('Split the work'):tool_call('agent', { prompt = 'do part one' }):write()
    local child = home:chat({ start = os.time() - 40 })
    child:parent(parent.id):user('do part one'):tool_call('run_shell_command', { command = 'make' })
    child:write()
    home:registry(vim.uv.os_getpid(), { sessionId = parent.id })
    home:registry(vim.uv.os_getpid(), { sessionId = child.id }, 'b')
    -- The parent's own turn began before anything it wrote: its hooks say
    -- "working", and a quiet tool call is not second-guessed.
    hk.event('qwen', parent.id, 'UserPromptSubmit', { t = os.time() - 61 })
    hk.event('qwen', child.id, 'PermissionRequest', { tool = 'run_shell_command' })
    store().refresh_sync()
    local p, c = store().get('qwen:' .. parent.id), store().get('qwen:' .. child.id)
    eq('attention', c.status)
    eq('attention', p.status)
    eq(c.key, p.through)
    eq(1, store().counts().attention, 'the nested chat is not counted twice')
    local display = require('agent-chats.display')
    -- Its summary says so, and what the nested chat is waiting for.
    local summary = table.concat(require('agent-chats.ui.preview').lines(p), '\n')
    has(summary, 'Needs you: a chat it started is waiting.')
    has(table.concat(display.waiting(p, store().get), '\n'), 'permission to use run_shell_command')

    hk.event('qwen', child.id, 'PostToolUse', { tool = 'run_shell_command' })
    store().refresh_sync({ full = false })
    p = store().get('qwen:' .. parent.id)
    eq('working', p.status)
    eq(nil, p.through)
  end)
end)
