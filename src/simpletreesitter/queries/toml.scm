; ----- comments -----
(comment) @comment

; ----- table headers -----
(table (bare_key) @namespace)
(table (dotted_key) @namespace)
(table (quoted_key) @namespace)
(table_array_element (bare_key) @namespace)
(table_array_element (dotted_key) @namespace)
(table_array_element (quoted_key) @namespace)

; ----- keys -----
(pair (bare_key) @property)
(pair (quoted_key) @property)
(pair (dotted_key (bare_key) @property))
(pair (dotted_key (quoted_key) @property))

; ----- values -----
(string) @string
(escape_sequence) @string.escape
(integer) @number
(float) @number
(boolean) @boolean
(offset_date_time) @string.special
(local_date_time) @string.special
(local_date) @string.special
(local_time) @string.special

; ----- punctuation -----
"=" @keyword.operator
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"[[" @punctuation.bracket
"]]" @punctuation.bracket
"," @punctuation.delimiter
"." @punctuation.delimiter
