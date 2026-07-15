; Vim9 symbols for your custom grammar (grammar.js)

; 函数（Vim9: def ... enddef）
; grammar.js: def_function 直接包含 (identifier)
(def_function (identifier) @symbol.function)

; 变量/常量声明（顶层或函数内）
(let_statement   (identifier) @symbol.variable)
(const_statement (identifier) @symbol.const)

; Scope/option references are intentionally not outline symbols. Declarations
; that the grammar currently treats as generic commands are recovered by the
; daemon's Vim declaration fallback.
