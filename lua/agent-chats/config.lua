-- Options. `setup()` merges the user's table over these defaults; every other
-- module reads the result through `get()`.

local M = {}

---@class agent_chats.Config
M.defaults = {
  -- One entry per agent. `cmd` is how the agent is started (add flags here
  -- rather than relying on a shell alias), `home` overrides where its data
  -- lives, `headless_args` are appended to background replies.
  providers = {
    claude = { enabled = true, cmd = { 'claude' }, home = nil, headless_args = {} },
    codex = { enabled = true, cmd = { 'codex' }, home = nil, headless_args = {} },
    qwen = { enabled = true, cmd = { 'qwen' }, home = nil, headless_args = {} },
    -- opencode also takes `config_dir`: where its config lives when that is
    -- not $OPENCODE_CONFIG_DIR or ~/.config/opencode (its plugins go there).
    opencode = { enabled = true, cmd = { 'opencode' }, home = nil, headless_args = {} },
  },

  board = {
    -- "tab" (its own tab page) | "float" | "current" (the current window)
    layout = 'tab',
    width = 0.92, -- float: fraction of the screen, or columns when > 1
    height = 0.88, -- float: fraction of the screen, or lines when > 1
    border = nil, -- float border; nil follows 'winborder', or "rounded"
    pane = true, -- open with the right-hand pane showing
    pane_size = 0.5, -- share of the board given to the pane
    group_by = 'status', -- "status" | "folder" | "agent" | "worktree"
    max_age_days = 30, -- hide chats quiet for longer; 0 shows everything
    max_per_group = 40, -- rows per group before the rest is folded away
    spinner = true, -- animate the glyph of working chats
    intro = true, -- show a short introduction in the pane the first time the board opens
  },

  -- Where a chat's terminal opens.
  open = {
    -- "pane" (the board's right-hand pane) | "vsplit" | "split" | "tab" |
    -- "float" | "current", or a function `fun(ctx): integer?` that opens the
    -- terminal itself and returns its buffer (ctx: argv, cmdline, cwd, env,
    -- title, chat).
    where = 'pane',
    size = 0.4, -- share of the screen for "vsplit" / "split"
    start_insert = true,
    close_on_exit = true, -- drop the terminal when the agent exits cleanly
    -- Key that returns from a chat's terminal to the list while you are
    -- typing in it, mapped in terminal mode on that terminal only. false
    -- leaves it unmapped. (In the terminal's normal mode `keys.back` does it.)
    back_key = '<C-\\><C-b>',
    reuse = true, -- show a chat in the window already holding one, rather than splitting again
    -- fun(buf, chat?) -- called once for every terminal the plugin starts
    -- for a chat, after it has set its own keys there: the place for your
    -- own terminal mappings and options. The same moment is the User event
    -- AgentChatsTerminal (data.buf, data.key, data.chat).
    on_open = nil,
  },

  status = {
    -- For a chat whose agent does not say that it is blocked on you (no
    -- hooks installed, and no session registry with a status), a tool call
    -- outstanding with nothing written for this many seconds is shown as
    -- "Needs you" with a question mark. false turns the guess off.
    stall_after = 30,
    -- A chat that stopped mid-turn with no process found is treated as
    -- ended after this many seconds without writes.
    working_timeout = 900,
  },

  -- What the agents report through their own hooks, once those are
  -- installed (`:Chats hooks install`). See "How status is worked out".
  hooks = {
    enabled = true, -- read what installed hooks report; false ignores it
    -- Where the hooks write. nil: $XDG_STATE_HOME/agent-chats/events, which
    -- is ~/.local/state/agent-chats/events. After changing it, install the
    -- hooks again: they name the folder they write to.
    dir = nil,
    -- Where the hook script the agents run is kept. nil:
    -- $XDG_DATA_HOME/agent-chats/agent-chats-hook.sh (~/.local/share/...).
    script = nil,
    remind = true, -- say so on the board while an agent has no hooks installed
  },

  watch = {
    enabled = true, -- keep watching in the background (notifications, statusline)
    interval = 2000, -- ms between checks while the board is open
    background_interval = 5000, -- ms between checks otherwise
    scan_interval = 30000, -- ms between full rescans for new chats
  },

  notify = {
    enabled = true,
    attention = true, -- a chat needs you
    done = true, -- a chat finished its turn
    -- Also for the "Needs you?" guess (see status.stall_after). Off: a long
    -- command looks the same as a prompt, and a notification should be a
    -- fact. The board still marks the guess.
    inferred = false,
    scope = 'all', -- "all" | "cwd" (chats under :pwd) | "hosted" (terminals in this Neovim)
    desktop = false, -- also send a desktop notification (notify-send / osascript)
    handler = nil, -- fun(event): boolean? -- return true to suppress the default
  },

  reply = {
    -- A chat with no running process: "background" resumes it headless,
    -- "terminal" resumes it in a terminal, "ask" lets you choose each time.
    ended = 'ask',
    paste_delay = 120, -- ms between pasting a reply and pressing Enter, at least
    -- A reply is pasted into the chat's terminal, and Enter is pressed only
    -- once the terminal shows the text (an agent showing a dialog of its
    -- own does not, and Enter would answer that dialog). ms to wait for it
    -- before giving up with nothing sent.
    echo_wait = 2000,
  },

  worktree = {
    -- Where a new worktree goes. Placeholders: {repo} (repository folder
    -- name), {parent} (its parent folder), {root} (repository root), {name}.
    -- Or a function `fun(ctx): string`.
    path = '{parent}/{repo}.worktrees/{name}',
    base = nil, -- ref the new branch starts from; nil is HEAD
  },

  -- The view of a whole conversation.
  conversation = {
    tool_output_lines = 30, -- lines of each tool result kept
    thinking = false, -- include the agent's thinking blocks
    fold_tools = true, -- start with tool calls folded
  },

  search = {
    -- Rows narrow as you type. The conversations themselves are read too:
    -- after a short pause in typing when `live` is on, and always on Enter.
    live = true,
    max_hits = 5, -- passages shown per chat
    tools = false, -- also search what tool calls were given and gave back
  },

  -- Where the plugin keeps what it remembers about chats (read marks, pins,
  -- labels, notes, queued replies). nil: stdpath('state')/agent-chats/state.json
  state_file = nil,
  -- Parsed chat details, so the board is populated the moment it opens.
  -- nil: stdpath('cache')/agent-chats/index.json. false: no cache.
  cache_file = nil,

  -- fun(chat) -- show what changed in the chat's folder. Default: a scratch
  -- buffer with `git status` and `git diff`.
  diff = nil,

  -- Glyphs. The defaults need no patched font.
  icons = {
    attention = '●',
    working = '◐',
    done = '✓',
    idle = '○',
    ended = '·',
    inferred = '?',
    spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
    pin = '★',
    note = '✎',
    queue = '»',
    sub = '└',
    collapsed = '▸',
    expanded = '▾',
    dirty = '±',
    elsewhere = '↗', -- running, but not in a terminal of this Neovim
    providers = {}, -- e.g. { claude = '󰚩' } to show a glyph instead of the name
  },

  -- Keys. A string, a list of strings, or false for no key. All of them are
  -- buffer-local to the board's own windows.
  --
  -- The letters are capitals, so that every lowercase key stays what it is
  -- everywhere else. A default is not bound where you have a mapping of your
  -- own on that key (see keys.lua); a key you set here always is.
  keys = {
    open = { '<CR>', '<2-LeftMouse>' },
    read = 'C', -- the whole conversation
    new = '+',
    search = { 'S', '/' },
    menu = { '?', 'g?', '<RightMouse>' }, -- everything that can be done here
    back = 'q', -- one step back: out of a conversation, a search, the board
    clear = '<Esc>', -- end a search
    toggle = '<Tab>', -- fold a group, show a chat's subagents

    -- In a conversation.
    next_prompt = { ']]', 'J' },
    prev_prompt = { '[[', 'K' },

    -- Without a key by default; all but the two that scroll are in the menu.
    queue = false, -- a reply for when the chat finishes its turn
    move = false, -- into a group of your own, or out of it
    notify = false, -- notifications on or off
    diff = false,
    rename = false,
    pin = false,
    label = false,
    note = false,
    unread = false,
    archive = false,
    yank = false,
    group = false,
    pane = false,
    show_all = false,
    read_all = false,
    next_attention = false,
    prev_attention = false,
    scroll_down = false,
    scroll_up = false,
    refresh = false,
    hooks = false,

    -- Switched off: passing a chat on to another agent is neither in the
    -- menu nor on a key until it is given one here.
    pass = false,
  },
}

---@type agent_chats.Config?
local current
-- Actions whose keys the user gave in `keys`: those are bound whatever else
-- is mapped there (see keys.lua). The same for `open.back_key`.
local explicit = {} ---@type table<string, boolean>
local explicit_back = false

local LAYOUTS = { tab = true, float = true, current = true }
local GROUPS = { status = true, folder = true, agent = true, worktree = true }

-- Names that options and key actions went by before, and what they are now.
local RENAMED_KEYS = {
  transcript = 'read',
  handoff = 'pass',
  filter = 'search',
  help = 'menu',
  close = 'back',
}
-- Key actions that no longer exist, and what does their work.
local GONE_KEYS = {
  yank_id = 'the command that keys.yank copies holds the id',
  reply = 'Enter goes into the chat, and the reply is typed there',
  fork = 'forking a chat was taken out',
}

local function warn(msg)
  vim.schedule(function()
    vim.notify('agent-chats: ' .. msg, vim.log.levels.WARN)
  end)
end

--- Take out what cannot be an option at all, saying so: a section that is
--- not a table would otherwise take the place of its defaults, and the
--- first thing to look in it would fail.
local function sanitise(opts)
  for name, default in pairs(M.defaults) do
    local given = opts[name]
    if type(default) == 'table' and given ~= nil then
      if type(given) ~= 'table' then
        warn(
          ('%s must be a table of options; %s is not one, so the defaults are kept'):format(
            name,
            vim.inspect(given)
          )
        )
        opts[name] = nil
      elseif given[1] ~= nil then
        -- A list where names are expected (`board = { 'float' }`): merged
        -- into the defaults it would sit there as an option called 1.
        warn(
          ('%s must be a table of named options; %s is a list, so the defaults are kept'):format(
            name,
            (vim.inspect(given):gsub('%s+', ' '))
          )
        )
        opts[name] = nil
      end
    end
  end
end

--- Bring options written for an earlier version up to date, saying so.
local function modernise(opts)
  -- The view of a conversation was configured under `transcript`.
  if opts.transcript ~= nil then
    if opts.conversation == nil then
      opts.conversation = opts.transcript
    end
    opts.transcript = nil
  end
  if type(opts.board) == 'table' and opts.board.group_by == 'provider' then
    opts.board.group_by = 'agent'
  end
  if type(opts.keys) ~= 'table' then
    return
  end
  for old, new in pairs(RENAMED_KEYS) do
    if opts.keys[old] ~= nil then
      if opts.keys[new] == nil then
        warn(('keys.%s is now keys.%s; it is read as that'):format(old, new))
        opts.keys[new] = opts.keys[old]
      else
        warn(
          ('keys.%s is now keys.%s, which is set as well: keys.%s is ignored'):format(old, new, old)
        )
      end
      opts.keys[old] = nil
    end
  end
  for old, why in pairs(GONE_KEYS) do
    if opts.keys[old] ~= nil then
      warn(('keys.%s is gone: %s'):format(old, why))
      opts.keys[old] = nil
    end
  end
end

local function check(cfg, user)
  for key in pairs(user) do
    if M.defaults[key] == nil and key ~= 'diff' and key ~= 'state_file' and key ~= 'cache_file' then
      warn(('unknown option %q'):format(key))
    end
  end
  if not LAYOUTS[cfg.board.layout] then
    warn(('board.layout %q is not one of tab, float, current'):format(tostring(cfg.board.layout)))
    cfg.board.layout = M.defaults.board.layout
  end
  if not GROUPS[cfg.board.group_by] then
    warn(
      ('board.group_by %q is not one of status, folder, agent, worktree'):format(
        tostring(cfg.board.group_by)
      )
    )
    cfg.board.group_by = M.defaults.board.group_by
  end
  if cfg.open.on_open ~= nil and type(cfg.open.on_open) ~= 'function' then
    warn('open.on_open must be a function; it is ignored')
    cfg.open.on_open = nil
  end
  local back = cfg.open.back_key
  if back ~= nil and back ~= false and (type(back) ~= 'string' or back == '') then
    warn(
      ('open.back_key must be a key or false; %s is neither, so the default is kept'):format(
        vim.inspect(back)
      )
    )
    cfg.open.back_key = M.defaults.open.back_key
    explicit_back = false
  end
  for action, lhs in pairs(cfg.keys) do
    if M.defaults.keys[action] == nil then
      local names = vim.tbl_keys(M.defaults.keys)
      table.sort(names)
      warn(
        ('keys.%s is not an action, so it is ignored. The actions are: %s'):format(
          action,
          table.concat(names, ', ')
        )
      )
      cfg.keys[action] = nil
    else
      local good = lhs == false or (type(lhs) == 'string' and lhs ~= '')
      if type(lhs) == 'table' then
        -- A list of keys, with no holes and nothing else in it.
        good = vim.islist(lhs)
        for _, key in pairs(lhs) do
          good = good and type(key) == 'string' and key ~= ''
        end
      end
      if not good then
        warn(
          ('keys.%s must be a key, a list of keys, or false; %s is none of these, so the action has no key'):format(
            action,
            (vim.inspect(lhs):gsub('%s+', ' '))
          )
        )
        cfg.keys[action] = false
      end
    end
  end
  for name, p in pairs(cfg.providers) do
    if type(p.cmd) == 'string' then
      p.cmd = { p.cmd }
    end
    if type(p.cmd) ~= 'table' or #p.cmd == 0 then
      p.cmd = { name }
    end
    p.headless_args = p.headless_args or {}
  end
end

--- Merge `opts` over the defaults and make the result current.
---@param opts table?
---@return agent_chats.Config
function M.setup(opts)
  opts = vim.deepcopy(type(opts) == 'table' and opts or {})
  -- Old names first: what was written under one is checked under the name
  -- it has now.
  modernise(opts)
  sanitise(opts)
  -- `providers = { codex = false }` is shorthand for disabling one.
  for name, p in pairs(opts.providers or {}) do
    if type(p) ~= 'table' then
      opts.providers[name] = { enabled = p ~= false }
    end
  end
  local cfg = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  -- Lists are replaced, not merged index by index.
  for name, p in pairs(opts.providers or {}) do
    if type(p) == 'table' then
      for _, field in ipairs({ 'cmd', 'headless_args' }) do
        if p[field] ~= nil then
          cfg.providers[name][field] = vim.deepcopy(p[field])
        end
      end
    end
  end
  explicit = {}
  for action, lhs in pairs(opts.keys or {}) do
    cfg.keys[action] = vim.deepcopy(lhs)
    explicit[action] = true
  end
  explicit_back = type(opts.open) == 'table' and opts.open.back_key ~= nil
  if opts.icons and opts.icons.spinner then
    cfg.icons.spinner = vim.deepcopy(opts.icons.spinner)
  end
  check(cfg, opts)
  current = cfg
  -- Which keys are bound is worked out again from the new options, and a
  -- board that is open is given them.
  local keys = package.loaded['agent-chats.keys']
  if keys then
    keys.reset()
  end
  local board = package.loaded['agent-chats.ui.board']
  if board and board.is_open() then
    board.rekey()
  end
  return cfg
end

--- The command of this plugin as it is to be typed, with `sub` after it:
--- `:Chats menu`, or `:AgentChats menu` where `:Chats` is another plugin's.
---@param sub string?
---@return string
function M.command(sub)
  local name = vim.g.agent_chats_command
  return (':%s%s'):format(type(name) == 'string' and name or 'Chats', sub and (' ' .. sub) or '')
end

--- The border of a window that says what it is in its border (a title, a
--- footer with its keys): the menu, a box to write in. The board's own
--- border where it has one, else the one Neovim gives every float
--- ('winborder'), else a plain one. Never none: the title and the keys
--- would go with it.
---@return (string|table)?
function M.box_border()
  local border = M.get().board.border
  if border ~= nil and border ~= '' and border ~= 'none' then
    return border
  end
  local ok, global = pcall(function()
    return vim.o.winborder
  end)
  if not ok or global == nil or global == '' or global == 'none' then
    return 'rounded'
  end
  return nil
end

--- The active options (the defaults until `setup` is called).
---@return agent_chats.Config
function M.get()
  if not current then
    current = M.setup({})
  end
  return current
end

--- Every key the options give for an action, bound or not.
---@param action string
---@return string[]
function M.configured(action)
  local lhs = M.get().keys[action]
  local out = {}
  for _, key in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
    if type(key) == 'string' and key ~= '' then
      out[#out + 1] = key
    end
  end
  return out
end

--- Whether the keys of `action` were set by the user (and so are bound
--- whatever else is mapped on them).
---@param action string
---@return boolean
function M.explicit(action)
  M.get()
  return explicit[action] == true
end

--- Whether `open.back_key` was set by the user.
---@return boolean
function M.explicit_back_key()
  M.get()
  return explicit_back
end

-- What follows is how every hint and title learns its keys. A key is named
-- only when it is bound: a hint for an action without one is left out
-- rather than name a key that does nothing. (keys.lua decides what is bound.)

--- The keys bound to an action on the board's list.
---@param action string
---@return string[]
function M.keys_of(action)
  return require('agent-chats.keys').of(action)
end

--- The first key bound to an action, as text for a hint; nil when it has none.
---@param action string
---@return string?
function M.key(action)
  return require('agent-chats.keys').key(action)
end

--- `fmt` with the key of `action` filled in, or '' when it has none:
--- `hint('new', '%s starts a chat')`.
---@param action string
---@param fmt string
---@return string
function M.hint(action, fmt)
  return require('agent-chats.keys').hint(action, fmt)
end

--- Options of one provider.
function M.provider(name)
  -- A provider registered by another plugin has no entry here: it is on by
  -- default and started by its own name.
  return M.get().providers[name] or { enabled = true, cmd = { name }, headless_args = {} }
end

return M
