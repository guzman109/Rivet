-- Names are emitted unescaped in imports, declarations, and native manifests.
-- Keep language keywords separate; a Python name need not be a Rust identifier.
local M = {}
local words = {
  python = 'False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield',
  rust = 'as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while abstract become box do final macro override priv try typeof unsized virtual yield',
  swift = 'associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any false is nil self Self super throws true try',
  c = 'auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while alignas alignof bool constexpr false nullptr static_assert thread_local true typeof typeof_unqual',
}
local keywords = {}
for language, list in pairs(words) do
  keywords[language] = {}
  for word in list:gmatch('%S+') do
    keywords[language][word] = true
  end
end
function M.validate(language, value, edition)
  assert(
    type(value) == 'string' and value:match('^[A-Za-z][A-Za-z0-9_]*$'),
    'Use a letter followed by letters, digits, or underscores'
  )
  local reserved = keywords[language][value]
    or language == 'rust' and tostring(edition or '2024') == '2024' and value == 'gen'
  assert(not reserved, 'Reserved ' .. language .. ' keyword: ' .. value)
  return value
end
return M
