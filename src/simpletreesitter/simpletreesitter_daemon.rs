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
    "c",
    "cpp",
    "python",
    "go",
    "bash",
    "vim",
];
const PROTOCOL_VERSION: u32 = 2;

const MAX_AST_NODES: usize = 50_000;
const MAX_AST_DEPTH: usize = 512;
const MAX_AST_INDENT: usize = 80;
const MAX_SOURCE_BYTES: usize = 32 * 1024 * 1024;
const MAX_CACHED_BUFFERS: usize = 128;
const MAX_CACHED_SOURCE_BYTES: usize = 256 * 1024 * 1024;
const MAX_HIGHLIGHT_SPANS: usize = 100_000;
const MAX_SYMBOLS: usize = 100_000;
const LINE_INDEX_STRIDE: usize = 256;

fn default_true() -> bool {
    true
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
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        lang: String,
        #[serde(default)]
        lstart: Option<u32>,
        #[serde(default)]
        lend: Option<u32>,
        #[serde(default)]
        max_items: Option<usize>,
    },
    #[serde(rename = "dump_ast")]
    DumpAst { buf: i64, lang: String },
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
        spans: Vec<Span>,
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        revision: u64,
        symbols: Vec<Symbol>,
    },
    #[serde(rename = "ast")]
    Ast {
        buf: i64,
        revision: u64,
        lines: Vec<String>,
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
    },
}

#[derive(Debug, Serialize, Clone)]
struct Span {
    lnum: u32,
    col: u32,
    end_lnum: u32,
    end_col: u32,
    group: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    depth: Option<u32>,
}

#[derive(Debug, Serialize, Clone)]
struct Symbol {
    name: String,
    kind: String,
    lnum: u32,
    col: u32,
    #[serde(default)]
    end_lnum: u32,
    #[serde(default)]
    end_col: u32,
    container_kind: Option<String>,
    container_name: Option<String>,
    container_lnum: Option<u32>,
    container_col: Option<u32>,
}

// 缓存：每个 buf 保存 lang/text/tree
struct BufCache {
    lang: String,
    text: String,
    tree: tree_sitter::Tree,
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

struct Server {
    // 缓存：buf -> BufCache
    cache: HashMap<i64, BufCache>,
    // 复用 parser（按语言）
    parsers: HashMap<String, tree_sitter::Parser>,
    // 预编译查询缓存（按语言）
    queries: HashMap<String, LangQueries>,
    full_parses: u64,
    incremental_parses: u64,
    unchanged_syncs: u64,
    cache_evictions: u64,
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
        self.reserve_cache_capacity(buf, text.len());
        let line_index = SparseLineIndex::new(&text);
        self.cache.insert(
            buf,
            BufCache {
                lang: lang.to_string(),
                text,
                tree,
                revision,
                line_index,
            },
        );
        Ok(mode)
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

fn main() -> Result<()> {
    let stdin = std::io::stdin();
    let lines = BufReader::new(stdin).lines();
    let mut out = std::io::stdout();
    let mut server = Server::new();

    for line in lines {
        let line = match line {
            Ok(s) => s,
            Err(_) => break,
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
                    },
                )?,
            },
            Request::Highlight {
                buf,
                lang,
                lstart,
                lend,
                rainbow,
                max_spans,
            } => {
                let lrange = lstart.zip(lend);
                match run_highlight_cached(&mut server, buf, &lang, lrange, rainbow, max_spans) {
                    Ok((revision, spans)) => send(
                        &mut out,
                        &Event::Highlights {
                            buf,
                            revision,
                            spans,
                        },
                    )?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                        },
                    )?,
                }
            }
            Request::Symbols {
                buf,
                lang,
                lstart,
                lend,
                max_items,
            } => {
                let lrange = lstart.zip(lend);
                match run_symbols_cached(&mut server, buf, &lang, lrange, max_items) {
                    Ok((revision, symbols)) => send(
                        &mut out,
                        &Event::Symbols {
                            buf,
                            revision,
                            symbols,
                        },
                    )?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                        },
                    )?,
                }
            }
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
            if newline_count % LINE_INDEX_STRIDE == 0 {
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
    let query = &server.queries.get(&cache.lang).unwrap().hl_query;
    let mut cursor = tree_sitter::QueryCursor::new();

    if let Some((ls, le)) = lrange {
        let b_range = expand_range_for_multiline_token(
            root,
            line_range_from_index(&cache.line_index, &cache.text, ls, le),
        );
        cursor.set_byte_range(b_range);
    }

    let mut spans = Vec::with_capacity(4096);
    let limit = max_spans
        .unwrap_or(MAX_HIGHLIGHT_SPANS)
        .min(MAX_HIGHLIGHT_SPANS);
    // Dedup by an explicit semantic priority. Capture iteration is ordered by
    // source position, but same-range pattern ordering is not an API contract.
    let mut seen = HashMap::<(u32, u32, u32, u32), (usize, u8)>::new();
    let mut it = cursor.captures(query, root, bytes);
    while let Some((m, cap_ix)) = it.next() {
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let sp = node.start_position();
        let ep = node.end_position();

        let lnum = sp.row as u32 + 1;
        let col = sp.column as u32 + 1;
        let end_lnum = ep.row as u32 + 1;
        let end_col = ep.column as u32 + 1;

        if let Some((ls, le)) = lrange {
            if end_lnum < ls || lnum > le {
                continue;
            }
        }

        let key = (lnum, col, end_lnum, end_col);
        let cname = query.capture_names()[cap.index as usize];
        let priority = capture_priority(cname);
        let group = map_capture_to_group(cname).to_string();
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
            break;
        }
        seen.insert(key, (spans.len(), priority));
        spans.push(span);
    }

    Ok((cache.revision, spans))
}

// 复用缓存 Tree + bytes 做符号
fn run_symbols_cached(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
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
        String,
        String,
        u32,
        u32,
        Option<String>,
        Option<String>,
        Option<u32>,
        Option<u32>,
    )>::new();
    let mut seen_at = HashMap::<(u32, u32), String>::new();

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
        let mut kind = map_symbol_capture(cname).to_string();
        if kind.is_empty() {
            continue;
        }

        if cache.lang == "rust" && kind == "function" && ancestor_kind(node, "impl_item").is_some()
        {
            kind = "method".to_string();
        }

        let name = node_text(node, bytes);
        let sp = node.start_position();
        let lnum = sp.row as u32 + 1;
        let col = sp.column as u32 + 1;
        // Query 捕获的一般只是名称节点；向上找到真正的定义，范围才会覆盖函数体。
        let def_end = definition_node(node, &cache.lang, &kind).end_position();
        let sym_end_lnum = def_end.row as u32 + 1;
        let sym_end_col = def_end.column as u32 + 1;

        if let Some((ls, le)) = lrange {
            if lnum < ls || lnum > le {
                continue;
            }
        }

        // 容器信息（可选）
        let mut ckind: Option<String> = None;
        let mut cname_opt: Option<String> = None;
        let mut clnum: Option<u32> = None;
        let mut ccol: Option<u32> = None;

        // Rust 容器推断
        if cache.lang == "rust" {
            match kind.as_str() {
                "field" => {
                    if let Some(vinfo) = variant_info(node, bytes) {
                        ckind = Some("variant".to_string());
                        cname_opt = Some(vinfo.0);
                        clnum = Some(vinfo.1);
                        ccol = Some(vinfo.2);
                    } else if let Some(sinfo) = struct_info(node, bytes) {
                        ckind = Some("struct".to_string());
                        cname_opt = Some(sinfo.0);
                        clnum = Some(sinfo.1);
                        ccol = Some(sinfo.2);
                    } else if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace".to_string());
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                "variant" => {
                    if let Some(einfo) = enum_info(node, bytes) {
                        ckind = Some("enum".to_string());
                        cname_opt = Some(einfo.0);
                        clnum = Some(einfo.1);
                        ccol = Some(einfo.2);
                    }
                }
                "method" => {
                    if let Some(tinfo) = impl_type_info(node, bytes) {
                        ckind = Some("type".to_string());
                        cname_opt = Some(tinfo.0);
                        clnum = Some(tinfo.1);
                        ccol = Some(tinfo.2);
                    }
                }
                "function" => {
                    if let Some(finfo) = outer_fn_info(node, bytes) {
                        ckind = Some("function".to_string());
                        cname_opt = Some(finfo.0);
                        clnum = Some(finfo.1);
                        ccol = Some(finfo.2);
                    } else if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace".to_string());
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                "const" => {
                    if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace".to_string());
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                _ => {}
            }
        }

        // JavaScript 容器推断：method → class
        if cache.lang == "javascript" && kind == "method" {
            if let Some(cls) = ancestor_kind(node, "class_declaration") {
                if let Some(cls_name) = child_text_by_kind(cls, "identifier", bytes) {
                    if let Some((ln, co)) = child_pos_by_kind(cls, "identifier") {
                        ckind = Some("class".to_string());
                        cname_opt = Some(cls_name);
                        clnum = Some(ln);
                        ccol = Some(co);
                    }
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
            ckind = Some("class".to_string());
            cname_opt = Some(cls_name);
            clnum = Some(ln);
            ccol = Some(co);
        }

        // Go 容器推断：method → receiver type, field → struct
        if cache.lang == "go" {
            if kind == "method" {
                // method_declaration 的 receiver 有 parameter_declaration → type_identifier
                if let Some(mdecl) = node.parent().and_then(|p| {
                    if p.kind() == "method_declaration" {
                        Some(p)
                    } else {
                        None
                    }
                }) {
                    let mut c = mdecl.walk();
                    for ch in mdecl.children(&mut c) {
                        if ch.kind() == "parameter_list" {
                            let mut c2 = ch.walk();
                            for pd in ch.children(&mut c2) {
                                if pd.kind() == "parameter_declaration" {
                                    if let Some(tname) =
                                        child_text_by_kind(pd, "type_identifier", bytes)
                                    {
                                        let sp = pd.start_position();
                                        ckind = Some("type".to_string());
                                        cname_opt = Some(tname);
                                        clnum = Some(sp.row as u32 + 1);
                                        ccol = Some(sp.column as u32 + 1);
                                    }
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
                ckind = Some("type".to_string());
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
                    ckind = Some("function".to_string());
                }
            }
        }

        // 同一位置的 function/method 去重规则
        if let Some(prev) = seen_at.get(&(lnum, col)) {
            if prev == "method" && kind == "function" {
                continue;
            }
            if prev == "function" && kind == "method" {
                if let Some(pos) = symbols.iter().position(|s: &Symbol| {
                    s.lnum == lnum && s.col == col && s.kind == "function" && s.name == name
                }) {
                    symbols.remove(pos);
                }
                seen_at.insert((lnum, col), "method".to_string());
            }
        } else {
            seen_at.insert((lnum, col), kind.clone());
        }

        let key = (
            kind.clone(),
            name.clone(),
            lnum,
            col,
            ckind.clone(),
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
        for symbol in extract_vim_declarations(&cache.text, lrange, limit - symbols.len()) {
            let key = (
                symbol.kind.clone(),
                symbol.name.clone(),
                symbol.lnum,
                symbol.col,
                symbol.container_kind.clone(),
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

                    if let Some((ls, le)) = lrange {
                        if lnum < ls || lnum > le {
                            // 压入子节点继续遍历
                            let mut child_cursor = n.walk();
                            for ch in n.children(&mut child_cursor) {
                                stack.push(ch);
                            }
                            continue;
                        }
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
                                (
                                    Some("mapping".to_string()),
                                    Some(format!("{} {}", cmd.trim(), lhs)),
                                )
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
                                Some(name) => {
                                    (Some("module".to_string()), Some(format!("Plug: {}", name)))
                                }
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
                                    Some("property".to_string()),
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
                                Some(g) if g != "END" => (
                                    Some("namespace".to_string()),
                                    Some(format!("augroup {}", g)),
                                ),
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
                                (
                                    Some("event".to_string()),
                                    Some(format!("autocmd {}", args.join(" "))),
                                )
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
                                Some(s) => (
                                    Some("property".to_string()),
                                    Some(format!("colorscheme {}", s)),
                                ),
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
                                Some(f) => (Some("function".to_string()), Some(f)),
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
                                    (
                                        Some("method".to_string()),
                                        Some(format!("command! {}", cmd_def_name)),
                                    )
                                }
                                None => (None, None),
                            }
                        }
                        // plug#begin / plug#end
                        s if s.contains('#') => {
                            (Some("namespace".to_string()), Some(cmd.trim().to_string()))
                        }
                        // filetype, syntax
                        "filetype" | "syntax" => {
                            let mut cursor = n.walk();
                            let args: Vec<String> = n
                                .children(&mut cursor)
                                .filter(|c| c.kind() == "safe_arg")
                                .map(|c| node_text(c, bytes).trim().to_string())
                                .collect();
                            (
                                Some("property".to_string()),
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
                                    Some("property".to_string()),
                                    Some(format!("{} {}", cmd.trim(), args.join(" "))),
                                )
                            }
                        }
                        _ => (None, None),
                    };
                    if let (Some(kind), Some(name)) = (sym_kind, sym_name) {
                        let key = (
                            kind.clone(),
                            name.clone(),
                            lnum,
                            col,
                            None,
                            None,
                            None,
                            None,
                        );
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
            if symbol.container_kind.as_deref() == Some("type")
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

fn extract_vim_declarations(text: &str, lrange: Option<(u32, u32)>, limit: usize) -> Vec<Symbol> {
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
                let index = if in_range && symbols.len() < limit {
                    let container = functions.last();
                    symbols.push(Symbol {
                        name: name.to_string(),
                        kind: "function".to_string(),
                        lnum: line_number,
                        col: column,
                        end_lnum: line_number,
                        end_col: source_line.len() as u32 + 1,
                        container_kind: container.map(|_| "function".to_string()),
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
            if symbols.len() >= limit
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
                kind: if matches!(keyword, "const" | "final") {
                    "const".to_string()
                } else {
                    "variable".to_string()
                },
                lnum: line_number,
                col: (declaration_offset + keyword.len() + spaces + 1) as u32,
                end_lnum: line_number,
                end_col: source_line.len() as u32 + 1,
                container_kind: container.map(|_| "function".to_string()),
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
        "string" => "TSString",
        "string.regex" => "TStringRegex",
        "string.escape" => "TStringEscape",
        "string.special" => "TStringSpecial",
        "number" => "TSNumber",
        "boolean" => "TSBoolean",
        "null" => "TSConstant",

        "keyword" => "TSKeyword",
        "keyword.operator" => "TSKeywordOperator",
        "operator" => "TSOperator",
        "punctuation.delimiter" => "TSPunctDelimiter",
        "punctuation.bracket" => "TSPunctBracket",

        "variable" => "TSVariable",
        "variable.parameter" => "TSVariableParameter",
        "variable.builtin" => "TSVariableBuiltin",
        "constant" => "TSConstant",
        "constant.builtin" => "TSConstBuiltin",

        "property" => "TSProperty",
        "field" => "TSField",

        "function" => "TSFunction",
        "method" => "TSMethod",
        "function.builtin" => "TSFunctionBuiltin",

        "type" => "TSType",
        "type.builtin" => "TSTypeBuiltin",
        "namespace" => "TSNamespace",
        "macro" => "TSMacro",
        "attribute" => "TSAttribute",

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
    if let Some(st) = ancestor_kind(node, "struct_item") {
        if let Some(name) = child_text_by_kind(st, "type_identifier", bytes) {
            if let Some((ln, co)) = child_pos_by_kind(st, "type_identifier") {
                return Some((name, ln, co));
            }
        }
    }
    None
}
fn enum_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(en) = ancestor_kind(node, "enum_item") {
        if let Some(name) = child_text_by_kind(en, "type_identifier", bytes) {
            if let Some((ln, co)) = child_pos_by_kind(en, "type_identifier") {
                return Some((name, ln, co));
            }
        }
    }
    None
}
fn variant_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "enum_variant" {
            if let Some(name) = child_text_by_kind(parent, "identifier", bytes) {
                if let Some((ln, co)) = child_pos_by_kind(parent, "identifier") {
                    return Some((name, ln, co));
                }
            }
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
    if let Some(md) = ancestor_kind(node, "mod_item") {
        if let Some(name) = child_text_by_kind(md, "identifier", bytes) {
            if let Some((ln, co)) = child_pos_by_kind(md, "identifier") {
                return Some((name, ln, co));
            }
        }
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
            if let Some(name) = child_text_by_kind(parent, "identifier", bytes) {
                if let Some((ln, co)) = child_pos_by_kind(parent, "identifier") {
                    return Some((name, ln, co));
                }
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
                    !map_capture_to_group(capture).is_empty(),
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
        assert_eq!(inner.container_kind.as_deref(), Some("function"));
        assert_eq!(inner.container_name.as_deref(), Some("outer"));
        assert!(symbols.iter().all(|symbol| symbol.end_lnum >= symbol.lnum));
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
            ("c", "int c_fn(void) { return 0; }\n", "c_fn"),
            ("cpp", "class Widget { public: int value; };\n", "Widget"),
            ("python", "def python_fn():\n    return 1\n", "python_fn"),
            ("go", "package main\nfunc goFn() {}\n", "goFn"),
            ("bash", "bash_fn() { echo ok; }\n", "bash_fn"),
            ("vim", "vim9script\ndef VimFn()\nenddef\n", "VimFn"),
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
}
