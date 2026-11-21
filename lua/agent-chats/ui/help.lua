-- The board's key reference (g?).

local api = vim.api
local config = require('agent-chats.config')

local M = {}

--- Lines of the key reference, from the keys actually configured.
---@return string[] lines, { [1]: integer, [2]: integer, [3]: integer }[] key_spans
function M.lines()
  local icons = config.get().icons
  local rows, widest = {}, 0
  for _, d in ipairs(require('agent-chats.ui.board').descriptions) do
    local lhs = config.keys_of(d[1])
    if #lhs > 0 then
      local shown = table.concat(lhs, ' / ')
      rows[#rows + 1] = { shown, d[2] }
      widest = math.max(widest, vim.fn.strdisplaywidth(shown))
    end
  end
  local lines, spans = {}, {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ('  %s%s  %s'):format(
      r[1],
      string.rep(' ', widest - vim.fn.strdisplaywidth(r[1])),
      r[2]
    )
    spans[#spans + 1] = { #lines - 1, 2, 2 + #r[1] }
  end
  vim.list_extend(lines, {
    '',
    ('  %s needs you   %s working   %s done, unread   %s idle   %s ended'):format(
      icons.attention,
      icons.working,
      icons.done,
      icons.idle,
      icons.ended
    ),
    ('  %s%s  a guess: quiet on a tool call, probably waiting for approval'):format(
      icons.attention,
      icons.inferred
    ),
    ('  %s  running outside this Neovim: it can be read here, not typed into'):format(
      icons.elsewhere
    ),
    '',
    '  The pane shows the live terminal of a chat running in this Neovim,',
    '  and a summary of any other chat.' .. config.hint('open', ' %s goes into the terminal;'),
    ('  %s comes back to this list.'):format(config.get().open.back_key or ':Chats'),
    '',
    '  What a chat is doing comes from its agent: through its hooks once',
    ('  they are installed (%s), else from what it writes to disk.'):format(
      config.key('hooks') or ':Chats hooks'
    ),
    '  :checkhealth agent-chats says which, per agent.',
  })
  return lines, spans
end

function M.open()
  local lines, spans = M.lines()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local ns = api.nvim_create_namespace('agent-chats-help')
  for _, s in ipairs(spans) do
    api.nvim_buf_set_extmark(buf, ns, s[1], s[2], { end_col = s[3], hl_group = 'AgentChatsKey' })
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)
  local border = config.get().board.border
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
    title = ' Agent chats: keys ',
    zindex = 70,
  })
  vim.wo[win].cursorline = false
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ 'q', '<Esc>', 'g?', '?', '<CR>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true })
  end
  api.nvim_create_autocmd(
    'WinLeave',
    { buffer = buf, once = true, callback = vim.schedule_wrap(close) }
  )
  return win
end

return M
