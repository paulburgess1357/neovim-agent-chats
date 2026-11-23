# Neovim Agent Chats

One board in Neovim for every AI agent chat on your machine: Claude Code, Codex, Qwen Code and opencode.

![The board: every chat in a list on the left, grouped by what it is doing, and the chat under the cursor in a terminal on the right](assets/board.png)

See which chats need you, which are still working and which have finished. Go into any of them in a Neovim terminal and type, search what was said, and start new ones.

It reads what the agents already write to disk and listens to what they report through their own hooks. Nothing wraps how you start them, so chats started anywhere show up: in a Neovim terminal, in another terminal, by a script.

## Requirements

- Neovim 0.11 or newer.
- At least one of the agents. No plugin dependencies, no patched font, no build step.
- Used when present: a POSIX `sh` (the status hooks), `git`, `rg`, and the system SQLite library (opencode).

Developed and tested on Linux. It has never been run on macOS, and Windows is untested.

## Install

With Neovim's built-in plugin manager (0.12):

```lua
vim.pack.add({ 'https://github.com/paulburgess1357/neovim-agent-chats' })
require('agent-chats').setup()
```

With lazy.nvim:

```lua
{ 'paulburgess1357/neovim-agent-chats', main = 'agent-chats', opts = {} }
```

## Set up

**1. Open it.** `:Chats` opens the board. Nothing is mapped globally, so give it a key if you like:

```lua
vim.keymap.set('n', '<leader>ac', '<Plug>(agent-chats)')
```

**2. Install the status hooks, once.** Run `:Chats hooks install`. It adds a small hook to the settings of each agent you have, so that the agent itself reports when it is working, when it needs you and when it has finished. It shows every line it is about to change and asks before it writes anything, and `:Chats hooks uninstall` takes it all out again. The board works without the hooks, but for every agent except Claude Code "Needs you" is then a guess.

**3. Configure it, if you want to.** Every option has a default, so `setup()` with nothing in it is enough. Options go in the same call, in your `init.lua` (with lazy.nvim, in `opts`):

```lua
require('agent-chats').setup({
  filter_out = { 'scratch' }, -- folders whose chats are kept out of the way (see below)
  board = { layout = 'float' }, -- 'tab' (the default), 'float' or 'current'
  notify = { enabled = false }, -- no notifications
  keys = { pin = 'P' }, -- give something in the menu a key of its own
})
```

Every option, with its default and what it does, is in the manual: [`doc/agent-chats.txt`](doc/agent-chats.txt), or `:help agent-chats-options` in Neovim.

## Using the board

The list on the left has every chat, under what it is doing:

| Heading | What it means |
| --- | --- |
| Needs you | The agent is waiting for your answer: a question, a permission |
| Working | The agent is in the middle of a turn |
| Unread | It finished since you last looked |
| Idle | Open, nothing new |
| Ended | Not open anywhere; it can be resumed |

The pane on the right shows the chat under the cursor: its live terminal when it runs in this Neovim, a summary otherwise (`I` shows the summary of a chat whose terminal is there, and `I` again the terminal). `Enter` goes into the chat, and you type there as you would in any terminal. A chat that ended is resumed, in its own folder.

You do not have to learn any keys. The bar above the list names them: what `Enter` does with the row you are on, then the rest.

## The menu

`?` opens the menu (`g?` if `?` is a key of your own; the bar says which). It lists everything that can be done, in words, and a line that has a key shows it, so the keys are picked up as you go. Choose a line with `Enter` or a click.

- **This chat.** Go into it, read the whole conversation, see its summary in place of its terminal, queue a reply to be sent when the agent finishes its turn, see what changed in its folder.
- **Keep track of it.** Rename it, pin it to the top of its group, put it in a group of your own, give it labels or a note (the note is shown on its row), mark it read or unread, archive it, copy the command that resumes it.
- **The list.** Start a new chat, search every chat (inside the conversations too), group the list by folder, agent or worktree, show older chats, mark everything read.
- **The board.** Hide the pane, refresh, see or set up the status hooks, switch notifications off and on, close the board.

## Keeping chats out of the way

**Filter folders out.** Chats you never want among the others (the ones a test suite starts, a scratch folder) are filtered out by their folder, with a list in the options:

```lua
require('agent-chats').setup({
  filter_out = { 'scratch', '~/tmp/experiments' },
})
```

A name stands for every folder called that, wherever it is, and everything inside it. A path stands for that one folder and everything inside it. Their chats go under one heading, "Filtered out", at the end of the list and folded. They are not counted and you are not notified about them; a search still finds them.

**Archive a chat.** "Archive it" in the menu (`A`) puts one chat under "Archived", at the very end of the list. The same on an archived chat takes it out again, and a chat that becomes active again comes back by itself.

**Folder gone.** A chat whose folder no longer exists cannot be resumed, only read. Those are under a heading of their own as well.

## Commands

| Command | Action |
| --- | --- |
| `:Chats` | Open the board, or go to it |
| `:Chats new [agent]` | Start a new chat |
| `:Chats next` | Go into the next chat that needs you, or the next unread one |
| `:Chats search [text]` | Search every chat |
| `:Chats hooks` | See which status hooks are installed |
| `:Chats notify [on\|off]` | Switch notifications |

`require('agent-chats').statusline()` returns a segment such as `● 2  ◐ 3  ✓ 1` for your statusline.

## More

[`doc/agent-chats.txt`](doc/agent-chats.txt) (`:help agent-chats`) is the full manual: every key, command and option with its default, groups, the search, the status hooks and how status is worked out, the Lua API and events, adding another agent, and the limits. A complete small agent is in [`examples/pal.lua`](examples/pal.lua).

`:checkhealth agent-chats` reports which agents were found and where each one's status comes from.

## Development

```
make test    # every spec; needs only nvim
make lint    # stylua --check, and shellcheck on the hook script when installed
```

The tests build synthetic data in temporary folders and never read your real chats.

## License

MIT
