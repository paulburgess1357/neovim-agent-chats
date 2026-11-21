-- A small floating box for writing a message to an agent: several lines,
-- normal editing, <C-s> (or <CR> in normal mode) to send, q / <Esc> to
-- cancel. One-line questions (a label, a name) go through `vim.ui.input`.

local api = vim.api

local M = {}

local active ---@type { win: integer, buf: integer, typed: string?, done: fun(text: string?, typed: string?) }?

local function finish(text)
  local cur = active
  if not cur then
    return
  end
  active = nil
  -- What is in the box, whether it is being sent or not: a caller may want
  -- to keep text that was written and then not sent.
  -- (A box closed with :q or :bdelete has taken its buffer with it by the
  -- time this runs; `cur.typed` is what it held when it was left.)
  local typed = cur.typed
  if api.nvim_buf_is_valid(cur.buf) and api.nvim_buf_is_loaded(cur.buf) then
    typed = table.concat(api.nvim_buf_get_lines(cur.buf, 0, -1, false), '\n')
  end
  vim.cmd.stopinsert()
  if api.nvim_win_is_valid(cur.win) then
    pcall(api.nvim_win_close, cur.win, true)
  end
  if api.nvim_buf_is_valid(cur.buf) then
    pcall(api.nvim_buf_delete, cur.buf, { force = true })
  end
  cur.done(text, typed)
end

--- Send what is in the box.
function M.submit()
  if not active then
    return
  end
  local lines = api.nvim_buf_get_lines(active.buf, 0, -1, false)
  finish(vim.trim(table.concat(lines, '\n')))
end

function M.cancel()
  finish(nil)
end

function M.is_open()
  return active ~= nil
end

---@class agent_chats.InputOpts
---@field title string
---@field text string?         Text to start with.
---@field height integer?
---@field allow_empty boolean?  Call back with "" instead of treating it as a cancel.

--- Ask for a message. `cb(text, typed)` gets the text, or nil when
--- cancelled; `typed` is what was in the box either way.
---@param opts agent_chats.InputOpts
---@param cb fun(text: string?, typed: string?)
function M.open(opts, cb)
  if active then
    M.cancel()
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'agent-chats-input'
  local start = opts.text and vim.split(opts.text, '\n', { plain = true }) or { '' }
  api.nvim_buf_set_lines(buf, 0, -1, false, start)

  local width = math.max(30, math.min(96, vim.o.columns - 8))
  local height = math.max(3, math.min(opts.height or math.max(6, #start + 1), vim.o.lines - 8))
  local border = require('agent-chats.config').get().board.border
  if not border and vim.o.winborder == '' then
    border = 'rounded'
  end
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    border = border,
    title = ' ' .. opts.title .. ' ',
    footer = ' <C-s> send · <CR> send (normal mode) · q / <Esc> cancel ',
    footer_pos = 'right',
    zindex = 60,
  })
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn = false, false, 'no'

  active = {
    win = win,
    buf = buf,
    typed = opts.text,
    done = function(text, typed)
      if text == '' and not opts.allow_empty then
        text = nil
      end
      cb(text, typed)
    end,
  }

  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map({ 'n', 'i' }, '<C-s>', M.submit)
  map('n', '<CR>', M.submit)
  map('n', 'q', M.cancel)
  map('n', '<Esc>', M.cancel)
  local mine = active
  -- Whatever closes the box (:q, :close, ZZ, :bdelete, another window
  -- taking the focus), what was written is read while it is still there.
  local function remember()
    if api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) then
      mine.typed = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    end
  end
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'InsertLeave', 'BufUnload' }, {
    buffer = buf,
    callback = remember,
  })
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      remember()
      vim.schedule(function()
        -- Only this box: another may have opened since.
        if active == mine then
          M.cancel()
        end
      end)
    end,
  })
  if not opts.text or opts.text == '' then
    vim.cmd.startinsert()
  else
    api.nvim_win_set_cursor(win, { #start, 0 })
  end
end

return M
