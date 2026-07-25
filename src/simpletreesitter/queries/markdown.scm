; ----- headings -----
(atx_heading) @text.title
(setext_heading) @text.title

; ----- code blocks -----
(fenced_code_block_delimiter) @punctuation.delimiter
(info_string (language) @type)
(code_fence_content) @text.literal
(indented_code_block) @text.literal

; ----- block quotes / lists -----
(block_quote_marker) @punctuation.delimiter
[
  (list_marker_minus)
  (list_marker_plus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
] @punctuation.delimiter
(task_list_marker_checked) @boolean
(task_list_marker_unchecked) @boolean

; ----- thematic break -----
(thematic_break) @punctuation.delimiter

; ----- link reference definitions -----
(link_reference_definition
  (link_label) @property
  (link_destination) @text.uri)
(link_title) @string

; ----- tables (GFM) -----
(pipe_table_header (pipe_table_cell) @text.strong)
(pipe_table_delimiter_row) @punctuation.delimiter

; ----- escapes / entities -----
(backslash_escape) @string.escape
(entity_reference) @string.escape
(numeric_character_reference) @string.escape

; ----- frontmatter -----
(minus_metadata) @comment
(plus_metadata) @comment
