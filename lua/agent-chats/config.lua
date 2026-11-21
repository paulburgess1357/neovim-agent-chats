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
    group_by = 'status', -- "status" | "folder" | "provider" | "worktree"
    max_age_days = 30, -- hide chats quiet for longer; 0 shows everything
    max_per_group = 40, -- rows per group before the rest is folded away
    spinner = true, -- animate the glyph of working chats
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
    -- Key that returns from a chat's terminal in the pane to the list, mapped
    -- in terminal mode on that terminal only. false leaves it unmapped.
    back_key = '<C-\\><C-b>',
    reuse = true, -- show a chat in the window already holding one, rather than splitting again
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

  transcript = {
    tool_output_lines = 30, -- lines of each tool result kept
    thinking = false, -- include the agent's thinking blocks
    fold_tools = true, -- start with tool calls folded
  },

  search = {
    max_hits = 5, -- excerpts shown per chat
    tools = false, -- also search tool calls and their output
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

  -- Board keys. A string, a list of strings, or false to leave unmapped.
  keys = {
    open = { '<CR>', 'o' },
    transcript = 't',
    pane = 'p',
    reply = 'r',
    queue = 'Q',
    new = 'n',
    fork = 'F',
    handoff = 'H',
    diff = 'd',
    filter = '/',
    search = 'S',
    clear = '<Esc>',
    group = 'b',
    toggle = '<Tab>',
    unread = 'u',
    read_all = 'U',
    pin = 'P',
    archive = 'a',
    show_all = 'A',
    label = 'l',
    note = 'e',
    rename = 'R',
    yank = 'y',
    yank_id = 'Y',
    next_attention = ']a',
    prev_attention = '[a',
    scroll_down = '<C-f>',
    scroll_up = '<C-b>',
    refresh = '<C-r>',
    hooks = 'gh',
    help = { 'g?', '?' },
    close = 'q',
  },
}

---@type agent_chats.Config?
local current

local LAYOUTS = { tab = true, float = true, current = true }
local GROUPS = { status = true, folder = true, provider = true, worktree = true }

local function warn(msg)
  vim.schedule(function()
    vim.notify('agent-chats: ' .. msg, vim.log.levels.WARN)
  end)
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
      ('board.group_by %q is not one of status, folder, provider, worktree'):format(
        tostring(cfg.board.group_by)
      )
    )
    cfg.board.group_by = M.defaults.board.group_by
  end
  for action, lhs in pairs(cfg.keys) do
    local good = lhs == false or (type(lhs) == 'string' and lhs ~= '')
    if type(lhs) == 'table' then
      good = true
      for _, key in ipairs(lhs) do
        good = good and type(key) == 'string' and key ~= ''
      end
    end
    if not good then
      warn(
        ('keys.%s must be a key, a list of keys, or false; %s is none of these, so the action has no key'):format(
          action,
          vim.inspect(lhs)
        )
      )
      cfg.keys[action] = false
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
  opts = vim.deepcopy(opts or {})
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
  for action, lhs in pairs(opts.keys or {}) do
    cfg.keys[action] = vim.deepcopy(lhs)
  end
  if opts.icons and opts.icons.spinner then
    cfg.icons.spinner = vim.deepcopy(opts.icons.spinner)
  end
  check(cfg, opts)
  current = cfg
  return cfg
end

--- The active options (the defaults until `setup` is called).
---@return agent_chats.Config
function M.get()
  if not current then
    current = M.setup({})
  end
  return current
end

-- Keys as people call them.
local KEY_NAMES =
  { ['<CR>'] = 'Enter', ['<Tab>'] = 'Tab', ['<Esc>'] = 'Esc', ['<Space>'] = 'Space' }

--- The keys bound to a board action: every non-empty string given for it.
---@param action string
---@return string[]
function M.keys_of(action)
  local lhs = M.get().keys[action]
  local out = {}
  for _, key in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
    if type(key) == 'string' and key ~= '' then
      out[#out + 1] = key
    end
  end
  return out
end

--- The first key bound to a board action, as text for a hint; nil when the
--- action has no key (hints then leave it out rather than name a key that
--- does nothing).
---@param action string
---@return string?
function M.key(action)
  local lhs = M.keys_of(action)[1]
  return lhs and (KEY_NAMES[lhs] or lhs) or nil
end

--- `fmt` with the key of `action` filled in, or '' when it has none:
--- `hint('new', '%s starts a chat')`.
---@param action string
---@param fmt string
---@return string
function M.hint(action, fmt)
  local key = M.key(action)
  return key and fmt:format(key) or ''
end

--- Options of one provider.
function M.provider(name)
  -- A provider registered by another plugin has no entry here: it is on by
  -- default and started by its own name.
  return M.get().providers[name] or { enabled = true, cmd = { name }, headless_args = {} }
end

return M
