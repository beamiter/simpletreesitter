; functions: function foo() / function M.foo() / local function foo()
(function_declaration name: (identifier) @symbol.function)
(function_declaration
  name: (dot_index_expression) @symbol.function)

; methods: function M:foo()
(function_declaration
  name: (method_index_expression) @symbol.method)

; assigned function values: local foo = function() ... end
(variable_declaration
  (assignment_statement
    (variable_list name: (identifier) @symbol.function)
    (expression_list value: (function_definition))))

; top-level local variables
(chunk
  (variable_declaration
    (assignment_statement
      (variable_list name: (identifier) @symbol.variable))))

; table fields holding functions: foo = function() ... end inside tables
(field
  name: (identifier) @symbol.method
  value: (function_definition))
