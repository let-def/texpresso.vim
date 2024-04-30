local M = {}

-- Configuration

M.texpresso_path = 'texpresso'

-- Logging routines

-- Debug logging function, silent by default
-- Change this variable to redirect the debug log.
-- E.g. require('texpresso').logger = foo
M.logger = nil

-- Cache last arguments passed to TeXpresso
M.last_args = {}

-- Debug printing function
-- It uses vim.inspect to pretty-print and vim.schedule
-- to delay printing when vim is textlocked.
local function p(...)
  if M.logger then
    local args = { ... }
    if #args == 1 then
      args = args[1]
    end
    local text = vim.inspect(args)
    vim.schedule(function()
      M.logger(text)
    end)
  end
end

-- ID of the buffer storing TeXpresso log
-- TODO: current logic is clunky when the buffer is closed.
--       look how other plugins handle that.
local log_buffer_id = -1

-- Get the ID of the logging buffer, creating it if it does not exist.
local function log_buffer()
  if not vim.api.nvim_buf_is_valid(log_buffer_id) then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == 'texpresso-log' then
        log_buffer_id = buf
      end
    end
  end
  if not vim.api.nvim_buf_is_valid(log_buffer_id) then
    log_buffer_id = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(log_buffer_id, 'texpresso-log')
  end
  return log_buffer_id
end

-- Append an array of lines to a buffer
-- The first entry is appended to the last line, other entries introduce new
-- lines.
local function buffer_append(buf, lines)
  local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)
  lines[1] = last[1] .. lines[1]
  vim.api.nvim_buf_set_lines(buf, -2, -1, false, lines)
end

-- Get buffer lines as a single string,
-- suitable for serialization to TeXpresso.
local function buffer_get_lines(buf, first, last)
  if first == last then
    return ''
  else
    return table.concat(vim.api.nvim_buf_get_lines(buf, first, last, false), '\n') .. '\n'
  end
end

-- Format a color VIM color to a TeXpresso color.
-- VIM represents a color as a single integer, encoding it as 0xRRGGBB.
-- RR, GG, BB are 8-bit unsigned integers.
-- TeXpresso represents a color as triple (R, G, B).
-- R, G, B are floating points in the 0.0 .. 1.0 range.
local function format_color(c)
  local b = math.fmod(c, 256) / 255
  c = math.floor(c / 256)
  local g = math.fmod(c, 256) / 255
  c = math.floor(c / 256)
  local r = math.fmod(c, 256) / 255
  return { r, g, b }
end

-- Tell VIM to display file:line
local skip_synctex = false
local function synctex_backward(file, line)
  skip_synctex = true
  if not (pcall(function()
    vim.cmd('b +' .. line .. ' ' .. file)
  end)) then
    vim.cmd('e +' .. line .. ' ' .. file)
  end
end

-- Manage quickfix list

-- Allocate and reuse a quickfix id
local qfid = -1
local function getqfid()
  local id = vim.fn.getqflist({ id = qfid }).id
  if id > 0 then
    return id
  end
  vim.fn.setqflist({}, ' ', { title = 'TeXpresso' })
  qfid = vim.fn.getqflist({ id = 0 }).id
  return qfid
end

-- Set quickfix items
local function setqf(items)
  local idx
  idx = vim.fn.getqflist({ id = getqfid(), idx = 0 }).idx
  vim.fn.setqflist({}, 'r', { id = getqfid(), items = items, idx = idx })
end

-- Parse a Tectonic diagnostic line to quickfix format
local function format_fix(line)
  local typ, f, l, txt
  typ, f, l, txt = string.match(line, '([a-z]+): (.*):(%d*): (.*)')
  if typ then
    return { type = typ, filename = f, lnum = l, text = txt }
  else
    return { text = line }
  end
end

-- TeXpresso process internal state
local job = {
  queued = nil,
  process = nil,
  generation = {},
}

-- Log output from TeX
M.log = {}

-- Problems (warnings and errors) emitted by TeX
M.fix = {}
M.fixcursor = 0

local function shrink(tbl, count)
  for _ = count, #tbl - 1 do
    table.remove(tbl)
  end
end

local function expand(tbl, count, default)
  for i = #tbl + 1, count do
    table.insert(tbl, i, default)
  end
end

-- Internal functions to communicate with TeXpresso

-- Process a message received from TeXpresso
-- TODO: handle message, right now they are only logged
local function process_message(json)
  -- p(json)
  local msg = json[1]
  if msg == 'reset-sync' then
    job.generation = {}
  elseif msg == 'synctex' then
    vim.schedule(function()
      synctex_backward(json[2], json[3])
    end)
  elseif msg == 'truncate-lines' then
    local name = json[2]
    local count = json[3]
    if name == 'log' then
      shrink(M.log, count)
      expand(M.log, count, '')
    elseif name == 'out' then
      expand(M.fix, count, {})
      M.fixcursor = count
    end
  elseif msg == 'append-lines' then
    local name = json[2]
    if name == 'log' then
      for i = 3, #json do
        table.insert(M.log, json[i])
      end
    elseif name == 'out' then
      for i = 3, #json do
        local cursor = M.fixcursor + 1
        M.fixcursor = cursor
        M.fix[cursor] = format_fix(json[i])
      end
      vim.schedule(function()
        setqf(M.fix)
      end)
    end
  elseif msg == 'flush' then
    shrink(M.fix, M.fixcursor)
    vim.schedule(function()
      setqf(M.fix)
    end)
  end
end

-- Send a command to TeXpresso
function M.send(...)
  local text = vim.json.encode({ ... })
  if job.process then
    vim.fn.chansend(job.process, { text, '' })
  end
  -- p(text)
end

-- Reload buffer in TeXpresso
function M.reload(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  M.send('open', path, buffer_get_lines(buf, 0, -1))
end

-- Communicate changed lines
function M.change_lines(buf, index, count, last)
  -- p("on_lines " .. vim.inspect{buf, index, index + count, last})
  local path = vim.api.nvim_buf_get_name(buf)
  local lines = buffer_get_lines(buf, index, last)
  M.send('change-lines', path, index, count, lines)
end

-- Attach a hook to synchronize a buffer
function M.attach(...)
  local args = { ... }
  local buf = args[1] or 0
  local generation = job.generation
  M.reload(buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_detach = function(_detach, buf)
      M.send('close', vim.api.nvim_buf_get_name(buf))
    end,
    on_reload = function(_reload, buf)
      M.reload(buf)
      generation = job.generation
    end,
    on_lines = function(_lines, buf, _tick, first, oldlast, newlast, _bytes)
      if generation == job.generation then
        M.change_lines(buf, first, oldlast - first, newlast)
      else
        M.reload(buf)
        generation = job.generation
      end
    end,
  })
end

-- Public API

-- Use VIM theme in TeXpresso
function M.theme()
  local colors = vim.api.nvim_get_hl(0, { name = 'Normal' })
  if colors.bg and colors.fg then
    M.send('theme', format_color(colors.bg), format_color(colors.fg))
  end
end

-- Go to next page
function M.next_page()
  M.send('next-page')
end

-- Go to previous page
function M.previous_page()
  M.send('previous-page')
end

-- Go to the page under the cursor
function M.synctex_forward()
  local line, _col = unpack(vim.api.nvim_win_get_cursor(0))
  local file = vim.api.nvim_buf_get_name(0)
  M.send('synctex-forward', file, line)
end

local last_line = -1
local last_file = ''

function M.synctex_forward_hook()
  if skip_synctex then
    skip_synctex = false
    return
  end

  local line, _col = unpack(vim.api.nvim_win_get_cursor(0))
  local file = vim.api.nvim_buf_get_name(0)
  if last_line == line and last_file == file then
    return
  end
  last_line = line
  last_file = file
  M.send('synctex-forward', file, line)
end

-- Start a new TeXpresso viewer
function M.launch(args)
  if job.process then
    vim.fn.chanclose(job.process)
  end
  cmd = { M.texpresso_path, '-json', '-lines' }

  if #args == 0 then
    args = M.last_args
  else
    M.last_args = args
  end
  if #args == 0 then
    print('No root file has been specified, use e.g. :TeXpresso main.tex')
    return
  end

  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end
  job.queued = ''
  job.process = vim.fn.jobstart(cmd, {
    on_stdout = function(j, data, e)
      if job.queued then
        data[1] = job.queued .. data[1]
      end
      job.queued = table.remove(data)
      for _, line in ipairs(data) do
        if line ~= '' then
          local ok, val = pcall(function()
            process_message(vim.json.decode(line))
          end)
          if not ok then
            p('error while processing input', line, val)
          end
        end
      end
    end,
    on_stderr = function(j, d, e)
      local buf = log_buffer()
      buffer_append(buf, d)
      if vim.api.nvim_buf_line_count(buf) > 8000 then
        vim.api.nvim_buf_set_lines(buf, 0, -4000, false, {})
      end
    end,
    on_exit = function()
      job.process = nil
    end,
  })
  job.generation = {}
  M.theme()
end

-- Hooks

vim.api.nvim_create_autocmd('ColorScheme', {
  callback = M.theme,
})

vim.api.nvim_create_autocmd('CursorMoved', {
  pattern = { '*.tex' },
  callback = M.synctex_forward_hook,
})

-- VIM commands

vim.api.nvim_create_user_command('TeXpresso', function(opts)
  M.launch(opts.fargs)
end, { nargs = '*', complete = 'file' })

return M
