; ----- comments -----
(comment) @comment
(hash_bang_line) @comment

; ----- strings -----
(string) @string
(escape_sequence) @string.escape

; ----- literals -----
(number) @number
(true) @boolean
(false) @boolean
(nil) @constant.builtin
(vararg_expression) @constant.builtin

; ----- keywords -----
[
  "local"
  "function"
  "end"
  "do"
  "if"
  "then"
  "else"
  "elseif"
  "for"
  "in"
  "while"
  "repeat"
  "until"
  "return"
  "goto"
] @keyword

(break_statement) @keyword

[
  "and"
  "or"
  "not"
] @keyword.operator

; ----- operators -----
(binary_expression operator: _ @operator)
(unary_expression operator: _ @operator)
"=" @operator

; ----- punctuation -----
[
  ";"
  ":"
  ","
  "."
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

; ----- functions -----
(function_declaration name: (identifier) @function)
(function_declaration
  name: (dot_index_expression field: (identifier) @function))
(function_declaration
  name: (method_index_expression method: (identifier) @method))
(function_call name: (identifier) @function)
(function_call
  name: (dot_index_expression field: (identifier) @function))
(function_call
  name: (method_index_expression method: (identifier) @method))

((function_call name: (identifier) @function.builtin)
  (#any-of? @function.builtin
    "assert" "error" "ipairs" "next" "pairs" "pcall" "print" "rawequal"
    "rawget" "rawlen" "rawset" "require" "select" "setmetatable"
    "getmetatable" "tonumber" "tostring" "type" "unpack" "xpcall"))

; ----- fields / properties -----
(field name: (identifier) @field)
(dot_index_expression field: (identifier) @property)

; ----- parameters and variables -----
(parameters name: (identifier) @variable.parameter)

((identifier) @variable.builtin
  (#eq? @variable.builtin "self"))

((identifier) @constant
  (#match? @constant "^[A-Z][A-Z_0-9]*$"))

(identifier) @variable
