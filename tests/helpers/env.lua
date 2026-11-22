-- Puts the plugin back in its just-loaded state between tests.

local M = {}

-- A question that no test answers would wait for a key that never comes,
-- and the whole run with it: it fails the test that asked instead.
local function unanswered(_, opts)
  error(('a question was asked and not answered: %s'):format(tostring(opts and opts.prompt)), 0)
end

function M.reset()
  vim.ui.select, vim.ui.input = unanswered, unanswered
  for _, name in ipairs({ 'store', 'state', 'term', 'notify', 'queue', 'events', 'hooks' }) do
    local mod = package.loaded['agent-chats.' .. name]
    if mod and mod.reset then
      mod.reset()
    end
  end
  local board = package.loaded['agent-chats.ui.board']
  if board and board.close then
    pcall(board.close)
    -- The grouping is kept from one opening to the next while Neovim runs:
    -- not from one test to the next.
    board._state.group_by = nil
  end
  -- Terminals first, each job waited for (see `fake.cleanup` for why a
  -- terminal's buffer must not simply be deleted under it).
  require('helpers.fake').cleanup()
  -- Leave one empty window in one tab.
  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
