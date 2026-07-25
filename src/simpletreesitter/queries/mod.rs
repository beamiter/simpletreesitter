pub const RUST_QUERY: &str = include_str!("rust.scm");
pub const JS_QUERY: &str = include_str!("javascript.scm");
pub const C_QUERY: &str = include_str!("c.scm");
pub const CPP_QUERY: &str = include_str!("cpp.scm");
pub const PYTHON_QUERY: &str = include_str!("python.scm");
pub const GO_QUERY: &str = include_str!("go.scm");
pub const BASH_QUERY: &str = include_str!("bash.scm");

pub const RUST_SYM_QUERY: &str = include_str!("rust_symbols.scm");
pub const JS_SYM_QUERY: &str = include_str!("js_symbols.scm");
pub const C_SYM_QUERY: &str = include_str!("c_symbols.scm");
pub const CPP_SYM_QUERY: &str = include_str!("cpp_symbols.scm");
pub const PYTHON_SYM_QUERY: &str = include_str!("python_symbols.scm");
pub const GO_SYM_QUERY: &str = include_str!("go_symbols.scm");
pub const BASH_SYM_QUERY: &str = include_str!("bash_symbols.scm");

pub const VIM_QUERY: &str = include_str!("vim.scm");
pub const VIM_SYM_QUERY: &str = include_str!("vim_symbols.scm");

pub const TS_QUERY: &str = include_str!("typescript.scm");
// TSX 语法是 TypeScript 的超集：先编译共享查询，再追加 JSX 专属模式。
pub const TSX_QUERY: &str = concat!(
    include_str!("typescript.scm"),
    include_str!("tsx_extra.scm")
);
pub const TS_SYM_QUERY: &str = include_str!("typescript_symbols.scm");
pub const JSON_QUERY: &str = include_str!("json.scm");
pub const JSON_SYM_QUERY: &str = include_str!("json_symbols.scm");
pub const YAML_QUERY: &str = include_str!("yaml.scm");
pub const YAML_SYM_QUERY: &str = include_str!("yaml_symbols.scm");
pub const TOML_QUERY: &str = include_str!("toml.scm");
pub const TOML_SYM_QUERY: &str = include_str!("toml_symbols.scm");
