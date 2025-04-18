--- include-files.lua – filter to include Markdown files
---
--- Copyright: © 2019–2021 Albert Krewinkel
--- License:   MIT – see LICENSE file for details

-- Module pandoc.path is required and was added in version 2.12
PANDOC_VERSION:must_be_at_least '2.12'

local List = require 'pandoc.List'
local path = require 'pandoc.path'

if #PANDOC_STATE.input_files > 1 then
	io.stderr:write("Error: only a single input file is supported.\n")
	os.exit(1)
end

local warn = pcall(require, 'pandoc.log')
  and (require 'pandoc.log').warn
  or warn
  or function (msg) io.stderr:write(msg .. '\n') end

--- Get include auto mode
local include_auto = false
function get_vars (meta)
  if meta['include-auto'] then
    include_auto = true
  end
end

--- Keep last heading level found
local last_heading_level = 0
function update_last_level(header)
  last_heading_level = header.level
end

--- Update contents of included file
local function update_contents(blocks, shift_by, include_path)
  local update_contents_filter = {
    -- Shift headings in block list by given number
    Header = function (header)
      if shift_by then
        header.level = header.level + shift_by
      end
      return header
    end,
    -- If image paths are relative then prepend include file path
    Image = function (image)
      if path.is_relative(image.src) then
        image.src = path.normalize(path.join({include_path, image.src}))
      end
      return image
    end,
    -- Update path for include-code-files.lua filter style CodeBlocks
    CodeBlock = function (cb)
      if cb.attributes.include and path.is_relative(cb.attributes.include) then
        cb.attributes.include =
          path.normalize(path.join({include_path, cb.attributes.include}))
      end
      return cb
    end
  }

  return pandoc.walk_block(pandoc.Div(blocks), update_contents_filter).content
end

--- Filter function for code blocks
local transclude
function transclude (cb, parent_file)
  -- ignore code blocks which are not of class "include".
  if not cb.classes:includes 'include' then
    return
  end

  -- Markdown is used if this is nil.
  local format = cb.attributes['format']

  -- Attributes shift headings
  local shift_heading_level_by = 0
  local shift_input = cb.attributes['shift-heading-level-by']
  if shift_input then
    shift_heading_level_by = tonumber(shift_input)
  else
    if include_auto then
      -- Auto shift headings
      shift_heading_level_by = last_heading_level
    end
  end

  --- keep track of level before recusion
  local buffer_last_heading_level = last_heading_level

  local blocks = List:new()
  for line in cb.text:gmatch('[^\n]+') do
    if line:sub(1,2) ~= '//' then
      -- resolve path relative to parent file
      local resolved_path = path.is_absolute(line) and 
                          line or 
                          path.normalize(path.join({parent_file and path.directory(parent_file) or ".", line}))

      local fh = io.open(resolved_path)
      if not fh then
        warn("Cannot open file " .. resolved_path .. " | Skipping includes")
      else
        -- read file as the given format with global reader options
        local contents = pandoc.read(
          fh:read '*a',
          format,
          PANDOC_READER_OPTIONS
        ).blocks
        last_heading_level = 0
        
        -- recursive transclusion with current file as parent
        contents = pandoc.walk_block(
          pandoc.Div(contents),
          { 
            Header = update_last_level, 
            CodeBlock = function(cb) 
              return transclude(cb, resolved_path) 
            end 
          }
        ).content
        --- reset to level before recursion
        last_heading_level = buffer_last_heading_level
        blocks:extend(update_contents(contents, shift_heading_level_by,
                                    path.directory(resolved_path)))
        fh:close()
      end
    end
  end
  return blocks
end

-- Wrapper for top-level transclusion
local function transclude_top(cb)
  local parent_file = PANDOC_STATE.input_files[1]
  return transclude(cb, parent_file or ".")
end

return {
  { Meta = get_vars },
  { Header = update_last_level, CodeBlock = transclude_top }
}
