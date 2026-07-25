; 表头作为容器
(table (bare_key) @symbol.namespace)
(table (dotted_key) @symbol.namespace)
(table (quoted_key) @symbol.namespace)
(table_array_element (bare_key) @symbol.namespace)
(table_array_element (dotted_key) @symbol.namespace)
(table_array_element (quoted_key) @symbol.namespace)

; 键值对
(pair (bare_key) @symbol.property)
(pair (quoted_key) @symbol.property)
(pair (dotted_key) @symbol.property)
