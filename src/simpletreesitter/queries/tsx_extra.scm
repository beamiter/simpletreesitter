; TSX 专属：JSX 高亮（追加在 typescript.scm 之后编译）
(jsx_opening_element name: (identifier) @type)
(jsx_closing_element name: (identifier) @type)
(jsx_self_closing_element name: (identifier) @type)
(jsx_attribute (property_identifier) @property)
(jsx_expression) @string.special
(jsx_text) @string
