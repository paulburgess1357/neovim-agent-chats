-- One test per bug found in review, so none of them comes back.

local T = require('helpers.harness')
local fx = require('helpers.claude')
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

local function chat(home, opts)
  opts = opts or {}
  local age = opts.age or 600
  local c = home:chat({ cwd = opts.cwd or '/work/alpha', start = os.time() - age - 5 })
  c:user(opts.prompt or 'Please fix the parser'):title(opts.title or 'Fix the parser')
  c:assistant(opts.reply or 'The parser is fixed.'):turn_done()
  return c:write(os.time() - age)
end

local function key(c)
  return 'claude:' .. c.id
end

local function list()
  return T.buf_text(board()._state.buf)
end

local function seen_everything()
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
end

after_each(function()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
  -- A test may have shrunk the time slice.
  require('agent-chats.util.async').slice_ms = 8
end)

describe('regressions', function()
  it('renders and counts while a refresh is still running', function()
    local home = fx.home({ board = { spinner = false } })
    for i = 1, 40 do
      chat(home, { title = 'Chat ' .. i, age = i * 30 })
    end
    require('agent-chats.util.async').slice_ms = 0
    local done = false
    store().refresh({ full = true }, function()
      done = true
    end)
    no(done, 'the refresh is suspended mid-way')
    -- Everything a user or a statusline can do meanwhile must hold up.
    eq('', require('agent-chats').statusline())
    store().start = function() end
    board().open()
    board().set_group('folder')
    board().set_group('status')
    T.wait(5000, function()
      return done
    end)
    has(list(), 'Chat 1')
  end)

  it('starts on a chat when the board opens before the first refresh ends', function()
    local home = fx.home({ board = { spinner = false } })
    chat(home)
    store().start = function()
      store().refresh({ full = true })
    end
    board().open()
    T.wait(3000, function()
      return store().initialized and board().current() ~= nil
    end)
    eq('chat', board().row().kind)
  end)

  it('applies max_age_days again after "show all" is switched off', function()
    local home = fx.home({ board = { max_age_days = 7 } })
    chat(home, { title = 'Recent one', age = 3600 })
    local old = chat(home, { title = 'Ancient one', age = 90 * 86400 })
    store().refresh_sync()
    eq(nil, store().get(key(old)))
    store().show_all = true
    store().refresh_sync()
    ok(store().get(key(old)))
    store().show_all = false
    store().refresh_sync()
    eq(nil, store().get(key(old)))
    eq(1, store().older)
  end)

  it('does not bring chats past the age limit back from the cache', function()
    local home = fx.home({ board = { max_age_days = 7 } })
    require('agent-chats.config').get().cache_file = home.root .. '/index.json'
    local old = chat(home, { title = 'Ancient one', age = 90 * 86400 })
    store().show_all = true
    store().refresh_sync()
    store().flush()
    store().reset()
    store().refresh_sync()
    eq(nil, store().get(key(old)))
    eq(0, #store().list())
  end)

  it('moves a terminal to the chat its agent switched to', function()
    local home = fx.home({ board = { spinner = false } })
    local x = chat(home, { title = 'Chat X', cwd = vim.uv.cwd() })
    local y = chat(home, { title = 'Chat Y', cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    board().open()
    local buf = actions().open(store().get(key(x)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    local pid
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      pid = store().get(key(x)).pid
      return pid ~= nil
    end)
    -- Inside the agent the user resumes Y: same process, another session.
    home:registry(pid, { sessionId = y.id, status = 'idle', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    eq(buf, store().get(key(y)).term)
    eq(nil, store().get(key(x)).term)
    eq(nil, require('agent-chats.term').find(store().get(key(x))))
  end)

  it('emits no update when nothing changed, and leaves the pane where you scrolled it', function()
    local home = fx.home({ board = { spinner = false } })
    local long = {}
    for i = 1, 80 do
      long[i] = 'reply line ' .. i
    end
    local c = chat(home, { reply = table.concat(long, '\n') })
    c:subagent('aaa111')
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'idle' })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    board().goto_chat(key(c))
    local pane = board()._state.pane_win
    api.nvim_win_set_cursor(pane, { 40, 0 })
    local updates = 0
    store().on(function(ev)
      if ev.type == 'update' then
        updates = updates + 1
      end
    end)
    for _ = 1, 3 do
      store().refresh_sync({ full = false })
    end
    eq(0, updates)
    board().render()
    eq(40, api.nvim_win_get_cursor(pane)[1])
  end)

  it('marks a chat read when its conversation is opened', function()
    local home = fx.home({ board = { spinner = false } })
    local a = chat(home, { title = 'External one', age = 30 })
    local b = chat(home, { title = 'Second one', age = 20 })
    state().update(function(s)
      s.baseline = os.time() - 300
    end)
    home:registry(vim.uv.os_getpid(), { sessionId = a.id, status = 'idle' })
    store().refresh_sync()
    store().start = function() end
    eq('done', store().get(key(a)).status)
    eq(2, #actions().waiting())
    actions().next()
    eq('idle', store().get(key(a)).status)
    eq(1, #actions().waiting())
    eq(key(b), actions().waiting()[1].key)
  end)

  it('refuses to queue for a chat that runs elsewhere', function()
    local home = fx.home()
    local c = home:chat({ start = os.time() - 30 }):user('Go'):write()
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'busy' })
    store().refresh_sync()
    actions().queue(store().get(key(c)))
    no(require('agent-chats.ui.input').is_open())
    eq(0, #state().queue(key(c)))
  end)

  it('keeps a reply queued for a chat that ended, and sends it only when asked', function()
    local home = fx.home({ reply = { ended = 'background' } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    local agent = fake.install(home)
    state().enqueue(key(c), 'left over from last time')
    seen_everything()
    store().refresh_sync()
    -- Nothing starts an agent by itself: not the sweep, not time passing.
    require('agent-chats.queue').sweep()
    vim.wait(300)
    eq('', agent.read())
    eq(1, #state().queue(key(c)))

    -- Q on the chat offers to send it.
    local real = vim.ui.select
    vim.ui.select = function(items, _, cb)
      cb(vim.tbl_contains(items, 'send') and 'send' or nil)
    end
    actions().queue(store().get(key(c)))
    vim.ui.select = real
    T.wait(3000, function()
      return agent.read():find('left over from last time', 1, true) ~= nil
    end)
    eq(0, #state().queue(key(c)))
  end)

  it('does not announce a chat you marked unread yourself', function()
    local home = fx.home({ notify = { enabled = true } })
    local c = chat(home)
    seen_everything()
    store().refresh_sync()
    require('agent-chats.notify').setup()
    local said, fired = {}, 0
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    local au = api.nvim_create_autocmd('User', {
      pattern = 'AgentChatsDone',
      callback = function()
        fired = fired + 1
      end,
    })
    actions().toggle_unread(store().get(key(c)))
    vim.notify = real
    api.nvim_del_autocmd(au)
    eq('done', store().get(key(c)).status)
    eq({}, said)
    eq(0, fired)
  end)

  it('fires its events even with notifications switched off', function()
    fx.home({ notify = { enabled = false } })
    local fired
    local au = api.nvim_create_autocmd('User', {
      pattern = 'AgentChatsAttention',
      callback = function(ev)
        fired = ev.data.key
      end,
    })
    local c = { key = 'claude:x', provider = 'claude', id = 'x', title = 'T', status = 'attention' }
    eq(
      nil,
      require('agent-chats.notify').handle({
        chat = c,
        from = 'working',
        to = 'attention',
        fresh = true,
      })
    )
    api.nvim_del_autocmd(au)
    eq('claude:x', fired)
  end)

  it('leaves you where you are when an agent exits in another tab', function()
    local home = fx.home({ board = { spinner = false }, open = { where = 'tab' } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    board().open()
    local buf = actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    vim.cmd('tabnew')
    local mine = api.nvim_get_current_win()
    require('agent-chats.term').send(buf, '/exit')
    T.wait(3000, function()
      return not api.nvim_buf_is_valid(buf)
    end)
    vim.wait(100)
    eq(mine, api.nvim_get_current_win())
  end)

  it('maps the way back in a terminal it did not start', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    -- Started by hand in a plain terminal.
    vim.cmd('enew')
    local buf = api.nvim_get_current_buf()
    vim.fn.jobstart({ agent.bin, '--resume', c.id }, { term = true })
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(c)).term == buf
    end)
    board().open()
    board().goto_chat(key(c))
    board().render()
    eq(buf, api.nvim_win_get_buf(board()._state.pane_win))
    ok(vim.b[buf].agent_chats_back)
  end)

  it('does not reuse a window that now shows a file', function()
    local home = fx.home({ board = { spinner = false }, open = { where = 'vsplit' } })
    local a = chat(home, { cwd = vim.uv.cwd() })
    local b = chat(home, { cwd = vim.uv.cwd(), title = 'Other' })
    seen_everything()
    store().refresh_sync()
    local agent = fake.install(home)
    actions().open(store().get(key(a)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    local win = api.nvim_get_current_win()
    vim.cmd('stopinsert')
    vim.cmd('enew')
    local file = api.nvim_get_current_buf()
    actions().open(store().get(key(b)))
    eq(file, api.nvim_win_get_buf(win))
  end)

  it('counts search matches only in the chats it shows', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { reply = 'mentions the zebra' })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    state().toggle_archive(key(c), store().get(key(c)).updated)
    board().open()
    hasnt(list(), 'Fix the parser')
    board().set_search({
      query = 'zebra',
      hits = {
        [key(c)] = { { index = 2, role = 'assistant', excerpt = 'mentions the zebra' } },
        -- A chat the index no longer has: none of it is on the board.
        ['claude:gone'] = {
          { index = 1, role = 'user', excerpt = 'a zebra here' },
          { index = 2, role = 'assistant', excerpt = 'and a zebra there' },
        },
      },
      running = false,
    })
    -- An archived chat is out of sight on the plain board; a search looks
    -- everywhere, shows it, and says that it is archived.
    has(list(), '1 chat · 1 passage')
    has(list(), 'Fix the parser archived')
    hasnt(list(), 'a zebra here')
  end)

  it('restores the window it borrowed in the "current" layout', function()
    local home = fx.home({ board = { spinner = false, layout = 'current', pane = false } })
    chat(home)
    store().refresh_sync()
    store().start = function() end
    vim.wo.number, vim.wo.wrap, vim.wo.signcolumn = true, true, 'yes'
    local win = api.nvim_get_current_win()
    board().open()
    eq(false, vim.wo[win].number)
    board().close()
    eq({ true, true, 'yes' }, { vim.wo[win].number, vim.wo[win].wrap, vim.wo[win].signcolumn })
    vim.wo.number, vim.wo.signcolumn = false, 'auto'
  end)

  it('opens as a float without a pane when the screen is too narrow for both', function()
    local home = fx.home({ board = { spinner = false, layout = 'float', width = 30 } })
    chat(home)
    store().refresh_sync()
    store().start = function() end
    board().open()
    ok(board().is_open())
    eq(nil, board()._state.pane_win)
    has(list(), 'Fix')
  end)

  it('accepts false as a way to switch an agent off', function()
    local cfg = require('agent-chats.config').setup({ providers = { codex = false } })
    eq(false, cfg.providers.codex.enabled)
    eq({ 'codex' }, cfg.providers.codex.cmd)
  end)

  it('shows a Codex chat under its new name without waiting for it to move', function()
    local cx = require('helpers.codex')
    local home = cx.home()
    local r = home:rollout({ start = os.time() - 5000 }):meta():task_started()
    r:item_user('hi'):task_complete('done'):write(os.time() - 4000)
    home:index(r.id, 'First name')
    store().refresh_sync()
    eq('First name', store().get('codex:' .. r.id).title)
    -- A rename touches the index of titles and nothing else.
    home:index(r.id, 'Second name')
    store().refresh_sync()
    eq('Second name', store().get('codex:' .. r.id).title)
    local parses, codex = 0, require('agent-chats.providers.codex')
    local real = codex.parse
    codex.parse = function(...)
      parses = parses + 1
      return real(...)
    end
    store().refresh_sync()
    codex.parse = real
    eq(0, parses, 'and it is not read again for nothing')
  end)

  it('hands out the next queued reply only when the one before it has arrived', function()
    fx.home()
    local s = state()
    s.enqueue('claude:a', 'first')
    s.enqueue('claude:a', 'second')
    s.enqueue('claude:b', 'other chat')
    eq('first', s.dequeue('claude:a').text)
    -- A second Neovim looking at the same chat at this moment gets nothing.
    eq(nil, s.dequeue('claude:a'))
    eq(1, #s.queue('claude:a'))
    eq('other chat', s.dequeue('claude:b').text, 'other chats are not held up')
    s.sent('claude:a')
    eq('second', s.dequeue('claude:a').text)
    -- A reply that could not be delivered goes back and frees the chat.
    s.requeue('claude:a', { text = 'second', at = os.time() })
    eq('second', s.dequeue('claude:a').text)
  end)

  --- Open `c` in a terminal of this Neovim, running the stand-in agent.
  local function hosted(home, c)
    local agent = fake.install(home)
    store().start = function() end
    board().open()
    local buf = actions().open(store().get(key(c)))
    -- Until the agent has registered itself: its process is then known.
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local now = store().get(key(c))
      return now.term == buf and now.pid ~= nil
    end)
    vim.cmd('stopinsert')
    return agent, buf
  end

  it('types queued replies in one after the other, each after the turn before it', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent = hosted(home, c)
    state().enqueue(key(c), 'reply number one')
    state().enqueue(key(c), 'reply number two')
    local queue = require('agent-chats.queue')
    queue.sweep()
    T.wait(3000, function()
      return agent.read():find('input: reply number one', 1, true) ~= nil
    end)
    -- The first is on its way: the second waits, however often it is looked at.
    queue.sweep()
    vim.wait(300)
    queue.sweep()
    eq(1, #state().queue(key(c)))
    hasnt(agent.read(), 'reply number two')

    -- The agent answers it in a turn shorter than the time between two
    -- looks: nobody ever sees the chat busy.
    c.ts = os.time() + 1
    c:user('reply number one'):assistant('Did that.'):turn_done():write()
    store().refresh_sync({ full = false })
    queue.sweep()
    T.wait(3000, function()
      return agent.read():find('input: reply number two', 1, true) ~= nil
    end)
    eq(0, #state().queue(key(c)))
  end)

  it(
    "sends the next queued reply when only the agent's own record shows the turn came and went",
    function()
      local home = fx.home({ board = { spinner = false } })
      local c = chat(home, { cwd = vim.uv.cwd() })
      seen_everything()
      store().refresh_sync()
      local agent = hosted(home, c)
      require('agent-chats.queue').setup()
      local pid = store().get(key(c)).pid
      local function registry(status)
        -- To the millisecond, as the agent writes it.
        local sec, usec = vim.uv.gettimeofday()
        home:registry(pid, {
          sessionId = c.id,
          status = status,
          cwd = vim.uv.cwd(),
          statusUpdatedAt = sec * 1000 + math.floor(usec / 1000),
        })
      end
      registry('busy')
      store().refresh_sync({ full = false })
      state().enqueue(key(c), 'first queued reply')
      state().enqueue(key(c), 'second queued reply')
      registry('idle')
      store().refresh_sync({ full = false })
      T.wait(4000, function()
        return agent.read():find('input: first queued reply', 1, true) ~= nil
      end)
      eq(1, #state().queue(key(c)))
      -- The agent takes it, works and is idle again, all between two looks.
      -- Nothing is written to the transcript in that time.
      vim.wait(20)
      registry('busy')
      registry('idle')
      store().refresh_sync({ full = false })
      T.wait(4000, function()
        return agent.read():find('input: second queued reply', 1, true) ~= nil
      end)
      eq(0, #state().queue(key(c)))
    end
  )

  it('sends a reply at once when the turn ended while it was being written', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    local pid = store().get(key(c)).pid
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    eq('working', store().get(key(c)).status)
    require('agent-chats.ui.board').focus()
    actions().queue(store().get(key(c)))
    local input = require('agent-chats.ui.input')
    ok(input.is_open())
    -- The turn ends while the box is open.
    home:registry(pid, { sessionId = c.id, status = 'idle', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    api.nvim_buf_set_lines(api.nvim_get_current_buf(), 0, -1, false, { 'and now the tests' })
    input.submit()
    T.wait(3000, function()
      return agent.read():find('input: and now the tests', 1, true) ~= nil
    end)
    eq(0, #state().queue(key(c)))
    ok(api.nvim_buf_is_valid(buf))
  end)

  it('does not start the agent again when it was quit with a reply queued', function()
    local home = fx.home({ board = { spinner = false }, reply = { ended = 'background' } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    require('agent-chats.queue').setup()
    local pid = store().get(key(c)).pid
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    state().enqueue(key(c), 'then delete the old branch')
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    require('agent-chats.term').send(buf, '/exit')
    T.wait(3000, function()
      return not api.nvim_buf_is_valid(buf)
    end)
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    vim.wait(900)
    vim.notify = real
    -- Once, by you; never again by itself.
    local _, starts = agent.read():gsub('argv:', '')
    eq(1, starts)
    eq(1, #state().queue(key(c)), 'the reply is kept')
    has(table.concat(said, '\n'), 'ended with 1 reply still queued')

    -- And it can be dropped.
    local real_select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb('drop_all')
    end
    actions().queue(store().get(key(c)))
    vim.ui.select = real_select
    eq(0, #state().queue(key(c)))
  end)

  it('keeps what you wrote when a reply is not sent after all', function()
    local home = fx.home({ reply = { ended = 'ask' } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    local agent = fake.install(home)
    seen_everything()
    store().refresh_sync()
    local input = require('agent-chats.ui.input')
    local real_select = vim.ui.select
    -- Written, sent, then the question of how to send is dismissed.
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    actions().queue(store().get(key(c)))
    api.nvim_buf_set_lines(
      api.nvim_get_current_buf(),
      0,
      -1,
      false,
      { 'first paragraph', '', 'second' }
    )
    input.submit()
    eq('', agent.read())
    actions().queue(store().get(key(c)))
    eq('first paragraph\n\nsecond', T.buf_text(api.nvim_get_current_buf()))
    -- Written, then the box is left without sending.
    api.nvim_buf_set_lines(api.nvim_get_current_buf(), 0, -1, false, { 'changed my mind halfway' })
    input.cancel()
    actions().queue(store().get(key(c)))
    eq('changed my mind halfway', T.buf_text(api.nvim_get_current_buf()))
    -- Sent for real: nothing is kept.
    vim.ui.select = function(items, _, cb)
      cb(items[2])
    end
    input.submit()
    T.wait(3000, function()
      return agent.read():find('changed my mind halfway', 1, true) ~= nil
    end)
    vim.ui.select = real_select
    actions().queue(store().get(key(c)))
    eq('', T.buf_text(api.nvim_get_current_buf()))
    input.cancel()
  end)

  it('does not type into a chat that is showing a question of its own', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    local pid = store().get(key(c)).pid
    home:registry(pid, {
      sessionId = c.id,
      status = 'waiting',
      waitingFor = 'permission to use Bash',
      cwd = vim.uv.cwd(),
    })
    store().refresh_sync({ full = false })
    eq('attention', store().get(key(c)).status)
    require('agent-chats.ui.board').focus()
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    -- (Whatever sends at once: a selection sent with :Chats send, a queued
    -- reply that is sent by hand.)
    local sent
    actions().deliver(store().get(key(c)), 'and the docs too', nil, function(done)
      sent = done
    end)
    vim.notify = real
    eq(false, sent)
    has(table.concat(said, '\n'), 'waiting for your answer (permission to use Bash)')
    eq(buf, api.nvim_get_current_buf(), 'the cursor is in the chat instead')
    hasnt(agent.read(), 'input:')
  end)

  it('keeps a copy of an unreadable state file before starting over', function()
    fx.home()
    local s = state()
    T.write(s.path(), '{ definitely not json')
    s.reset()
    s.mark_seen('claude:a', 5)
    ok(vim.uv.fs_stat(s.path() .. '.corrupt'))
  end)
end)

-- Found by the review of the status sources (hooks, the index, the queue).
describe('regressions: status', function()
  local hk = require('helpers.hooks')

  --- A provider with only what the contract requires.
  local function minimal(extra)
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
        return { { id = 'one', mtime = os.time() - 20, size = 1 } }
      end,
      parse = function()
        return { title = 'A demo chat', turn = 'working', updated = os.time() - 20 }
      end,
      messages = function()
        return {}, nil
      end,
      resume_cmd = function(c)
        return { 'demo', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    }, extra or {})
  end

  after_each(function()
    require('agent-chats.providers').reset()
  end)

  it('keeps an opencode subagent that asks for permission waiting, look after look', function()
    local ox = require('helpers.opencode')
    local home = ox.home()
    local dir = T.tmpdir()
    local parent = home:session({ directory = dir, title = 'Parent chat', start = os.time() - 60 })
    parent:user('split the work'):assistant():tool('task', { status = 'running', input = {} })
    local child = home:session({ directory = dir, parent = parent.id, start = os.time() - 40 })
    child
      :user('part one')
      :assistant()
      :tool('bash', { status = 'running', input = { command = 'make' } })
    local job = ox.spawn(dir, { '-s', parent.id })
    hk.event('opencode', parent.id, 'session.status', { type = 'busy', t = os.time() - 60 })
    hk.event('opencode', child.id, 'session.status', { type = 'busy', t = os.time() - 40 })
    hk.event('opencode', child.id, 'permission.asked', { req = 'per_1', tool = 'bash' })
    local announced = 0
    store().on(function(ev)
      if ev.type == 'transition' and ev.to == 'attention' and ev.chat.id == parent.id then
        announced = announced + 1
      end
    end)
    local seen = {}
    for i = 1, 6 do
      store().refresh_sync({ full = i == 1 })
      seen[i] = store().get('opencode:' .. child.id).status
        .. '/'
        .. store().get('opencode:' .. parent.id).status
    end
    ox.kill(job)
    for i = 1, 6 do
      eq('attention/attention', seen[i], 'look ' .. i)
    end
    ok(announced <= 1, 'one request, one announcement')
  end)

  it('ends a chat known only through hooks when its process is gone', function()
    fx.home()
    require('agent-chats').register(minimal({
      hooks = { events = { ask = 'waiting' }, process = { sleep = true } },
    }))
    local sleeper = vim.system({ 'sleep', '30' })
    hk.event('demo', 'one', 'ask', { tool = 'shell', pid = sleeper.pid })
    store().refresh_sync()
    eq('attention', store().get('demo:one').status)
    eq(true, store().get('demo:one').live)
    sleeper:kill(9)
    sleeper:wait(2000)
    store().refresh_sync({ full = false })
    store().refresh_sync({ full = false })
    local c = store().get('demo:one')
    eq(false, c.live)
    eq('ended', c.status)
  end)

  it('says "needs you" at the top of a family three deep, whatever the ids', function()
    for round = 1, 12 do
      fx.home()
      local ids = {
        top = 'top' .. round,
        mid = ('%x'):format(round * 7919) .. 'mid',
        low = 'low' .. (97 - round),
      }
      require('agent-chats').register(minimal({
        hooks = { events = { ask = 'waiting' } },
        discover = function()
          return {
            { id = ids.top, mtime = os.time() - 20, size = 1 },
            { id = ids.mid, mtime = os.time() - 20, size = 1 },
            { id = ids.low, mtime = os.time() - 20, size = 1 },
          }
        end,
        parse = function(entry)
          return {
            title = entry.id,
            turn = 'working',
            updated = os.time() - 20,
            parent_id = entry.id == ids.low and ids.mid or (entry.id == ids.mid and ids.top or nil),
          }
        end,
      }))
      hk.event('demo', ids.low, 'ask', { tool = 'shell' })
      store().refresh_sync()
      eq('attention', store().get('demo:' .. ids.top).status, 'round ' .. round)
      eq('demo:' .. ids.low, store().get('demo:' .. ids.top).through, 'round ' .. round)
      require('agent-chats.providers').reset()
    end
  end)

  it('goes back to guessing when the hooks stopped reporting some turn ago', function()
    local qx = require('helpers.qwen')
    local home = qx.home({ status = { stall_after = 30 } })
    local chat = home:chat({ start = os.time() - 1000 })
    chat:turn('First thing', 'Done.')
    chat.ts = os.time() - 200
    chat:user('Second thing'):tool_call('run_shell_command', { command = 'make' })
    chat:write()
    home:registry(vim.uv.os_getpid(), { sessionId = chat.id })
    -- The only word from the hooks is from the turn before.
    hk.event('qwen', chat.id, 'UserPromptSubmit', { t = os.time() - 999 })
    store().refresh_sync()
    local c = store().get('qwen:' .. chat.id)
    eq('transcript', c.source)
    eq('attention', c.status)
    ok(c.inferred)
  end)

  it('does not take a stray "running" for a turn when the transcript shows it over', function()
    local home = fx.home()
    local chat = home:chat({ start = os.time() - 100 }):user('Go')
    chat.ts = os.time() - 60
    chat:interrupt():write()
    home:registry(vim.uv.os_getpid(), { sessionId = chat.id, status = 'not-a-known-status' })
    -- A tool reporting in after the interrupt, with nothing written since.
    hk.event('claude', chat.id, 'PostToolUse', { t = os.time() - 50, tool = 'Bash' })
    store().refresh_sync()
    local c = store().get('claude:' .. chat.id)
    eq('aborted', c.turn)
    eq('transcript', c.source)
  end)

  it('treats a tool cut short by an interrupt as the turn being interrupted', function()
    local ev = require('agent-chats.events')
    for _, name in ipairs({ 'claude', 'qwen' }) do
      local rules = require('agent-chats.providers.' .. name).hooks.events
      local r = ev._fold(rules, {
        { t = 1000, e = 'UserPromptSubmit' },
        { t = 1010, e = 'PostToolUseFailure', tool = 'Bash', interrupt = true },
      })
      eq('aborted', r.turn, name)
      eq(
        'working',
        ev._fold(rules, {
          { t = 1000, e = 'UserPromptSubmit' },
          { t = 1010, e = 'PostToolUseFailure', tool = 'Bash' },
        }).turn,
        name
      )
    end
    -- And the script writes that down.
    fx.home()
    hk.run(
      'qwen',
      '{"session_id":"s-int","hook_event_name":"PostToolUseFailure","tool_name":"x","tool_input":{},"error":"cancelled","is_interrupt":true}'
    )
    eq(true, hk.lines('qwen', 's-int')[1].interrupt)
  end)

  it('does not call a session that was only just started "done, unread"', function()
    local home = fx.home()
    state().update(function(s)
      s.baseline = os.time() - 600
    end)
    local events = {}
    store().on(function(ev)
      if ev.type == 'transition' then
        events[#events + 1] = ev.to
      end
    end)
    store().refresh_sync()
    local rec = home:registry(vim.uv.os_getpid(), { status = 'idle', startedAt = os.time() * 1000 })
    store().refresh_sync({ full = false })
    local c = store().get('claude:' .. rec.sessionId)
    ok(c and c.stub)
    eq('idle', c.status)
    eq({ 'idle' }, events)
  end)

  it('knows a chat is over the moment its agent exits', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local agent = fake.install(home)
    board().open()
    local buf = actions().open(store().get(key(c)))
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(c)).live == true
    end)
    -- No refresh from here on: the exit itself must settle it.
    local real_refresh = store().refresh
    store().refresh = function() end
    require('agent-chats.term').send(buf, '/exit')
    local gone = vim.wait(3000, function()
      return not api.nvim_buf_is_valid(buf)
    end, 10)
    vim.wait(50)
    local now = store().get(key(c))
    local shown = list()
    store().refresh = real_refresh
    ok(gone, 'the terminal closed')
    eq(false, now.live)
    eq('ended', now.status)
    hasnt(shown, '↗')
    has(agent.read(), '/exit')
  end)

  it('still announces a turn that ended while you pressed a key mid-refresh', function()
    local home = fx.home()
    local c = home:chat({ start = os.time() - 30 }):user('Go'):write()
    local pid = vim.uv.os_getpid()
    home:registry(pid, { sessionId = c.id, status = 'busy' })
    for i = 1, 30 do
      chat(home, { title = 'Other ' .. i, age = 600 + i })
    end
    store().refresh_sync()
    eq('working', store().get(key(c)).status)
    local fresh
    store().on(function(ev)
      if ev.type == 'transition' and ev.chat.id == c.id and ev.to == 'done' then
        fresh = ev.fresh
      end
    end)
    c.ts = os.time()
    c:assistant('Done.'):turn_done():write()
    home:registry(pid, { sessionId = c.id, status = 'idle' })
    require('agent-chats.util.async').slice_ms = 0
    local finished = false
    store().refresh({ full = true }, function()
      finished = true
    end)
    -- A pin, a read mark: anything that recomputes statuses while the
    -- refresh is between two chats.
    local presses = 0
    while not finished and presses < 2000 do
      store().touch()
      presses = presses + 1
      vim.wait(1)
    end
    ok(finished)
    eq('done', store().get(key(c)).status)
    eq(true, fresh, 'the refresh itself announces it')
  end)

  it('matches every session a Codex process holds open', function()
    if not require('agent-chats.util.proc').has_procfs then
      return
    end
    local cx = require('helpers.codex')
    local home = cx.home()
    local a =
      home:rollout({ start = os.time() - 60 }):meta():task_started():item_user('one'):write()
    local b =
      home:rollout({ start = os.time() - 50 }):meta():task_started():item_user('two'):write()
    local job = cx.fake({
      body = 'exec 3<"$ROLL_A" 4<"$ROLL_B"\nread _\n',
      env = { ROLL_A = a.path, ROLL_B = b.path },
    })
    store().refresh_sync()
    job.stop()
    eq(true, store().get('codex:' .. a.id).live)
    eq(true, store().get('codex:' .. b.id).live)
  end)

  it('stops calling Claude exact where it keeps no session registry', function()
    local home = fx.home({ board = { spinner = false } })
    chat(home)
    local claude = require('agent-chats.providers.claude')
    local providers = require('agent-chats.providers')
    eq(true, providers.exact(claude))
    eq({}, board()._guessed())
    vim.fn.delete(home.dir .. '/sessions', 'd')
    eq(false, providers.exact(claude))
    require('agent-chats.hooks').lacking()
    eq({ 'Claude' }, board()._guessed())
    local said = {}
    for _, line in ipairs(require('agent-chats.health').sources(claude)) do
      said[#said + 1] = line.text
    end
    hasnt(table.concat(said, '\n'), 'is exact')
  end)

  it('does not wait for input it was not promised', function()
    fx.home()
    local dir = require('agent-chats.events').dir()
    -- Standard input left open and silent, as a terminal would be.
    local job = vim.system(
      { 'sh', hk.script, 'pal', 'ask', 'sess-open-stdin' },
      { stdin = true, env = { AGENT_CHATS_EVENTS_DIR = dir } }
    )
    local res = job:wait(3000)
    eq(0, res.code, 'it finished by itself')
    eq('ask', hk.lines('pal', 'sess-open-stdin')[1].e)
  end)
end)

-- Found by the review of the hook installer. The files are the user's.
describe('regressions: installer', function()
  local function hooks()
    return require('agent-chats.hooks')
  end

  local function read(path)
    local f = io.open(path, 'rb')
    if not f then
      return nil
    end
    local text = f:read('*a')
    f:close()
    return text
  end

  local function settings(home)
    return home.dir .. '/settings.json'
  end

  local function apply(name, action)
    local plan, err = hooks().plan(name, action)
    ok(plan, tostring(err))
    local done, why = hooks().apply(plan)
    ok(done, tostring(why))
    return plan
  end

  it('leaves a settings file it cannot read alone instead of replacing it', function()
    if vim.uv.getuid() == 0 then
      return
    end
    local home = fx.home()
    T.write(settings(home), '{ "permissions": { "allow": ["Bash(ls:*)"] } }\n')
    vim.uv.fs_chmod(settings(home), 0)
    eq('broken', hooks().status('claude').state)
    local plan, err = hooks().plan('claude', 'install')
    eq(nil, plan)
    has(err, 'cannot be read')
    local lines, good = hooks().install({ 'claude' })
    no(good)
    has(table.concat(lines, '\n'), 'cannot be read')
    vim.uv.fs_chmod(settings(home), 420)
    eq('{ "permissions": { "allow": ["Bash(ls:*)"] } }\n', read(settings(home)))
    eq({}, vim.fn.glob(settings(home) .. '.agent-chats-backup-*', false, true))
  end)

  it('leaves a read-only file and a link to nothing alone', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    vim.uv.fs_chmod(settings(home), 292)
    local plan, err = hooks().plan('claude', 'install')
    if vim.uv.getuid() ~= 0 then
      eq(nil, plan)
      has(err, 'read-only')
      eq('{}\n', read(settings(home)))
    end
    vim.uv.fs_chmod(settings(home), 420)
    vim.uv.fs_unlink(settings(home))

    assert(vim.uv.fs_symlink(home.root .. '/dotfiles/gone.json', settings(home)))
    eq('broken', hooks().status('claude').state)
    plan, err = hooks().plan('claude', 'install')
    eq(nil, plan)
    has(err, 'a link to a file that is not there')
    eq('link', vim.uv.fs_lstat(settings(home)).type)
  end)

  it('keeps every name of a hard-linked settings file pointing at the same content', function()
    local home = fx.home()
    T.write(settings(home), '{\n  "model": "opus"\n}\n')
    local twin = home.root .. '/twin.json'
    assert(vim.uv.fs_link(settings(home), twin))
    apply('claude', 'install')
    has(read(twin), 'agent-chats-hook.sh')
    eq(read(settings(home)), read(twin))
    eq(2, vim.uv.fs_stat(twin).nlink)
  end)

  it('sets up only the agents that are there', function()
    local home = fx.home({
      providers = {
        codex = { enabled = true, home = vim.fs.dirname(fx.home().dir) .. '/never-made/.codex' },
        qwen = { enabled = true, home = vim.fs.dirname(fx.home().dir) .. '/never-made/.qwen' },
      },
    })
    T.write(settings(home), '{}\n')
    local names = {}
    for _, p in ipairs(hooks().candidates()) do
      names[#names + 1] = p.name
    end
    eq({ 'claude' }, names)
    local lines = hooks().install()
    eq(1, #vim.tbl_filter(function(line)
      return line:find('hooks installed', 1, true) ~= nil
    end, lines))
    local cfg = require('agent-chats.config').get().providers
    eq(nil, vim.uv.fs_stat(cfg.codex.home))
    eq(nil, vim.uv.fs_stat(cfg.qwen.home))
  end)

  it('keeps every comment, wherever it is written', function()
    local layouts = {
      in_empty_root = '{\n  // nothing set yet\n}\n',
      in_empty_root_inline = '{ /* nothing */ }\n',
      in_empty_hooks = '{\n  "hooks": {\n    // my hooks go here\n  },\n  "model": "opus"\n}\n',
      in_empty_list = '{\n  "hooks": {\n    "Stop": [\n      // none yet\n    ]\n  }\n}\n',
      beside_values = '{\n  // which model\n  "model": "opus", /* inline */\n  "x": 1 // last\n}\n',
      above_my_entry = table.concat({
        '{',
        '  "hooks": {',
        '    "Stop": [',
        '      // tell me when it is done',
        '      { "hooks": [{ "type": "command", "command": "notify-send done" }] }',
        '    ]',
        '  }',
        '}',
        '',
      }, '\n'),
    }
    local jsontext = require('agent-chats.util.jsontext')
    for name, before in pairs(layouts) do
      local home = fx.home()
      T.write(settings(home), before)
      apply('claude', 'install')
      local installed = read(settings(home))
      eq(jsontext.comments(before), jsontext.comments(installed), name .. ': after installing')
      eq('installed', hooks().status('claude').state, name)
      -- A second entry of the user's own, with a comment, right after ours.
      apply('claude', 'uninstall')
      local removed = read(settings(home))
      eq(jsontext.comments(before), jsontext.comments(removed), name .. ': after removing')
      eq('missing', hooks().status('claude').state, name)
      ok(jsontext.decode(removed) ~= nil, name)
    end

    -- A comment the user wrote above an entry of theirs that follows ours.
    local home = fx.home()
    T.write(settings(home), '{}\n')
    apply('claude', 'install')
    local text = read(settings(home))
    local mine = '{ "hooks": [{ "type": "command", "command": "notify-send done" }] }'
    text = text:gsub('("Stop": %[)(.-)(%])', function(open, ours, close)
      return open
        .. '\n      '
        .. vim.trim(ours)
        .. ',\n      // and tell me\n      '
        .. mine
        .. '\n    '
        .. close
    end, 1)
    T.write(settings(home), text)
    ok(jsontext.decode(text) ~= nil)
    apply('claude', 'uninstall')
    local after = read(settings(home))
    has(after, '// and tell me')
    has(after, 'notify-send done')
    hasnt(after, 'agent-chats-hook.sh')
  end)

  it('removes its own link, never the file a link points at', function()
    local ox = require('helpers.opencode')
    local home = ox.home()
    local plugins = home.root .. '/config/opencode/plugins'
    vim.fn.mkdir(plugins, 'p')
    -- Installed once, then kept in a checkout and linked from there.
    ok(hooks().apply(assert(hooks().plan('opencode', 'install'))))
    local content = read(plugins .. '/agent-chats.js')
    local checkout = T.write(home.root .. '/checkout/opencode-agent-chats.js', content)
    vim.uv.fs_unlink(plugins .. '/agent-chats.js')
    assert(vim.uv.fs_symlink(checkout, plugins .. '/agent-chats.js'))
    eq('installed', hooks().status('opencode').state)
    no(assert(hooks().plan('opencode', 'install')).changed)

    ok(hooks().apply(assert(hooks().plan('opencode', 'uninstall'))))
    eq(nil, vim.uv.fs_lstat(plugins .. '/agent-chats.js'), 'the link is gone')
    eq(content, read(checkout), 'what it pointed at is not')

    -- A link whose target has moved on is the user's to look after.
    T.write(checkout, content .. '\n// my own change\n')
    assert(vim.uv.fs_symlink(checkout, plugins .. '/agent-chats.js'))
    local plan, err = hooks().plan('opencode', 'install')
    eq(nil, plan)
    has(err, 'a link you keep yourself')
    eq(content .. '\n// my own change\n', read(checkout))
  end)

  it('always keeps the backup it has just made', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    for round = 1, 7 do
      local plan = assert(hooks().plan('claude', round % 2 == 1 and 'install' or 'uninstall'))
      local before = plan.before
      local done, err, saved = hooks().apply(plan)
      ok(done, tostring(err))
      ok(saved and vim.uv.fs_stat(saved), 'round ' .. round .. ': the backup named exists')
      eq(before, read(saved), 'round ' .. round)
    end
    eq(3, #vim.fn.glob(settings(home) .. '.agent-chats-backup-*', false, true))
  end)

  it('writes a path with a backslash in it as it is', function()
    local home = fx.home()
    local odd = home.root .. '/odd\\/agent-chats-hook.sh'
    require('agent-chats.config').get().hooks.script = odd
    T.write(settings(home), '{}\n')
    apply('claude', 'install')
    local command = vim.json.decode(read(settings(home))).hooks.Stop[1].hooks[1].command
    has(command, odd)
    eq('installed', hooks().status('claude').state)
  end)

  it('tells the hook where to write, and notices when that is no longer here', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    apply('claude', 'install')
    local dir = require('agent-chats.events').dir()
    has(hooks().command('claude'), 'AGENT_CHATS_EVENTS_DIR=' .. dir .. ' ')
    eq('installed', hooks().status('claude').state)
    -- The folder is changed in the options afterwards.
    require('agent-chats.config').get().hooks.dir = home.root .. '/moved'
    local st = hooks().status('claude')
    eq('outdated', st.state)
    has(st.detail, 'a folder this Neovim does not read')
    apply('claude', 'install')
    eq('installed', hooks().status('claude').state)
    has(read(settings(home)), home.root .. '/moved')
  end)
end)

-- Found by the review of the board: reading a conversation.
describe('regressions: transcript', function()
  local function transcript()
    return require('agent-chats.ui.conversation')
  end

  --- A made-up agent whose reader hands back the whole conversation every
  --- time (no cursor), as opencode's does. `t` is what the test changes.
  local function whole_reader(t)
    t.reads, t.mtime = 0, os.time() - 20
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return '/nonexistent'
      end,
      available = function()
        return true
      end,
      discover = function()
        return { { id = 'one', mtime = t.mtime, size = #t.messages } }
      end,
      parse = function()
        return { title = 'A demo chat', cwd = '/work/demo', turn = 'working', updated = t.mtime }
      end,
      live = function()
        return { one = { pid = vim.uv.os_getpid(), turn = 'working' } }
      end,
      messages = function()
        t.reads = t.reads + 1
        if t.fail then
          error('the database is locked')
        end
        return vim.deepcopy(t.messages), nil
      end,
      resume_cmd = function(c)
        return { 'demo', 'resume', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    return t
  end

  local function said(n)
    local out = {}
    for i = 1, n do
      out[i] = { role = i % 2 == 1 and 'user' or 'assistant', text = 'message number ' .. i }
    end
    return out
  end

  local function count(haystack, needle)
    local n, from = 0, 1
    while true do
      local s, e = haystack:find(needle, from, true)
      if not s then
        return n
      end
      n, from = n + 1, e + 1
    end
  end

  local poll

  before_each(function()
    poll = transcript()._poll_ms
    transcript()._poll_ms = 40
  end)

  after_each(function()
    transcript()._poll_ms = poll
    require('agent-chats.providers').reset()
  end)

  it('puts each result under its own call when tools ran at the same time', function()
    local home = fx.home()
    local c = home:chat({ cwd = '/work/alpha', start = os.time() - 60 })
    c:user('Read both files')
    c:tool_use('Bash', { command = 'cat FIRST.txt' })
    local first = c.tool_id
    c:tool_use('Bash', { command = 'cat SECOND.txt' })
    local second = c.tool_id
    c:tool_result('contents of the FIRST file', { id = first })
    c:tool_result('contents of the SECOND file', { id = second })
    c:assistant('Both read.'):turn_done():write()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local buf = actions().read(store().get(key(c)))
    T.wait(3000, function()
      return T.buf_text(buf):find('Both read', 1, true) ~= nil
    end)
    local text = T.buf_text(buf)
    local call_a = text:find('cat FIRST.txt', 1, true)
    local result_a = text:find('contents of the FIRST file', 1, true)
    local call_b = text:find('cat SECOND.txt', 1, true)
    local result_b = text:find('contents of the SECOND file', 1, true)
    ok(call_a < result_a and result_a < call_b and call_b < result_b, text)
    -- Each call's fold holds its own result and nothing else.
    local st = transcript()._states[buf]
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local fold_of = {}
    local current
    for l, line in ipairs(lines) do
      if st.levels[l] == '>1' then
        current = line
      elseif st.levels[l] == '0' or st.levels[l] == nil then
        current = nil
      end
      if line:find('contents of the', 1, true) then
        fold_of[line] = current
      end
    end
    has(fold_of['contents of the FIRST file'], 'cat FIRST.txt')
    has(fold_of['contents of the SECOND file'], 'cat SECOND.txt')
  end)

  it('names the call of a result that arrives after other calls were written', function()
    local home = fx.home()
    local c = home:chat({ cwd = '/work/alpha', start = os.time() - 60 })
    c:user('Read both files')
    c:tool_use('Bash', { command = 'cat FIRST.txt' })
    local first = c.tool_id
    c:tool_use('Bash', { command = 'cat SECOND.txt' })
    local second = c.tool_id
    c:write()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local buf = actions().read(store().get(key(c)))
    T.wait(3000, function()
      return T.buf_text(buf):find('cat SECOND.txt', 1, true) ~= nil
    end)
    -- The calls are on screen; their results come with the next read.
    c:tool_result('contents of the FIRST file', { id = first })
    c:tool_result('contents of the SECOND file', { id = second })
    c:write()
    store().refresh_sync({ full = false })
    T.wait(3000, function()
      return T.buf_text(buf):find('contents of the SECOND file', 1, true) ~= nil
    end)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local st = transcript()._states[buf]
    local heads = {}
    for l, line in ipairs(lines) do
      if line:find('^↳ result') then
        heads[#heads + 1] = { line = line, level = st.levels[l] }
      end
    end
    eq(2, #heads)
    has(heads[1].line, 'result of Bash')
    has(heads[1].line, 'cat FIRST.txt')
    eq('>1', heads[1].level, 'it does not join the fold of the second call')
    has(heads[2].line, 'cat SECOND.txt')
  end)

  it('follows a conversation whose reader has no cursor, drawing only what is new', function()
    fx.home()
    local t = whole_reader({ messages = said(40) })
    store().refresh_sync()
    store().start = function() end
    board().open()
    local buf = actions().read(store().get('demo:one'))
    T.wait(3000, function()
      return T.buf_text(buf):find('message number 40', 1, true) ~= nil
    end)
    local win = vim.fn.win_findbuf(buf)[1]
    eq(api.nvim_buf_line_count(buf), api.nvim_win_get_cursor(win)[1], 'opened at the latest turn')
    local reads = t.reads

    -- Nothing changes for a while: it is not read again and again.
    vim.wait(300)
    eq(reads, t.reads)

    -- The conversation grows.
    t.messages, t.mtime = said(44), t.mtime + 1
    store().refresh_sync({ full = false })
    T.wait(3000, function()
      return T.buf_text(buf):find('message number 44', 1, true) ~= nil
    end)
    eq(api.nvim_buf_line_count(buf), api.nvim_win_get_cursor(win)[1], 'the view went with it')
    eq(1, count(T.buf_text(buf), 'message number 40\n'))
    eq(1, count(T.buf_text(buf), '# A demo chat'))

    -- The last message is still being written: it is drawn again in place.
    t.messages[44].text = 'message number 44, now longer'
    t.mtime = t.mtime + 1
    store().refresh_sync({ full = false })
    T.wait(3000, function()
      return T.buf_text(buf):find('now longer', 1, true) ~= nil
    end)
    eq(1, count(T.buf_text(buf), 'message number 44'))
    eq(1, count(T.buf_text(buf), 'message number 43'))

    -- Reading further up: the view stays where it is put.
    api.nvim_win_set_cursor(win, { 5, 0 })
    t.messages, t.mtime = said(46), t.mtime + 1
    store().refresh_sync({ full = false })
    T.wait(3000, function()
      return T.buf_text(buf):find('message number 46', 1, true) ~= nil
    end)
    eq(5, api.nvim_win_get_cursor(win)[1])
  end)

  it(
    'replaces "could not read" and "nothing said yet" by the conversation once it is there',
    function()
      fx.home()
      local t = whole_reader({ messages = {}, fail = true })
      store().refresh_sync()
      store().start = function() end
      board().open()
      local buf = actions().read(store().get('demo:one'))
      T.wait(3000, function()
        return T.buf_text(buf):find('Could not read this conversation', 1, true) ~= nil
      end)
      has(T.buf_text(buf), 'the database is locked')
      has(T.buf_text(buf), '# A demo chat')
      hasnt(T.buf_text(buf), 'Reading…')

      t.fail, t.mtime = false, t.mtime + 1
      store().refresh_sync({ full = false })
      T.wait(3000, function()
        return T.buf_text(buf):find('Nothing has been said in this chat yet', 1, true) ~= nil
      end)
      hasnt(T.buf_text(buf), 'Could not read')

      t.messages, t.mtime = said(2), t.mtime + 1
      store().refresh_sync({ full = false })
      T.wait(3000, function()
        return T.buf_text(buf):find('message number 2', 1, true) ~= nil
      end)
      local text = T.buf_text(buf)
      hasnt(text, 'Nothing has been said')
      hasnt(text, 'Could not read')
      hasnt(text, 'Reading…')
      eq(1, count(text, '# A demo chat'))
    end
  )

  it('shows a search hit without touching your own search pattern or hlsearch', function()
    local home = fx.home()
    local c = home:chat({ cwd = '/work/alpha', start = os.time() - 60 })
    c:user('Rename it')
    c:assistant('Renamed the Tokenizer to lexer, and the tokenizer tests with it.')
      :turn_done()
      :write()
    store().refresh_sync()
    store().start = function() end
    board().open()
    vim.o.hlsearch = false
    vim.fn.setreg('/', 'my own pattern')
    local buf = actions().read(store().get(key(c)), { index = 2, query = 'tokenizer' })
    T.wait(3000, function()
      return T.buf_text(buf):find('Renamed', 1, true) ~= nil
    end)
    no(vim.o.hlsearch)
    eq('my own pattern', vim.fn.getreg('/'))
    local win = vim.fn.win_findbuf(buf)[1]
    local pos = api.nvim_win_get_cursor(win)
    local line = api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1]
    eq('Tokenizer', line:sub(pos[2] + 1, pos[2] + 9), 'the cursor is on the match')
    local ns = api.nvim_get_namespaces()['agent-chats-conversation']
    eq(2, #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 'both places are marked')
  end)
end)

-- Found by the review of the board: the list itself.
describe('regressions: board', function()
  local function open_board(home_opts, make)
    local home =
      fx.home(vim.tbl_deep_extend('force', { board = { spinner = false } }, home_opts or {}))
    local made = make and make(home) or nil
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    return home, made
  end

  local function press(lhs)
    local keys = api.nvim_replace_termcodes(lhs, true, false, true)
    api.nvim_feedkeys(keys, 'x', false)
  end

  it('finds with one search what the rows show and what only a conversation holds', function()
    local _, c = open_board(nil, function(h)
      chat(h, { title = 'Fix the parser' })
      return chat(h, {
        title = 'Street layout',
        prompt = 'Where do people cross?',
        reply = 'Noted.',
      })
    end)
    -- The passage is in the middle of the conversation: nothing a row
    -- shows or holds (names, folders, the first and latest exchange) has it.
    c.ts = os.time() - 500
    c:user('And the animals?'):assistant('The zebra crossing is over there.')
    c:user('Thanks'):assistant('You are welcome.'):turn_done():write(os.time() - 400)
    store().refresh_sync()
    -- While it is being typed, only the rows are looked at.
    board().search('zebra', { conversations = false })
    has(list(), 'No row shows “zebra”')
    has(list(), 'The conversations are read for it next')

    -- The same search, finished: the conversations are read too. No second
    -- key, and no rule about which of two searches wins.
    board().search('zebra')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    has(list(), '1 chat · 1 passage')
    has(list(), 'Street layout')
    has(list(), 'zebra crossing')
    hasnt(list(), 'Fix the parser')

    -- A text a row shows is found at once, with no passage needed.
    board().search('parser', { conversations = false })
    has(list(), 'Search “parser”  1 chat')
    has(list(), 'Fix the parser')
    hasnt(list(), 'Street layout')

    -- One step back ends the search, and the board is still there.
    board().back()
    eq(nil, board()._state.search)
    ok(board().is_open())
    has(list(), 'Fix the parser')
    has(list(), 'Street layout')
    -- The next step back closes it.
    board().back()
    no(board().is_open())
  end)

  it('does not search half an index when it is the first thing asked for', function()
    local home = fx.home({ board = { spinner = false }, cache_file = false })
    for i = 1, 60 do
      chat(home, {
        title = 'Chat ' .. i,
        age = 100 + i,
        reply = i % 2 == 0 and 'The wombat was here.' or 'Nothing to see.',
      })
    end
    seen_everything()
    -- Every step of the first load gives way: the search starts in the middle of it.
    require('agent-chats.util.async').slice_ms = 0
    store().start = function() end
    no(store().initialized)
    actions().search('wombat')
    T.wait(8000, function()
      local search = board()._state.search
      return search ~= nil and not search.running
    end)
    eq(30, vim.tbl_count(board()._state.search.hits))
    has(list(), '30 chats · 30 passages')
  end)

  it('shows a search hit that sits in a folded group', function()
    local _, c = open_board(nil, function(h)
      return chat(h, { title = 'Fix the parser', reply = 'Renamed the tokenizer to lexer.' })
    end)
    state().set_collapsed('status:ended', true)
    board().render()
    hasnt(list(), 'Fix the parser')
    actions().search('tokenizer')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    has(list(), '1 chat · 1 passage')
    has(list(), 'Renamed the tokenizer')
    eq(key(c), board()._state.rows[4].chat.key)
    -- The fold is what it was once the search is over.
    board().clear()
    hasnt(list(), 'Fix the parser')
  end)

  it('finds the chat that needs you inside a folded group', function()
    local home = open_board(nil, function(h)
      chat(h, { title = 'Seen already' })
    end)
    local waiting = chat(home, { title = 'Wants an answer', age = 5 })
    home:registry(vim.uv.os_getpid(), {
      sessionId = waiting.id,
      status = 'waiting',
      waitingFor = 'permission to use Bash',
    })
    store().refresh_sync()
    has(list(), '1 needs you')
    state().set_collapsed('status:attention', true)
    board().render()
    hasnt(list(), 'Wants an answer')
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    board().jump_attention(1)
    vim.notify = real
    eq({}, said)
    has(list(), 'Wants an answer')
    eq(key(waiting), board().current().key)
  end)

  it('counts in the header what the search left, not everything', function()
    local home = open_board(nil, function(h)
      chat(h, { title = 'Alpha one', cwd = '/work/alpha' })
      chat(h, { title = 'Beta one', cwd = '/work/beta' })
    end)
    local a = chat(home, { title = 'Alpha two', cwd = '/work/alpha', age = 5 })
    local b = chat(home, { title = 'Beta two', cwd = '/work/beta', age = 5 })
    state().update(function(s)
      s.baseline = os.time() - 300
      s.seen = {}
    end)
    store().refresh_sync()
    eq('done', store().get(key(a)).status)
    eq('done', store().get(key(b)).status)
    has(list(), '4 chats · 2 unread')
    board().search('beta', { conversations = false })
    has(list(), 'Search “beta”  2 chats')
    hasnt(list(), '4 chats')
    hasnt(list(), '2 unread')
  end)

  it('keeps the way to the menu in a narrow bar', function()
    open_board(nil, function(h)
      for i = 1, 3 do
        chat(h, { title = 'Chat ' .. i, age = 5 * i, cwd = vim.uv.cwd() })
      end
    end)
    state().update(function(s)
      s.baseline = os.time() - 300
      s.seen = {}
    end)
    store().refresh_sync()
    local win = board()._state.win
    api.nvim_win_set_width(win, 36)
    board().render()
    local header = api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1]
    -- The counts are still there, in fewer cells, and so is a key.
    has(header, '3 chats')
    has(header, '✓3')
    has(header, '+ new')
    ok(vim.fn.strdisplaywidth(header) <= 36, 'the header fits: ' .. header)
    api.nvim_win_set_width(win, 60)
    board().render()
    has(api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1], '3 chats · 3 unread')
    api.nvim_win_set_width(win, 36)
    board().render()
    -- The bar above the list drops its hints one by one, never the last:
    -- the way to everything else.
    local bar = vim.wo[win].winbar
    has(bar, '?%* menu')
    has(bar, 'Enter')
    hasnt(bar, 'pass on')
  end)

  it('acts on the chat under the cursor of the window the key was typed in', function()
    open_board({ keys = { pin = 'X' } }, function(h)
      chat(h, { title = 'Chat A', age = 10 })
      chat(h, { title = 'Chat B', age = 20 })
      chat(h, { title = 'Chat C', age = 30 })
    end)
    local first = board().current()
    eq('Chat A', first.title)
    -- A second view of the list, its cursor on another chat.
    vim.cmd('split')
    local second = api.nvim_get_current_win()
    ok(second ~= board()._state.win)
    for i, row in ipairs(board()._state.rows) do
      if row.chat and row.chat.title == 'Chat C' then
        api.nvim_win_set_cursor(second, { i, 1 })
      end
    end
    eq('Chat C', board().current().title)
    press('X')
    local pinned = {}
    for _, c in ipairs(store().list()) do
      if state().pinned(c.key) then
        pinned[#pinned + 1] = c.title
      end
    end
    eq({ 'Chat C' }, pinned)
    api.nvim_win_close(second, true)
  end)

  it('names in its hints the keys that are bound, and no command that does not exist', function()
    local home = fx.home({
      board = { spinner = false, max_per_group = 2, max_age_days = 30 },
      keys = {
        show_all = 'gA',
        clear = false,
        back = false,
        toggle = 'zo',
        menu = 'g!',
        open = false,
        read = 'v',
        reply = false,
        new = false,
      },
    })
    for i = 1, 4 do
      chat(home, { title = 'Chat ' .. i, age = 60 * i, cwd = vim.uv.cwd() })
    end
    local old = home:chat({ cwd = '/work/old', start = os.time() - 90 * 86400 })
    old:user('Long ago'):assistant('Done long ago.'):turn_done():write(os.time() - 90 * 86400)
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local text = list()
    has(text, '… 2 more (zo shows them)')
    has(text, '1 chat older than 30 days not shown (gA shows them)')
    has(text, 'S search')
    hasnt(text, 'new chat')
    hasnt(text, ':Chats')
    local bar = vim.wo[board()._state.win].winbar
    has(bar, 'v%* conversation')
    has(bar, 'g!%* menu')
    hasnt(bar, 'reply')
    hasnt(bar, 'Enter')
    hasnt(bar, '?')
    -- With no key to end a search, nothing is said about ending one.
    board().search('nothing-matches-this', { conversations = false })
    hasnt(list(), 'ends the search')
    hasnt(list(), ':Chats')
    -- And the summary speaks of the same keys.
    board().clear()
    board().goto_chat('claude:' .. store().list()[1].id)
    local pane = T.buf_text(api.nvim_win_get_buf(board()._state.pane_win))
    hasnt(pane, 'Enter')
    hasnt(pane, 'C reads')
  end)

  it('makes the summary anew after :bdelete, so nothing of it is ever written to a file', function()
    open_board(nil, function(h)
      chat(h, { title = 'Fix the parser' })
    end)
    local summary = board()._state.preview_buf
    api.nvim_set_current_win(board()._state.pane_win)
    vim.cmd('bdelete')
    board().focus()
    -- The pane went with its buffer; p brings it back.
    eq(nil, board()._state.pane_win)
    board().toggle_pane()
    local now = board()._state.preview_buf
    ok(api.nvim_buf_is_valid(now))
    eq('nofile', vim.bo[now].buftype)
    no(vim.bo[now].modified)
    has(T.buf_text(now), 'Fix the parser')
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
        no(vim.bo[buf].modified, 'no plain buffer is left with the summary in it: ' .. buf)
      end
    end
    ok(summary ~= now or vim.bo[summary].buftype == 'nofile')
  end)

  it('leaves the cursor in a chat opened from the floating board into a split', function()
    for _, where in ipairs({ 'vsplit', 'split', 'tab' }) do
      local home = fx.home({
        board = { spinner = false, layout = 'float' },
        open = { where = where, start_insert = false },
      })
      local c = chat(home, { cwd = vim.uv.cwd() })
      local agent = fake.install(home)
      seen_everything()
      store().refresh_sync()
      store().start = function() end
      local file_win = api.nvim_get_current_win()
      board().open()
      local buf = actions().open(store().get(key(c)))
      ok(buf, where)
      T.wait(3000, function()
        return agent.read():find('argv:', 1, true) ~= nil
      end)
      -- The board gets out of the way a moment later; the cursor stays.
      T.wait(2000, function()
        return not board().is_open()
      end)
      vim.wait(50)
      eq(buf, api.nvim_get_current_buf(), where .. ': the cursor is in the chat')
      ok(api.nvim_get_current_win() ~= file_win, where)
      fake.cleanup()
      vim.cmd('silent! tabonly')
      vim.cmd('silent! only')
    end
  end)

  it('gives back a plain window after :tabonly on the board tab', function()
    vim.wo.number, vim.wo.wrap, vim.wo.cursorline = true, true, false
    open_board(nil, function(h)
      chat(h, { title = 'Fix the parser' })
    end)
    api.nvim_set_current_win(board()._state.win)
    vim.cmd('tabonly')
    board().close()
    local win = api.nvim_get_current_win()
    eq(true, vim.wo[win].number)
    eq(true, vim.wo[win].wrap)
    eq(false, vim.wo[win].cursorline)
    no(vim.wo[win].winfixbuf)
    vim.wo.number = false
  end)
end)

-- Found by the review of the board: what the keys do.
describe('regressions: actions', function()
  local function notes(fn)
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    local ok_run, err = pcall(fn)
    vim.notify = real
    assert(ok_run, err)
    return table.concat(said, '\n')
  end

  it("does not turn the agent's title into a name of yours when R is only confirmed", function()
    local home = fx.home()
    local c = chat(home, { title = 'Fix the parser' })
    store().refresh_sync()
    local real = vim.ui.input
    -- Enter on what is offered.
    vim.ui.input = function(opts, cb)
      cb(opts.default)
    end
    actions().rename(store().get(key(c)))
    eq(nil, state().name(key(c)))
    -- The agent retitles the chat later: the row follows.
    c:title('Fix the parser and the lexer'):write()
    store().refresh_sync()
    eq('Fix the parser and the lexer', require('agent-chats.display').title(store().get(key(c))))

    -- A name of your own stays, and can be confirmed without losing it.
    vim.ui.input = function(_, cb)
      cb('My name for it')
    end
    actions().rename(store().get(key(c)))
    vim.ui.input = function(opts, cb)
      cb(opts.default)
    end
    actions().rename(store().get(key(c)))
    eq('My name for it', state().name(key(c)))
    -- Emptied, it goes back to the agent's.
    vim.ui.input = function(_, cb)
      cb('')
    end
    actions().rename(store().get(key(c)))
    vim.ui.input = real
    eq(nil, state().name(key(c)))
  end)

  it('says what to do instead when a key is pressed on a subagent row', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { title = 'Parent chat', cwd = vim.uv.cwd() })
    c:subagent(
      'aaa111',
      { agentType = 'Explore', description = 'Find parser files', finished = true }
    )
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    board().goto_chat(key(c))
    board().toggle_row()
    local sub
    for _, row in ipairs(board()._state.rows) do
      if row.chat and row.chat.subagent then
        sub = row.chat
      end
    end
    ok(sub, 'the subagent is listed')
    local real_input, real_select = vim.ui.input, vim.ui.select
    vim.ui.input = function()
      error('nothing is asked for a subagent')
    end
    vim.ui.select = vim.ui.input
    for _, name in ipairs({
      'archive',
      'pin',
      'labels',
      'note',
      'rename',
      'toggle_unread',
      'queue',
      'pass',
    }) do
      local said = notes(function()
        actions()[name](sub)
      end)
      has(said, 'A subagent cannot be', name)
      has(said, 'the chat it belongs to (“Parent chat”)', name)
    end
    vim.ui.input, vim.ui.select = real_input, real_select
    -- And nothing was saved under its name.
    no(state().pinned(sub.key))
    eq(nil, state().archived_at(sub.key))
    eq({}, state().labels(sub.key))
    eq(nil, state().note(sub.key))
    eq(nil, state().name(sub.key))
    no(require('agent-chats.ui.input').is_open())
  end)

  it(
    'lists a new chat that has not started a session yet, so its terminal can be reached',
    function()
      local cx = require('helpers.codex')
      local home = cx.home({ board = { spinner = false }, open = { start_insert = false } })
      local old =
        home:rollout({ cwd = vim.uv.cwd(), start = os.time() - 5000 }):meta():task_started()
      old:item_user('An older question'):task_complete('An older answer'):write(os.time() - 4000)
      -- A stand-in for an agent that writes nothing until it is sent a
      -- prompt, and holds its conversation open from then on.
      local new = home:rollout({ cwd = vim.uv.cwd(), start = os.time() })
      local bin = T.tmpdir() .. '/codex'
      T.write(bin, '#!/bin/sh\nread _\nexec 3<"$HOLD"\nread _\n')
      vim.uv.fs_chmod(bin, 493)
      vim.env.HOLD = new.path
      require('agent-chats.config').get().providers.codex.cmd = { bin }
      state().update(function(s)
        s.baseline = os.time() + 10
      end)
      store().refresh_sync()
      store().start = function() end
      board().open()

      actions().new({ provider = 'codex', cwd = vim.uv.cwd(), prompt = '' })
      local buf = api.nvim_get_current_buf()
      eq('terminal', vim.bo[buf].buftype)
      -- Back to the list, as the pane's title says.
      board().focus()
      store().refresh_sync({ full = false })
      local row
      for _, c in pairs(store().chats) do
        if c.term == buf then
          row = c
        end
      end
      ok(row, 'a row leads to the terminal')
      ok(row.unstarted)
      eq('idle', row.status)
      has(list(), '(no prompt yet)')
      board().goto_chat(row.key)
      eq(buf, actions().open(row), 'Enter goes back to it')
      board().focus()

      -- It is sent its first prompt: the session appears, and takes the row's place.
      new:meta():task_started():item_user('The first prompt'):write()
      require('agent-chats.term').send(buf, 'The first prompt')
      -- The look that finds the session gives it its terminal: it is never
      -- listed as a chat of its own that nobody has open.
      eq(nil, store().chats['codex:' .. new.id], 'not found before this look')
      store().refresh_sync()
      local real = store().get('codex:' .. new.id)
      ok(real, 'the session is found')
      eq(buf, real.term, 'and has its terminal in the same look')
      eq(true, real.live)
      for _, c in pairs(store().chats) do
        no(c.unstarted, 'the stand-in row is gone')
      end
      hasnt(list(), '(no prompt yet)')
      vim.env.HOLD = nil
    end
  )
end)

-- Found by the review of the board: more than one Neovim, and the command.
describe('regressions: shared state and the command', function()
  it('shows a pin, a label and a name given in another Neovim', function()
    local home = fx.home({ board = { spinner = false } })
    local a = chat(home, { title = 'Chat A', age = 10 })
    local b = chat(home, { title = 'Chat B', age = 20 })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local before = list()
    ok(before:find('Chat A', 1, true) < before:find('Chat B', 1, true))

    -- Another instance writes the shared file: pins B, labels and names it.
    local path = state().path()
    local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    saved.pins[key(b)] = true
    saved.labels[key(b)] = { 'urgent' }
    saved.names[key(b)] = 'Named elsewhere'
    T.write(path, vim.json.encode(saved))
    T.touch(path, os.time() + 2)
    vim.wait(300) -- past the quarter second the file is not looked at again

    -- Nothing happened to any chat; the next look still has to draw it.
    local updates = 0
    local off = store().on(function(ev)
      if ev.type == 'update' then
        updates = updates + 1
      end
    end)
    store().refresh_sync({ full = false })
    off()
    eq(1, updates)
    local after = list()
    has(after, 'Named elsewhere')
    has(after, 'urgent')
    ok(after:find('Named elsewhere', 1, true) < after:find('Chat A', 1, true), 'pinned to the top')
    eq(true, state().pinned(key(b)))
    no(state().pinned(key(a)))
  end)

  it('does not announce a chat that another Neovim marked unread', function()
    local home = fx.home({ notify = { enabled = true } })
    local c = chat(home)
    seen_everything()
    store().refresh_sync()
    require('agent-chats.notify').setup()
    eq('ended', store().get(key(c)).status)
    local path = state().path()
    local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    saved.baseline = os.time() - 3600
    saved.seen = vim.empty_dict()
    T.write(path, vim.json.encode(saved))
    T.touch(path, os.time() + 2)
    vim.wait(300)
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    store().refresh_sync({ full = false })
    vim.notify = real
    eq('done', store().get(key(c)).status, 'it is unread here too')
    eq({}, said)
  end)

  it('completes subcommands after a modifier or a range', function()
    fx.home()
    local complete = require('agent-chats').complete
    eq({ 'new', 'next' }, complete('ne', 'tab Chats ne'))
    eq({ 'new', 'next' }, complete('ne', 'Chats ne'))
    eq({ 'send' }, complete('sen', "'<,'>Chats sen"))
    eq({ 'search', 'send' }, complete('se', 'silent! AgentChats se'))
    eq({ 'claude' }, complete('cl', 'vertical Chats new cl'))
    eq({ 'install', 'uninstall', 'show', 'status' }, complete('', 'tab Chats hooks '))
    eq({ 'claude' }, complete('', 'tab Chats hooks install '))
    -- And through the command line itself.
    vim.cmd('runtime plugin/agent-chats.lua')
    eq({ 'new', 'next' }, vim.fn.getcompletion('tab Chats ne', 'cmdline'))
  end)
end)

-- Found by the review of the status layer: the smaller ones.
describe('regressions: telling you', function()
  after_each(function()
    require('agent-chats.providers').reset()
    require('agent-chats.ui.hooks')._answer(false)
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= '' then
        pcall(api.nvim_win_close, win, true)
      end
    end
  end)

  local function floats()
    local n = 0
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= '' then
        n = n + 1
      end
    end
    return n
  end

  it('announces a waiting chat whose parent is not on the board', function()
    fx.home({ notify = { enabled = true } })
    local turn = 'working'
    local now = os.time()
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return '/nonexistent'
      end,
      available = function()
        return true
      end,
      discover = function()
        return { { id = 'child', mtime = now - 20, size = 1 } }
      end,
      parse = function()
        -- Started by a chat that is not listed (too old, or deleted).
        return {
          title = 'An orphan',
          cwd = '/work/demo',
          turn = 'working',
          parent = 'demo:long-gone',
          updated = now - 20,
        }
      end,
      query = function()
        return { child = { pid = vim.uv.os_getpid(), turn = turn, waiting_for = 'your go-ahead' } }
      end,
      query_interval = 0,
      messages = function()
        return {}, nil
      end,
      resume_cmd = function(c)
        return { 'demo', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    store().refresh_sync()
    eq('working', store().get('demo:child').status)
    require('agent-chats.notify').setup()
    local events = 0
    local group = api.nvim_create_augroup('AgentChatsTestOrphan', { clear = true })
    api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'AgentChatsAttention',
      callback = function()
        events = events + 1
      end,
    })
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    turn = 'waiting'
    store().refresh_sync({ full = false })
    vim.notify = real
    api.nvim_del_augroup_by_id(group)
    eq('attention', store().get('demo:child').status)
    eq(1, #said)
    has(said[1], 'Needs you: An orphan')
    eq(1, events)
  end)

  it(
    'says in :checkhealth that installed hooks are switched off, and when one last reported',
    function()
      local home = fx.home()
      home:chat():user('Hi'):assistant('Hello.'):turn_done():write()
      T.write(home.dir .. '/settings.json', '{}\n')
      local hooks = require('agent-chats.hooks')
      ok(hooks.apply(assert(hooks.plan('claude', 'install'))))
      require('helpers.hooks').event('claude', 'some-session', 'Stop')
      local function report()
        local out = {}
        for _, line in
          ipairs(
            require('agent-chats.health').sources(require('agent-chats.providers').get('claude'))
          )
        do
          out[#out + 1] = line.level .. ': ' .. line.text
        end
        return table.concat(out, '\n')
      end
      has(report(), 'ok: Claude: hooks installed (1 session has reported, the last just now)')
      hasnt(report(), 'now ago')
      require('agent-chats.config').get().hooks.enabled = false
      local off = report()
      has(off, 'info: Claude: hooks installed')
      has(off, 'hooks.enabled is false in the options: what they report is ignored')
      hasnt(off, 'say themselves when they need you')
      hasnt(off, 'whichever spoke last is believed')
      has(off, 'status comes from its session registry')
    end
  )

  it('keeps one hooks overview, and one question, at a time', function()
    vim.cmd('runtime plugin/agent-chats.lua')
    local home = fx.home()
    T.write(home.dir .. '/settings.json', '{}\n')
    local ui = require('agent-chats.ui.hooks')
    local before = floats()
    vim.cmd('Chats hooks')
    vim.cmd('Chats hooks')
    vim.cmd('Chats hooks')
    eq(before + 1, floats(), 'asked for three times, shown once')

    -- A question opened from the overview, then the same asked again by command.
    api.nvim_feedkeys('i', 'xt', false)
    ok(ui.is_asking())
    vim.cmd('Chats hooks install claude')
    ok(ui.is_asking())
    vim.wait(100)
    ok(ui.is_asking(), 'the newer question is not closed by the older one going away')
    local asking_win = api.nvim_get_current_win()
    ok(api.nvim_win_get_config(asking_win).relative ~= '')
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    ui._answer(true)
    vim.notify = real
    eq('installed', require('agent-chats.hooks').status('claude').state)
    has(table.concat(said, '\n'), 'Claude: hooks installed')

    -- Leaving the overview for another window takes it off the screen.
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= '' then
        pcall(api.nvim_win_close, win, true)
      end
    end
    vim.cmd('Chats hooks')
    eq(before + 1, floats())
    vim.cmd('wincmd p')
    vim.wait(50)
    eq(before, floats())
  end)

  it('takes a program for an agent by its name, not by a folder it lies in', function()
    local proc = require('agent-chats.util.proc')
    local dir = T.tmpdir() .. '/.claude/tools'
    local script = T.write(dir .. '/watch.sh', '#!/bin/sh\nread _\n')
    vim.uv.fs_chmod(script, 493)
    local job = vim.system({ 'sh', script }, { stdin = true })
    T.wait(2000, function()
      return proc.argv(job.pid) ~= nil
    end)
    no(proc.is(job.pid, { claude = true }), 'a script kept under ~/.claude is not Claude')
    ok(proc.is(job.pid, { ['watch'] = true }), 'its own name, extension or not, is it')
    ok(proc.is(job.pid, { ['watch.sh'] = true }))
    job:kill(9)
    job:wait(2000)

    -- An agent started through a runtime is found by the script it runs,
    -- under the names packages give their folders and files.
    local modules = T.tmpdir() .. '/lib/node_modules'
    for script, name in pairs({
      [modules .. '/@openai/codex/bin/codex.js'] = 'codex',
      [modules .. '/@qwen-code/qwen-code/cli-entry.js'] = 'qwen',
      [modules .. '/@anthropic-ai/claude-code/cli.js'] = 'claude',
    }) do
      T.write(script, '#!/bin/sh\nread _\n')
      local job2 = vim.system({ 'sh', script }, { stdin = true })
      T.wait(2000, function()
        return proc.argv(job2.pid) ~= nil
      end)
      ok(proc.is(job2.pid, { [name] = true }), script)
      no(proc.is(job2.pid, { opencode = true }), script)
      job2:kill(9)
      job2:wait(2000)
    end

    -- A file some other program was pointed at says nothing about it.
    local notes = T.write(T.tmpdir() .. '/codex-notes.txt', 'notes\n')
    local tail = vim.system({ 'tail', '-f', notes }, {})
    T.wait(2000, function()
      return proc.argv(tail.pid) ~= nil
    end)
    no(proc.is(tail.pid, { codex = true }))
    tail:kill(9)
    tail:wait(2000)
  end)
end)

-- Found by the review of the board: terminals.
describe('regressions: terminals', function()
  it('gives a terminal to the chat whose agent it runs, not to one that agent started', function()
    -- Whatever the ids are: the order chats are looked at must not decide.
    local pairs_of_ids = {
      { '00001eef-0000-4000-8000-000000019919', '00ec4ba7-0000-4000-8000-000001ef30eb' },
      { 'ffff1eef-0000-4000-8000-000000019919', '00ec4ba7-0000-4000-8000-000001ef30eb' },
      { '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002' },
      { '20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001' },
    }
    for n, ids in ipairs(pairs_of_ids) do
      local home = fx.home({ board = { spinner = false }, open = { start_insert = false } })
      local function make(id, title, age)
        local c = home:chat({ id = id, cwd = vim.uv.cwd(), start = os.time() - age - 5 })
        c:user('Please do it'):title(title):assistant('Done.'):turn_done():write(os.time() - age)
        return c
      end
      local outer = make(ids[1], 'The chat in the terminal', 600)
      local inner = make(ids[2], 'A chat it started', 300)
      seen_everything()
      local agent = fake.install(home)
      store().refresh_sync()
      store().start = function() end
      board().open()
      -- Like an agent running a tool: a second session as a child process.
      require('agent-chats.config').get().providers.claude.cmd = {
        'sh',
        '-c',
        ('(sleep 30 | %s --resume %s) & exec %s "$@"'):format(agent.bin, inner.id, agent.bin),
        'claude',
      }
      local buf = actions().open(store().get(key(outer)))
      T.wait(3000, function()
        return select(2, agent.read():gsub('argv:', '')) >= 2
      end)
      T.wait(3000, function()
        store().refresh_sync()
        local o, i = store().get(key(outer)), store().get(key(inner))
        return o.live and i.live
      end)
      store().refresh_sync()
      eq(buf, store().get(key(outer)).term, 'pair ' .. n .. ': the chat on screen has its terminal')
      eq(nil, store().get(key(inner)).term, 'pair ' .. n .. ': the chat it started has none')
      -- Stopping the terminal's job takes what it started with it.
      fake.cleanup()
    end
  end)

  it(
    'titles the pane with the chat from the first moment, and says when its agent has gone',
    function()
      local home = fx.home({
        board = { spinner = false },
        open = { start_insert = false, close_on_exit = false },
      })
      local c = chat(home, { title = 'Fix the parser', cwd = vim.uv.cwd() })
      seen_everything()
      local agent = fake.install(home)
      store().refresh_sync()
      store().start = function() end
      board().open()
      local buf = actions().open(store().get(key(c)))
      local bar = vim.wo[board()._state.pane_win].winbar
      has(bar, 'LIVE')
      has(bar, 'Fix the parser')
      -- From the first moment it also says how to get back: the key that
      -- does it in the mode the terminal is in.
      has(bar, 'q back')
      T.typing(function()
        has(vim.wo[board()._state.pane_win].winbar, [[<C-\><C-b> back]])
      end)
      ok(vim.fn.maparg([[<C-\><C-b>]], 't', false, true).buffer == 1)
      T.wait(3000, function()
        return agent.read():find('argv:', 1, true) ~= nil
      end)
      -- The agent is killed; its last screen stays up.
      vim.fn.jobstop(vim.bo[buf].channel)
      T.wait(3000, function()
        return vim.wo[board()._state.pane_win].winbar:find('ENDED', 1, true) ~= nil
      end)
      bar = vim.wo[board()._state.pane_win].winbar
      hasnt(bar, 'LIVE')
      has(bar, 'the agent has exited')
    end
  )
end)

-- Found by driving the real agents. None of these could show with a
-- stand-in that takes whatever is typed.
describe('regressions: found with the real agents', function()
  -- An agent that is showing a dialog of its own: what is pasted does not
  -- appear, and a line (that is, Enter) is an answer to the dialog.
  local DIALOG = [[#!/usr/bin/env bash
log="$FAKE_AGENT_LOG"
echo "argv: $*" >> "$log"
sid=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--resume" ] || [ "$prev" = "--session-id" ]; then sid="$a"; fi
  prev="$a"
done
printf '{"pid":%d,"sessionId":"%s","cwd":"%s","status":"idle","kind":"interactive","name":"fake"}' \
  $$ "$sid" "$PWD" > "$FAKE_AGENT_HOME/sessions/$$.json"
trap 'rm -f "$FAKE_AGENT_HOME/sessions/$$.json"' EXIT
stty -echo
echo "A new release is available. Update now?    Skip   [Confirm]"
while IFS= read -r line; do
  echo "dialog answered with: $line" >> "$log"
done
]]

  local function notes(fn)
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    local ok_run, err = pcall(fn)
    vim.notify = real
    assert(ok_run, err)
    return said
  end

  --- Open `c` in a terminal of this Neovim, running `script` (the usual
  --- stand-in when nil), and wait until the index has it there.
  local function hosted(home, c, script)
    local agent = fake.install(home)
    if script then
      T.write(agent.bin, script)
      vim.uv.fs_chmod(agent.bin, 493)
    end
    store().start = function() end
    board().open()
    local buf = actions().open(store().get(key(c)))
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local now = store().get(key(c))
      return now.term == buf and now.pid ~= nil
    end)
    vim.cmd('stopinsert')
    return agent, buf
  end

  it('does not press Enter when the chat shows a dialog instead of taking the text', function()
    local home = fx.home({ board = { spinner = false }, reply = { echo_wait = 300 } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c, DIALOG)
    T.wait(3000, function()
      return T.buf_text(buf):find('Update now', 1, true) ~= nil
    end)
    board().focus()

    -- Sent by hand, through the box (the chat is free: it goes at once).
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    local function warned()
      return #vim.tbl_filter(function(m)
        return m:find('did not take the text', 1, true) ~= nil
      end, said)
    end
    actions().queue(store().get(key(c)))
    api.nvim_buf_set_lines(api.nvim_get_current_buf(), 0, -1, false, { 'please run the tests' })
    require('agent-chats.ui.input').submit()
    local told = pcall(T.wait, 3000, function()
      return warned() > 0
    end)
    vim.notify = real
    ok(told, 'you are told that it was not sent')
    vim.wait(450)
    hasnt(agent.read(), 'dialog answered', 'Enter was never pressed')
    has(table.concat(said, '\n'), 'did not take the text')
    has(table.concat(said, '\n'), 'Nothing was sent')
    hasnt(agent.read(), 'dialog answered')
    -- What was written is still there for the next try.
    actions().queue(store().get(key(c)))
    eq('please run the tests', T.buf_text(api.nvim_get_current_buf()))
    require('agent-chats.ui.input').cancel()

    -- A queued reply: kept, said once, and not typed again and again.
    local queue = require('agent-chats.queue')
    queue.setup()
    state().sent(key(c))
    state().enqueue(key(c), 'then commit')
    said = notes(function()
      queue.sweep()
      T.wait(3000, function()
        return #state().queue(key(c)) == 1 and state().claim(key(c)) == nil
      end)
      vim.wait(450)
      for _ = 1, 4 do
        queue.sweep()
        vim.wait(120)
      end
    end)
    eq(1, #state().queue(key(c)), 'the reply is still queued')
    eq(1, #vim.tbl_filter(function(m)
      return m:find('did not take the text', 1, true) ~= nil
    end, said))
    hasnt(agent.read(), 'dialog answered')
  end)

  it('sends a reply as one paste, also into a terminal that is in no window', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    board().focus()
    board().toggle_pane()
    eq(0, #vim.fn.win_findbuf(buf), 'the terminal is hidden')
    local done
    actions().deliver(store().get(key(c)), '1 more thing: update the docs', nil, function(sent)
      done = sent
    end)
    T.wait(3000, function()
      return done ~= nil
    end)
    eq(true, done)
    T.wait(3000, function()
      return agent.read():find('paste: end', 1, true) ~= nil
    end)
    -- A paste, not key presses: a dialog would take "1" as its first choice.
    has(agent.read(), 'paste: begin\ninput: 1 more thing: update the docs\npaste: end')
  end)

  it('types one reply at a time into a terminal', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    local term = require('agent-chats.term')
    local first, second
    ok(term.send(buf, 'the first reply', function(sent, why)
      first = { sent, why }
    end))
    -- Before the first one's Enter: a second paste would join its message.
    ok(term.send(buf, 'the second reply', function(sent, why)
      second = { sent, why }
    end))
    T.wait(3000, function()
      return first ~= nil and second ~= nil
    end)
    eq({ true }, first)
    eq({ false, 'busy' }, second)
    T.wait(3000, function()
      return agent.read():find('paste: end', 1, true) ~= nil
    end)
    has(agent.read(), 'input: the first reply\n')
    hasnt(agent.read(), 'the second reply')
    -- And a queued reply is held from the moment one is sent by hand.
    local queue = require('agent-chats.queue')
    queue.setup()
    state().enqueue(key(c), 'queued meanwhile')
    actions().deliver(store().get(key(c)), 'sent by hand')
    queue.sweep()
    ok(state().claim(key(c)) ~= nil)
    eq(1, #state().queue(key(c)))
    T.wait(3000, function()
      return agent.read():find('input: sent by hand', 1, true) ~= nil
    end)
    vim.wait(200)
    hasnt(agent.read(), 'queued meanwhile')
  end)

  it('looks for the session of a chat just started here every few seconds', function()
    local cx = require('helpers.codex')
    cx.home({ board = { spinner = false }, open = { start_insert = false } })
    local bin = T.tmpdir() .. '/codex'
    T.write(bin, '#!/bin/sh\nread _\n')
    vim.uv.fs_chmod(bin, 493)
    require('agent-chats.config').get().providers.codex.cmd = { bin }
    store().refresh_sync()
    eq(30000, store()._scan_due())
    store().start = function() end
    board().open()
    actions().new({ provider = 'codex', cwd = vim.uv.cwd(), prompt = '' })
    store().refresh_sync({ full = false })
    -- Its row is a stand-in until the session shows up: that is looked
    -- for often now, not twice a minute.
    eq(3000, store()._scan_due())
  end)

  it('keeps a finished chat unread when its agent is quit with /exit', function()
    local home = fx.home()
    local c = home:chat({ cwd = '/work/alpha', start = os.time() - 100 })
    c:user('Please fix the parser')
      :title('Fix the parser')
      :assistant('The parser is fixed.')
      :turn_done()
    c:write(os.time() - 50)
    state().update(function(s)
      s.baseline = os.time() - 3600
    end)
    store().refresh_sync()
    eq('done', store().get(key(c)).status)
    -- /exit, as the agent records it: a note (a meta record), the command,
    -- its output. None of it is a prompt; no turn starts.
    c:local_command('/exit')
    c:write(os.time() - 10)
    store().refresh_sync()
    local now = store().get(key(c))
    eq('done', now.turn_file)
    eq('done', now.status, 'still unread')
    eq('Please fix the parser', now.last_prompt)
  end)

  it('holds a queued reply back behind one just sent by hand', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    local queue = require('agent-chats.queue')
    queue.setup()
    local pid = store().get(key(c)).pid
    local function registry(status)
      local sec, usec = vim.uv.gettimeofday()
      home:registry(pid, {
        sessionId = c.id,
        status = status,
        cwd = vim.uv.cwd(),
        statusUpdatedAt = sec * 1000 + math.floor(usec / 1000),
      })
    end
    board().focus()
    actions().deliver(store().get(key(c)), 'sent by hand')
    T.wait(3000, function()
      return agent.read():find('input: sent by hand', 1, true) ~= nil
    end)
    ok(state().claim(key(c)) ~= nil, 'it is on its way')

    -- Q straight after it: the index has not seen the chat busy yet.
    eq('idle', store().get(key(c)).status)
    actions().queue(store().get(key(c)))
    api.nvim_buf_set_lines(api.nvim_get_current_buf(), 0, -1, false, { 'queued behind it' })
    require('agent-chats.ui.input').submit()
    eq(1, #state().queue(key(c)), 'queued, not sent at once')
    for _ = 1, 3 do
      queue.sweep()
      vim.wait(150)
    end
    hasnt(agent.read(), 'queued behind it')

    -- The agent's own record shows that turn came and went.
    vim.wait(20)
    registry('busy')
    registry('idle')
    store().refresh_sync({ full = false })
    T.wait(4000, function()
      return agent.read():find('input: queued behind it', 1, true) ~= nil
    end)
    eq(0, #state().queue(key(c)))
    ok(api.nvim_buf_is_valid(buf))
  end)
end)

-- Found by the second review: where a reply ends up.
describe('regressions: where a reply goes', function()
  local function notes(fn)
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    local ok_run, err = pcall(fn)
    vim.notify = real
    assert(ok_run, err)
    return table.concat(said, '\n')
  end

  local function hosted(home, c)
    local agent = fake.install(home)
    store().start = function() end
    board().open()
    local buf = actions().open(store().get(key(c)))
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local now = store().get(key(c))
      return now.term == buf and now.pid ~= nil
    end)
    vim.cmd('stopinsert')
    return agent, buf
  end

  local function registry(home, c, pid, status, extra)
    local sec, usec = vim.uv.gettimeofday()
    home:registry(
      pid,
      vim.tbl_extend('force', {
        sessionId = c.id,
        status = status,
        cwd = vim.uv.cwd(),
        statusUpdatedAt = sec * 1000 + math.floor(usec / 1000),
      }, extra or {})
    )
  end

  it('types nothing into a shell of yours once the agent in it has exited', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent = fake.install(home)
    -- A terminal you opened yourself, with the agent started inside it.
    local buf = api.nvim_create_buf(true, false)
    local chan = api.nvim_buf_call(buf, function()
      return vim.fn.jobstart({ 'sh' }, { term = true, cwd = vim.uv.cwd() })
    end)
    api.nvim_chan_send(chan, ('%s --resume %s\n'):format(agent.bin, c.id))
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(c)).term == buf
    end)
    local term = require('agent-chats.term')
    ok(term.still_hosts(buf, store().get(key(c))))

    local proof = home.root .. '/typed-into-the-shell'
    state().enqueue(key(c), ('touch %s'):format(proof))
    -- The agent is quit; the index has not looked since.
    api.nvim_chan_send(chan, '/exit\n')
    T.wait(3000, function()
      return not require('agent-chats.util.proc').alive(store().get(key(c)).pid)
    end)
    eq(buf, store().get(key(c)).term, 'the index still has the old picture')
    no(term.still_hosts(buf, store().get(key(c))))

    local queue = require('agent-chats.queue')
    queue.sweep()
    local said = notes(function()
      local done
      actions().deliver(
        store().get(key(c)),
        ('touch %s-by-hand'):format(proof),
        nil,
        function(sent, why)
          done = { sent, why }
        end
      )
      T.wait(3000, function()
        return done ~= nil
      end)
      eq({ false, 'gone' }, done)
    end)
    has(said, 'no longer running in that terminal')
    vim.wait(400)
    eq(nil, vim.uv.fs_stat(proof), 'the queued reply was not run by the shell')
    eq(nil, vim.uv.fs_stat(proof .. '-by-hand'), 'nor the one sent by hand')
    eq(1, #state().queue(key(c)), 'it is still queued')
    pcall(vim.fn.jobstop, chan)
  end)

  it('does not take an agent inside another editor for a chat of this one', function()
    local term = require('agent-chats.term')
    local dir = T.tmpdir()
    -- job -> "nvim" -> the agent, and for comparison job -> the agent.
    local function chain(name)
      local pidfile = ('%s/%s.pid'):format(dir, name)
      local script = T.write(
        ('%s/%s'):format(dir, name),
        ('#!/bin/sh\nsleep 30 &\necho $! > %s\nwait\n'):format(pidfile)
      )
      vim.uv.fs_chmod(script, 493)
      local job = vim.system({ 'sh', '-c', script .. '; true' }, {})
      T.wait(3000, function()
        return vim.uv.fs_stat(pidfile) ~= nil and (vim.fn.readfile(pidfile)[1] or '') ~= ''
      end)
      return job, tonumber(vim.fn.readfile(pidfile)[1])
    end
    local inner, agent_in_editor = chain('nvim')
    local plain, agent_in_shell = chain('wrapper')
    eq(nil, (term.job_above(agent_in_editor, { [inner.pid] = 7 })))
    eq(7, (term.job_above(agent_in_shell, { [plain.pid] = 7 })))
    for _, pid in ipairs({ agent_in_editor, agent_in_shell }) do
      vim.uv.kill(pid, 9)
    end
    inner:kill(9)
    plain:kill(9)
  end)

  it('gives a terminal shared by a chat and a session it started to the chat', function()
    local term = require('agent-chats.term')
    local job = vim.system({ 'sh', '-c', 'read _' }, { stdin = true })
    local buf = api.nvim_create_buf(true, false)
    local chan = api.nvim_buf_call(buf, function()
      return vim.fn.jobstart({ 'sh', '-c', 'read _' }, { term = true })
    end)
    local pid = vim.fn.jobpid(chan)
    -- Both sessions live in the terminal's own process. The child's key
    -- sorts first, which used to decide.
    local chats = {
      ['opencode:aaa-child'] = {
        key = 'opencode:aaa-child',
        live = true,
        pid = pid,
        parent = 'opencode:zzz-parent',
      },
      ['opencode:zzz-parent'] = { key = 'opencode:zzz-parent', live = true, pid = pid },
    }
    term.attach(chats)
    eq(buf, chats['opencode:zzz-parent'].term)
    eq(nil, chats['opencode:aaa-child'].term)
    pcall(vim.fn.jobstop, chan)
    job:kill(9)
  end)

  it('keeps what was written when the box is closed any other way', function()
    local home = fx.home({ reply = { ended = 'ask' } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local input = require('agent-chats.ui.input')
    for _, how in ipairs({ 'quit', 'close', 'normal! ZZ', 'bdelete!' }) do
      notes(function()
        actions().queue(store().get(key(c)))
        api.nvim_buf_set_lines(
          api.nvim_get_current_buf(),
          0,
          -1,
          false,
          { 'written, then ' .. how }
        )
        vim.cmd(how)
        T.wait(1000, function()
          return not input.is_open()
        end)
      end)
      actions().queue(store().get(key(c)))
      eq('written, then ' .. how, T.buf_text(api.nvim_get_current_buf()), how)
      -- Closed again untouched: still there the time after.
      vim.cmd('quit')
      T.wait(1000, function()
        return not input.is_open()
      end)
      actions().queue(store().get(key(c)))
      eq('written, then ' .. how, T.buf_text(api.nvim_get_current_buf()), how .. ', twice')
      api.nvim_buf_set_lines(api.nvim_get_current_buf(), 0, -1, false, { '' })
      input.cancel()
    end
  end)

  it('does not send into a chat that began to ask something while a menu was open', function()
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent = hosted(home, c)
    local pid = store().get(key(c)).pid
    state().enqueue(key(c), 'rm -rf build && make')
    state().park(key(c))
    board().focus()
    local real = vim.ui.select
    vim.ui.select = function(items, _, cb)
      -- While the menu is up, the agent asks for permission.
      registry(home, c, pid, 'waiting', { waitingFor = 'permission to use Bash' })
      store().refresh_sync({ full = false })
      cb(vim.tbl_contains(items, 'send') and 'send' or nil)
    end
    local said = notes(function()
      actions().queue(store().get(key(c)))
      vim.wait(400)
    end)
    vim.ui.select = real
    has(said, 'waiting for your answer')
    hasnt(agent.read(), 'rm -rf build')
    eq(1, #state().queue(key(c)), 'the reply is back in the queue')

    -- :Chats send looks too, and leaves you where you are.
    board().focus()
    local win = api.nvim_get_current_win()
    said = notes(function()
      actions().send('a selection')
      vim.wait(300)
    end)
    has(said, 'waiting for your answer')
    hasnt(said, 'Sent to')
    hasnt(agent.read(), 'a selection')
    eq(win, api.nvim_get_current_win())
  end)

  it(
    'attaches nothing to a chat that has not started, and names its row for this Neovim only',
    function()
      local cx = require('helpers.codex')
      local home = cx.home({ board = { spinner = false }, open = { start_insert = false } })
      local bin = T.tmpdir() .. '/codex'
      T.write(bin, '#!/bin/sh\nread _\n')
      vim.uv.fs_chmod(bin, 493)
      require('agent-chats.config').get().providers.codex.cmd = { bin }
      store().refresh_sync()
      store().start = function() end
      board().open()
      actions().new({ provider = 'codex', cwd = vim.uv.cwd(), prompt = '' })
      local buf = api.nvim_get_current_buf()
      board().focus()
      store().refresh_sync({ full = false })
      local row
      for _, c in pairs(store().chats) do
        if c.term == buf then
          row = c
        end
      end
      ok(row and row.unstarted)
      has(row.key, ('codex:term-%d-%d'):format(vim.uv.os_getpid(), buf))
      local real_input = vim.ui.input
      vim.ui.input = function()
        error('nothing is asked for a chat that has not started')
      end
      for _, name in ipairs({ 'pin', 'labels', 'note', 'rename', 'archive', 'toggle_unread' }) do
        has(
          notes(function()
            actions()[name](row)
          end),
          'has not started yet',
          name
        )
      end
      vim.ui.input = real_input
      local saved = state().get()
      eq(nil, saved.pins[row.key])
      eq(nil, saved.names[row.key])
      eq(nil, saved.labels[row.key])
      eq(nil, saved.notes[row.key])
      eq(nil, saved.archived[row.key])
      eq(home.dir, home.dir)
    end
  )

  it('keeps queued replies back once their chat is no longer open here, and says so', function()
    local home = fx.home({ board = { spinner = false }, open = { start_insert = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    local agent, buf = hosted(home, c)
    local queue = require('agent-chats.queue')
    queue.setup()
    local pid = store().get(key(c)).pid
    registry(home, c, pid, 'busy')
    store().refresh_sync({ full = false })
    board().focus()
    state().enqueue(key(c), 'then run the linter')
    queue.sweep()

    -- The turn ends unread (you are on the list), and the agent exits at
    -- once: the chat goes from "done" to "done", with no move to announce.
    local said = notes(function()
      c.ts = os.time() + 1
      c:user('more'):assistant('Did more.'):turn_done():write()
      require('agent-chats.term').send(buf, '/exit')
      T.wait(3000, function()
        return not api.nvim_buf_is_valid(buf)
      end)
      store().refresh_sync({ full = false })
      queue.sweep()
      queue.sweep()
    end)
    eq(1, select(2, said:gsub('ended with 1 reply still queued', '')), said)
    eq(1, #state().queue(key(c)))
    ok(state().parked(key(c)))

    -- Opening the chat again does not send it.
    local again = actions().open(store().get(key(c)))
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local now = store().get(key(c))
      return now.term == again and now.pid ~= nil
    end)
    for _ = 1, 3 do
      queue.sweep()
      vim.wait(150)
    end
    hasnt(agent.read(), 'input: then run the linter')
    eq(1, #state().queue(key(c)))

    -- Q offers to carry on.
    board().focus()
    local real = vim.ui.select
    local offered
    vim.ui.select = function(items, _, cb)
      offered = items
      cb('carry_on')
    end
    actions().queue(store().get(key(c)))
    vim.ui.select = real
    ok(vim.tbl_contains(offered, 'carry_on'))
    T.wait(4000, function()
      return agent.read():find('input: then run the linter', 1, true) ~= nil
    end)
    eq(0, #state().queue(key(c)))
    no(state().parked(key(c)))
  end)

  it('says that a reply queued for a chat that is not open here is kept, not sent', function()
    fx.home()
    local now = os.time()
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return '/nonexistent'
      end,
      available = function()
        return true
      end,
      discover = function()
        return { { id = 'one', mtime = now - 5, size = 1 } }
      end,
      parse = function()
        return { title = 'A demo chat', cwd = vim.uv.cwd(), turn = 'working', updated = now - 5 }
      end,
      messages = function()
        return {}, nil
      end,
      resume_cmd = function(c)
        return { 'demo', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    store().refresh_sync()
    local c = store().get('demo:one')
    eq('working', c.status)
    eq(nil, c.live, 'nothing can see its process')
    local said = notes(function()
      actions().queue(c)
      api.nvim_buf_set_lines(
        api.nvim_get_current_buf(),
        0,
        -1,
        false,
        { 'when you are done, commit' }
      )
      require('agent-chats.ui.input').submit()
    end)
    has(said, 'Queued, and kept')
    has(said, 'not open in a terminal here')
    hasnt(said, 'typed into the chat when it finishes')
    ok(state().parked('demo:one'))
    require('agent-chats.providers').reset()
  end)
end)

-- Found by the second review: the rest.
describe('regressions: second review', function()
  local function notes(fn)
    local said = {}
    local real = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    local ok_run, err = pcall(fn)
    vim.notify = real
    assert(ok_run, err)
    return table.concat(said, '\n')
  end

  local function open_board(home_opts, make)
    local home =
      fx.home(vim.tbl_deep_extend('force', { board = { spinner = false } }, home_opts or {}))
    local made = make and make(home) or nil
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    return home, made
  end

  local function count(haystack, needle)
    local n, from = 0, 1
    while true do
      local a, b = haystack:find(needle, from, true)
      if not a then
        return n
      end
      n, from = n + 1, b + 1
    end
  end

  local poll
  before_each(function()
    poll = require('agent-chats.ui.conversation')._poll_ms
    require('agent-chats.ui.conversation')._poll_ms = 40
  end)
  after_each(function()
    require('agent-chats.ui.conversation')._poll_ms = poll
    require('agent-chats.providers').reset()
    require('agent-chats.ui.hooks')._answer(false)
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= '' then
        pcall(api.nvim_win_close, win, true)
      end
    end
  end)

  it('draws a conversation once when its file was rewritten shorter', function()
    local _, c = open_board(nil, function(h)
      local made = h:chat({ cwd = '/work/alpha', start = os.time() - 600 })
      made:user('First question'):title('Three questions'):assistant('First answer.')
      made:user('Second question'):assistant('Second answer.')
      made:user('Third question'):assistant('Third answer.'):turn_done()
      return made:write(os.time() - 300)
    end)
    local buf = actions().read(store().get(key(c)))
    T.wait(3000, function()
      return T.buf_text(buf):find('Third answer', 1, true) ~= nil
    end)
    -- The last exchange is taken out of the file (the agent rewrote it).
    c.lines[#c.lines] = nil
    c.lines[#c.lines] = nil
    c.lines[#c.lines] = nil
    c:write(os.time() - 200)
    store().refresh_sync({ full = false })
    T.wait(3000, function()
      return T.buf_text(buf):find('Third question', 1, true) == nil
    end)
    local text = T.buf_text(buf)
    eq(1, count(text, 'First question'))
    eq(1, count(text, 'Second answer.'))
    eq(0, count(text, 'Third answer.'))
    eq(1, count(text, '# Three questions'))
  end)

  it('pairs results with calls in order when a reader gives no ids', function()
    fx.home()
    local now = os.time()
    require('agent-chats').register({
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
        return { title = 'A demo chat', cwd = '/work/demo', turn = 'done', updated = now - 20 }
      end,
      messages = function()
        return {
          { role = 'user', text = 'read both' },
          { role = 'tool', name = 'Bash', summary = 'cat FIRST.txt' },
          { role = 'tool', name = 'Bash', summary = 'cat SECOND.txt' },
          { role = 'tool_result', text = 'contents of the FIRST file' },
          { role = 'tool_result', text = 'contents of the SECOND file' },
          { role = 'assistant', text = 'Both read.' },
        },
          nil
      end,
      resume_cmd = function(c)
        return { 'demo', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    store().refresh_sync()
    store().start = function() end
    board().open()
    local buf = actions().read(store().get('demo:one'))
    T.wait(3000, function()
      return T.buf_text(buf):find('Both read', 1, true) ~= nil
    end)
    local text = T.buf_text(buf)
    local call_a = text:find('cat FIRST.txt', 1, true)
    local result_a = text:find('contents of the FIRST file', 1, true)
    local call_b = text:find('cat SECOND.txt', 1, true)
    local result_b = text:find('contents of the SECOND file', 1, true)
    ok(call_a < result_a and result_a < call_b and call_b < result_b, text)
  end)

  it('says that opencode could not be read, and shows the conversation once it can', function()
    local ox = require('helpers.opencode')
    local home = ox.home({ board = { spinner = false } })
    local s = home:session({ title = 'Port the renderer' })
    s:user('Port it'):assistant():text('The renderer is ported.'):finish('stop')
    store().refresh_sync()
    store().start = function() end
    board().open()
    local provider = require('agent-chats.providers.opencode')
    -- The database cannot be read just now.
    provider._query = function()
      return nil, 'database is locked'
    end
    local c
    for _, chat in pairs(store().chats) do
      if chat.title == 'Port the renderer' then
        c = chat
      end
    end
    local buf = actions().read(c)
    T.wait(3000, function()
      return T.buf_text(buf):find('Could not read this conversation', 1, true) ~= nil
    end)
    hasnt(T.buf_text(buf), 'Nothing has been said')
    -- It can be read again: nothing about the chat itself has changed.
    provider._query = nil
    T.wait(3000, function()
      return T.buf_text(buf):find('The renderer is ported', 1, true) ~= nil
    end)
    hasnt(T.buf_text(buf), 'Could not read')
  end)

  it('takes "could not read" away again when the next read finds nothing new', function()
    fx.home()
    local t = { fail = false, mtime = os.time() - 20 }
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return '/nonexistent'
      end,
      available = function()
        return true
      end,
      discover = function()
        return { { id = 'one', mtime = t.mtime, size = 1 } }
      end,
      parse = function()
        return { title = 'A demo chat', cwd = '/work/demo', turn = 'done', updated = t.mtime }
      end,
      messages = function()
        if t.fail then
          error('the file is busy', 0)
        end
        return { { role = 'user', text = 'hello' }, { role = 'assistant', text = 'hello to you' } },
          nil
      end,
      resume_cmd = function(c)
        return { 'demo', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    store().refresh_sync()
    store().start = function() end
    board().open()
    local buf = actions().read(store().get('demo:one'))
    T.wait(3000, function()
      return T.buf_text(buf):find('hello to you', 1, true) ~= nil
    end)
    -- The chat moves, and reading it fails this once.
    t.fail, t.mtime = true, t.mtime + 1
    store().refresh_sync({ full = false })
    T.wait(3000, function()
      return T.buf_text(buf):find('Could not read this conversation: the file is busy', 1, true)
        ~= nil
    end)
    has(T.buf_text(buf), 'hello to you', 'what was read before stays')
    t.fail = false
    T.wait(3000, function()
      return T.buf_text(buf):find('Could not read', 1, true) == nil
    end)
    eq(1, count(T.buf_text(buf), 'hello to you'))
  end)

  it('reaches every chat that needs you with ]a, folded away or past the end of a group', function()
    local home = open_board({ board = { spinner = false, max_per_group = 2 } }, function(h)
      chat(h, { title = 'Quiet one' })
    end)
    -- Four finished and unread (two of them past the group's cap), and one
    -- waiting in a group that is folded.
    state().update(function(s)
      s.baseline = os.time() - 3000
      s.seen = { ['claude:' .. select(2, next(store().chats)).id] = os.time() + 10 }
    end)
    local unread = {}
    for i = 1, 4 do
      unread[i] = chat(home, { title = 'Unread ' .. i, age = 10 * i })
    end
    local waiting = chat(home, { title = 'Waits for you', age = 5 })
    home:registry(vim.uv.os_getpid(), {
      sessionId = waiting.id,
      status = 'waiting',
      waitingFor = 'permission to use Bash',
    })
    store().refresh_sync()
    state().set_collapsed('status:attention', true)
    board().render()
    hasnt(list(), 'Waits for you')
    hasnt(list(), 'Unread 4')
    local reached = {}
    for _ = 1, 6 do
      board().jump_attention(1)
      local c = board().current()
      reached[c and c.title or '?'] = true
    end
    for _, title in ipairs({ 'Waits for you', 'Unread 1', 'Unread 2', 'Unread 3', 'Unread 4' }) do
      ok(reached[title], title .. ' is reached')
    end
    no(reached['Quiet one'])
    -- And backwards, from the top.
    api.nvim_win_set_cursor(board()._state.win, { 1, 0 })
    board().jump_attention(-1)
    eq('Unread 4', board().current().title)
  end)

  it('moves in the view of the list that the key was typed in', function()
    local home = open_board(nil, function(h)
      chat(h, { title = 'Chat A', age = 100 })
      chat(h, { title = 'Chat B', age = 200 })
    end)
    local waiting = chat(home, { title = 'Waits for you', age = 5 })
    home:registry(vim.uv.os_getpid(), { sessionId = waiting.id, status = 'waiting' })
    store().refresh_sync()
    local first = board()._state.win
    for i, row in ipairs(board()._state.rows) do
      if row.chat and row.chat.title == 'Chat B' then
        api.nvim_win_set_cursor(first, { i, 1 })
      end
    end
    vim.cmd('split')
    local second = api.nvim_get_current_win()
    local kept = api.nvim_win_get_cursor(first)[1]
    board().jump_attention(1)
    eq('Waits for you', board()._state.rows[api.nvim_win_get_cursor(second)[1]].chat.title)
    eq(kept, api.nvim_win_get_cursor(first)[1], 'the other view stays where it was')
    -- The pane shows what this view is on.
    has(T.buf_text(api.nvim_win_get_buf(board()._state.pane_win)), 'Waits for you')
    api.nvim_win_close(second, true)
  end)

  it(
    'announces a finished turn although a key was pressed while the refresh was half-way',
    function()
      local home = fx.home({ notify = { enabled = true }, board = { spinner = false } })
      local c = chat(home, { title = 'The long task', cwd = vim.uv.cwd() })
      local other = chat(home, { title = 'Another chat' })
      state().update(function(s)
        s.baseline = os.time() - 5
        s.seen = { [key(c)] = os.time() + 1, [key(other)] = os.time() + 1 }
      end)
      -- Its agent is open and idle: the chat is "Idle", read.
      home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'idle', cwd = vim.uv.cwd() })
      store().refresh_sync()
      eq('idle', store().get(key(c)).status)
      require('agent-chats.notify').setup()
      -- A turn runs and ends.
      c.ts = os.time() + 3
      c:user('Do the long task'):assistant('Done with it.'):turn_done():write(os.time() + 4)
      local said = notes(function()
        require('agent-chats.util.async').slice_ms = 0
        local done = false
        store().refresh({ full = false }, function()
          done = true
        end)
        -- A pin on another chat, while that refresh is suspended.
        actions().pin(store().get(key(other)))
        T.wait(5000, function()
          return done
        end)
      end)
      eq('done', store().get(key(c)).status)
      has(said, 'Finished: The long task')
      -- Marked unread by hand later: nothing has finished, nothing is said.
      state().mark_seen(key(c), os.time() + 60)
      store().touch()
      eq('idle', store().get(key(c)).status)
      said = notes(function()
        actions().toggle_unread(store().get(key(c)))
      end)
      eq('done', store().get(key(c)).status)
      hasnt(said, 'Finished')
    end
  )

  it('does not advise installing hooks that are switched off', function()
    local qx = require('helpers.qwen')
    local home = qx.home({ hooks = { enabled = false }, board = { spinner = false } })
    home:chat({ start = os.time() - 60 }):turn('Hello', 'Hi.'):write()
    T.write(home.dir .. '/settings.json', '{}\n')
    store().refresh_sync()
    local lines = {}
    for _, line in
      ipairs(require('agent-chats.health').sources(require('agent-chats.providers').get('qwen')))
    do
      lines[#lines + 1] = line.level
        .. ': '
        .. line.text
        .. ' '
        .. table.concat(line.advice or {}, ' ')
    end
    local report = table.concat(lines, '\n')
    has(report, 'hooks.enabled is false in the options')
    hasnt(report, 'Run :Chats hooks install')
    eq({}, board()._guessed())
    require('agent-chats.config').get().hooks.enabled = true
    require('agent-chats.hooks').reset()
    eq({ 'Qwen' }, board()._guessed())
  end)

  it('takes a key option it cannot use for "no key" and says which one', function()
    local warned = {}
    local real = vim.notify
    vim.notify = function(msg)
      warned[#warned + 1] = msg
    end
    local home = fx.home({
      board = { spinner = false },
      keys = { queue = '', pin = 5, open = {}, label = { 'l', '' } },
    })
    chat(home, { title = 'Fix the parser', cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    vim.wait(50)
    board().open()
    vim.notify = real
    ok(board().is_open(), 'the board opens')
    local said = table.concat(warned, '\n')
    has(said, 'keys.queue')
    has(said, 'keys.pin')
    has(said, 'keys.label')
    hasnt(said, 'could not open the board')
    -- What could not be used is no key at all; the rest is as it was.
    local keys = require('agent-chats.keys')
    eq(nil, keys.key('queue'))
    eq(nil, keys.key('pin'))
    eq(nil, keys.key('open'))
    eq(nil, keys.key('label'))
    eq('C', keys.key('read'))
    eq('', vim.fn.maparg('Q', 'n'))
    ok(vim.fn.maparg('C', 'n', false, true).buffer == 1)
    -- The menu still lists them, by name: nothing is out of reach.
    board().menu()
    local menu = require('agent-chats.ui.menu')
    local more = table.concat(menu.lines(), '\n')
    has(more, 'C  Read the conversation')
    has(more, 'Pin to the top of its group')
    has(more, 'Edit its labels')
    menu.close()
  end)

  it('says so when a floating board has no room for the pane', function()
    local home = fx.home({ board = { spinner = false, layout = 'float', width = 44 } })
    local c = chat(home, { title = 'Fix the parser' })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    eq(nil, board()._state.pane_win)
    local said = notes(function()
      actions().read(store().get(key(c)))
    end)
    has(said, 'no room for the pane')
    said = notes(function()
      board().toggle_pane()
    end)
    has(said, 'no room for the pane')
  end)

  it('leaves the folds alone while search results are shown', function()
    local _, c = open_board(nil, function(h)
      return chat(h, { title = 'Fix the parser', reply = 'Renamed the tokenizer to lexer.' })
    end)
    actions().search('tokenizer')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(board()._state.win, { i, 0 })
      end
    end
    local said = notes(function()
      board().toggle_row()
    end)
    has(said, 'Groups stay open')
    no(state().collapsed('status:ended'))
    board().clear()
    has(list(), 'Fix the parser')
    ok(store().get(key(c)))
  end)

  it(
    'does not bring the hooks overview back when its question is left for another window',
    function()
      vim.cmd('runtime plugin/agent-chats.lua')
      local home = fx.home()
      T.write(home.dir .. '/settings.json', '{}\n')
      local ui = require('agent-chats.ui.hooks')
      local function floats()
        local n = 0
        for _, win in ipairs(api.nvim_list_wins()) do
          if api.nvim_win_get_config(win).relative ~= '' then
            n = n + 1
          end
        end
        return n
      end
      local file_win = api.nvim_get_current_win()
      vim.cmd('Chats hooks')
      api.nvim_feedkeys('i', 'xt', false)
      ok(ui.is_asking())
      api.nvim_set_current_win(file_win)
      vim.wait(100)
      no(ui.is_asking())
      eq(0, floats(), 'nothing comes back on top of the file')
      eq(file_win, api.nvim_get_current_win())
      -- Answered "no" with its key, the overview does come back.
      vim.cmd('Chats hooks')
      api.nvim_feedkeys('i', 'xt', false)
      ui._answer(false)
      vim.wait(100)
      eq(1, floats())
      api.nvim_feedkeys('q', 'xt', false)
    end
  )

  it('names a program by its file or its package, not by a folder on the way', function()
    local proc = require('agent-chats.util.proc')
    local root = T.tmpdir()
    local cases = {
      { { 'bash', root .. '/src/codex/scripts/lint.sh' }, 'codex', false },
      { { 'bash', root .. '/work/claude/build/server.sh' }, 'claude', false },
      { { 'bash', '-O', 'extglob', root .. '/lib/qwen/qwen.js' }, 'qwen', true },
      {
        { 'bash', root .. '/node_modules/@qwen-code/qwen-code/dist/src/cli/bin/index.js' },
        'qwen',
        true,
      },
      { { 'bash', root .. '/node_modules/@openai/codex/bin/codex.js' }, 'codex', true },
    }
    for _, case in ipairs(cases) do
      local argv, name, want = case[1], case[2], case[3]
      T.write(argv[#argv], '#!/bin/bash\nread _\n')
      local job = vim.system(argv, { stdin = true })
      T.wait(2000, function()
        return proc.argv(job.pid) ~= nil
      end)
      eq(want, proc.is(job.pid, { [name] = true }), table.concat(argv, ' '))
      job:kill(9)
      job:wait(2000)
    end
  end)

  it('rotates only its own backups out', function()
    local home = fx.home()
    local path = home.dir .. '/settings.json'
    T.write(path, '{}\n')
    -- A copy the user made, named alike.
    local mine = path .. '.agent-chats-backup-before-i-broke-it'
    T.write(mine, 'my own copy\n')
    local hooks = require('agent-chats.hooks')
    for round = 1, 6 do
      local plan = assert(hooks.plan('claude', round % 2 == 1 and 'install' or 'uninstall'))
      ok(hooks.apply(plan))
    end
    ok(vim.uv.fs_stat(mine), 'it is still there')
    eq(4, #vim.fn.glob(path .. '.agent-chats-backup-*', false, true), 'three of ours, and that one')
  end)

  it('completes after a range that ends in a letter', function()
    fx.home()
    local complete = require('agent-chats').complete
    eq({ 'send' }, complete('sen', "'a,'bChats sen"))
    eq({ 'new', 'next' }, complete('ne', 'Chats ne'))
    eq({ 'claude' }, complete('cl', "'<,'>AgentChats new cl"))
  end)

  it('does not read a chat again at every look when its reader gives whole seconds', function()
    fx.home()
    local dir = T.tmpdir()
    local path = T.write(dir .. '/one.jsonl', '{"role":"user","text":"hello"}\n')
    local parses = 0
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return dir
      end,
      available = function()
        return true
      end,
      discover = function()
        local st = vim.uv.fs_stat(path)
        -- Whole seconds, as the README's example reader gives them.
        return { { id = 'one', path = path, mtime = st.mtime.sec, size = st.size } }
      end,
      parse = function(entry)
        parses = parses + 1
        return { title = 'A demo chat', cwd = '/work/demo', turn = 'working', updated = entry.mtime }
      end,
      messages = function()
        return {}, nil
      end,
      resume_cmd = function(c)
        return { 'demo', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    store().refresh_sync()
    eq(1, parses)
    for _ = 1, 3 do
      store().refresh_sync({ full = false })
      store().refresh_sync()
    end
    eq(1, parses, 'the file has not changed')
  end)

  it('words a question and a plan for what they are', function()
    local home = fx.home()
    local c = home:chat({ start = os.time() - 30 }):user('Go'):write()
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'busy' })
    local hk = require('helpers.hooks')
    hk.event('claude', c.id, 'UserPromptSubmit')
    hk.event('claude', c.id, 'PermissionRequest', { tool = 'AskUserQuestion' })
    store().refresh_sync()
    eq('attention', store().get(key(c)).status)
    eq('a question for you', store().get(key(c)).waiting_for)
    hk.event('claude', c.id, 'PostToolUse', { tool = 'AskUserQuestion' })
    hk.event('claude', c.id, 'PermissionRequest', { tool = 'ExitPlanMode' })
    store().refresh_sync({ full = false })
    eq('your go-ahead for its plan', store().get(key(c)).waiting_for)
    hk.event('claude', c.id, 'PostToolUse', { tool = 'ExitPlanMode' })
    hk.event('claude', c.id, 'PermissionRequest', { tool = 'Bash' })
    store().refresh_sync({ full = false })
    eq('permission to use Bash', store().get(key(c)).waiting_for)
  end)
end)

-- Found by using it: the board took keys that were the user's own.
describe('regressions: your own keys', function()
  local mapped = {}
  local function user_map(mode, lhs, rhs, opts)
    vim.keymap.set(mode, lhs, rhs, opts or {})
    mapped[#mapped + 1] = { mode, lhs }
  end

  after_each(function()
    for _, m in ipairs(mapped) do
      pcall(vim.keymap.del, m[1], m[2])
    end
    mapped = {}
    pcall(function()
      require('agent-chats.ui.menu').close()
    end)
  end)

  local function feed(lhs)
    api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), 'xt', false)
  end

  it('switches tabs with H and L on the board, because they are your keys for it', function()
    -- As in the config this was found with: H / L are the previous / next tab.
    user_map('n', 'H', 'gT', { desc = 'Previous tab' })
    user_map('n', 'L', 'gt', { desc = 'Next tab' })
    local home = fx.home({ board = { spinner = false } })
    local c = chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    local before = api.nvim_get_current_tabpage()
    board().open()
    local tab = api.nvim_get_current_tabpage()
    ok(tab ~= before)
    local function switches(where)
      feed('H')
      eq(before, api.nvim_get_current_tabpage(), 'H goes to the previous tab ' .. where)
      feed('L')
      eq(tab, api.nvim_get_current_tabpage(), 'L comes back ' .. where)
    end
    switches('from the list')
    no(require('agent-chats.ui.input').is_open(), 'and nothing of the board ran')

    -- From a conversation in the pane.
    local buf = actions().read(store().get(key(c)))
    eq(buf, api.nvim_get_current_buf())
    switches('from a conversation')
    feed('q')

    -- From a chat's terminal, in its normal mode.
    local agent = fake.install(home)
    local term = actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    vim.cmd('stopinsert')
    eq(term, api.nvim_get_current_buf())
    switches("from a chat's terminal")
  end)

  it('leaves every default key that is a mapping of yours to you', function()
    -- Each of the board's default keys, mapped by the user before it opens.
    local defaults = require('agent-chats.config').defaults.keys
    local pressed = {}
    local all = {}
    for action, lhs in pairs(defaults) do
      for _, k in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
        if type(k) == 'string' and not k:lower():find('mouse', 1, true) then
          all[#all + 1] = { action = action, lhs = k }
          user_map('n', k, function()
            pressed[#pressed + 1] = k
          end)
        end
      end
    end
    ok(#all >= 14, 'the defaults have keys: ' .. #all)
    local home = fx.home({ board = { spinner = false } })
    chat(home, { cwd = vim.uv.cwd() })
    seen_everything()
    store().refresh_sync()
    store().start = function() end
    board().open()
    for _, each in ipairs(all) do
      no(
        vim.fn.maparg(each.lhs, 'n', false, true).buffer == 1,
        ('%s (%s) was taken on the list'):format(each.lhs, each.action)
      )
    end
    for _, each in ipairs(all) do
      feed(each.lhs)
    end
    eq(#all, #pressed, 'every one of them ran your mapping')
    ok(board().is_open(), 'and none of them ran the board')
    no(require('agent-chats.ui.input').is_open())
    eq(nil, board()._state.search)
    -- Nothing is advertised that is not there; the way to everything is a command.
    local bar = vim.wo[board()._state.win].winbar
    has(bar, ':Chats menu')
    hasnt(bar, 'Enter')
    hasnt(list(), 'new chat')
    vim.cmd('runtime plugin/agent-chats.lua')
    vim.cmd('Chats menu')
    ok(require('agent-chats.ui.menu').is_open())
  end)
end)
