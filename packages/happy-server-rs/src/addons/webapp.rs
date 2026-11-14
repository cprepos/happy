//! The bundled web app (`main.ts` `staticWebappOptions`, the static part of
//! `api.ts`) and the server check (`isServerCheckRequest.ts`,
//! `replyToServerCheck.ts`).
//!
//! With `HAPPY_STATIC_DIR` holding an `index.html`, `/` serves the app to
//! browsers and the banner to the apps checking the server, files in the
//! directory are served, and any other GET that is not an API path gets the
//! app's `index.html` (SPA fallback). `HAPPY_INJECT_HTML_CONFIG`, a JSON value,
//! is exposed to the app as `window.__HAPPY_CONFIG__`.

use crate::app::App;
use crate::config::Config;
use crate::h;
use crate::http::{Body, HResult, Reply, Req, Router};
use hyper::Method;
use regex::Regex;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, LazyLock};

pub const SERVER_BANNER: &str = "Welcome to Happy Server!";

pub struct Webapp {
    pub dir: PathBuf,
    /// The `<script>` that sets `window.__HAPPY_CONFIG__`, if configured.
    pub inject_script: Option<String>,
}

static WEBAPP: LazyLock<Option<Webapp>> = LazyLock::new(|| from_env(crate::addons::voice::env));

/// `staticWebappOptions`: `None` (with a warning) when the directory has no
/// `index.html`; an invalid `HAPPY_INJECT_HTML_CONFIG` is ignored with a warning.
pub fn from_env(var: impl Fn(&str) -> Option<String>) -> Option<Webapp> {
    let dir = var("HAPPY_STATIC_DIR")?;
    if !Path::new(&dir).join("index.html").exists() {
        tracing::warn!(module = "static", "HAPPY_STATIC_DIR={} has no index.html; not serving a web app", dir);
        return None;
    }
    let inject_script = var("HAPPY_INJECT_HTML_CONFIG").and_then(|raw| match crate::js::parse(&raw) {
        Ok(v) => Some(format!("<script>window.__HAPPY_CONFIG__ = {};</script>", crate::js::stringify(&v))),
        Err(_) => {
            tracing::warn!(module = "static", "HAPPY_INJECT_HTML_CONFIG is not valid JSON; ignoring it");
            None
        }
    });
    tracing::info!("Serving web app from {}", dir);
    Some(Webapp { dir: PathBuf::from(dir), inject_script })
}

pub fn webapp() -> Option<&'static Webapp> {
    WEBAPP.as_ref()
}

/// Without a web app upstream's `GET /` banner stays. With one, `/` and every
/// unmatched path are answered here.
pub fn register(r: &mut Router, _c: &Config) {
    if webapp().is_none() {
        return;
    }
    crate::addons::remove_route(r, &Method::GET, "/");
    r.get("/").handle(h!(root));
    r.get("/*").handle(h!(get_any));
    for m in [Method::POST, Method::PUT, Method::PATCH, Method::DELETE] {
        r.add(m, "/*").handle(h!(not_found));
    }
}

/// An app validating a server rather than a browser opening the web app: a GET
/// of exactly `/` (query ignored) whose Accept does not ask for `text/html`,
/// compared case-insensitively. A missing Accept counts as a check.
pub fn is_server_check(method: &str, url: &str, accept: Option<&str>) -> bool {
    if method != "GET" {
        return false;
    }
    if url.split('?').next() != Some("/") {
        return false;
    }
    !accept.is_some_and(|a| a.to_lowercase().contains("text/html"))
}

static HEAD_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)<head[^>]*>").unwrap());

/// Puts `script` on a new line after the first `<head ...>` tag.
pub fn inject(html: &str, script: &str) -> String {
    HEAD_TAG.replacen(html, 1, |c: &regex::Captures| format!("{}\n{}", &c[0], script)).into_owned()
}

/// The URLs whose HTML gets the config: the index, by any of its names.
fn is_index_url(url: &str) -> bool {
    url == "/" || url == "/index.html" || url.starts_with("/?")
}

/// Paths the SPA fallback leaves as 404s.
fn is_api_path(url: &str) -> bool {
    ["/v1", "/v3", "/socket", "/files/", "/metrics", "/health"].iter().any(|p| url.starts_with(p))
}

async fn root(_app: Arc<App>, req: Req) -> HResult {
    if is_server_check(req.method.as_str(), &req.url, req.header("accept")) {
        return Ok(Reply::text(200, SERVER_BANNER)?.with_header("content-type", "text/plain"));
    }
    let Some(w) = webapp() else { return not_found_reply() };
    serve_file(w, &w.dir.join("index.html"), &req).await
}

async fn get_any(_app: Arc<App>, req: Req) -> HResult {
    let Some(w) = webapp() else { return not_found_reply() };
    if let Some(file) = static_file(&w.dir, &req.param("*"), &req.url).await {
        return serve_file(w, &file, &req).await;
    }
    // SPA fallback.
    if req.method != Method::GET || is_api_path(&req.url) {
        return not_found_reply();
    }
    let Ok(html) = tokio::fs::read(w.dir.join("index.html")).await else { return not_found_reply() };
    let html = String::from_utf8_lossy(&html);
    let body = match &w.inject_script {
        Some(s) => inject(&html, s),
        None => html.into_owned(),
    };
    Ok(Reply { status: 200, headers: vec![("content-type".into(), "text/html".into())], body: Body::Text(body) })
}

async fn not_found(_app: Arc<App>, _req: Req) -> HResult {
    not_found_reply()
}

fn not_found_reply() -> HResult {
    Reply::error(404, "Not found")
}

/// The file a request path names inside `dir`, as `@fastify/static` with
/// `wildcard: false` routes them: one route per file found, so no `..`, no dot
/// files, a directory only with a trailing slash (meaning its `index.html`),
/// and nothing when the URL escapes a reserved character (`%2f`), which the
/// router keeps encoded and no file route matches.
async fn static_file(dir: &Path, rel: &str, url: &str) -> Option<PathBuf> {
    if rel.contains('\0') {
        return None;
    }
    let raw = url.split(['?', '#']).next().unwrap_or("");
    let decoded = crate::http::decode_uri(raw)?;
    if decoded.trim_start_matches('/') != rel {
        return None;
    }
    let mut path = dir.to_path_buf();
    for c in Path::new(rel).components() {
        match c {
            Component::Normal(s) if !s.to_string_lossy().starts_with('.') => path.push(s),
            Component::CurDir => {}
            _ => return None,
        }
    }
    let meta = tokio::fs::metadata(&path).await.ok()?;
    if meta.is_dir() {
        if !(rel.is_empty() || rel.ends_with('/')) {
            return None;
        }
        path.push("index.html");
        tokio::fs::metadata(&path).await.ok().filter(|m| m.is_file())?;
    } else if !meta.is_file() || rel.ends_with('/') {
        return None;
    }
    Some(path)
}

/// `Date.parse` of an HTTP date, in milliseconds; `None` where it gives NaN.
fn parse_date(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc2822(s.trim()).ok().map(|d| d.timestamp_millis())
}

/// `parseTokenList`: the comma separated tokens of a header, spaces trimmed.
fn tokens(s: &str) -> impl Iterator<Item = &str> {
    s.split(',').map(|t| t.trim_matches(' ')).filter(|t| !t.is_empty())
}

/// `send`'s `isPreconditionFailure`: If-Match or If-Unmodified-Since fail.
fn precondition_failed(req: &Req, etag: &str, modified_ms: i64) -> bool {
    if let Some(m) = req.header("if-match").filter(|m| !m.is_empty()) {
        if m != "*" && !tokens(m).any(|t| t == etag || format!("W/{t}") == etag) {
            return true;
        }
    }
    if let Some(since) = req.header("if-unmodified-since").and_then(parse_date) {
        return modified_ms > since;
    }
    false
}

/// `send`'s `isNotModifiedFailure`: answer 304. `Cache-Control: no-cache`
/// always gets the file; If-None-Match, when present, decides alone.
fn not_modified(req: &Req, etag: &str, modified_ms: i64) -> bool {
    if req.header("cache-control").is_some_and(|c| c.contains("no-cache")) {
        return false;
    }
    if let Some(m) = req.header("if-none-match") {
        return m == "*" || tokens(m).any(|t| t == etag || (etag.len() > t.len() && format!("W/{t}") == etag));
    }
    match req.header("if-modified-since") {
        Some(since) => parse_date(since).is_some_and(|since| modified_ms <= since),
        None => false,
    }
}

/// `send`'s `isRangeFresh`: If-Range names this etag or a date not before the file's.
fn range_fresh(req: &Req, etag: &str, modified_ms: i64) -> bool {
    let Some(r) = req.header("if-range") else { return true };
    if r.contains('"') {
        return r.contains(etag);
    }
    parse_date(r).is_some_and(|t| modified_ms <= t)
}

/// `parseInt(s, 10)`: leading spaces, a sign, then digits; `None` for NaN.
fn parse_int(s: &str) -> Option<i64> {
    let s = s.trim_start();
    let (neg, rest) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    let n: i64 = digits.parse().ok()?;
    Some(if neg { -n } else { n })
}

/// `send`'s `parseBytesRange`: the satisfiable ranges, overlapping or
/// adjacent ones combined, in request order.
fn parse_ranges(size: i64, header: &str) -> Vec<(i64, i64)> {
    let values = &header[header.find('=').map_or(0, |i| i + 1)..];
    let mut ranges: Vec<(i64, i64, usize)> = vec![];
    for part in values.split(',') {
        let (a, b) = match part.find('-') {
            Some(i) => (&part[..i], &part[i + 1..]),
            None => (part, ""),
        };
        let (start, end) = match (parse_int(a), parse_int(b)) {
            (None, Some(e)) => (Some(size - e), Some(size - 1)),
            (None, None) => (None, None),
            (Some(s), None) => (Some(s), Some(size - 1)),
            (Some(s), Some(e)) => (Some(s), Some(e.min(size - 1))),
        };
        if let (Some(s), Some(e)) = (start, end) {
            if s > -1 && s <= e {
                let n = ranges.len();
                ranges.push((s, e, n));
            }
        }
    }
    if ranges.len() >= 2 {
        ranges.sort_by_key(|r| r.0);
        let mut merged: Vec<(i64, i64, usize)> = vec![ranges[0]];
        for r in &ranges[1..] {
            let cur = merged.last_mut().unwrap();
            if r.0 > cur.1 + 1 {
                merged.push(*r);
            } else if r.1 > cur.1 {
                cur.1 = r.1;
                cur.2 = cur.2.min(r.2);
            }
        }
        merged.sort_by_key(|r| r.2);
        ranges = merged;
    }
    ranges.into_iter().map(|(s, e, _)| (s, e)).collect()
}

/// `@fastify/send`'s answer for a file, with the config injected into the index.
async fn serve_file(w: &Webapp, path: &Path, req: &Req) -> HResult {
    let meta = tokio::fs::metadata(path).await?;
    let mtime_ms = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0);
    let etag = format!("W/\"{:x}-{:x}\"", meta.len(), mtime_ms);
    // Last-Modified has whole seconds; send compares against what it sent.
    let modified_ms = mtime_ms - mtime_ms.rem_euclid(1000);
    let last_modified = crate::util::ms_to_naive(mtime_ms).format("%a, %d %b %Y %H:%M:%S GMT").to_string();
    let ct = content_type(path);
    let mut headers = vec![
        ("accept-ranges".to_string(), "bytes".to_string()),
        ("cache-control".to_string(), "public, max-age=0".to_string()),
        ("last-modified".to_string(), last_modified),
        ("etag".to_string(), etag.clone()),
    ];
    let conditional = ["if-match", "if-unmodified-since", "if-none-match", "if-modified-since"].iter().any(|h| req.header(h).is_some_and(|v| !v.is_empty()));
    if conditional {
        if precondition_failed(req, &etag, modified_ms) {
            return Ok(crate::http::error_reply(412, "PreconditionFailedError", "Precondition Failed"));
        }
        if not_modified(req, &etag, modified_ms) {
            return Ok(Reply { status: 304, headers, body: Body::Empty });
        }
    }
    if !ct.is_empty() {
        headers.push(("content-type".to_string(), ct.to_string()));
    }
    let bytes = tokio::fs::read(path).await?;
    if let Some(range) = req.header("range").filter(|r| r.trim_start_matches(' ').starts_with("bytes=")) {
        if range_fresh(req, &etag, modified_ms) {
            let len = bytes.len() as i64;
            match parse_ranges(len, range).as_slice() {
                [] => {
                    return Ok(crate::http::error_reply(416, "RangeNotSatisfiableError", "Range Not Satisfiable"));
                }
                [(s, e)] => {
                    headers.push(("content-range".to_string(), format!("bytes {s}-{e}/{len}")));
                    let part = bytes[*s as usize..=*e as usize].to_vec();
                    return Ok(Reply { status: 206, headers, body: Body::Bytes(part, "") });
                }
                _ => {}
            }
        }
    }
    let body = match &w.inject_script {
        Some(s) if is_index_url(&req.url) && ct.contains("text/html") => Body::Text(inject(&String::from_utf8_lossy(&bytes), s)),
        _ => Body::Bytes(bytes, ""),
    };
    Ok(Reply { status: 200, headers, body })
}

/// The media type `send` gives a file, with the UTF-8 charset on text types.
pub fn content_type(path: &Path) -> &'static str {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "application/javascript; charset=utf-8",
        "cjs" => "application/node",
        "css" => "text/css; charset=utf-8",
        "json" | "map" => "application/json; charset=utf-8",
        "webmanifest" => "application/manifest+json; charset=utf-8",
        "txt" => "text/plain; charset=utf-8",
        "xml" => "application/xml; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/vnd.microsoft.icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "wasm" => "application/wasm",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        "wav" => "audio/wav",
        "md" => "text/markdown; charset=utf-8",
        "csv" => "text/csv; charset=utf-8",
        "pdf" => "application/pdf",
        "avif" => "image/avif",
        "eot" => "application/vnd.ms-fontobject",
        "webm" => "video/webm",
        // `mime` knows no type: send sets none.
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_check_is_a_get_of_root_not_asking_for_html() {
        assert!(is_server_check("GET", "/", None));
        assert!(is_server_check("GET", "/?x=1", Some("*/*")));
        assert!(is_server_check("GET", "/", Some("application/json")));
        assert!(!is_server_check("GET", "/", Some("text/html,application/xhtml+xml")));
        assert!(!is_server_check("GET", "/", Some("TEXT/HTML")));
        assert!(!is_server_check("HEAD", "/", None));
        assert!(!is_server_check("POST", "/", None));
        assert!(!is_server_check("GET", "/index.html", None));
        assert!(!is_server_check("GET", "/app", None));
    }

    #[test]
    fn injects_after_the_first_head_tag_only() {
        let s = "<script>x</script>";
        assert_eq!(inject("<html><HEAD lang=en><title/></head><head>", s), "<html><HEAD lang=en>\n<script>x</script><title/></head><head>");
        assert_eq!(inject("<html><body>", s), "<html><body>");
    }

    #[test]
    fn index_urls_and_api_paths() {
        assert!(is_index_url("/") && is_index_url("/index.html") && is_index_url("/?a=b"));
        assert!(!is_index_url("/index.html?x") && !is_index_url("/app"));
        assert!(is_api_path("/v1/x") && is_api_path("/v1") && is_api_path("/socket.io/") && is_api_path("/health"));
        assert!(!is_api_path("/files") && !is_api_path("/settings"));
    }

    #[tokio::test]
    async fn resolves_files_inside_the_directory_only() {
        // A fixed directory, rewritten on every run.
        let dir = std::env::temp_dir().join("happy-server-rs-addons-webapp-test");
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::write(dir.join("index.html"), "<head></head>").unwrap();
        std::fs::write(dir.join("a.js"), "1").unwrap();
        std::fs::write(dir.join(".env"), "x").unwrap();
        std::fs::write(dir.join("sub/index.html"), "s").unwrap();
        std::fs::create_dir_all(dir.join("bare")).unwrap();
        let f = |rel: &'static str, url: &'static str| static_file(&dir, rel, url);
        assert_eq!(f("a.js", "/a.js").await, Some(dir.join("a.js")));
        assert_eq!(f("sub/", "/sub/").await, Some(dir.join("sub/index.html")));
        assert_eq!(f("sub", "/sub").await, None);
        assert_eq!(f("a.js/", "/a.js/").await, None);
        assert_eq!(f("bare/", "/bare/").await, None);
        assert_eq!(f("", "/").await, Some(dir.join("index.html")));
        assert_eq!(f("sub/index.html", "/sub%2findex.html").await, None);
        assert_eq!(f("../etc/passwd", "/../etc/passwd").await, None);
        assert_eq!(f(".env", "/.env").await, None);
        assert_eq!(f("/etc/passwd", "//etc/passwd").await, None);
        assert_eq!(f("missing.js", "/missing.js").await, None);
        let w = from_env(|k| match k {
            "HAPPY_STATIC_DIR" => Some(dir.to_string_lossy().into_owned()),
            "HAPPY_INJECT_HTML_CONFIG" => Some(r#"{"b":1,"a":"x"}"#.into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(w.inject_script.as_deref(), Some(r#"<script>window.__HAPPY_CONFIG__ = {"b":1,"a":"x"};</script>"#));
        assert!(from_env(|k| (k == "HAPPY_STATIC_DIR").then(|| "/nonexistent-dir".to_string())).is_none());
        let bad = from_env(|k| match k {
            "HAPPY_STATIC_DIR" => Some(dir.to_string_lossy().into_owned()),
            "HAPPY_INJECT_HTML_CONFIG" => Some("{nope".into()),
            _ => None,
        })
        .unwrap();
        assert!(bad.inject_script.is_none());
    }

    #[test]
    fn byte_ranges_like_send() {
        assert_eq!(parse_ranges(10, "bytes=0-6"), vec![(0, 6)]);
        assert_eq!(parse_ranges(10, "bytes=-3"), vec![(7, 9)]);
        assert_eq!(parse_ranges(10, "bytes=4-"), vec![(4, 9)]);
        assert_eq!(parse_ranges(10, "bytes=4-100"), vec![(4, 9)]);
        assert_eq!(parse_ranges(10, "bytes=20-30"), vec![]);
        assert_eq!(parse_ranges(10, "bytes=x"), vec![]);
        assert_eq!(parse_ranges(10, "bytes=0-1,5-6"), vec![(0, 1), (5, 6)]);
        assert_eq!(parse_ranges(10, "bytes=5-6,0-1,2-3"), vec![(5, 6), (0, 3)]);
        assert_eq!(parse_ranges(10, "bytes=0-4,3-8"), vec![(0, 8)]);
    }

    #[test]
    fn mime_types_like_send() {
        assert_eq!(content_type(Path::new("a/app.js")), "application/javascript; charset=utf-8");
        assert_eq!(content_type(Path::new("x.WOFF2")), "font/woff2");
        assert_eq!(content_type(Path::new("LICENSE")), "");
    }
}
