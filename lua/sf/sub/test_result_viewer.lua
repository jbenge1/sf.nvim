local U = require("sf.util")
local api = vim.api

local M = {}
local H = {}

-- Buffer and window state
local result_buf = nil
local result_win = nil

---Parse test result JSON and extract useful information
---@param test_result table The decoded JSON test result
---@return table Parsed test summary
H.parse_test_result = function(test_result)
  local summary = {
    total = 0,
    passed = 0,
    failed = 0,
    skipped = 0,
    failures = {},
    time = 0,
  }

  -- Navigate to the actual test results in the JSON structure
  local tests = vim.tbl_get(test_result, "result", "tests")
  if not tests then
    return summary
  end

  for _, test in ipairs(tests) do
    summary.total = summary.total + 1

    local outcome = test.Outcome or test.outcome
    if outcome == "Pass" then
      summary.passed = summary.passed + 1
    elseif outcome == "Fail" then
      summary.failed = summary.failed + 1
      table.insert(summary.failures, {
        class = test.ApexClass and test.ApexClass.Name or test.FullName:match("(.+)%."),
        method = test.MethodName,
        message = test.Message,
        stackTrace = test.StackTrace,
        time = test.RunTime or 0,
      })
    elseif outcome == "Skip" then
      summary.skipped = summary.skipped + 1
    end

    summary.time = summary.time + (test.RunTime or 0)
  end

  return summary
end

---Format the test results into display lines
---@param summary table Parsed test summary
---@return table Lines to display
H.format_results = function(summary)
  local lines = {}

  -- Header
  table.insert(
    lines,
    "╔════════════════════════════════════════════════════════════╗"
  )
  table.insert(lines, "║                    TEST RESULTS SUMMARY                    ║")
  table.insert(
    lines,
    "╚════════════════════════════════════════════════════════════╝"
  )
  table.insert(lines, "")

  -- Summary stats
  local status_icon = summary.failed == 0 and "✓" or "✗"
  local status_text = summary.failed == 0 and "ALL TESTS PASSED" or "TESTS FAILED"

  table.insert(lines, string.format("  %s  %s", status_icon, status_text))
  table.insert(lines, "")
  table.insert(lines, string.format("  Total:   %d tests", summary.total))
  table.insert(lines, string.format("  ✓ Passed: %d", summary.passed))

  if summary.failed > 0 then
    table.insert(lines, string.format("  ✗ Failed: %d", summary.failed))
  end

  if summary.skipped > 0 then
    table.insert(lines, string.format("  ⊘ Skipped: %d", summary.skipped))
  end

  table.insert(lines, string.format("  ⏱ Time:    %.3fs", summary.time / 1000))
  table.insert(lines, "")

  -- Show failures if any
  if summary.failed > 0 then
    table.insert(
      lines,
      "────────────────────────────────────────────────────────────"
    )
    table.insert(lines, "FAILURES:")
    table.insert(
      lines,
      "────────────────────────────────────────────────────────────"
    )
    table.insert(lines, "")

    for i, failure in ipairs(summary.failures) do
      table.insert(lines, string.format("✗ Test #%d:", i))
      table.insert(lines, string.format("  Class:  %s", failure.class))
      table.insert(lines, string.format("  Method: %s", failure.method))
      table.insert(lines, "")
      table.insert(lines, "  Error Message:")

      -- Wrap error message
      if failure.message then
        for msg_line in failure.message:gmatch("[^\r\n]+") do
          table.insert(lines, "    " .. msg_line)
        end
      end

      table.insert(lines, "")

      -- Stack trace
      if failure.stackTrace then
        table.insert(lines, "  Stack Trace:")
        for trace_line in failure.stackTrace:gmatch("[^\r\n]+") do
          table.insert(lines, "    " .. trace_line)
        end
        table.insert(lines, "")
      end

      if i < #summary.failures then
        table.insert(
          lines,
          "  ─────────────────────────────────────────────────"
        )
        table.insert(lines, "")
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Press 'q' to close | Press 'j'/'k' to cycle through failures")

  return lines
end

---Create or reuse result buffer
---@return integer Buffer number
H.get_or_create_buf = function()
  if result_buf and api.nvim_buf_is_valid(result_buf) then
    return result_buf
  end

  result_buf = api.nvim_create_buf(false, true)
  vim.bo[result_buf].buftype = "nofile"
  vim.bo[result_buf].filetype = "sf_test_results"
  vim.bo[result_buf].bufhidden = "wipe"

  return result_buf
end

---Open result window
---@param buf integer Buffer to display
---@return integer Window number
H.open_window = function(buf)
  -- Get editor dimensions
  local width = api.nvim_get_option("columns")
  local height = api.nvim_get_option("lines")

  -- Calculate window size (80% of screen)
  local win_width = math.min(100, math.floor(width * 0.8))
  local win_height = math.min(30, math.floor(height * 0.8))

  -- Center the window
  local row = math.floor((height - win_height) / 2)
  local col = math.floor((width - win_width) / 2)

  local opts = {
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " SF Test Results ",
    title_pos = "center",
  }

  result_win = api.nvim_open_win(buf, true, opts)

  -- Set window options
  vim.wo[result_win].wrap = false
  vim.wo[result_win].cursorline = true

  return result_win
end

---Set up keymaps for the result window
---@param buf integer Buffer number
---@param summary table Test summary with failure info
H.setup_keymaps = function(buf, summary)
  local opts = { buffer = buf, noremap = true, silent = true }
  local current_failure_index = 1

  -- Close window
  vim.keymap.set("n", "q", function()
    if result_win and api.nvim_win_is_valid(result_win) then
      api.nvim_win_close(result_win, true)
    end
  end, opts)

  vim.keymap.set("n", "<Esc>", function()
    if result_win and api.nvim_win_is_valid(result_win) then
      api.nvim_win_close(result_win, true)
    end
  end, opts)

  -- Jump to failures - cycles through all with repeated 'j' presses
  vim.keymap.set("n", "j", function()
    if #summary.failures == 0 then
      return
    end

    local failure = summary.failures[current_failure_index]

    -- Close the result window
    if result_win and api.nvim_win_is_valid(result_win) then
      api.nvim_win_close(result_win, true)
    end

    -- Construct the path to the test class using get_default_dir_path
    local class_path = U.get_default_dir_path() .. "classes/" .. failure.class .. ".cls"

    if U.file_readable(class_path) then
      vim.cmd("edit " .. class_path)

      -- Try to find the test method and jump to it
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      for line_num, line in ipairs(lines) do
        if
          line:match("testmethod%s+" .. failure.method)
          or line:match("void%s+" .. failure.method)
          or line:match(failure.method .. "%s*%(")
        then
          vim.api.nvim_win_set_cursor(0, { line_num, 0 })
          vim.cmd("normal! zz")
          break
        end
      end

      -- Show which failure we're on
      if #summary.failures > 1 then
        U.show(string.format("Failure %d of %d", current_failure_index, #summary.failures))
      end

      -- Cycle to next failure for next 'j' press
      current_failure_index = current_failure_index + 1
      if current_failure_index > #summary.failures then
        current_failure_index = 1
      end
    else
      U.show_warn("Could not find test class: " .. failure.class .. " at path: " .. class_path)
    end
  end, opts)

  -- Jump backwards through failures
  vim.keymap.set("n", "k", function()
    if #summary.failures == 0 then
      return
    end

    -- Move backwards
    current_failure_index = current_failure_index - 2
    if current_failure_index < 1 then
      current_failure_index = #summary.failures
    end

    -- Trigger the jump (which will increment by 1)
    vim.api.nvim_feedkeys("j", "n", false)
  end, opts)
end

---Display test results in a floating window
---@param test_result_path string Path to the test result JSON file
M.show_results = function(test_result_path)
  -- Read and parse the test result JSON
  local test_result = U.read_file_json_to_tbl("test_result.json", U.get_plugin_folder_path())

  if not test_result then
    return U.show_err("Could not read test results from: " .. test_result_path)
  end

  -- Parse the results
  local summary = H.parse_test_result(test_result)

  if summary.total == 0 then
    return U.show_warn("No test results found")
  end

  -- Format into display lines
  local lines = H.format_results(summary)

  -- Get or create buffer
  local buf = H.get_or_create_buf()

  -- Set the content
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Open window
  H.open_window(buf)

  -- Setup keymaps
  H.setup_keymaps(buf, summary)

  -- Apply highlights
  H.apply_highlights(buf, summary)

  -- Show notification
  if summary.failed == 0 then
    U.show(string.format("✓ All %d tests passed!", summary.total))
  else
    U.show_err(string.format("✗ %d of %d tests failed", summary.failed, summary.total))
  end
end

---Apply syntax highlighting to the results buffer
---@param buf integer Buffer number
---@param summary table Test summary
H.apply_highlights = function(buf, summary)
  local ns = api.nvim_create_namespace("sf_test_results")

  -- Clear existing highlights
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local line_num = i - 1

    -- Header box
    if line:match("^[╔╚]") or line:match("^║") then
      api.nvim_buf_add_highlight(buf, ns, "Comment", line_num, 0, -1)
    end

    -- Success/failure status
    if line:match("ALL TESTS PASSED") then
      api.nvim_buf_add_highlight(buf, ns, "diffAdded", line_num, 0, -1)
    elseif line:match("TESTS FAILED") then
      api.nvim_buf_add_highlight(buf, ns, "diffRemoved", line_num, 0, -1)
    end

    -- Stats
    if line:match("✓ Passed") then
      api.nvim_buf_add_highlight(buf, ns, "diffAdded", line_num, 0, -1)
    elseif line:match("✗ Failed") then
      api.nvim_buf_add_highlight(buf, ns, "diffRemoved", line_num, 0, -1)
    elseif line:match("⊘ Skipped") then
      api.nvim_buf_add_highlight(buf, ns, "Comment", line_num, 0, -1)
    end

    -- Failure headers
    if line:match("^✗ Test #%d+:") then
      api.nvim_buf_add_highlight(buf, ns, "ErrorMsg", line_num, 0, -1)
    end

    -- Section headers
    if line:match("Error Message:") or line:match("Stack Trace:") then
      api.nvim_buf_add_highlight(buf, ns, "Title", line_num, 0, -1)
    end

    -- Dividers
    if line:match("^──") or line:match("^  ──") then
      api.nvim_buf_add_highlight(buf, ns, "Comment", line_num, 0, -1)
    end
  end
end

return M
