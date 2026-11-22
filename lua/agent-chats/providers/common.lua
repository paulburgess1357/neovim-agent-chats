-- Helpers shared by the providers.

local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local text = require('agent-chats.util.text')

local M = {}

--- The agent's command plus extra arguments, as an argument list.
---@param name string Provider name.
---@param ... string|string[]|nil
---@return string[]
--- A prompt as an argument on an agent's command line. Two things would
--- make the program read it as something else: a leading dash (an option),
--- and a single word that names one of its commands (`codex logout`,
--- `claude update`, `qwen mcp`: seen in each program's own help). A space
--- in front changes nothing of what the agent is asked, and makes the
--- argument plain text to the program.
---@param prompt string
---@return string
function M.arg(prompt)
  if prompt:sub(1, 1) == '-' or not prompt:find('%s') then
    return ' ' .. prompt
  end
  return prompt
end

function M.cmd(name, ...)
  local out = vim.deepcopy(config.provider(name).cmd)
  for i = 1, select('#', ...) do
    local arg = select(i, ...)
    if type(arg) == 'table' then
      vim.list_extend(out, arg)
    elseif arg ~= nil then
      out[#out + 1] = arg
    end
  end
  return out
end

--- Data directory of a provider: the option, then an environment variable,
--- then the default under the home directory.
function M.home(name, env, default)
  local opt = config.provider(name).home
  if type(opt) == 'string' and opt ~= '' then
    return (vim.fs.normalize(opt))
  end
  local from_env = env and vim.env[env]
  if from_env and from_env ~= '' then
    return (vim.fs.normalize(from_env))
  end
  return fs.home .. '/' .. default
end

-- Bytes kept of a prompt or reply for the board and the preview.
M.PROMPT_BYTES = 2000
M.REPLY_BYTES = 6000

--- Tail records of a JSONL transcript, widening the read until `enough`
--- says the records answer the question (or the whole file was read).
---@param path string
---@param size integer
---@param opts { skip: (fun(line: string): boolean)?, enough: fun(records: table[]): boolean, steps: integer[]? }
---@return table[] records, boolean whole
function M.tail(path, size, opts)
  local records, whole = {}, false
  for _, bytes in ipairs(opts.steps or { 131072, 1048576, 8388608 }) do
    records, whole = fs.jsonl_tail(path, bytes, { skip = opts.skip, size = size })
    if whole or opts.enough(records) then
      break
    end
  end
  return records, whole
end

--- Head records of a JSONL transcript, widening the same way.
function M.head(path, size, opts)
  local records, whole = {}, false
  for _, bytes in ipairs(opts.steps or { 131072, 1048576 }) do
    records, whole = fs.jsonl_head(path, bytes, { skip = opts.skip, size = size })
    if whole or opts.enough(records) then
      break
    end
  end
  return records, whole
end

local function first_string(input, keys)
  for _, k in ipairs(keys) do
    local v = input[k]
    if type(v) == 'string' and v ~= '' then
      return v
    end
  end
end

local function command_text(v)
  if type(v) == 'string' then
    return v
  end
  if type(v) == 'table' then
    -- `{ "bash", "-lc", "<script>" }`: the script is what matters.
    if #v >= 3 and (v[2] == '-lc' or v[2] == '-c') then
      return tostring(v[3])
    end
    local parts = {}
    for _, a in ipairs(v) do
      parts[#parts + 1] = tostring(a)
    end
    return table.concat(parts, ' ')
  end
end

local function diff_lines(old, new)
  local out = {}
  for _, l in ipairs(text.lines(old)) do
    out[#out + 1] = '-' .. l
  end
  for _, l in ipairs(text.lines(new)) do
    out[#out + 1] = '+' .. l
  end
  return table.concat(out, '\n')
end

---@class agent_chats.ToolView
---@field summary string   One line: what the call does.
---@field input string?    Body worth showing in full.
---@field lang string?     Fence language for `input`.

--- Describe a tool call from its name and input. The agents name their
--- tools differently but use the same handful of argument names, so this
--- goes by the arguments rather than by a per-agent table.
---@param name string
---@param input any
---@return agent_chats.ToolView
function M.tool(name, input)
  name = name or 'tool'
  if type(input) == 'string' then
    -- Some agents pass arguments as JSON text.
    local decoded = input:sub(1, 1) == '{' and fs.decode(input) or nil
    if type(decoded) == 'table' then
      input = decoded
    else
      return { summary = text.oneline(input, 120), input = input }
    end
  end
  if type(input) ~= 'table' then
    return { summary = '' }
  end

  local cmd = command_text(input.command or input.cmd)
  if cmd then
    return { summary = text.oneline(cmd, 120), input = cmd, lang = 'sh' }
  end

  local file =
    first_string(input, { 'file_path', 'filePath', 'path', 'notebook_path', 'absolute_path' })
  local old, new = input.old_string or input.oldString, input.new_string or input.newString
  if file and (type(old) == 'string' or type(new) == 'string') then
    return { summary = fs.tilde(file), input = diff_lines(old or '', new or ''), lang = 'diff' }
  end
  if file and type(input.content) == 'string' then
    return { summary = fs.tilde(file), input = input.content }
  end
  if type(input.patch) == 'string' or type(input.diff) == 'string' then
    return {
      summary = file and fs.tilde(file) or 'patch',
      input = input.patch or input.diff,
      lang = 'diff',
    }
  end
  if file then
    local extra = first_string(input, { 'pattern', 'query' })
    return { summary = fs.tilde(file) .. (extra and (' · ' .. text.oneline(extra, 60)) or '') }
  end

  local one =
    first_string(input, { 'pattern', 'query', 'url', 'description', 'subject', 'skill', 'name' })
  local body = first_string(input, { 'prompt', 'message', 'text' })
  if one or body then
    return { summary = text.oneline(one or body, 120), input = body }
  end

  if type(input.todos) == 'table' then
    local lines = {}
    for _, todo in ipairs(input.todos) do
      if type(todo) == 'table' then
        local mark = todo.status == 'completed' and 'x'
          or (todo.status == 'in_progress' and '~' or ' ')
        lines[#lines + 1] = ('- [%s] %s'):format(mark, tostring(todo.content or todo.title or ''))
      end
    end
    return {
      summary = ('%d items'):format(#lines),
      input = table.concat(lines, '\n'),
      lang = 'markdown',
    }
  end

  if next(input) == nil then
    return { summary = '' }
  end
  local dump = vim.inspect(input)
  return { summary = text.oneline(dump, 100), input = dump, lang = 'lua' }
end

--- `Name: summary` for the board's "now doing" line.
function M.activity(name, view)
  local s = view and view.summary or ''
  return s ~= '' and (name .. ': ' .. s) or name
end

--- Text of a tool result that may be a string, a list of content blocks, or
--- a table with an `output` / `text` field.
function M.result_text(v)
  if type(v) == 'string' then
    return v
  end
  if type(v) ~= 'table' then
    return v ~= nil and tostring(v) or ''
  end
  if vim.islist(v) then
    local parts = {}
    for _, b in ipairs(v) do
      if type(b) == 'string' then
        parts[#parts + 1] = b
      elseif type(b) == 'table' then
        if type(b.text) == 'string' then
          parts[#parts + 1] = b.text
        elseif b.type == 'image' or b.type == 'input_image' then
          parts[#parts + 1] = '[image]'
        end
      end
    end
    return table.concat(parts, '\n')
  end
  local direct = v.output or v.text or v.content or v.stdout or v.result
  if type(direct) == 'string' then
    return direct
  elseif type(direct) == 'table' then
    return M.result_text(direct)
  end
  return vim.inspect(v)
end

--- Carry over what only the start of a transcript can tell, so a re-parse
--- of the same file reads its tail alone.
---@param prev agent_chats.Chat?
---@param entry agent_chats.Entry
---@return { created: number?, cwd: string?, first_prompt: string?, origin: string?, parent_id: string? }?
function M.carried(prev, entry)
  if prev and prev.path == entry.path and prev.cwd and prev.first_prompt then
    return {
      created = prev.created,
      cwd = prev.cwd,
      first_prompt = prev.first_prompt,
      origin = prev.origin,
      parent_id = prev.parent_id,
    }
  end
end

return M
