-- Timestamps: parsing what the agents write, and saying it briefly.

local M = {}

function M.now()
  return os.time()
end

--- Epoch seconds with their fraction. For marks that are compared with
--- times an agent wrote down to the millisecond.
---@return number
function M.precise()
  local sec, usec = vim.uv.gettimeofday()
  return sec + usec / 1e6
end

-- Days since 1970-01-01 for a proleptic Gregorian date.
local function days_from_civil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Epoch seconds for an ISO 8601 timestamp (`2026-11-20T08:11:23.123Z`,
--- with or without fraction, `Z` or a numeric offset). nil when unparseable.
---@param s string?
---@return number?
function M.parse_iso(s)
  if type(s) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, sec, rest =
    s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$')
  if not y then
    return nil
  end
  local t = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600
    + tonumber(mi) * 60
    + tonumber(sec)
  local frac = rest:match('^%.(%d+)')
  if frac then
    t = t + tonumber('0.' .. frac)
  end
  local sign, oh, om = rest:match('([%+%-])(%d%d):?(%d%d)$')
  if sign then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    t = t - (sign == '+' and off or -off)
  end
  return t
end

--- Epoch seconds from a value that may be seconds, milliseconds or ISO text.
---@return number?
function M.epoch(v)
  if type(v) == 'string' then
    return M.parse_iso(v) or M.epoch(tonumber(v))
  end
  if type(v) ~= 'number' then
    return nil
  end
  -- Anything past year ~5138 in seconds is really milliseconds.
  if v > 1e11 then
    return v / 1000
  end
  return v
end

--- How long ago, in at most four cells: `now`, `41s`, `2m`, `3h`, `5d`, `3w`, `8mo`, `2y`.
---@param ts number?
---@param now number?
function M.ago(ts, now)
  if not ts then
    return ''
  end
  local d = math.max(0, (now or os.time()) - ts)
  if d < 5 then
    return 'now'
  elseif d < 60 then
    return ('%ds'):format(d)
  elseif d < 3600 then
    return ('%dm'):format(math.floor(d / 60))
  elseif d < 86400 then
    return ('%dh'):format(math.floor(d / 3600))
  elseif d < 86400 * 14 then
    return ('%dd'):format(math.floor(d / 86400))
  elseif d < 86400 * 60 then
    return ('%dw'):format(math.floor(d / (86400 * 7)))
  elseif d < 86400 * 365 then
    return ('%dmo'):format(math.floor(d / (86400 * 30)))
  end
  return ('%dy'):format(math.floor(d / (86400 * 365)))
end

--- How long ago, as a phrase: `just now`, `41s ago`, `2m ago`.
---@param ts number?
---@param now number?
function M.since(ts, now)
  local ago = M.ago(ts, now)
  if ago == '' then
    return ''
  end
  return ago == 'now' and 'just now' or (ago .. ' ago')
end

--- A span of seconds: `41s`, `2m 05s`, `1h 12m`.
function M.span(secs)
  secs = math.max(0, math.floor(secs or 0))
  if secs < 60 then
    return ('%ds'):format(secs)
  elseif secs < 3600 then
    return ('%dm %02ds'):format(math.floor(secs / 60), secs % 60)
  end
  return ('%dh %02dm'):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end

--- Local wall-clock time: `14:02` today, `Nov 20 14:02` otherwise.
function M.stamp(ts, now)
  if not ts then
    return ''
  end
  ts = math.floor(ts)
  if os.date('%Y%m%d', ts) == os.date('%Y%m%d', now or os.time()) then
    return os.date('%H:%M', ts) --[[@as string]]
  end
  return os.date('%b %d %H:%M', ts) --[[@as string]]
end

return M
