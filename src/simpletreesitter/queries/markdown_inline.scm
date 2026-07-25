; ----- code spans -----
(code_span) @text.literal
(code_span_delimiter) @punctuation.delimiter

; ----- emphasis -----
(emphasis) @text.emphasis
(strong_emphasis) @text.strong
(emphasis_delimiter) @punctuation.delimiter
(strikethrough) @text.strike

; ----- links -----
(inline_link (link_text) @text.reference)
(inline_link (link_destination) @text.uri)
(image (image_description) @text.reference)
(image (link_destination) @text.uri)
(full_reference_link (link_text) @text.reference)
(full_reference_link (link_label) @property)
(collapsed_reference_link (link_text) @text.reference)
(shortcut_link (link_text) @text.reference)
(link_title) @string
(uri_autolink) @text.uri
(email_autolink) @text.uri

; ----- escapes / entities -----
(backslash_escape) @string.escape
(entity_reference) @string.escape
(numeric_character_reference) @string.escape
