-- The screens for setting up the agents' status hooks: an overview of which
-- agent has them, and a preview that shows every line an install or removal
-- would change before anything is written.

local api = vim.api
local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local hooks = require('agent-chats.hooks')

local M = {}

local ns = api.nvim_create_namespace('agent-chats-hooks')

local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = 'Agent chats' })
end

local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = 'Agent chats' })
end

local function border()
  local b = config.get().board.border
  if not b and vim.o.winborder == '' then
    b = 'rounded'
  end
  return b
end

--- A centred floating window showing `lines`.
---@return integer buf, integer win
local function float(lines, opts)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].modifiable = false
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.max(20, math.min(width, vim.o.columns - 6))
  local height = math.max(3, math.min(#lines, vim.o.lines - 8))
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    border = border(),
    title = ' ' .. opts.title .. ' ',
    footer = opts.footer and (' ' .. opts.footer .. ' ') or nil,
    footer_pos = opts.footer and 'right' or nil,
    zindex = 65,
  })
  vim.wo[win].wrap, vim.wo[win].cursorline = false, opts.cursorline or false
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn = false, false, 'no'
  return buf, win
end

local function close_win(win)
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

-----------------------------------------------------------------------------
-- Preview and confirm
-----------------------------------------------------------------------------

---@type { win: integer, answer: fun(yes: boolean) }?
local asking

--- Answer the open preview (tests, and the keys below).
function M._answer(yes)
  if asking then
    asking.answer(yes)
  end
end

function M.is_asking()
  return asking ~= nil
end

--- Show what `plans` would change and apply them when the user says so.
---@param plans agent_chats.HookPlan[]
---@param problems string[]
---@param done fun()?
local function confirm(plans, problems, done)
  local action = plans[1].action
  local lines = {}
  for _, plan in ipairs(plans) do
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    vim.list_extend(lines, hooks.diff(plan))
    if plan.note then
      lines[#lines + 1] = '# afterwards: ' .. plan.note
    end
  end
  for _, problem in ipairs(problems) do
    vim.list_extend(lines, { '', '# skipped: ' .. problem })
  end
  vim.list_extend(lines, {
    '',
    action == 'install'
        and '# Each file is backed up beside itself first. Nothing else in it changes.'
      or '# Each file is backed up beside itself first. Only these entries are removed.',
  })
  if asking then
    -- A newer question takes its place: the old one is dropped without
    -- its follow-up (which would open something on top of this one).
    asking.answer(false, true)
  end
  local buf, win = float(lines, {
    title = action == 'install' and 'Install status hooks?' or 'Remove status hooks?',
    footer = 'y apply · n cancel',
    filetype = 'diff',
  })
  local mine
  mine = {
    win = win,
    answer = function(yes, away)
      if asking ~= mine then
        return
      end
      asking = nil
      close_win(win)
      -- Replaced by a newer question, or left for another window: over,
      -- with nothing to follow it (the follow-up would open the overview
      -- on top of whatever was gone to).
      if away then
        return
      end
      if yes then
        local report, all_ok = hooks.apply_all(plans)
        local text = table.concat(report, '\n')
        if all_ok then
          info(text)
        else
          warn(text)
        end
        local store = package.loaded['agent-chats.store']
        if store and store.initialized then
          store.refresh({ full = true })
        end
      end
      if done then
        done()
      end
    end,
  }
  asking = mine
  local function map(lhs, yes)
    vim.keymap.set('n', lhs, function()
      mine.answer(yes)
    end, { buffer = buf, nowait = true, silent = true })
  end
  map('y', true)
  for _, lhs in ipairs({ 'n', 'q', '<Esc>' }) do
    map(lhs, false)
  end
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        mine.answer(false, true)
      end)
    end,
  })
  -- Closed from somewhere else (another window's command, a script):
  -- nobody is being asked any more.
  api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        mine.answer(false, true)
      end)
    end,
  })
end

--- Install or remove hooks after showing what changes.
---@param action "install"|"uninstall"
---@param names string[]?   Provider names; nil or empty: every agent in use.
---@param done fun()?       Called when the question is settled either way.
function M.change(action, names, done)
  local plans, problems = hooks.plans(names, action)
  local todo, settled = {}, {}
  for _, plan in ipairs(plans) do
    if plan.changed or plan.script then
      todo[#todo + 1] = plan
    else
      settled[#settled + 1] = plan.label
    end
  end
  if #todo == 0 then
    local msg = {}
    if #settled > 0 then
      msg[#msg + 1] = (
        action == 'install' and 'Hooks are already installed for %s.'
        or 'No hooks to remove for %s.'
      ):format(table.concat(settled, ', '))
    end
    vim.list_extend(msg, problems)
    if #msg == 0 then
      msg[1] =
        'No agent with hooks to set up was found. :checkhealth agent-chats lists what was looked for.'
    end
    if #problems > 0 then
      warn(table.concat(msg, '\n'))
    else
      info(table.concat(msg, '\n'))
    end
    if done then
      done()
    end
    return
  end
  confirm(todo, problems, done)
end

local by_hand ---@type integer?  The window with the steps, while it is open.

--- The steps to do it by hand, in a window to copy from.
---@param names string[]?
function M.show(names)
  if not names or #names == 0 then
    names = {}
    for _, p in ipairs(hooks.candidates()) do
      names[#names + 1] = p.name
    end
  end
  local lines = {}
  for _, name in ipairs(names) do
    if #lines > 0 then
      vim.list_extend(lines, { '', string.rep('─', 60), '' })
    end
    vim.list_extend(lines, hooks.manual(name))
  end
  if #lines == 0 then
    return info('No agent with hooks to set up was found.')
  end
  -- One at a time: asked for again, it takes the place of the last one.
  close_win(by_hand)
  local buf, win = float(lines, { title = 'Status hooks, by hand', footer = 'q close' })
  by_hand = win
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, function()
      close_win(win)
    end, { buffer = buf, nowait = true, silent = true })
  end
end

-----------------------------------------------------------------------------
-- Overview
-----------------------------------------------------------------------------

local MARKS = {
  installed = { '✓', 'AgentChatsDone' },
  missing = { '·', 'AgentChatsDim' },
  outdated = { '↻', 'AgentChatsAttention' },
  broken = { '!', 'AgentChatsAttention' },
  unsupported = { '!', 'AgentChatsDim' },
  none = { ' ', 'AgentChatsDim' },
}

--- One line per agent on whether its hooks are installed.
---@return string[] lines, agent_chats.HookStatus[] statuses
function M.report()
  local statuses = {}
  for _, p in ipairs(hooks.candidates()) do
    statuses[#statuses + 1] = hooks.status(p.name)
  end
  local wl, wd = 0, 0
  for _, st in ipairs(statuses) do
    wl = math.max(wl, vim.fn.strdisplaywidth(st.label))
    wd = math.max(wd, vim.fn.strdisplaywidth(st.detail))
  end
  local lines = {}
  for _, st in ipairs(statuses) do
    lines[#lines + 1] = ('  %s %s%s  %s%s  %s'):format(
      MARKS[st.state][1],
      st.label,
      string.rep(' ', wl - vim.fn.strdisplaywidth(st.label)),
      st.detail,
      string.rep(' ', wd - vim.fn.strdisplaywidth(st.detail)),
      st.path and fs.tilde(st.path) or ''
    )
  end
  return lines, statuses
end

local overview ---@type integer?  The overview's window, while it is open.

--- The overview: which agents have their hooks, with keys to change that.
function M.open()
  require('agent-chats.ui.highlights').setup()
  -- One at a time: asked for again, it is drawn again in place.
  close_win(overview)
  overview = nil
  local body, statuses = M.report()
  if #statuses == 0 then
    return info(
      'No agent with hooks to set up was found. :checkhealth agent-chats lists what was looked for.'
    )
  end
  local head = {
    '',
    '  With its hooks installed an agent says itself what it is doing: a',
    '  permission prompt or a finished turn shows at once, and "needs you"',
    '  is no longer a guess. Installing shows every change first.',
    '',
  }
  local lines = vim.list_extend(vim.deepcopy(head), body)
  vim.list_extend(
    lines,
    { '', '  a install all   i install   x remove   s do it by hand   q close' }
  )
  local buf, win = float(lines, { title = 'Agent chats: status hooks', cursorline = true })
  overview = win
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      -- Left for another window: do not stay on top of it.
      vim.schedule(function()
        close_win(win)
        if overview == win then
          overview = nil
        end
      end)
    end,
  })
  for i, st in ipairs(statuses) do
    local mark = MARKS[st.state]
    api.nvim_buf_set_extmark(
      buf,
      ns,
      #head + i - 1,
      2,
      { end_col = 2 + #mark[1], hl_group = mark[2] }
    )
  end
  api.nvim_buf_set_extmark(
    buf,
    ns,
    #lines - 1,
    0,
    { end_col = #lines[#lines], hl_group = 'AgentChatsDim' }
  )
  pcall(api.nvim_win_set_cursor, win, { #head + 1, 2 })

  local function current()
    local st = statuses[api.nvim_win_get_cursor(win)[1] - #head]
    return st and st.name or nil
  end
  local function reopen()
    vim.schedule(M.open)
  end
  local function act(fn)
    return function()
      close_win(win)
      fn()
    end
  end
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map(
    'a',
    act(function()
      M.change('install', nil, reopen)
    end)
  )
  for _, lhs in ipairs({ 'i', '<CR>' }) do
    map(lhs, function()
      local name = current()
      if name then
        close_win(win)
        M.change('install', { name }, reopen)
      end
    end)
  end
  map('x', function()
    local name = current()
    if name then
      close_win(win)
      M.change('uninstall', { name }, reopen)
    end
  end)
  map('s', function()
    local name = current()
    close_win(win)
    M.show(name and { name } or nil)
  end)
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    map(lhs, function()
      close_win(win)
    end)
  end
  return win
end

return M
