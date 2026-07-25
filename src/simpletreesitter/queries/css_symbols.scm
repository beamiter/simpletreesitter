; rule sets: capture the selectors as outline entries
(stylesheet
  (rule_set (selectors) @symbol.class))

; nested rules (media queries, supports, ...)
(block
  (rule_set (selectors) @symbol.class))

; keyframes
(keyframes_statement
  (keyframes_name) @symbol.function)
