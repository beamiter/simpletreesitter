; ----- comments -----
(comment) @comment

; ----- mapping keys -----
(block_mapping_pair
  key: (flow_node (plain_scalar (string_scalar) @property)))
(block_mapping_pair
  key: (flow_node (double_quote_scalar) @property))
(block_mapping_pair
  key: (flow_node (single_quote_scalar) @property))
(flow_pair
  key: (flow_node (plain_scalar (string_scalar) @property)))

; ----- scalars -----
(string_scalar) @string
(double_quote_scalar) @string
(single_quote_scalar) @string
(block_scalar) @string
(escape_sequence) @string.escape
(integer_scalar) @number
(float_scalar) @number
(boolean_scalar) @boolean
(null_scalar) @constant
(timestamp_scalar) @string.special

; ----- anchors / aliases / tags -----
(anchor) @constant.builtin
(alias) @constant.builtin
(tag) @type

; ----- directives -----
(yaml_directive) @keyword
(tag_directive) @keyword
(reserved_directive) @keyword

; ----- punctuation -----
"-" @punctuation.delimiter
":" @punctuation.delimiter
"," @punctuation.delimiter
"?" @punctuation.delimiter
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
