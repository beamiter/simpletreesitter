; functions
(function_declaration name: (identifier) @symbol.function)
(function_signature name: (identifier) @symbol.function)

; classes / interfaces / type aliases / enums / namespaces
(class_declaration name: (type_identifier) @symbol.class)
(abstract_class_declaration name: (type_identifier) @symbol.class)
(interface_declaration name: (type_identifier) @symbol.type)
(type_alias_declaration name: (type_identifier) @symbol.type)
(enum_declaration name: (identifier) @symbol.enum)
(internal_module name: (identifier) @symbol.namespace)

; class / interface members
(method_definition name: (property_identifier) @symbol.method)
(method_signature name: (property_identifier) @symbol.method)
(abstract_method_signature name: (property_identifier) @symbol.method)
(public_field_definition name: (property_identifier) @symbol.field)
(property_signature name: (property_identifier) @symbol.field)

; enum members
(enum_body (property_identifier) @symbol.variant)
(enum_assignment name: (property_identifier) @symbol.variant)

; top-level variables (including exported ones)
(program
  (variable_declaration
    (variable_declarator name: (identifier) @symbol.variable)))
(program
  (lexical_declaration
    (variable_declarator name: (identifier) @symbol.variable)))
(program
  (export_statement
    (variable_declaration
      (variable_declarator name: (identifier) @symbol.variable))))
(program
  (export_statement
    (lexical_declaration
      (variable_declarator name: (identifier) @symbol.variable))))
