local M = {}
function M.randomCitizenId(prefix)
  prefix = prefix or 'EXEC'
  local t = {}
  for i=1,8 do t[i] = string.char(math.random(48,57)) end
  return string.format('%s%s', prefix, table.concat(t))
end
function M.sanitizeName(s)
  s = (s or ''):gsub('[^%w%-_ ]',''):sub(1, 20)
  return s
end
return M
