-- A complete small provider: a reader for a made-up agent, Pal, that keeps
-- each chat as `~/.pal/chats/<id>.jsonl`, one `{ "role": ..., "text": ... }`
-- object per line. Register a table like this one and the agent gets the
-- whole board: its chats are listed, read, searched and resumed.
--
-- Only what is here is needed. What else a provider can have (exact status
-- from hooks, running processes, subagents, background replies) is in
-- `:help agent-chats-providers`; the annotated contract is in
-- `lua/agent-chats/types.lua`, and `lua/agent-chats/providers/claude.lua` is
-- the reference implementation.

local home = vim.fn.expand('~/.pal')

local function read(path)
  local out = {}
  for line in io.lines(path) do
    local ok, msg = pcall(vim.json.decode, line)
    if ok and type(msg) == 'table' then
      out[#out + 1] = msg
    end
  end
  return out
end

require('agent-chats').register({
  name = 'pal',
  label = 'Pal',
  home = function() return home end,
  available = function() return vim.fn.isdirectory(home .. '/chats') == 1 end,

  -- Cheap listing: one entry per chat, no file opened.
  discover = function()
    local out = {}
    for name in vim.fs.dir(home .. '/chats') do
      local id = name:match('^(.+)%.jsonl$')
      local st = id and vim.uv.fs_stat(home .. '/chats/' .. name)
      if st then
        out[#out + 1] =
          { id = id, path = home .. '/chats/' .. name, mtime = st.mtime.sec, size = st.size }
      end
    end
    return out
  end,

  -- Called only for entries whose mtime or size changed.
  parse = function(entry)
    local msgs = read(entry.path)
    if #msgs == 0 then return nil end
    local out = { cwd = msgs[1].cwd, updated = entry.mtime }
    for _, m in ipairs(msgs) do
      if m.role == 'user' then
        out.first_prompt = out.first_prompt or m.text
        out.last_prompt = m.text
      else
        out.last_reply = m.text
      end
    end
    -- 'working' | 'waiting' | 'done' | 'aborted' | 'unknown'
    out.turn = msgs[#msgs].role == 'user' and 'working' or 'done'
    return out
  end,

  -- The conversation, for reading it and for searching it.
  messages = function(chat) return read(chat.path), nil end,

  resume_cmd = function(chat) return { 'pal', '--resume', chat.id } end,
  new_cmd = function(opts) return { 'pal', opts.prompt } end,

  -- Optional: what the events of its hooks mean, if it has hooks.
  hooks = {
    events = { prompt = 'working', ask = 'waiting', answer = 'resolved', stop = 'done' },
  },
})
