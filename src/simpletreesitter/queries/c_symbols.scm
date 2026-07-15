; functions
(function_definition
  declarator: (function_declarator
                declarator: (identifier) @symbol.function))

; typedef aliases (the target may be a primitive, struct, enum, ...)
(type_definition declarator: (type_identifier) @symbol.type)

; structs
(struct_specifier name: (type_identifier) @symbol.struct)

; enums
(enum_specifier name: (type_identifier) @symbol.enum)
