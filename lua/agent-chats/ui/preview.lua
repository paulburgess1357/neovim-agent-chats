-- The summary shown in the board's pane for a chat that has no terminal in
-- this Neovim: what it is, where it runs, the last exchange, what it is
-- doing now. Built from what the index already holds, so moving the cursor
-- never reads a file.

local config = require('agent-chats.config')
local display = require('agent-chats.display')
local state = require('agent-chats.state')
local status = require('agent-chats.status')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

local M = {}

local function section(out, heading, body, max, from_end)
  if not body or vim.trim(body) == '' then
    return
  end
  out[#out + 1] = ''
  out[#out + 1] = '## ' .. heading
  out[#out + 1] = ''
  local lines, cut
  if from_end then
    lines, cut = text.tail_lines(body, max)
    if cut then
      out[#out + 1] = '…'
    end
    vim.list_extend(out, lines)
  else
    local omitted
    lines, omitted = text.head_lines(body, max)
    vim.list_extend(out, lines)
    if omitted > 0 then
      out[#out + 1] = ('… %d more lines%s'):format(
        omitted,
        config.hint('transcript', ' (press %s for the whole conversation)')
      )
    end
  end
end

--- Lines describing `chat` (markdown).
---@param chat agent_chats.Chat?
---@param row table?  The board row, for search hits.
---@return string[]
function M.lines(chat, row, rows)
  if not chat then
    -- Hints name the keys that are bound; one for an unbound action is left out.
    local function keys(...)
      local out = {}
      for _, pair in ipairs({ ... }) do
        local key = config.key(pair[1])
        if key and not vim.tbl_contains(out, key) then
          out[#out + 1] = pair[2] and pair[2]:format(key) or key
        end
      end
      return out
    end
    if row and row.kind == 'group' then
      local fold = keys({ 'open' }, { 'toggle' })
      if #fold == 0 then
        return { '' }
      end
      return { '', ('  %s folds and unfolds this group.'):format(table.concat(fold, ' or ')) }
    end
    local any = false
    for _, r in ipairs(rows or {}) do
      any = any or r.chat ~= nil
    end
    if any then
      return {
        '',
        '  Move to a chat to see it here.',
        '',
        '  ' .. table.concat(
          keys(
            { 'new', '%s starts a new chat' },
            { 'filter', '%s filters' },
            { 'search', '%s searches conversations' },
            { 'help', '%s lists every key' }
          ),
          ' · '
        ),
      }
    end
    -- Nothing to move to: say what this place is for.
    local out = {
      '',
      '  Every chat of your coding agents in one list: which need you,',
      '  which are working, which have finished.',
      '',
      '  A chat that runs in a terminal of this Neovim shows here live.',
      '  Any other chat shows its last prompt and reply.',
      '',
    }
    vim.list_extend(
      out,
      keys(
        { 'new', '    %-4s start a chat' },
        { 'hooks', '    %-4s let the agents report their own status (hooks)' },
        { 'help', '    %-4s every key' }
      )
    )
    return out
  end
  local now = os.time()
  local out = { '# ' .. display.title(chat), '', display.where(chat), '' }

  local label = status.labels[chat.status] or chat.status or ''
  if chat.status == 'attention' and chat.through then
    label = label .. ' (a chat it started is waiting)'
  elseif chat.status == 'attention' and chat.inferred then
    label = label .. '? (quiet on a tool call; it may be waiting for approval)'
  end
  local facts = { label }
  if chat.updated then
    facts[#facts + 1] = 'active ' .. time.since(chat.updated, now)
  end
  out[#out + 1] = table.concat(facts, ' · ')
  facts = {}
  if chat.created then
    facts[#facts + 1] = 'Started ' .. time.stamp(chat.created, now)
  end
  if chat.model then
    facts[#facts + 1] = chat.model
  end
  -- Who says so, for a chat that is running: worth knowing when deciding
  -- how far to trust "needs you".
  local source = display.source(chat)
  if source then
    facts[#facts + 1] = 'status from ' .. source
  end
  if #facts > 0 then
    out[#out + 1] = table.concat(facts, ' · ')
  end

  if chat.live and not chat.term and not chat.subagent then
    out[#out + 1] = ''
    out[#out + 1] = ('> Running outside this Neovim (pid %s). Open it there to type;'):format(
      tostring(chat.pid or '?')
    )
    out[#out + 1] = ('> here you can read it%s and watch its status.'):format(
      config.hint('transcript', ' (%s)')
    )
  end

  -- What you attached to it yourself, set apart from what the agent says.
  local own = {}
  local labels = state.labels(chat.key)
  if #labels > 0 then
    own[#own + 1] = 'Labels: ' .. table.concat(labels, ', ')
  end
  local note = state.note(chat.key)
  if note then
    own[#own + 1] = 'Note: ' .. note
  end
  local queued = state.queue(chat.key)
  for i, item in ipairs(queued) do
    own[#own + 1] = ('Queued %d: %s'):format(i, text.oneline(item.text, 90))
  end
  if #own > 0 then
    out[#out + 1] = ''
    vim.list_extend(out, own)
  end

  if row and row.kind == 'hit' then
    section(out, 'Match', row.hit.excerpt, 12)
  end
  if chat.subagent then
    out[#out + 1] = ''
    out[#out + 1] = ('Subagent%s.%s'):format(
      chat.agent_type and (' (' .. chat.agent_type .. ')') or '',
      config.hint('transcript', ' Press %s to read what it did.')
    )
    return out
  end
  if chat.stub then
    out[#out + 1] = ''
    out[#out + 1] = 'A new session that has not been sent a prompt yet.'
    if chat.unstarted then
      out[#out + 1] = ('It is listed under its own name once it has one.%s'):format(
        config.hint('open', ' %s goes to its terminal.')
      )
    end
    return out
  end

  if chat.status == 'attention' then
    local store = package.loaded['agent-chats.store']
    local waiting = display.waiting(chat, store and store.get or nil)
    if #waiting > 0 then
      section(out, 'Waiting on', table.concat(waiting, '\n'), 6)
    end
  elseif chat.status == 'working' then
    section(out, 'Now', chat.activity, 6)
  end
  section(out, 'Last prompt', chat.last_prompt or chat.first_prompt, 14)
  section(out, 'Last reply', chat.last_reply, 60)
  return out
end

--- Fill `buf` with the summary of `chat`.
function M.render(buf, chat, row, rows)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = M.lines(chat, row, rows)
  -- Buffer lines cannot hold newlines.
  for i, l in ipairs(lines) do
    if l:find('\n', 1, true) then
      lines[i] = l:gsub('\n', ' ')
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- A scratch buffer for the summary, highlighted as markdown.
---@return integer buf
function M.create()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'agent-chats-summary'
  pcall(vim.api.nvim_buf_set_name, buf, 'Agent chats: summary')
  pcall(vim.treesitter.start, buf, 'markdown')
  vim.bo[buf].modifiable = false
  return buf
end

return M
