; ----- comments -----
(comment) @comment

; ----- strings -----
(interpreted_string_literal) @string
(raw_string_literal) @string
(rune_literal) @string
(escape_sequence) @string.escape

; ----- numbers / booleans / nil -----
(int_literal) @number
(float_literal) @number
(imaginary_literal) @number
(true) @boolean
(false) @boolean
(nil) @constant
(iota) @constant

; ----- identifiers -----
(identifier) @variable
(field_identifier) @property
(package_identifier) @namespace
(type_identifier) @type
(label_name) @variable

; ----- keywords -----
"break" @keyword
"case" @keyword
"chan" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"defer" @keyword
"else" @keyword
"fallthrough" @keyword
"for" @keyword
"func" @keyword
"go" @keyword
"goto" @keyword
"if" @keyword
"import" @keyword
"interface" @keyword
"map" @keyword
"package" @keyword
"range" @keyword
"return" @keyword
"select" @keyword
"struct" @keyword
"switch" @keyword
"type" @keyword
"var" @keyword

; ----- operators -----
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"&" @operator
"|" @operator
"^" @operator
"<<" @operator
">>" @operator
"&^" @operator
"==" @operator
"!=" @operator
"<" @operator
"<=" @operator
">" @operator
">=" @operator
"&&" @operator
"||" @operator
"!" @operator
"<-" @operator
"++" @operator
"--" @operator
"=" @keyword.operator
":=" @keyword.operator
"+=" @keyword.operator
"-=" @keyword.operator
"*=" @keyword.operator
"/=" @keyword.operator
"%=" @keyword.operator
"&=" @keyword.operator
"|=" @keyword.operator
"^=" @keyword.operator
"<<=" @keyword.operator
">>=" @keyword.operator
"&^=" @keyword.operator
"..." @operator

; ----- punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
":" @punctuation.delimiter

; ----- functions / methods -----
(function_declaration name: (identifier) @function)
(method_declaration name: (field_identifier) @method)
(call_expression function: (identifier) @function)
(call_expression function: (selector_expression field: (field_identifier) @method))

; ----- types -----
(type_spec name: (type_identifier) @type)
(type_alias name: (type_identifier) @type)

; ----- builtins -----
((identifier) @function.builtin
  (#match? @function.builtin "^(append|cap|close|complex|copy|delete|imag|len|make|max|min|new|panic|print|println|real|recover|clear)$"))
