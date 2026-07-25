; ----- comments (JSONC) -----
(comment) @comment

; ----- keys -----
(pair key: (string (string_content) @property))

; ----- values -----
(string) @string
(escape_sequence) @string.escape
(number) @number
(true) @boolean
(false) @boolean
(null) @constant

; ----- punctuation -----
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"," @punctuation.delimiter
":" @punctuation.delimiter
