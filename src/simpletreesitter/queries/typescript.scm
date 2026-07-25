; ----- comments -----
(comment) @comment

; ----- strings / regex / escapes -----
(string) @string
(template_string) @string
(escape_sequence) @string.escape
(regex) @string.regex
(template_substitution) @string.special

; ----- numbers / booleans / null -----
(number) @number
(true) @boolean
(false) @boolean
(null) @constant
(undefined) @constant

; ----- this 表达式 -----
(this) @variable.builtin

; ----- keywords -----
"var" @keyword
"let" @keyword
"const" @keyword
"function" @keyword
"return" @keyword
"if" @keyword
"else" @keyword
"for" @keyword
"while" @keyword
"do" @keyword
"switch" @keyword
"case" @keyword
"break" @keyword
"continue" @keyword
"new" @keyword
"try" @keyword
"catch" @keyword
"finally" @keyword
"throw" @keyword
"class" @keyword
"extends" @keyword
(super) @keyword
"import" @keyword
"from" @keyword
"export" @keyword
"default" @keyword
"in" @keyword
"of" @keyword
"instanceof" @keyword
"typeof" @keyword
"void" @keyword
"delete" @keyword
"yield" @keyword
"await" @keyword
"async" @keyword
"static" @keyword
"get" @keyword
"set" @keyword
"debugger" @keyword
"with" @keyword

; ----- TypeScript keywords -----
"interface" @keyword
"type" @keyword
"enum" @keyword
"namespace" @keyword
"module" @keyword
"declare" @keyword
"readonly" @keyword
"abstract" @keyword
"private" @keyword
"public" @keyword
"protected" @keyword
"override" @keyword
"implements" @keyword
"keyof" @keyword.operator
"as" @keyword.operator
"satisfies" @keyword.operator
"is" @keyword.operator
"infer" @keyword.operator
"asserts" @keyword

; ----- operators -----
"=" @keyword.operator
"+=" @keyword.operator
"-=" @keyword.operator
"*=" @keyword.operator
"/=" @keyword.operator
"%=" @keyword.operator
"**=" @keyword.operator
"==" @operator
"===" @operator
"!=" @operator
"!==" @operator
"<" @operator
"<=" @operator
">" @operator
">=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"**" @operator
"&&" @operator
"||" @operator
"!" @operator
"??" @operator
"??=" @keyword.operator
"&&=" @keyword.operator
"||=" @keyword.operator
"=>" @operator
"|" @operator
"&" @operator

; ----- punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket

"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
":" @punctuation.delimiter
"?" @punctuation.delimiter

; ----- types -----
(type_identifier) @type
(predefined_type) @type.builtin

; ----- decorators -----
(decorator) @attribute

; ----- functions / methods / classes -----
(function_declaration name: (identifier) @function)
(function_expression name: (identifier) @function)
(function_signature name: (identifier) @function)
(method_definition name: (property_identifier) @method)
(method_signature name: (property_identifier) @method)
(abstract_method_signature name: (property_identifier) @method)
(class_declaration name: (type_identifier) @type)
(abstract_class_declaration name: (type_identifier) @type)
(interface_declaration name: (type_identifier) @type)
(type_alias_declaration name: (type_identifier) @type)
(enum_declaration name: (identifier) @type)
(internal_module name: (identifier) @namespace)

; 箭头函数赋值给变量
(lexical_declaration
  (variable_declarator
    name: (identifier) @function
    value: (arrow_function)))

(variable_declaration
  (variable_declarator
    name: (identifier) @function
    value: (arrow_function)))

; 函数调用
(call_expression function: (identifier) @function)
(call_expression function: (member_expression property: (property_identifier) @method))

; ----- parameters -----
(required_parameter pattern: (identifier) @variable.parameter)
(required_parameter pattern: (rest_pattern (identifier) @variable.parameter))
(optional_parameter pattern: (identifier) @variable.parameter)
(arrow_function parameter: (identifier) @variable.parameter)

; ----- properties / fields -----
(pair key: (property_identifier) @property)
(pair key: (string (string_fragment) @property))
(member_expression property: (property_identifier) @property)
(property_signature name: (property_identifier) @property)
(public_field_definition name: (property_identifier) @field)
(enum_assignment name: (property_identifier) @constant)

; ----- builtins -----
((identifier) @variable.builtin
  (#match? @variable.builtin "^(undefined|arguments|NaN|Infinity)$"))

((identifier) @constant.builtin
  (#match? @constant.builtin "^(console|JSON|Math|Date|Number|String|Boolean|Array|Object|RegExp|Error|Promise|Symbol|BigInt|Map|Set|WeakMap|WeakSet|Proxy|Reflect|globalThis|window|document)$"))

; ----- fallback -----
(identifier) @variable
(property_identifier) @property
(shorthand_property_identifier) @property
