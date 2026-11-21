-- Puts the plugin back in its just-loaded state between tests.

local M = {}

function M.reset()
  for _, name in ipairs({ 'store', 'state', 'term', 'notify', 'queue', 'events', 'hooks' }) do
    local mod = package.loaded['agent-chats.' .. name]
    if mod and mod.reset then
      mod.reset()
    end
  end
  local board = package.loaded['agent-chats.ui.board']
  if board and board.close then
    pcall(board.close)
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
