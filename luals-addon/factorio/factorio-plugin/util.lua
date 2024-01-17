--##

local floor_div = __plugin_dev
  and function(left, right) return math.floor(left / right) end
  or load("return function(left, right) return left // right end")()
local band = __plugin_dev and bit32.band or load("return function(left, right) return left & right end")()
local bor = __plugin_dev and bit32.bor or load("return function(left, right) return left | right end")()
local bnot = __plugin_dev and bit32.bnot or load("return function(value) return ~value end")()

---@type table<integer, Diff>
local diff_finish_pos_to_diff_map = {}

local function clean_up_diff_finished_pos_to_diff_map()
  local next = next
  local k = next(diff_finish_pos_to_diff_map)
  while k do
    local next_k = next(diff_finish_pos_to_diff_map, k)
    diff_finish_pos_to_diff_map[k] = nil
    k = next_k
  end
end

---it's string.gmatch, but anchored at the start of a line
---it is not supported to capture the entire match by not defining any captures
---in that case explicitly define the capture. (Because a newline might be added at the start)
---
---**important** note: if the given pattern contains `\n` and the second line
---could be a match for the first lien of the pattern (like if you have `foo()\nfoo`)
---then the second match returned by the returned iterator would actually start at the
---`foo` that was already included in the first match.
---(so `foo()\nfoo` with the input `foo\nfoo\nfoo` would result in 2 matches instead of 1)
---this _could_ be fixed, however it is not worth the complexity and performance.
---not as long as there is no use for it
---
---the same goes for the first oddity about matching the whole pattern. it could be fixed, but is not worth it
---@param s string
---@param pattern string
---@return fun(): string|integer, ...
local function gmatch_at_start_of_line(s, pattern)
  local first = true
  local unpack = table.unpack
  ---@type fun(): string|integer, ...
  local gmatch_iterator = s:gmatch("\n"..pattern)
  return function()
    if first then
      first = false
      local result = {s:match("^"..pattern)}
      if result[1] then
        return unpack(result)
      end
    end
    return gmatch_iterator()
  end
end

---extends the text of a ChainDiffElem or setting it if it is nil
---@param elem ChainDiffElem
---@param text string
local function extend_chain_diff_elem_text(elem, text)
  if elem.text then
    elem.text = elem.text.. text
  else
    elem.text = text
  end
end

---@param diffs Diff.ArrayWithCount
---@param start integer
---@param finish integer
---@param replacement string
local function add_diff(diffs, start, finish, replacement)
  -- Finish is treated as including, but we want excluding for consistency with chain diffs.
  finish = finish - 1
  local count = diffs.count
  count = count + 1
  diffs.count = count
  ---@type Diff
  local diff = {
    start = start,
    finish = finish,
    text = replacement,
  }
  diffs[count] = diff
  diff_finish_pos_to_diff_map[finish] = diff
end

---@param diffs Diff.ArrayWithCount
---@param position integer @ Position of a single character, instead of start and finish.
---@param prev_char string @ The character at the given position, before replacements.
---@param addition string @ The string to append after `prev_char`.
local function add_or_append_diff(diffs, position, prev_char, addition)
  local diff = diff_finish_pos_to_diff_map[position]
  if diff then
    diff.text = diff.text..addition
  else
    return add_diff(diffs, position, position + 1, prev_char..addition)
  end
end

---@param diffs Diff.ArrayWithCount
local function remove_diff(diffs)
  local count = diffs.count
  diffs[count] = nil
  diffs.count = count - 1
end

---if 'source' is a string wrapped in "" or '' get the string inside those quotes
---otherwise returns nil
---@param source string
---@return string|false
local function try_parse_string_literal(source)
  ---@type string, integer
  local str, f_str = source:match("^[\"']([^\"']*)[\"']%s*()")
  return f_str == #str and str
end

---@param chain_diff ChainDiffElem[]
---@param i_in_chain_diff number @ index of the elem in `chain_diff` that represents the source
---@param source string
---@param is_literal_contents? boolean @ is 'source' the contents of a literal string already
---@param do_not_pad_with_white_space? boolean @ when using literal identifiers they get padded with a blank space to acuminate for replacing the quotes. If `true`, that padding is not added
local function use_source_to_index(chain_diff, i_in_chain_diff, source, is_literal_contents, do_not_pad_with_white_space)
  local contents = is_literal_contents and source or try_parse_string_literal(source)
  if contents and contents:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
    -- source is a literal string and a valid identifier
    extend_chain_diff_elem_text(chain_diff[i_in_chain_diff - 1], ".")
    chain_diff[i_in_chain_diff].text = (do_not_pad_with_white_space and "" or " ")..contents
  else
    -- source is a variable, expression or literal string which is an invalid identifier
    extend_chain_diff_elem_text(chain_diff[i_in_chain_diff - 1], "[")
    extend_chain_diff_elem_text(chain_diff[i_in_chain_diff + 1], "]")
    -- leaves chain_diff[i_in_chain_diff] untouched
  end
end

---@class ChainDiffElem
---@field i integer @ index within the text of the file
---@field text nil|string @ text replacing from this elem's `i` including to the next elem's `i` excluding. When nil no diff will be created. If the last elem has `text` it will treat it as if there was another elem after with with the same `i`

---creates diffs according to the chain_diff. See ChainDiffElem class description for how it works
---@param chain_diff ChainDiffElem[]
---@param diffs Diff.ArrayWithCount
local function add_chain_diff(chain_diff, diffs)
  local prev_chain_diff_elem = chain_diff[1]
  if not prev_chain_diff_elem then return end
  for i = 2, #chain_diff do
    local chain_diff_elem = chain_diff[i]
    if prev_chain_diff_elem.text then
      local count = diffs.count
      count = count + 1
      diffs.count = count
      local finish = chain_diff_elem.i - 1 -- finish is treated as including, which we don't want
      ---@type Diff
      local diff = {
        start = prev_chain_diff_elem.i,
        finish = finish,
        text = prev_chain_diff_elem.text,
      }
      diffs[count] = diff
      diff_finish_pos_to_diff_map[finish] = diff
    end
    prev_chain_diff_elem = chain_diff_elem
  end
  if prev_chain_diff_elem.text then
    local count = diffs.count
    count = count + 1
    diffs.count = count
    local finish = prev_chain_diff_elem.i - 1
    ---@type Diff
    local diff = {
      start = prev_chain_diff_elem.i,
      finish = finish,
      text = prev_chain_diff_elem.text,
    }
    diffs[count] = diff
    diff_finish_pos_to_diff_map[finish] = diff
  end
end

---@enum PluginDisableFlags
local module_flags = {
  none = 0,
  command_line = 1,
  global = 2,
  object_name = 4,
  on_event = 8,
  remote_add = 16,
  remote_call = 32,
  require = 64,
  all = 127,
}

---@type integer[]
local disabled_positions = {1} -- Always contains 1 element.
---@type PluginDisableFlags[]
local disabled_flags = {module_flags.none} -- Indexes match up with `disabled_positions`.
local disabled_positions_count = 1
local current_disabled_positions_lower_bound = 0 -- Zero based.

-- -- Premature optimization
-- local flags_lookups = {}
-- for _, flag in pairs(disabled_flags) do
--   local lut = {}
--   flags_lookups[flag] = lut
--   for _, other_flag in pairs(disabled_flags) do
--     lut[flag + (other_flag == flag and 0 or other_flag)] = true
--   end
-- end

---@param position integer
---@param flag PluginDisableFlags
---@return boolean
local function is_disabled(position, flag)
  local lower_bound = current_disabled_positions_lower_bound -- Zero based, inclusive.
  local upper_bound = disabled_positions_count -- Zero based, exclusive.
  local i = floor_div(lower_bound + upper_bound, 2)
  -- Try close to the lower bound first, since text is processed front to back.
  i = math.min(i, lower_bound + 8)
  while true do
    local pos = disabled_positions[i + 1]
    if position >= pos then
      lower_bound = i + 1
    else
      upper_bound = i
    end
    if lower_bound == upper_bound then break end
    i = floor_div(lower_bound + upper_bound, 2)
  end
  lower_bound = lower_bound - 1
  current_disabled_positions_lower_bound = lower_bound
  local flags = disabled_flags[lower_bound + 1] -- + 1 to go from zero to one based.
  return band(flags, flag) ~= 0
end

local function reset_is_disabled_to_file_start()
  current_disabled_positions_lower_bound = 0
end

local function clean_up_disabled_data()
  for i = 2, disabled_positions_count do
    disabled_positions[i] = nil
    disabled_flags[i] = nil
  end
  disabled_positions_count = 1
  current_disabled_positions_lower_bound = 0
end

---@param position integer
---@param flags PluginDisableFlags
---@param may_not_be_last boolean? @
---The current last position may actually be past this position. Check and adjust for that.
local function add_disabled_flags(position, flags, may_not_be_last)
  local count = disabled_positions_count + 1
  disabled_positions_count = count
  if may_not_be_last and disabled_positions[count - 1] > position then
    disabled_positions[count] = disabled_positions[count - 1]
    disabled_flags[count] = disabled_flags[count - 1]
    count = count - 1
  end
  disabled_positions[count] = position
  disabled_flags[count] = flags
end

local module_name_intellisense = [[
__plugin_dummy(({---@diagnostic disable-line: undefined-global
---Removal of `/c` and friends at the start of a line.
command_line=true,
---Replacement of expressions involving `global` to help the language sever distinguish global tables between different mods.
global=true,
---Rearrangement of `obj.object_name == "LuaEntity"` for the language server to perform type narrowing, same as how `type()` works.
object_name=true,
---Insertion of `@param` tag for inline event registrations, with support for flib and stdlib.
on_event=true,
---Hacks for `remote.add_interface` to look like table assignments, allowing the remote_add hack to provide intellisense.
remote_add=true,
---Hacks for `remote.call` to look like table indexes into a fake table with all found remote interfaces to provide intellisense.
remote_call=true,
---Mainly removal of the `__` in `require("__mod-name__.file")` for better cross mod file resolution.
require=true,
}).]]

---Always contains 1 element.\
---This element must exist because the binary search expects at least 1 element. It searches for a value <=
---the given position, but this has to be 0 because 1 could be an index in the actual code already. So this 0
---basically defines the range starting at "before the code" until the first position, exclusive.\
---Additionally for code ranges the index in the code_ranges array defines whether or not it is code or a
---string or comment. They alternate, so the first range is code, the second string/comment, and so on.
---@type integer[]
local code_ranges = {0}
local code_ranges_count = 1
local current_code_ranges_lower_bound = 0 -- Zero based.

local function clean_up_code_ranges()
  for i = code_ranges_count, 2, -1 do
    code_ranges[i] = nil
  end
  code_ranges[1] = 0
  code_ranges_count = 1
  current_code_ranges_lower_bound = 0
end

local function reset_code_ranges()
  current_code_ranges_lower_bound = 0
end

---@param position integer? @ `nil` means end of file.
local function add_code_range_position(position)
  if not position then return end -- End of file, nothing to do.
  -- If the latest position is the same then simply extend that range. Do so by removing the
  -- current end of the range, it will get closed by the next call to `add_code_range_position`.
  if code_ranges[code_ranges_count] == position then
    -- Does not need to remove from code_ranges, because it'll
    -- probably get overwritten and count is tracked separately anyway.
    code_ranges_count = code_ranges_count - 1
    return
  end
  code_ranges_count = code_ranges_count + 1
  code_ranges[code_ranges_count] = position
end

local parse_strings_comments_and_annotations
do
  ---@type string
  local source
  ---@type Diff.ArrayWithCount
  local diffs
  ---@type integer?
  local cursor
  ---@type integer
  local line_start
  ---@type PluginDisableFlags
  local current_flags

  ---`cursor` must not be `nil`.\
  ---check if the next character(s) are equal to the given string
  ---@param query string
  ---@return boolean
  local function peek(query)
    ---@cast cursor -nil
    if cursor + #query > #source then return false end
    return source:sub(cursor, cursor + #query - 1) == query
  end

  ---`cursor` must not be `nil`.
  ---@param query string
  ---@return boolean
  local function take(query)
    ---@cast cursor -nil
    if not peek(query) then return false end
    cursor = cursor + #query
    return true
  end

  ---Parse a opening long bracket, like `[[` or `[=[`
  ---Assumes the first bracket has already been consumed.
  ---@return integer? level @ `nil` when there isn't a valid open bracket.
  local function parse_long_bracket_open()
    -- Consume all the '='s
    local match = source:match("^=*%[()", cursor)
    if not match then return nil end
    local level = match - cursor - 1
    cursor = match
    return level
  end

  ---@param start_position integer
  ---@param quote `"`|`'`
  local function parse_short_string(start_position, quote)
    add_code_range_position(start_position)
    while cursor do
      cursor = string.match(source, "()[\\"..quote.."\r\n]", cursor)
      if not cursor then return end
      if not take("\\") then
        cursor = cursor + 1 -- Consume quote or newline (Don't care about 2 char wide newlines).
        add_code_range_position(cursor)
        return
      end
      -- `\` has been consumed.
      local escaped_char = source:sub(cursor, cursor)
      cursor = cursor + 1 -- Consume escaped char.
      if escaped_char == "z" then
        cursor = string.match(source, "^%s*()", cursor)
        goto continue
      end
      if escaped_char == "\n" or escaped_char == "\r" then
        local next_char = source:sub(cursor, cursor)
        if (next_char == "\n" or next_char == "\r") and next_char ~= escaped_char then
          -- Handle `\r\n` and `\n\r` in source files. They are both treated as a single newline in Lua.
          -- (And they are converted to just `\n`, but we don't care about that here.)
          cursor = cursor + 1
        end
        goto continue
      end
      -- All other escaped characters, valid or not, don't require special handling.
      ::continue::
    end
  end

  ---@param start_position integer
  ---@param level integer @ The amount of `=` between the square brackets
  local function parse_long_string(start_position, level)
    add_code_range_position(start_position)
    cursor = string.match(source, "%]"..string.rep("=", level).."%]()", cursor)
    add_code_range_position(cursor)
  end

  ---@return PluginDisableFlags
  local function parse_module_flags_list()
    local flags = module_flags.none
    repeat
      local s_module_name, module_name, f_module_name, p_comma
      local start_pos = cursor
      ---@type integer, string, integer, integer, integer
      s_module_name, module_name, f_module_name, p_comma, cursor
        = string.match(source, "^[^%S\r\n]*()([%a_]*)()[^%S\r\n]*(),?()", cursor)
      local module_flag = module_flags[module_name]
      if not module_flag then-- Invalid 'module_name'.
        -- Add a newline followed by a function call (to make it valid both as a statement and in
        -- table constructors). The first argument to the call is a table constructor wrapped in
        -- '()' followed by '.' to instantly index into that constructed table. The table contains
        -- all the valid module names with a short comment describing what that module does.
        add_diff(diffs, start_pos - 1, start_pos,
          string.sub(source, start_pos - 1, start_pos - 1).."\n"..module_name_intellisense
        )
        -- Must be split into 2 diffs like this to actually get the intellisense from the "table index".
        -- Using an undefined global to get a warning. Extra ',' in the argument list to ensure
        -- there is an error visible to the programmer, even with undefined global warnings disabled.
        -- ';' at the end because it is valid both in statement and in table constructor context.
        add_diff(diffs, s_module_name, f_module_name,
          module_name..","..(module_name == "" and "missing" or "invalid").."_module_name,);--"
        )
        goto continue
      end
      -- if band(flags, module_flag) ~= 0 then end -- Duplicate 'module_name' in list.
      flags = bor(flags, module_flag)
      ::continue::
    until p_comma == cursor
    return flags
  end

  local valid_tags_lut = {
    ["disable-next-line"] = true,
    ["disable-line"] = true,
    ["disable"] = true,
    ["enable"] = true,
  }

  local function parse_plugin_annotation()
    ---@cast cursor -nil
    ---@type integer, string, integer, integer
    local s_tag, tag, colon_pos, done_pos = string.match(source, "^[^%S\r\n]*()([%a%-]*)[^%S\r\n]*():?()", cursor)
    if (cursor == s_tag and tag == "")
      or (cursor ~= s_tag and not valid_tags_lut[tag])
    then
      add_diff(diffs, cursor - #"plugin", cursor, "diagnostic") -- To get disable/enable etc suggestions.
      return
    end
    if cursor == s_tag then return end -- It isn't actually an ---@plugin annotation.

    cursor = done_pos
    local flags = colon_pos == done_pos
      and module_flags.all -- No colon.
      or parse_module_flags_list() -- Has colon, must have a list of flags.

    if flags == module_flags.none then return end -- Short circuit.

    if tag == "disable-next-line" then
      local next_line_start, next_line_finish = string.match(source, "[\r\n]()[^\r\n]*()", done_pos)
      if next_line_start then
        add_disabled_flags(next_line_start, bor(current_flags, flags))
        add_disabled_flags(next_line_finish, current_flags)
      end
    elseif tag == "disable-line" then
      if disabled_positions[disabled_positions_count - 1] == line_start then
        -- If the previous line had a disable-next-line, combine them.
        disabled_flags[disabled_positions_count - 1] = bor(disabled_flags[disabled_positions_count - 1], flags)
      else
        add_disabled_flags(line_start, bor(current_flags, flags))
        add_disabled_flags(string.match(source, "^[^\r\n]*()", done_pos), current_flags)
      end
    elseif tag == "disable" then
      current_flags = bor(current_flags, flags)
      -- 'may_not_be_last = true' because the pervious line may have been 'disable-next-line'.
      add_disabled_flags(colon_pos, current_flags, true)
    elseif tag == "enable" then
      current_flags = band(current_flags, bnot(flags))
      -- 'may_not_be_last = true' because the pervious line may have been 'disable-next-line'.
      add_disabled_flags(colon_pos, current_flags, true)
    else
      error("Impossible tag "..tostring(tag).." because the tag has already been checked using valid_tags_lut.")
    end
  end

  ---@param start_position integer
  local function parse_short_comment(start_position)
    add_code_range_position(start_position)
    if take("-") then
      cursor = string.match(source, "^[^%S\r\n]*()", cursor)
      if take("@plugin") then
        parse_plugin_annotation()
      end
    end
    -- Technically in Lua newlines are not part of the single line comment anymore,
    -- however this distinction does not matter for us here, in fact this is more efficient
    -- because it can allow for ranges to be combined into 1. Unless the source uses `\r\n`.
    cursor = string.match(source, "[\r\n]()", cursor)
    add_code_range_position(cursor)
  end

  local function parse()
    while cursor do
      local current_char
      -- rapid advance to the next interesting character
      current_char, cursor = string.match(source, "([-[\"'\r\n])()", cursor)
      if not cursor then break end
      local anchor = cursor

      if current_char == "-" then
        if not take("-") then goto continue end
        if not take("[") then
          parse_short_comment(anchor)
          goto continue
        end
        -- `[` has been consumed.
        local level = parse_long_bracket_open()
        if level then
          parse_long_string(anchor, level)
        else
          cursor = cursor - 1 -- Don't consume `[`.
          parse_short_comment(anchor)
        end
      elseif current_char == "[" then
        local level = parse_long_bracket_open()
        if level then
          parse_long_string(anchor, level)
        end
      elseif current_char == '"' or current_char == "'" then
        parse_short_string(anchor, current_char)
      elseif current_char == "\r" or current_char == "\n" then
        line_start = cursor
      else
        error("Impossible current_char '"..tostring(current_char).."'.")
      end
      ::continue::
    end
  end

  ---Lexically analyze Lua source files for positions of strings and comments.
  ---Notably, this needs to be able to handle 'long brackets', which are context-sensitive.
  ---Also parses ---@plugin annotations.
  ---This is only run once per file.
  ---@param text string
  ---@param diffs_array Diff.ArrayWithCount
  function parse_strings_comments_and_annotations(text, diffs_array)
    source = text
    diffs = diffs_array
    cursor = 1 -- 1 is the first character in the source file.
    line_start = 1
    current_flags = module_flags.none
    parse()
    -- If it is currently still inside of a string or comment, that range will not get closed.
    -- That's fine however because nothing will be checking if a position past the end of the
    -- file is code, a string or a comment.
  end
end

---@param position integer
---@return boolean
local function is_code(position)
  local lower_bound = current_code_ranges_lower_bound -- Zero based, inclusive.
  local upper_bound = #code_ranges -- Zero based, exclusive.
  local i = floor_div(lower_bound + upper_bound, 2)
  -- Try close to the lower bound first, since text is processed front to back.
  i = math.min(i, lower_bound + 16)
  while true do
    local pos = code_ranges[i + 1]
    if position >= pos then
      lower_bound = i + 1
    else
      upper_bound = i
    end
    if lower_bound == upper_bound then break end
    i = floor_div(lower_bound + upper_bound, 2)
  end
  lower_bound = lower_bound - 1
  current_code_ranges_lower_bound = lower_bound
  return (lower_bound % 2) == 0 -- Remember it's zero based.
end

---@param text string
---@param diffs Diff.ArrayWithCount
local function on_pre_process_file(text, diffs)
  parse_strings_comments_and_annotations(text, diffs)
end

local function on_post_process_file()
  clean_up_diff_finished_pos_to_diff_map()
  clean_up_disabled_data()
  clean_up_code_ranges()
end

return {
  module_flags = module_flags,
  is_disabled = is_disabled,
  reset_is_disabled_to_file_start = reset_is_disabled_to_file_start,
  gmatch_at_start_of_line = gmatch_at_start_of_line,
  add_diff = add_diff,
  add_or_append_diff = add_or_append_diff,
  remove_diff = remove_diff,
  add_chain_diff = add_chain_diff,
  extend_chain_diff_elem_text = extend_chain_diff_elem_text,
  try_parse_string_literal = try_parse_string_literal,
  use_source_to_index = use_source_to_index,
  is_code = is_code,
  reset_code_ranges = reset_code_ranges,
  on_pre_process_file = on_pre_process_file,
  on_post_process_file = on_post_process_file,
}
