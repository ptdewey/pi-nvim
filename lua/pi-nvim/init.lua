local M = {}

--- @class pi_nvim.Config
--- @field socket_path string|nil  Override socket path (default: auto-discover)
--- @field diff_flash pi_nvim.DiffFlashConfig
M.config = {
  socket_path = nil,
  diff_flash = {
    enabled = true,
    duration_ms = 3000,
  },
}

local function resolve_workspace_root(start)
  local path = start
  if not path or path == "" then
    return nil
  end

  local stat = vim.uv.fs_stat(path)
  if stat and stat.type ~= "directory" then
    path = vim.fs.dirname(path)
  end
  local original = path

  while path and path ~= "" do
    if vim.uv.fs_stat(path .. "/.git") or vim.uv.fs_stat(path .. "/.jj") then
      return path
    end

    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
      break
    end
    path = parent
  end

  return original
end

--- @param opts pi_nvim.Config|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  require("pi-nvim.diff_flash").setup(M.config.diff_flash)

  -- Auto-reload buffers when files are changed externally (e.g. by pi agent).
  -- Only polls when a pi session is reachable. Respects existing autoread setting.
  if not vim.o.autoread then
    vim.o.autoread = true
  end
  local reload_timer = vim.uv.new_timer()
  reload_timer:start(0, 1000, vim.schedule_wrap(function()
    if M.get_socket_path() then
      pcall(vim.cmd, "silent! checktime")
    end
  end))

  -- Commands
  vim.api.nvim_create_user_command("PiSendFile", function()
    M.send_file()
  end, { desc = "Send current file to pi with a prompt" })

  vim.api.nvim_create_user_command("PiSendBuffer", function()
    M.send_buffer()
  end, { desc = "Send entire buffer to pi with a prompt" })

  vim.api.nvim_create_user_command("Pi", function(args)
    local ui = require("pi-nvim.ui")
    local selection = nil
    if args.range == 2 then
      selection = ui.capture_selection()
    end
    ui.open({ selection = selection })
  end, { range = true, desc = "Open pi send dialog" })

  -- Default keymap: <leader>p in normal and visual mode
  vim.keymap.set("n", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send to pi" })
  vim.keymap.set("v", "<leader>p", ":Pi<CR>", { silent = true, desc = "Send selection to pi" })

  vim.api.nvim_create_user_command("PiPing", function()
    M.ping()
  end, { desc = "Ping the pi session" })

  vim.api.nvim_create_user_command("PiSessions", function()
    M.list_sessions()
  end, { desc = "List running pi sessions" })

  vim.api.nvim_create_user_command("PiOpen", function()
    M.open_terminal()
  end, { desc = "Open pi in a split terminal" })
end

--- Resolve the socket path to use.
--- Priority: config override > matching workspace root
--- @return string|nil
function M.get_socket_path()
  if M.config.socket_path then
    return M.config.socket_path
  end

  local sockets_dir = "/tmp/pi-nvim-sockets"
  local cwd = vim.uv.cwd()
  local cwd_root = resolve_workspace_root(cwd)

  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if not ok or not files then
    return nil
  end

  local best_sock = nil
  local best_mtime = 0
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock = info_path:sub(1, -6)
        local stat = vim.uv.fs_stat(sock)
        local session_root = info.workspace_root or info.workspaceRoot or resolve_workspace_root(info.cwd)
        if stat and session_root == cwd_root then
          if stat.mtime.sec > best_mtime then
            best_mtime = stat.mtime.sec
            best_sock = sock
          end
        end
      end
    end
  end

  return best_sock
end

--- Send a raw JSON message to the pi socket and call cb with the parsed response.
--- @param msg table
--- @param cb fun(err: string|nil, response: table|nil)|nil
function M.send_raw(msg, cb)
  local sock_path = M.get_socket_path()
  if not sock_path then
    local err = "No pi session found for this workspace. Is pi running here with pi-nvim enabled?"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  local client = vim.uv.new_pipe(false)
  if not client then
    local err = "Failed to create pipe"
    vim.notify(err, vim.log.levels.ERROR)
    if cb then cb(err, nil) end
    return
  end

  client:connect(sock_path, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Failed to connect to pi: " .. err, vim.log.levels.ERROR)
        if cb then cb(err, nil) end
      end)
      return
    end

    local payload = vim.json.encode(msg) .. "\n"
    client:write(payload)

    local buf = ""
    client:read_start(function(read_err, data)
      if read_err then
        client:close()
        vim.schedule(function()
          if cb then cb(read_err, nil) end
        end)
        return
      end
      if data then
        buf = buf .. data
        local nl = buf:find("\n")
        if nl then
          local line = buf:sub(1, nl - 1)
          client:read_stop()
          client:close()
          vim.schedule(function()
            local ok, resp = pcall(vim.json.decode, line)
            if ok and resp then
              if cb then cb(nil, resp) end
            else
              if cb then cb("Invalid response from pi", nil) end
            end
          end)
        end
      else
        -- EOF
        client:close()
      end
    end)
  end)
end

--- Send a prompt string to pi.
--- @param message string|nil  If nil, prompts the user for input
function M.prompt(message)
  if message then
    M.send_raw({ type = "prompt", message = message }, function(err, resp)
      if err then return end
      if resp and resp.ok then
        vim.notify("Sent to pi", vim.log.levels.INFO)
      else
        vim.notify("pi error: " .. (resp and resp.error or "unknown"), vim.log.levels.ERROR)
      end
    end)
  else
    vim.ui.input({ prompt = "Pi prompt: " }, function(input)
      if input and input ~= "" then
        M.prompt(input)
      end
    end)
  end
end

--- Send the current file path with optional prompt.
function M.send_file()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("No file open", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi prompt (file: " .. vim.fn.expand("%:.") .. "): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file: %s", file)
    else
      message = string.format("File: %s\n\n%s", file, input)
    end
    M.prompt(message)
  end)
end

--- Send the entire buffer contents with a prompt.
function M.send_buffer()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local content = table.concat(lines, "\n")
  local file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  vim.ui.input({ prompt = "Pi prompt (buffer): " }, function(input)
    if not input then return end

    local message
    if input == "" then
      message = string.format("Look at this file %s:\n\n```%s\n%s\n```", file, ft, content)
    else
      message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", input, file, ft, content)
    end
    M.prompt(message)
  end)
end

--- Open pi in a vertical split terminal rooted at the current workspace.
function M.open_terminal()
  if vim.fn.executable("pi") ~= 1 then
    vim.notify("pi executable not found in $PATH", vim.log.levels.ERROR)
    return
  end

  local file = vim.fn.expand("%:p")
  local cwd = resolve_workspace_root(file ~= "" and file or vim.uv.cwd()) or vim.uv.cwd()
  local width = math.max(40, math.floor(vim.o.columns * 0.4))
  local previous_win = vim.api.nvim_get_current_win()

  vim.cmd(string.format("botright vertical %dnew", width))

  local term_win = vim.api.nvim_get_current_win()
  local term_buf = vim.api.nvim_get_current_buf()

  vim.wo[term_win].number = false
  vim.wo[term_win].relativenumber = false
  vim.wo[term_win].signcolumn = "no"
  vim.wo[term_win].foldcolumn = "0"
  pcall(function() vim.wo[term_win].statuscolumn = "" end)

  local function follow_output(force)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(term_win) or not vim.api.nvim_buf_is_valid(term_buf) then
        return
      end

      local last_line = vim.api.nvim_buf_line_count(term_buf)
      local wininfo = vim.fn.getwininfo(term_win)[1]
      local near_bottom = wininfo and wininfo.botline >= (last_line - 5)

      if force or near_bottom then
        pcall(vim.api.nvim_win_set_cursor, term_win, { last_line, 0 })
      end
    end)
  end

  vim.fn.termopen({ "pi" }, {
    cwd = cwd,
    on_stdout = function() follow_output(false) end,
    on_exit = function() follow_output(false) end,
  })

  follow_output(true)

  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
end

--- Ping the pi session to check connectivity.
function M.ping()
  M.send_raw({ type = "ping" }, function(err, resp)
    if err then
      vim.notify("Pi not reachable: " .. err, vim.log.levels.ERROR)
    elseif resp and resp.type == "pong" then
      vim.notify("Pi is alive! ✓", vim.log.levels.INFO)
    else
      vim.notify("Unexpected response from pi", vim.log.levels.WARN)
    end
  end)
end

--- List running pi sessions for the current workspace.
function M.list_sessions()
  local sockets_dir = "/tmp/pi-nvim-sockets"
  local cwd = vim.uv.cwd()
  local cwd_root = resolve_workspace_root(cwd)
  local ok, files = pcall(vim.fn.glob, sockets_dir .. "/*.info", false, true)
  if not ok or not files or #files == 0 then
    vim.notify("No pi sessions found", vim.log.levels.INFO)
    return
  end

  local sessions = {}
  for _, info_path in ipairs(files) do
    local content_ok, content = pcall(vim.fn.readfile, info_path)
    if content_ok and content and content[1] then
      local parsed_ok, info = pcall(vim.json.decode, content[1])
      if parsed_ok and info then
        local sock = info_path:sub(1, -6)
        local alive = vim.uv.fs_stat(sock) ~= nil
        local session_root = info.workspace_root or info.workspaceRoot or resolve_workspace_root(info.cwd)
        if alive and session_root == cwd_root then
          local started = ""
          if info.startedAt then
            local ok2, ts = pcall(function()
              local y, mo, d, h, mi, s = info.startedAt:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
              if h and mi then
                return string.format("%s:%s", h, mi)
              end
              return info.startedAt
            end)
            if ok2 then started = ts end
          end
          table.insert(sessions, {
            cwd = info.cwd or "?",
            pid = info.pid or "?",
            started = started,
            socket = sock,
          })
        end
      end
    end
  end

  if #sessions == 0 then
    vim.notify("No pi sessions found for this workspace", vim.log.levels.INFO)
    return
  end

  local items = {}
  local current = M.get_socket_path()
  for _, s in ipairs(sessions) do
    local marker = (current == s.socket) and "●" or "○"
    local time_str = s.started ~= "" and string.format(" started %s", s.started) or ""
    table.insert(items, string.format("%s %s [pid %s%s]", marker, s.cwd, s.pid, time_str))
  end

  vim.ui.select(items, { prompt = "Pi sessions (workspace):" }, function(choice, idx)
    if not choice or not idx then return end
    local session = sessions[idx]
    if session then
      M.config.socket_path = session.socket
      vim.notify(string.format("Connected to pi at %s [pid %s]", session.cwd, session.pid), vim.log.levels.INFO)
    end
  end)
end

return M
