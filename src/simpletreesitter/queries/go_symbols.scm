; functions
(function_declaration name: (identifier) @symbol.function)

; methods
(method_declaration name: (field_identifier) @symbol.method)

; types (struct, interface, type alias)
(type_spec name: (type_identifier) @symbol.type)
(type_alias name: (type_identifier) @symbol.type)

; constants
(const_spec name: (identifier) @symbol.const)

; package-level variables
(var_spec name: (identifier) @symbol.variable)

; struct fields
(field_declaration name: (field_identifier) @symbol.field)
