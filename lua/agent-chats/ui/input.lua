-- A small floating box for writing a message to an agent: several lines,
-- normal editing, <C-s> (or Enter in normal mode) to send, q / Esc to
-- cancel. One-line questions (a label, a name) go through `vim.ui.input`.
--
-- The box is the plugin's own window and holds the cursor until it is
-- closed, so its keys are its own and fixed; its footer names them.

local api = vim.api

local M = {}

local active ---@type { win: integer, buf: integer, typed: string?, done: fun(text: string?, typed: string?) }?

--- Close the box. `text` is what to send (nil: nothing).
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
  -- Out of the box's insert mode, wherever the cursor has taken it. Not
  -- out of a terminal the cursor has left the box for: typing there is
  -- another thing, and would be ended by this.
  if api.nvim_get_mode().mode ~= 't' then
    vim.cmd.stopinsert()
  end
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
---@field verb string?          What sending is called in the footer ("send" when nil).
---@field review boolean?       Open on text that is there to be read first (notes): in normal mode, at the top. Otherwise the box opens ready to type, after whatever is in it.

--- The line under the box that names its keys: in full where there is
--- room for it, else said more briefly. The key that sends is never left out.
---@param opts agent_chats.InputOpts
---@param room integer?  Cells there are for it; all it takes when nil.
---@return string
function M.footer(opts, room)
  local verb = opts.verb or 'send'
  local forms = {
    (' <C-s> %s · Enter %s (normal mode) · q / Esc cancel '):format(verb, verb),
    (' <C-s> %s · Enter %s (normal) · q / Esc cancel '):format(verb, verb),
    -- How to call it off is kept longer than a second way to send.
    (' <C-s> %s · q / Esc cancel '):format(verb),
    (' <C-s> %s '):format(verb),
  }
  for _, form in ipairs(forms) do
    if not room or vim.api.nvim_strwidth(form) <= room then
      return form
    end
  end
  return forms[#forms]
end

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
  local border = require('agent-chats.config').box_border()
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    border = border,
    -- A title wider than the box is cut by Neovim at its start, which is
    -- the part that says what the box is: cut here instead, at its end.
    title = ' '
      .. require('agent-chats.util.text').truncate(opts.title, math.max(8, width - 4))
      .. ' ',
    footer = M.footer(opts, width - 2),
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
  if opts.review then
    api.nvim_win_set_cursor(win, { 1, 0 })
    return
  end
  -- Ready to type, after what is there (a reply that was kept, a prompt
  -- half written). A moment from now: reached from another box that was
  -- being typed in, that insert mode is still being left, and Neovim
  -- ignores `:startinsert` until it has been.
  api.nvim_win_set_cursor(win, { #start, math.max(0, #start[#start] - 1) })
  -- At once as well: what is typed right behind the key that opened the
  -- box (in one burst, or from a mapping) is text for it, not commands.
  vim.cmd('startinsert!')
  vim.schedule(function()
    if active == mine and api.nvim_get_current_win() == win then
      vim.cmd('startinsert!')
    end
  end)
end

return M
