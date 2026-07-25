; ----- comments -----
(comment) @comment
(js_comment) @comment

; ----- selectors -----
(tag_name) @type
(class_name) @property
(id_name) @constant
(namespace_name) @namespace
(universal_selector) @operator
(nesting_selector) @operator
(attribute_name) @property
(pseudo_class_selector (class_name) @function)
(pseudo_element_selector (tag_name) @function)

; ----- properties and values -----
(property_name) @field
(feature_name) @field
(function_name) @function
(plain_value) @variable
(keyframes_name) @constant
(keyword_query) @keyword

(string_value) @string
(color_value) @constant.builtin
(integer_value) @number
(float_value) @number
(unit) @type.builtin
(important) @keyword
(at_keyword) @keyword

[
  "@media"
  "@import"
  "@charset"
  "@namespace"
  "@supports"
  "@keyframes"
] @keyword

(to) @keyword
(from) @keyword

; ----- operators / punctuation -----
[
  ","
  ";"
  ":"
  "::"
] @punctuation.delimiter

[
  "{"
  "}"
  "("
  ")"
  "["
  "]"
] @punctuation.bracket
