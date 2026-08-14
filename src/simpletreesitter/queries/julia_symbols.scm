(function_definition
  (signature
    (identifier) @symbol.function))

(function_definition
  (signature
    (call_expression
      .
      (identifier) @symbol.function)))

(macro_definition
  (signature
    (identifier) @symbol.macro))

(macro_definition
  (signature
    (call_expression
      .
      (identifier) @symbol.macro)))

(struct_definition
  (type_head
    (identifier) @symbol.struct))

(abstract_definition
  (type_head
    (identifier) @symbol.type))

(primitive_definition
  (type_head
    (identifier) @symbol.type))

(module_definition
  name: (identifier) @symbol.namespace)
