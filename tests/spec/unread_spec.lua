-- An unread chat under the cursor. Looking at it marks it read, and read
-- it belongs to another group: but a row does not jump away from under the
-- cursor for that. It stays where it is, with the mark of what it is now,
-- and goes to its new place when the cursor leaves it.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local fake = require('helpers.fake')
local eq, ok, has = T.eq, T.ok, T.has

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

local function chat(home, title, age)
  local c = home:chat({ cwd = vim.uv.cwd(), branch = 'main', start = os.time() - age - 5 })
  c:user('Please ' .. title:lower())
  c:title(title)
  c:assistant('Done.')
  c:turn_done()
  return c:write(os.time() - age)
end

local function settle()
  vim.wait(60, function()
    return false
  end, 10)
end

--- Move the list's cursor to the row of `c`, as a key would.
local function go(c)
  board().focus()
  board().goto_chat(key(c))
  api.nvim_exec_autocmds('CursorMoved', { buffer = board()._state.buf })
  settle()
end

--- The line of the list `c` is on, and the heading it is under.
---@return integer line, string heading, string row
local function place(c)
  local S = board()._state
  local lines = api.nvim_buf_get_lines(S.buf, 0, -1, false)
  for i, row in ipairs(S.rows) do
    if row.kind == 'chat' and row.chat.key == key(c) then
      for j = i, 1, -1 do
        if S.rows[j].kind == 'group' then
          return i, (lines[j]:match('^%S+ (%S+)')), lines[i]
        end
      end
    end
  end
  error('not listed: ' .. key(c))
end

local function cursor()
  return api.nvim_win_get_cursor(board()._state.win)[1]
end

--- Two unread chats and one that has been read, the board open on them.
local function scene()
  local home = fx.home({ board = { spinner = false, intro = false } })
  local made = {
    first = chat(home, 'First unread', 60),
    second = chat(home, 'Second unread', 120),
    old = chat(home, 'Read long ago', 900),
  }
  state().update(function(s)
    s.baseline = os.time() - 300
    s.seen = {}
  end)
  store().refresh_sync()
  store().start = function() end
  board().open()
  return home, made
end

--- What going into a chat or reading it does to its read mark.
local function look_at(c)
  state().mark_seen(key(c))
  store().touch()
end

after_each(function()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
end)

describe('an unread chat under the cursor', function()
  it('stays where it is when it is read, and moves when the cursor leaves it', function()
    local _, made = scene()
    go(made.first)
    local line, heading, row = place(made.first)
    eq('Unread', heading)
    has(row, '✓')
    eq(line, cursor())
    has(api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1], '2 unread')

    look_at(made.first)
    eq('ended', store().get(key(made.first)).status, 'it is read')
    local line2, heading2, row2 = place(made.first)
    eq(line, line2, 'on the line it was on')
    eq('Unread', heading2, 'under the heading it was under')
    eq(line, cursor())
    -- Its mark and the counts say what it is now.
    has(row2, '·')
    has(api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1], '1 unread')
    -- Looked at again, as the board does every few seconds: still there.
    store().refresh_sync()
    eq('Unread', select(2, place(made.first)))
    eq(line, cursor())

    -- The cursor moves on: the chat goes to where it belongs, and the
    -- cursor stays with the row it went to.
    go(made.second)
    eq('Ended', select(2, place(made.first)))
    eq('Unread', select(2, place(made.second)))
    eq((place(made.second)), cursor())
  end)

  it('stays there while you are in the chat, and when you come back', function()
    local home, made = scene()
    fake.install(home)
    go(made.first)
    local line = place(made.first)
    -- Enter: the chat is resumed in the pane, and the cursor is in it.
    local term = actions().open(store().get(key(made.first)))
    ok(term)
    vim.cmd('stopinsert')
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(made.first)).term == term
    end)
    eq('idle', store().get(key(made.first)).status)
    eq('Unread', select(2, place(made.first)))
    eq(line, (place(made.first)))
    board().focus()
    settle()
    eq(line, cursor(), 'back on the row it was left on')
    eq('Unread', select(2, place(made.first)))
    go(made.second)
    eq('Idle', select(2, place(made.first)))
  end)

  it('is kept in place when its live terminal has been in the pane long enough', function()
    local home, made = scene()
    fake.install(home)
    -- The first chat runs in a terminal here, and has finished a turn that
    -- nobody saw end.
    go(made.first)
    local term = actions().open(store().get(key(made.first)))
    vim.cmd('stopinsert')
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local now = store().get(key(made.first))
      return now.term == term and now.pid ~= nil
    end)
    go(made.second)
    local pid = store().get(key(made.first)).pid
    home:registry(pid, { sessionId = made.first.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    made.first.ts = os.time() + 2
    made.first:user('one more'):assistant('there it is'):turn_done():write(os.time() + 3)
    home:registry(pid, { sessionId = made.first.id, status = 'idle', cwd = vim.uv.cwd() })
    store().refresh_sync()
    eq('done', store().get(key(made.first)).status)

    go(made.first)
    local S = board()._state
    eq(term, api.nvim_win_get_buf(S.pane_win))
    local line = place(made.first)
    -- A moment on the row is not looking at it.
    store().refresh_sync()
    eq('done', store().get(key(made.first)).status)
    -- A couple of seconds are.
    S.shown_since = vim.uv.hrtime() - 5e9
    store().refresh_sync()
    eq('idle', store().get(key(made.first)).status)
    local line2, heading, row = place(made.first)
    eq('Unread', heading)
    eq(line, line2)
    eq(line, cursor())
    has(row, '○')
    go(made.second)
    eq('Idle', select(2, place(made.first)))
  end)

  it('goes where it belongs at once when it is marked read by hand', function()
    local _, made = scene()
    go(made.first)
    board().run('unread')
    eq('ended', store().get(key(made.first)).status)
    local line, heading = place(made.first)
    eq('Ended', heading)
    eq(line, cursor(), 'the cursor goes with it')
    -- And back, marked unread again.
    board().run('unread')
    eq('Unread', select(2, place(made.first)))
    -- Every chat at once: the one under the cursor as well.
    go(made.second)
    board().run('read_all')
    eq('Ended', select(2, place(made.second)))
    eq('Ended', select(2, place(made.first)))
  end)

  it(
    'stays unread when you mark it so yourself, however long its terminal is in front of you',
    function()
      local home, made = scene()
      fake.install(home)
      go(made.first)
      local term = actions().open(store().get(key(made.first)))
      vim.cmd('stopinsert')
      T.wait(3000, function()
        store().refresh_sync({ full = false })
        local now = store().get(key(made.first))
        return now.term == term and now.pid ~= nil
      end)
      go(made.first)
      local S = board()._state
      eq(term, api.nvim_win_get_buf(S.pane_win))
      eq('idle', store().get(key(made.first)).status)
      -- Its terminal has been in the pane, beside the list, for a while.
      S.shown_since = vim.uv.hrtime() - 5e9
      ok(board().is_showing(term))
      board().run('unread')
      eq('done', store().get(key(made.first)).status, 'unread, as asked')
      store().refresh_sync()
      eq('done', store().get(key(made.first)).status, 'and still unread at the next look')
      -- Going into it is what reads it.
      actions().open(store().get(key(made.first)))
      vim.cmd('stopinsert')
      eq('idle', store().get(key(made.first)).status)
    end
  )

  it('counts the couple of seconds from the start when the board is opened again', function()
    local home, made = scene()
    fake.install(home)
    go(made.first)
    local term = actions().open(store().get(key(made.first)))
    vim.cmd('stopinsert')
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(made.first)).term == term
    end)
    go(made.first)
    board()._state.shown_since = vim.uv.hrtime() - 5e9
    ok(board().is_showing(term))
    board().close()
    board().open()
    go(made.first)
    eq(term, api.nvim_win_get_buf(board()._state.pane_win))
    T.no(board().is_showing(term), 'it has only just come into view')
  end)

  it('is moved at once by what its agent does', function()
    local home, made = scene()
    go(made.first)
    look_at(made.first)
    eq('Unread', select(2, place(made.first)))
    -- It is taken up again somewhere: that is news, not a read mark.
    home:registry(
      vim.uv.os_getpid(),
      { sessionId = made.first.id, status = 'busy', cwd = vim.uv.cwd() }
    )
    store().refresh_sync({ full = false })
    eq('working', store().get(key(made.first)).status)
    local line, heading = place(made.first)
    eq('Working', heading)
    eq(line, cursor())
    home:unregister(vim.uv.os_getpid())
  end)

  it('keeps its place in a list that is grouped another way', function()
    local _, made = scene()
    -- Grouped by agent, a group is in the order of what its chats are
    -- doing: read, the second chat belongs below one that was read before
    -- it and has moved since.
    made.old.ts = os.time() - 12
    made.old:user('and this'):assistant('Done too.'):turn_done():write(os.time() - 10)
    state().mark_seen(key(made.old), os.time() + 1)
    store().refresh_sync()
    eq('ended', store().get(key(made.old)).status)
    board().set_group('agent')
    go(made.second)
    local line = place(made.second)
    ok(line < (place(made.old)), 'unread comes before read')
    look_at(made.second)
    eq(line, (place(made.second)), 'not moved down among the chats that were read')
    eq(line, cursor())
    go(made.first)
    ok((place(made.second)) > (place(made.old)), 'below the one that moved last, now')
  end)
end)
