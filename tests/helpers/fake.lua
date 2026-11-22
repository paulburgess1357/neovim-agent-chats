-- A stand-in agent for tests of everything that starts or types into one.
--
-- `install(home)` writes an executable named `claude` into a temporary bin
-- folder and points the Claude provider at it. When started it records its
-- arguments, registers itself in the fake Claude home the way the real one
-- does (so the index sees a running session), and appends every line typed
-- into it to a log the test can read.

local T = require('helpers.harness')

local M = {}

local SCRIPT = [[#!/usr/bin/env bash
log="$FAKE_AGENT_LOG"
# An input box, as the real agents have one: the terminal does not echo,
# the program shows what it is given itself, and a paste comes in brackets
# that are not shown. Before anything is logged, so that a test that has
# seen "argv:" knows the agent is past its start. (With the terminal's own
# echo the brackets would show as "^[[200~": that is how an agent that is
# still starting looks, and what is pasted then must not be taken for
# accepted. FAKE_AGENT_COOKED stages that.)
if [ -z "$FAKE_AGENT_COOKED" ] && [ -t 0 ]; then
  stty -echo -icanon min 1 time 0 2>/dev/null
fi
echo "argv: $*" >> "$log"
echo "cwd: $PWD" >> "$log"
sid=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--resume" ] || [ "$prev" = "--session-id" ]; then sid="$a"; fi
  prev="$a"
done
for a in "$@"; do
  if [ "$a" = "-p" ]; then echo "headless done" >> "$log"; exit 0; fi
  # A fork is a session of its own, as with the real agent: it does not
  # take the place of the chat it was made from.
  if [ "$a" = "--fork-session" ]; then
    sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "fork-$$")
  fi
done
if [ -n "$FAKE_AGENT_HOME" ] && [ -n "$sid" ]; then
  printf '{"pid":%d,"sessionId":"%s","cwd":"%s","status":"idle","kind":"interactive","name":"%s"}' \
    $$ "$sid" "$PWD" "${FAKE_AGENT_NAME:-fake}" > "$FAKE_AGENT_HOME/sessions/$$.json"
  trap 'rm -f "$FAKE_AGENT_HOME/sessions/$$.json"' EXIT
fi
echo "fake agent ready"
seq=""; line=""; inpaste=""; ended=""
while IFS= read -r -N1 ch; do
  if [ -n "$seq" ] || [ "$ch" = $'\e' ]; then
    seq+="$ch"
    case "$seq" in
      $'\e[200~') echo "paste: begin" >> "$log"; inpaste=1; seq="" ;;
      $'\e[201~') inpaste=""; ended=1; seq="" ;;
      *'~') seq="" ;;
    esac
    continue
  fi
  if [ "$ch" = $'\n' ] || [ "$ch" = $'\r' ]; then
    echo "input: $line" >> "$log"
    [ -z "$FAKE_AGENT_COOKED" ] && printf '\r\n'
    if [ -z "$inpaste" ]; then
      [ -n "$ended" ] && echo "paste: end" >> "$log"
      ended=""
      case "$line" in *"/exit"*) exit 0 ;; esac
    fi
    line=""
    continue
  fi
  line+="$ch"
  [ -z "$FAKE_AGENT_COOKED" ] && printf '%s' "$ch"
done
]]

---@param home tests.ClaudeHome
---@return { log: string, read: fun(): string, bin: string }
function M.install(home)
  local bin = home.root .. '/bin'
  local exe = T.write(bin .. '/claude', SCRIPT)
  vim.uv.fs_chmod(exe, 493)
  local log = home.root .. '/agent.log'
  T.write(log, '')
  vim.env.FAKE_AGENT_LOG = log
  vim.env.FAKE_AGENT_HOME = home.dir
  require('agent-chats.config').get().providers.claude.cmd = { exe }
  return {
    log = log,
    bin = exe,
    read = function()
      local f = io.open(log, 'r')
      if not f then
        return ''
      end
      local s = f:read('*a')
      f:close()
      return s
    end,
  }
end

--- The same stand-in under another agent's name (`opencode`, `codex`):
--- written into `root`, and that agent's command pointed at it. It
--- registers nothing: those agents keep no list of running sessions.
---@return { log: string, read: fun(): string, bin: string }
function M.install_as(root, name)
  local exe = T.write(root .. '/bin/' .. name, SCRIPT)
  vim.uv.fs_chmod(exe, 493)
  local log = root .. '/agent.log'
  T.write(log, '')
  vim.env.FAKE_AGENT_LOG = log
  vim.env.FAKE_AGENT_HOME = nil
  require('agent-chats.config').get().providers[name].cmd = { exe }
  return {
    log = log,
    bin = exe,
    read = function()
      local f = io.open(log, 'r')
      if not f then
        return ''
      end
      local s = f:read('*a')
      f:close()
      return s
    end,
  }
end

--- Stop every terminal job started during a test.
---
--- Each job is waited for before its buffer is deleted. Deleting the
--- buffer of a terminal that still has input or output on its way makes
--- Neovim (0.12) spin for ever in the next `vim.wait`: the terminal's
--- deferred clean-up puts itself back on the queue that `vim.wait` is
--- emptying until that traffic is done, and nothing lets it get done.
function M.cleanup()
  local jobs, bufs = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == 'terminal' then
      local chan = vim.bo[buf].channel
      if pcall(vim.fn.jobstop, chan) then
        jobs[#jobs + 1] = chan
      end
      bufs[#bufs + 1] = buf
    end
  end
  if #jobs > 0 then
    pcall(vim.fn.jobwait, jobs, 3000)
  end
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
