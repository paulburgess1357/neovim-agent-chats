local T = require('helpers.harness')
local fx = require('helpers.claude')
local eq, ok, no = T.eq, T.ok, T.no

local function store()
  return require('agent-chats.store')
end

local function state()
  return require('agent-chats.state')
end

local function key(chat)
  return 'claude:' .. chat.id
end

--- A finished chat whose last activity is `age` seconds ago.
local function finished(home, age, opts)
  local chat = home:chat(vim.tbl_extend('force', { start = os.time() - age - 10 }, opts or {}))
  chat:user('Do the thing'):title('The thing'):assistant('Did the thing.'):turn_done()
  chat.ts = os.time() - age
  chat.lines[#chat.lines] = nil
  chat.ts = chat.ts - 1
  chat:turn_done()
  return chat:write()
end

describe('store statuses', function()
  it('does not call chats from before the first run unread', function()
    local home = fx.home()
    local chat = finished(home, 600)
    state().update(function(s)
      s.baseline = os.time()
    end)
    store().refresh_sync()
    eq('ended', store().get(key(chat)).status)
    eq({ attention = 0, working = 0, done = 0, idle = 0, ended = 1 }, store().counts())
  end)

  it('marks a turn that finished since you last looked as done, until read', function()
    local home = fx.home()
    local chat = finished(home, 5)
    state().update(function(s)
      s.baseline = os.time() - 60
    end)
    store().refresh_sync()
    eq('done', store().get(key(chat)).status)
    state().mark_seen(key(chat))
    store().touch()
    eq('ended', store().get(key(chat)).status)
    state().mark_unseen(key(chat))
    store().touch()
    eq('done', store().get(key(chat)).status)
  end)

  it('follows the registry of a running session', function()
    local home = fx.home()
    local chat = finished(home, 300)
    local pid = vim.uv.os_getpid()
    state().update(function(s)
      s.baseline = os.time()
    end)

    home:registry(pid, { sessionId = chat.id, status = 'busy', cwd = chat.cwd })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('working', c.status)
    ok(c.live)
    ok(c.exact)
    eq(pid, c.pid)

    home:registry(
      pid,
      { sessionId = chat.id, status = 'waiting', waitingFor = 'permission to run Bash' }
    )
    store().refresh_sync({ full = false })
    c = store().get(key(chat))
    eq('attention', c.status)
    no(c.inferred)
    eq('permission to run Bash', c.waiting_for)

    home:registry(pid, { sessionId = chat.id, status = 'idle' })
    store().refresh_sync({ full = false })
    eq('idle', store().get(key(chat)).status)
  end)

  it('treats a chat that stopped mid-turn with no process as ended', function()
    local home = fx.home()
    local chat = home:chat():user('Go'):tool_use('Bash', { command = 'make' }):write()
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('working', c.turn)
    eq(false, c.live)
    eq('ended', c.status)
  end)

  it('guesses "needs you" for a quiet tool call when the agent reports no state', function()
    local home = fx.home({ status = { stall_after = 30 } })
    local chat = home:chat({ start = os.time() - 120 })
    chat:user('Go'):tool_use('Bash', { command = 'rm -rf build' }):write()
    home:registry(vim.uv.os_getpid(), { sessionId = chat.id, status = 'not-a-known-status' })
    store().refresh_sync()
    local c = store().get(key(chat))
    eq('attention', c.status)
    ok(c.inferred)
    no(c.exact)

    -- Fresh activity is just work.
    chat.ts = os.time() - 2
    chat:tool_result('ok'):tool_use('Bash', { command = 'make' }):write()
    store().refresh_sync({ full = false })
    c = store().get(key(chat))
    eq('working', c.status)
    no(c.inferred)
  end)

  it('keeps a session live through one missed look', function()
    local home = fx.home()
    local chat = finished(home, 300)
    local pid = vim.uv.os_getpid()
    home:registry(pid, { sessionId = chat.id, status = 'busy' })
    store().refresh_sync()
    eq('working', store().get(key(chat)).status)
    home:unregister(pid)
    store().refresh_sync({ full = false })
    eq(true, store().get(key(chat)).live)
    store().refresh_sync({ full = false })
    eq(false, store().get(key(chat)).live)
  end)
end)

describe('store index', function()
  it('shows a running session that has no transcript yet, then adopts the transcript', function()
    local home = fx.home()
    local pid = vim.uv.os_getpid()
    local rec = home:registry(pid, { status = 'idle', cwd = '/work/fresh', name = 'fresh-1a' })
    store().refresh_sync()
    local c = store().get('claude:' .. rec.sessionId)
    ok(c and c.stub)
    eq('idle', c.status)
    eq('/work/fresh', c.cwd)
    eq('fresh-1a', require('agent-chats.display').title(c))

    home:chat({ id = rec.sessionId, cwd = '/work/fresh' }):user('First prompt'):write()
    home:registry(pid, { sessionId = rec.sessionId, status = 'busy', cwd = '/work/fresh' })
    store().refresh_sync({ full = false })
    c = store().get('claude:' .. rec.sessionId)
    no(c.stub)
    eq('First prompt', c.first_prompt)
    eq('working', c.status)

    home:unregister(pid)
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    eq('ended', store().get('claude:' .. rec.sessionId).status)
  end)

  it('drops a stub when its process goes away', function()
    local home = fx.home()
    local pid = vim.uv.os_getpid()
    local rec = home:registry(pid, { status = 'idle' })
    store().refresh_sync()
    ok(store().get('claude:' .. rec.sessionId))
    home:unregister(pid)
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    eq(nil, store().get('claude:' .. rec.sessionId))
  end)

  it('re-parses only what changed and picks up new and deleted chats on a full refresh', function()
    local home = fx.home()
    local a = finished(home, 100)
    local b = finished(home, 200)
    store().refresh_sync()
    local first = store().get(key(a))
    store().refresh_sync()
    ok(first == store().get(key(a)), 'an unchanged chat keeps its table')

    a.ts = os.time() - 1
    a:user('More'):write()
    local c = finished(home, 50)
    vim.fn.delete(b.path)
    store().refresh_sync()
    eq('More', store().get(key(a)).last_prompt)
    ok(store().get(key(c)))
    eq(nil, store().get(key(b)))
  end)

  it('leaves chats older than max_age_days unread until asked', function()
    local home = fx.home({ board = { max_age_days = 7 } })
    local recent = finished(home, 3600)
    local old = finished(home, 30 * 86400)
    store().refresh_sync()
    ok(store().get(key(recent)))
    eq(nil, store().get(key(old)))
    eq(1, store().older)

    store().show_all = true
    store().refresh_sync()
    ok(store().get(key(old)))
    eq(0, store().older)
  end)

  it('always reads a pinned chat, however old', function()
    local home = fx.home({ board = { max_age_days = 7 } })
    local old = finished(home, 30 * 86400)
    state().toggle_pin(key(old))
    store().refresh_sync()
    ok(store().get(key(old)))
    eq(0, store().older)
  end)

  it('hides archived chats until they move again', function()
    local home = fx.home()
    local chat = finished(home, 100)
    store().refresh_sync()
    eq(1, #store().list())
    ok(state().toggle_archive(key(chat), store().get(key(chat)).updated))
    eq(0, #store().list())
    eq(1, #store().list({ archived = true }))
    eq(0, store().counts().ended)

    chat.ts = os.time() + 5
    chat:user('Wake up'):write()
    store().refresh_sync()
    eq(1, #store().list())
  end)

  it('lists subagents as children of their chat', function()
    local home = fx.home()
    local chat = finished(home, 100)
    chat:subagent('aaa111', { agentType = 'Explore', description = 'Find files', finished = true })
    store().refresh_sync()
    local subs = store().children(key(chat))
    eq(1, #subs)
    eq('Find files', subs[1].title)
    eq('ended', subs[1].status)
    eq(subs[1], store().get(subs[1].key))
    eq(1, #store().list(), 'subagents are not top-level chats')
  end)

  it('survives a provider that throws', function()
    local home = fx.home()
    finished(home, 100)
    local claude = require('agent-chats.providers.claude')
    local real = claude.live
    claude.live = function()
      error('boom')
    end
    local good, err = pcall(store().refresh_sync)
    claude.live = real
    ok(good, tostring(err))
    eq(1, #store().list())
  end)

  it('restores parsed chats from its cache', function()
    local home = fx.home()
    local cache = home.root .. '/index.json'
    require('agent-chats.config').get().cache_file = cache
    local chat = finished(home, 100)
    store().refresh_sync()
    store().flush()
    ok(vim.uv.fs_stat(cache))

    store().reset()
    local claude = require('agent-chats.providers.claude')
    local real, parses = claude.parse, 0
    claude.parse = function(...)
      parses = parses + 1
      return real(...)
    end
    store().refresh_sync()
    claude.parse = real
    eq(0, parses, 'an unchanged chat is not parsed again')
    eq('The thing', store().get(key(chat)).title)
    eq('ended', store().get(key(chat)).status)
  end)
end)

describe('store events', function()
  it('announces status changes it watched happen', function()
    local home = fx.home()
    local chat = home:chat({ start = os.time() - 30 }):user('Go'):write()
    local pid = vim.uv.os_getpid()
    home:registry(pid, { sessionId = chat.id, status = 'busy' })
    local events, updates = {}, 0
    store().on(function(ev)
      if ev.type == 'transition' then
        events[#events + 1] = ('%s>%s'):format(tostring(ev.from), ev.to)
      else
        updates = updates + 1
      end
    end)
    store().refresh_sync()
    eq({}, events, 'the first look announces nothing')
    eq(1, updates)

    chat.ts = os.time()
    chat:assistant('Done.'):turn_done():write()
    home:registry(pid, { sessionId = chat.id, status = 'idle' })
    store().refresh_sync({ full = false })
    eq({ 'working>done' }, events)

    store().refresh_sync({ full = false })
    eq({ 'working>done' }, events, 'nothing new, nothing announced')
  end)

  it('notifies for attention and done, respecting the options', function()
    local home = fx.home({ notify = { enabled = true } })
    local notify = require('agent-chats.notify')
    local seen = {}
    local real = vim.notify
    vim.notify = function(msg, level)
      seen[#seen + 1] = { msg = msg, level = level }
    end
    local chat = {
      key = 'claude:x',
      provider = 'claude',
      id = 'x',
      title = 'Ship it',
      cwd = '/work/alpha',
      status = 'attention',
      waiting_for = 'permission',
    }
    local ev = notify.handle({ chat = chat, from = 'working', to = 'attention', fresh = true })
    ok(ev)
    eq('attention', ev.kind)
    T.has(seen[1].msg, 'Needs you: Ship it')
    T.has(seen[1].msg, 'permission')
    eq(vim.log.levels.WARN, seen[1].level)

    eq(nil, notify.handle({ chat = chat, from = 'working', to = 'attention', fresh = false }))
    eq(nil, notify.handle({ chat = chat, from = 'working', to = 'idle', fresh = true }))
    chat.inferred = true
    require('agent-chats.config').get().notify.inferred = false
    eq(nil, notify.handle({ chat = chat, from = 'working', to = 'attention', fresh = true }))

    chat.inferred = nil
    require('agent-chats.config').get().notify.handler = function()
      return true
    end
    local count = #seen
    ok(notify.handle({ chat = chat, from = 'working', to = 'done', fresh = true }))
    eq(count, #seen, 'a handler that returns true replaces the default')
    vim.notify = real
    no(home == nil)
  end)
end)

describe('state', function()
  it('persists and shares changes through the file', function()
    fx.home()
    local s = state()
    s.mark_seen('claude:a', 123)
    eq(true, s.toggle_pin('claude:a'))
    s.set_labels('claude:a', { 'review', 'urgent' })
    s.set_note('claude:a', 'waiting on CI')
    s.set_name('claude:a', 'My chat')
    s.enqueue('claude:a', 'first')
    s.enqueue('claude:a', 'second')
    s.set_collapsed('ended', true)

    s.reset()
    eq(123, s.seen('claude:a'))
    ok(s.pinned('claude:a'))
    eq({ 'review', 'urgent' }, s.labels('claude:a'))
    eq('waiting on CI', s.note('claude:a'))
    eq('My chat', s.name('claude:a'))
    eq('first', s.dequeue('claude:a').text)
    eq(1, #s.queue('claude:a'))
    ok(s.collapsed('ended'))

    eq(false, s.toggle_pin('claude:a'))
    s.set_note('claude:a', '')
    eq(nil, s.note('claude:a'))
    eq(s.get().baseline, s.seen('claude:never-seen'))
  end)

  it('recovers from a corrupt file and a stale lock', function()
    fx.home()
    local s = state()
    T.write(s.path(), '{ not json')
    T.write(s.path() .. '.lock', '')
    T.touch(s.path() .. '.lock', os.time() - 60)
    s.reset()
    s.mark_seen('claude:a', 5)
    eq(5, s.seen('claude:a'))
    eq(nil, vim.uv.fs_stat(s.path() .. '.lock'))
  end)
end)
