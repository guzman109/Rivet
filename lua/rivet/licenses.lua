-- Shared, offline license choices for every language provider.
local M = {}
M.choices = {
  {
    id = 'none',
    label = 'No license yet',
    description = 'Create no license file. This does not grant open-source permissions.',
  },
  {
    id = 'MIT',
    label = 'MIT',
    description = 'Permissive; retain the copyright and license notice.',
  },
  {
    id = 'Apache-2.0',
    label = 'Apache 2.0',
    description = 'Permissive, with an explicit patent grant and notice requirements.',
  },
  {
    id = 'BSD-3-Clause',
    label = 'BSD 3-Clause',
    description = 'Permissive, with a non-endorsement clause.',
  },
  {
    id = 'GPL-3.0-only',
    label = 'GNU GPL v3 only',
    description = 'Copyleft; distributed covered derivatives must follow GPL v3.',
  },
}

function M.holder(value)
  assert(type(value) == 'string', 'Supply a copyright holder with --license-holder')
  value = value:match('^%s*(.-)%s*$')
  assert(
    value ~= ''
      and #value <= 256
      and not value:find('[%c]')
      and not value:find('*/', 1, true)
      and not value:match('\\$'),
    'Copyright holder must be non-empty, single-line text'
  )
  return value
end

function M.year(value)
  value = tostring(value or os.date('%Y'))
  assert(
    value:match('^%d%d%d%d$') and tonumber(value) >= 1000,
    'License year must contain four digits'
  )
  return value
end

function M.normalize(value, holder, year)
  if value == nil then
    value = 'none'
  end
  if type(value) == 'table' then
    holder, year, value = value.holder, value.year, value.id
  end
  local found = false
  for _, item in ipairs(M.choices) do
    found = found or item.id == value
  end
  assert(found, 'Choose none, MIT, Apache-2.0, BSD-3-Clause, or GPL-3.0-only')
  if value == 'none' then
    return { id = 'none' }
  end
  return { id = value, holder = M.holder(holder), year = M.year(year) }
end

function M.options(opts)
  local result = {}
  for key, value in pairs(opts) do
    result[key] = value
  end
  result.license = M.normalize(opts.license, opts.license_holder, opts.license_year)
  result.license_holder, result.license_year = nil, nil
  if result.license.id ~= 'none' and opts.comment_header then
    result.comment_header = {}
    for key, value in pairs(opts.comment_header) do
      result.comment_header[key] = value
    end
    if not result.comment_header.license or result.comment_header.license == '' then
      result.comment_header.license = result.license.id
    end
    if not result.comment_header.copyright or result.comment_header.copyright == '' then
      result.comment_header.copyright = result.license.year .. ' ' .. result.license.holder
    end
  end
  return result
end

function M.files(value)
  local config = M.normalize(value)
  if config.id == 'none' then
    return {}
  end
  local text = assert(require('rivet.license_texts')[config.id])
  if config.id == 'MIT' or config.id == 'BSD-3-Clause' then
    -- Function replacements preserve literal percent signs in supplied names.
    text = text
      :gsub('<year>', function()
        return config.year
      end)
      :gsub('<copyright holders>', function()
        return config.holder
      end)
      :gsub('<owner>', function()
        return config.holder
      end)
  end
  local files = { LICENSE = text }
  if config.id == 'Apache-2.0' or config.id == 'GPL-3.0-only' then
    files.NOTICE = 'Copyright (c) '
      .. config.year
      .. ' '
      .. config.holder
      .. '\nSPDX-License-Identifier: '
      .. config.id
      .. '\n\n'
      .. (config.id == 'GPL-3.0-only' and 'This project is licensed under version 3 only of the GNU General Public License.\n' or 'This project is licensed under the Apache License, Version 2.0.\n')
      .. 'See LICENSE for the full terms.\n'
  end
  return files
end

function M.questions(spec)
  return {
    { key = 'license', title = 'Project license', items = M.choices },
    {
      key = 'license_holder',
      title = 'Copyright holder (person or organization)',
      input = true,
      default = '',
      when = function()
        return spec.license ~= 'none'
      end,
      validate = M.holder,
    },
    {
      key = 'license_year',
      title = 'Copyright year',
      input = true,
      default = os.date('%Y'),
      when = function()
        return spec.license ~= 'none'
      end,
      validate = M.year,
    },
    {
      key = '_license_review',
      title = 'Review project license',
      when = function()
        return spec.license ~= 'none'
      end,
      items = function()
        local config = M.normalize(spec.license, spec.license_holder, spec.license_year)
        local files = M.files(config)
        return {
          {
            id = true,
            label = 'Use ' .. config.id,
            description = 'Included in the final project review before any files are written. Backspace changes your choice.',
            preview = files.LICENSE
              .. (files.NOTICE and '\n--- NOTICE ---\n' .. files.NOTICE or ''),
          },
        }
      end,
    },
  }
end

return M
