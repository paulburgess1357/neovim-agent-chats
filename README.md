# agent-chats.nvim

One board for every AI agent chat on your machine: Claude Code, Codex, Qwen Code and opencode.

See which chats need you, which are still working and which have finished. Go into any of them in a Neovim terminal and type, search what was said, and start new ones, without hunting through terminals.

```
 Enter resume  C conversation                             ? menu │ Summary
 8 chats · 1 needs you · 2 working · 1 unread   + new   S search │# Write the README
                                                                 │
▾ Needs you  1   waiting for your answer                         │✓ Unread: it finished 4m ago.
 ●  Claude  Fix flaky session restore ↗       nvim-config     2m │  Enter resumes it in ~/work/plan.
                                                                 │
▾ Working  2   in the middle of a turn                           │Folder  ~/work/plan · main
 ◐  Claude  Port the renderer to Vulkan »1 ↗  engine          1m │Agent   Qwen · qwen-test-1
 ◐  Codex   Add a picker for tab pages ↗      nvim-config     1m │Started 14:10
                                                                 │
▾ Unread  1   finished since you last looked                     │## First prompt
 ✓  Qwen    Write the README                  plan            4m │
                                                                 │Write a README for the plan repo, covering setup and the weekly
▾ Idle  1   open, nothing new                                    │workflow.
 ○  Claude  Refactor the audio mixer ↗        engine         25m │
                                                                 │## Last prompt
▾ Ended  3   not open, can be resumed                            │
 ·  Codex   Explain the borrow checker error  engine          2h │Shorter, and put the two setup commands first.
 ·  Claude  Review the release checklist      plan            2d │
 ·  Qwen    Migrate the config to vim.pack    old-checkout    4d │## Last reply
                                                                 │
                                                                 │The README is rewritten.
                                                                 │
                                                                 │- Setup comes first: the two commands, nothing else.
                                                                 │- Workflow walks through a week in five lines.
                                                                 │
                                                                 │One thing to check: the badge URL is a guess.
```

The bar above the list names what you can do with the row under the cursor, and the keys for it. The pane beside it shows that chat. Nothing has to be remembered: `?` opens the menu, which lists everything else.

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

`:Chats` opens the board in its own tab. Run it again from anywhere to go back to it; `q` on the board then leads back to where you last asked for it.

The left side lists your chats. The right-hand pane follows the cursor:

- For a chat running in a terminal of this Neovim, it shows that **live terminal**.
- For any other chat, it shows a **summary**: what state it is in and what it wants from you, the folder it works in, your first prompt, your last prompt, and the last reply.

Press `Enter` to go into the chat, and type: that is how you reply. A chat running in this Neovim is focused. One that ended is resumed, in its own folder (the summary says which before you press anything). One that runs somewhere else can only be read here, so its conversation opens instead.

You do not have to learn the keys below. **The bar above the list always names the ones for the row you are on**, and `?` opens the menu: everything else that can be done, in words. It is one list, all of it in view, in parts with a heading each: the chat under the cursor, your own marks on it (a name, a pin, a group, labels, a note), the list (a new chat, the search, how it is grouped) and the board (the pane, the status hooks, notifications). Pick a line with `Enter` or a click. A line that has a key shows it, and the key works right there too: a key of the board does in the menu what it does on the list, also when the menu does not list it for this row (it then says why not, as on the list). For a letter either case will do, unless the other case is a key of yours or of another action. (`q` and `Esc` close the menu, so an action whose key is one of those is shown with the key after its words: "Close the board (q)" is what `q` does on the list.) When something cannot be done with a chat, the bar says why: "(it runs outside this Neovim)", "(its folder is gone)"; on a narrow list in short, "(runs elsewhere)", "(folder gone)". The reason comes before the less used keys: those are in the menu, and why `Enter` only reads a chat is nowhere else.

This is the menu on a chat that has ended:

```
  ── This chat ────────────────────────────────────
  Enter  Resume it in ~/work/plan
  C      Read the conversation
         Show what changed in its folder
  ── Keep track of it ─────────────────────────────
         Rename
         Pin to the top of its group
         Put it in a group of your own
         Edit its labels
         Add a note
         Mark unread
         Archive (hide it until it is active again)
         Copy the command that resumes it
  ── The list ─────────────────────────────────────
  +      New chat
  S      Search chats
         Group by folder
         Group by agent
         Group by worktree
         Show older and archived chats
         Mark every chat read
         Go to the next chat that needs you
         Go to the previous chat that needs you
  ── The board ────────────────────────────────────
         Hide the pane
         Refresh the list now
         Status hooks of the agents: see or set up
         Turn notifications off
         Close the board (q)
```

It opens with the cursor on the first line. `j` and `k` move over the lines that can be chosen and go round at the ends, so `k` from the top is the last line; `gg` and `G` are the first and the last. Only what applies is listed: a chat that is in the middle of a turn has a line to queue a reply, a chat that runs somewhere else has none to resume it, a heading has "Fold this group" and nothing about a chat.

### Keys

The board's own letters are capitals, so every lowercase key stays what it is everywhere else in your Neovim: `j` and `k` move, `gg` and `G` jump, and whatever you have mapped yourself still does what you mapped it to. The cursor passes over the lines that stand for nothing (the counts at the top, the gap between two groups), so `gg` lands on the first heading and `G` on the last row.

| Key | What it does |
| --- | --- |
| `Enter` | Go into the chat and type (see above). On a heading: fold or unfold the group |
| `C` | Read the whole conversation, tool calls folded |
| `+` | New chat: pick the agent, and it opens |
| `S` or `/` | Search every chat, inside the conversations too |
| `?` or `g?` | The menu: everything else, for the row under the cursor and for the board |
| `q` | Back: out of a conversation, out of a search, out of the board |
| `Esc` | End a search |
| `Tab` | Fold a group, or show a chat's subagents |

A double click opens a chat, and a right click opens the menu.

In a conversation the same keys act on the chat being read: `q` goes back to the list, `+` and `S` start a chat and search as they do on the list, and `?` opens the menu for this chat, with the keys that work there. `]]` and `[[` (or `J` and `K`) move between your prompts. A tool call is folded to one line, which says how much it holds and how to open it: `Tab` or `Enter` on that line, or the usual fold commands. `/` is Vim's own search there, with `n` and `N` behind it, so a long conversation is searched like any buffer; the search over every chat is on `S`.

Those are all the keys there are. The rest is in the menu, and has no key until you give it one in the `keys` option:

- **For the chat:** queue a reply for when it finishes its turn (`queue`), show what changed in its folder (`diff`).
- **To keep track of it:** rename it, pin it, put it in a group of your own (`move`), label it, add a note, mark it read or unread, archive it, copy the command that resumes it (`yank`).
- **For the list:** group it by folder, agent or worktree, show older and archived chats, mark everything read, go to the next or the previous chat that needs you.
- **For the board:** hide the pane, refresh, set up the status hooks, switch notifications off and on (`notify`).

(Two more can be given keys and are not in the menu, because they only move what you see: `scroll_down` and `scroll_up` scroll the pane from the list.)

`q` is the one way back, everywhere. So is closing the window, however you do that: `:q` in a conversation takes you back to the list just as `q` does. If the cursor ends up in the summary (a window command, a click), the keys of the list work there too, on the chat it shows, and `q` goes back to the list. In the floating layout the list and the pane are two floats, which Neovim's window commands know nothing of: on the board `<C-w>h`, `<C-w>l`, `<C-w>w` and `<C-w>p` move between the two as they would between two windows side by side. (A key of your own that calls `:wincmd` leaves the floats for the window behind them, and that closes the floating board.)

### Your keys stay yours

Every key the board maps is local to its own windows, but a local mapping still hides a global one. So:

- **A default key is not bound where you have a mapping of your own on it.** If `S` is your jump key, the board leaves `S` alone and searches with `/`; if `?` is yours, the menu is on `g?`. The bar and the menu name whichever key is actually bound, never one that is not.
- **A key you name in the `keys` option is always bound.** That is how you say "take this one anyway": `keys = { back = 'q' }`. It is also that action's alone: an action that only had the key by default loses it (`keys = { archive = 'C' }` leaves reading the conversation without a key), and of two actions you give the same key the first in the alphabet keeps it. You are told of both, and `<cr>` and `<CR>` are one key.
- An action that ends up with no key is still one step away, in the menu and in `:Chats menu`. The menu marks a key that was left to you with `*`, and `:checkhealth agent-chats` lists every such key and what does its work instead.

This holds on the list, in a conversation and in a chat's terminal. The keys are worked out when the board opens and again each time the list gets the cursor, and a default key that a mapping of yours has turned up on since (a plugin that loads late) gives way at the first press: your mapping runs, and the bar stops naming the key. `setup()` called again takes effect on the list and the summary at once; a conversation or a chat's terminal that is already open keeps the keys it was opened with, and names those. Neovim's own default mappings and a key you mapped to `<Nop>` do not count as yours. A longer mapping of yours that merely begins with one of these keys is not counted either: on the board the short key acts at once, without waiting for more, so the longer one is out of reach there when typed by hand.

The pop-up boxes (a reply to be queued, the menu) are the plugin's own windows, open only until you send or close them, and their keys are fixed: the footer of each names them.

### Statuses

| | Status | Meaning |
| --- | --- | --- |
| `●` | Needs you | The agent is blocked on you: a permission prompt or a question |
| `◐` | Working | The agent is mid-turn |
| `✓` | Unread | The turn finished and you have not looked at it since |
| `○` | Idle | Finished, seen, and the agent is still open |
| `·` | Ended | No process has the chat open; it can be resumed |

`●?` is a guess: see [How status is worked out](#how-status-is-worked-out). Opening a chat, reading its conversation, or having its terminal in front of you when it finishes, marks it read (live in the pane beside the list counts: a reply you sent from the list and watched arrive is not "unread"). It has to have been there for a couple of seconds: going down the list past an unread chat does not mark it read. `↗` marks a chat that runs outside this Neovim, and `»2` one with two replies queued.

### Groups of your own

The list is grouped by what each chat is doing. A chat can be taken out of that and put in a group you name: "Put it in a group of your own" in the menu asks which one (the groups there are, or a new one; the first time, only the name).

```
▾ Release  2   ●1
 ●  Claude  Review the release checklist ↗    plan            2m
 ·  Codex   Explain the borrow checker error  engine          2h

▾ Working  1   in the middle of a turn
 ◐  Codex   Add a picker for tab pages ↗      nvim-config     1m
```

Your groups are headings of their own above the others, by name. A chat stays in its group whatever it does: its mark still says whether it needs you, is working or has ended, and what needs you comes first in the group. The heading says how many of its chats want a look (`●1`), also while it is folded, and the counts on the first line include them. A chat in a group is not dropped from the list for being old (`board.max_age_days`).

"Move it out of “Release”, or to another group" on a chat that is in one offers the other groups, a new one, and "No group": it is then back where its status puts it. A group is nothing but its chats. It is made by naming it, and it is gone when the last chat has left it.

A search finds a chat by the name of its group, and its summary shows it ("Group   Release"). Your groups belong to the grouping by status: grouped by folder, agent or worktree, the list shows those and nothing else, and you are told so when you move a chat there.

### Searching

There is one search. `S` asks for the text and narrows the list while you type: it looks at what each row shows and holds (names, folders, branches, agents, labels, notes, your groups, your first and last prompt, the last reply). When you pause, and when you press `Enter`, the conversations themselves are read for the same text, and the passages found are listed under their chats; `Enter` on a passage opens the conversation there, and `C` on the chat's own row opens it at the first of them. What is read is what a conversation shows: your prompts, the replies, and the line each tool call has ("Bash · make test"). What a call was given and what it returned is read as well with `search.tools`. Whether a match is in a title or deep in a conversation, it is the same key and the same list.

Words are looked for in any order in a row; inside conversations the text is looked for as typed, ignoring case unless it has a capital. Archived chats are found too. What you searched for is marked where a row shows it, so a chat found by its folder shows why. While you type, the first line names the keys of the prompt (`Enter` keeps the search, `Esc` calls it off); afterwards `q` (or `Esc`) ends the search, and `S` again asks for another text (the prompt starts empty; `Up` brings back the last one).

### Replying

To reply, press `Enter` and type. You are in the chat's own terminal then, with everything its agent offers; a chat that had ended is resumed first, in its folder. There is no box to write a reply in, and no key for it.

A reply can also wait. The menu of a chat that is in the middle of a turn has "Queue a reply for when it finishes its turn": it opens a box, and what you write there is pasted into the chat's terminal when that turn ends. With replies queued the row shows how many (`»2`), its summary shows them, and the menu line reads "Queued replies (2): send, add or drop". (`keys.queue` gives this a key. The key then works on any chat: on one that is not busy and has nothing queued there is nothing to wait for, so it sends at once, and the title of the box says which it will be before you write.)

Nothing can be sent from here to a chat that runs outside this Neovim, or to one whose folder is gone. No reply can be queued for such a chat, and replies that were queued for it earlier can only be dropped. A reply that is sent to a chat that has ended resumes it (`reply.ended` says how: in a terminal, or in the background, where it runs with no terminal at all; while a background reply is being answered the chat can be read and nothing else, and the board says so).

These rules keep what is sent from the list (a queued reply, lines sent with `:Chats send`) from going where it should not:

- **It is pasted, and Enter is pressed only once the terminal shows the text.** An agent may be showing a dialog of its own that nothing reports: "trust this folder?", "update available", a permission prompt. Keys typed into one are answers to it, and Enter confirms whatever it has selected. A dialog does not take a paste, so the text never appears, Enter is not pressed, and you are told that nothing was sent. A chat that is known to be asking (it shows as "Needs you") is not pasted into at all: you are taken to it to answer first.
- **A queued reply is only ever pasted into a terminal of this Neovim that still has the chat in it,** and never starts an agent by itself. If the chat ends first, its replies are kept, you are told, and from then on they go only when you say so: "Queued replies" in the chat's menu sends them, adds to them, or drops them. Opening the chat again does not send them. The summary of a chat with replies queued says which of the two holds.
- **It waits while the terminal holds something you typed and have not sent.** Pasted behind your half-written line, the two would go as one message. You are told once, and it goes when you have sent your line or cleared it.
- **Nothing is typed into a terminal that the agent is not reading.** An agent you started by hand in a shell and then suspended (`Ctrl-Z`) has left the shell reading: what is pasted there would be run as commands. The board says so and sends nothing. (A terminal the plugin started has no shell in between.)

What you wrote in the box and then did not send (the box was closed, the question of how to send was dismissed, the chat did not take it, the agent that was resumed for it exited at once, a background run failed) is in the box again the next time. So is what you wrote for a chat while its row was still a stand-in for it: a draft or a queued reply goes with the chat when its agent has named it.

### Notifications

When a chat needs you or finishes a turn, you are told (the `notify` options say what counts, and whether the desktop is told as well). The menu switches all of it off and on again: "Turn notifications off" is its last line but one, so from where the menu opens `k` twice leads to it (the menu goes round), and `Enter` switches. While they are off, the first line of the list says "notifications off"; while they are on, it says nothing. It is one switch for every Neovim and is kept when Neovim is closed. `:Chats notify`, `:Chats notify on` and `:Chats notify off` do the same from anywhere, and `keys.notify` gives it a key. The board itself goes on showing what needs you either way.

### Starting a chat

`+` asks one thing: which agent. The question names the folder the chat will start in (the one Neovim is in), and the agent you used last is its first line, so `+` and `Enter` start another chat with it. The last line leads to another folder: one used lately, a new git worktree of the repository that folder is in (if it is in one), or any other. Then the agent's own terminal opens and you are typing in it. What to say to it first, which model it runs and everything else about it is chosen there, in the agent itself: the board asks nothing more. `:Chats new claude` starts that agent without asking. (What it is started with is `providers.<name>.cmd`: `cmd = { 'claude', '--model', 'opus' }` is how every new Claude chat gets a model.)

A new chat has a row from the start, so there is always one that leads back to its terminal. Until its agent has named it, the row says "(no prompt yet)". The cursor of the list goes to the new row, so going back lands on the chat you just started.

**Passing a chat on to another agent is switched off.** It is on no key and in no menu until you give it a key: `keys = { pass = 'P' }`. With one, `P` asks which agent, and a box shows the notes that agent will be started with, for you to read and change before they go. The notes are not the whole conversation. They hold the task's name, the folder and branch, your first prompt, and the last eight messages of the conversation as they were said (yours and the agent's; no tool calls or their output), each cut to a paragraph or two, with a count of how many earlier ones were left out. The new chat starts in the same folder, so its agent can look at the files and at git for the rest, with that agent's own command (`providers.<name>.cmd`), and so with whatever model that gives it. Its row shows the first line of the notes, which names the task ("Taking over “Fix the parser” from Claude"), until the agent has named the chat. If the agent does not start (it is not installed, it exits as soon as it is started, the notes are longer than a program can be given when it starts, about 127 KB), you are told why, and the notes are in the box the next time.

What an agent asks when it starts is its own business and shows in that terminal: Claude Code and Codex ask whether to trust a folder they have not seen, Codex asks about hooks it has not been told to trust, any of them may offer an update. The plugin never answers these for you.

### Folders

A chat belongs to the folder it was started in, and its agent is always started there: when you open a chat that ended, or send it a reply that was queued. Where Neovim itself happens to be makes no difference, and neither does a `cd` the agent did along the way. The folder is in the chat's summary ("Enter resumes it in ~/work/plan"), on its row when the list is wide enough for it, and in the title of its terminal.

A chat whose folder no longer exists cannot be resumed, because no agent resumes a chat from anywhere else. The board says so before you try: such a chat can still be read. (Where passing on has a key, it can also be passed on to a new chat in a folder you choose.)

### In a chat's terminal

While you type in a chat, every plain key belongs to the agent. `<C-\><C-b>` (`open.back_key`) goes back to the list; in the terminal's normal mode `q` does. The title of the pane says which chat and folder you are in, and names the key that goes back in the mode you are in. Closing the window (`:q`) goes back as well, and is what the title names when no key is bound. A chat that is open in a terminal here is listed as open ("Idle" or busier) from the moment its terminal exists, never as "Ended".

To give chat terminals the mappings your other terminals have, set `open.on_open`. It is called once for every terminal the plugin starts for a chat, after the plugin has set its own keys, and whatever it maps is left alone:

```lua
require('agent-chats').setup({
  open = {
    on_open = function(buf)
      -- Window keys that work while typing, as in the terminals you open yourself.
      for _, dir in ipairs({ 'h', 'j', 'k', 'l' }) do
        vim.keymap.set('t', '<C-' .. dir .. '>', [[<C-\><C-n><C-w>]] .. dir, { buffer = buf })
      end
    end,
  },
})
```

If your function maps a key of its own on top of one of the two that go back, the title stops naming that key, because the plugin cannot know what yours does. To have it named, say so: return `{ back = 'q' }` for the key that goes back in normal mode, `{ back_typing = '<C-x>' }` for the one while typing (`require('agent-chats').open()` is what goes back). A key is named only if something of yours is mapped on it there.

The same moment is the `User` event `AgentChatsTerminal` (`data.buf`, `data.key`, `data.chat`), for code that lives elsewhere. A terminal you made yourself (a chat you started by hand in a `:terminal`, or one from `open.where`) is yours: the board shows it and gives it the one key that goes back while typing, and changes nothing else about it.

### Commands

| Command | Action |
| --- | --- |
| `:Chats` | Open the board, or go to it |
| `:Chats new [agent]` | Start a new chat |
| `:Chats next` | Jump into the chat that has waited for you longest |
| `:Chats search [text]` | Search every chat (asks for the text when none is given) |
| `:Chats menu` | The menu for the chat under the cursor on the board |
| `:'<,'>Chats send` | Send the selected lines, with their file and line range, to a chat running in this Neovim |
| `:Chats hooks [install\|uninstall\|show\|status] [agent]` | Set up the status hooks, for every agent in use or the ones named; alone, it opens an overview |
| `:Chats notify [on\|off]` | Switch notifications on or off; alone, the other way round |
| `:Chats refresh` / `:Chats close` / `:Chats toggle` / `:Chats health` | As named |

`:AgentChats` is the same command under a second name. Where another plugin already owns `:Chats`, that is the name this plugin's hints use, and what `<Plug>(agent-chats-send)` runs.

Nothing is mapped globally. Suggested mappings:

```lua
vim.keymap.set('n', '<leader>ac', '<Plug>(agent-chats)')        -- board
vim.keymap.set('n', '<leader>an', '<Plug>(agent-chats-next)')   -- next chat that needs you
vim.keymap.set('n', '<leader>aN', '<Plug>(agent-chats-new)')    -- new chat
vim.keymap.set('n', '<leader>as', '<Plug>(agent-chats-search)') -- search chats
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

`:Chats hooks install` sets them up for every agent you use, or `:Chats hooks install codex` for one. It shows a diff of every file it would touch, asks, and keeps the old file beside the new one. `:Chats hooks` alone opens an overview with the same actions on keys; it is also in the board's menu, under "The board".

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

The summary says where a running chat's status comes from ("Status  known from its hooks"), and `:checkhealth agent-chats` says it per agent.

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
    group_by = 'status',   -- 'status' | 'folder' | 'agent' | 'worktree'
    max_age_days = 30,     -- hide chats quiet for longer; 0 shows everything
    max_per_group = 40,    -- rows per group before the rest is folded away
    spinner = true,        -- animate the glyph of working chats
    intro = true,          -- introduce the board in the pane the first time it opens
  },

  open = {
    -- Where a chat's terminal opens: 'pane' (the board's pane) | 'vsplit' |
    -- 'split' | 'tab' | 'float' | 'current', or a function (see below).
    where = 'pane',
    size = 0.4,            -- share of the screen for 'vsplit' / 'split'
    start_insert = true,
    close_on_exit = true,  -- drop the terminal when the agent exits cleanly
    back_key = '<C-\\><C-b>', -- while typing in a chat: back to the list; false unmaps
    reuse = true,          -- reuse the window already holding a chat instead of splitting again
    on_open = nil,         -- function(buf, chat): your own setup for a terminal started for a chat
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
    enabled = true,        -- the switch in the menu overrides this for good, once it has been used
    attention = true,      -- a chat needs you
    done = true,           -- a chat finished its turn
    inferred = false,      -- also for the "Needs you?" guess
    scope = 'all',         -- 'all' | 'cwd' (chats under :pwd) | 'hosted' (terminals in this Neovim)
    desktop = false,       -- also notify-send / osascript
    handler = nil,         -- function(event) ... return true to suppress the default end
  },

  reply = {
    ended = 'ask',         -- a reply sent to an ended chat: 'ask' | 'terminal' | 'background'
    paste_delay = 120,     -- ms between pasting a reply and pressing Enter, at least
    echo_wait = 2000,      -- ms to wait for the terminal to show the pasted text; Enter is not pressed without it
  },

  worktree = {
    path = '{parent}/{repo}.worktrees/{name}', -- or function(ctx) return path end
    base = nil,            -- ref a new worktree branch starts from; nil is HEAD
  },

  -- The view of a whole conversation.
  conversation = { tool_output_lines = 30, thinking = false, fold_tools = true },
  search = {
    live = true,           -- read the conversations while you type (after a pause), not only on Enter
    max_hits = 5,          -- passages shown per chat
    tools = false,         -- also search what tool calls were given and gave back
  },

  diff = nil,              -- function(chat) to show changes your own way
  state_file = nil,        -- default: stdpath('state')/agent-chats/state.json
  cache_file = nil,        -- default: stdpath('cache')/agent-chats/index.json; false disables

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
    elsewhere = '↗',       -- running, but not in a terminal of this Neovim
    providers = {},        -- e.g. { claude = '󰚩' } to show a glyph instead of the name
  },

  -- Keys: a key, a list of keys, or false for none. A default gives way to
  -- a mapping of yours on the same key; a key you set here never does, and
  -- is taken from any other action that only had it by default.
  keys = {
    open = { '<CR>', '<2-LeftMouse>' },
    read = 'C',            -- the whole conversation
    new = '+',
    search = { 'S', '/' },
    menu = { '?', 'g?', '<RightMouse>' },
    back = 'q',
    clear = '<Esc>',       -- end a search
    toggle = '<Tab>',      -- fold a group, show a chat's subagents

    -- In a conversation.
    next_prompt = { ']]', 'J' },
    prev_prompt = { '[[', 'K' },

    -- No key by default. All but the two that scroll are in the menu.
    queue = false,         -- a reply for when the chat finishes its turn
    move = false,          -- into a group of your own, or out of it
    notify = false,        -- notifications on or off
    diff = false,
    rename = false,
    pin = false,
    label = false,
    note = false,
    unread = false,
    archive = false,
    yank = false,          -- copy the command that resumes the chat
    group = false,         -- cycle the grouping
    pane = false,          -- show or hide the pane
    show_all = false,      -- older and archived chats
    read_all = false,
    next_attention = false,
    prev_attention = false,
    scroll_down = false,   -- scroll the pane from the list
    scroll_up = false,
    refresh = false,
    hooks = false,

    -- Switched off: passing a chat on to another agent is neither in the
    -- menu nor on a key until it is given one here.
    pass = false,
  },
})
```

Highlight groups all start with `AgentChats` and link to standard groups, so the board follows your colorscheme.

Options written for an earlier version are still read: `transcript` is `conversation` now, `group_by = 'provider'` is `'agent'`, and `keys.transcript`, `keys.handoff`, `keys.filter`, `keys.help` and `keys.close` are `keys.read`, `keys.pass`, `keys.search`, `keys.menu` and `keys.back` (a message says so).

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

`User` autocommands: `AgentChatsUpdate` (the index changed), `AgentChatsAttention` and `AgentChatsDone` (a chat needs you, a chat finished its turn; with `data.key` and `data.chat`), and `AgentChatsTerminal` (the plugin started a terminal for a chat; with `data.buf`, `data.key` and `data.chat`).

## Limits

What has and has not been checked against the real thing:

- **Reading chats** is checked against real data of all four agents (Claude Code 2.1, Codex 0.121 to 0.166, Qwen Code 0.26 and 0.28, opencode 1.17 and 1.19).
- **A real chat with each agent was driven through the plugin**, by its keys, in a real terminal (Claude Code 2.1.330, Codex 0.171.0, Qwen Code 0.28.3, opencode 1.19.6; earlier versions of each before that): a new chat from the board (`+`, the agent picked, the first prompt typed in its own terminal), going back to the list and into the chat again, a reply queued behind a running turn, the conversation, a search inside it, quitting the agent, opening the chat again. With Claude Code also: a permission prompt answered with a reply queued behind it, a queued reply held back while the chat's terminal held a half-typed line (and sent once that was cleared), a chat running in a terminal outside Neovim, and passing a chat on (to Qwen Code). Sending several lines at once, and sending to a chat that had ended (in a terminal and in the background), were driven with Claude Code while the list still had a key for an immediate reply; the same sending code is behind a queued reply and `:Chats send` now. The board as it is now, with the menu as the way to everything that has no key, was driven with Claude Code under a real config with mappings of its own: the menu opened from the key the bar names, notifications switched off and on from it, a chat put in a group of its own and taken out again, and a reply queued from the menu line behind a running turn and sent when the turn ended. With the other three agents the same actions were driven while they still had keys of their own. That is where the rules about pasting above come from: an earlier version typed a reply into opencode while it was offering an update, and its Enter accepted the update. Not driven for real: a new git worktree for a new chat, permission prompts of the other three agents.
- **The hooks report correctly from real sessions** of Claude Code (including a question it put to the user, shown as "Needs you" the moment it was asked), Qwen Code (including a permission prompt) and opencode (busy and idle). Not seen live: opencode's permission requests, and anything from Codex's hooks, which Codex runs only after you have trusted them.
- **Everything else** (the installer's refusals, two Neovims on one state file, every awkward order of events in the regression tests) runs in the test suite against stand-ins.
- **macOS**: never run on a Mac. The code path for systems without `/proc` is exercised by the tests on Linux, where `ps` and `lsof` take the same arguments. **Windows** is untested, and the shell hooks need a POSIX `sh`.

What it cannot do:

- **Chats running outside this Neovim** (another terminal, an IDE) are listed with `↗` and can be read, but not typed into: only Neovim terminals are driven.
- **Background replies cannot answer permission prompts.** A step that needs approval fails. Use `headless_args` to choose the agent's non-interactive permission mode, or reply in a terminal.
- **Queued replies are pasted into a terminal of this Neovim, or not sent.** A chat running elsewhere cannot be queued for (what was queued for it before can only be dropped), and a chat that ended keeps its queue until you send or drop it from its menu.
- **A dialog the agent shows is only known when the agent says so.** Claude Code reports its prompts through its registry and hooks, Qwen Code and opencode through their hooks. For anything else (an update offer, a trust question), the paste rule above is the protection: the reply is not sent, and you are told to look.
- **Codex and opencode keep no record of running sessions**, so which process has which chat open is matched from process inspection (and, with hooks installed, from the process a session's hook ran under). Codex 0.171 keeps a daemon (`codex app-server`) that holds every session and runs their hooks; the daemon being alive is not taken for a chat being open, only a `codex` process of a terminal is.
- **Two opencode processes in one folder, without its hooks, can only be told apart by a guess.** A process started with a prompt is matched to the chat that begins with that prompt. Beyond that there is the folder and the time, and nothing more. The guess is still made, so that each row leads to a terminal, but nothing is typed on it: queueing a reply for such a chat says why, and you type in its terminal. With the hooks installed (`:Chats hooks install opencode`) opencode says which process has which chat, and none of this applies.
- **A prompt is handed to an agent as an argument when it starts**, and an argument can hold about 127 KB. A longer first prompt, or longer notes for a chat that is passed on, are refused with that reason and kept in the box: start with less and paste the rest into the terminal.
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

  -- The conversation, for reading it and for searching it.
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
| `headless_cmd`, `resume_prompt_cmd` | Background replies, resuming with a message |

The full contract is in [`lua/agent-chats/types.lua`](lua/agent-chats/types.lua), and [`providers/claude.lua`](lua/agent-chats/providers/claude.lua) is the reference implementation. Its options go under `providers.pal`.

## Development

```
make test               # every spec (needs only nvim; a few tests also use sh, ps and node when present)
make test SPEC=hooks    # one spec file
make test FILTER='text' # tests whose name contains the text
make lint               # stylua --check, and shellcheck on the hook script when installed
make format             # stylua, twice
```

The tests build synthetic agent data in temporary folders and never read your real chats or touch your agents' settings. As a net under that, the run moves `$HOME` and the XDG folders into a temporary folder before the plugin loads, fails if a spec writes to any default location, and sees only the processes it started itself (an agent you have running would otherwise turn up as a chat in a test).

`tests/demo.lua` stages a board with chats of three agents in every state, in a home of its own. Open it to use it, or have every screen printed as text (the picture at the top of this file is `DEMO_DUMP=readme` at 132 columns):

```
nvim --clean -c 'luafile tests/demo.lua'
DEMO_DUMP=all nvim --clean --headless --cmd 'set columns=150 lines=40' -c 'luafile tests/demo.lua'
```

`:checkhealth agent-chats` reports which agents were found, where each one's status comes from, and which optional tools are present.

## License

MIT
