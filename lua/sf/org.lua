local U = require("sf.util")
local B = require("sf.sub.cmd_builder")

local H = {}
local Org = {}

function Org.fetch_org_list()
  H.fetch_org_list()
end

function Org.set_target_org()
  H.set_target_org()
end

function Org.set_global_target_org()
  H.set_global_target_org()
end

function Org.diff_in_target_org()
  H.diff_in_target_org()
end

function Org.diff_in_org()
  H.diff_in_org()
end

function Org.open()
  -- local cmd = 'sf org open -o ' .. U.get()
  local cmd = B:new():cmd("org"):act("open"):build()
  local err_msg = "Command failed: " .. cmd
  U.job_call(cmd, nil, err_msg)
end

function Org.open_current_file()
  -- local cmd = vim.fn.expandcmd('sf org open --source-file "%:p" -o ') .. U.get()
  local cmd = B:new():cmd("org"):act("open"):addParams("-f", "%:p"):build()
  local err_msg = "Command failed: " .. cmd
  U.job_call(cmd, nil, err_msg)
end

function Org.pull_log()
  H.pull_log()
end

function Org.auth_org()
  H.auth_org()
end

-- helpers;

H.pull_log = function()
  if U.is_empty_str(U.target_org) then
    return U.show_err("Target_org empty!")
  end
  if not U.is_installed("fzf-lua") then
    return U.show_err("fzf-lua is not installed. Need it to show the list.")
  end

  local log_id

  local on_list = function(obj)
    local ok, log_table = pcall(vim.json.decode, obj.stdout, {})
    if not ok then
      return U.show_err("Failed to parse log JSON!")
    end

    local logs = {}
    local log_names = {}

    if #log_table["result"] == 0 then
      return U.show_warn("No logs found in org")
    end

    for _, v in ipairs(log_table["result"]) do
      local name = string.format(
        "%s | %s | %s bytes | %s",
        v["LogUser"]["Name"],
        string.gsub(v["StartTime"], "T", " "),
        v["LogLength"],
        v["Status"]
      )
      table.insert(log_names, name)
      v["User"] = v["LogUser"]["Name"]
      v["attributes"] = nil
      v["LogUser"] = nil
      logs[name] = v
    end

    require("fzf-lua").fzf_exec(log_names, {
      winopts = {
        preview = {
          layout = "vertical",
          hidden = false,
          vertical = "down:50%",
        },
      },
      preview = function(items)
        local contents = {}
        local prepend_char = ""
        vim.tbl_map(function(x)
          table.insert(contents, prepend_char .. U.table_to_string_lines(logs[x]))
          prepend_char = "\n"
        end, items)
        return contents
      end,
      actions = {
        ["default"] = function(selected)
          log_id = logs[selected[1]]["Id"]
          U.show("Downloading log...")
          local get_cmd = B:new()
            :cmd("apex")
            :act("get")
            :subact("log")
            :addParams("-i", log_id)
            :addParams("-d", U.get_plugin_folder_path() .. "logs/")
            :buildAsTable()
          U.silent_system_call(get_cmd, nil, "Failed to get logs from org", function()
            U.try_open_file(U.get_plugin_folder_path() .. "logs/" .. log_id .. ".log")
          end)
        end,
      },
    })
  end

  local cmd_tbl = B:new():cmd("apex"):act("list"):subact("log"):addParams("--json"):buildAsTable()
  U.system_call(cmd_tbl, nil, "Failed to get logs from org", on_list, "Querying logs...")
end

H.orgs = {}

H.get_project_login_url = function()
  local sf_root = U.get_sf_root()
  if not sf_root then
    return nil
  end

  local project_file = sf_root .. "/sfdx-project.json"
  if vim.fn.filereadable(project_file) == 0 then
    return nil
  end

  local content = vim.fn.readfile(project_file)
  local json_str = table.concat(content, "\n")
  local ok, project_config = pcall(vim.json.decode, json_str)

  if ok and project_config and project_config.sfdcLoginUrl then
    return project_config.sfdcLoginUrl
  end

  return nil
end

H.authorize_an_org = function(name, instance_url)
  local cmd_builder =
    B:new():cmd("org"):act("login web"):addParams({ ["--alias"] = name, ["--set-default"] = "" }):localOnly()

  if instance_url then
    cmd_builder:addParams("-r", instance_url)
  end

  local cmd = cmd_builder:build()
  local msg = "Opening browser to authenticate org: " .. name
  local err_msg = "Authentication failed for: " .. name
  U.job_call(cmd, msg, err_msg)
end

H.continue_auth_with_alias = function(instance_url)
  vim.ui.input({ prompt = "Enter Org Alias: " }, function(alias)
    if alias == nil or alias == "" then
      return U.show_warn("Alias is required")
    end
    H.authorize_an_org(alias, instance_url)
  end)
end

H.auth_org = function()
  local project_login_url = H.get_project_login_url()
  local options = {}

  -- Add project default as first option if it exists
  if project_login_url then
    table.insert(options, "Project Default (" .. project_login_url .. ")")
  end

  table.insert(options, "Production (login.salesforce.com)")
  table.insert(options, "Sandbox (test.salesforce.com)")
  table.insert(options, "Custom URL")

  vim.ui.select(options, {
    prompt = "Select Salesforce org type:",
    format_item = function(item)
      return "  " .. item
    end,
  }, function(choice)
    if choice == nil then
      return
    end

    if choice:match("Project Default") then
      H.continue_auth_with_alias(project_login_url)
    elseif choice:match("Sandbox") then
      H.continue_auth_with_alias("https://test.salesforce.com")
    elseif choice:match("Custom") then
      vim.ui.input({
        prompt = "Enter instance URL (empty for project default): ",
        default = "https://",
      }, function(url)
        -- If empty and project default exists, use it
        if (url == nil or url == "" or url == "https://") and project_login_url then
          H.continue_auth_with_alias(project_login_url)
        elseif url == nil or url == "" or url == "https://" then
          return U.show_warn("URL is required")
        else
          -- Validate URL format
          if not url:match("^https?://") then
            return U.show_err("URL must start with http:// or https://")
          end
          H.continue_auth_with_alias(url)
        end
      end)
    else
      -- Production - no instance URL needed (uses default)
      H.continue_auth_with_alias(nil)
    end
  end)
end

H.clean_org_cache = function()
  H.orgs = {}
end

H.set_target_org = function()
  U.is_table_empty(H.orgs)
  vim.ui.select(H.orgs, {
    prompt = "Local target_org:",
  }, function(choice)
    if choice ~= nil then
      local org = string.gsub(choice, "%[S%] ", "")
      local cmd = 'sf config set target-org "' .. org .. '"'
      local err_msg = org .. " - set target_org failed! Not in a sfdx project folder?"
      local cb = function()
        U.target_org = org
      end

      U.silent_job_call(cmd, nil, err_msg, cb)
    end
  end)
end

H.set_global_target_org = function()
  if U.is_empty_str(H.orgs) then
    U.notify_then_error("Empty value")
  end

  vim.ui.select(H.orgs, {
    prompt = "Global target_org:",
  }, function(choice)
    if choice ~= nil then
      local org = string.gsub(choice, "%[S%] ", "")
      local cmd = "sf config set target-org --global " .. org
      local msg = "Global target_org set: " .. org
      local err_msg = string.format("Global set target_org [%s] failed!", org)
      local cb = function()
        U.target_org = org
      end
      U.silent_job_call(cmd, msg, err_msg, cb)
    end
  end)
end

---@param data string
H.store_orgs = function(data)
  local s = ""
  for _, v in ipairs(data) do
    s = s .. v
  end

  local org_data = vim.json.decode(s, {}).result.nonScratchOrgs
  local scratch_org_data = vim.json.decode(s, {}).result.scratchOrgs

  for i = 1, #scratch_org_data do
    org_data[#org_data + 1] = scratch_org_data[i]
  end

  for _, v in pairs(org_data) do
    local alias = v.alias or v.username
    if v.isDefaultUsername then
      U.target_org = alias
    end

    local org_entry = v.isScratch and "[S] " .. alias or alias
    table.insert(H.orgs, org_entry)
  end

  U.is_table_empty(H.orgs)
end

H.fetch_and_store_orgs = function()
  vim.fn.jobstart("sf org list --json --skip-connection-status", {
    stdout_buffered = true,
    on_stdout = function(_, data)
      H.store_orgs(data)
    end,
  })
end

H.fetch_org_list = function()
  U.is_sf_cmd_installed()

  H.clean_org_cache()
  H.fetch_and_store_orgs()
end

H.diff_in_target_org = function()
  if U.is_empty_str(U.target_org) then
    return U.show_err("Target_org empty!")
  end

  H.diff_in(U.target_org)
end

H.diff_in_org = function()
  U.is_table_empty(H.orgs)

  vim.ui.select(H.orgs, {
    prompt = "Select org to diff in:",
  }, function(choice)
    if choice ~= nil then
      H.diff_in(choice)
    end
  end)
end

---@param org string
H.diff_in = function(org)
  local file_name = vim.fn.expand("%:t")
  local metadataType = H.get_metadata_type(vim.fn.expand("%:p"))
  local file_name_no_ext = H.get_file_name_without_extension(file_name)
  local temp_path = vim.fn.tempname()

  -- local cmd = string.format(
  --   "sf project retrieve start -m %s:%s -r %s -o %s --json",
  --   metadataType,
  --   file_name_no_ext,
  --   temp_path,
  --   org
  -- )
  local cmd = B:new()
    :cmd("project")
    :act("retrieve start")
    :addParams({
      ["-m"] = metadataType .. ":" .. file_name_no_ext,
      ["-r"] = temp_path,
      ["--json"] = "",
    })
    :set_org(org)
    :build()

  local msg = "Retrive success: " .. org
  local err_msg = "Retrive failed: " .. org
  local cb = function()
    local temp_file = H.find_file(temp_path, file_name)
    vim.cmd("vert diffsplit " .. temp_file)
    vim.bo[0].buflisted = false
  end

  U.silent_job_call(cmd, msg, err_msg, cb)
end

---@param fileName string
---@return any
H.get_file_name_without_extension = function(fileName)
  -- (.-) makes the match non-greedy
  -- see https://www.lua.org/manual/5.3/manual.html#6.4.1
  return fileName:match("(.-)%.%w+%-meta%.xml$") or fileName:match("(.-)%.[^%.]+$")
end

H.metadata_types = {
  ["lwc"] = "LightningComponentBundle",
  ["aura"] = "AuraDefinitionBundle",
  ["classes"] = "ApexClass",
  ["triggers"] = "ApexTrigger",
  ["pages"] = "ApexPage",
  ["components"] = "ApexComponent",
  ["flows"] = "Flow",
  ["objects"] = "CustomObject",
  ["layouts"] = "Layout",
  ["permissionsets"] = "PermissionSet",
  ["profiles"] = "Profile",
  ["labels"] = "CustomLabels",
  ["staticresources"] = "StaticResource",
  ["sites"] = "CustomSite",
  ["applications"] = "CustomApplication",
  ["roles"] = "UserRole",
  ["groups"] = "Group",
  ["queues"] = "Queue",
}

---@param filePath string
---@return string | nil
H.get_metadata_type = function(filePath)
  for key, metadataType in pairs(H.metadata_types) do
    if filePath:find(key) then
      return metadataType
    end
  end
  return nil
end

---@param path string
---@param target string
---@return string
H.find_file = function(path, target)
  local scanner = vim.loop.fs_scandir(path)
  -- if scanner is nil, then path is not a valid dir
  if scanner then
    local file, type = vim.loop.fs_scandir_next(scanner)
    if path:sub(-1) ~= "/" then
      path = path .. "/"
    end
    while file do
      if type == "directory" then
        local found = H.find_file(path .. file, target)
        if found then
          return found
        end
      elseif file == target then
        return path .. file
      end
      -- get the next file and type
      file, type = vim.loop.fs_scandir_next(scanner)
    end
  end
end

return Org
