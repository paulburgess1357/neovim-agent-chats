-- Chats that the options leave out by what they are called
-- (`filter_out_names`). They are not listed anywhere, and nothing more is
-- done with them: one that is left out is not read again until its file has
-- changed.

local T = require('helpers.harness')
local cx = require('helpers.codex')
local fx = require('helpers.claude')
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
local function config()
  return require('agent-chats.config')
end
local function claude()
  return require('agent-chats.providers.claude')
end

local function key(c)
  return 'claude:' .. c.id
end

--- A chat that finished its turn `age` seconds ago. `title`: what its agent
--- calls it (false: nothing, so that it goes by its first prompt).
local function chat(home, title, age, prompt)
  local c = home:chat({ cwd = T.folder('here'), branch = 'main', start = os.time() - age - 5 })
  c:user(prompt or ('Please ' .. tostring(title):lower()))
  if title then
    c:title(title)
  end
  c:assistant('Done.')
  c:turn_done()
  return c:write(os.time() - age)
end

local function list()
  return T.buf_text(board()._state.buf)
end

--- The names of the chats that are listed, in order.
local function listed()
  local display = require('agent-chats.display')
  local names = vim.tbl_map(function(c)
    return display.title(c)
  end, store().list({ archived = true }))
  table.sort(names)
  return names
end

--- What is said (warnings, notifications) while `fn` runs.
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

--- How often each chat's file is read while `fn` runs, by the id of the chat.
local function reads(fn)
  local p = claude()
  local real, seen = p.parse, {}
  p.parse = function(entry, prev)
    seen[entry.id] = (seen[entry.id] or 0) + 1
    return real(entry, prev)
  end
  local good, err = pcall(fn)
  p.parse = real
  assert(good, err)
  return seen
end

--- The options as they are, with `changes` made to them.
local function reconfigure(changes)
  local opts = vim.deepcopy(config().get())
  for name, value in pairs(changes) do
    opts[name] = value
  end
  config().setup(opts)
end

local function seen_everything()
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
end

--- Two chats called what the options leave out and two that are not; the
--- board is open.
local function scene(extra)
  local home = fx.home(
    vim.tbl_deep_extend(
      'force',
      { board = { spinner = false }, filter_out_names = { 'Capital of France' } },
      extra or {}
    )
  )
  local made = {
    one = chat(home, 'Capital of France', 60),
    two = chat(home, 'Capital of France', 90),
    near = chat(home, 'Capital of France, again', 120),
    work = chat(home, 'Real work', 150),
  }
  seen_everything()
  store().refresh_sync()
  store().start = function() end
  board().open()
  return home, made
end

after_each(function()
  pcall(function()
    board().close()
  end)
end)

describe('chats that are left out by name', function()
  it('are not listed, counted or found by a search', function()
    local _, made = scene({ notify = { enabled = true } })
    eq({ 'Capital of France, again', 'Real work' }, listed())
    eq(nil, store().get(key(made.one)))
    eq(nil, store().get(key(made.two)))
    local text = list()
    has(text, '2 chats')
    has(text, 'Real work')
    has(text, 'Capital of France, again', 'a name is a whole name')
    hasnt(text, 'Filtered out')
    eq(2, store().counts().ended)

    -- A turn ends in one of them: nothing is said, and it is not unread.
    require('agent-chats.notify').setup()
    state().update(function(s)
      s.baseline = os.time() - 3000
      s.seen = { [key(made.near)] = os.time() + 10, [key(made.work)] = os.time() + 10 }
    end)
    made.one.ts = os.time() + 20
    made.one:user('And of Kenya?'):assistant('Nairobi.'):turn_done():write(os.time() + 21)
    made.work.ts = os.time() + 20
    made.work:user('One more thing'):assistant('Done again.'):turn_done():write(os.time() + 21)
    local said = notes(function()
      store().refresh_sync()
    end)
    has(said, 'Finished: Real work')
    hasnt(said, 'Capital')
    eq(1, store().counts().done)
    eq(nil, store().get(key(made.one)))

    -- What is said in them is not found either: they are not read for it.
    board().search('Nairobi')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    has(list(), 'No chat has “Nairobi” in it.')
  end)

  it('go by what their row says: your name for it, its title, else its first prompt', function()
    local home = fx.home({ filter_out_names = { 'capital of FRANCE', '  hi ', 'Mine' } })
    local made = {
      titled = chat(home, 'Capital of France', 60),
      greeting = chat(home, false, 70, 'hi'),
      longer = chat(home, false, 80, 'hi there'),
      -- Called "Hi" by its agent, and something else by you.
      renamed = chat(home, 'Hi', 90),
      mine = chat(home, 'Something else', 100),
      -- Its first prompt is one of the names, and its row says its title.
      asked = chat(home, 'A question', 110, 'hi'),
    }
    state().set_name(key(made.renamed), 'Keep this one')
    seen_everything()
    store().refresh_sync()
    eq({ 'A question', 'Keep this one', 'Something else', 'hi there' }, listed())

    -- A name you give a chat counts from the next look on.
    state().set_name(key(made.mine), 'Mine')
    store().refresh_sync({ full = false })
    eq({ 'A question', 'Keep this one', 'hi there' }, listed())
    eq(nil, store().get(key(made.mine)))
  end)

  it('are not read again until their file has changed', function()
    local home = fx.home({ filter_out_names = { 'Capital of France' } })
    local c = chat(home, 'Capital of France', 60)
    local work = chat(home, 'Real work', 150)
    seen_everything()
    local seen = reads(function()
      store().refresh_sync()
    end)
    eq({ [c.id] = 1, [work.id] = 1 }, seen)
    eq({ 'Real work' }, listed())
    for _ = 1, 3 do
      eq(
        {},
        reads(function()
          store().refresh_sync()
          store().refresh_sync({ full = false })
        end)
      )
    end

    -- Still called that after a change: read once, and left out again.
    c.ts = os.time() + 20
    c:user('And of Kenya?'):assistant('Nairobi.'):turn_done():write(os.time() + 21)
    eq(
      { [c.id] = 1 },
      reads(function()
        store().refresh_sync()
        store().refresh_sync()
      end)
    )
    eq({ 'Real work' }, listed())

    -- Called something else now: it is a chat like any other.
    c:custom_title('Capitals of the world'):write(os.time() + 30)
    eq(
      { [c.id] = 1 },
      reads(function()
        store().refresh_sync()
      end)
    )
    eq({ 'Capitals of the world', 'Real work' }, listed())
    ok(store().get(key(c)))
  end)

  it('go out of the list when their agent gives them a name that is left out', function()
    local home = fx.home({ filter_out_names = { 'Capital of France' } })
    local c = chat(home, false, 60, 'What is the capital of France?')
    seen_everything()
    store().refresh_sync()
    eq({ 'What is the capital of France?' }, listed())
    -- Found between two looks for new chats, as a chat that is at work is.
    c:title('Capital of France'):write(os.time() + 5)
    store().refresh_sync({ full = false })
    eq({}, listed())
    eq(nil, store().get(key(c)))
    eq(
      {},
      reads(function()
        store().refresh_sync()
      end)
    )
  end)

  it('are known for that after a restart, without being read', function()
    local root = T.tmpdir()
    local home = fx.home({
      filter_out_names = { 'Capital of France' },
      cache_file = root .. '/index.json',
    })
    local c = chat(home, 'Capital of France', 60)
    local work = chat(home, 'Real work', 150)
    seen_everything()
    store().refresh_sync()
    store().flush()
    -- As a Neovim that has just started has it: nothing but the cache.
    store().reset()
    eq(
      {},
      reads(function()
        store().refresh_sync()
      end)
    )
    eq({ 'Real work' }, listed())
    eq(nil, store().get(key(c)))
    ok(store().get(key(work)))

    -- With other names in the options, what the cache says is not believed.
    store().flush()
    store().reset()
    reconfigure({ filter_out_names = { 'Real work' } })
    local seen = reads(function()
      store().refresh_sync()
    end)
    eq({ [c.id] = 1 }, seen)
    eq({ 'Capital of France' }, listed())
  end)

  it('follow the options when those change', function()
    local _, made = scene()
    hasnt(list(), 'Capital of France  ')
    reconfigure({ filter_out_names = { 'Real work' } })
    local seen = reads(function()
      store().refresh_sync({ full = false })
    end)
    -- The two that were left out are read again, and no other.
    eq({ [made.one.id] = 1, [made.two.id] = 1 }, seen)
    eq({ 'Capital of France', 'Capital of France', 'Capital of France, again' }, listed())
    hasnt(list(), 'Real work')
    eq(nil, store().get(key(made.work)))

    reconfigure({ filter_out_names = {} })
    store().refresh_sync({ full = false })
    eq(4, #listed())
    has(list(), 'Real work')
  end)

  it('have no row while they are running either', function()
    local home = fx.home({ filter_out_names = { 'Capital of France' } })
    local c = chat(home, 'Capital of France', 60)
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, cwd = c.cwd, status = 'busy' })
    seen_everything()
    store().refresh_sync()
    eq({}, listed())
    eq(nil, store().get(key(c)))
    eq(
      {},
      reads(function()
        store().refresh_sync({ full = false })
        store().refresh_sync()
      end)
    )
    eq(nil, store().get(key(c)))
    eq(0, store().counts().working)
  end)

  it('lose the row they had before they had a name', function()
    local home = fx.home({ filter_out_names = { 'Capital of France' } })
    -- Running, and nothing written yet: listed as a chat with no prompt.
    local c = home:chat({ cwd = T.folder('here'), start = os.time() - 5 })
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, cwd = c.cwd })
    seen_everything()
    store().refresh_sync()
    ok(store().get(key(c)), 'a running session has a row')
    ok(store().get(key(c)).stub)
    c:user('What is the capital of France?'):title('Capital of France'):assistant('Paris.')
    c:turn_done():write()
    store().refresh_sync({ full = false })
    eq(nil, store().get(key(c)))
    eq({}, listed())
  end)

  it('are listed all the same while they are open in a terminal of this Neovim', function()
    local home = fx.home({ filter_out_names = { 'Capital of France' } })
    local c = chat(home, 'Capital of France', 60)
    local terms = require('agent-chats.term')
    local buf = api.nvim_create_buf(false, true)
    terms.terms[buf] = { key = key(c), provider = 'claude', owned = true, cwd = c.cwd }
    seen_everything()
    store().refresh_sync()
    eq({ 'Capital of France' }, listed())
    eq(buf, store().get(key(c)).term)
    -- Its terminal is gone: so is the reason to list it.
    terms.terms[buf] = nil
    api.nvim_buf_delete(buf, { force = true })
    store().refresh_sync({ full = false })
    eq({}, listed())
    eq(nil, store().get(key(c)))
  end)

  it('take the chats they started with them', function()
    local home = cx.home({ filter_out_names = { 'Capital of France' } })
    local function thread(prompt, age, meta)
      local r = home:rollout({ cwd = T.folder('here'), start = os.time() - age - 30 })
      r:meta(meta):task_started():user_message(prompt)
      r:agent_message('On it.'):task_complete('On it.')
      return r:write(os.time() - age)
    end
    local parent = thread('What is the capital of France?', 600)
    home:index(parent.id, 'Capital of France')
    local child = thread(
      'What is the capital of France?',
      500,
      { spawned = { parent = parent.id, nickname = 'Beauvoir', path = '/root/geography' } }
    )
    local other = thread('Tidy the tests', 300)
    seen_everything()
    store().refresh_sync()
    eq({ 'Tidy the tests' }, listed())
    eq(nil, store().get('codex:' .. parent.id))
    eq(nil, store().get('codex:' .. child.id), 'not listed in the place of its parent')
    ok(store().get('codex:' .. other.id))

    -- Its parent is called something else now: both are back, the one
    -- under the other. (The second look is for the one that was looked at
    -- before its parent was.)
    home:index(parent.id, 'Geography')
    store().refresh_sync()
    store().refresh_sync()
    eq({ 'Geography', 'Tidy the tests' }, listed())
    eq(
      { 'codex:' .. child.id },
      vim.tbl_map(function(c)
        return c.key
      end, store().children('codex:' .. parent.id))
    )
  end)

  it('are not among the older chats that are not shown', function()
    local home = fx.home({
      board = { max_age_days = 7 },
      filter_out_names = { 'Capital of France' },
    })
    chat(home, 'Capital of France', 90 * 86400)
    chat(home, 'Old work', 90 * 86400)
    seen_everything()
    store().refresh_sync()
    -- Neither has been read: what they are called is not known.
    eq(2, store().older)
    store().show_all = true
    store().refresh_sync()
    eq({ 'Old work' }, listed())
    eq(0, store().older)
    store().show_all = false
    local seen = reads(function()
      store().refresh_sync()
    end)
    eq({}, seen)
    eq({}, listed())
    eq(1, store().older, 'the one that showing the older chats would show')
  end)
end)

describe('the filter_out_names option', function()
  it('compares whole names, whatever their capitals and blanks', function()
    fx.home({ filter_out_names = { 'Capital of France', 'héllo  wörld' } })
    local named_out = config().named_out
    eq('Capital of France', named_out('Capital of France'))
    eq('Capital of France', named_out('CAPITAL OF france'))
    eq('Capital of France', named_out('  Capital   of France\n'))
    eq(nil, named_out('Capital of France?'))
    eq(nil, named_out('Capital'))
    eq('héllo  wörld', named_out('Héllo Wörld'))
    eq(nil, named_out(''))
    eq(nil, named_out(nil))

    -- Nothing named: nothing left out.
    fx.home()
    eq({}, config().get().filter_out_names)
    eq(nil, config().named_out('Capital of France'))
  end)

  it('takes one name as it is, and says what it cannot take', function()
    local said = notes(function()
      fx.home({ filter_out_names = 'Capital of France' })
    end)
    eq('', said)
    eq({ 'Capital of France' }, config().get().filter_out_names)

    said = notes(function()
      fx.home({ filter_out_names = { 'Capital of France', 7, '', { 'nested' } } })
    end)
    has(said, 'filter_out_names takes the names of chats; 7 is not a name, so it is left out')
    has(said, '"" is not a name')
    has(said, '{ "nested" } is not a name')
    eq({ 'Capital of France' }, config().get().filter_out_names)

    said = notes(function()
      fx.home({ filter_out_names = true })
    end)
    has(said, 'filter_out_names must be a list of the names of chats; true is not one')
    eq({}, config().get().filter_out_names)
    no(config().named_out('Capital of France'))
  end)
end)
