local Config = require("persistence.config")

local uv = vim.uv or vim.loop

local M = {}
M._active = false

local e = vim.fn.fnameescape

---@param opts? {branch?: boolean}
function M.current(opts)
  opts = opts or {}
  local name = vim.fn.getcwd():gsub("[\\/:]+", "%%")
  if Config.options.branch and opts.branch ~= false then
    local branch = M.branch()
    if branch and branch ~= "main" and branch ~= "master" then
      name = name .. "%%" .. branch:gsub("[\\/:]+", "%%")
    end
  end
  return Config.options.dir .. name .. ".vim"
end

function M.setup(opts)
  Config.setup(opts)
  M.start()
end

function M.fire(event)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "Persistence" .. event,
  })
end

-- Check if a session is active
function M.active()
  return M._active
end

function M.start()
  M._active = true

  -- Preserve the original session options
  local orig_ssop = vim.o.sessionoptions

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("persistence", { clear = true }),
    callback = function()
      M.fire("SavePre")

      if Config.options.need > 0 then
        local bufs = vim.tbl_filter(function(b)
          if vim.bo[b].buftype ~= "" or vim.tbl_contains({ "gitcommit", "gitrebase", "jj" }, vim.bo[b].filetype) then
            return false
          end
          return vim.api.nvim_buf_get_name(b) ~= ""
        end, vim.api.nvim_list_bufs())
        if #bufs < Config.options.need then
          return
        end
      end

      -- Close all netrw buffers to prevent saving them in the session.
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].filetype == "netrw" then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end

      -- Modify sessionoptions to exclude netrw
      vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,terminal"

      M.save()

      -- Restore default settings
      vim.o.sessionoptions = orig_ssop

      M.fire("SavePost")
    end,
  })
end

function M.stop()
  M._active = false
  pcall(vim.api.nvim_del_augroup_by_name, "persistence")
end

function M.save()
  vim.cmd("mks! " .. e(M.current()))
end

---@param opts? { last?: boolean }
function M.load(opts)
  opts = opts or {}
  ---@type string
  local file
  if opts.last then
    file = M.last()
  else
    file = M.current()
    if vim.fn.filereadable(file) == 0 then
      file = M.current({ branch = false })
    end
  end
  if file and vim.fn.filereadable(file) ~= 0 then
    -- Close all netrw buffers before loading the session.
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == "netrw" then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    -- Preserve the original session options
    local orig_ssop = vim.o.sessionoptions
    -- Modify sessionoptions to exclude netrw
    vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,terminal"

    M.fire("LoadPre")
    vim.cmd("silent! source " .. e(file))

    vim.o.sessionoptions = orig_ssop

    M.fire("LoadPost")

    -- After loading the session, close all netrw buffers again.
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == "netrw" then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end

      -- Check and close the directory buffer (possibly netrw but filetype is not set to netrw)
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname ~= "" and vim.fn.isdirectory(bufname) == 1 then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end
end

---@return string[]
function M.list()
  local sessions = vim.fn.glob(Config.options.dir .. "*.vim", true, true)
  table.sort(sessions, function(a, b)
    return uv.fs_stat(a).mtime.sec > uv.fs_stat(b).mtime.sec
  end)
  return sessions
end

function M.last()
  return M.list()[1]
end

function M.select()
  ---@type { session: string, dir: string, branch?: string }[]
  local items = {}
  local have = {} ---@type table<string, boolean>
  for _, session in ipairs(M.list()) do
    if uv.fs_stat(session) then
      local file = session:sub(#Config.options.dir + 1, -5)
      local dir, branch = unpack(vim.split(file, "%%", { plain = true }))
      dir = dir:gsub("%%", "/")
      if jit.os:find("Windows") then
        dir = dir:gsub("^(%w)/", "%1:/")
      end
      if not have[dir] then
        have[dir] = true
        items[#items + 1] = { session = session, dir = dir, branch = branch }
      end
    end
  end
  vim.ui.select(items, {
    prompt = "Select a session: ",
    format_item = function(item)
      return vim.fn.fnamemodify(item.dir, ":p:~")
    end,
  }, function(item)
    if item then
      vim.fn.chdir(item.dir)
      M.load()
    end
  end)
end

--- get current branch name
---@return string?
function M.branch()
  if uv.fs_stat(".git") then
    local ret = vim.fn.systemlist("git branch --show-current")[1]
    return vim.v.shell_error == 0 and ret or nil
  end
end

return M
