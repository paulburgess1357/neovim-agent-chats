-- Highlight groups. All of them link to standard groups by default, so the
-- board follows whatever colorscheme is active; override any of them freely.

local M = {}

local LINKS = {
  AgentChatsAttention = 'DiagnosticWarn',
  AgentChatsWorking = 'DiagnosticInfo',
  AgentChatsDone = 'DiagnosticOk',
  AgentChatsIdle = 'Normal',
  AgentChatsEnded = 'Comment',
  AgentChatsHeader = 'Title',
  AgentChatsGroup = 'Title',
  AgentChatsCount = 'Comment',
  AgentChatsProvider = 'Type',
  AgentChatsTitle = 'Normal',
  AgentChatsFolder = 'Directory',
  AgentChatsBranch = 'Special',
  AgentChatsAge = 'Comment',
  AgentChatsDim = 'Comment',
  AgentChatsLabel = 'Label',
  AgentChatsPin = 'DiagnosticWarn',
  AgentChatsNote = 'DiagnosticHint',
  AgentChatsQueue = 'DiagnosticInfo',
  AgentChatsMatch = 'Search',
  AgentChatsKey = 'Special',
  AgentChatsLive = 'DiagnosticOk',
  -- The row of the chat that is in the pane: the line, and the bar at its
  -- left. (Not the cursor line's group: many colorschemes and configs make
  -- that one faint, or take it away in a window the cursor is not in.)
  AgentChatsShown = 'Visual',
  AgentChatsShownMark = 'Title',
}

function M.apply()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- Unread titles stand out by weight, not colour.
  vim.api.nvim_set_hl(0, 'AgentChatsUnread', { bold = true, default = true })
end

local did_setup = false

function M.setup()
  M.apply()
  if did_setup then
    return
  end
  did_setup = true
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('AgentChatsHighlights', { clear = true }),
    callback = M.apply,
  })
end

return M
