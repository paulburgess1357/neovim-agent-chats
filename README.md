# agent-chats.nvim

One board for every AI agent chat on your machine: Claude Code, Codex, Qwen Code and opencode.

See which chats need you, which are still working and which have finished. Open any of them in a Neovim terminal, reply, search what was said, and start new ones, without hunting through terminals.

```
 8 chats · 1 need you · 2 working · 1 unread      g? help   by status │ Summary   Enter open · t transcript · r reply
                                                                      │ # Fix flaky session restore
▾ Needs you  1                                                        │
 ●  Claude  Fix flaky session restore ✎           nvim-config    2m   │ Claude · ~/work/nvim-config · main
                                                                      │
▾ Working  2                                                          │ Needs you · active 2m ago
 ◐  Codex   Add a picker for tab pages            nvim-config   38s   │ Started 14:02 · status from its hooks
 ◐  Claude  Port the renderer to Vulkan           engine         1m   │
                                                                      │ ## Waiting on
▾ Done, unread  1                                                     │
 ✓  Qwen    Write the README                      plan           4m   │ permission to use Bash
                                                                      │ Bash: rm -rf .cache/sessions
▾ Idle  1                                                             │
 ○  Claude  Refactor the audio mixer              engine        25m   │ ## Last prompt
                                                                      │
▾ Ended  3                                                            │ The session restore test fails one run
 ·  Claude  ★ Review the release checklist #release  plan        2d   │ in five. Find out why.
```

It reads what the agents already write to disk, and listens to what they report through their own hooks. Nothing wraps how you start them, so chats started anywhere show up: in a Neovim terminal, in another terminal, by a script.

## Requirements

- Neovim 0.11 or newer (developed and tested on 0.12).
- At least one of the agents. Nothing else is required: no plugin dependencies, no patched font, no build step.

Optional, used when present:

| Tool | Used for |
| --- | --- |
| A POSIX `sh` | The status hooks of Claude Code, Qwen Code and Codex |
| `git` | Branches, worktree grouping, new worktrees, diffs |
| `rg` | Faster conversation search |
| System SQLite library | Reading opencode chats directly (otherwise `opencode db` is used) |

Developed and tested on Linux. See [Limits](#limits) for macOS and Windows.

## Install

With Neovim's built-in plugin manager (0.12):

```lua
vim.pack.add({ 'https://github.com/paulburgess1357/agent-chats.nvim' })
require('agent-chats').setup()
```

With lazy.nvim:

```lua
{ 'paulburgess1357/agent-chats.nvim', opts = {} }
```

Then, once:

```vim
:Chats hooks install
```

That lets each agent you use report its own status. It shows every line it is about to change and asks before writing; see [Status hooks](#status-hooks). The board works without this step, but for every agent except Claude Code "needs you" is then a guess.

`setup()` is optional too. Without it `:Chats` still works; with it the plugin also watches in the background, which is what drives notifications and the statusline segment.

## Use

`:Chats` opens the board in its own tab. Run it again from anywhere to go back to it.

The left side lists your chats. The right-hand pane follows the cursor:

- For a chat running in a terminal of this Neovim, it shows that **live terminal**.
- For any other chat, it shows a summary: what it is waiting on or doing, the last prompt, the last reply.

Press `<CR>` to go into the chat. A chat that ended is resumed in the pane; a chat already running in this Neovim is focused. `<C-\><C-b>` in that terminal (or `:Chats` from anywhere) comes back to the list. The pane's title always says which of the two you are looking at and which key is next.

A new chat that has not been sent a prompt yet is listed as "(no prompt yet)" until its agent gives it a name, so there is always a row that leads back to its terminal.

What an agent asks when it starts is its own business and shows in that terminal: Claude Code and Codex ask whether to trust a folder they have not seen, Codex asks about hooks it has not been told to trust, any of them may offer an update. The plugin never answers these for you.

### Statuses

| | Status | Meaning |
| --- | --- | --- |
| `●` | Needs you | The agent is blocked on you: a permission prompt or a question |
| `◐` | Working | The agent is mid-turn |
| `✓` | Done, unread | The turn finished and you have not looked at it since |
| `○` | Idle | Finished, seen, and the agent is still open |
| `·` | Ended | No process has the chat open; it can be resumed |

`●?` is a guess: see [How status is worked out](#how-status-is-worked-out). Opening a chat, or having its terminal in front of you when it finishes, marks it read.

### Keys on the board

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the chat (its terminal; resumes it if it ended) |
| `t` | Read the whole conversation, tool calls folded |
| `r` | Reply |
| `Q` | Queue a reply for when the chat finishes its turn; with replies queued, also send or drop them |
| `n` | New chat: agent, folder or a new git worktree, optional first prompt |
| `F` | Fork the chat into a new one |
| `H` | Hand the chat to another agent, with notes you can edit first |
| `d` | Show uncommitted changes in the chat's folder |
| `/` | Filter the board: names, folders, branches, agents, labels and the latest messages |
| `S` | Search inside all conversations (starts from the filter, if there is one) |
| `<Esc>` | Clear the filter, then the search |
| `b` | Group by status, folder, agent or worktree |
| `<Tab>` | Fold a group, or show a chat's subagents |
| `p` | Show or hide the pane |
| `u` / `U` | Mark read or unread / mark everything read |
| `P` | Pin to the top of its group |
| `a` / `A` | Archive (hidden until it moves again) / show archived and older chats |
| `l` / `e` / `R` | Edit labels / edit the note / rename |
| `y` / `Y` | Copy the command that resumes it / copy its id |
| `]a` / `[a` | Next / previous chat that needs you |
| `<C-f>` / `<C-b>` | Scroll the pane |
| `<C-r>` | Refresh now |
| `gh` | Set up the agents' status hooks |
| `g?` | Show the keys |
| `q` | Close the board (terminals keep running) |

Pins, labels, notes, names and read marks are kept by the plugin, so they work the same for every agent and never touch the agents' own files.

**Filter or search?** `/` narrows what is on the board as you type and costs nothing: it looks at what each row already shows. `S` reads the conversations themselves, every prompt and reply of every chat, and lists the matching passages under their chats. When the filter finds nothing, the board says so and `S` picks up the same text. A search always starts from every chat, so it drops the filter; a filter typed afterwards narrows the results.

**Replying.** `r` sends now. A chat running in a terminal of this Neovim has the reply pasted into that terminal; a chat that ended is resumed with it (`reply.ended` says how). `Q` queues the reply behind the turn that is running, and it is pasted in when that turn ends.

Two rules keep a reply from going where it should not:

- **It is pasted, and Enter is pressed only once the terminal shows the text.** An agent may be showing a dialog of its own that nothing reports: "trust this folder?", "update available", a permission prompt. Keys typed into one are answers to it, and Enter confirms whatever it has selected. A dialog does not take a paste, so the text never appears, Enter is not pressed, and you are told that nothing was sent. A chat that is known to be asking (it shows as "Needs you") is not pasted into at all: you are taken to it to answer first.
- **A queued reply is only ever pasted into a terminal of this Neovim that still has the chat in it,** and never starts an agent by itself. If the chat ends first, its replies are kept, you are told, and from then on they go only when you say so: `Q` on the chat sends them, carries on, or drops them. Opening the chat again does not send them.

A reply you wrote and then did not send (the box was closed, the question of how to send was dismissed, the chat did not take it) is offered again the next time you reply to that chat.

### Commands

| Command | Action |
| --- | --- |
| `:Chats` | Open the board, or go to it |
| `:Chats new [agent]` | Start a new chat |
| `:Chats next` | Jump into the chat that has waited for you longest |
| `:Chats search [text]` | Search inside all conversations |
| `:Chats filter <text>` | Open the board filtered |
| `:'<,'>Chats send` | Send the selected lines, with their file and line range, to a chat running in this Neovim |
| `:Chats hooks [install\|uninstall\|show\|status] [agent]` | Set up the status hooks; alone, it opens an overview |
| `:Chats refresh` / `:Chats close` / `:Chats health` | As named |

`:AgentChats` is the same command under a second name.

Nothing is mapped globally. Suggested mappings:

```lua
vim.keymap.set('n', '<leader>ac', '<Plug>(agent-chats)')        -- board
vim.keymap.set('n', '<leader>an', '<Plug>(agent-chats-next)')   -- next chat that needs you
vim.keymap.set('n', '<leader>aN', '<Plug>(agent-chats-new)')    -- new chat
vim.keymap.set('n', '<leader>as', '<Plug>(agent-chats-search)') -- search conversations
vim.keymap.set('x', '<leader>aa', '<Plug>(agent-chats-send)')   -- send selection to a chat
```

### Statusline

`require('agent-chats').statusline()` returns a segment such as `● 2  ◐ 3  ✓ 1`, and an empty string when nothing is going on. For lualine:

```lua
lualine_x = { require('agent-chats').statusline }
```

`require('agent-chats').counts()` returns the numbers if you want your own format.

## Status hooks

Each of these agents has an official way to tell other programs what it is doing. Claude Code, Qwen Code and Codex run a command on events such as "about to ask for permission" and "turn finished"; opencode hands its events to a plugin file. With these set up, the board shows a prompt the moment it appears and a finished turn the moment it ends.

`:Chats hooks install` sets them up for every agent you use, or `:Chats hooks install codex` for one. It shows a diff of every file it would touch, asks, and keeps the old file beside the new one. `:Chats hooks` alone opens an overview with the same actions on keys, and `gh` on the board opens that overview.

| Agent | What changes | When it takes effect |
| --- | --- | --- |
| Claude Code | `hooks` in `~/.claude/settings.json` | At once, also in sessions that are running |
| Qwen Code | `hooks` in `~/.qwen/settings.json` | In new sessions (or open `/hooks` once in a running one) |
| Codex | `~/.codex/hooks.json` | Once you trust them: Codex asks the next time it starts ("Hooks need review"), or run `/hooks` |
| opencode | `~/.config/opencode/plugins/agent-chats.js` | In new sessions |

The agents' own environment variables (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `QWEN_HOME`, `OPENCODE_CONFIG_DIR`, `XDG_CONFIG_HOME`) and the `home` option are followed.

What the installer promises:

- **Only its own entries.** The file is edited as text. Key order, indentation, comments and your own hooks stay as they were, and `:Chats hooks uninstall` takes out what was put in. (What was empty before may not come back byte for byte: `{   }` returns as `{}`, and an empty `"hooks": {}` is not put back.)
- **Checked before written.** The result must parse, must say what the file said before plus the new entries, and must still hold every comment. A file that is not valid JSON, cannot be read, is read-only, or was changed while the diff was on screen is left alone, and you are told why.
- **A backup each time**, named `<file>.agent-chats-backup-<date>-<time>.<n>` (the last three are kept), made before anything else is written.
- **Links are respected.** A symlinked settings file stays a symlink and is edited where it points; one that points at nothing is left alone. opencode's plugin file is the plugin's own: when it is a link you made, uninstalling removes the link and never the file behind it.
- **Only agents you have.** With no name given, hooks are set up for the agents whose own folder exists; nothing is created for one you never used.

What the hook is:

- One POSIX shell script, [`scripts/agent-chats-hook.sh`](scripts/agent-chats-hook.sh), copied to `~/.local/share/agent-chats/` so that updating or moving the plugin never leaves an agent pointing at nothing. For opencode, one plugin file, [`scripts/opencode-agent-chats.js`](scripts/opencode-agent-chats.js).
- It appends one line per event to `~/.local/state/agent-chats/events/<agent>/<session>.log`: the time, the event's name and, when the event has them, the notification type, the tool's name, the subagent id, why the session started or ended, and the agent's process id. The first line of a log also names the transcript file and the working directory. **Prompts, replies, commands and tool output are never stored.** The folder is private to you (mode 700), and logs older than 30 days are removed.
- It prints nothing and always exits 0, and the installed command is `AGENT_CHATS_EVENTS_DIR=<folder> sh <script> <agent> 2>/dev/null || true`, so nothing about it can block a prompt or fail a tool call, not even a missing script. The folder is named outright because an agent's environment need not be Neovim's. It takes a few milliseconds and needs nothing but `sh`.
- It works whether or not Neovim is running. Any number of Neovim instances read the same logs; none of them deletes or rewrites one.

By hand, if you would rather not have a plugin edit your settings: `:Chats hooks show claude` prints the exact steps and JSON for your machine. They come to this:

```sh
mkdir -p ~/.local/share/agent-chats
cp <plugin>/scripts/agent-chats-hook.sh ~/.local/share/agent-chats/
```

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "sh ~/.local/share/agent-chats/agent-chats-hook.sh claude 2>/dev/null || true", "timeout": 10 }] }
    ]
  }
}
```

with the same entry under each of `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PermissionRequest`, `Notification`, `ElicitationResult`, `PostToolUse`, `PostToolUseFailure`, `SubagentStop`, `Stop` and `StopFailure`. An entry made by hand is recognised as long as its command runs `agent-chats-hook.sh` with the agent's name, ends in `|| true`, and writes where this Neovim reads. Without `AGENT_CHATS_EVENTS_DIR=` in front it writes to `~/.local/state/agent-chats/events` (or under `$XDG_STATE_HOME`), which is also where Neovim reads unless `hooks.dir` says otherwise. `:Chats hooks status` and `:checkhealth` say so when the two differ.

From a setup script, without the question:

```sh
nvim --headless -c "lua print(table.concat(require('agent-chats.hooks').install(), '\n'))" -c qa
```

## How status is worked out

What a chat is doing can be known three ways. Each agent supplies what it has, and the most direct source that has spoken is believed:

1. **Hooks**: the agent says so itself, as it happens. Needs the one-time install above.
2. **An interface that can be asked**: a command or API of the agent.
3. **Files and processes**: the transcript, a session registry where the agent keeps one, and the process table. Always there.

| Agent | With hooks installed | Without |
| --- | --- | --- |
| Claude Code | Hooks and its session registry; whichever spoke last is believed | Its session registry (`~/.claude/sessions`): **exact**, but undocumented |
| Codex | Hooks: **exact**, including interrupts | Transcript and processes: "needs you" is a **guess** |
| Qwen Code | Hooks: **exact** | Transcript and its session registry: a **guess** |
| opencode | Its plugin: **exact**, each request followed by its id | Database and processes: a **guess** |

The guess is: a tool call has no result and nothing has been written for `status.stall_after` seconds. That is often an approval prompt, but a long-running command looks the same, so such chats show as `●?` and, by default, do not raise a notification.

The pane says where a running chat's status comes from ("status from its hooks"), and `:checkhealth agent-chats` says it per agent.

What hooks do not say, and what is done about it:

- **No agent reports that you answered a prompt.** The next news is the tool finishing. Claude Code's registry fills the gap at once. For the others a chat keeps showing "Needs you" while an approved command runs, with one exception: when the chat runs in a terminal of this Neovim, typing into that terminal after the question counts as the answer.
- **Claude Code and Qwen Code report nothing when you interrupt a turn.** The transcript does, so a transcript that shows the turn over after the hooks last spoke wins.
- **A session reports only once its agent has loaded the hooks**: one started before they were installed (Qwen Code, opencode), or one whose hooks Codex has not been told to trust, is worked out from files as before.
- **A hook's last word can go stale** if the agent is killed. Whether a process still has the chat open is always checked separately; a chat nobody has open is "Ended" whatever was last reported.

## Options

Every option with its default:

```lua
require('agent-chats').setup({
  providers = {
    -- cmd: how the agent is started. Add flags here instead of relying on a shell alias.
    -- home: where its data lives, if not the default.
    -- headless_args: extra arguments for background replies.
    claude = { enabled = true, cmd = { 'claude' }, home = nil, headless_args = {} },
    codex = { enabled = true, cmd = { 'codex' }, home = nil, headless_args = {} },
    qwen = { enabled = true, cmd = { 'qwen' }, home = nil, headless_args = {} },
    -- config_dir: where opencode keeps its config, if not ~/.config/opencode.
    opencode = { enabled = true, cmd = { 'opencode' }, home = nil, headless_args = {} },
  },

  board = {
    layout = 'tab',        -- 'tab' | 'float' | 'current'
    width = 0.92,          -- float size: a fraction of the screen, or cells when > 1
    height = 0.88,
    border = nil,          -- float border; nil follows 'winborder', else 'rounded'
    pane = true,           -- open with the right-hand pane showing
    pane_size = 0.5,       -- share of the board given to the pane
    group_by = 'status',   -- 'status' | 'folder' | 'provider' | 'worktree'
    max_age_days = 30,     -- hide chats quiet for longer; 0 shows everything
    max_per_group = 40,    -- rows per group before the rest is folded away
    spinner = true,        -- animate the glyph of working chats
  },

  open = {
    -- Where a chat's terminal opens: 'pane' (the board's pane) | 'vsplit' |
    -- 'split' | 'tab' | 'float' | 'current', or a function (see below).
    where = 'pane',
    size = 0.4,            -- share of the screen for 'vsplit' / 'split'
    start_insert = true,
    close_on_exit = true,  -- drop the terminal when the agent exits cleanly
    back_key = '<C-\\><C-b>', -- in a pane terminal: back to the list; false unmaps
    reuse = true,          -- reuse the window already holding a chat instead of splitting again
  },

  status = {
    stall_after = 30,      -- seconds; see "How status is worked out". false turns the guess off
    working_timeout = 900, -- seconds before a silent mid-turn chat with no process counts as ended
  },

  hooks = {
    enabled = true,        -- read what installed hooks report; false ignores it
    dir = nil,             -- where hooks write; nil: ~/.local/state/agent-chats/events. Changed later: install again
    script = nil,          -- where the hook script is kept; nil: ~/.local/share/agent-chats/agent-chats-hook.sh
    remind = true,         -- say on the board when an agent in use can only guess
  },

  watch = {
    enabled = true,              -- watch in the background (notifications, statusline)
    interval = 2000,             -- ms between checks while the board is open
    background_interval = 5000,  -- ms between checks otherwise
    scan_interval = 30000,       -- ms between full rescans for new chats
  },

  notify = {
    enabled = true,
    attention = true,      -- a chat needs you
    done = true,           -- a chat finished its turn
    inferred = false,      -- also for the "Needs you?" guess
    scope = 'all',         -- 'all' | 'cwd' (chats under :pwd) | 'hosted' (terminals in this Neovim)
    desktop = false,       -- also notify-send / osascript
    handler = nil,         -- function(event) ... return true to suppress the default end
  },

  reply = {
    ended = 'ask',         -- reply to an ended chat: 'ask' | 'terminal' | 'background'
    paste_delay = 120,     -- ms between pasting a reply and pressing Enter, at least
    echo_wait = 2000,      -- ms to wait for the terminal to show the pasted text; Enter is not pressed without it
  },

  worktree = {
    path = '{parent}/{repo}.worktrees/{name}', -- or function(ctx) return path end
    base = nil,            -- ref a new worktree branch starts from; nil is HEAD
  },

  transcript = { tool_output_lines = 30, thinking = false, fold_tools = true },
  search = { max_hits = 5, tools = false },  -- tools: also search tool calls and output

  diff = nil,              -- function(chat) to show changes your own way
  state_file = nil,        -- default: stdpath('state')/agent-chats/state.json
  cache_file = nil,        -- default: stdpath('cache')/agent-chats/index.json; false disables

  icons = { attention = '●', working = '◐', done = '✓', idle = '○', ended = '·', --[[ ... ]] },
  keys = { open = { '<CR>', 'o' }, reply = 'r', hooks = 'gh', --[[ ... every action; false unmaps ]] },
})
```

Highlight groups all start with `AgentChats` and link to standard groups, so the board follows your colorscheme.

### Putting terminals where you want them

`open.where` can be a function. It receives `{ argv, cmdline, cwd, env, title, chat }`, opens the terminal however you like, and returns its buffer:

```lua
open = {
  where = function(ctx)
    vim.cmd('botright vsplit | enew')
    vim.fn.jobstart(ctx.argv, { term = true, cwd = ctx.cwd })
    return vim.api.nvim_get_current_buf()
  end,
}
```

If you would rather type the command into a shell you already have, send `ctx.cmdline` to it and return that terminal's buffer. A chat is recognised in any terminal of this Neovim by its process, however it was started.

### Events

`User` autocommands: `AgentChatsUpdate` (the index changed), `AgentChatsAttention` and `AgentChatsDone` (with `data.key` and `data.chat`).

## Limits

What has and has not been checked against the real thing:

- **Reading chats** is checked against real data of all four agents (Claude Code 2.1, Codex 0.121 to 0.166, Qwen Code 0.26 and 0.28, opencode 1.17 and 1.19).
- **A real session of each agent was driven through the plugin** (Claude Code 2.1.330, Codex 0.166, Qwen Code 0.26 and 0.28.3, opencode 1.17.4 and 1.19.6): a new chat from the board, a reply, a queued reply behind it, a reply of several lines, quitting, opening it again. That is where the rules about pasting above come from: an earlier version typed a reply into opencode while it was offering an update, and its Enter accepted the update.
- **The hooks report correctly from real sessions** of Claude Code (including a question it put to the user, shown as "Needs you" the moment it was asked), Qwen Code (including a permission prompt) and opencode (busy and idle). Not seen live: opencode's permission requests, and anything from Codex's hooks, which Codex runs only after you have trusted them.
- **Everything else** (the installer's refusals, two Neovims on one state file, every awkward order of events in the regression tests) runs in the test suite against stand-ins.
- **macOS**: never run on a Mac. The code path for systems without `/proc` is exercised by the tests on Linux, where `ps` and `lsof` take the same arguments. **Windows** is untested, and the shell hooks need a POSIX `sh`.

What it cannot do:

- **Chats running outside this Neovim** (another terminal, an IDE) are listed with `↗` and can be read, but not typed into: only Neovim terminals are driven.
- **Background replies cannot answer permission prompts.** A step that needs approval fails. Use `headless_args` to choose the agent's non-interactive permission mode, or reply in a terminal.
- **Queued replies are pasted into a terminal of this Neovim, or not sent.** A chat running elsewhere cannot be queued for, and a chat that ended keeps its queue until you send or drop it with `Q`.
- **A dialog the agent shows is only known when the agent says so.** Claude Code reports its prompts through its registry and hooks, Qwen Code and opencode through their hooks. For anything else (an update offer, a trust question), the paste rule above is the protection: the reply is not sent, and you are told to look.
- **Codex and opencode keep no record of running sessions**, so which process has which chat open is matched from process inspection (and, with hooks installed, from the process a session's hook ran under).
- **The agents' on-disk formats are not public interfaces** and change between versions. The readers skip what they do not recognise.

What was looked at and left out, and why:

- **Codex app-server.** It reports a status per thread, including "waiting on approval". It is marked experimental, and it only sees threads hosted by a shared daemon, so using it would mean starting or keeping alive a daemon you did not ask for. Codex's hooks are stable, on by default, and report the same states for every way Codex is started.
- **opencode's HTTP server.** `GET /session/status` exists, but a normal `opencode` picks a random port each time and nothing documented says which. The plugin file reports every session without that.
- **`qwen sessions ps`.** It prints the same registry records this plugin already reads, at the price of starting Node. It is used only when the registry is not where it is expected, and by `:checkhealth` to compare the two.
- **The Agent Client Protocol.** It makes the editor the owner of a session; it does not show chats started elsewhere.

## Adding another agent

Each agent is one table. Register yours and it gets the whole board. This is a complete reader for a made-up agent, Pal, that keeps each chat as `~/.pal/chats/<id>.jsonl` with one `{ "role": ..., "text": ... }` per line:

```lua
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

  -- The conversation, for the transcript view and search.
  messages = function(chat) return read(chat.path), nil end,

  resume_cmd = function(chat) return { 'pal', '--resume', chat.id } end,
  new_cmd = function(opts) return { 'pal', opts.prompt } end,

  -- Optional: what the events of its hooks mean, if it has hooks.
  hooks = {
    events = { prompt = 'working', ask = 'waiting', answer = 'resolved', stop = 'done' },
  },
})
```

That is all the board needs. The rest is optional and each piece stands alone:

| Field | What it adds |
| --- | --- |
| `hooks.events` | Exact status from events the agent pushes. The agent runs the [hook script](scripts/agent-chats-hook.sh) with its name; an agent whose hooks do not pass JSON on standard input passes the event and session id as arguments: `sh agent-chats-hook.sh pal ask "$PAL_SESSION"` |
| `hooks.config()` | How `:Chats hooks install` sets those hooks up |
| `query(chats)` | Status from a CLI or API of the agent, asked every `query_interval` ms |
| `live(chats)` | Which chats have a running process, from files or the process table |
| `locate`, `subagents`, `grep`, `rev`, `check` | Finding the transcript of a new session, child agents, narrowing a search, noticing a rename, lines for `:checkhealth` |
| `fork_cmd`, `headless_cmd`, `resume_prompt_cmd` | Forking, background replies, resuming with a message |

The full contract is in [`lua/agent-chats/types.lua`](lua/agent-chats/types.lua), and [`providers/claude.lua`](lua/agent-chats/providers/claude.lua) is the reference implementation. Its options go under `providers.pal`.

## Development

```
make test               # every spec (needs only nvim; a few tests also use sh, ps and node when present)
make test SPEC=hooks    # one spec file
make test FILTER='text' # tests whose name contains the text
make lint               # stylua --check, and shellcheck on the hook script when installed
```

The tests build synthetic agent data in temporary folders and never read your real chats or touch your agents' settings. As a net under that, the run moves `$HOME` and the XDG folders into a temporary folder before the plugin loads, and fails if a spec writes to any default location. `tests/demo.lua` stages a board with chats in every state to look at:

```
nvim --clean -c 'luafile tests/demo.lua'
```

`:checkhealth agent-chats` reports which agents were found, where each one's status comes from, and which optional tools are present.

## License

MIT
