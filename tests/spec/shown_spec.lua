-- The row of the chat that is in the pane is marked in the list: a bar at
-- its left edge and the line set off, whatever the pane shows of the chat
-- and wherever the cursor is.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local fake = require('helpers.fake')
local eq, ok = T.eq, T.ok

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
  return c
end

local function settle()
  vim.wait(60, function()
    return false
  end, 10)
end

local function go(c)
  board().focus()
  board().goto_chat(key(c))
  api.nvim_exec_autocmds('CursorMoved', { buffer = board()._state.buf })
  settle()
end

--- The line of the list `c` is on.
local function line_of(c)
  for i, row in ipairs(board()._state.rows) do
    if row.kind == 'chat' and row.chat.key == key(c) then
      return i
    end
  end
end

--- Every mark that says "this one is in the pane": `{ line, bar, line highlight }`.
local function marks()
  local ns = api.nvim_get_namespaces()['agent-chats-shown']
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(board()._state.buf, ns, 0, -1, { details = true })) do
    local d = m[4]
    out[#out + 1] = { m[2] + 1, d.virt_text and d.virt_text[1][1] or nil, d.line_hl_group }
  end
  return out
end

local function scene(extra)
  local home = fx.home(
    vim.tbl_deep_extend('force', { board = { spinner = false, intro = false } }, extra or {})
  )
  local made = {
    a = chat(home, 'Chat A', 60):write(os.time() - 60),
    b = chat(home, 'Chat B', 120):write(os.time() - 120),
  }
  made.parent = chat(home, 'Parent chat', 300)
  made.parent:subagent('aaa111')
  made.parent:write(os.time() - 300)
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
  store().refresh_sync()
  store().start = function() end
  board().open()
  return home, made
end

after_each(function()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
end)

describe('the chat that is in the pane', function()
  it('is marked in the list, and the mark goes with the cursor', function()
    local _, made = scene()
    go(made.a)
    eq({ { line_of(made.a), '▌', 'AgentChatsShown' } }, marks())
    go(made.b)
    eq({ { line_of(made.b), '▌', 'AgentChatsShown' } }, marks())
    -- The bar takes the place of the blank a row begins with: nothing moves.
    local row =
      api.nvim_buf_get_lines(board()._state.buf, line_of(made.b) - 1, line_of(made.b), false)[1]
    eq(' ', row:sub(1, 1))
    -- Drawn again (as it is every few seconds), it is still there.
    board().render()
    eq({ { line_of(made.b), '▌', 'AgentChatsShown' } }, marks())
  end)

  it('stays marked while the cursor is in the pane: a conversation, a terminal', function()
    local home, made = scene()
    fake.install(home)
    go(made.b)
    actions().read(store().get(key(made.b)))
    settle()
    local S = board()._state
    eq(S.pane_win, api.nvim_get_current_win())
    eq({ { line_of(made.b), '▌', 'AgentChatsShown' } }, marks())
    -- The list is drawn again behind it, with the chat on another line.
    local was = line_of(made.b)
    state().toggle_pin(key(made.b))
    store().touch()
    ok(line_of(made.b) ~= was, 'pinned, it is first in its group')
    eq(S.pane_win, api.nvim_get_current_win())
    eq({ { line_of(made.b), '▌', 'AgentChatsShown' } }, marks())
    state().toggle_pin(key(made.b))
    store().touch()

    -- Its live terminal.
    go(made.a)
    local term = actions().open(store().get(key(made.a)))
    vim.cmd('stopinsert')
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(made.a)).term == term
    end)
    eq(S.pane_win, api.nvim_get_current_win())
    eq({ { line_of(made.a), '▌', 'AgentChatsShown' } }, marks())
    -- A chat opened without the cursor having been on its row: the mark
    -- says what the pane shows, not where the list's cursor is.
    actions().read(store().get(key(made.b)))
    settle()
    eq({ { line_of(made.b), '▌', 'AgentChatsShown' } }, marks())
    ok(api.nvim_win_get_cursor(S.win)[1] ~= line_of(made.b))
  end)

  it('is the chat a subagent belongs to, when the subagent has no row', function()
    local _, made = scene()
    go(made.parent)
    local sub = store().load_children(store().get(key(made.parent)))[1]
    ok(sub, 'the chat has a subagent')
    go(made.a)
    actions().read(sub)
    settle()
    eq({ { line_of(made.parent), '▌', 'AgentChatsShown' } }, marks())
  end)

  it('is not marked where the pane shows no chat', function()
    local _, made = scene()
    go(made.a)
    eq(1, #marks())
    -- On a heading.
    local S = board()._state
    for i, row in ipairs(S.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(S.win, { i, 1 })
        break
      end
    end
    api.nvim_exec_autocmds('CursorMoved', { buffer = S.buf })
    settle()
    eq({}, marks())
    -- With the pane hidden.
    go(made.a)
    eq(1, #marks())
    board().toggle_pane()
    eq({}, marks())
    board().toggle_pane()
    eq({ { line_of(made.a), '▌', 'AgentChatsShown' } }, marks())
    -- With the pane closed by hand.
    api.nvim_win_close(S.pane_win, true)
    settle()
    eq({}, marks())
  end)

  it('is not marked while the pane introduces the board', function()
    scene({ board = { intro = true } })
    settle()
    eq({}, marks())
  end)

  it('is set off by the line alone where the bar is switched off', function()
    local _, made = scene({ icons = { shown = '' } })
    go(made.a)
    eq({ { line_of(made.a), nil, 'AgentChatsShown' } }, marks())
  end)
end)
