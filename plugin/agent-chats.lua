if vim.g.loaded_agent_chats then
  return
end
vim.g.loaded_agent_chats = true

if vim.fn.has('nvim-0.11') == 0 then
  vim.notify('Neovim Agent Chats needs Neovim 0.11 or newer', vim.log.levels.ERROR)
  return
end

-- Only the commands are defined here; the plugin itself loads on first use.
---@return boolean ours
local function define(name)
  if vim.fn.exists(':' .. name) == 2 then
    return false
  end
  vim.api.nvim_create_user_command(name, function(opts)
    require('agent-chats').command(opts)
  end, {
    nargs = '*',
    range = true,
    desc = 'Agent chats: open the board (close it when it is in front of you), or run a subcommand',
    complete = function(lead, line)
      return require('agent-chats').complete(lead, line)
    end,
  })
  return true
end

-- :Chats is the everyday name; :AgentChats is there in case another plugin
-- already owns :Chats. Whichever is this plugin's is the one its hints and
-- its own mappings name.
local chats, long = define('Chats'), define('AgentChats')
vim.g.agent_chats_command = chats and 'Chats' or (long and 'AgentChats' or 'Chats')

vim.keymap.set('n', '<Plug>(agent-chats)', function()
  require('agent-chats').toggle()
end, { desc = 'Agent chats: board' })
vim.keymap.set('n', '<Plug>(agent-chats-next)', function()
  require('agent-chats').next()
end, { desc = 'Agent chats: next chat that needs you' })
vim.keymap.set('n', '<Plug>(agent-chats-new)', function()
  require('agent-chats').new()
end, { desc = 'Agent chats: new chat' })
vim.keymap.set('n', '<Plug>(agent-chats-search)', function()
  require('agent-chats').search()
end, { desc = 'Agent chats: search chats' })
vim.keymap.set(
  'x',
  '<Plug>(agent-chats-send)',
  ':' .. vim.g.agent_chats_command .. ' send<CR>',
  { desc = 'Agent chats: send selection to a chat' }
)
