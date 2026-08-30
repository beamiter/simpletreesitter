use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::ops;
use tree_sitter::StreamingIterator;

mod queries;

const SUPPORTED_LANGUAGES: &[&str] = &[
    "rust",
    "javascript",
    "typescript",
    "tsx",
    "c",
    "cpp",
    "python",
    "go",
    "bash",
    "vim",
    "json",
    "yaml",
    "toml",
    "lua",
    "html",
    "css",
    "markdown",
    "julia",
    "haskell",
];
const PROTOCOL_VERSION: u32 = 7;

const MAX_AST_NODES: usize = 50_000;
const MAX_AST_DEPTH: usize = 512;
const MAX_AST_INDENT: usize = 80;
const MAX_SOURCE_BYTES: usize = 32 * 1024 * 1024;
const MAX_CACHED_BUFFERS: usize = 128;
const MAX_CACHED_SOURCE_BYTES: usize = 256 * 1024 * 1024;
const MAX_HIGHLIGHT_SPANS: usize = 100_000;
const MAX_SYMBOLS: usize = 100_000;
const MAX_FOLDS: usize = 50_000;
const LINE_INDEX_STRIDE: usize = 256;
/// Ancestors reported for one `scope` request. Deep enough for any real nesting
/// and shallow enough that a pathological tree cannot make an interactive
/// keystroke serialise an unbounded payload.
const MAX_SCOPE_CHAIN: usize = 256;
/// Injected ranges per buffer. Generous because markdown emits one `inline`
/// range per paragraph, and stingy enough that a pathological document cannot
/// make one sync parse an unbounded number of keyholes.
const MAX_INJECTED_RANGES: usize = 8_192;

fn default_true() -> bool {
    true
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// FNV-1a over the fields of a reply, used to answer "is this the same payload
/// I already sent you?" without sending it.
///
/// Written out rather than taken from `DefaultHasher` because the value goes on
/// the wire and comes back from the client: `SipHasher`'s per-process random
/// keys would make every digest a client saved across a daemon restart compare
/// unequal, and its exact output is explicitly not a stable API.
struct Fnv1a(u64);

impl Fnv1a {
    fn new() -> Self {
        Fnv1a(0xcbf2_9ce4_8422_2325)
    }

    fn bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x100_0000_01b3);
        }
    }

    fn u32(&mut self, value: u32) {
        self.bytes(&value.to_le_bytes());
    }

    /// Length-prefixed, so that ("ab", "c") and ("a", "bc") cannot collide —
    /// adjacent symbol names and kinds are exactly the fields most likely to
    /// shift a character across a boundary as the user types.
    fn str(&mut self, value: &str) {
        self.u32(value.len() as u32);
        self.bytes(value.as_bytes());
    }

    /// Decimal, and therefore never the empty string, which is the wire's
    /// "I hold no payload for this buffer".
    fn finish(self) -> String {
        self.0.to_string()
    }
}

fn digest_symbols(symbols: &[Symbol]) -> String {
    let mut hash = Fnv1a::new();
    hash.u32(symbols.len() as u32);
    for symbol in symbols {
        hash.str(&symbol.name);
        hash.str(symbol.kind);
        hash.u32(symbol.lnum);
        hash.u32(symbol.col);
        hash.u32(symbol.end_lnum);
        hash.u32(symbol.end_col);
        hash.str(symbol.container_kind.unwrap_or(""));
        hash.str(symbol.container_name.as_deref().unwrap_or(""));
        hash.u32(symbol.container_lnum.unwrap_or(0));
        hash.u32(symbol.container_col.unwrap_or(0));
    }
    hash.finish()
}

fn digest_folds(folds: &[Fold]) -> String {
    let mut hash = Fnv1a::new();
    hash.u32(folds.len() as u32);
    for fold in folds {
        hash.u32(fold.lnum);
        hash.u32(fold.end_lnum);
        hash.u32(fold.level);
    }
    hash.finish()
}

/// Split spans into a group-name dictionary and fixed-width rows.
///
/// Group names come from one static table, so the dictionary is at most the
/// size of that table however many spans there are.
fn compact_spans(spans: &[Span]) -> (Vec<&'static str>, Vec<[u32; 6]>) {
    let mut groups: Vec<&'static str> = Vec::new();
    let mut index: HashMap<&'static str, u32> = HashMap::new();
    let mut rows: Vec<[u32; 6]> = Vec::with_capacity(spans.len());
    for span in spans {
        let group = *index.entry(span.group).or_insert_with(|| {
            groups.push(span.group);
            (groups.len() - 1) as u32
        });
        rows.push([
            span.lnum,
            span.col,
            span.end_lnum,
            span.end_col,
            group,
            span.depth.unwrap_or(0),
        ]);
    }
    (groups, rows)
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "set_text")]
    SetText {
        buf: i64,
        lang: String,
        text: String,
        #[serde(default)]
        revision: u64,
    },
    #[serde(rename = "edit_lines")]
    EditLines {
        buf: i64,
        lang: String,
        #[serde(default)]
        revision: u64,
        /// 1-based first replaced line.
        lstart: u32,
        /// Exclusive 1-based end of the replaced old range.
        old_lend: u32,
        #[serde(default)]
        lines: Vec<String>,
        /// Expected total line count after the edit; a mismatch forces a full resync.
        line_count: u64,
        #[serde(default = "default_true")]
        eol: bool,
    },
    #[serde(rename = "highlight")]
    Highlight {
        buf: i64,
        lang: String,
        #[serde(default)]
        lstart: Option<u32>,
        #[serde(default)]
        lend: Option<u32>,
        #[serde(default = "default_true")]
        rainbow: bool,
        #[serde(default)]
        max_spans: Option<usize>,
        /// Ask for the protocol-v7 compact span encoding. Opt-in per request
        /// rather than negotiated in `hello`, so a client that downgrades mid
        /// session (or a second client on the same daemon) cannot be handed an
        /// encoding it does not parse.
        #[serde(default)]
        compact: bool,
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        lang: String,
        /// Client-generated correlation token. Protocol-v4 clients omit it
        /// and deserialize as zero; v5 clients use it to reject late replies.
        #[serde(default)]
        request_id: u64,
        #[serde(default)]
        lstart: Option<u32>,
        #[serde(default)]
        lend: Option<u32>,
        #[serde(default)]
        max_items: Option<usize>,
        /// Optional server-side kind filter. Applying it before `max_items`
        /// keeps a large run of non-navigation symbols from hiding a later
        /// structural symbol.
        #[serde(default)]
        kinds: Vec<String>,
        /// Digest of the payload the client still holds for this buffer, from
        /// an earlier reply's `digest`. When it matches what this request would
        /// produce, the reply carries `unchanged` and no `symbols` array.
        #[serde(default)]
        have_digest: String,
    },
    #[serde(rename = "folds")]
    Folds {
        buf: i64,
        lang: String,
        #[serde(default)]
        max_items: Option<usize>,
        /// See `Symbols::have_digest`.
        #[serde(default)]
        have_digest: String,
    },
    #[serde(rename = "dump_ast")]
    DumpAst { buf: i64, lang: String },
    /// Report what the highlighter sees at one point: which captures matched
    /// there, which group each maps to, and the enclosing node chain. Read-only
    /// and cheap — one point query, no state.
    #[serde(rename = "inspect")]
    Inspect {
        buf: i64,
        lang: String,
        /// 1-based line and byte column, matching Vim's line()/col().
        lnum: u32,
        col: u32,
    },
    /// Report the named-ancestor chain at one point, each entry carrying an
    /// outer and an inner range. One request serves both text objects (pick the
    /// innermost entry of the wanted class) and incremental selection (step
    /// outward through the chain), so growing a selection never needs a second
    /// round trip.
    #[serde(rename = "scope")]
    Scope {
        buf: i64,
        lang: String,
        /// 1-based line and byte column, matching Vim's line()/col().
        lnum: u32,
        col: u32,
    },
    #[serde(rename = "close_buffer")]
    CloseBuffer { buf: i64 },
    #[serde(rename = "status")]
    Status,
    #[serde(rename = "hello")]
    Hello {
        #[serde(default, rename = "client_protocol")]
        _client_protocol: u32,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "highlights")]
    Highlights {
        buf: i64,
        revision: u64,
        /// Protocol v6 object form, one JSON object per span. Omitted when the
        /// request asked for the compact encoding below.
        #[serde(skip_serializing_if = "Option::is_none")]
        spans: Option<Vec<Span>>,
        /// Compact encoding (v7): the group-name dictionary, plus one fixed
        /// list per span holding [lnum, col, end_lnum, end_col, group_index,
        /// depth]. A highlight reply repeats the same thirty-odd group names
        /// and the same six key names thousands of times; hoisting both out
        /// costs about two thirds of the bytes and turns six dictionary
        /// lookups per span into list indexing on the Vim side.
        #[serde(skip_serializing_if = "Option::is_none")]
        groups: Option<Vec<&'static str>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cspans: Option<Vec<[u32; 6]>>,
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        revision: u64,
        request_id: u64,
        /// Absent exactly when `unchanged` is set.
        #[serde(skip_serializing_if = "Option::is_none")]
        symbols: Option<Vec<Symbol>>,
        /// Digest of the payload this reply describes, for the client to send
        /// back as `have_digest` next time. A decimal string, not a number:
        /// Vim's json_decode() rounds integers above 2^53 through a float.
        #[serde(skip_serializing_if = "String::is_empty")]
        digest: String,
        /// The client already holds this exact payload; `symbols` is omitted.
        #[serde(skip_serializing_if = "is_false")]
        unchanged: bool,
    },
    #[serde(rename = "ast")]
    Ast {
        buf: i64,
        revision: u64,
        lines: Vec<String>,
    },
    #[serde(rename = "folds")]
    Folds {
        buf: i64,
        revision: u64,
        /// Absent exactly when `unchanged` is set.
        #[serde(skip_serializing_if = "Option::is_none")]
        folds: Option<Vec<Fold>>,
        #[serde(skip_serializing_if = "String::is_empty")]
        digest: String,
        #[serde(skip_serializing_if = "is_false")]
        unchanged: bool,
    },
    #[serde(rename = "inspect")]
    Inspect {
        buf: i64,
        revision: u64,
        lnum: u32,
        col: u32,
        captures: Vec<InspectCapture>,
        node_chain: Vec<InspectNode>,
    },
    #[serde(rename = "scope")]
    Scope {
        buf: i64,
        revision: u64,
        lnum: u32,
        col: u32,
        /// Range of the node the point resolved to, anonymous ones included.
        /// Every point inside it resolves to that same node and therefore to
        /// this same chain, which lets a client cache one reply for a whole
        /// token instead of re-asking on every column the cursor crosses.
        anchor_lnum: u32,
        anchor_col: u32,
        anchor_end_lnum: u32,
        anchor_end_col: u32,
        chain: Vec<ScopeNode>,
    },
    #[serde(rename = "ok")]
    Ok {
        buf: i64,
        op: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        revision: Option<u64>,
    },
    #[serde(rename = "status")]
    Status {
        protocol_version: u32,
        version: &'static str,
        cached_buffers: usize,
        full_parses: u64,
        incremental_parses: u64,
        unchanged_syncs: u64,
        cached_bytes: usize,
        cache_evictions: u64,
        languages: &'static [&'static str],
    },
    #[serde(rename = "hello")]
    Hello {
        protocol_version: u32,
        version: &'static str,
        capabilities: &'static [&'static str],
    },
    #[serde(rename = "error")]
    Error {
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        buf: Option<i64>,
        /// Request class that failed, so clients only clear matching inflight
        /// state. This is additive and harmless to older clients.
        #[serde(skip_serializing_if = "Option::is_none")]
        op: Option<&'static str>,
        /// Present for symbol requests in protocol v5. Other request classes
        /// keep None, preserving their v4 wire representation.
        #[serde(skip_serializing_if = "Option::is_none")]
        request_id: Option<u64>,
    },
}

#[derive(Debug, Serialize, Clone)]
struct Span {
    lnum: u32,
    col: u32,
    end_lnum: u32,
    end_col: u32,
    // 高亮组名全部来自 map_capture_to_group 的静态表；用 &'static str
    // 避免每个 span 一次堆分配（大文件全量高亮时有数千个 span）。
    group: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    depth: Option<u32>,
}

/// One highlight capture covering the inspected point.
#[derive(Debug, Serialize, Clone)]
struct InspectCapture {
    /// Capture name as written in the .scm query, without the leading '@'.
    capture: String,
    /// Result of `map_capture_to_group`; empty when the capture is not mapped
    /// to any group, which is itself the answer to "why is this not coloured".
    group: &'static str,
    priority: u8,
    lnum: u32,
    col: u32,
    end_lnum: u32,
    end_col: u32,
    /// True when this capture is the one the renderer would keep for its exact
    /// span. Computed with the same priority rule `run_highlight_cached` uses,
    /// so the report cannot claim a colour the highlighter does not draw.
    applied: bool,
    /// Set when the capture came from an injected grammar's query rather than
    /// the host language's.
    #[serde(skip_serializing_if = "Option::is_none")]
    injected_lang: Option<&'static str>,
}

/// One node on the path from the innermost node at the point up to the root.
#[derive(Debug, Serialize, Clone)]
struct InspectNode {
    kind: String,
    named: bool,
    lnum: u32,
    col: u32,
    end_lnum: u32,
    end_col: u32,
    /// The field name this node occupies in its parent, when it has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    field: Option<String>,
}

/// One named ancestor of an inspected point, innermost first.
///
/// Both ranges are 1-based and use byte columns, like every other position on
/// this wire; `end_col` is one past the last byte, so an empty range has
/// `col == end_col` on the same line.
#[derive(Debug, Serialize, Clone)]
struct ScopeNode {
    /// Grammar node kind, e.g. "function_item". Reported so a user can see what
    /// a text object actually matched without dumping the whole AST.
    node: &'static str,
    /// Text-object class this node answers to, absent when the node is only a
    /// step for incremental selection. A node has at most one class on purpose:
    /// a closure passed as an argument is a function, not a parameter, and a
    /// node that claimed both would need two contradictory outer ranges.
    #[serde(skip_serializing_if = "Option::is_none")]
    kind: Option<&'static str>,
    lnum: u32,
    col: u32,
    end_lnum: u32,
    end_col: u32,
    inner_lnum: u32,
    inner_col: u32,
    inner_end_lnum: u32,
    inner_end_col: u32,
}

#[derive(Debug, Serialize, Clone, PartialEq, Eq)]
struct Fold {
    lnum: u32,
    end_lnum: u32,
    level: u32,
}

#[derive(Debug, Serialize, Clone)]
struct Symbol {
    name: String,
    // 符号种类与容器种类都来自静态表，避免逐符号堆分配。
    kind: &'static str,
    lnum: u32,
    col: u32,
    #[serde(default)]
    end_lnum: u32,
    #[serde(default)]
    end_col: u32,
    container_kind: Option<&'static str>,
    container_name: Option<String>,
    container_lnum: Option<u32>,
    container_col: Option<u32>,
}

/// A second grammar parsed over a subset of the host document.
///
/// One tree per injected language, parsed once with `set_included_ranges` over
/// all of that language's ranges — a markdown file with forty rust fences costs
/// one rust parse, not forty.
struct InjectedTree {
    lang: &'static str,
    tree: tree_sitter::Tree,
}

// 缓存：每个 buf 保存 lang/text/tree
struct BufCache {
    lang: String,
    text: String,
    tree: tree_sitter::Tree,
    // 注入语法树：markdown 的 inline 与围栏代码块、HTML 的 <script>/<style>。
    // 每次同步整体重建：注入解析很快，而注入区间会随宿主的任何编辑整体平移，
    // 维护它们的增量复用不值当。
    injections: Vec<InjectedTree>,
    // 上面那些树占据的字节区间，按文档顺序排列且互不重叠。落在其中的宿主
    // capture 会被丢弃 —— markdown 把整段围栏内容捕获成 @text.literal，注入
    // 之后那一段应当由被注入的语法说了算。
    injected_ranges: Vec<ops::Range<usize>>,
    revision: u64,
    line_index: SparseLineIndex,
}

/// Sparse mapping from 1-based line numbers to byte offsets.
///
/// A dense `Vec<usize>` costs eight bytes for every newline on 64-bit hosts;
/// a newline-only buffer could therefore make the index many times larger than
/// its source. Checkpointing every `LINE_INDEX_STRIDE` lines bounds the index to
/// roughly 1/32 of the source size in that worst case. Lookups scan at most 255
/// newline boundaries forward from the nearest checkpoint.
struct SparseLineIndex {
    /// Byte offsets for lines 1, 1 + stride, 1 + 2 * stride, ...
    checkpoints: Box<[usize]>,
    /// Number of addressable lines, including the final empty line after `\n`.
    line_count: usize,
}

// 预编译的查询缓存
struct LangQueries {
    language: tree_sitter::Language,
    hl_query: tree_sitter::Query,
    sym_query: tree_sitter::Query,
}

/// A grammar compiled only to highlight injected content.
///
/// Kept apart from `LangQueries` because an injection target need not be a
/// filetype anyone can open: `markdown_inline` has no symbol query, no fold
/// kinds and no entry in `SUPPORTED_LANGUAGES`.
struct InjectionQuery {
    language: tree_sitter::Language,
    hl_query: tree_sitter::Query,
}

struct Server {
    // 缓存：buf -> BufCache
    cache: HashMap<i64, BufCache>,
    // 复用 parser（按语言）
    parsers: HashMap<String, tree_sitter::Parser>,
    // 预编译查询缓存（按语言）
    queries: HashMap<String, LangQueries>,
    // 注入语法的查询缓存（按注入语言名，含 markdown_inline）
    injection_queries: HashMap<String, InjectionQuery>,
    full_parses: u64,
    incremental_parses: u64,
    unchanged_syncs: u64,
    cache_evictions: u64,
}

/// Line-range replacement payload for `edit_lines`.
struct LineSplice {
    lstart: u32,
    old_lend: u32,
    lines: Vec<String>,
    line_count: u64,
    eol: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ParseMode {
    Full,
    Incremental,
    Unchanged,
}

impl Server {
    fn new() -> Self {
        Server {
            cache: HashMap::new(),
            parsers: HashMap::new(),
            queries: HashMap::new(),
            injection_queries: HashMap::new(),
            full_parses: 0,
            incremental_parses: 0,
            unchanged_syncs: 0,
            cache_evictions: 0,
        }
    }

    fn lang_info(lang: &str) -> Result<(tree_sitter::Language, &'static str, &'static str)> {
        let (language, hl_query, sym_query) = match lang {
            "rust" => (
                tree_sitter_rust::LANGUAGE.into(),
                queries::RUST_QUERY,
                queries::RUST_SYM_QUERY,
            ),
            "javascript" => (
                tree_sitter_javascript::LANGUAGE.into(),
                queries::JS_QUERY,
                queries::JS_SYM_QUERY,
            ),
            "typescript" => (
                tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
                queries::TS_QUERY,
                queries::TS_SYM_QUERY,
            ),
            "tsx" => (
                tree_sitter_typescript::LANGUAGE_TSX.into(),
                queries::TSX_QUERY,
                queries::TS_SYM_QUERY,
            ),
            "json" => (
                tree_sitter_json::LANGUAGE.into(),
                queries::JSON_QUERY,
                queries::JSON_SYM_QUERY,
            ),
            "yaml" => (
                tree_sitter_yaml::LANGUAGE.into(),
                queries::YAML_QUERY,
                queries::YAML_SYM_QUERY,
            ),
            "toml" => (
                tree_sitter_toml_ng::LANGUAGE.into(),
                queries::TOML_QUERY,
                queries::TOML_SYM_QUERY,
            ),
            "c" => (
                tree_sitter_c::LANGUAGE.into(),
                queries::C_QUERY,
                queries::C_SYM_QUERY,
            ),
            "cpp" => (
                tree_sitter_cpp::LANGUAGE.into(),
                queries::CPP_QUERY,
                queries::CPP_SYM_QUERY,
            ),
            "python" => (
                tree_sitter_python::LANGUAGE.into(),
                queries::PYTHON_QUERY,
                queries::PYTHON_SYM_QUERY,
            ),
            "go" => (
                tree_sitter_go::LANGUAGE.into(),
                queries::GO_QUERY,
                queries::GO_SYM_QUERY,
            ),
            "bash" | "sh" => (
                tree_sitter_bash::LANGUAGE.into(),
                queries::BASH_QUERY,
                queries::BASH_SYM_QUERY,
            ),
            "vim" => (
                tree_sitter_vim9::LANGUAGE.into(),
                queries::VIM_QUERY,
                queries::VIM_SYM_QUERY,
            ),
            "lua" => (
                tree_sitter_lua::LANGUAGE.into(),
                queries::LUA_QUERY,
                queries::LUA_SYM_QUERY,
            ),
            "html" => (
                tree_sitter_html::LANGUAGE.into(),
                queries::HTML_QUERY,
                queries::HTML_SYM_QUERY,
            ),
            "css" => (
                tree_sitter_css::LANGUAGE.into(),
                queries::CSS_QUERY,
                queries::CSS_SYM_QUERY,
            ),
            "markdown" => (
                tree_sitter_md::LANGUAGE.into(),
                queries::MD_QUERY,
                queries::MD_SYM_QUERY,
            ),
            "julia" => (
                tree_sitter_julia::LANGUAGE.into(),
                queries::JULIA_QUERY,
                queries::JULIA_SYM_QUERY,
            ),
            "haskell" => (
                tree_sitter_haskell::LANGUAGE.into(),
                queries::HASKELL_QUERY,
                queries::HASKELL_SYM_QUERY,
            ),
            _ => return Err(anyhow!("unsupported language: {lang}")),
        };
        Ok((language, hl_query, sym_query))
    }

    fn ensure_queries(&mut self, lang: &str) -> Result<()> {
        if !self.queries.contains_key(lang) {
            let (language, hl_src, sym_src) = Self::lang_info(lang)?;
            let hl_query = tree_sitter::Query::new(&language, hl_src)?;
            let sym_query = tree_sitter::Query::new(&language, sym_src)?;
            self.queries.insert(
                lang.to_string(),
                LangQueries {
                    language,
                    hl_query,
                    sym_query,
                },
            );
        }
        // Compile the fixed injection targets now rather than on first sight of
        // an injected range: `--self-test` only calls this, and it is what makes
        // a broken injected query fail at install time instead of silently
        // leaving `<script>` bodies uncoloured for the one user who has one.
        for rule in injection_rules(lang) {
            if let InjectionTarget::Fixed(target) = rule.target {
                self.ensure_injection_query(target)?;
            }
        }
        Ok(())
    }

    fn ensure_injection_query(&mut self, name: &str) -> Result<()> {
        if self.injection_queries.contains_key(name) {
            return Ok(());
        }
        let (language, hl_src): (tree_sitter::Language, &str) = if name == "markdown_inline" {
            (
                tree_sitter_md::INLINE_LANGUAGE.into(),
                queries::MD_INLINE_QUERY,
            )
        } else {
            let (language, hl_src, _) = Self::lang_info(name)?;
            (language, hl_src)
        };
        let hl_query = tree_sitter::Query::new(&language, hl_src)?;
        self.injection_queries
            .insert(name.to_string(), InjectionQuery { language, hl_query });
        Ok(())
    }

    fn parser_for(
        &mut self,
        lang: &str,
        language: tree_sitter::Language,
    ) -> Result<&mut tree_sitter::Parser> {
        use std::collections::hash_map::Entry;
        Ok(match self.parsers.entry(lang.to_string()) {
            Entry::Occupied(e) => {
                let p = e.into_mut();
                p.set_language(&language)?;
                p
            }
            Entry::Vacant(v) => {
                let mut p = tree_sitter::Parser::new();
                p.set_language(&language)?;
                v.insert(p)
            }
        })
    }

    fn set_text(&mut self, buf: i64, lang: &str, text: String, revision: u64) -> Result<ParseMode> {
        if text.len() > MAX_SOURCE_BYTES {
            self.cache.remove(&buf);
            return Err(anyhow!(
                "buffer exceeds daemon limit of {MAX_SOURCE_BYTES} bytes"
            ));
        }
        self.ensure_queries(lang)?;
        let language = self.queries.get(lang).unwrap().language.clone();

        if let Some(cache) = self.cache.get_mut(&buf)
            && cache.lang == lang
            && cache.text == text
        {
            cache.revision = revision;
            self.unchanged_syncs += 1;
            return Ok(ParseMode::Unchanged);
        }

        let old_tree = self.cache.get(&buf).and_then(|cache| {
            if cache.lang != lang {
                return None;
            }
            let edit = compute_input_edit(&cache.text, &text)?;
            let mut tree = cache.tree.clone();
            tree.edit(&edit);
            Some(tree)
        });

        let p = self.parser_for(lang, language.clone())?;
        let tree = p
            .parse(&text, old_tree.as_ref())
            .ok_or_else(|| anyhow!("parse failed"))?;
        let mode = if old_tree.is_some() {
            self.incremental_parses += 1;
            ParseMode::Incremental
        } else {
            self.full_parses += 1;
            ParseMode::Full
        };
        let (injections, injected_ranges) = self.parse_injections(lang, &tree, &text)?;
        self.reserve_cache_capacity(buf, text.len());
        let line_index = SparseLineIndex::new(&text);
        self.cache.insert(
            buf,
            BufCache {
                lang: lang.to_string(),
                text,
                tree,
                injections,
                injected_ranges,
                revision,
                line_index,
            },
        );
        Ok(mode)
    }

    /// Parse every language injected into `host_tree`, one tree per language.
    ///
    /// Returns the trees plus the union of the byte ranges they own, in
    /// document order, which the highlighter uses to let an injected grammar
    /// win over the host's own capture for the same text.
    fn parse_injections(
        &mut self,
        lang: &str,
        host_tree: &tree_sitter::Tree,
        text: &str,
    ) -> Result<(Vec<InjectedTree>, Vec<ops::Range<usize>>)> {
        let rules = injection_rules(lang);
        if rules.is_empty() {
            return Ok((Vec::new(), Vec::new()));
        }
        let mut found: Vec<(&'static str, tree_sitter::Range)> = Vec::new();
        collect_injection_ranges(host_tree.root_node(), rules, text, &mut found);
        if found.is_empty() {
            return Ok((Vec::new(), Vec::new()));
        }

        // Group by target language while preserving document order: a parser
        // wants all of one language's ranges in one `set_included_ranges` call,
        // ascending and non-overlapping.
        let mut grouped: Vec<(&'static str, Vec<tree_sitter::Range>)> = Vec::new();
        let mut injected_ranges: Vec<ops::Range<usize>> = Vec::with_capacity(found.len());
        for (target, range) in found {
            injected_ranges.push(range.start_byte..range.end_byte);
            match grouped.iter_mut().find(|(name, _)| *name == target) {
                Some((_, ranges)) => ranges.push(range),
                None => grouped.push((target, vec![range])),
            }
        }

        let mut injections = Vec::with_capacity(grouped.len());
        for (target, ranges) in grouped {
            // An injected grammar that fails to compile its query must not take
            // the host buffer down with it; drop that language and carry on.
            if self.ensure_injection_query(target).is_err() {
                continue;
            }
            let language = self.injection_queries[target].language.clone();
            // Keyed apart from the host parser of the same language: a rust
            // fence inside markdown must not clobber the parser a rust buffer
            // is reusing, included ranges and all.
            let key = format!("injection-{target}");
            let parser = self.parser_for(&key, language)?;
            parser.set_included_ranges(&ranges)?;
            let parsed = parser.parse(text, None);
            // Restore the default (whole-document) range unconditionally, or the
            // next user of this pooled parser silently parses a keyhole.
            parser.set_included_ranges(&[])?;
            if let Some(tree) = parsed {
                injections.push(InjectedTree { lang: target, tree });
            }
        }
        Ok((injections, injected_ranges))
    }

    /// Apply a line-range splice reported by the editor, then reuse the normal
    /// `set_text` path for incremental parsing.
    ///
    /// `lstart`/`old_lend` are 1-based with an exclusive end, expressed against
    /// the last synced text. `line_count` is the expected total line count after
    /// the edit; any mismatch drops the cache so the client falls back to a full
    /// `set_text` instead of silently diverging from the buffer.
    fn edit_lines(
        &mut self,
        buf: i64,
        lang: &str,
        revision: u64,
        splice: LineSplice,
    ) -> Result<ParseMode> {
        let cache = self
            .cache
            .get(&buf)
            .ok_or_else(|| anyhow!("buffer not cached: {buf}"))?;
        if cache.lang != lang {
            return Err(anyhow!(
                "lang mismatch for buf {buf}: cached={}, req={}",
                cache.lang,
                lang
            ));
        }

        // 还原为逻辑行；缓存文本总是 join(lines, "\n") + (eol ? "\n" : "")。
        let spliced: Result<String> = {
            let old_text = cache.text.as_str();
            let body = old_text.strip_suffix('\n').unwrap_or(old_text);
            let old_lines: Vec<&str> = body.split('\n').collect();

            let start = splice.lstart.max(1) as usize - 1;
            let end = splice.old_lend.max(1) as usize - 1;
            if start > old_lines.len() || end > old_lines.len() || end < start {
                Err(anyhow!(
                    "edit_lines mismatch for buf {buf}: splice {}..{} outside {} lines",
                    splice.lstart,
                    splice.old_lend,
                    old_lines.len()
                ))
            } else {
                let new_total = old_lines.len() - (end - start) + splice.lines.len();
                if new_total as u64 != splice.line_count {
                    Err(anyhow!(
                        "edit_lines mismatch for buf {buf}: expected {} lines, spliced {new_total}",
                        splice.line_count
                    ))
                } else {
                    let added_bytes: usize = splice.lines.iter().map(|line| line.len() + 1).sum();
                    let mut text = String::with_capacity(old_text.len() + added_bytes + 1);
                    for line in old_lines[..start]
                        .iter()
                        .copied()
                        .chain(splice.lines.iter().map(String::as_str))
                        .chain(old_lines[end..].iter().copied())
                    {
                        text.push_str(line);
                        text.push('\n');
                    }
                    if !splice.eol {
                        text.pop();
                    }
                    Ok(text)
                }
            }
        };

        match spliced {
            Ok(text) => self.set_text(buf, lang, text, revision),
            Err(error) => {
                // 失配说明客户端与缓存已经分叉；丢掉缓存，强制下一次全量同步。
                self.cache.remove(&buf);
                Err(error)
            }
        }
    }

    fn reserve_cache_capacity(&mut self, current_buf: i64, incoming_bytes: usize) {
        loop {
            let contains_current = self.cache.contains_key(&current_buf);
            let resulting_count = self.cache.len() + usize::from(!contains_current);
            let bytes_without_current: usize = self
                .cache
                .iter()
                .filter(|(buf, _)| **buf != current_buf)
                .map(|(_, cache)| cache.text.len())
                .sum();
            if resulting_count <= MAX_CACHED_BUFFERS
                && bytes_without_current.saturating_add(incoming_bytes) <= MAX_CACHED_SOURCE_BYTES
            {
                break;
            }
            let Some(victim) = self
                .cache
                .keys()
                .copied()
                .find(|buffer| *buffer != current_buf)
            else {
                break;
            };
            self.cache.remove(&victim);
            self.cache_evictions += 1;
        }
    }

    fn get_cache(&self, buf: i64, lang: &str) -> Result<&BufCache> {
        let c = self
            .cache
            .get(&buf)
            .ok_or_else(|| anyhow!("buffer not cached: {buf}"))?;
        if c.lang != lang {
            return Err(anyhow!(
                "lang mismatch for buf {buf}: cached={}, req={}",
                c.lang,
                lang
            ));
        }
        Ok(c)
    }
}

/// Compute one conservative edit that turns `old` into `new`.
///
/// Tree-sitter only needs a valid edit; it does not have to be the smallest
/// possible edit. Keeping the unchanged prefix and suffix gives the parser a
/// useful old tree while remaining linear in the size of the transferred text.
fn compute_input_edit(old: &str, new: &str) -> Option<tree_sitter::InputEdit> {
    if old == new {
        return None;
    }

    let old_bytes = old.as_bytes();
    let new_bytes = new.as_bytes();
    let mut start = old_bytes
        .iter()
        .zip(new_bytes)
        .take_while(|(left, right)| left == right)
        .count();
    while start > 0 && (!old.is_char_boundary(start) || !new.is_char_boundary(start)) {
        start -= 1;
    }

    let mut old_end = old.len();
    let mut new_end = new.len();
    while old_end > start && new_end > start && old_bytes[old_end - 1] == new_bytes[new_end - 1] {
        old_end -= 1;
        new_end -= 1;
    }
    while old_end < old.len()
        && new_end < new.len()
        && (!old.is_char_boundary(old_end) || !new.is_char_boundary(new_end))
    {
        old_end += 1;
        new_end += 1;
    }

    Some(tree_sitter::InputEdit {
        start_byte: start,
        old_end_byte: old_end,
        new_end_byte: new_end,
        start_position: byte_offset_to_point(old, start),
        old_end_position: byte_offset_to_point(old, old_end),
        new_end_position: byte_offset_to_point(new, new_end),
    })
}

fn byte_offset_to_point(text: &str, offset: usize) -> tree_sitter::Point {
    let offset = offset.min(text.len());
    let prefix = &text.as_bytes()[..offset];
    let row = prefix.iter().filter(|byte| **byte == b'\n').count();
    let column = prefix
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(offset, |newline| offset - newline - 1);
    tree_sitter::Point { row, column }
}

/// The largest JSON record the request loop will materialise.
///
/// `set_text` carries a whole buffer body in one JSONL record, and the daemon
/// accepts a body of up to `MAX_SOURCE_BYTES`.  `serde_json` expands every
/// control byte to six ASCII bytes (`\u00xx`), so a buffer at that documented
/// maximum can legitimately encode to six times its length; `edit_lines` stays
/// under the same ceiling because each line's `","` separator is paid for by
/// the newline that line contributes to the source it replaces.  A kilobyte
/// covers the request envelope around it.
///
/// Deriving the bound from `MAX_SOURCE_BYTES` rather than picking a round
/// number keeps the reader from rejecting a request `set_text` would have
/// accepted, while still putting a ceiling in front of the allocation that
/// `MAX_SOURCE_BYTES` exists to prevent.
const MAX_REQUEST_LINE_BYTES: usize = MAX_SOURCE_BYTES * 6 + 1024;

fn finish_request_line(mut bytes: Vec<u8>, too_long: bool, limit: usize) -> Result<String, String> {
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if too_long || bytes.len() > limit {
        return Err(format!("request line exceeds {limit} bytes"));
    }
    String::from_utf8(bytes).map_err(|_| "request line is not valid UTF-8".to_string())
}

/// Read one bounded JSONL record and, after rejecting an oversized one, resume
/// exactly at the next newline.  `BufRead::lines()` has no size limit: it grows
/// a single `String` until the newline arrives, so a client that loses its
/// newline grows the daemon until the machine runs out of memory, and
/// `MAX_SOURCE_BYTES` never gets to speak because `set_text` is never reached.
/// `lines()` also cannot skip a bad record, so one oversized line would
/// desynchronise the stream for every request behind it.
fn read_request_line<R: BufRead>(
    reader: &mut R,
    limit: usize,
) -> std::io::Result<Option<Result<String, String>>> {
    let mut bytes = Vec::new();
    let mut too_long = false;

    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return if bytes.is_empty() && !too_long {
                Ok(None)
            } else {
                Ok(Some(finish_request_line(bytes, too_long, limit)))
            };
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_len = newline.unwrap_or(available.len());
        let consumed = newline.map_or(available.len(), |position| position + 1);

        if !too_long {
            // Keep one extra byte until the record ends: for CRLF that byte is
            // the framing CR, not part of the JSON line's documented limit.
            if bytes.len().saturating_add(content_len) > limit.saturating_add(1) {
                bytes.clear();
                too_long = true;
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);

        if newline.is_some() {
            return Ok(Some(finish_request_line(bytes, too_long, limit)));
        }
    }
}

const USAGE: &str = "\
Usage: ts-hl-daemon [OPTION]

With no arguments the daemon serves newline-delimited JSON requests on stdin
and writes replies to stdout.  That is how the Vim plugin starts it; there is
nothing useful to do with it interactively.

Options:
  -V, --version    print the version and exit
  -h, --help       print this help and exit
      --self-test  compile every bundled grammar's queries and exit
";

/// Loads and compiles the highlight queries for every bundled grammar.
///
/// This binary links seventeen tree-sitter grammars, and a grammar that fails
/// to compile its queries is invisible until a user opens that filetype and
/// gets no highlighting at all.  The installer runs this so the failure lands
/// at install time instead.
fn self_test() -> Result<()> {
    let mut server = Server::new();
    for language in SUPPORTED_LANGUAGES {
        server
            .ensure_queries(language)
            .map_err(|error| anyhow::anyhow!("{language}: {error}"))?;
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => serve(),
        Some("--version" | "-V") => {
            println!("ts-hl-daemon {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("--help" | "-h") => {
            println!("ts-hl-daemon {}\n\n{USAGE}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("--self-test") => match self_test() {
            Ok(()) => {
                println!("ok ({} grammars)", SUPPORTED_LANGUAGES.len());
                Ok(())
            }
            Err(error) => {
                eprintln!("self-test failed: {error}");
                std::process::exit(1);
            }
        },
        Some(other) => {
            eprintln!("unknown argument: {other}\n\n{USAGE}");
            std::process::exit(2);
        }
    }
}

fn serve() -> Result<()> {
    let stdin = std::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut out = std::io::stdout();
    let mut server = Server::new();

    // A read error on stdin ends the session the same way end-of-stream does:
    // the editor is gone, and there is nobody left to report it to.
    while let Ok(Some(record)) = read_request_line(&mut reader, MAX_REQUEST_LINE_BYTES) {
        let line = match record {
            Ok(line) => line,
            Err(message) => {
                send(
                    &mut out,
                    &Event::Error {
                        message,
                        buf: None,
                        op: None,
                        request_id: None,
                    },
                )?;
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                send(
                    &mut out,
                    &Event::Error {
                        message: format!("invalid request: {e}"),
                        buf: None,
                        op: None,
                        request_id: None,
                    },
                )?;
                continue;
            }
        };
        match req {
            Request::SetText {
                buf,
                lang,
                text,
                revision,
            } => match server.set_text(buf, &lang, text, revision) {
                Ok(_) => send(
                    &mut out,
                    &Event::Ok {
                        buf,
                        op: "set_text".to_string(),
                        revision: Some(revision),
                    },
                )?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
                        op: Some("set_text"),
                        request_id: None,
                    },
                )?,
            },
            Request::EditLines {
                buf,
                lang,
                revision,
                lstart,
                old_lend,
                lines,
                line_count,
                eol,
            } => {
                let splice = LineSplice {
                    lstart,
                    old_lend,
                    lines,
                    line_count,
                    eol,
                };
                match server.edit_lines(buf, &lang, revision, splice) {
                    Ok(_) => send(
                        &mut out,
                        &Event::Ok {
                            buf,
                            op: "edit_lines".to_string(),
                            revision: Some(revision),
                        },
                    )?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                            op: Some("edit_lines"),
                            request_id: None,
                        },
                    )?,
                }
            }
            Request::Highlight {
                buf,
                lang,
                lstart,
                lend,
                rainbow,
                max_spans,
                compact,
            } => {
                let lrange = lstart.zip(lend);
                match run_highlight_cached(&mut server, buf, &lang, lrange, rainbow, max_spans) {
                    Ok((revision, spans)) => {
                        let (groups, cspans) = if compact {
                            let (groups, rows) = compact_spans(&spans);
                            (Some(groups), Some(rows))
                        } else {
                            (None, None)
                        };
                        send(
                            &mut out,
                            &Event::Highlights {
                                buf,
                                revision,
                                spans: if compact { None } else { Some(spans) },
                                groups,
                                cspans,
                            },
                        )?
                    }
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                            op: Some("highlight"),
                            request_id: None,
                        },
                    )?,
                }
            }
            Request::Symbols {
                buf,
                lang,
                request_id,
                lstart,
                lend,
                max_items,
                kinds,
                have_digest,
            } => {
                let lrange = lstart.zip(lend);
                match run_symbols_cached_filtered(
                    &mut server,
                    buf,
                    &lang,
                    lrange,
                    max_items,
                    &kinds,
                ) {
                    Ok((revision, symbols)) => {
                        let digest = digest_symbols(&symbols);
                        let unchanged = !have_digest.is_empty() && have_digest == digest;
                        send(
                            &mut out,
                            &Event::Symbols {
                                buf,
                                revision,
                                request_id,
                                symbols: if unchanged { None } else { Some(symbols) },
                                digest,
                                unchanged,
                            },
                        )?
                    }
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                            op: Some("symbols"),
                            request_id: Some(request_id),
                        },
                    )?,
                }
            }
            Request::Folds {
                buf,
                lang,
                max_items,
                have_digest,
            } => match run_folds_cached(&server, buf, &lang, max_items) {
                Ok((revision, folds)) => {
                    let digest = digest_folds(&folds);
                    let unchanged = !have_digest.is_empty() && have_digest == digest;
                    send(
                        &mut out,
                        &Event::Folds {
                            buf,
                            revision,
                            folds: if unchanged { None } else { Some(folds) },
                            digest,
                            unchanged,
                        },
                    )?
                }
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
                        op: Some("folds"),
                        request_id: None,
                    },
                )?,
            },
            Request::DumpAst { buf, lang } => match dump_ast_cached(&mut server, buf, &lang) {
                Ok((revision, lines)) => send(
                    &mut out,
                    &Event::Ast {
                        buf,
                        revision,
                        lines,
                    },
                )?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
                        op: Some("dump_ast"),
                        request_id: None,
                    },
                )?,
            },
            Request::Inspect {
                buf,
                lang,
                lnum,
                col,
            } => match inspect_cached(&mut server, buf, &lang, lnum, col) {
                Ok((revision, captures, node_chain)) => send(
                    &mut out,
                    &Event::Inspect {
                        buf,
                        revision,
                        lnum,
                        col,
                        captures,
                        node_chain,
                    },
                )?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
                        op: Some("inspect"),
                        request_id: None,
                    },
                )?,
            },
            Request::Scope {
                buf,
                lang,
                lnum,
                col,
            } => match scope_chain_cached(&server, buf, &lang, lnum, col) {
                Ok(answer) => send(
                    &mut out,
                    &Event::Scope {
                        buf,
                        revision: answer.revision,
                        lnum,
                        col,
                        anchor_lnum: answer.anchor[0],
                        anchor_col: answer.anchor[1],
                        anchor_end_lnum: answer.anchor[2],
                        anchor_end_col: answer.anchor[3],
                        chain: answer.chain,
                    },
                )?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
                        op: Some("scope"),
                        request_id: None,
                    },
                )?,
            },
            Request::CloseBuffer { buf } => {
                server.cache.remove(&buf);
                send(
                    &mut out,
                    &Event::Ok {
                        buf,
                        op: "close_buffer".to_string(),
                        revision: None,
                    },
                )?;
            }
            Request::Status => send(
                &mut out,
                &Event::Status {
                    protocol_version: PROTOCOL_VERSION,
                    version: env!("CARGO_PKG_VERSION"),
                    cached_buffers: server.cache.len(),
                    full_parses: server.full_parses,
                    incremental_parses: server.incremental_parses,
                    unchanged_syncs: server.unchanged_syncs,
                    cached_bytes: server.cache.values().map(|cache| cache.text.len()).sum(),
                    cache_evictions: server.cache_evictions,
                    languages: SUPPORTED_LANGUAGES,
                },
            )?,
            Request::Hello { .. } => {
                send(
                    &mut out,
                    &Event::Hello {
                        protocol_version: PROTOCOL_VERSION,
                        version: env!("CARGO_PKG_VERSION"),
                        capabilities: &[
                            "revision",
                            "incremental_parse",
                            "close_buffer",
                            "status",
                            "bounded_results",
                            "edit_lines",
                            "folds",
                            "symbol_kind_filter",
                            "error_op",
                            "symbol_request_id",
                            "inspect",
                            "scope",
                            "injections",
                            "payload_digest",
                            "compact_spans",
                        ],
                    },
                )?;
            }
        }
    }
    Ok(())
}

fn send(out: &mut std::io::Stdout, ev: &Event) -> Result<()> {
    let js = serde_json::to_string(ev)?;
    out.write_all(js.as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}

// 将行号范围转为字节范围（用于 QueryCursor 限制扫描区间）
#[cfg(test)]
fn line_range_to_byte_range(text: &str, ls: u32, le: u32) -> ops::Range<usize> {
    line_range_from_index(&SparseLineIndex::new(text), text, ls, le)
}

impl SparseLineIndex {
    fn new(text: &str) -> Self {
        let mut checkpoints = vec![0];
        let mut newline_count = 0_usize;
        for (index, byte) in text.bytes().enumerate() {
            if byte != b'\n' {
                continue;
            }
            newline_count += 1;
            if newline_count.is_multiple_of(LINE_INDEX_STRIDE) {
                checkpoints.push(index + 1);
            }
        }
        Self {
            checkpoints: checkpoints.into_boxed_slice(),
            line_count: newline_count + 1,
        }
    }

    fn line_start_byte(&self, text: &str, line: u32) -> usize {
        let Some(target_line) = usize::try_from(line.saturating_sub(1)).ok() else {
            return text.len();
        };
        if target_line >= self.line_count {
            return text.len();
        }

        let checkpoint_index = target_line / LINE_INDEX_STRIDE;
        let checkpoint_line = checkpoint_index * LINE_INDEX_STRIDE;
        let mut offset = self.checkpoints[checkpoint_index];
        for _ in checkpoint_line..target_line {
            let Some(relative_newline) = text.as_bytes()[offset..]
                .iter()
                .position(|byte| *byte == b'\n')
            else {
                return text.len();
            };
            offset += relative_newline + 1;
        }
        offset
    }

    /// Byte offset -> tree-sitter `Point` (0-based row, byte column).
    ///
    /// Text objects need points for offsets no node starts at — an inner range
    /// trimmed in past a brace, a parameter's trailing comma — and this runs on
    /// a key the user holds down, so a scan from byte 0 is not affordable.
    /// Binary-searching the checkpoints bounds the scan to one stride of lines
    /// however far into the file the offset is.
    fn point_at_byte(&self, text: &str, offset: usize) -> tree_sitter::Point {
        let offset = offset.min(text.len());
        let checkpoint_index = match self.checkpoints.binary_search(&offset) {
            Ok(index) => index,
            Err(index) => index.saturating_sub(1),
        };
        let base = self.checkpoints[checkpoint_index];
        let mut row = checkpoint_index * LINE_INDEX_STRIDE;
        let mut line_start = base;
        for (index, byte) in text.as_bytes()[base..offset].iter().enumerate() {
            if *byte == b'\n' {
                row += 1;
                line_start = base + index + 1;
            }
        }
        tree_sitter::Point {
            row,
            column: offset - line_start,
        }
    }
}

fn line_range_from_index(
    line_index: &SparseLineIndex,
    text: &str,
    ls: u32,
    le: u32,
) -> ops::Range<usize> {
    // ls/le 为 1-based；结束偏移是 le 下一行的开头。
    let start_line = ls.max(1);
    let end_line = le.max(start_line);
    let start = line_index.line_start_byte(text, start_line);
    let end = line_index.line_start_byte(text, end_line.saturating_add(1));
    ops::Range { start, end }
}

fn expand_range_for_multiline_token(
    root: tree_sitter::Node,
    mut range: ops::Range<usize>,
) -> ops::Range<usize> {
    if range.start >= range.end {
        return range;
    }
    let Some(mut node) = root.descendant_for_byte_range(range.start, range.start) else {
        return range;
    };
    loop {
        let kind = node.kind();
        if node.start_byte() < range.start
            && node.end_byte() > range.start
            && (kind.contains("string")
                || kind.contains("comment")
                || kind.contains("heredoc")
                || kind.contains("raw_text"))
        {
            range.start = node.start_byte();
            break;
        }
        let Some(parent) = node.parent() else {
            break;
        };
        node = parent;
    }
    range
}

// 复用缓存的 Tree + bytes 做高亮
fn run_highlight_cached(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lrange: Option<(u32, u32)>,
    rainbow: bool,
    max_spans: Option<usize>,
) -> Result<(u64, Vec<Span>)> {
    server.ensure_queries(lang)?;
    let cache = server.get_cache(buf, lang)?;
    let bytes = cache.text.as_bytes();
    let root = cache.tree.root_node();
    let lang_queries = server.queries.get(&cache.lang).unwrap();

    // 宿主查询之外，每棵注入树再跑一遍它自己语言的高亮查询。
    let mut passes: Vec<(&tree_sitter::Query, tree_sitter::Node, bool)> =
        vec![(&lang_queries.hl_query, root, false)];
    for injected in &cache.injections {
        if let Some(query) = server.injection_queries.get(injected.lang) {
            passes.push((&query.hl_query, injected.tree.root_node(), true));
        }
    }

    let mut spans = Vec::with_capacity(4096);
    let limit = max_spans
        .unwrap_or(MAX_HIGHLIGHT_SPANS)
        .min(MAX_HIGHLIGHT_SPANS);
    // Dedup by an explicit semantic priority. Capture iteration is ordered by
    // source position, but same-range pattern ordering is not an API contract.
    let mut seen = HashMap::<(u32, u32, u32, u32), (usize, u8)>::new();
    'passes: for (query, pass_root, injected) in passes {
        let mut cursor = tree_sitter::QueryCursor::new();
        if let Some((ls, le)) = lrange {
            let b_range = expand_range_for_multiline_token(
                pass_root,
                line_range_from_index(&cache.line_index, &cache.text, ls, le),
            );
            cursor.set_byte_range(b_range);
        }
        let mut it = cursor.captures(query, pass_root, bytes);
        while let Some((m, cap_ix)) = it.next() {
            let cap = m.captures[*cap_ix];
            let node = cap.node;
            if node.start_byte() >= node.end_byte() {
                continue;
            }
            // Inside an injected range the injected grammar has the last word:
            // markdown captures a whole fence as @text.literal, and leaving that
            // in place would paint one flat colour over the rust underneath it.
            if !injected && covered_by_injection(&cache.injected_ranges, node) {
                continue;
            }
            let sp = node.start_position();
            let ep = node.end_position();

            let lnum = sp.row as u32 + 1;
            let col = sp.column as u32 + 1;
            let end_lnum = ep.row as u32 + 1;
            let end_col = ep.column as u32 + 1;

            if let Some((ls, le)) = lrange
                && (end_lnum < ls || lnum > le)
            {
                continue;
            }

            let key = (lnum, col, end_lnum, end_col);
            let cname = query.capture_names()[cap.index as usize];
            let priority = capture_priority(cname);
            let group = map_capture_to_group(cname);
            if group.is_empty() {
                continue;
            }
            let depth = if rainbow && cname == "punctuation.bracket" {
                let d = bracket_depth(node);
                if d > 0 { Some(d) } else { None }
            } else {
                None
            };
            let span = Span {
                lnum,
                col,
                end_lnum,
                end_col,
                group,
                depth,
            };
            if let Some((index, old_priority)) = seen.get_mut(&key) {
                if priority > *old_priority {
                    spans[*index] = span;
                    *old_priority = priority;
                }
                continue;
            }
            if spans.len() >= limit {
                break 'passes;
            }
            seen.insert(key, (spans.len(), priority));
            spans.push(span);
        }
    }

    Ok((cache.revision, spans))
}

// 复用缓存 Tree + bytes 做符号
#[cfg(test)]
fn run_symbols_cached(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
) -> Result<(u64, Vec<Symbol>)> {
    run_symbols_cached_filtered(server, buf, lang, lrange, max_items, &[])
}

fn symbol_kind_allowed(kind: &str, kinds: &[String]) -> bool {
    kinds.is_empty() || kinds.iter().any(|candidate| candidate == kind)
}

fn run_symbols_cached_filtered(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
    kinds: &[String],
) -> Result<(u64, Vec<Symbol>)> {
    server.ensure_queries(lang)?;
    let cache = server.get_cache(buf, lang)?;
    let bytes = cache.text.as_bytes();
    let root = cache.tree.root_node();
    let query = &server.queries.get(&cache.lang).unwrap().sym_query;
    let mut cursor = tree_sitter::QueryCursor::new();

    if let Some((ls, le)) = lrange {
        let b_range = line_range_from_index(&cache.line_index, &cache.text, ls, le);
        cursor.set_byte_range(b_range);
    }

    let limit = max_items.unwrap_or(MAX_SYMBOLS).min(MAX_SYMBOLS);
    use std::collections::{HashMap, HashSet};
    let mut seen = HashSet::<(
        &'static str,
        String,
        u32,
        u32,
        Option<&'static str>,
        Option<String>,
        Option<u32>,
        Option<u32>,
    )>::new();
    let mut seen_at = HashMap::<(u32, u32), &'static str>::new();

    let mut symbols = Vec::with_capacity(limit.min(4096));

    // 1) 先用查询收集符号
    let mut it = cursor.captures(query, root, bytes);
    while let Some((m, cap_ix)) = it.next() {
        if symbols.len() >= limit {
            break;
        }
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let cname = query.capture_names()[cap.index as usize];
        let mut kind = map_symbol_capture(cname);
        if kind.is_empty() {
            continue;
        }

        if cache.lang == "rust" && kind == "function" && ancestor_kind(node, "impl_item").is_some()
        {
            kind = "method";
        }

        if !symbol_kind_allowed(kind, kinds) {
            continue;
        }

        let name = node_text(node, bytes);
        let sp = node.start_position();
        let lnum = sp.row as u32 + 1;
        let col = sp.column as u32 + 1;
        // Query 捕获的一般只是名称节点；向上找到真正的定义，范围才会覆盖函数体。
        let def_end = definition_node(node, &cache.lang, kind).end_position();
        let sym_end_lnum = def_end.row as u32 + 1;
        let sym_end_col = def_end.column as u32 + 1;

        if let Some((ls, le)) = lrange
            && (lnum < ls || lnum > le)
        {
            continue;
        }

        // 容器信息（可选）
        let mut ckind: Option<&'static str> = None;
        let mut cname_opt: Option<String> = None;
        let mut clnum: Option<u32> = None;
        let mut ccol: Option<u32> = None;

        // Rust 容器推断
        if cache.lang == "rust" {
            match kind {
                "field" => {
                    if let Some(vinfo) = variant_info(node, bytes) {
                        ckind = Some("variant");
                        cname_opt = Some(vinfo.0);
                        clnum = Some(vinfo.1);
                        ccol = Some(vinfo.2);
                    } else if let Some(sinfo) = struct_info(node, bytes) {
                        ckind = Some("struct");
                        cname_opt = Some(sinfo.0);
                        clnum = Some(sinfo.1);
                        ccol = Some(sinfo.2);
                    } else if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace");
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                "variant" => {
                    if let Some(einfo) = enum_info(node, bytes) {
                        ckind = Some("enum");
                        cname_opt = Some(einfo.0);
                        clnum = Some(einfo.1);
                        ccol = Some(einfo.2);
                    }
                }
                "method" => {
                    if let Some(tinfo) = impl_type_info(node, bytes) {
                        ckind = Some("type");
                        cname_opt = Some(tinfo.0);
                        clnum = Some(tinfo.1);
                        ccol = Some(tinfo.2);
                    }
                }
                "function" => {
                    if let Some(finfo) = outer_fn_info(node, bytes) {
                        ckind = Some("function");
                        cname_opt = Some(finfo.0);
                        clnum = Some(finfo.1);
                        ccol = Some(finfo.2);
                    } else if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace");
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                "const" => {
                    if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace");
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                _ => {}
            }
        }

        // JavaScript 容器推断：method → class
        if cache.lang == "javascript"
            && kind == "method"
            && let Some(cls) = ancestor_kind(node, "class_declaration")
            && let Some(cls_name) = child_text_by_kind(cls, "identifier", bytes)
            && let Some((ln, co)) = child_pos_by_kind(cls, "identifier")
        {
            ckind = Some("class");
            cname_opt = Some(cls_name);
            clnum = Some(ln);
            ccol = Some(co);
        }

        // TypeScript/TSX 容器推断：method/field → class/interface，variant → enum
        if cache.lang == "typescript" || cache.lang == "tsx" {
            if kind == "method" || kind == "field" {
                for (ancestor, container_kind, name_kind) in [
                    ("class_declaration", "class", "type_identifier"),
                    ("abstract_class_declaration", "class", "type_identifier"),
                    ("interface_declaration", "type", "type_identifier"),
                ] {
                    if let Some(cls) = ancestor_kind(node, ancestor)
                        && let Some(cls_name) = child_text_by_kind(cls, name_kind, bytes)
                        && let Some((ln, co)) = child_pos_by_kind(cls, name_kind)
                    {
                        ckind = Some(container_kind);
                        cname_opt = Some(cls_name);
                        clnum = Some(ln);
                        ccol = Some(co);
                        break;
                    }
                }
            } else if kind == "variant"
                && let Some(en) = ancestor_kind(node, "enum_declaration")
                && let Some(enum_name) = child_text_by_kind(en, "identifier", bytes)
                && let Some((ln, co)) = child_pos_by_kind(en, "identifier")
            {
                ckind = Some("enum");
                cname_opt = Some(enum_name);
                clnum = Some(ln);
                ccol = Some(co);
            }
        }

        // JSON/YAML 容器推断：二级键 → 顶层键
        if (cache.lang == "json" || cache.lang == "yaml") && kind == "field" {
            let pair_kind = if cache.lang == "json" {
                "pair"
            } else {
                "block_mapping_pair"
            };
            let key_kind = if cache.lang == "json" {
                "string_content"
            } else {
                "string_scalar"
            };
            if let Some(own_pair) = ancestor_kind(node, pair_kind)
                && let Some(outer_pair) = ancestor_kind(own_pair, pair_kind)
                && let Some(key_node) = outer_pair
                    .child_by_field_name("key")
                    .and_then(|key| descendant_by_kind(key, key_kind))
            {
                let sp = key_node.start_position();
                ckind = Some("property");
                cname_opt = Some(node_text(key_node, bytes));
                clnum = Some(sp.row as u32 + 1);
                ccol = Some(sp.column as u32 + 1);
            }
        }

        // TOML 容器推断：pair → table
        if cache.lang == "toml"
            && kind == "property"
            && let Some(table) =
                ancestor_kind(node, "table").or_else(|| ancestor_kind(node, "table_array_element"))
        {
            for key_kind in ["bare_key", "dotted_key", "quoted_key"] {
                if let Some(key_name) = child_text_by_kind(table, key_kind, bytes)
                    && let Some((ln, co)) = child_pos_by_kind(table, key_kind)
                {
                    ckind = Some("namespace");
                    cname_opt = Some(key_name);
                    clnum = Some(ln);
                    ccol = Some(co);
                    break;
                }
            }
        }

        // Python 容器推断：method → class
        if cache.lang == "python"
            && kind == "method"
            && let Some(cls) = ancestor_kind(node, "class_definition")
            && let Some(cls_name) = child_text_by_kind(cls, "identifier", bytes)
            && let Some((ln, co)) = child_pos_by_kind(cls, "identifier")
        {
            ckind = Some("class");
            cname_opt = Some(cls_name);
            clnum = Some(ln);
            ccol = Some(co);
        }

        // Go 容器推断：method → receiver type, field → struct
        if cache.lang == "go" {
            if kind == "method" {
                // method_declaration 的 receiver 有 parameter_declaration → type_identifier
                if let Some(mdecl) = node.parent().filter(|p| p.kind() == "method_declaration") {
                    let mut c = mdecl.walk();
                    for ch in mdecl.children(&mut c) {
                        if ch.kind() == "parameter_list" {
                            let mut c2 = ch.walk();
                            for pd in ch.children(&mut c2) {
                                if pd.kind() == "parameter_declaration"
                                    && let Some(tname) =
                                        child_text_by_kind(pd, "type_identifier", bytes)
                                {
                                    let sp = pd.start_position();
                                    ckind = Some("type");
                                    cname_opt = Some(tname);
                                    clnum = Some(sp.row as u32 + 1);
                                    ccol = Some(sp.column as u32 + 1);
                                }
                            }
                            break;
                        }
                    }
                }
            } else if kind == "field"
                && let Some(type_spec) = ancestor_kind(node, "type_spec")
                && let Some(type_name) = child_text_by_kind(type_spec, "type_identifier", bytes)
                && let Some((ln, co)) = child_pos_by_kind(type_spec, "type_identifier")
            {
                ckind = Some("type");
                cname_opt = Some(type_name);
                clnum = Some(ln);
                ccol = Some(co);
            }
        }

        if cache.lang == "vim" {
            if kind == "namespace" && name == "END" {
                continue;
            }
            if kind == "variable" {
                // 处于函数内的变量：标注容器为 function，交给插件的 hide_inner 逻辑过滤
                let mut cur = node;
                let mut in_func = false;
                while let Some(parent) = cur.parent() {
                    let pk = parent.kind();
                    // 兼容你的 Vim9 语法（def_function）
                    if pk == "def_function"
                        || pk == "function_definition"
                        || pk == "vim9_function_definition"
                    {
                        in_func = true;
                        break;
                    }
                    cur = parent;
                }
                if in_func {
                    ckind = Some("function");
                }
            }
        }

        // 同一位置的 function/method 去重规则
        if let Some(&prev) = seen_at.get(&(lnum, col)) {
            if prev == "method" && kind == "function" {
                continue;
            }
            if prev == "function" && kind == "method" {
                if let Some(pos) = symbols.iter().position(|s: &Symbol| {
                    s.lnum == lnum && s.col == col && s.kind == "function" && s.name == name
                }) {
                    symbols.remove(pos);
                }
                seen_at.insert((lnum, col), "method");
            }
        } else {
            seen_at.insert((lnum, col), kind);
        }

        let key = (
            kind,
            name.clone(),
            lnum,
            col,
            ckind,
            cname_opt.clone(),
            clnum,
            ccol,
        );
        if seen.contains(&key) {
            continue;
        }
        seen.insert(key);

        symbols.push(Symbol {
            name,
            kind,
            lnum,
            col,
            end_lnum: sym_end_lnum,
            end_col: sym_end_col,
            container_kind: ckind,
            container_name: cname_opt,
            container_lnum: clnum,
            container_col: ccol,
        });
    }

    // 2) Vim9 grammar currently parses some valid `def`/`var` lines as generic
    // Ex commands. A small line-oriented fallback keeps the core outline useful
    // while the grammar evolves.
    if cache.lang == "vim" && symbols.len() < limit {
        for symbol in extract_vim_declarations(&cache.text, lrange, limit - symbols.len(), kinds) {
            let key = (
                symbol.kind,
                symbol.name.clone(),
                symbol.lnum,
                symbol.col,
                symbol.container_kind,
                symbol.container_name.clone(),
                symbol.container_lnum,
                symbol.container_col,
            );
            if seen.insert(key) {
                symbols.push(symbol);
            }
        }
    }

    // 3) 额外：Vim 语言从 command 节点中补充提取符号
    if cache.lang == "vim" && symbols.len() < limit {
        let mut stack = Vec::<tree_sitter::Node>::with_capacity(1024);
        stack.push(root);
        while let Some(n) = stack.pop() {
            if symbols.len() >= limit {
                break;
            }
            if n.kind() == "command" {
                let cmd_name_text = {
                    let mut cursor = n.walk();
                    n.children(&mut cursor)
                        .find(|c| c.kind() == "command_name")
                        .map(|c| node_text(c, bytes))
                };
                if let Some(ref cmd) = cmd_name_text {
                    let sp = n.start_position();
                    let lnum = sp.row as u32 + 1;
                    let col = sp.column as u32 + 1;

                    if let Some((ls, le)) = lrange
                        && (lnum < ls || lnum > le)
                    {
                        // 压入子节点继续遍历
                        let mut child_cursor = n.walk();
                        for ch in n.children(&mut child_cursor) {
                            stack.push(ch);
                        }
                        continue;
                    }

                    let cmd_lower = cmd.trim().to_lowercase();
                    let (sym_kind, sym_name) = match cmd_lower.as_str() {
                        // 映射命令
                        "nnoremap" | "vnoremap" | "inoremap" | "tnoremap" | "cnoremap"
                        | "xnoremap" | "onoremap" | "snoremap" | "noremap" | "nmap" | "vmap"
                        | "imap" | "tmap" | "cmap" | "xmap" | "omap" | "smap" | "map" => {
                            // 从源码行中提取 lhs
                            let line_text = {
                                let start_byte = n.start_byte();
                                let end_byte = n.end_byte();
                                let s = &bytes[start_byte..end_byte];
                                String::from_utf8_lossy(s).to_string()
                            };
                            // 解析：cmd [modifiers...] lhs rhs
                            let mut parts = line_text.split_whitespace();
                            let _cmd_part = parts.next(); // skip command name
                            let mut lhs = String::new();
                            for part in parts {
                                let pl = part.to_lowercase();
                                // 跳过独立修饰词
                                if pl == "<silent>"
                                    || pl == "<buffer>"
                                    || pl == "<expr>"
                                    || pl == "<nowait>"
                                    || pl == "<unique>"
                                    || pl == "<silent><expr>"
                                {
                                    continue;
                                }
                                // 第一个非修饰词就是 lhs
                                // 但可能以修饰词为前缀：<silent><leader>gk → 去掉 <silent>
                                let mut s = part.to_string();
                                loop {
                                    let sl = s.to_lowercase();
                                    let prefix_length = [
                                        "<silent>", "<buffer>", "<expr>", "<nowait>", "<unique>",
                                        "<script>",
                                    ]
                                    .into_iter()
                                    .find(|prefix| sl.starts_with(prefix))
                                    .map(str::len);
                                    let Some(prefix_length) = prefix_length else {
                                        break;
                                    };
                                    s = s[prefix_length..].to_string();
                                }
                                if s.is_empty() {
                                    continue;
                                }
                                lhs = s;
                                break;
                            }
                            if lhs.is_empty() {
                                (None, None)
                            } else {
                                (Some("mapping"), Some(format!("{} {}", cmd.trim(), lhs)))
                            }
                        }
                        // Plug 插件
                        "plug" => {
                            let mut cursor = n.walk();
                            let plug_name = n
                                .children(&mut cursor)
                                .find(|c| c.kind() == "safe_arg")
                                .map(|c| {
                                    let t = node_text(c, bytes).trim().to_string();
                                    // 'user/repo' -> repo
                                    let unquoted = t.trim_matches('\'').trim_matches('"');
                                    if let Some(slash) = unquoted.rfind('/') {
                                        unquoted[slash + 1..].to_string()
                                    } else {
                                        unquoted.to_string()
                                    }
                                });
                            match plug_name {
                                Some(name) => (Some("module"), Some(format!("Plug: {}", name))),
                                None => (None, None),
                            }
                        }
                        // Set 选项
                        "set" | "setlocal" | "setglobal" => {
                            let mut cursor = n.walk();
                            let opts: Vec<String> = n
                                .children(&mut cursor)
                                .filter(|c| c.kind() == "safe_arg" || c.kind() == "raw_text")
                                .map(|c| node_text(c, bytes).trim().to_string())
                                .collect();
                            let opts_str = opts.join(" ");
                            if opts_str.is_empty() {
                                (None, None)
                            } else {
                                (
                                    Some("property"),
                                    Some(format!("{} {}", cmd.trim(), opts_str)),
                                )
                            }
                        }
                        // Augroup
                        "augroup" => {
                            let mut cursor = n.walk();
                            let group = n
                                .children(&mut cursor)
                                .find(|c| c.kind() == "safe_arg")
                                .map(|c| node_text(c, bytes).trim().to_string());
                            match group {
                                Some(g) if g != "END" => {
                                    (Some("namespace"), Some(format!("augroup {}", g)))
                                }
                                _ => (None, None),
                            }
                        }
                        // Autocmd
                        "autocmd" | "autocmd!" => {
                            let mut cursor = n.walk();
                            let args: Vec<String> = n
                                .children(&mut cursor)
                                .filter(|c| c.kind() == "safe_arg")
                                .take(2)
                                .map(|c| node_text(c, bytes).trim().to_string())
                                .collect();
                            if args.is_empty() {
                                (None, None)
                            } else {
                                (Some("event"), Some(format!("autocmd {}", args.join(" "))))
                            }
                        }
                        // Colorscheme
                        "colorscheme" => {
                            let mut cursor = n.walk();
                            let scheme = n
                                .children(&mut cursor)
                                .find(|c| c.kind() == "safe_arg")
                                .map(|c| node_text(c, bytes).trim().to_string());
                            match scheme {
                                Some(s) => (Some("property"), Some(format!("colorscheme {}", s))),
                                None => (None, None),
                            }
                        }
                        // 传统函数声明 function!
                        "function!" => {
                            let mut cursor = n.walk();
                            let fname = n
                                .children(&mut cursor)
                                .find(|c| c.kind() == "safe_arg")
                                .map(|c| node_text(c, bytes).trim().to_string());
                            match fname {
                                Some(f) => (Some("function"), Some(f)),
                                None => (None, None),
                            }
                        }
                        // 用户自定义命令 command!
                        "command!" => {
                            let raw = {
                                let mut cursor = n.walk();
                                n.children(&mut cursor)
                                    .find(|c| c.kind() == "raw_text")
                                    .map(|c| node_text(c, bytes).trim().to_string())
                            };
                            match raw {
                                Some(r) => {
                                    // 跳过 -nargs=X 之类的选项，找到命令名
                                    let cmd_def_name = r
                                        .split_whitespace()
                                        .find(|w| !w.starts_with('-'))
                                        .unwrap_or(&r);
                                    (Some("method"), Some(format!("command! {}", cmd_def_name)))
                                }
                                None => (None, None),
                            }
                        }
                        // plug#begin / plug#end
                        s if s.contains('#') => (Some("namespace"), Some(cmd.trim().to_string())),
                        // filetype, syntax
                        "filetype" | "syntax" => {
                            let mut cursor = n.walk();
                            let args: Vec<String> = n
                                .children(&mut cursor)
                                .filter(|c| c.kind() == "safe_arg")
                                .map(|c| node_text(c, bytes).trim().to_string())
                                .collect();
                            (
                                Some("property"),
                                Some(format!("{} {}", cmd.trim(), args.join(" "))),
                            )
                        }
                        // highlight / hi
                        "highlight" | "hi" => {
                            let mut cursor = n.walk();
                            let args: Vec<String> = n
                                .children(&mut cursor)
                                .filter(|c| c.kind() == "safe_arg")
                                .take(1)
                                .map(|c| node_text(c, bytes).trim().to_string())
                                .collect();
                            if args.is_empty() {
                                (None, None)
                            } else {
                                (
                                    Some("property"),
                                    Some(format!("{} {}", cmd.trim(), args.join(" "))),
                                )
                            }
                        }
                        _ => (None, None),
                    };
                    if let (Some(kind), Some(name)) = (sym_kind, sym_name)
                        && symbol_kind_allowed(kind, kinds)
                    {
                        let key = (kind, name.clone(), lnum, col, None, None, None, None);
                        if !seen.contains(&key) {
                            seen.insert(key);
                            let ep = n.end_position();
                            symbols.push(Symbol {
                                name,
                                kind,
                                lnum,
                                col,
                                end_lnum: ep.row as u32 + 1,
                                end_col: ep.column as u32 + 1,
                                container_kind: None,
                                container_name: None,
                                container_lnum: None,
                                container_col: None,
                            });
                        }
                    }
                }
            }

            // 压入子节点
            let mut child_cursor = n.walk();
            for ch in n.children(&mut child_cursor) {
                stack.push(ch);
            }
        }
    }

    if cache.lang == "go" {
        let type_positions: HashMap<String, (u32, u32)> = symbols
            .iter()
            .filter(|symbol| symbol.kind == "type")
            .map(|symbol| (symbol.name.clone(), (symbol.lnum, symbol.col)))
            .collect();
        for symbol in &mut symbols {
            if symbol.container_kind == Some("type")
                && let Some(name) = &symbol.container_name
                && let Some((line, column)) = type_positions.get(name)
            {
                symbol.container_lnum = Some(*line);
                symbol.container_col = Some(*column);
            }
        }
    }

    symbols.sort_by_key(|s| (s.lnum, s.col));
    Ok((cache.revision, symbols))
}

/// Node kinds that produce folds per language. Plain string matching keeps
/// this table cheap and tolerant: a kind absent from a grammar simply never
/// matches.
fn foldable_kinds(lang: &str) -> &'static [&'static str] {
    match lang {
        "rust" => &[
            "function_item",
            "impl_item",
            "mod_item",
            "struct_item",
            "enum_item",
            "trait_item",
            "macro_definition",
            "match_expression",
            "block",
        ],
        "c" | "cpp" => &[
            "function_definition",
            "struct_specifier",
            "enum_specifier",
            "union_specifier",
            "class_specifier",
            "namespace_definition",
            "compound_statement",
        ],
        "javascript" => &[
            "function_declaration",
            "function_expression",
            "arrow_function",
            "method_definition",
            "class_declaration",
            "object",
            "statement_block",
            "switch_statement",
        ],
        "typescript" | "tsx" => &[
            "function_declaration",
            "function_expression",
            "arrow_function",
            "method_definition",
            "class_declaration",
            "abstract_class_declaration",
            "interface_declaration",
            "enum_declaration",
            "internal_module",
            "object",
            "statement_block",
            "switch_statement",
            "jsx_element",
        ],
        "python" => &[
            "function_definition",
            "class_definition",
            "if_statement",
            "for_statement",
            "while_statement",
            "try_statement",
            "with_statement",
            "match_statement",
        ],
        "go" => &[
            "function_declaration",
            "method_declaration",
            "func_literal",
            "type_declaration",
            "block",
        ],
        "bash" => &[
            "function_definition",
            "if_statement",
            "for_statement",
            "while_statement",
            "case_statement",
            "compound_statement",
        ],
        "vim" => &["def_function", "function_definition"],
        "json" => &["object", "array"],
        "yaml" => &["block_mapping", "block_sequence"],
        "toml" => &["table", "table_array_element"],
        "julia" => &[
            "function_definition",
            "macro_definition",
            "struct_definition",
            "module_definition",
            "if_statement",
            "for_statement",
            "while_statement",
            "try_statement",
            "let_statement",
            "compound_statement",
        ],
        "haskell" => &[
            "function",
            "class",
            "instance",
            "data_type",
            "newtype",
            "do",
            "case",
        ],
        _ => &[],
    }
}

// 从缓存树上收集折叠区间；level 为折叠祖先数量 + 1。
fn run_folds_cached(
    server: &Server,
    buf: i64,
    lang: &str,
    max_items: Option<usize>,
) -> Result<(u64, Vec<Fold>)> {
    let cache = server.get_cache(buf, lang)?;
    let kinds = foldable_kinds(lang);
    let limit = max_items.unwrap_or(MAX_FOLDS).min(MAX_FOLDS);
    let mut folds: Vec<Fold> = Vec::new();
    // (node, level, enclosing fold range) —— 与父 fold 完全同界的嵌套节点合并，
    // 否则 `fn f() { ... }` 会因 function_item 与 block 同界而叠出两层折叠。
    let mut stack = vec![(cache.tree.root_node(), 0_u32, None::<(u32, u32)>)];
    while let Some((node, level, parent_range)) = stack.pop() {
        if folds.len() >= limit {
            break;
        }
        let sp = node.start_position();
        let ep = node.end_position();
        let range = (sp.row as u32 + 1, ep.row as u32 + 1);
        let mut next_level = level;
        let mut next_range = parent_range;
        if kinds.contains(&node.kind()) && ep.row > sp.row && parent_range != Some(range) {
            folds.push(Fold {
                lnum: range.0,
                end_lnum: range.1,
                level: level + 1,
            });
            next_level = level + 1;
            next_range = Some(range);
        }
        let child_count = node.child_count().min(u32::MAX as usize);
        for index in (0..child_count).rev() {
            if let Some(child) = node.child(index as u32) {
                stack.push((child, next_level, next_range));
            }
        }
    }
    folds.sort_by_key(|fold| (fold.lnum, fold.level));
    Ok((cache.revision, folds))
}

fn extract_vim_declarations(
    text: &str,
    lrange: Option<(u32, u32)>,
    limit: usize,
    kinds: &[String],
) -> Vec<Symbol> {
    let mut symbols = Vec::<Symbol>::new();
    // (name, line, column, index in symbols). Vim functions do not normally
    // nest, but a stack makes malformed/in-progress edits behave predictably.
    let mut functions = Vec::<(String, u32, u32, Option<usize>)>::new();

    for (row, source_line) in text.lines().enumerate() {
        let line_number = row as u32 + 1;
        let leading = source_line.len() - source_line.trim_start().len();
        let mut line = source_line.trim_start();
        let mut declaration_offset = leading;
        if line.is_empty() || line.starts_with('"') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("export")
            && rest.starts_with(char::is_whitespace)
        {
            let trimmed = rest.trim_start();
            declaration_offset += "export".len() + (rest.len() - trimmed.len());
            line = trimmed;
        }

        if starts_with_vim_keyword(line, "enddef") || starts_with_vim_keyword(line, "endfunction") {
            if let Some((_, _, _, Some(index))) = functions.pop()
                && let Some(symbol) = symbols.get_mut(index)
            {
                symbol.end_lnum = line_number;
                symbol.end_col = source_line.len() as u32 + 1;
            }
            continue;
        }

        let function_keyword = ["def", "function!", "function"]
            .into_iter()
            .find(|keyword| starts_with_vim_keyword(line, keyword));
        if let Some(keyword) = function_keyword {
            let rest = &line[keyword.len()..];
            let name_part = rest.trim_start();
            let spaces = rest.len() - name_part.len();
            let name = name_part
                .split(|character: char| character == '(' || character.is_whitespace())
                .next()
                .unwrap_or("")
                .trim();
            if !name.is_empty() {
                let column = (declaration_offset + keyword.len() + spaces + 1) as u32;
                let in_range =
                    lrange.is_none_or(|(start, end)| line_number >= start && line_number <= end);
                let index = if in_range
                    && symbols.len() < limit
                    && symbol_kind_allowed("function", kinds)
                {
                    let container = functions.last();
                    symbols.push(Symbol {
                        name: name.to_string(),
                        kind: "function",
                        lnum: line_number,
                        col: column,
                        end_lnum: line_number,
                        end_col: source_line.len() as u32 + 1,
                        container_kind: container.map(|_| "function"),
                        container_name: container.map(|value| value.0.clone()),
                        container_lnum: container.map(|value| value.1),
                        container_col: container.map(|value| value.2),
                    });
                    Some(symbols.len() - 1)
                } else {
                    None
                };
                functions.push((name.to_string(), line_number, column, index));
            }
            continue;
        }

        let variable_keyword = ["var", "const", "final", "let"]
            .into_iter()
            .find(|keyword| starts_with_vim_keyword(line, keyword));
        if let Some(keyword) = variable_keyword {
            let kind = if matches!(keyword, "const" | "final") {
                "const"
            } else {
                "variable"
            };
            if !symbol_kind_allowed(kind, kinds)
                || symbols.len() >= limit
                || !lrange.is_none_or(|(start, end)| line_number >= start && line_number <= end)
            {
                continue;
            }
            let rest = &line[keyword.len()..];
            let name_part = rest.trim_start();
            let spaces = rest.len() - name_part.len();
            let raw_name = name_part
                .split(|character: char| character == '=' || character.is_whitespace())
                .next()
                .unwrap_or("");
            let name = raw_name.trim_end_matches(':');
            if name.is_empty() || name.starts_with('[') || name.starts_with('{') {
                continue;
            }
            let container = functions.last();
            symbols.push(Symbol {
                name: name.to_string(),
                kind,
                lnum: line_number,
                col: (declaration_offset + keyword.len() + spaces + 1) as u32,
                end_lnum: line_number,
                end_col: source_line.len() as u32 + 1,
                container_kind: container.map(|_| "function"),
                container_name: container.map(|value| value.0.clone()),
                container_lnum: container.map(|value| value.1),
                container_col: container.map(|value| value.2),
            });
        }
    }

    symbols
}

fn starts_with_vim_keyword(line: &str, keyword: &str) -> bool {
    let Some(rest) = line.strip_prefix(keyword) else {
        return false;
    };
    rest.is_empty() || rest.starts_with(char::is_whitespace)
}

/// Byte offset of a 1-based (line, byte column) pair, clamped into the line and
/// snapped back to a UTF-8 boundary. Vim's col() counts bytes, so a cursor
/// sitting on a continuation byte of a multi-byte character is impossible from
/// Vim itself but trivially reachable from a script; a mid-character offset
/// would make `descendant_for_byte_range` describe a neighbouring token.
fn point_byte_offset(cache: &BufCache, lnum: u32, col: u32) -> usize {
    let start = cache.line_index.line_start_byte(&cache.text, lnum.max(1));
    let mut end = cache
        .line_index
        .line_start_byte(&cache.text, lnum.max(1).saturating_add(1))
        .min(cache.text.len());
    if end > start && cache.text.as_bytes()[end - 1] == b'\n' {
        end -= 1;
    }
    let mut offset = start
        .saturating_add(col.max(1).saturating_sub(1) as usize)
        .min(end.max(start));
    while offset > start && !cache.text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

fn inspect_node(node: tree_sitter::Node) -> InspectNode {
    let sp = node.start_position();
    let ep = node.end_position();
    InspectNode {
        kind: node.kind().to_string(),
        named: node.is_named(),
        lnum: sp.row as u32 + 1,
        col: sp.column as u32 + 1,
        end_lnum: ep.row as u32 + 1,
        end_col: ep.column as u32 + 1,
        field: None,
    }
}

fn inspect_cached(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lnum: u32,
    col: u32,
) -> Result<(u64, Vec<InspectCapture>, Vec<InspectNode>)> {
    server.ensure_queries(lang)?;
    let cache = server.get_cache(buf, lang)?;
    let bytes = cache.text.as_bytes();
    let root = cache.tree.root_node();
    let offset = point_byte_offset(cache, lnum, col);
    let lang_queries = server.queries.get(&cache.lang).unwrap();

    // Node chain, innermost first. `field` is read from the parent because a
    // node does not know which slot it fills.
    let mut node_chain = Vec::new();
    if let Some(innermost) = root.descendant_for_byte_range(offset, offset) {
        let mut current = Some(innermost);
        while let Some(node) = current {
            let mut entry = inspect_node(node);
            if let Some(parent) = node.parent() {
                let mut cursor = parent.walk();
                if cursor.goto_first_child() {
                    loop {
                        if cursor.node() == node {
                            entry.field = cursor.field_name().map(str::to_string);
                            break;
                        }
                        if !cursor.goto_next_sibling() {
                            break;
                        }
                    }
                }
            }
            node_chain.push(entry);
            if node_chain.len() >= MAX_AST_DEPTH {
                break;
            }
            current = node.parent();
        }
    }

    // Same passes as run_highlight_cached, so an injected grammar's captures
    // show up here exactly when they show up on screen.
    let mut passes: Vec<(&tree_sitter::Query, tree_sitter::Node, Option<&'static str>)> =
        vec![(&lang_queries.hl_query, root, None)];
    for injected in &cache.injections {
        if let Some(query) = server.injection_queries.get(injected.lang) {
            passes.push((
                &query.hl_query,
                injected.tree.root_node(),
                Some(injected.lang),
            ));
        }
    }

    let mut captures: Vec<InspectCapture> = Vec::new();
    for (query, pass_root, injected_lang) in passes {
        let mut cursor = tree_sitter::QueryCursor::new();
        cursor.set_byte_range(offset..offset.saturating_add(1));
        let mut it = cursor.captures(query, pass_root, bytes);
        while let Some((m, cap_ix)) = it.next() {
            let node = m.captures[*cap_ix].node;
            // set_byte_range only bounds which patterns are considered; a match
            // may still report a capture that does not cover the point.
            if node.start_byte() > offset || node.end_byte() <= offset {
                continue;
            }
            // The renderer drops these, so the report must too, or :TsHlInspect
            // would name a group the screen does not show.
            if injected_lang.is_none() && covered_by_injection(&cache.injected_ranges, node) {
                continue;
            }
            let sp = node.start_position();
            let ep = node.end_position();
            let name = query.capture_names()[m.captures[*cap_ix].index as usize];
            captures.push(InspectCapture {
                capture: name.to_string(),
                group: map_capture_to_group(name),
                priority: capture_priority(name),
                lnum: sp.row as u32 + 1,
                col: sp.column as u32 + 1,
                end_lnum: ep.row as u32 + 1,
                end_col: ep.column as u32 + 1,
                applied: false,
                injected_lang,
            });
        }
    }

    // Mark the winner per exact span with the rule run_highlight_cached applies:
    // strictly greater priority replaces, so the first of a tie survives.
    let mut winners = HashMap::<(u32, u32, u32, u32), usize>::new();
    for index in 0..captures.len() {
        if captures[index].group.is_empty() {
            continue;
        }
        let key = (
            captures[index].lnum,
            captures[index].col,
            captures[index].end_lnum,
            captures[index].end_col,
        );
        match winners.get(&key) {
            Some(&best) if captures[index].priority <= captures[best].priority => {}
            _ => {
                winners.insert(key, index);
            }
        }
    }
    for index in winners.into_values() {
        captures[index].applied = true;
    }
    // Most specific first: the report's first line should be the answer.
    captures.sort_by_key(|capture| std::cmp::Reverse(capture.priority));

    Ok((cache.revision, captures, node_chain))
}

/// Grammar node kind -> text-object class, per language.
///
/// A table and not a name heuristic: `block` is a lexical block in Rust and a
/// mapping entry in other grammars, `class` is a JavaScript class expression
/// and a C++ storage specifier. A text object that matches the wrong node
/// silently edits the wrong text, which is far worse than not answering.
fn scope_table(lang: &str) -> &'static [(&'static str, &'static str)] {
    match lang {
        "rust" => &[
            ("function_item", "function"),
            ("function_signature_item", "function"),
            ("closure_expression", "function"),
            ("struct_item", "class"),
            ("enum_item", "class"),
            ("union_item", "class"),
            ("trait_item", "class"),
            ("impl_item", "class"),
            ("mod_item", "class"),
            ("block", "block"),
            ("call_expression", "call"),
            ("macro_invocation", "call"),
            ("if_expression", "conditional"),
            ("match_expression", "conditional"),
            ("for_expression", "loop"),
            ("while_expression", "loop"),
            ("loop_expression", "loop"),
        ],
        "c" | "cpp" => &[
            ("function_definition", "function"),
            ("lambda_expression", "function"),
            ("struct_specifier", "class"),
            ("union_specifier", "class"),
            ("enum_specifier", "class"),
            ("class_specifier", "class"),
            ("namespace_definition", "class"),
            ("compound_statement", "block"),
            ("call_expression", "call"),
            ("if_statement", "conditional"),
            ("switch_statement", "conditional"),
            ("for_statement", "loop"),
            ("for_range_loop", "loop"),
            ("while_statement", "loop"),
            ("do_statement", "loop"),
        ],
        // One table for the whole JavaScript family: the TypeScript-only kinds
        // simply never appear in a JavaScript tree, so splitting it would only
        // create two places to forget an entry.
        "javascript" | "typescript" | "tsx" => &[
            ("function_declaration", "function"),
            ("function_expression", "function"),
            ("generator_function", "function"),
            ("generator_function_declaration", "function"),
            ("arrow_function", "function"),
            ("method_definition", "function"),
            ("class_declaration", "class"),
            ("class", "class"),
            ("abstract_class_declaration", "class"),
            ("interface_declaration", "class"),
            ("enum_declaration", "class"),
            ("type_alias_declaration", "class"),
            ("internal_module", "class"),
            ("statement_block", "block"),
            ("call_expression", "call"),
            ("new_expression", "call"),
            ("if_statement", "conditional"),
            ("switch_statement", "conditional"),
            ("ternary_expression", "conditional"),
            ("for_statement", "loop"),
            ("for_in_statement", "loop"),
            ("while_statement", "loop"),
            ("do_statement", "loop"),
        ],
        "python" => &[
            ("function_definition", "function"),
            ("lambda", "function"),
            ("class_definition", "class"),
            ("block", "block"),
            ("call", "call"),
            ("if_statement", "conditional"),
            ("match_statement", "conditional"),
            ("for_statement", "loop"),
            ("while_statement", "loop"),
        ],
        "go" => &[
            ("function_declaration", "function"),
            ("method_declaration", "function"),
            ("func_literal", "function"),
            ("type_declaration", "class"),
            ("type_spec", "class"),
            ("block", "block"),
            ("call_expression", "call"),
            ("if_statement", "conditional"),
            ("expression_switch_statement", "conditional"),
            ("type_switch_statement", "conditional"),
            ("for_statement", "loop"),
        ],
        "bash" => &[
            ("function_definition", "function"),
            ("compound_statement", "block"),
            ("command", "call"),
            ("if_statement", "conditional"),
            ("case_statement", "conditional"),
            ("for_statement", "loop"),
            ("while_statement", "loop"),
        ],
        "lua" => &[
            ("function_declaration", "function"),
            ("function_definition", "function"),
            ("block", "block"),
            ("function_call", "call"),
            ("if_statement", "conditional"),
            ("for_statement", "loop"),
            ("while_statement", "loop"),
            ("repeat_statement", "loop"),
        ],
        "vim" => &[
            ("def_function", "function"),
            ("function_definition", "function"),
            ("if_statement", "conditional"),
            ("for_statement", "loop"),
            ("while_statement", "loop"),
        ],
        "julia" => &[
            ("function_definition", "function"),
            ("macro_definition", "function"),
            ("struct_definition", "class"),
            ("module_definition", "class"),
            ("compound_statement", "block"),
            ("call_expression", "call"),
            ("if_statement", "conditional"),
            ("try_statement", "conditional"),
            ("for_statement", "loop"),
            ("while_statement", "loop"),
        ],
        "haskell" => &[
            ("function", "function"),
            ("lambda", "function"),
            ("class", "class"),
            ("data_type", "class"),
            ("newtype", "class"),
            ("apply", "call"),
            ("conditional", "conditional"),
            ("case", "conditional"),
            ("do", "block"),
        ],
        "css" => &[("rule_set", "class"), ("block", "block")],
        _ => &[],
    }
}

/// True for nodes whose named children are individually addressable as
/// parameters or arguments.
///
/// Classifying by the container and not by a per-language list of parameter
/// node kinds, because a JavaScript parameter is a bare `identifier` — a kind
/// that means something else in every other position in the tree.
fn is_parameter_container(kind: &str) -> bool {
    matches!(
        kind,
        "parameters"
            | "formal_parameters"
            | "parameter_list"
            | "lambda_parameters"
            | "type_parameters"
            | "type_parameter_list"
            | "arguments"
            | "argument_list"
            | "type_arguments"
    )
}

fn scope_kind(lang: &str, node: tree_sitter::Node) -> Option<&'static str> {
    let kind = node.kind();
    // Spelled the same in every bundled grammar, so it does not earn a row in
    // seventeen tables.
    if matches!(kind, "comment" | "line_comment" | "block_comment") {
        return Some("comment");
    }
    if let Some((_, class)) = scope_table(lang).iter().find(|(k, _)| *k == kind) {
        return Some(class);
    }
    // Reached only when the node has no class of its own, which is what keeps a
    // closure argument answering to `af` rather than to `aa`.
    if node.is_named()
        && let Some(parent) = node.parent()
        && is_parameter_container(parent.kind())
    {
        return Some("parameter");
    }
    None
}

/// Byte range of the "inner" half of a text object: the node's body with its
/// delimiters and the whitespace they left behind removed.
///
/// `consequence` and `arguments` are listed beside `body` because a conditional
/// and a call keep their interesting child in a differently named field, and
/// falling back to the node itself is what makes a delimiter-only node such as
/// a Rust `block` still produce a useful inner range.
fn inner_byte_range(node: tree_sitter::Node, text: &str) -> (usize, usize) {
    let target = ["body", "consequence", "arguments"]
        .into_iter()
        .find_map(|field| node.child_by_field_name(field))
        .unwrap_or(node);
    let mut start = target.start_byte();
    let mut end = target.end_byte();
    let count = target.child_count().min(u32::MAX as usize);
    if count >= 2
        && let (Some(first), Some(last)) = (target.child(0), target.child(count as u32 - 1))
        && !first.is_named()
        && !last.is_named()
        && matches!(first.kind(), "{" | "(" | "[")
        && matches!(last.kind(), "}" | ")" | "]")
    {
        start = first.end_byte();
        end = last.start_byte();
    }
    // Without this, `dif` on a function body deletes the newline the opening
    // brace sat on and leaves the closing brace hanging off the signature.
    let bytes = text.as_bytes();
    while start < end && bytes[start].is_ascii_whitespace() {
        start += 1;
    }
    while end > start && bytes[end - 1].is_ascii_whitespace() {
        end -= 1;
    }
    (start, end)
}

/// Outer range of a parameter or argument: the node plus the separator that
/// would otherwise be left behind.
///
/// `daa` on the middle argument of `f(a, b, c)` has to leave `f(a, c)` and not
/// `f(a, , c)`; on the last one there is no following comma, so the preceding
/// one is taken instead.
fn parameter_outer_byte_range(node: tree_sitter::Node, text: &str) -> (usize, usize) {
    let start = node.start_byte();
    let end = node.end_byte();
    let mut sibling = node.next_sibling();
    while let Some(next) = sibling {
        if next.is_named() {
            break;
        }
        if next.kind() == "," {
            // Whitespace is not in the tree, so swallow the run after the comma
            // by hand or `f(a, b)` loses `a,` and keeps its space.
            let mut after = next.end_byte();
            let bytes = text.as_bytes();
            while after < text.len() && (bytes[after] == b' ' || bytes[after] == b'\t') {
                after += 1;
            }
            return (start, after);
        }
        sibling = next.next_sibling();
    }
    let mut previous = node.prev_sibling();
    while let Some(prior) = previous {
        if prior.is_named() {
            break;
        }
        if prior.kind() == "," {
            return (prior.start_byte(), end);
        }
        previous = prior.prev_sibling();
    }
    (start, end)
}

fn scope_node(node: tree_sitter::Node, cache: &BufCache) -> ScopeNode {
    let kind = scope_kind(&cache.lang, node);
    let is_parameter = kind == Some("parameter");
    // The common case is the node's own range, and the node already knows its
    // points; only the parameter form has to be located in the text.
    let (outer_sp, outer_ep) = if is_parameter {
        let (start, end) = parameter_outer_byte_range(node, &cache.text);
        (
            cache.line_index.point_at_byte(&cache.text, start),
            cache.line_index.point_at_byte(&cache.text, end),
        )
    } else {
        (node.start_position(), node.end_position())
    };
    // A parameter has no body to reach into, so its inner half is the node
    // itself — that is exactly the difference `daa` vs `dia` is asked to make.
    let (inner_start, inner_end) = if is_parameter {
        (node.start_byte(), node.end_byte())
    } else {
        inner_byte_range(node, &cache.text)
    };
    let inner_sp = cache.line_index.point_at_byte(&cache.text, inner_start);
    let inner_ep = cache.line_index.point_at_byte(&cache.text, inner_end);
    ScopeNode {
        node: node.kind(),
        kind,
        lnum: outer_sp.row as u32 + 1,
        col: outer_sp.column as u32 + 1,
        end_lnum: outer_ep.row as u32 + 1,
        end_col: outer_ep.column as u32 + 1,
        inner_lnum: inner_sp.row as u32 + 1,
        inner_col: inner_sp.column as u32 + 1,
        inner_end_lnum: inner_ep.row as u32 + 1,
        inner_end_col: inner_ep.column as u32 + 1,
    }
}

/// One `scope` answer.
struct ScopeAnswer {
    revision: u64,
    /// 1-based `[lnum, col, end_lnum, end_col]` of the region in which every
    /// point resolves to the same node and therefore to this same chain.
    anchor: [u32; 4],
    chain: Vec<ScopeNode>,
}

/// Byte range around `offset` in which `descendant_for_byte_range` keeps
/// answering `node`.
///
/// This is *not* the node's own range: at a column of leading indentation the
/// resolved node is the whole enclosing block, and a client that cached the
/// block's range would keep serving that coarse chain after the cursor moved
/// onto a statement inside it. `descendant_for_byte_range` returns the smallest
/// node containing the point, so no child of `node` covers `offset` and the
/// answer holds exactly across the gap between its neighbouring children.
fn stable_byte_range(node: tree_sitter::Node, offset: usize) -> (usize, usize) {
    let mut low = node.start_byte();
    let mut high = node.end_byte();
    let mut cursor = node.walk();
    if cursor.goto_first_child() {
        loop {
            let child = cursor.node();
            if child.end_byte() <= offset {
                low = low.max(child.end_byte());
            } else if child.start_byte() > offset {
                high = high.min(child.start_byte());
                break;
            } else {
                // A child covering the point should have been the descendant.
                // Zero-width error/missing nodes can still land here; refuse to
                // let the client cache anything rather than guess.
                return (offset, offset);
            }
            if !cursor.goto_next_sibling() {
                break;
            }
        }
    }
    (low, high)
}

fn scope_chain_cached(
    server: &Server,
    buf: i64,
    lang: &str,
    lnum: u32,
    col: u32,
) -> Result<ScopeAnswer> {
    let cache = server.get_cache(buf, lang)?;
    let offset = point_byte_offset(cache, lnum, col);
    let resolved = cache
        .tree
        .root_node()
        .descendant_for_byte_range(offset, offset);
    let anchor = match resolved {
        Some(node) => {
            let (low, high) = stable_byte_range(node, offset);
            let start = cache.line_index.point_at_byte(&cache.text, low);
            let end = cache.line_index.point_at_byte(&cache.text, high);
            [
                start.row as u32 + 1,
                start.column as u32 + 1,
                end.row as u32 + 1,
                end.column as u32 + 1,
            ]
        }
        // No node at all: an empty range, so a client can only ever treat the
        // reply as immediately stale rather than caching it forever.
        None => [lnum, col, lnum, col],
    };
    let mut chain: Vec<ScopeNode> = Vec::new();
    let mut current = resolved;
    while let Some(node) = current {
        // Anonymous nodes are punctuation: never a text object, and never a
        // step a user would recognise while growing a selection.
        if node.is_named() {
            chain.push(scope_node(node, cache));
            if chain.len() >= MAX_SCOPE_CHAIN {
                break;
            }
        }
        current = node.parent();
    }
    Ok(ScopeAnswer {
        revision: cache.revision,
        anchor,
        chain,
    })
}

fn dump_ast_cached(server: &mut Server, buf: i64, lang: &str) -> Result<(u64, Vec<String>)> {
    let cache = server.get_cache(buf, lang)?;
    let root = cache.tree.root_node();
    let (lines, _) = format_ast(root, MAX_AST_NODES, MAX_AST_DEPTH);
    Ok((cache.revision, lines))
}

/// Format an AST while keeping both the result and pending traversal stack
/// within `node_limit`. Returning the peak stack size lets regression tests
/// verify that a very wide node cannot bypass the output budget.
fn format_ast(
    root: tree_sitter::Node,
    node_limit: usize,
    depth_limit: usize,
) -> (Vec<String>, usize) {
    if node_limit == 0 {
        return (Vec::new(), 0);
    }
    let mut lines = Vec::new();
    let mut stack = vec![(root, 0_usize)];
    let mut max_pending_nodes = stack.len();
    let mut nodes_truncated = false;
    let mut depth_truncated = false;
    while let Some((node, depth)) = stack.pop() {
        if lines.len() >= node_limit {
            nodes_truncated = true;
            break;
        }
        let sp = node.start_position();
        let ep = node.end_position();
        let indent = (depth * 2).min(MAX_AST_INDENT);
        let depth_marker = if depth * 2 > MAX_AST_INDENT {
            "… "
        } else {
            ""
        };
        lines.push(format!(
            "{:indent$}{}{} [{}:{} - {}:{}]",
            "",
            depth_marker,
            node.kind(),
            sp.row + 1,
            sp.column + 1,
            ep.row + 1,
            ep.column + 1,
            indent = indent
        ));

        if depth >= depth_limit {
            depth_truncated = true;
            continue;
        }

        // Pending siblings already consume part of the same hard node budget.
        // Only enqueue children that can still be visited; never materialize an
        // arbitrarily wide child list merely to discard it on the next loop.
        let remaining_slots = node_limit.saturating_sub(lines.len().saturating_add(stack.len()));
        let child_count = node.child_count().min(u32::MAX as usize);
        let scheduled_children = child_count.min(remaining_slots);
        if scheduled_children < child_count {
            nodes_truncated = true;
        }
        for index in (0..scheduled_children).rev() {
            if let Some(child) = node.child(index as u32) {
                stack.push((child, depth + 1));
            }
        }
        max_pending_nodes = max_pending_nodes.max(stack.len());
    }

    if nodes_truncated || depth_truncated {
        let marker = match (nodes_truncated, depth_truncated) {
            (true, true) => {
                format!("... AST truncated at {node_limit} nodes and depth {depth_limit} ...")
            }
            (true, false) => format!("... AST truncated at {node_limit} nodes ..."),
            (false, true) => {
                format!("... branches deeper than {depth_limit} nodes were truncated ...")
            }
            (false, false) => unreachable!(),
        };
        if lines.len() < node_limit {
            lines.push(marker);
        } else if let Some(last) = lines.last_mut() {
            *last = marker;
        }
    }

    (lines, max_pending_nodes)
}

fn bracket_depth(node: tree_sitter::Node) -> u32 {
    let mut depth: u32 = 0;
    let mut cur = node.parent();
    while let Some(p) = cur {
        // Delimited grammar nodes expose their opening/closing token as an
        // edge child. Checking two children keeps this O(tree depth), even
        // when the source root itself has millions of children.
        let last_child = p.child_count().saturating_sub(1).min(u32::MAX as usize) as u32;
        let has_brackets = [p.child(0), p.child(last_child)]
            .into_iter()
            .flatten()
            .any(|child| matches!(child.kind(), "(" | ")" | "{" | "}" | "[" | "]"));
        if has_brackets {
            depth += 1;
        }
        cur = p.parent();
    }
    depth
}

fn capture_priority(name: &str) -> u8 {
    match name {
        "variable" => 0,
        "constant" | "number" | "boolean" | "string" => 2,
        "keyword" | "operator" | "punctuation.delimiter" | "punctuation.bracket" => 3,
        "variable.parameter" | "variable.builtin" | "constant.builtin" => 5,
        "property" | "field" | "function" | "method" | "type" | "namespace" => 8,
        name if name.contains('.') => 9,
        _ => 4,
    }
}

fn map_capture_to_group(name: &str) -> &'static str {
    match name {
        "comment" => "TSComment",
        "spell" => "TSComment",
        "string" => "TSString",
        "string.regex" => "TStringRegex",
        "string.escape" => "TStringEscape",
        "string.special" => "TStringSpecial",
        "string.documentation" => "TSString",
        "number" => "TSNumber",
        "boolean" => "TSBoolean",
        "null" => "TSConstant",

        "keyword" => "TSKeyword",
        "keyword.operator" => "TSKeywordOperator",
        "operator" => "TSOperator",
        "punctuation.delimiter" => "TSPunctDelimiter",
        "punctuation.bracket" => "TSPunctBracket",
        "punctuation.special" => "TSPunctDelimiter",

        "variable" => "TSVariable",
        "variable.parameter" => "TSVariableParameter",
        "variable.builtin" => "TSVariableBuiltin",
        "variable.member" => "TSProperty",
        "constant" => "TSConstant",
        "constant.builtin" => "TSConstBuiltin",

        "property" => "TSProperty",
        "field" => "TSField",

        "function" => "TSFunction",
        "method" => "TSMethod",
        "function.builtin" => "TSFunctionBuiltin",
        "function.macro" => "TSMacro",

        "type" => "TSType",
        "type.builtin" => "TSTypeBuiltin",
        "namespace" => "TSNamespace",
        "macro" => "TSMacro",
        "attribute" => "TSAttribute",

        "character" => "TSString",
        "number.float" => "TSNumber",
        "module" => "TSNamespace",
        "constructor" => "TSType",

        "text.title" => "TSTitle",
        "text.literal" => "TSLiteral",
        "text.emphasis" => "TSEmphasis",
        "text.strong" => "TSStrong",
        "text.strike" => "TSStrike",
        "text.uri" => "TSURI",
        "text.reference" => "TSLink",

        name if name.starts_with("comment.") => "TSComment",
        name if name.starts_with("string.special") => "TStringSpecial",
        name if name.starts_with("function.") => "TSFunction",
        name if name.starts_with("keyword.") => "TSKeyword",
        name if name.starts_with("type.") => "TSType",
        _ => "",
    }
}

fn map_symbol_capture(name: &str) -> &'static str {
    match name {
        "symbol.function" => "function",
        "symbol.method" => "method",
        "symbol.type" => "type",
        "symbol.struct" => "struct",
        "symbol.enum" => "enum",
        "symbol.class" => "class",
        "symbol.namespace" => "namespace",
        "symbol.variable" => "variable",
        "symbol.const" => "const",
        "symbol.macro" => "macro",
        "symbol.property" => "property",
        "symbol.field" => "field",
        "symbol.variant" => "variant",
        _ => "",
    }
}

#[allow(dead_code)]
fn is_ident_char(b: u8) -> bool {
    (b as char).is_ascii_alphanumeric() || b == b'_'
}

fn node_text(node: tree_sitter::Node, bytes: &[u8]) -> String {
    let s = &bytes[node.start_byte()..node.end_byte()];
    String::from_utf8_lossy(s).to_string()
}

/// 收集树中指定 kind 的全部节点区间（不递归进匹配到的节点内部）。
/// True when an injected grammar owns every byte of `node`.
///
/// The ranges are in document order, so a binary search finds the only
/// candidate; a highlight pass calls this once per host capture.
fn covered_by_injection(ranges: &[ops::Range<usize>], node: tree_sitter::Node) -> bool {
    if ranges.is_empty() {
        return false;
    }
    let start = node.start_byte();
    let index = match ranges.binary_search_by_key(&start, |range| range.start) {
        Ok(index) => index,
        Err(0) => return false,
        Err(index) => index - 1,
    };
    ranges[index].start <= start && node.end_byte() <= ranges[index].end
}

/// Which grammar an injection rule hands its content to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InjectionTarget {
    /// Always this grammar, whatever the content says.
    Fixed(&'static str),
    /// Read it off the fence's info string, e.g. ```` ```rust ````. Unknown or
    /// absent languages are skipped, which is why an unlabelled fence keeps the
    /// host's own `@text.literal`.
    InfoString,
}

/// One "this node's content is another language" rule.
struct InjectionRule {
    /// Node kind that introduces the injection.
    host: &'static str,
    /// Named descendant holding the injected text; `None` injects the host node
    /// itself, which is what markdown's `inline` needs.
    content: Option<&'static str>,
    target: InjectionTarget,
}

/// Injection rules for a host language.
///
/// Depth is capped at one by construction: `collect_injection_ranges` does not
/// descend into a node it has already matched, so a fence inside a fence is
/// left to the outer grammar and the cost of a sync stays linear.
fn injection_rules(lang: &str) -> &'static [InjectionRule] {
    match lang {
        "markdown" => &[
            // The block grammar leaves every span of prose as one opaque
            // `inline` node; without this, emphasis and links are invisible.
            InjectionRule {
                host: "inline",
                content: None,
                target: InjectionTarget::Fixed("markdown_inline"),
            },
            InjectionRule {
                host: "fenced_code_block",
                content: Some("code_fence_content"),
                target: InjectionTarget::InfoString,
            },
        ],
        "html" => &[
            InjectionRule {
                host: "script_element",
                content: Some("raw_text"),
                target: InjectionTarget::Fixed("javascript"),
            },
            InjectionRule {
                host: "style_element",
                content: Some("raw_text"),
                target: InjectionTarget::Fixed("css"),
            },
        ],
        _ => &[],
    }
}

/// Map a fence info string to a bundled grammar, or `None`.
///
/// The aliases are the ones people actually write in fences; anything not
/// resolving to a linked grammar is skipped rather than guessed at.
fn injection_language_for_tag(tag: &str) -> Option<&'static str> {
    let normalized = tag.trim().to_ascii_lowercase();
    let name = match normalized.as_str() {
        "rs" => "rust",
        "js" | "jsx" | "mjs" | "cjs" | "node" => "javascript",
        "ts" => "typescript",
        "tsx" => "tsx",
        "py" | "python3" => "python",
        "sh" | "shell" | "zsh" | "console" => "bash",
        "golang" => "go",
        "c++" | "cxx" | "hpp" => "cpp",
        "h" => "c",
        "yml" => "yaml",
        "vim9" | "viml" => "vim",
        "md" => "markdown",
        "jl" => "julia",
        "hs" => "haskell",
        other => other,
    };
    SUPPORTED_LANGUAGES
        .iter()
        .copied()
        .find(|supported| *supported == name)
}

/// Read the language tag out of a `fenced_code_block`'s info string.
fn fence_info_language(node: tree_sitter::Node, text: &str) -> Option<&'static str> {
    let info = descendant_by_kind(node, "info_string")?;
    // tree-sitter-md wraps the tag in a `language` node; older trees leave the
    // whole info string bare, so fall back to its first word.
    let tag = descendant_by_kind(info, "language").unwrap_or(info);
    let raw = text.get(tag.start_byte()..tag.end_byte())?;
    injection_language_for_tag(raw.split_whitespace().next().unwrap_or(""))
}

fn collect_injection_ranges(
    node: tree_sitter::Node,
    rules: &'static [InjectionRule],
    text: &str,
    out: &mut Vec<(&'static str, tree_sitter::Range)>,
) {
    if out.len() >= MAX_INJECTED_RANGES {
        return;
    }
    if let Some(rule) = rules.iter().find(|rule| rule.host == node.kind()) {
        let target = match rule.target {
            InjectionTarget::Fixed(name) => Some(name),
            InjectionTarget::InfoString => fence_info_language(node, text),
        };
        let content = match rule.content {
            Some(kind) => descendant_by_kind(node, kind),
            None => Some(node),
        };
        if let (Some(target), Some(content)) = (target, content)
            && content.end_byte() > content.start_byte()
        {
            out.push((target, content.range()));
        }
        // Matched or not, this subtree belongs to the host rule: not descending
        // is what caps injection depth at one.
        return;
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_injection_ranges(child, rules, text, out);
    }
}

// ---- Rust-specific helpers (保持不变) ----
fn ancestor_kind<'a>(mut node: tree_sitter::Node<'a>, want: &str) -> Option<tree_sitter::Node<'a>> {
    while let Some(parent) = node.parent() {
        if parent.kind() == want {
            return Some(parent);
        }
        node = parent;
    }
    None
}

fn definition_node<'a>(
    node: tree_sitter::Node<'a>,
    lang: &str,
    kind: &str,
) -> tree_sitter::Node<'a> {
    let candidates: &[&str] = match (lang, kind) {
        ("rust", "function" | "method") => &["function_item"],
        ("rust", "struct") => &["struct_item"],
        ("rust", "enum") => &["enum_item"],
        ("rust", "type") => &["trait_item", "type_item"],
        ("rust", "const") => &["const_item", "static_item"],
        ("rust", "namespace") => &["mod_item"],
        ("rust", "macro") => &["macro_definition"],
        ("rust", "field") => &["field_declaration"],
        ("rust", "variant") => &["enum_variant"],

        ("c" | "cpp", "function" | "method") => {
            &["function_definition", "field_declaration", "declaration"]
        }
        ("c" | "cpp", "class") => &["class_specifier"],
        ("c" | "cpp", "struct") => &["struct_specifier", "type_definition"],
        ("c" | "cpp", "enum") => &["enum_specifier"],
        ("c" | "cpp", "namespace") => &["namespace_definition"],
        ("c" | "cpp", "type") => &["alias_declaration", "type_definition"],
        ("c" | "cpp", "variable") => &["declaration"],

        ("javascript", "function") => &["function_declaration"],
        ("javascript", "method") => &["method_definition"],
        ("javascript", "class") => &["class_declaration"],
        ("javascript", "variable") => &["variable_declarator", "variable_declaration"],

        ("typescript" | "tsx", "function") => &["function_declaration", "function_signature"],
        ("typescript" | "tsx", "method") => &[
            "method_definition",
            "method_signature",
            "abstract_method_signature",
        ],
        ("typescript" | "tsx", "class") => &["class_declaration", "abstract_class_declaration"],
        ("typescript" | "tsx", "type") => &["interface_declaration", "type_alias_declaration"],
        ("typescript" | "tsx", "enum") => &["enum_declaration"],
        ("typescript" | "tsx", "namespace") => &["internal_module", "module"],
        ("typescript" | "tsx", "variable") => &["variable_declarator", "variable_declaration"],
        ("typescript" | "tsx", "field") => &["public_field_definition", "property_signature"],
        // 变体本身就是叶子；有赋值时也只取名字，避免退化到整个 enum_body。
        ("typescript" | "tsx", "variant") => &["property_identifier"],

        ("json", "property" | "field") => &["pair"],
        ("yaml", "property" | "field") => &["block_mapping_pair"],
        ("toml", "namespace") => &["table", "table_array_element"],
        ("toml", "property") => &["pair"],

        ("python", "function" | "method") => &["function_definition"],
        ("python", "class") => &["class_definition"],
        ("python", "variable") => &["assignment", "expression_statement"],
        ("python", "type") => &["type_alias_statement"],

        ("go", "function") => &["function_declaration"],
        ("go", "method") => &["method_declaration"],
        ("go", "type") => &["type_spec", "type_alias"],
        ("go", "const") => &["const_spec", "const_declaration"],
        ("go", "variable") => &["var_spec", "var_declaration"],
        ("go", "field") => &["field_declaration"],

        ("bash", "function") => &["function_definition"],
        ("bash", "variable") => &["variable_assignment"],

        ("vim", "function") => &["def_function"],
        ("vim", "variable" | "const") => &["let_statement", "const_statement"],
        _ => &[],
    };

    let mut current = Some(node);
    while let Some(candidate) = current {
        if candidates.contains(&candidate.kind()) {
            return candidate;
        }
        current = candidate.parent();
    }
    node.parent().unwrap_or(node)
}

/// Depth-first search for the first descendant (including `node`) of `kind`.
fn descendant_by_kind<'a>(
    node: tree_sitter::Node<'a>,
    kind: &str,
) -> Option<tree_sitter::Node<'a>> {
    if node.kind() == kind {
        return Some(node);
    }
    let child_count = node.child_count().min(u32::MAX as usize);
    for index in 0..child_count {
        if let Some(child) = node.child(index as u32)
            && let Some(found) = descendant_by_kind(child, kind)
        {
            return Some(found);
        }
    }
    None
}

fn child_text_by_kind(node: tree_sitter::Node, child_kind: &str, bytes: &[u8]) -> Option<String> {
    let mut cursor = node.walk();
    for ch in node.children(&mut cursor) {
        if ch.kind() == child_kind {
            return Some(node_text(ch, bytes));
        }
    }
    None
}
fn child_pos_by_kind(node: tree_sitter::Node, child_kind: &str) -> Option<(u32, u32)> {
    let mut cursor = node.walk();
    for ch in node.children(&mut cursor) {
        if ch.kind() == child_kind {
            let sp = ch.start_position();
            return Some((sp.row as u32 + 1, sp.column as u32 + 1));
        }
    }
    None
}
fn struct_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(st) = ancestor_kind(node, "struct_item")
        && let Some(name) = child_text_by_kind(st, "type_identifier", bytes)
        && let Some((ln, co)) = child_pos_by_kind(st, "type_identifier")
    {
        return Some((name, ln, co));
    }
    None
}
fn enum_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(en) = ancestor_kind(node, "enum_item")
        && let Some(name) = child_text_by_kind(en, "type_identifier", bytes)
        && let Some((ln, co)) = child_pos_by_kind(en, "type_identifier")
    {
        return Some((name, ln, co));
    }
    None
}
fn variant_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "enum_variant"
            && let Some(name) = child_text_by_kind(parent, "identifier", bytes)
            && let Some((ln, co)) = child_pos_by_kind(parent, "identifier")
        {
            return Some((name, ln, co));
        }
        cur = parent;
    }
    None
}
fn impl_type_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(im) = ancestor_kind(node, "impl_item") {
        let mut last: Option<(String, u32, u32)> = None;
        let mut cursor = im.walk();
        for ch in im.children(&mut cursor) {
            if ch.kind() == "type_identifier" || ch.kind() == "identifier" {
                let name = node_text(ch, bytes);
                let sp = ch.start_position();
                last = Some((name, sp.row as u32 + 1, sp.column as u32 + 1));
            }
        }
        if let Some(x) = last {
            return Some(x);
        }
    }
    None
}
fn mod_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(md) = ancestor_kind(node, "mod_item")
        && let Some(name) = child_text_by_kind(md, "identifier", bytes)
        && let Some((ln, co)) = child_pos_by_kind(md, "identifier")
    {
        return Some((name, ln, co));
    }
    None
}
fn outer_fn_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    let mut cur = node;
    let mut skipped_current = false;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "function_item" {
            if !skipped_current {
                skipped_current = true;
                cur = parent;
                continue;
            }
            if let Some(name) = child_text_by_kind(parent, "identifier", bytes)
                && let Some((ln, co)) = child_pos_by_kind(parent, "identifier")
            {
                return Some((name, ln, co));
            }
        }
        cur = parent;
    }
    None
}
#[allow(dead_code)]
fn has_ancestor_of(node: tree_sitter::Node, kinds: &[&str]) -> bool {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        for &k in kinds {
            if parent.kind() == k {
                return true;
            }
        }
        cur = parent;
    }
    false
}

// 如需拿到父函数名，可用这个辅助（可选）
#[allow(dead_code)]
fn vim_func_name(node: tree_sitter::Node, bytes: &[u8]) -> Option<String> {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "function_definition" || parent.kind() == "vim9_function_definition" {
            // 找到声明节点，取里面的名字（identifier/scoped_identifier/field_expression）
            let mut cursor = parent.walk();
            for ch in parent.children(&mut cursor) {
                if ch.kind() == "function_declaration" || ch.kind() == "vim9_function_declaration" {
                    let mut c2 = ch.walk();
                    for nm in ch.children(&mut c2) {
                        match nm.kind() {
                            "identifier" | "scoped_identifier" | "field_expression" => {
                                return Some(node_text(nm, bytes));
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
        cur = parent;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `set_text` advertises a `MAX_SOURCE_BYTES` ceiling, but that check runs
    /// only after the record has been read into a `String` and serde has parsed
    /// a second copy of `text` out of it -- so it can only protect the daemon if
    /// something bounds the request line *before* it is materialised.  Reverting
    /// `serve()` to `BufReader::lines()` fails every assertion here: that reader
    /// has no cap at all, so it grows one `String` to whatever arrives and hands
    /// it back as a perfectly valid line.
    #[test]
    fn stdin_is_bounded_before_the_request_is_materialized() {
        // No newline anywhere -- the shape that never reaches `set_text`.  The
        // bound is answered from the bytes seen so far, not from a finished
        // record, so the reader refuses long before EOF would arrive.
        let unterminated = vec![b'x'; 6400];
        let mut reader = BufReader::new(unterminated.as_slice());
        assert_eq!(
            read_request_line(&mut reader, 64)
                .unwrap()
                .unwrap()
                .unwrap_err(),
            "request line exceeds 64 bytes"
        );

        // An oversized record is discarded, not retained: nothing of it is
        // carried into the reply, and no allocation of its size outlives it.
        let mut with_newline = BufReader::new(&b"aaaaaaaaaaaaaaaaaaaaaaaa\n"[..]);
        assert!(
            read_request_line(&mut with_newline, 8)
                .unwrap()
                .unwrap()
                .is_err()
        );

        // Invalid UTF-8 is a rejected record, not a dead daemon.  `lines()`
        // surfaced it as an io::Error, which the request loop could only treat
        // as end-of-stream.
        let mut invalid = BufReader::new(&b"\xff\xfe\n{\"type\":\"status\"}\n"[..]);
        assert_eq!(
            read_request_line(&mut invalid, 64).unwrap().unwrap(),
            Err("request line is not valid UTF-8".to_string())
        );
        assert_eq!(
            read_request_line(&mut invalid, 64).unwrap().unwrap(),
            Ok(r#"{"type":"status"}"#.to_string())
        );
    }

    /// One oversized record must not desynchronise the stream behind it: the
    /// reader resumes at the next newline and the request after it is served.
    #[test]
    fn bounded_request_reader_recovers_at_the_next_record() {
        let input = b"0123456789\n{\"type\":\"status\"}\r\n";
        let mut reader = BufReader::new(&input[..]);

        let oversized = read_request_line(&mut reader, 8)
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert_eq!(oversized, "request line exceeds 8 bytes");

        let next = read_request_line(&mut reader, 64)
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(next, r#"{"type":"status"}"#);
        assert!(matches!(
            serde_json::from_str::<Request>(&next).unwrap(),
            Request::Status
        ));
        assert!(read_request_line(&mut reader, 64).unwrap().is_none());

        // A record of exactly the limit is not over it, and the CRLF framing
        // byte is not charged against the JSON line's documented length.
        let mut exact_crlf = BufReader::new(&b"12345678\r\n"[..]);
        assert_eq!(
            read_request_line(&mut exact_crlf, 8)
                .unwrap()
                .unwrap()
                .unwrap(),
            "12345678"
        );
    }

    /// The reader must not reject a request `set_text` would have accepted, so
    /// the limit is derived from `MAX_SOURCE_BYTES` and the widest expansion
    /// `serde_json` can apply to a buffer body.
    #[test]
    fn request_line_limit_admits_a_worst_case_body_at_the_source_limit() {
        // A control byte is the widest escape serde_json emits: six ASCII bytes
        // for one source byte.  Nothing else expands further.
        let sample = "\u{1}".repeat(4096);
        let encoded = serde_json::to_string(&sample).unwrap();
        assert_eq!(encoded.len(), sample.len() * 6 + 2);

        let envelope = serde_json::to_string(&serde_json::json!({
            "type": "set_text",
            "buf": i64::MIN,
            "lang": "typescript",
            "revision": u64::MAX,
            "text": "",
        }))
        .unwrap()
        .len();
        assert!(
            envelope < 1024,
            "set_text envelope grew to {envelope} bytes"
        );
        assert!(MAX_REQUEST_LINE_BYTES >= MAX_SOURCE_BYTES * 6 + envelope);

        // `edit_lines` splits the same body across a JSON array.  Its worst
        // ratio is all-empty lines, where each `","` costs three bytes for the
        // one source byte (the newline) that line contributes -- still inside
        // the same six-fold ceiling, so one constant covers both requests.
        let lines = vec![String::new(); 4096];
        let source_bytes: usize = lines.iter().map(|line| line.len() + 1).sum();
        assert!(serde_json::to_string(&lines).unwrap().len() <= source_bytes * 6);
    }

    #[test]
    fn symbol_request_ids_are_additive_and_echoed_on_success_and_error() {
        let legacy: Request =
            serde_json::from_str(r#"{"type":"symbols","buf":3,"lang":"rust"}"#).unwrap();
        match legacy {
            Request::Symbols { request_id, .. } => assert_eq!(request_id, 0),
            _ => panic!("wrong legacy request variant"),
        }

        let current: Request =
            serde_json::from_str(r#"{"type":"symbols","buf":3,"lang":"rust","request_id":77}"#)
                .unwrap();
        match current {
            Request::Symbols { request_id, .. } => assert_eq!(request_id, 77),
            _ => panic!("wrong current request variant"),
        }

        let success = serde_json::to_value(Event::Symbols {
            buf: 3,
            revision: 9,
            request_id: 77,
            symbols: Some(Vec::new()),
            digest: digest_symbols(&[]),
            unchanged: false,
        })
        .unwrap();
        assert_eq!(success["request_id"], 77);

        let error = serde_json::to_value(Event::Error {
            message: "synthetic".into(),
            buf: Some(3),
            op: Some("symbols"),
            request_id: Some(77),
        })
        .unwrap();
        assert_eq!(error["request_id"], 77);
    }

    #[test]
    fn byte_offsets_use_tree_sitter_byte_columns() {
        let text = "αβ\nhello\n世界";
        assert_eq!(byte_offset_to_point(text, 0), tree_sitter::Point::new(0, 0));
        assert_eq!(byte_offset_to_point(text, 4), tree_sitter::Point::new(0, 4));
        assert_eq!(byte_offset_to_point(text, 5), tree_sitter::Point::new(1, 0));
        assert_eq!(
            byte_offset_to_point(text, 10),
            tree_sitter::Point::new(1, 5)
        );
        assert_eq!(
            byte_offset_to_point(text, text.len()),
            tree_sitter::Point::new(2, 6)
        );
    }

    #[test]
    fn input_edit_handles_insert_delete_and_unicode() {
        let cases = [
            ("fn main() {}", "fn main() { let x = 1; }"),
            ("one\ntwo\nthree", "one\nthree"),
            ("let café = 1;", "let 咖啡 = 2;"),
            ("αβγ", "αxγ"),
            ("", "hello\nworld"),
        ];

        for (old, new) in cases {
            let edit = compute_input_edit(old, new).expect("texts differ");
            assert!(old.is_char_boundary(edit.start_byte));
            assert!(old.is_char_boundary(edit.old_end_byte));
            assert!(new.is_char_boundary(edit.new_end_byte));
            assert_eq!(
                edit.start_position,
                byte_offset_to_point(old, edit.start_byte)
            );
            assert_eq!(
                edit.old_end_position,
                byte_offset_to_point(old, edit.old_end_byte)
            );
            assert_eq!(
                edit.new_end_position,
                byte_offset_to_point(new, edit.new_end_byte)
            );
        }
        assert!(compute_input_edit("same", "same").is_none());
    }

    #[test]
    fn incremental_parse_matches_full_parse() {
        let old = "fn main() {\n    println!(\"hello\");\n}\n";
        let new = "fn main() {\n    let café = 42;\n    println!(\"{café}\");\n}\n";
        let language: tree_sitter::Language = tree_sitter_rust::LANGUAGE.into();
        let mut parser = tree_sitter::Parser::new();
        parser.set_language(&language).unwrap();
        let mut edited_tree = parser.parse(old, None).unwrap();
        edited_tree.edit(&compute_input_edit(old, new).unwrap());
        let incremental = parser.parse(new, Some(&edited_tree)).unwrap();
        let full = parser.parse(new, None).unwrap();
        assert_eq!(
            incremental.root_node().to_sexp(),
            full.root_node().to_sexp()
        );
    }

    #[test]
    fn line_ranges_are_clamped_and_utf8_safe() {
        let text = "one\n二\nthree";
        assert_eq!(line_range_to_byte_range(text, 1, 1), 0..4);
        assert_eq!(line_range_to_byte_range(text, 2, 2), 4..8);
        assert_eq!(line_range_to_byte_range(text, 2, 3), 4..text.len());
        assert_eq!(
            line_range_to_byte_range(text, 99, 100),
            text.len()..text.len()
        );
        assert_eq!(line_range_to_byte_range(text, 3, 1), 8..text.len());
    }

    #[test]
    fn sparse_line_index_stays_small_and_exact_for_newline_heavy_text() {
        let newline_count = LINE_INDEX_STRIDE * 32 + 17;
        let text = "\n".repeat(newline_count);
        let index = SparseLineIndex::new(&text);

        assert_eq!(index.line_count, newline_count + 1);
        assert_eq!(
            index.checkpoints.len(),
            newline_count / LINE_INDEX_STRIDE + 1
        );
        let checkpoint_bytes = std::mem::size_of_val(index.checkpoints.as_ref());
        assert_eq!(
            checkpoint_bytes,
            index.checkpoints.len() * std::mem::size_of::<usize>()
        );
        assert!(
            checkpoint_bytes <= (text.len() / LINE_INDEX_STRIDE + 1) * std::mem::size_of::<usize>()
        );
        assert!(index.checkpoints.len() * 200 < index.line_count);

        for line in [
            1,
            2,
            LINE_INDEX_STRIDE as u32,
            LINE_INDEX_STRIDE as u32 + 1,
            (LINE_INDEX_STRIDE * 17 + 93) as u32,
            newline_count as u32 + 1,
            newline_count as u32 + 2,
        ] {
            let expected = usize::try_from(line.saturating_sub(1))
                .unwrap()
                .min(text.len());
            assert_eq!(index.line_start_byte(&text, line), expected, "line {line}");
        }
    }

    #[test]
    fn bounded_ast_dump_never_queues_all_children_of_a_wide_root() {
        let source = (0..256)
            .map(|index| format!("int item_{index};\n"))
            .collect::<String>();
        let language: tree_sitter::Language = tree_sitter_c::LANGUAGE.into();
        let mut parser = tree_sitter::Parser::new();
        parser.set_language(&language).unwrap();
        let tree = parser.parse(&source, None).unwrap();
        let root = tree.root_node();
        let node_limit = 32;

        assert!(root.child_count() > node_limit);
        let (lines, max_pending_nodes) = format_ast(root, node_limit, MAX_AST_DEPTH);
        assert!(lines.len() <= node_limit);
        assert!(max_pending_nodes <= node_limit);
        assert!(lines.last().unwrap().contains("truncated"));
    }

    #[test]
    fn all_language_queries_compile() {
        let mut server = Server::new();
        for lang in SUPPORTED_LANGUAGES {
            server
                .ensure_queries(lang)
                .unwrap_or_else(|error| panic!("failed to compile {lang} queries: {error}"));
            let queries = server.queries.get(*lang).unwrap();
            for capture in queries.hl_query.capture_names() {
                assert!(
                    capture.starts_with('_') || !map_capture_to_group(capture).is_empty(),
                    "{lang} has unmapped highlight capture @{capture}"
                );
            }
            for capture in queries.sym_query.capture_names() {
                assert!(
                    !map_symbol_capture(capture).is_empty(),
                    "{lang} has unmapped symbol capture @{capture}"
                );
            }
            for pattern in 0..queries.hl_query.pattern_count() {
                assert!(
                    queries.hl_query.general_predicates(pattern).is_empty(),
                    "{lang} highlight query pattern {pattern} has an unhandled general predicate"
                );
            }
            for pattern in 0..queries.sym_query.pattern_count() {
                assert!(
                    queries.sym_query.general_predicates(pattern).is_empty(),
                    "{lang} symbol query pattern {pattern} has an unhandled general predicate"
                );
            }
        }
        assert_eq!(server.queries.len(), SUPPORTED_LANGUAGES.len());

        // ensure_queries() compiles every fixed injection target too, so a
        // broken injected query fails --self-test rather than silently leaving
        // one construct uncoloured.
        for (name, injection) in &server.injection_queries {
            for capture in injection.hl_query.capture_names() {
                assert!(
                    !map_capture_to_group(capture).is_empty(),
                    "injection {name} has unmapped highlight capture @{capture}"
                );
            }
            for pattern in 0..injection.hl_query.pattern_count() {
                assert!(
                    injection.hl_query.general_predicates(pattern).is_empty(),
                    "injection {name} pattern {pattern} has an unhandled general predicate"
                );
            }
        }
        for required in ["markdown_inline", "javascript", "css"] {
            assert!(
                server.injection_queries.contains_key(required),
                "no compiled injection query for {required}: {:?}",
                server.injection_queries.keys().collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn markdown_highlights_symbols_and_inline_tree() {
        let mut server = Server::new();
        let source = "# Top\n\nSome *emphasis*, **strong**, `code span` and \
                      [a link](https://example.com).\n\n## Second level\n\n\
                      ```rust\nfn main() {}\n```\n\n- [x] done task\n\n\
                      Setext Title\n============\n";
        server
            .set_text(9, "markdown", source.to_string(), 1)
            .expect("markdown parse");
        let injected: Vec<&str> = server
            .cache
            .get(&9)
            .unwrap()
            .injections
            .iter()
            .map(|injection| injection.lang)
            .collect();
        assert!(
            injected.contains(&"markdown_inline"),
            "inline tree must be built for markdown: {injected:?}"
        );
        assert!(
            injected.contains(&"rust"),
            "a ```rust fence must inject the rust grammar: {injected:?}"
        );

        let (_, spans) =
            run_highlight_cached(&mut server, 9, "markdown", None, false, None).unwrap();
        let groups: Vec<&str> = spans.iter().map(|s| s.group).collect();
        for expected in [
            "TSTitle",    // headings (block)
            "TSEmphasis", // *emphasis* (inline)
            "TSStrong",   // **strong** (inline)
            "TSLiteral",  // `code span` (the fence content is injected instead)
            "TSLink",     // [a link]
            "TSURI",      // (https://example.com)
            "TSType",     // fence info string "rust"
            "TSBoolean",  // task list marker
        ] {
            assert!(
                groups.contains(&expected),
                "missing {expected} in {groups:?}"
            );
        }

        let (_, symbols) = run_symbols_cached(&mut server, 9, "markdown", None, None).unwrap();
        let names: Vec<(&str, &str)> = symbols.iter().map(|s| (s.kind, s.name.as_str())).collect();
        assert!(names.contains(&("namespace", "Top")), "{names:?}");
        assert!(names.contains(&("class", "Second level")), "{names:?}");
        assert!(names.contains(&("namespace", "Setext Title")), "{names:?}");

        // Plain text without emphasis/links: the inline pass must not panic and
        // the block-only path still renders. Also exercises the resync path.
        server
            .set_text(9, "markdown", "# Only heading\n".to_string(), 2)
            .expect("markdown reparse");
        let (_, spans) =
            run_highlight_cached(&mut server, 9, "markdown", None, false, None).unwrap();
        assert!(spans.iter().any(|s| s.group == "TSTitle"));
    }

    /// A fenced block is the first thing anyone notices about markdown
    /// highlighting, and getting it half right is worse than not doing it: the
    /// host query paints the whole fence `@text.literal`, so if that span
    /// survived the injection the user would see one flat colour with tokens
    /// fighting underneath it.
    #[test]
    fn a_labelled_fence_is_parsed_by_its_own_grammar_in_host_coordinates() {
        let mut server = Server::new();
        let source = "Prose with a héllo before it.\n\n```rust\nfn main() { let x = 1; }\n```\n\n\
                      ```\nplain fence, no language\n```\n";
        server
            .set_text(11, "markdown", source.to_string(), 1)
            .unwrap();

        let (_, spans) =
            run_highlight_cached(&mut server, 11, "markdown", None, false, None).unwrap();

        // `fn` is on line 4, column 1 of the *host* document: set_included_ranges
        // keeps injected positions in the host's coordinate space, and the
        // multi-byte character above must not shift them.
        let keyword = spans
            .iter()
            .find(|span| span.group == "TSKeyword" && span.lnum == 4)
            .unwrap_or_else(|| panic!("rust fence produced no keyword: {spans:?}"));
        assert_eq!((keyword.col, keyword.end_col), (1, 3));

        // The host's flat literal over the injected fence is gone...
        assert!(
            !spans
                .iter()
                .any(|span| span.group == "TSLiteral" && span.lnum == 4),
            "the host @text.literal survived on top of the injected fence: {spans:?}"
        );
        // ...but an unlabelled fence keeps it, because nothing replaced it.
        assert!(
            spans
                .iter()
                .any(|span| span.group == "TSLiteral" && span.lnum == 8),
            "an unlabelled fence lost its literal highlighting: {spans:?}"
        );

        // :TsHlInspect has to agree with the screen, or it answers "why is this
        // token this colour" with a colour that is not drawn.
        let (_, captures, _) = inspect_cached(&mut server, 11, "markdown", 4, 1).unwrap();
        assert!(
            captures.iter().any(
                |capture| capture.group == "TSKeyword" && capture.injected_lang == Some("rust")
            ),
            "inspect did not attribute the capture to the injected grammar: {captures:?}"
        );
        assert!(
            captures.iter().all(|capture| capture.group != "TSLiteral"),
            "inspect reported a host capture the renderer drops: {captures:?}"
        );
    }

    #[test]
    fn html_injects_javascript_and_css() {
        let mut server = Server::new();
        let source = "<html>\n<style>\nbody { color: red; }\n</style>\n\
                      <script>\nfunction go() { return 1; }\n</script>\n</html>\n";
        server.set_text(12, "html", source.to_string(), 1).unwrap();
        let injected: Vec<&str> = server
            .cache
            .get(&12)
            .unwrap()
            .injections
            .iter()
            .map(|injection| injection.lang)
            .collect();
        assert!(injected.contains(&"css"), "{injected:?}");
        assert!(injected.contains(&"javascript"), "{injected:?}");

        let (_, spans) = run_highlight_cached(&mut server, 12, "html", None, false, None).unwrap();
        assert!(
            spans
                .iter()
                .any(|span| span.lnum == 6 && span.group == "TSKeyword"),
            "<script> body was not highlighted as javascript: {spans:?}"
        );
        assert!(
            spans.iter().any(|span| span.lnum == 3),
            "<style> body produced no highlighting at all: {spans:?}"
        );
    }

    /// Unknown fence tags are skipped rather than guessed at, and a fence inside
    /// a fence must not start a second level of injection.
    #[test]
    fn injections_skip_unknown_languages_and_do_not_nest() {
        assert_eq!(injection_language_for_tag("rs"), Some("rust"));
        assert_eq!(injection_language_for_tag("  Python3 "), Some("python"));
        assert_eq!(injection_language_for_tag("brainfuck"), None);
        assert_eq!(injection_language_for_tag(""), None);

        let mut server = Server::new();
        let source = "````markdown\n```rust\nfn inner() {}\n```\n````\n";
        server
            .set_text(13, "markdown", source.to_string(), 1)
            .unwrap();
        let injected: Vec<&str> = server
            .cache
            .get(&13)
            .unwrap()
            .injections
            .iter()
            .map(|injection| injection.lang)
            .collect();
        assert!(
            injected.contains(&"markdown"),
            "the outer fence did not inject markdown: {injected:?}"
        );
        assert!(
            !injected.contains(&"rust"),
            "an injected fence started a second level of injection: {injected:?}"
        );
    }

    #[test]
    fn covered_by_injection_only_swallows_fully_contained_spans() {
        let mut server = Server::new();
        server
            .set_text(14, "markdown", "```rust\nfn f() {}\n```\n".to_string(), 1)
            .unwrap();
        let cache = server.cache.get(&14).unwrap();
        let ranges = &cache.injected_ranges;
        assert_eq!(ranges.len(), 1, "{ranges:?}");

        let block = cache
            .tree
            .root_node()
            .child(0)
            .expect("a fenced code block");
        assert!(
            !covered_by_injection(ranges, block),
            "the fence itself must survive: its delimiters are not injected"
        );
        let content = descendant_by_kind(block, "code_fence_content").expect("fence content");
        assert!(covered_by_injection(ranges, content));
    }

    #[test]
    fn server_reuses_trees_and_preserves_revisions() {
        let mut server = Server::new();
        assert_eq!(
            server
                .set_text(7, "rust", "fn first() {}".to_string(), 10)
                .unwrap(),
            ParseMode::Full
        );
        assert_eq!(
            server
                .set_text(7, "rust", "fn second() {}".to_string(), 11)
                .unwrap(),
            ParseMode::Incremental
        );
        assert_eq!(
            server
                .set_text(7, "rust", "fn second() {}".to_string(), 12)
                .unwrap(),
            ParseMode::Unchanged
        );

        let (revision, spans) =
            run_highlight_cached(&mut server, 7, "rust", None, true, None).unwrap();
        assert_eq!(revision, 12);
        assert!(!spans.is_empty());
        assert_eq!(server.full_parses, 1);
        assert_eq!(server.incremental_parses, 1);
        assert_eq!(server.unchanged_syncs, 1);
    }

    #[test]
    fn symbols_include_definition_ranges() {
        let mut server = Server::new();
        let source = "struct User { name: String }\nfn greet() {}\nimpl User { fn method(&self) {} }\nfn outer() { fn inner() {} }\n";
        server.set_text(1, "rust", source.to_string(), 3).unwrap();
        let (revision, symbols) = run_symbols_cached(&mut server, 1, "rust", None, None).unwrap();
        assert_eq!(revision, 3);
        assert!(symbols.iter().any(|symbol| symbol.name == "User"));
        let greet = symbols
            .iter()
            .find(|symbol| symbol.name == "greet")
            .unwrap();
        assert_eq!(greet.kind, "function");
        assert!(greet.container_kind.is_none());
        let method = symbols
            .iter()
            .find(|symbol| symbol.name == "method")
            .unwrap();
        assert_eq!(method.kind, "method");
        assert_eq!(method.container_name.as_deref(), Some("User"));
        let inner = symbols
            .iter()
            .find(|symbol| symbol.name == "inner")
            .unwrap();
        assert_eq!(inner.container_kind, Some("function"));
        assert_eq!(inner.container_name.as_deref(), Some("outer"));
        assert!(symbols.iter().all(|symbol| symbol.end_lnum >= symbol.lnum));
    }

    #[test]
    fn symbol_kind_filter_is_applied_before_result_limit() {
        let mut server = Server::new();
        let source = "const A: i32 = 1;\nconst B: i32 = 2;\nfn target() {}\n";
        server
            .set_text(42, "rust", source.to_string(), 1)
            .expect("rust parse");

        let (_, symbols) = run_symbols_cached_filtered(
            &mut server,
            42,
            "rust",
            None,
            Some(1),
            &["function".to_string()],
        )
        .expect("filtered symbols");
        assert_eq!(symbols.len(), 1);
        assert_eq!(symbols[0].name, "target");
        assert_eq!(symbols[0].kind, "function");
    }

    #[test]
    fn rust_keywords_are_highlighted_as_keywords() {
        let mut server = Server::new();
        let source = "pub fn answer() -> i32 { let value = 42; return value; }\n";
        server.set_text(1, "rust", source.to_string(), 1).unwrap();
        let (_, spans) = run_highlight_cached(&mut server, 1, "rust", None, false, None).unwrap();
        let keyword_count = spans
            .iter()
            .filter(|span| span.group == "TSKeyword")
            .count();
        assert!(keyword_count >= 4, "keyword spans: {spans:?}");
        assert!(spans.iter().all(|span| span.depth.is_none()));
    }

    /// `:TsHlInspect` must answer "why is this token this colour, and which
    /// group do I override" with the same facts the renderer used.
    #[test]
    fn inspect_reports_captures_groups_and_the_node_chain() {
        let mut server = Server::new();
        let source = "pub fn answer() -> i32 { 42 }\n";
        server.set_text(1, "rust", source.to_string(), 7).unwrap();
        // Column 5 is the 'f' of `fn`.
        let (revision, captures, chain) = inspect_cached(&mut server, 1, "rust", 1, 5).unwrap();
        assert_eq!(revision, 7);

        let keyword = captures
            .iter()
            .find(|capture| capture.capture == "keyword")
            .unwrap_or_else(|| panic!("no @keyword capture: {captures:?}"));
        assert_eq!(keyword.group, "TSKeyword");
        assert_eq!(keyword.priority, capture_priority("keyword"));
        assert_eq!((keyword.lnum, keyword.col), (1, 5));
        assert_eq!((keyword.end_lnum, keyword.end_col), (1, 7));
        assert!(keyword.applied, "the winning capture was not marked");
        // Highest priority first, so the first line of the report is the answer.
        assert_eq!(captures.first().map(|c| c.priority), Some(keyword.priority));

        // Innermost first, up to the root, with parent field names attached.
        assert_eq!(chain.first().map(|node| node.kind.as_str()), Some("fn"));
        assert_eq!(
            chain.last().map(|node| node.kind.as_str()),
            Some("source_file")
        );
        let function = chain
            .iter()
            .find(|node| node.kind == "function_item")
            .unwrap_or_else(|| panic!("no enclosing function_item: {chain:?}"));
        assert_eq!((function.lnum, function.end_lnum), (1, 1));

        // Column 8 is the function's name; a node that fills a named slot in
        // its parent reports which slot, which is what makes the chain usable
        // for writing a query.
        let (_, name_captures, name_chain) = inspect_cached(&mut server, 1, "rust", 1, 8).unwrap();
        assert_eq!(
            name_chain.first().map(|node| node.field.as_deref()),
            Some(Some("name")),
            "innermost node did not report its parent field: {name_chain:?}"
        );
        assert!(
            name_captures
                .iter()
                .any(|capture| capture.group == "TSFunction"),
            "function name is not captured as a function: {name_captures:?}"
        );
    }

    /// A byte column landing inside a multi-byte character must not describe a
    /// neighbouring token, and a column past the end of the line must clamp.
    #[test]
    fn inspect_clamps_columns_to_the_line_and_to_utf8_boundaries() {
        let mut server = Server::new();
        let source = "let s = \"héllo\";\nlet t = 1;\n";
        server.set_text(1, "rust", source.to_string(), 1).unwrap();
        // 'é' starts at byte column 11 and occupies columns 11-12.
        let (_, mid_char, _) = inspect_cached(&mut server, 1, "rust", 1, 12).unwrap();
        let (_, boundary, _) = inspect_cached(&mut server, 1, "rust", 1, 11).unwrap();
        assert_eq!(
            mid_char
                .iter()
                .map(|c| (c.capture.as_str(), c.col))
                .collect::<Vec<_>>(),
            boundary
                .iter()
                .map(|c| (c.capture.as_str(), c.col))
                .collect::<Vec<_>>(),
        );

        // Well past the end of line 1: still line 1, never line 2's content.
        let (_, _, chain) = inspect_cached(&mut server, 1, "rust", 1, 9_000).unwrap();
        assert!(
            chain.iter().all(|node| node.lnum <= 1),
            "clamped column escaped its line: {chain:?}"
        );
    }

    /// `point_at_byte` is the only byte -> position conversion the text objects
    /// have, and it is the one place a checkpoint off-by-one would put every
    /// inner range on the wrong line without any other test noticing. Compare
    /// it against a naive scan at every byte of a text that crosses several
    /// checkpoint strides and carries multi-byte characters.
    #[test]
    fn point_at_byte_agrees_with_a_naive_scan_across_checkpoint_strides() {
        let mut text = String::new();
        for line in 0..(LINE_INDEX_STRIDE * 3 + 7) {
            text.push_str(&format!("line {line} héllo\n"));
        }
        text.push_str("no trailing newline");
        let index = SparseLineIndex::new(&text);

        let mut row = 0_usize;
        let mut line_start = 0_usize;
        for offset in 0..=text.len() {
            let expected = tree_sitter::Point {
                row,
                column: offset - line_start,
            };
            assert_eq!(
                index.point_at_byte(&text, offset),
                expected,
                "byte {offset} mapped to the wrong point"
            );
            if text.as_bytes().get(offset) == Some(&b'\n') {
                row += 1;
                line_start = offset + 1;
            }
        }
        // Past the end clamps rather than panicking on the slice.
        assert_eq!(
            index.point_at_byte(&text, text.len() + 500),
            index.point_at_byte(&text, text.len())
        );
    }

    #[test]
    fn scope_chain_separates_outer_and_inner_ranges() {
        let mut server = Server::new();
        let source = "fn outer(first: i32, second: i32) -> i32 {\n    \
                      let total = first + second;\n    total\n}\n";
        server.set_text(3, "rust", source.to_string(), 12).unwrap();

        // Cursor on `total` inside the body.
        let answer = scope_chain_cached(&server, 3, "rust", 2, 9).unwrap();
        let (revision, chain) = (answer.revision, answer.chain);
        assert_eq!(revision, 12);
        assert_eq!(
            chain.last().map(|node| node.node),
            Some("source_file"),
            "chain does not reach the root: {chain:?}"
        );
        let function = chain
            .iter()
            .find(|node| node.kind == Some("function"))
            .unwrap_or_else(|| panic!("no enclosing function: {chain:?}"));
        assert_eq!(function.node, "function_item");
        // Outer spans the whole item; inner is the body with braces and the
        // whitespace they left behind removed.
        assert_eq!(
            (
                function.lnum,
                function.col,
                function.end_lnum,
                function.end_col
            ),
            (1, 1, 4, 2)
        );
        assert_eq!(
            (
                function.inner_lnum,
                function.inner_col,
                function.inner_end_lnum,
                function.inner_end_col
            ),
            (2, 5, 3, 10)
        );

        // A parameter's outer range swallows the separator that would otherwise
        // be left behind; the last one takes the comma in front of it instead.
        let at_second = scope_chain_cached(&server, 3, "rust", 1, 22).unwrap().chain;
        let second = at_second
            .iter()
            .find(|node| node.kind == Some("parameter"))
            .unwrap_or_else(|| panic!("no parameter at the cursor: {at_second:?}"));
        assert_eq!(
            (second.col, second.end_col),
            (20, 33),
            "last parameter did not take the preceding comma"
        );
        assert_eq!((second.inner_col, second.inner_end_col), (22, 33));

        let at_first = scope_chain_cached(&server, 3, "rust", 1, 10).unwrap().chain;
        let first = at_first
            .iter()
            .find(|node| node.kind == Some("parameter"))
            .unwrap_or_else(|| panic!("no parameter at the cursor: {at_first:?}"));
        assert_eq!(
            (first.col, first.end_col),
            (10, 22),
            "parameter outer did not swallow the trailing comma and space"
        );
        assert_eq!((first.inner_col, first.inner_end_col), (10, 20));
    }

    /// A node carries exactly one class, so a closure passed as an argument is
    /// reachable with `af`/`if` and does not also masquerade as a parameter with
    /// a contradictory outer range.
    #[test]
    fn a_closure_argument_is_classified_as_a_function_not_a_parameter() {
        let mut server = Server::new();
        let source = "fn main() {\n    let v = items.map(|x| x + 1);\n}\n";
        server.set_text(4, "rust", source.to_string(), 1).unwrap();
        // Column 27 is inside `|x| x + 1`.
        let chain = scope_chain_cached(&server, 4, "rust", 2, 27).unwrap().chain;
        let closure = chain
            .iter()
            .find(|node| node.node == "closure_expression")
            .unwrap_or_else(|| panic!("no closure in the chain: {chain:?}"));
        assert_eq!(closure.kind, Some("function"));
        assert!(
            chain
                .iter()
                .take_while(|node| node.node != "closure_expression")
                .all(|node| node.kind != Some("parameter")),
            "the closure argument was also reported as a parameter: {chain:?}"
        );
    }

    /// Incremental selection walks the chain outward, so it must be ordered
    /// innermost-first and every step must contain the previous one.
    #[test]
    fn scope_chain_is_ordered_innermost_first_and_nests() {
        let mut server = Server::new();
        let source = "def f(a, b):\n    x = a + b\n    return x\n";
        server.set_text(5, "python", source.to_string(), 1).unwrap();
        let chain = scope_chain_cached(&server, 5, "python", 2, 9)
            .unwrap()
            .chain;
        assert!(chain.len() >= 3, "chain is too short: {chain:?}");
        for pair in chain.windows(2) {
            let (inner, outer) = (&pair[0], &pair[1]);
            assert!(
                (outer.lnum, outer.col) <= (inner.lnum, inner.col)
                    && (outer.end_lnum, outer.end_col) >= (inner.end_lnum, inner.end_col),
                "chain step is not nested: {outer:?} does not contain {inner:?}"
            );
        }

        // Python has no braces: the inner half of a function is its suite, and
        // the delimiter-stripping must not eat anything it should not.
        let function = chain
            .iter()
            .find(|node| node.kind == Some("function"))
            .unwrap_or_else(|| panic!("no enclosing function: {chain:?}"));
        assert_eq!(
            (
                function.inner_lnum,
                function.inner_col,
                function.inner_end_lnum,
                function.inner_end_col
            ),
            (2, 5, 3, 13)
        );
    }

    /// The client caches one reply for the whole anchor range and asks again
    /// only when the cursor leaves it, so the anchor has to be exactly the set
    /// of columns that produce this chain. Were it ever too wide, a text object
    /// would silently act on a chain belonging to a different token.
    #[test]
    fn every_column_inside_the_anchor_reproduces_the_same_chain() {
        let mut server = Server::new();
        let source = "fn main() {\n    let answer = compute(1, 2);\n}\n";
        server.set_text(7, "rust", source.to_string(), 1).unwrap();

        // Every (line, column) of the source, so the leading-indentation case —
        // where the resolved node is the whole enclosing block and its own
        // range would be far too wide an anchor — is covered by construction.
        let lines: Vec<&str> = source.lines().collect();
        let mut anchors_narrower_than_their_node = 0;
        for (row, line) in lines.iter().enumerate() {
            let lnum = row as u32 + 1;
            for col in 1..=(line.len() as u32 + 1) {
                let answer = scope_chain_cached(&server, 7, "rust", lnum, col).unwrap();
                let shape: Vec<&str> = answer.chain.iter().map(|node| node.node).collect();
                let [alnum, acol, aelnum, aecol] = answer.anchor;
                if answer.chain.first().is_some_and(|node| {
                    (node.lnum, node.col) < (alnum, acol)
                        || (node.end_lnum, node.end_col) > (aelnum, aecol)
                }) {
                    anchors_narrower_than_their_node += 1;
                }
                // An anchor may end on the phantom line after the final newline.
                for probe_lnum in alnum..=aelnum.min(lines.len() as u32) {
                    let width = lines[probe_lnum as usize - 1].len() as u32;
                    let first = if probe_lnum == alnum { acol } else { 1 };
                    let last = if probe_lnum == aelnum {
                        aecol - 1
                    } else {
                        width
                    };
                    for probe in first..=last.min(width) {
                        let probed = scope_chain_cached(&server, 7, "rust", probe_lnum, probe)
                            .unwrap()
                            .chain;
                        assert_eq!(
                            probed.iter().map(|node| node.node).collect::<Vec<_>>(),
                            shape,
                            "{probe_lnum}:{probe} is inside the anchor \
                             [{alnum}:{acol}-{aelnum}:{aecol}] reported for {lnum}:{col} \
                             but produces a different chain"
                        );
                    }
                }
            }
        }
        // The indentation columns are exactly the case a node-range anchor gets
        // wrong, so the test is worthless if it never reached one.
        assert!(
            anchors_narrower_than_their_node > 0,
            "no column resolved to a node wider than its anchor, so this test \
             never exercised the case a node-range anchor would break on"
        );
    }

    /// Every bundled language must at least classify a comment, so that `ac`
    /// on an unlisted grammar degrades to "no match here" and never to a match
    /// on the wrong node.
    #[test]
    fn scope_tables_only_name_kinds_and_comments_are_universal() {
        for lang in SUPPORTED_LANGUAGES {
            for (node_kind, class) in scope_table(lang) {
                assert!(
                    matches!(
                        *class,
                        "function"
                            | "class"
                            | "parameter"
                            | "block"
                            | "call"
                            | "comment"
                            | "conditional"
                            | "loop"
                    ),
                    "{lang}: {node_kind} maps to unknown text-object class {class}"
                );
            }
        }

        let mut server = Server::new();
        server
            .set_text(6, "rust", "// a note\nfn f() {}\n".to_string(), 1)
            .unwrap();
        let chain = scope_chain_cached(&server, 6, "rust", 1, 4).unwrap().chain;
        assert_eq!(
            chain.first().map(|node| node.kind),
            Some(Some("comment")),
            "a comment is not a comment text object: {chain:?}"
        );
    }

    #[test]
    fn c_function_range_covers_its_body() {
        let mut server = Server::new();
        let source = "int answer(void) {\n  return 42;\n}\n";
        server.set_text(1, "c", source.to_string(), 1).unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 1, "c", None, None).unwrap();
        let function = symbols
            .iter()
            .find(|symbol| symbol.name == "answer")
            .unwrap();
        assert_eq!(function.kind, "function");
        assert_eq!(function.end_lnum, 3);
    }

    #[test]
    fn visible_range_includes_multiline_tokens_starting_above_it() {
        let mut server = Server::new();
        let source = "text = '''first\nsecond\nthird'''\nprint(text)\n";
        server.set_text(1, "python", source.to_string(), 1).unwrap();
        let (_, spans) =
            run_highlight_cached(&mut server, 1, "python", Some((2, 2)), false, None).unwrap();
        assert!(
            spans
                .iter()
                .any(|span| span.group == "TSString" && span.lnum == 1 && span.end_lnum == 3),
            "multiline spans: {spans:?}"
        );
    }

    #[test]
    fn vim9_declarations_are_available_when_grammar_uses_generic_commands() {
        let mut server = Server::new();
        let source = "vim9script\nexport def Greet(name: string)\n  var message = name\n  return message\nenddef\nconst VERSION = 2\n";
        server.set_text(1, "vim", source.to_string(), 1).unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 1, "vim", None, None).unwrap();
        let function = symbols
            .iter()
            .find(|symbol| symbol.name == "Greet")
            .unwrap();
        assert_eq!(function.kind, "function");
        assert_eq!(function.end_lnum, 5);
        let local = symbols
            .iter()
            .find(|symbol| symbol.name == "message")
            .unwrap();
        assert_eq!(local.container_name.as_deref(), Some("Greet"));
        let version = symbols
            .iter()
            .find(|symbol| symbol.name == "VERSION")
            .unwrap();
        assert_eq!(version.kind, "const");
        assert!(version.container_kind.is_none());
    }

    #[test]
    fn javascript_lexical_declarations_are_symbols() {
        let mut server = Server::new();
        let source = "const first = 1; let second = 2; var third = 3;\n";
        server
            .set_text(1, "javascript", source.to_string(), 1)
            .unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 1, "javascript", None, None).unwrap();
        for expected in ["first", "second", "third"] {
            assert!(
                symbols.iter().any(|symbol| symbol.name == expected),
                "missing {expected}: {symbols:?}"
            );
        }
    }

    #[test]
    fn go_methods_and_fields_share_the_real_type_container() {
        let mut server = Server::new();
        let source = "package main\ntype User struct { Name string }\nfunc (u User) Greet() {}\n";
        server.set_text(1, "go", source.to_string(), 1).unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 1, "go", None, None).unwrap();
        let user = symbols.iter().find(|symbol| symbol.name == "User").unwrap();
        for name in ["Name", "Greet"] {
            let child = symbols.iter().find(|symbol| symbol.name == name).unwrap();
            assert_eq!(child.container_name.as_deref(), Some("User"));
            assert_eq!(child.container_lnum, Some(user.lnum));
            assert_eq!(child.container_col, Some(user.col));
        }
    }

    #[test]
    fn every_supported_language_has_semantic_smoke_coverage() {
        let cases = [
            ("rust", "fn rust_fn() {}\n", "rust_fn"),
            (
                "javascript",
                "function javascriptFn() { return 1; }\n",
                "javascriptFn",
            ),
            (
                "typescript",
                "interface Shape { area(): number }\nfunction tsFn(x: number): number { return x; }\n",
                "tsFn",
            ),
            (
                "tsx",
                "function TsxComponent() { return <div className=\"x\">hi</div>; }\n",
                "TsxComponent",
            ),
            ("c", "int c_fn(void) { return 0; }\n", "c_fn"),
            ("cpp", "class Widget { public: int value; };\n", "Widget"),
            ("python", "def python_fn():\n    return 1\n", "python_fn"),
            ("go", "package main\nfunc goFn() {}\n", "goFn"),
            ("bash", "bash_fn() { echo ok; }\n", "bash_fn"),
            ("vim", "vim9script\ndef VimFn()\nenddef\n", "VimFn"),
            ("json", "{\"top_key\": {\"nested\": 1}}\n", "top_key"),
            ("yaml", "top_key:\n  nested: 1\n", "top_key"),
            ("toml", "[section]\nkey = \"value\"\n", "section"),
            (
                "julia",
                "module Demo\nstruct Point\n  x::Float64\nend\nfunction area(p::Point)\n  p.x\nend\nend\n",
                "area",
            ),
            ("haskell", "module Demo where\narea x = x * x\n", "area"),
        ];
        let mut server = Server::new();
        for (index, (lang, source, expected_symbol)) in cases.into_iter().enumerate() {
            let buffer = index as i64 + 1;
            server
                .set_text(buffer, lang, source.to_string(), 1)
                .unwrap();
            let (_, highlights) =
                run_highlight_cached(&mut server, buffer, lang, None, false, None).unwrap();
            assert!(!highlights.is_empty(), "no {lang} highlights");
            let (_, symbols) = run_symbols_cached(&mut server, buffer, lang, None, None).unwrap();
            assert!(
                symbols.iter().any(|symbol| symbol.name == expected_symbol),
                "missing {lang} symbol {expected_symbol}: {symbols:?}"
            );
        }
    }

    fn splice(
        lstart: u32,
        old_lend: u32,
        lines: &[&str],
        line_count: u64,
        eol: bool,
    ) -> LineSplice {
        LineSplice {
            lstart,
            old_lend,
            lines: lines.iter().map(|line| line.to_string()).collect(),
            line_count,
            eol,
        }
    }

    #[test]
    fn edit_lines_replaces_inserts_and_deletes() {
        let mut server = Server::new();
        server
            .set_text(
                1,
                "rust",
                "fn one() {}\nfn two() {}\nfn three() {}\n".to_string(),
                1,
            )
            .unwrap();

        // 替换中间一行
        let mode = server
            .edit_lines(1, "rust", 2, splice(2, 3, &["fn changed() {}"], 3, true))
            .unwrap();
        assert_eq!(mode, ParseMode::Incremental);
        assert_eq!(
            server.cache.get(&1).unwrap().text,
            "fn one() {}\nfn changed() {}\nfn three() {}\n"
        );

        // 在开头插入一行
        server
            .edit_lines(1, "rust", 3, splice(1, 1, &["fn zero() {}"], 4, true))
            .unwrap();
        assert_eq!(
            server.cache.get(&1).unwrap().text,
            "fn zero() {}\nfn one() {}\nfn changed() {}\nfn three() {}\n"
        );

        // 删除最后两行
        server
            .edit_lines(1, "rust", 4, splice(3, 5, &[], 2, true))
            .unwrap();
        assert_eq!(
            server.cache.get(&1).unwrap().text,
            "fn zero() {}\nfn one() {}\n"
        );

        // 语法树与全量解析一致，revision 精确更新
        let (revision, symbols) = run_symbols_cached(&mut server, 1, "rust", None, None).unwrap();
        assert_eq!(revision, 4);
        let names: Vec<&str> = symbols.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["zero", "one"]);
    }

    #[test]
    fn edit_lines_respects_missing_trailing_newline() {
        let mut server = Server::new();
        server
            .set_text(1, "rust", "fn a() {}\nfn b() {}".to_string(), 1)
            .unwrap();
        server
            .edit_lines(1, "rust", 2, splice(2, 3, &[], 1, false))
            .unwrap();
        assert_eq!(server.cache.get(&1).unwrap().text, "fn a() {}");
        server
            .edit_lines(1, "rust", 3, splice(2, 2, &["fn c() {}"], 2, true))
            .unwrap();
        assert_eq!(server.cache.get(&1).unwrap().text, "fn a() {}\nfn c() {}\n");
    }

    #[test]
    fn edit_lines_mismatch_drops_the_cache() {
        let mut server = Server::new();
        server
            .set_text(1, "rust", "fn a() {}\n".to_string(), 1)
            .unwrap();
        let error = server
            .edit_lines(1, "rust", 2, splice(1, 2, &["fn b() {}"], 99, true))
            .unwrap_err();
        assert!(error.to_string().contains("edit_lines mismatch"));
        assert!(!server.cache.contains_key(&1));

        // 未缓存 buffer 的 edit_lines 必须请求全量重同步
        let error = server
            .edit_lines(2, "rust", 1, splice(1, 1, &["fn x() {}"], 1, true))
            .unwrap_err();
        assert!(error.to_string().contains("buffer not cached"));
    }

    #[test]
    fn folds_are_nested_and_merge_identical_ranges() {
        let mut server = Server::new();
        let source = "fn outer() {\n    match 1 {\n        _ => {}\n    }\n}\nfn flat() {}\n";
        server.set_text(1, "rust", source.to_string(), 7).unwrap();
        let (revision, folds) = run_folds_cached(&server, 1, "rust", None).unwrap();
        assert_eq!(revision, 7);
        // function_item 与其同界 block 合并为一个 level-1 折叠；match 嵌套其中。
        let outer = folds.iter().find(|fold| fold.lnum == 1).unwrap();
        assert_eq!((outer.end_lnum, outer.level), (5, 1));
        let inner = folds.iter().find(|fold| fold.lnum == 2).unwrap();
        assert_eq!((inner.end_lnum, inner.level), (4, 2));
        // 单行函数不产生折叠
        assert!(!folds.iter().any(|fold| fold.lnum == 6));
        assert_eq!(folds.len(), 2);
    }

    #[test]
    fn payload_digests_track_content_and_not_revision() {
        let mut server = Server::new();
        let source = "fn outer() {\n    let x = 1;\n}\n";
        server.set_text(1, "rust", source.to_string(), 1).unwrap();
        let (_, symbols) =
            run_symbols_cached_filtered(&mut server, 1, "rust", None, None, &[]).expect("symbols");
        let (_, folds) = run_folds_cached(&server, 1, "rust", None).expect("folds");
        let sym_digest = digest_symbols(&symbols);
        let fold_digest = digest_folds(&folds);

        // Editing inside a body is the common keystroke: same symbols, same
        // folds, new revision. The digest must not move, or the suppression
        // never fires where it matters most.
        server
            .set_text(
                1,
                "rust",
                "fn outer() {\n    let x = 12;\n}\n".to_string(),
                2,
            )
            .unwrap();
        let (revision, symbols) =
            run_symbols_cached_filtered(&mut server, 1, "rust", None, None, &[]).expect("symbols");
        assert_eq!(revision, 2);
        assert_eq!(digest_symbols(&symbols), sym_digest);
        let (_, folds) = run_folds_cached(&server, 1, "rust", None).expect("folds");
        assert_eq!(digest_folds(&folds), fold_digest);

        // A rename of the same length moves no position and changes no count:
        // only the length-prefixed name bytes distinguish it.
        server
            .set_text(
                1,
                "rust",
                "fn outre() {\n    let x = 12;\n}\n".to_string(),
                3,
            )
            .unwrap();
        let (_, symbols) =
            run_symbols_cached_filtered(&mut server, 1, "rust", None, None, &[]).expect("symbols");
        assert_ne!(digest_symbols(&symbols), sym_digest);

        // Growing the body moves the fold's end line.
        server
            .set_text(
                1,
                "rust",
                "fn outre() {\n    let x = 12;\n    let y = 2;\n}\n".to_string(),
                4,
            )
            .unwrap();
        let (_, folds) = run_folds_cached(&server, 1, "rust", None).expect("folds");
        assert_ne!(digest_folds(&folds), fold_digest);
    }

    #[test]
    fn a_matching_have_digest_suppresses_the_payload() {
        // The reply's own fields, exactly as the dispatcher assembles them.
        let mut server = Server::new();
        server
            .set_text(1, "rust", "fn a() {\n    let x = 1;\n}\n".to_string(), 1)
            .unwrap();
        let (revision, symbols) =
            run_symbols_cached_filtered(&mut server, 1, "rust", None, None, &[]).expect("symbols");
        assert!(!symbols.is_empty());
        let digest = digest_symbols(&symbols);

        let fresh = serde_json::to_value(Event::Symbols {
            buf: 1,
            revision,
            request_id: 1,
            symbols: Some(symbols.clone()),
            digest: digest.clone(),
            unchanged: false,
        })
        .unwrap();
        assert!(fresh["symbols"].is_array());
        assert_eq!(fresh["digest"], serde_json::Value::String(digest.clone()));
        // `unchanged` is skipped when false so a v6 client sees the v6 shape.
        assert!(fresh.get("unchanged").is_none());

        let suppressed = serde_json::to_value(Event::Symbols {
            buf: 1,
            revision,
            request_id: 2,
            symbols: None,
            digest: digest.clone(),
            unchanged: true,
        })
        .unwrap();
        assert!(suppressed.get("symbols").is_none());
        assert_eq!(suppressed["unchanged"], true);

        // A client that sends no digest is never suppressed, whatever the
        // payload — that is what makes the optimisation opt-in.
        let request: Request = serde_json::from_str(r#"{"type":"symbols","buf":1,"lang":"rust"}"#)
            .expect("legacy symbols request");
        match request {
            Request::Symbols { have_digest, .. } => assert_eq!(have_digest, ""),
            _ => panic!("wrong request variant"),
        }
        let request: Request =
            serde_json::from_str(r#"{"type":"folds","buf":1,"lang":"rust","have_digest":"42"}"#)
                .expect("folds request");
        match request {
            Request::Folds { have_digest, .. } => assert_eq!(have_digest, "42"),
            _ => panic!("wrong request variant"),
        }
    }

    #[test]
    fn the_compact_span_encoding_reproduces_the_object_form() {
        let mut server = Server::new();
        let source = "fn main() {\n    let v = vec![(1, 2)];\n}\n";
        server.set_text(1, "rust", source.to_string(), 1).unwrap();
        let (_, spans) = run_highlight_cached(&mut server, 1, "rust", None, true, None).unwrap();
        assert!(spans.len() > 5);
        let (groups, rows) = compact_spans(&spans);
        assert_eq!(rows.len(), spans.len());
        // The dictionary is deduplicated: `fn`/`let` share one group entry.
        assert!(groups.len() < spans.len());
        for (span, row) in spans.iter().zip(rows.iter()) {
            assert_eq!(
                [span.lnum, span.col, span.end_lnum, span.end_col],
                [row[0], row[1], row[2], row[3]]
            );
            assert_eq!(groups[row[4] as usize], span.group);
            assert_eq!(span.depth.unwrap_or(0), row[5]);
        }
        // Rainbow depth survives: the brackets in this source are nested.
        assert!(rows.iter().any(|row| row[5] > 1));

        // Only the asked-for encoding goes on the wire; a v6 client that never
        // sends `compact` must keep seeing `spans`.
        let compact = serde_json::to_value(Event::Highlights {
            buf: 1,
            revision: 1,
            spans: None,
            groups: Some(groups),
            cspans: Some(rows),
        })
        .unwrap();
        assert!(compact.get("spans").is_none());
        assert_eq!(compact["cspans"][0].as_array().unwrap().len(), 6);
        let legacy = serde_json::to_value(Event::Highlights {
            buf: 1,
            revision: 1,
            spans: Some(spans),
            groups: None,
            cspans: None,
        })
        .unwrap();
        assert!(legacy.get("cspans").is_none());
        assert!(legacy["spans"].is_array());
    }

    #[test]
    fn folds_cover_config_languages() {
        let mut server = Server::new();
        server
            .set_text(
                1,
                "json",
                "{\n  \"a\": {\n    \"b\": 1\n  }\n}\n".to_string(),
                1,
            )
            .unwrap();
        let (_, folds) = run_folds_cached(&server, 1, "json", None).unwrap();
        assert!(folds.iter().any(|fold| fold.level == 1));
        assert!(folds.iter().any(|fold| fold.level == 2));

        server
            .set_text(2, "yaml", "top:\n  a: 1\n  b: 2\n".to_string(), 1)
            .unwrap();
        let (_, folds) = run_folds_cached(&server, 2, "yaml", None).unwrap();
        assert!(!folds.is_empty());
    }

    #[test]
    fn typescript_symbols_have_containers_and_ranges() {
        let mut server = Server::new();
        let source = "export const VALUE = 1;\ninterface Shape {\n  area(): number;\n}\nclass Circle {\n  radius: number = 1;\n  area(): number { return this.radius; }\n}\nenum Color { Red, Green }\nnamespace Util {}\n";
        server
            .set_text(1, "typescript", source.to_string(), 1)
            .unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 1, "typescript", None, None).unwrap();

        let value = symbols.iter().find(|s| s.name == "VALUE").unwrap();
        assert_eq!(value.kind, "variable");
        let shape = symbols.iter().find(|s| s.name == "Shape").unwrap();
        assert_eq!(shape.kind, "type");
        assert_eq!(shape.end_lnum, 4);
        let circle_area = symbols
            .iter()
            .find(|s| s.name == "area" && s.container_name.as_deref() == Some("Circle"))
            .unwrap();
        assert_eq!(circle_area.kind, "method");
        assert_eq!(circle_area.container_kind, Some("class"));
        let radius = symbols.iter().find(|s| s.name == "radius").unwrap();
        assert_eq!(radius.container_name.as_deref(), Some("Circle"));
        let red = symbols.iter().find(|s| s.name == "Red").unwrap();
        assert_eq!(red.kind, "variant");
        assert_eq!(red.container_name.as_deref(), Some("Color"));
        assert!(
            symbols
                .iter()
                .any(|s| s.name == "Util" && s.kind == "namespace")
        );
    }

    #[test]
    fn config_symbols_nest_under_their_parents() {
        let mut server = Server::new();
        server
            .set_text(
                1,
                "yaml",
                "server:\n  host: localhost\n  port: 8080\nlogging:\n  level: info\n".to_string(),
                1,
            )
            .unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 1, "yaml", None, None).unwrap();
        let host = symbols.iter().find(|s| s.name == "host").unwrap();
        assert_eq!(host.container_name.as_deref(), Some("server"));
        assert_eq!(host.container_kind, Some("property"));

        server
            .set_text(
                2,
                "toml",
                "top = 1\n[dependencies]\nserde = \"1\"\n[dev.extra]\nother = 2\n".to_string(),
                1,
            )
            .unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 2, "toml", None, None).unwrap();
        let serde = symbols.iter().find(|s| s.name == "serde").unwrap();
        assert_eq!(serde.container_name.as_deref(), Some("dependencies"));
        assert_eq!(serde.container_kind, Some("namespace"));
        let top = symbols.iter().find(|s| s.name == "top").unwrap();
        assert!(top.container_kind.is_none());

        server
            .set_text(3, "json", "{\"outer\": {\"inner\": true}}\n".to_string(), 1)
            .unwrap();
        let (_, symbols) = run_symbols_cached(&mut server, 3, "json", None, None).unwrap();
        let inner = symbols.iter().find(|s| s.name == "inner").unwrap();
        assert_eq!(inner.container_name.as_deref(), Some("outer"));
    }

    #[test]
    fn buffer_cache_has_a_hard_entry_limit() {
        let mut server = Server::new();
        for buffer in 0..(MAX_CACHED_BUFFERS as i64 + 3) {
            server
                .set_text(buffer, "rust", format!("fn item_{buffer}() {{}}"), 1)
                .unwrap();
        }
        assert_eq!(server.cache.len(), MAX_CACHED_BUFFERS);
        assert_eq!(server.cache_evictions, 3);
    }

    #[test]
    fn lua_highlights_and_symbols() {
        let mut server = Server::new();
        let source = "local M = {}\n\
                      -- doc comment\n\
                      function M.greet(name)\n  print('hi ' .. name)\nend\n\
                      function M:method_one()\nend\n\
                      local top_level = 42\n\
                      return M\n";
        server
            .set_text(1, "lua", source.to_string(), 1)
            .expect("lua parse");
        let (_, spans) = run_highlight_cached(&mut server, 1, "lua", None, false, None).unwrap();
        let groups: Vec<&str> = spans.iter().map(|s| s.group).collect();
        for expected in [
            "TSComment",
            "TSString",
            "TSKeyword",
            "TSFunctionBuiltin",
            "TSNumber",
        ] {
            assert!(
                groups.contains(&expected),
                "missing {expected} in {groups:?}"
            );
        }
        let (_, symbols) = run_symbols_cached(&mut server, 1, "lua", None, None).unwrap();
        let names: Vec<(&str, &str)> = symbols.iter().map(|s| (s.kind, s.name.as_str())).collect();
        assert!(names.contains(&("function", "M.greet")), "{names:?}");
        assert!(names.contains(&("method", "M:method_one")), "{names:?}");
        assert!(names.contains(&("variable", "top_level")), "{names:?}");
    }

    #[test]
    fn html_highlights_and_symbols() {
        let mut server = Server::new();
        let source = "<!DOCTYPE html>\n<!-- comment -->\n<html>\n<body class=\"main\">\n\
                      <h1>Title</h1>\n<script>var x = 1;</script>\n</body>\n</html>\n";
        server
            .set_text(2, "html", source.to_string(), 1)
            .expect("html parse");
        let (_, spans) = run_highlight_cached(&mut server, 2, "html", None, false, None).unwrap();
        let groups: Vec<&str> = spans.iter().map(|s| s.group).collect();
        for expected in ["TSComment", "TSType", "TSProperty", "TSString"] {
            assert!(
                groups.contains(&expected),
                "missing {expected} in {groups:?}"
            );
        }
        let (_, symbols) = run_symbols_cached(&mut server, 2, "html", None, None).unwrap();
        assert!(
            symbols.iter().any(|s| s.kind == "class" && s.name == "h1"),
            "{symbols:?}"
        );
    }

    #[test]
    fn css_highlights_and_symbols() {
        let mut server = Server::new();
        let source = "/* comment */\n.card, #hero {\n  color: #fff;\n  margin: 2px;\n}\n\
                      @media (min-width: 600px) {\n  .card { padding: 1em; }\n}\n\
                      @keyframes spin {\n  from { opacity: 0; }\n  to { opacity: 1; }\n}\n";
        server
            .set_text(3, "css", source.to_string(), 1)
            .expect("css parse");
        let (_, spans) = run_highlight_cached(&mut server, 3, "css", None, false, None).unwrap();
        let groups: Vec<&str> = spans.iter().map(|s| s.group).collect();
        for expected in [
            "TSComment",
            "TSProperty",
            "TSField",
            "TSNumber",
            "TSKeyword",
        ] {
            assert!(
                groups.contains(&expected),
                "missing {expected} in {groups:?}"
            );
        }
        let (_, symbols) = run_symbols_cached(&mut server, 3, "css", None, None).unwrap();
        let names: Vec<(&str, &str)> = symbols.iter().map(|s| (s.kind, s.name.as_str())).collect();
        assert!(names.contains(&("class", ".card, #hero")), "{names:?}");
        assert!(names.contains(&("function", "spin")), "{names:?}");
    }
}
