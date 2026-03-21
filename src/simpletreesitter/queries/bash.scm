; ----- comments -----
(comment) @comment

; ----- strings -----
(string) @string
(raw_string) @string
(ansi_c_string) @string
(heredoc_body) @string
(heredoc_start) @string
(heredoc_end) @string
(string_content) @string
(translated_string) @string

; ----- numbers -----
(number) @number

; ----- variables -----
(variable_name) @variable
(special_variable_name) @variable.builtin
(simple_expansion) @variable
(expansion) @variable

; ----- keywords -----
"if" @keyword
"then" @keyword
"else" @keyword
"elif" @keyword
"fi" @keyword
"for" @keyword
"in" @keyword
"do" @keyword
"done" @keyword
"while" @keyword
"until" @keyword
"case" @keyword
"esac" @keyword
"function" @keyword
"select" @keyword
"declare" @keyword
"typeset" @keyword
"export" @keyword
"readonly" @keyword
"local" @keyword
"unset" @keyword
"unsetenv" @keyword

; ----- operators -----
"=" @keyword.operator
"+=" @keyword.operator
"=~" @operator
"==" @operator
"!=" @operator
"<" @operator
">" @operator
"&&" @operator
"||" @operator
"|" @operator
"!" @operator

; ----- punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
";;" @punctuation.delimiter
";" @punctuation.delimiter

; ----- redirections -----
(file_redirect) @operator
(heredoc_redirect) @operator

; ----- functions / commands -----
(function_definition name: (word) @function)
(command name: (command_name) @function)

; ----- test operators -----
(test_operator) @operator
