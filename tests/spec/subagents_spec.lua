-- Chats that another chat started: the subagents an agent hands part of its
-- work to. They belong to the chat that started them, and are listed under
-- it when its row is unfolded; with `hide_subagents` they are not listed at
-- all, and the board has the chats you talk to yourself and no others.

local T = require('helpers.harness')
local cx = require('helpers.codex')
local fx = require('helpers.claude')
local hk = require('helpers.hooks')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt

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
local function codex()
  return require('agent-chats.providers.codex')
end

local function list()
  return T.buf_text(board()._state.buf)
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

--- The keys of the chats that have a row of their own, in order.
local function listed()
  local keys = vim.tbl_map(function(c)
    return c.key
  end, store().list())
  table.sort(keys)
  return keys
end

--- `keys` in the order `listed` gives them.
local function these(...)
  local keys = { ... }
  table.sort(keys)
  return keys
end

--- Everything is read: nothing here is about what is unread.
local function seen_everything()
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
end

--- A Codex chat that finished its turn `age` seconds ago.
local function thread(home, prompt, age)
  local r = home:rollout({ cwd = T.folder('here'), start = os.time() - age - 30 })
  r.prompt = prompt
  r:meta():context():task_started():user_message(prompt)
  r:agent_message('On it.'):task_complete('On it.')
  return r:write(os.time() - age)
end

--- A thread that `parent` spawned, as Codex writes one: its own header,
--- then the conversation it was spawned from (header and all), then what
--- it did itself.
local function spawned(home, parent, nickname, path, age)
  local r = home:rollout({ cwd = parent.cwd, start = os.time() - age - 20 })
  r:meta({ spawned = { parent = parent.id, nickname = nickname, path = path } })
  r:_line(
    'session_meta',
    vim.json.encode({ session_id = parent.id, id = parent.id, cwd = parent.cwd, source = 'cli' })
  )
  r:task_started():user_message(parent.prompt or 'Plan the release')
  r:task_started():agent_message('Looked into it.'):task_complete('Looked into it.')
  return r:write(os.time() - age)
end

local function ck(r)
  return 'codex:' .. r.id
end

--- A Codex chat that spawned two threads; the board is open.
local function scene(extra)
  local home = cx.home(vim.tbl_deep_extend('force', { board = { spinner = false } }, extra or {}))
  local made = {}
  made.parent = thread(home, 'Plan the release', 600)
  home:index(made.parent.id, 'Release plan')
  made.one = spawned(home, made.parent, 'Beauvoir', '/root/onboarding', 500)
  made.two = spawned(home, made.parent, 'Helmholtz', '/root/interaction', 400)
  made.other = thread(home, 'Tidy the tests', 300)
  seen_everything()
  store().refresh_sync()
  store().start = function() end
  board().open()
  return home, made
end

after_each(function()
  pcall(function()
    require('agent-chats.ui.menu').close()
  end)
  pcall(function()
    board().close()
  end)
end)

describe('a thread that Codex spawned', function()
  it('says which thread spawned it, and goes by the name Codex gave it', function()
    local home = cx.home()
    local parent = thread(home, 'Plan the release', 600)
    local child = spawned(home, parent, 'Beauvoir', '/root/onboarding', 500)
    local by = {}
    for _, e in ipairs(codex().discover()) do
      by[e.id] = e
    end
    local p = codex().parse(by[child.id])
    eq(parent.id, p.parent_id)
    eq('subagent', p.origin)
    -- Its rollout begins with the conversation it was spawned from: by its
    -- first prompt it would be called what its parent is.
    eq('Plan the release', p.first_prompt)
    eq('Beauvoir: onboarding', p.title)
    eq(nil, codex().parse(by[parent.id]).parent_id)
    eq(nil, codex().parse(by[parent.id]).title)

    -- Read again from its tail alone, it keeps both.
    local prev =
      vim.tbl_extend('force', p, { path = child.path, id = child.id, key = 'codex:' .. child.id })
    child:task_started():agent_message('One more thing.'):task_complete('One more thing.'):write()
    local again
    for _, e in ipairs(codex().discover()) do
      if e.id == child.id then
        again = codex().parse(e, prev)
      end
    end
    eq(parent.id, again.parent_id)
    eq('Beauvoir: onboarding', again.title)
    eq('One more thing.', again.last_reply)

    -- A title in Codex's own index is the title.
    home:index(child.id, 'Onboarding review')
    for _, e in ipairs(codex().discover()) do
      if e.id == child.id then
        eq('Onboarding review', codex().parse(e).title)
      end
    end
  end)

  it('is told from a fork, which is a chat of its own', function()
    local home = cx.home()
    local first = thread(home, 'Plan the release', 600)
    local fork = home:rollout({ cwd = first.cwd, start = os.time() - 300 })
    fork:meta({ forked = first.id }):task_started():user_message('Another way to plan it')
    fork:agent_message('Here is one.'):task_complete('Here is one.'):write()
    -- With no name and no path, and its parent named outside `source`.
    local bare = home:rollout({ cwd = first.cwd, start = os.time() - 200 })
    bare:_line(
      'session_meta',
      vim.json.encode({
        id = bare.id,
        cwd = bare.cwd,
        source = { subagent = 'review' },
        thread_source = 'subagent',
        parent_thread_id = first.id,
      })
    )
    bare:task_started():agent_message('Reviewed.'):task_complete('Reviewed.'):write()
    local by = {}
    for _, e in ipairs(codex().discover()) do
      by[e.id] = codex().parse(e)
    end
    eq(nil, by[fork.id].parent_id)
    eq(nil, by[fork.id].title)
    eq(first.id, by[bare.id].parent_id)
    eq('subagent', by[bare.id].title)
  end)

  it('is listed under the chat that spawned it, when that row is unfolded', function()
    local _, made = scene()
    eq(these(ck(made.other), ck(made.parent)), listed())
    local text = list()
    has(text, '2 chats')
    has(text, 'Release plan')
    hasnt(text, 'Beauvoir')
    hasnt(text, 'Helmholtz')
    eq(2, store().counts().ended)

    ok(board().goto_chat(ck(made.parent)))
    board().toggle_row()
    text = list()
    has(text, '└')
    has(text, 'Beauvoir: onboarding')
    has(text, 'Helmholtz: interaction')
    has(text, '2 chats', 'they are not counted as chats of their own')
    board().toggle_row()
    hasnt(list(), 'Beauvoir')
  end)

  it('is a row of its own when the chat that spawned it is not there', function()
    local home = cx.home({ board = { spinner = false } })
    local gone = { id = cx.uuid(), cwd = T.folder('here') }
    local orphan = spawned(home, gone, 'Hume', '/root/review', 300)
    seen_everything()
    store().refresh_sync()
    eq({ ck(orphan) }, listed())
    eq('Hume: review', require('agent-chats.display').title(store().get(ck(orphan))))
  end)
end)

describe('hide_subagents', function()
  it('leaves the chats that another chat started out of the list', function()
    local _, made = scene({ hide_subagents = true })
    eq(these(ck(made.other), ck(made.parent)), listed())
    has(list(), '2 chats')
    eq({}, store().children(ck(made.parent)))
    eq({}, store().load_children(store().get(ck(made.parent))))

    -- Unfolding the row shows none, and says why.
    ok(board().goto_chat(ck(made.parent)))
    local said = notes(function()
      board().toggle_row()
    end)
    has(said, 'Subagents are not shown: hide_subagents is on in the options.')
    hasnt(list(), 'Beauvoir')
    -- The menu does not offer them either.
    board().menu()
    local menu = table.concat(require('agent-chats.ui.menu').lines(), '\n')
    require('agent-chats.ui.menu').close()
    has(menu, 'Read the conversation')
    hasnt(menu, 'subagents')

    -- A search goes through the chats that are listed.
    board().search('Looked into it')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    hasnt(list(), 'Beauvoir')
    has(list(), 'No chat has “Looked into it” in it.')
  end)

  it('is taken up by a board that is open when the options change', function()
    local _, made = scene()
    ok(board().goto_chat(ck(made.parent)))
    board().toggle_row()
    has(list(), 'Beauvoir: onboarding')
    local opts = vim.deepcopy(config().get())
    opts.hide_subagents = true
    config().setup(opts)
    hasnt(list(), 'Beauvoir')
    has(list(), 'Release plan')
    opts.hide_subagents = false
    config().setup(opts)
    has(list(), 'Beauvoir: onboarding')
  end)

  it('lists no subagent in the place of a chat that is not there', function()
    local home =
      cx.home({ board = { spinner = false }, hide_subagents = true, notify = { enabled = true } })
    local gone = { id = cx.uuid(), cwd = T.folder('here') }
    local orphan = spawned(home, gone, 'Hume', '/root/review', 300)
    seen_everything()
    store().refresh_sync()
    eq({}, listed())
    eq(0, store().counts().ended)
    ok(store().get(ck(orphan)), 'it is still known')

    -- And nothing is said when it finishes a turn: it has no row to go to.
    require('agent-chats.notify').setup()
    state().update(function(s)
      s.baseline = os.time() - 3000
    end)
    orphan.ts = os.time() + 20
    orphan:task_started():agent_message('Reviewed again.'):task_complete('Reviewed again.')
    orphan:write(os.time() + 21)
    local said = notes(function()
      store().refresh_sync()
    end)
    eq('done', store().get(ck(orphan)).status)
    hasnt(said, 'Finished')
  end)

  it('announces such a subagent where they are not hidden', function()
    local home = cx.home({ board = { spinner = false }, notify = { enabled = true } })
    local gone = { id = cx.uuid(), cwd = T.folder('here') }
    local orphan = spawned(home, gone, 'Hume', '/root/review', 300)
    seen_everything()
    store().refresh_sync()
    require('agent-chats.notify').setup()
    state().update(function(s)
      s.baseline = os.time() - 3000
    end)
    orphan.ts = os.time() + 20
    orphan:task_started():agent_message('Reviewed again.'):task_complete('Reviewed again.')
    orphan:write(os.time() + 21)
    has(
      notes(function()
        store().refresh_sync()
      end),
      'Finished: Hume: review'
    )
  end)

  it('does not look for the subagents of Claude Code', function()
    local home = fx.home({ board = { spinner = false }, hide_subagents = true })
    local c = home:chat({ cwd = T.folder('here'), start = os.time() - 700 })
    c:user('Fix the parser'):title('Fix the parser'):assistant('Done.'):turn_done()
    c:write(os.time() - 600)
    c:subagent('aaa111', { agentType = 'Explore', description = 'Find parser files' })
    local claude = require('agent-chats.providers.claude')
    local real, asked = claude.subagents, 0
    claude.subagents = function(...)
      asked = asked + 1
      return real(...)
    end
    local good, err = pcall(function()
      seen_everything()
      store().refresh_sync()
      store().start = function() end
      board().open()
      ok(board().goto_chat('claude:' .. c.id))
      has(
        notes(function()
          board().toggle_row()
        end),
        'Subagents are not shown'
      )
      hasnt(list(), 'Find parser files')
      board().menu()
      hasnt(table.concat(require('agent-chats.ui.menu').lines(), '\n'), 'subagents')
    end)
    claude.subagents = real
    assert(good, err)
    eq(0, asked)
  end)

  it('still lets a chat say that one it started is waiting for you', function()
    local qx = require('helpers.qwen')
    local home = qx.home({ hide_subagents = true })
    local parent = home:chat({ start = os.time() - 60 })
    parent:user('Split the work'):tool_call('agent', { prompt = 'do part one' }):write()
    local child = home:chat({ start = os.time() - 40 })
    child:parent(parent.id):user('do part one'):tool_call('run_shell_command', { command = 'make' })
    child:write()
    home:registry(vim.uv.os_getpid(), { sessionId = parent.id })
    home:registry(vim.uv.os_getpid(), { sessionId = child.id }, 'b')
    hk.event('qwen', parent.id, 'UserPromptSubmit', { t = os.time() - 61 })
    hk.event('qwen', child.id, 'PermissionRequest', { tool = 'run_shell_command' })
    store().refresh_sync()
    local p = store().get('qwen:' .. parent.id)
    eq('attention', p.status)
    eq('qwen:' .. child.id, p.through)
    eq({ 'qwen:' .. parent.id }, listed())
    eq(1, store().counts().attention)
    local summary = table.concat(require('agent-chats.ui.preview').lines(p), '\n')
    has(summary, 'Needs you: a chat it started is waiting.')
  end)

  it('is true or false, and says so of anything else', function()
    local said = notes(function()
      fx.home({ hide_subagents = 'yes' })
    end)
    has(said, 'hide_subagents must be true or false; "yes" is neither')
    eq(false, config().get().hide_subagents)
    said = notes(function()
      fx.home({ hide_subagents = true })
    end)
    eq('', said)
    eq(true, config().get().hide_subagents)
    fx.home()
    no(config().get().hide_subagents)
  end)
end)
