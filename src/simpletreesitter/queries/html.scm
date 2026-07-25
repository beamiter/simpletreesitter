; ----- comments / doctype -----
(comment) @comment
(doctype) @keyword

; ----- tags -----
(tag_name) @type
(erroneous_end_tag_name) @constant

; ----- attributes -----
(attribute_name) @property
(attribute_value) @string
(quoted_attribute_value) @string

; ----- entities -----
(entity) @string.escape

; ----- punctuation -----
[
  "<"
  ">"
  "</"
  "/>"
] @punctuation.bracket

"=" @operator
