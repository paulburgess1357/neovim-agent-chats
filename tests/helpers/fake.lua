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
echo "argv: $*" >> "$log"
echo "cwd: $PWD" >> "$log"
sid=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--resume" ] || [ "$prev" = "--session-id" ]; then sid="$a"; fi
  prev="$a"
done
for a in "$@"; do
  if [ "$a" = "-p" ]; then echo "headless done" >> "$log"; exit 0; fi
done
if [ -n "$FAKE_AGENT_HOME" ] && [ -n "$sid" ]; then
  printf '{"pid":%d,"sessionId":"%s","cwd":"%s","status":"idle","kind":"interactive","name":"fake"}' \
    $$ "$sid" "$PWD" > "$FAKE_AGENT_HOME/sessions/$$.json"
  trap 'rm -f "$FAKE_AGENT_HOME/sessions/$$.json"' EXIT
fi
echo "fake agent ready"
# Text arrives as a bracketed paste, as it does in the real agents.
while IFS= read -r line; do
  case "$line" in *$'\e[200~'*) echo "paste: begin" >> "$log" ;; esac
  ended=""
  case "$line" in *$'\e[201~'*) ended=1 ;; esac
  line=${line//$'\e[200~'/}
  line=${line//$'\e[201~'/}
  echo "input: $line" >> "$log"
  [ -n "$ended" ] && echo "paste: end" >> "$log"
  case "$line" in *"/exit"*) exit 0 ;; esac
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
