local M = {}

-- Logging routines

-- Debug logging function, silent by default
-- Change this variable to redirect the debug log.
-- E.g. require('texpresso').logger = foo
function M.logger(text)
end

-- Debug printing function
-- It uses vim.inspect to pretty-print and vim.schedule
-- to delay printing when vim is textlocked.
local function p(...)
  local args = {...}
  if next(args, next(args)) == nil then
    args = args[1]
  end
  local text = vim.inspect(args)
  vim.schedule(function() M.logger(text) end)
end

-- ID of the buffer storing TeXpresso log
-- TODO: current logic is clunky when the buffer is closed.
--       look how other plugins handle that.
local log_buffer_id = -1

-- Get the ID of the logging buffer, creating it if it does not exist.
local function log_buffer()
  if not vim.api.nvim_buf_is_valid(log_buffer_id) then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == "[texpresso-log]" then
        log_buffer_id = buf
      end
    end
  end
  if not vim.api.nvim_buf_is_valid(log_buffer_id) then
    log_buffer_id = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(log_buffer_id, "[texpresso-log]")
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
    return ""
  else
    return vim.fn.join(vim.api.nvim_buf_get_lines(buf, first, last, false), "\n") .. "\n"
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
  return {r, g, b}
end

-- Tell VIM to display file:line
local function synctex_backward(file, line)
  if not(pcall(function() vim.cmd("b +" .. line .. " " .. file) end)) then
    vim.cmd("e +" .. line .. " " .. file)
  end
end

-- TeXpresso process internal state
local job = {
  queued = nil,
  process = nil,
  generation = {},
}

-- Internal functions to communicate with TeXpresso 

-- Process a message received from TeXpresso
-- TODO: handle message, right now they are only logged
local function process_message(json)
  p(json)
  if json[1] == "reset-sync" then
    job.generation = {}
  elseif json[1] == "synctex" then
    vim.schedule(function() synctex_backward(json[2], json[3]) end)
  end
end

-- Send a command to TeXpresso
function M.send(...)
  local text = vim.json.encode({...})
  if job.process then
    vim.fn.chansend(job.process, {text, ""})
  end
  p(text)
end

-- Reload buffer in TeXpresso
function M.reload(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  M.send("open", path, buffer_get_lines(buf, 0, -1))
end

-- Communicate changed lines
function M.change_lines(buf, index, count, last)
  p("on_lines " .. vim.inspect{buf, index, index + count, last})
  local path = vim.api.nvim_buf_get_name(buf)
  local lines = buffer_get_lines(buf, index, last)
  M.send("change-lines", path, index, count, lines)
end

-- Attach a hook to synchronize a buffer
function M.attach(...)
  local let args = {...}
  local buf = args[1] or 0
  local generation = job.generation
  M.reload(buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_detach=function(_detach, buf)
      M.send("close", vim.api.nvim_buf_get_name(buf))
    end,
    on_reload=function(_reload, buf)
      M.reload(buf)
      generation = job.generation
    end,
    on_lines=function(_lines, buf, _tick, first, oldlast, newlast, _bytes)
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
  local colors = vim.api.nvim_get_hl_by_name("Normal", true)
  M.send(
    "theme",
    format_color(colors.background),
    format_color(colors.foreground)
  )
end

-- Go to next page
function M.next_page()
  M.send("next-page")
end

-- Go to previous page
function M.previous_page()
  M.send("previous-page")
end

-- Go to the page under the cursor
function M.synctex_forward()
  local l,c = unpack(vim.api.nvim_win_get_cursor(0))
  M.send("synctex-forward", vim.api.nvim_buf_get_name(0), l)
end 

-- Start a new TeXpresso viewer
function M.launch(args)
  if job.process then
    chanclose(job.process)
  end
  cmd = {"texpresso", "-json"}
  for _, arg in ipairs(args) do 
      table.insert(cmd, arg)
  end
  job.queued = ""
  job.process = vim.fn.jobstart(cmd, {
      on_stdout = function(j, data, e)
        if job.queued then
          data[1] = job.queued .. data[1]
        end
        job.queued = table.remove(data)
        for _, line in ipairs(data) do
          if line ~= "" then
            process_message(vim.json.decode(line))
          end
        end
      end,
      on_stderr = function(j, d, e)
        buffer_append(log_buffer(), d)
      end,
      on_exit = function()
        job.process = nil
      end,
  })
  job.generation = {}
  M.theme()
end

-- Hooks

vim.api.nvim_create_autocmd("ColorScheme", {
  callback = M.theme
})

vim.api.nvim_create_autocmd("CursorMoved", {
  pattern = {"*.tex"},
  callback = M.synctex_forward
})

-- VIM commands

vim.api.nvim_create_user_command('TeXpresso',
  function(opts)
    M.launch(opts.fargs)
  end,
  { nargs = "+",
    complete = "file",
  }
)

return M
