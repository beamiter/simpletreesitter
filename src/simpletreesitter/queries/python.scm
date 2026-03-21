; ----- comments -----
(comment) @comment

; ----- strings -----
(string) @string
(concatenated_string) @string
(escape_sequence) @string.escape
(interpolation) @string.special
(format_expression) @string.special

; ----- numbers / booleans / none -----
(integer) @number
(float) @number
(true) @boolean
(false) @boolean
(none) @constant
(ellipsis) @constant

; ----- identifiers -----
(identifier) @variable

; ----- keywords -----
"and" @keyword
"as" @keyword
"assert" @keyword
"async" @keyword
"await" @keyword
"break" @keyword
"class" @keyword
"continue" @keyword
"def" @keyword
"del" @keyword
"elif" @keyword
"else" @keyword
"except" @keyword
"finally" @keyword
"for" @keyword
"from" @keyword
"global" @keyword
"if" @keyword
"import" @keyword
"in" @keyword
"is" @keyword
"lambda" @keyword
"nonlocal" @keyword
"not" @keyword
"or" @keyword
"pass" @keyword
"raise" @keyword
"return" @keyword
"try" @keyword
"while" @keyword
"with" @keyword
"yield" @keyword
"match" @keyword
"case" @keyword
"type" @keyword

; ----- operators -----
"+" @operator
"-" @operator
"*" @operator
"**" @operator
"/" @operator
"//" @operator
"%" @operator
"|" @operator
"&" @operator
"^" @operator
"~" @operator
"<<" @operator
">>" @operator
"<" @operator
">" @operator
"<=" @operator
">=" @operator
"==" @operator
"!=" @operator
"=" @keyword.operator
"+=" @keyword.operator
"-=" @keyword.operator
"*=" @keyword.operator
"/=" @keyword.operator
"//=" @keyword.operator
"%=" @keyword.operator
"**=" @keyword.operator
"|=" @keyword.operator
"&=" @keyword.operator
"^=" @keyword.operator
"<<=" @keyword.operator
">>=" @keyword.operator
":=" @keyword.operator
"->" @operator

; ----- punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"," @punctuation.delimiter
":" @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
"@" @punctuation.delimiter

; ----- functions / methods / classes -----
(function_definition name: (identifier) @function)
(class_definition name: (identifier) @type)
(decorator (identifier) @function)
(decorator (attribute attribute: (identifier) @function))

(call function: (identifier) @function)
(call function: (attribute attribute: (identifier) @method))

; ----- parameters -----
(parameters (identifier) @variable.parameter)
(default_parameter name: (identifier) @variable.parameter)
(typed_parameter (identifier) @variable.parameter)
(typed_default_parameter name: (identifier) @variable.parameter)
(lambda_parameters (identifier) @variable.parameter)

; ----- builtins -----
((identifier) @variable.builtin
  (#match? @variable.builtin "^(self|cls)$"))

((identifier) @function.builtin
  (#match? @function.builtin "^(print|len|range|type|int|str|float|list|dict|set|tuple|bool|input|open|map|filter|zip|enumerate|sorted|reversed|sum|min|max|abs|round|any|all|isinstance|issubclass|hasattr|getattr|setattr|delattr|repr|id|hash|hex|oct|bin|chr|ord|super|property|staticmethod|classmethod)$"))

((identifier) @constant.builtin
  (#match? @constant.builtin "^(NotImplemented|Ellipsis|__name__|__file__|__doc__|__debug__|__package__|__spec__|__loader__|__builtins__)$"))

; ----- properties / attributes -----
(attribute attribute: (identifier) @property)
(keyword_argument name: (identifier) @property)
