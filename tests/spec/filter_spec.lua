-- Folders that the options filter out (`filter_out`). Their chats are not
-- among the others: they are under a heading of their own at the end of the
-- list, folded, and nothing about them asks for attention.

local T = require('helpers.harness')
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
local function actions()
  return require('agent-chats.actions')
end

local function key(c)
  return 'claude:' .. c.id
end

local function chat(home, title, cwd, age)
  local c = home:chat({ cwd = cwd, branch = 'main', start = os.time() - age - 5 })
  c:user('Please ' .. title:lower())
  c:title(title)
  c:assistant('Done.')
  c:turn_done()
  return c:write(os.time() - age)
end

local function list()
  return T.buf_text(board()._state.buf)
end

local function pane()
  return T.buf_text(api.nvim_win_get_buf(board()._state.pane_win))
end

local function settle()
  vim.wait(60, function()
    return false
  end, 10)
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

--- The line of the list a text is on.
local function line_of(words)
  for i, l in ipairs(api.nvim_buf_get_lines(board()._state.buf, 0, -1, false)) do
    if l:find(words, 1, true) then
      return i
    end
  end
end

local function to_line(words)
  local S = board()._state
  api.nvim_set_current_win(S.win)
  api.nvim_win_set_cursor(S.win, { assert(line_of(words), words), 1 })
  api.nvim_exec_autocmds('CursorMoved', { buffer = S.buf })
  settle()
end

--- Folders that are really there: one called "waffle", one inside it, one
--- whose name only begins the same way, and one that has nothing to do
--- with it.
local function folders()
  local root = T.tmpdir()
  local dirs = {
    root = root,
    waffle = root .. '/waffle',
    inside = root .. '/waffle/app',
    near = root .. '/waffle-house',
    work = root .. '/work',
  }
  for _, dir in pairs(dirs) do
    vim.fn.mkdir(dir, 'p')
  end
  return dirs
end

--- Two chats in the folder that is filtered out (one of them unread), one
--- inside it, and two elsewhere; everything else read. The board is open.
local function scene(extra, dirs)
  dirs = dirs or folders()
  local home = fx.home(
    vim.tbl_deep_extend(
      'force',
      { board = { spinner = false }, filter_out = { 'waffle' } },
      extra or {}
    )
  )
  local made = {
    waffle = chat(home, 'Waffle one', dirs.waffle, 60),
    unread = chat(home, 'Waffle unread', dirs.waffle, 30),
    inside = chat(home, 'Waffle inside', dirs.inside, 90),
    near = chat(home, 'Near miss', dirs.near, 120),
    work = chat(home, 'Real work', dirs.work, 150),
  }
  state().update(function(s)
    s.baseline = os.time() - 3000
    s.seen = {}
    for name, c in pairs(made) do
      if name ~= 'unread' then
        s.seen[key(c)] = os.time() + 10
      end
    end
  end)
  store().refresh_sync()
  store().start = function() end
  board().open()
  return home, made, dirs
end

after_each(function()
  pcall(function()
    board().close()
  end)
end)

describe('folders that are filtered out', function()
  it('have their chats under a heading of their own, last and folded', function()
    local _, made = scene()
    local text = list()
    -- Counted apart: the first line is about the chats that are not.
    has(text, '2 chats')
    hasnt(vim.split(text, '\n')[1], 'unread')
    has(text, '▸ Filtered out  3   folders named in filter_out')
    hasnt(text, 'Waffle')
    has(text, 'Near miss')
    has(text, 'Real work')
    -- After every other group.
    ok(line_of('Filtered out') > line_of('Real work'))
    ok(line_of('Filtered out') > line_of('Ended'))

    -- Unfolded like any group, and it stays so.
    to_line('Filtered out')
    has(vim.wo[board()._state.win].winbar, 'Unfold')
    board().run('open')
    text = list()
    has(text, '▾ Filtered out  3')
    has(text, 'Waffle one')
    has(text, 'Waffle inside')
    -- What wants a look comes first in it.
    ok(line_of('Waffle unread') < line_of('Waffle one'))
    has(vim.wo[board()._state.win].winbar, 'Fold')
    board().close()
    board().open()
    has(list(), 'Waffle one')
    to_line('Filtered out')
    board().run('open')
    hasnt(list(), 'Waffle one')
    eq('ended', store().get(key(made.waffle)).status)
  end)

  it('are left out of the counts, the notifications and the next chat that needs you', function()
    local _, made = scene({ notify = { enabled = true } })
    eq('done', store().get(key(made.unread)).status)
    eq(0, store().counts().done)
    eq(2, store().counts().ended)
    eq('', require('agent-chats').statusline())
    eq({}, actions().waiting())
    has(
      notes(function()
        actions().next()
      end),
      'No chat needs you right now.'
    )

    -- A turn ends in the folder: the event is raised for whoever listens,
    -- and nothing is said.
    require('agent-chats.notify').setup()
    local heard = {}
    api.nvim_create_autocmd('User', {
      pattern = 'AgentChatsDone',
      callback = function(ev)
        heard[#heard + 1] = ev.data.key
      end,
    })
    local function finish(c)
      -- (After the moment it was last looked at.)
      c.ts = os.time() + 20
      c:user('One more thing'):assistant('Done again.'):turn_done():write(os.time() + 21)
    end
    finish(made.waffle)
    finish(made.work)
    local said = notes(function()
      store().refresh_sync()
    end)
    eq('done', store().get(key(made.waffle)).status)
    eq('done', store().get(key(made.work)).status)
    has(said, 'Finished: Real work')
    hasnt(said, 'Waffle')
    table.sort(heard)
    local both = { key(made.waffle), key(made.work) }
    table.sort(both)
    eq(both, heard)
    eq(1, store().counts().done)
    eq(
      { key(made.work) },
      vim.tbl_map(function(c)
        return c.key
      end, actions().waiting())
    )
  end)

  it('are found by a search, and shown open under their heading', function()
    scene()
    board().search('waffle')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    local text = list()
    has(text, '▾ Filtered out  3')
    has(text, 'Waffle one')
    has(text, 'Waffle inside')
    has(text, 'Near miss')
    -- What a search found is counted whole.
    has(vim.split(text, '\n')[1], '4 chats')
    board().clear()
    hasnt(list(), 'Waffle one')
  end)

  it('are apart however the list is grouped, and whatever group a chat was put in', function()
    local _, made = scene()
    for _, mode in ipairs({ 'folder', 'agent', 'worktree' }) do
      board().set_group(mode)
      local text = list()
      has(text, '▸ Filtered out  3', mode)
      hasnt(text, 'Waffle one', mode)
      has(text, 'Real work', mode)
      eq(api.nvim_buf_line_count(board()._state.buf) - 1, line_of('Filtered out'), mode)
    end
    board().set_group('status')
    -- A group of your own does not bring it back, and that is said.
    state().set_group(key(made.waffle), 'Later')
    store().touch()
    hasnt(list(), 'Later')
    has(list(), '▸ Filtered out  3')
    vim.ui.select = function(items, _, cb)
      for _, item in ipairs(items) do
        if item.new then
          return cb(item)
        end
      end
    end
    vim.ui.input = function(_, cb)
      cb('Sooner')
    end
    to_line('Filtered out')
    board().run('open')
    to_line('Waffle inside')
    local said = notes(function()
      board().run('move')
    end)
    eq('Sooner', state().group(key(made.inside)))
    has(said, 'It stays under “Filtered out”')
    hasnt(list(), '▾ Sooner')
  end)

  it('say in the pane where the chats come from, and how they get out', function()
    local _, _, dirs = scene({ filter_out = { 'waffle', '~/no/such/folder' } })
    to_line('Filtered out')
    local text = pane():gsub('\n%s*', ' ')
    has(text, 'folds and unfolds this group.')
    has(text, 'the options filter out (filter_out): waffle, ~/no/such/folder.')
    has(text, 'left out of the counts and the notifications')
    has(text, 'Take a folder out of filter_out')
    -- On a chat of it: why it is here, beside its folder.
    board().run('open')
    to_line('Waffle one')
    text = pane():gsub('\n%s*', ' ')
    has(text, 'Folder')
    has(text, 'filtered out in the options')
    to_line('Real work')
    hasnt(pane(), 'filtered out')
    ok(dirs.work)
  end)

  it('are gone to like any chat: its group is unfolded for it', function()
    local _, made = scene()
    hasnt(list(), 'Waffle inside')
    ok(board().goto_chat(key(made.inside)))
    has(list(), '▾ Filtered out  3')
    eq(key(made.inside), board().current().key)
  end)

  it('leave nothing but their heading where every chat is in one', function()
    local dirs = folders()
    local home = fx.home({ board = { spinner = false }, filter_out = { 'waffle' } })
    chat(home, 'Waffle one', dirs.waffle, 60)
    store().refresh_sync()
    store().start = function() end
    board().open()
    local text = list()
    has(text, '0 chats')
    has(text, '▸ Filtered out  1')
    hasnt(text, 'No chats yet')
    eq('group', board().row().kind)
  end)
end)

describe('the filter_out option', function()
  it('takes a name for every folder called that, and a path for one folder', function()
    local dirs = folders()
    fx.home({ filter_out = { 'waffle' } })
    local filtered = config().filtered
    eq('waffle', filtered(dirs.waffle))
    eq('waffle', filtered(dirs.inside))
    eq('waffle', filtered('/somewhere/else/waffle/deep/down'))
    eq(nil, filtered(dirs.near), 'a name is a whole name')
    eq(nil, filtered(dirs.work))
    eq(nil, filtered(nil))
    eq(nil, filtered(''))

    -- A path: that folder and what is inside it, and no other of its name.
    fx.home({ filter_out = { dirs.waffle .. '/' } })
    filtered = config().filtered
    eq(dirs.waffle .. '/', filtered(dirs.waffle))
    eq(dirs.waffle .. '/', filtered(dirs.inside))
    eq(nil, filtered('/somewhere/else/waffle'))
    eq(nil, filtered(dirs.near))

    -- From the home folder, and a folder in a folder.
    fx.home({ filter_out = { '~/tmp/scratch', 'play/waffle' } })
    filtered = config().filtered
    eq('~/tmp/scratch', filtered(vim.fs.normalize('~/tmp/scratch/one')))
    eq(nil, filtered(vim.fs.normalize('~/tmp')))
    eq('play/waffle', filtered('/home/someone/play/waffle'))
    eq(nil, filtered('/home/someone/work/waffle'))

    -- Nothing named: nothing filtered.
    fx.home()
    eq({}, config().get().filter_out)
    eq(nil, config().filtered(dirs.waffle))
  end)

  it('takes one folder as it is, and says what it cannot take', function()
    local said = notes(function()
      fx.home({ filter_out = 'waffle' })
    end)
    eq('', said)
    eq({ 'waffle' }, config().get().filter_out)

    said = notes(function()
      fx.home({ filter_out = { 'waffle', 7, '', { 'nested' } } })
    end)
    has(said, 'filter_out takes the names or paths of folders; 7 is neither, so it is left out')
    has(said, '"" is neither')
    has(said, '{ "nested" } is neither')
    eq({ 'waffle' }, config().get().filter_out)

    said = notes(function()
      fx.home({ filter_out = true })
    end)
    has(said, 'filter_out must be a list of folder names or paths; true is not one')
    eq({}, config().get().filter_out)
    no(config().filtered('/a/waffle'))
  end)

  it('is taken up by a board that is open when the options change', function()
    local _, _, dirs = scene()
    has(list(), '▸ Filtered out  3')
    local opts = vim.deepcopy(config().get())
    opts.filter_out = { 'work' }
    config().setup(opts)
    local text = list()
    has(text, '▸ Filtered out  1')
    has(text, 'Waffle one')
    hasnt(text, 'Real work')
    eq(1, store().counts().done, 'counted again under the new options')
    ok(dirs.work)
  end)
end)
