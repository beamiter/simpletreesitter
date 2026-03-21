; 函数定义（自由函数）
(function_definition
  declarator: (function_declarator
    declarator: (identifier) @symbol.function))

; 成员函数定义（类外定义：Class::method）
(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (identifier) @symbol.method)))

; 成员函数声明（类内原型）
(field_declaration
  declarator: (function_declarator
    declarator: (field_identifier) @symbol.method))

; 函数原型（自由函数原型）
(declaration
  declarator: (function_declarator
    declarator: (identifier) @symbol.function))

; 类 / 结构体 / 枚举
(class_specifier
  name: (type_identifier) @symbol.class)

(struct_specifier
  name: (type_identifier) @symbol.struct)

(enum_specifier
  name: (type_identifier) @symbol.enum)

; 命名空间（修正为 namespace_identifier）
(namespace_definition
  name: (namespace_identifier) @symbol.namespace)

; 模板声明（提取内部的函数/类名）
(template_declaration
  (function_definition
    declarator: (function_declarator
      declarator: (identifier) @symbol.function)))

(template_declaration
  (class_specifier
    name: (type_identifier) @symbol.class))

(template_declaration
  (struct_specifier
    name: (type_identifier) @symbol.struct))

; 类型别名 using X = ...
(alias_declaration
  name: (type_identifier) @symbol.type)

; 变量声明（只抓 identifier）
(declaration
  declarator: (init_declarator
    declarator: (identifier) @symbol.variable))
