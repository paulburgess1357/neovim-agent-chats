-- One bar of keys, above the list; no bar on the pane. And the chats that
-- cannot be resumed because their folder is gone: under a heading of their
-- own, out of the way of the ones that can.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local fake = require('helpers.fake')
local eq, ok, has, hasnt = T.eq, T.ok, T.has, T.hasnt

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

--- The bar above the list, as it reads: the highlight codes taken out.
local function bar()
  local raw = vim.wo[board()._state.win].winbar
  return (raw:gsub('%%#%w+#', ''):gsub('%%%*', ''):gsub('%%=', ' | '))
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

local function feed(keys_)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys_, true, false, true), 'mx', false)
end

--- The line of the list a text is on.
local function line_of(words)
  for i, l in ipairs(api.nvim_buf_get_lines(board()._state.buf, 0, -1, false)) do
    if l:find(words, 1, true) then
      return i
    end
  end
end

--- The last line of the list that says something.
local function last_line()
  local lines = api.nvim_buf_get_lines(board()._state.buf, 0, -1, false)
  for i = #lines, 1, -1 do
    if vim.trim(lines[i]) ~= '' then
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

--- Chats in a folder that is there and in one that is not (one of those
--- not read yet); everything else read. The board is open.
local function scene(extra)
  local here = T.folder('here')
  local lost = T.tmpdir() .. '/lost'
  local home = fx.home(vim.tbl_deep_extend('force', { board = { spinner = false } }, extra or {}))
  local made = {
    here = chat(home, 'Still here', here, 60),
    lost = chat(home, 'Lost one', lost, 90),
    older = chat(home, 'Lost and older', lost, 300),
    unread = chat(home, 'Lost and unread', lost, 30),
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
  return home, made, { here = here, lost = lost }
end

T.after_each(function()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
end)

T.describe('chats whose folder is gone', function()
  T.it('are under a heading of their own at the end, folded until it is unfolded', function()
    scene()
    local text = list()
    has(text, '▾ Ended  1   not open, can be resumed')
    has(text, '▸ Folder gone  2   can be read, not resumed')
    ok(line_of('Ended  1') < line_of('Folder gone  2'), 'after the chats that can be resumed')
    hasnt(text, 'Lost one')
    hasnt(text, 'Lost and older')
    -- They are chats like the others: counted.
    has(text, '4 chats · 1 unread')
    -- The pane says what the heading is.
    to_line('Folder gone')
    has(bar(), 'Enter Unfold')
    has(pane():gsub('\n%s*', ' '), 'The folders these chats were in are no longer there')
    has(pane():gsub('\n%s*', ' '), 'can be read and not resumed')
    -- Unfolded, it stays so.
    feed('<CR>')
    settle()
    has(list(), '▾ Folder gone  2')
    has(list(), 'Lost one')
    board().close()
    board().open()
    has(list(), '▾ Folder gone  2')
    to_line('Folder gone')
    feed('<CR>')
    settle()
    has(list(), '▸ Folder gone  2')
  end)

  T.it('are not put away before they have been read', function()
    local _, made = scene()
    -- It finished since the last look: that is said first, wherever it ran.
    has(list(), '▾ Unread  1')
    has(list(), 'Lost and unread')
    board().goto_chat(key(made.unread))
    has(bar(), 'Enter Read')
    -- Enter reads it, and says nothing more: the bar named it.
    local said = notes(function()
      feed('<CR>')
      settle()
    end)
    eq('', said)
    eq('agent-chats-conversation', vim.bo.filetype)
    -- Read, and with the cursor gone from its row, it is with the others.
    board().focus()
    to_line('Still here')
    board().render()
    has(list(), '▸ Folder gone  3')
    hasnt(list(), 'Unread')
  end)

  T.it('are gone to when asked for by name, their heading unfolded', function()
    local _, made = scene()
    ok(board().goto_chat(key(made.older)))
    eq('Lost and older', board().row().chat.title)
    has(list(), '▾ Folder gone  2')
    has(pane(), 'Its folder is gone, so it cannot be resumed.')
  end)

  T.it('stay in a group of your own, and are listed by folder as any chat is', function()
    local _, made, dirs = scene()
    state().set_group(key(made.lost), 'Keep')
    board().render()
    has(list(), '▾ Keep  1')
    has(list(), 'Lost one')
    has(list(), '▸ Folder gone  1')
    -- By folder there is no such heading: the folder is one.
    board().set_group('folder')
    hasnt(list(), 'Folder gone')
    has(list(), 'lost  3')
    board().set_group('status')
    -- A search shows what it finds, folded away or not.
    board().search('older', { conversations = false })
    has(list(), 'Lost and older')
    board().clear()
    -- The folder is there again: so are its chats, among the others.
    vim.fn.mkdir(dirs.lost, 'p')
    board().render()
    hasnt(list(), 'Folder gone')
    has(list(), '▾ Ended  2')
    has(list(), 'Lost and older')
  end)
end)

T.describe('the bar above the list: the keys of the list', function()
  T.it('are at its right on every row, and the first line has the counts alone', function()
    scene()
    local always = ' | + New Chat  S Search  ? Menu '
    to_line('Still here')
    eq(' Enter Resume | C Conversation  A Archive  P Pin  + New Chat  S Search  ? Menu ', bar())
    to_line('Ended')
    eq(' Enter Fold' .. always, bar())
    eq(' 4 chats · 1 unread', api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1])
    -- Notifications are switched in the menu, and that is where it says
    -- which way.
    require('agent-chats.notify').set(false)
    board().render()
    eq(' 4 chats · 1 unread', api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1])
    hasnt(bar():lower(), 'notif')
  end)

  T.it('R looks for changes now, and says when it has', function()
    local home, _, dirs = scene()
    chat(home, 'Made a moment ago', dirs.here, 5)
    hasnt(list(), 'Made a moment ago')
    local said = notes(function()
      feed('R')
      T.wait(3000, function()
        return list():find('Made a moment ago', 1, true) ~= nil
      end)
      settle()
    end)
    has(said, 'The list is up to date')
  end)
end)

T.describe('the pane has no bar of its own', function()
  T.it(
    'whatever it shows, and the bar above the list names the keys of where the cursor is',
    function()
      local home, made = scene()
      local S = board()._state
      local function pane_bar()
        return vim.wo[S.pane_win].winbar
      end
      -- A summary.
      to_line('Still here')
      eq('', pane_bar())
      -- A conversation: its keys, and its menu.
      actions().read(store().get(key(made.here)))
      eq(S.pane_win, api.nvim_get_current_win())
      eq('', pane_bar())
      eq(' q Back  ]] [[ Prompts | ? Menu ', bar())
      -- Back on the list, the keys of the row again.
      feed('q')
      settle()
      eq(S.win, api.nvim_get_current_win())
      has(bar(), 'Enter Resume | C Conversation  A Archive  P Pin  + New Chat')
      -- A chat's terminal: the way back, and nothing else (every other key
      -- is the agent's).
      fake.install(home)
      local buf = actions().open(store().get(key(made.here)))
      ok(buf, 'a terminal was opened')
      eq(S.pane_win, api.nvim_get_current_win())
      eq('', pane_bar())
      eq(' q Back |  ', bar())
      T.typing(function()
        eq([[ <C-\><C-b> Back |  ]], bar())
      end)
      -- Left with a window command, not with the key: the bar follows.
      vim.cmd('wincmd h')
      settle()
      eq(S.win, api.nvim_get_current_win())
      has(bar(), 'Enter Open | C Conversation  A Archive  I Info  + New Chat  S Search  ? Menu ')
      hasnt(bar(), 'Back')
      eq('', pane_bar())
    end
  )
end)

T.describe('archiving a chat', function()
  --- One chat that can be resumed, one whose folder is gone, one in a
  --- folder that is filtered out, and one more to archive. All read.
  local function shelf(extra)
    local lost = T.tmpdir() .. '/lost'
    local home = fx.home(
      vim.tbl_deep_extend(
        'force',
        { board = { spinner = false }, filter_out = { 'waffle' } },
        extra or {}
      )
    )
    local made = {
      keep = chat(home, 'Kept in sight', T.folder('here'), 60),
      away = chat(home, 'Put away', T.folder('here'), 90),
      lost = chat(home, 'Lost one', lost, 120),
      waffle = chat(home, 'Waffle one', T.folder('waffle'), 150),
    }
    state().update(function(s)
      s.baseline = os.time() + 10
    end)
    store().refresh_sync()
    store().start = function() end
    board().open()
    return home, made
  end

  T.it(
    'puts it under a heading at the very end, with one key, and takes it out with the same',
    function()
      local _, made = shelf()
      -- (Three: the one in a folder that is filtered out is not counted.)
      has(list(), '3 chats')
      has(list(), '▾ Ended  2')
      board().goto_chat(key(made.away))
      has(bar(), 'Enter Resume | C Conversation  A Archive  P Pin  + New Chat')
      -- No message: the row is seen to go.
      local said = notes(function()
        feed('A')
        settle()
      end)
      eq('', said)
      local text = list()
      has(text, '▾ Ended  1')
      hasnt(text, 'Put away')
      has(text, '▸ Archived  1   A takes a chat out again')
      -- After everything else, the other headings that are out of the way too.
      ok(line_of('Folder gone  1') < line_of('Filtered out  1'))
      ok(line_of('Filtered out  1') < line_of('Archived  1'))
      eq(last_line(), line_of('Archived  1'))
      -- Not counted: it is put away.
      has(text, '2 chats')
      -- (The two that are left: the one in sight, and the one whose folder
      -- is gone.)
      eq(2, store().counts().ended)
      -- The cursor is on a row still, and the heading says what it is.
      ok(board().row(), 'the cursor is on a row')
      to_line('Archived  1')
      has(bar(), 'Enter Unfold')
      has(pane():gsub('\n%s*', ' '), 'Chats you archived.')
      has(pane():gsub('\n%s*', ' '), 'A on one of them takes it out again')
      -- Unfolded, its chat says how to take it out; and the key does.
      feed('<CR>')
      settle()
      has(list(), 'Put away')
      to_line('Put away')
      has(bar(), 'C Conversation  A Unarchive  + New Chat')
      has(pane(), 'Archived: A takes it out again.')
      feed('A')
      settle()
      hasnt(list(), 'Archived')
      has(list(), '▾ Ended  2')
      has(list(), '3 chats')
    end
  )

  T.it('keeps it there however the list is grouped, and gives it back to its group', function()
    local _, made = shelf()
    state().set_group(key(made.away), 'Release')
    board().render()
    has(list(), '▾ Release  1')
    actions().archive(store().get(key(made.away)))
    hasnt(list(), 'Release')
    has(list(), '▸ Archived  1')
    for _, mode in ipairs({ 'folder', 'agent', 'worktree' }) do
      board().set_group(mode)
      has(list(), '▸ Archived  1', mode)
      eq(last_line(), line_of('Archived  1'), mode)
    end
    board().set_group('status')
    -- A search shows what it finds, under that heading.
    board().search('away', { conversations = false })
    has(list(), '▾ Archived  1')
    has(list(), 'Put away')
    board().clear()
    -- One whose folder is filtered out can be archived as well.
    actions().archive(store().get(key(made.waffle)))
    has(list(), '▸ Archived  2')
    hasnt(list(), 'Filtered out')
    -- Taken out, it is in the group it was in.
    actions().archive(store().get(key(made.away)))
    has(list(), '▾ Release  1')
    has(list(), '▸ Archived  1')
  end)

  T.it('comes back by itself when the chat moves again, and says so from a conversation', function()
    local home, made = shelf()
    -- From where the list is not what is looked at, the key says what it did.
    actions().read(store().get(key(made.away)))
    eq('agent-chats-conversation', vim.bo.filetype)
    local said = notes(function()
      feed('A')
      settle()
    end)
    has(said, 'Archived: it is under “Archived” at the end of the list')
    feed('q')
    settle()
    has(list(), '▸ Archived  1')
    -- A new turn in it: it is a chat to look at again.
    vim.wait(1100)
    local again = home:chat({ id = made.away.id, cwd = T.folder('here'), start = os.time() })
    again:user('Please put away'):title('Put away'):assistant('Done.'):turn_done()
    again:user('One more thing'):assistant('Done as well.'):turn_done()
    again:write(os.time() + 2)
    store().refresh_sync()
    board().render()
    hasnt(list(), 'Archived')
    has(list(), 'Put away')
  end)
end)
