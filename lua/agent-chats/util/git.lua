-- Git facts about a folder: which repository and worktree it belongs to,
-- its branch, and whether it has uncommitted changes. Gathered in the
-- background and cached, since a board redraw must never wait on git.

local async = require('agent-chats.util.async')
local fs = require('agent-chats.util.fs')

local M = {}

---@class agent_chats.GitInfo
---@field cwd string
---@field missing boolean?      The folder no longer exists.
---@field repo string?          Root of the main checkout (shared by all its worktrees).
---@field root string?          Root of this worktree.
---@field worktree boolean?     `root` is a linked worktree, not the main checkout.
---@field branch string?
---@field detached boolean?
---@field dirty integer?        Changed or untracked paths.
---@field ahead integer?
---@field behind integer?
---@field at number

M.ttl = 15

---@type table<string, agent_chats.GitInfo>
local cache = {}
---@type table<string, (fun(info: agent_chats.GitInfo))[]>
local pending = {}

local function git(cwd, args)
  local cmd = { 'git', '-C', cwd }
  vim.list_extend(cmd, args)
  return async.system(cmd, { timeout = 8000 })
end

--- Gather the facts for `cwd`. Runs two git processes.
---@return agent_chats.GitInfo
function M.read(cwd)
  local info = { cwd = cwd, at = os.time() }
  if not fs.is_dir(cwd) then
    info.missing = true
    return info
  end
  local rp =
    git(cwd, { 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir' })
  if rp.code ~= 0 then
    return info
  end
  local lines = vim.split(vim.trim(rp.stdout or ''), '\n', { plain = true })
  info.root = lines[1]
  local common = lines[2]
  if common then
    -- `<repo>/.git` for a normal checkout; a bare repository is its own
    -- root; a submodule keeps its git folder inside the project it is part
    -- of (`<super>/.git/modules/<name>`), and its checkout is its root.
    if fs.basename(common) == '.git' then
      info.repo = vim.fs.dirname(common)
    elseif common:find('/.git/modules/', 1, true) and info.root then
      info.repo = info.root
    else
      info.repo = common
    end
    info.worktree = info.root ~= nil and info.repo ~= info.root
  end
  local st = git(cwd, { 'status', '--porcelain=v2', '--branch' })
  if st.code == 0 then
    local dirty = 0
    for line in (st.stdout or ''):gmatch('[^\n]+') do
      local head = line:match('^# branch%.head (.+)$')
      if head then
        info.detached = head == '(detached)'
        info.branch = info.detached and nil or head
      else
        local a, b = line:match('^# branch%.ab %+(%d+) %-(%d+)$')
        if a then
          info.ahead, info.behind = tonumber(a), tonumber(b)
        elseif line:sub(1, 1) ~= '#' then
          dirty = dirty + 1
        end
      end
    end
    info.dirty = dirty
  end
  return info
end

--- Cached facts for `cwd`, if any (possibly stale).
---@return agent_chats.GitInfo?
function M.cached(cwd)
  return cache[cwd]
end

--- Facts for `cwd`, refreshed in the background when older than `M.ttl`.
--- `cb` runs once fresh facts are in; the return value is whatever is cached now.
---@param cwd string
---@param cb fun(info: agent_chats.GitInfo)?
---@return agent_chats.GitInfo?
function M.info(cwd, cb)
  local hit = cache[cwd]
  if hit and os.time() - hit.at < M.ttl then
    if cb then
      cb(hit)
    end
    return hit
  end
  if pending[cwd] then
    if cb then
      table.insert(pending[cwd], cb)
    end
    return hit
  end
  pending[cwd] = { cb }
  async.run(function()
    return M.read(cwd)
  end, function(ok, info)
    local waiters = pending[cwd] or {}
    pending[cwd] = nil
    if not ok or type(info) ~= 'table' then
      info = { cwd = cwd, at = os.time() }
    end
    cache[cwd] = info
    for _, fn in ipairs(waiters) do
      fn(info)
    end
  end)
  return hit
end

--- Create a worktree at `path` on a new branch `branch` (from `base`, default HEAD).
---@return boolean ok, string? err
function M.add_worktree(cwd, path, branch, base)
  local args = { 'worktree', 'add', '-b', branch, path }
  if base and base ~= '' then
    args[#args + 1] = base
  end
  local res = git(cwd, args)
  if res.code ~= 0 then
    return false, vim.trim(res.stderr or res.stdout or 'git worktree add failed')
  end
  cache[path] = nil
  return true
end

--- Uncommitted changes in `cwd` as diff text, untracked files listed first.
---@return string? text, string? err
function M.diff(cwd)
  if not fs.is_dir(cwd) then
    return nil, 'folder no longer exists'
  end
  local st = git(cwd, { 'status', '--short' })
  if st.code ~= 0 then
    return nil, 'not a git repository'
  end
  local diff = git(cwd, { 'diff', 'HEAD' })
  if diff.code ~= 0 then
    -- No commits yet: there is no HEAD to diff against.
    diff = git(cwd, { 'diff' })
  end
  return vim.trim(st.stdout or '') .. '\n\n' .. (diff.stdout or '')
end

return M
