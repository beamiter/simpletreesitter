; functions
(function_definition name: (identifier) @symbol.function)

; classes
(class_definition name: (identifier) @symbol.class)

; methods (inside class)
(class_definition
  body: (block
    (function_definition
      name: (identifier) @symbol.method)))

; decorated definitions
(decorated_definition
  definition: (function_definition
    name: (identifier) @symbol.function))

(decorated_definition
  definition: (class_definition
    name: (identifier) @symbol.class))

; module-level assignments (variables)
(module
  (expression_statement
    (assignment
      left: (identifier) @symbol.variable)))

; type alias
(type_alias_statement
  left: (type) @symbol.type)
