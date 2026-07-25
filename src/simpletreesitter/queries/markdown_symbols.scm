; ATX headings: level maps to a symbol kind so the outline shows hierarchy.
(atx_heading (atx_h1_marker) heading_content: (inline) @symbol.namespace)
(atx_heading (atx_h2_marker) heading_content: (inline) @symbol.class)
(atx_heading (atx_h3_marker) heading_content: (inline) @symbol.method)
(atx_heading (atx_h4_marker) heading_content: (inline) @symbol.field)
(atx_heading (atx_h5_marker) heading_content: (inline) @symbol.property)
(atx_heading (atx_h6_marker) heading_content: (inline) @symbol.variable)

; Setext headings (underlined with === or ---).
(setext_heading
  heading_content: (paragraph (inline) @symbol.namespace)
  (setext_h1_underline))
(setext_heading
  heading_content: (paragraph (inline) @symbol.class)
  (setext_h2_underline))
