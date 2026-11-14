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

static WEBAPP: LazyLock<Option<Webapp>> = LazyLock::new(|| from_env(crate::plugins::voice::env));

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
    crate::plugins::remove_route(r, &Method::GET, "/");
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
    if let Some(file) = static_file(&w.dir, &req.param("*")).await {
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

/// The file a request path names inside `dir`: no `..`, no dot files, and a
/// directory means its `index.html`.
async fn static_file(dir: &Path, rel: &str) -> Option<PathBuf> {
    if rel.contains('\0') {
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
        path.push("index.html");
        tokio::fs::metadata(&path).await.ok().filter(|m| m.is_file())?;
    } else if !meta.is_file() {
        return None;
    }
    Some(path)
}

/// `@fastify/send`'s answer for a file, with the config injected into the index.
async fn serve_file(w: &Webapp, path: &Path, req: &Req) -> HResult {
    let meta = tokio::fs::metadata(path).await?;
    let mtime_ms = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0);
    let etag = format!("W/\"{:x}-{:x}\"", meta.len(), mtime_ms);
    let last_modified = crate::util::ms_to_naive(mtime_ms).format("%a, %d %b %Y %H:%M:%S GMT").to_string();
    let ct = content_type(path);
    let headers = vec![
        ("accept-ranges".to_string(), "bytes".to_string()),
        ("cache-control".to_string(), "public, max-age=0".to_string()),
        ("last-modified".to_string(), last_modified),
        ("etag".to_string(), etag.clone()),
        ("content-type".to_string(), ct.to_string()),
    ];
    if req.header("if-none-match").is_some_and(|v| v.split(',').any(|t| t.trim() == etag)) {
        return Ok(Reply { status: 304, headers, body: Body::Empty });
    }
    let bytes = tokio::fs::read(path).await?;
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
        "js" | "mjs" | "cjs" => "text/javascript; charset=utf-8",
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
        _ => "application/octet-stream",
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
        let dir = std::env::temp_dir().join("happy-server-rs-plugins-webapp-test");
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::write(dir.join("index.html"), "<head></head>").unwrap();
        std::fs::write(dir.join("a.js"), "1").unwrap();
        std::fs::write(dir.join(".env"), "x").unwrap();
        std::fs::write(dir.join("sub/index.html"), "s").unwrap();
        assert_eq!(static_file(&dir, "a.js").await, Some(dir.join("a.js")));
        assert_eq!(static_file(&dir, "sub").await, Some(dir.join("sub/index.html")));
        assert_eq!(static_file(&dir, "").await, Some(dir.join("index.html")));
        assert_eq!(static_file(&dir, "../etc/passwd").await, None);
        assert_eq!(static_file(&dir, ".env").await, None);
        assert_eq!(static_file(&dir, "/etc/passwd").await, None);
        assert_eq!(static_file(&dir, "missing.js").await, None);
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
}
