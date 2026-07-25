; headings make natural outline anchors
((tag_name) @symbol.class
  (#match? @symbol.class "^[hH][1-6]$"))

; top-level structural containers
(document
  (element
    (start_tag (tag_name) @symbol.namespace)))

; script / style blocks
(script_element
  (start_tag (tag_name) @symbol.function))
(style_element
  (start_tag (tag_name) @symbol.function))
