//! The iroh bridge of `sparkles:iroh-send`: `sendme send`, as a library with a
//! C interface that D loads at run time (fileset explorer `FXS7`, `X18`).
//!
//! It is built inside `sendme` 0.37's own source tree, against its
//! `Cargo.lock` (`nix/packages/sparkles-iroh-send.nix`), and it does what
//! `sendme send` does: it imports each file into an iroh-blobs store, makes
//! the collection of their names, serves it over iroh's blobs protocol and
//! hands out a `BlobTicket` for it. What differs is that the caller names
//! the files, so a fileset is sent rather than a directory, and that it runs
//! on threads of its own, reporting through `sparkles_iroh_send_status`.
//!
//! Every function is `extern "C"`; strings cross as a pointer and a length,
//! never NUL-terminated. A session is a `Session` behind an opaque pointer,
//! freed by `sparkles_iroh_send_stop`.

use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::Context;
use iroh::{endpoint::presets, Endpoint, RelayMode, SecretKey};
use iroh_blobs::{
    api::{
        blobs::{AddPathOptions, AddProgressItem, ImportMode},
        Store, TempTag,
    },
    format::collection::Collection,
    provider::events::{ConnectMode, EventMask, EventSender, ProviderMessage, RequestMode, RequestUpdate},
    store::{fs::FsStore, mem::MemStore},
    ticket::BlobTicket,
    BlobFormat, BlobsProtocol,
};
use n0_future::StreamExt;
use tokio::sync::{mpsc, oneshot};

/// The version of this interface; D refuses a library with another.
pub const ABI_VERSION: u32 = 2;

/// The flag that disables relays: a ticket then carries direct addresses only.
pub const FLAG_NO_RELAY: u32 = 1;

/// One file to send: its name in the collection and its path on disk, each
/// UTF-8 bytes and a length.
#[repr(C)]
pub struct IrohSendFile {
    pub name: *const u8,
    pub name_len: usize,
    pub path: *const u8,
    pub path_len: usize,
}

/// Where a session is.
pub const PHASE_IMPORTING: u32 = 0;
pub const PHASE_ONLINE: u32 = 1;
pub const PHASE_SERVING: u32 = 2;
pub const PHASE_FAILED: u32 = 3;
pub const PHASE_STOPPED: u32 = 4;

/// What a session has done, copied out by `sparkles_iroh_send_status`.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct IrohSendStatus {
    pub phase: u32,
    pub has_hash: u32,
    pub files_done: u64,
    pub files_total: u64,
    pub bytes_done: u64,
    pub hash: [u8; 32],
    pub peers: u64,
    pub requests: u64,
    pub bytes_sent: u64,
}

#[derive(Default)]
struct Shared {
    status: IrohSendStatus,
    ticket: String,
    error: String,
}

/// A running send.
pub struct Session {
    shared: Arc<Mutex<Shared>>,
    stop: Option<oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

/// The interface version.
#[no_mangle]
pub extern "C" fn sparkles_iroh_send_abi() -> u32 {
    ABI_VERSION
}

/// On Android, hands iroh the app's `JavaVM` and a global reference to its
/// application `Context`: iroh reads the system's DNS servers through JNI,
/// and without them its fallback relies on unwinding, which `sendme`'s
/// `panic = "abort"` turns into an abort. Elsewhere it does nothing. Call it
/// once, before the first `sparkles_iroh_send_start`.
///
/// # Safety
/// On Android, both pointers stay valid until the process exits.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_send_android_context(
    java_vm: *mut std::ffi::c_void,
    context: *mut std::ffi::c_void,
) {
    #[cfg(target_os = "android")]
    unsafe {
        iroh::dns::install_android_jni_context(java_vm, context)
    };
    #[cfg(not(target_os = "android"))]
    let _ = (java_vm, context);
}

/// Starts sending `files` under a fresh key, keeping the store beneath
/// `store_parent` (the system's temporary directory when empty). Never null:
/// a session that cannot start reports `PHASE_FAILED` and why.
///
/// # Safety
/// `files` points at `n` valid entries, each naming `name_len` and
/// `path_len` readable bytes; `store_parent` names `store_parent_len`.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_send_start(
    files: *const IrohSendFile,
    n: usize,
    store_parent: *const u8,
    store_parent_len: usize,
    flags: u32,
) -> *mut Session {
    let shared = Arc::new(Mutex::new(Shared::default()));
    let list = match unsafe { read_files(files, n) } {
        Ok(list) => list,
        Err(e) => return failed_session(shared, e),
    };
    let parent = match unsafe { read_str(store_parent, store_parent_len) } {
        Ok(p) if !p.is_empty() => PathBuf::from(p),
        Ok(_) => std::env::temp_dir(),
        Err(e) => return failed_session(shared, e),
    };
    shared.lock().unwrap().status.files_total = list.len() as u64;
    let (stop_tx, stop_rx) = oneshot::channel();
    let thread_shared = shared.clone();
    let thread = std::thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => return fail(&thread_shared, anyhow::Error::from(e)),
        };
        let result = runtime.block_on(serve(list, parent, flags, thread_shared.clone(), stop_rx));
        match result {
            Ok(()) => thread_shared.lock().unwrap().status.phase = PHASE_STOPPED,
            Err(e) => fail(&thread_shared, e),
        }
    });
    Box::into_raw(Box::new(Session { shared, stop: Some(stop_tx), thread: Some(thread) }))
}

/// Copies the session's status into `out`.
///
/// # Safety
/// `session` came from `sparkles_iroh_send_start` and is not stopped; `out`
/// is writable.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_send_status(session: *const Session, out: *mut IrohSendStatus) {
    let session = unsafe { &*session };
    unsafe { *out = session.shared.lock().unwrap().status };
}

/// Copies the session's ticket (`which` 0) or error (`which` 1) into `buf`,
/// up to `cap` bytes, and returns its whole length.
///
/// # Safety
/// As `sparkles_iroh_send_status`; `buf` holds `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_send_text(
    session: *const Session,
    which: u32,
    buf: *mut u8,
    cap: usize,
) -> usize {
    let session = unsafe { &*session };
    let shared = session.shared.lock().unwrap();
    let text = if which == 0 { &shared.ticket } else { &shared.error };
    let n = text.len().min(cap);
    if n > 0 {
        unsafe { std::ptr::copy_nonoverlapping(text.as_ptr(), buf, n) };
    }
    text.len()
}

/// Stops the session, waits for it to end, removes its store and frees it.
///
/// # Safety
/// `session` came from `sparkles_iroh_send_start`, and is not used again.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_send_stop(session: *mut Session) {
    let mut session = unsafe { Box::from_raw(session) };
    if let Some(stop) = session.stop.take() {
        let _ = stop.send(());
    }
    if let Some(thread) = session.thread.take() {
        let _ = thread.join();
    }
}

/// The collection's name for `files`, as `sendme` would import and name
/// them, with no network: written to `out`. Returns 0, or -1 with the error
/// in `err` (up to `err_cap` bytes; `err_len` its whole length).
///
/// # Safety
/// As `sparkles_iroh_send_start`; `out` holds 32 writable bytes, `err`
/// `err_cap`, and `err_len` is writable.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_collection(
    files: *const IrohSendFile,
    n: usize,
    out: *mut u8,
    err: *mut u8,
    err_cap: usize,
    err_len: *mut usize,
) -> i32 {
    let result = unsafe { read_files(files, n) }.and_then(|list| collection_hash(list));
    match result {
        Ok(hash) => {
            unsafe { std::ptr::copy_nonoverlapping(hash.as_ptr(), out, 32) };
            0
        }
        Err(e) => {
            let text = format!("{e:#}");
            let k = text.len().min(err_cap);
            unsafe {
                std::ptr::copy_nonoverlapping(text.as_ptr(), err, k);
                *err_len = text.len();
            }
            -1
        }
    }
}

/// The collection's name for `(name, path)` pairs, imported into an
/// in-memory store as `sendme` imports them.
pub fn collection_hash(files: Vec<(String, PathBuf)>) -> anyhow::Result<[u8; 32]> {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(async move {
        let store = MemStore::new();
        let (tag, _) = import(files, &store, ImportMode::Copy, |_, _| {}).await?;
        Ok(*tag.hash().as_bytes())
    })
}

// ---------------------------------------------------------------------------

async fn serve(
    files: Vec<(String, PathBuf)>,
    parent: PathBuf,
    flags: u32,
    shared: Arc<Mutex<Shared>>,
    stop: oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    let dir = tempfile_dir(&parent)?;
    let result = serve_in(files, &dir, flags, shared, stop).await;
    let _ = tokio::fs::remove_dir_all(&dir).await;
    result
}

async fn serve_in(
    files: Vec<(String, PathBuf)>,
    dir: &std::path::Path,
    flags: u32,
    shared: Arc<Mutex<Shared>>,
    mut stop: oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    let no_relay = flags & FLAG_NO_RELAY != 0;
    let endpoint = Endpoint::builder(presets::N0)
        .alpns(vec![iroh_blobs::protocol::ALPN.to_vec()])
        .secret_key(SecretKey::generate())
        .relay_mode(if no_relay { RelayMode::Disabled } else { RelayMode::Default })
        .bind()
        .await?;
    let store = FsStore::load(dir).await?;
    let (events_tx, events_rx) = mpsc::channel(32);
    let blobs = BlobsProtocol::new(
        &store,
        Some(EventSender::new(
            events_tx,
            EventMask { connected: ConnectMode::Notify, get: RequestMode::NotifyLog, ..EventMask::DEFAULT },
        )),
    );

    let progress = shared.clone();
    let (tag, _collection) = tokio::select! {
        r = import(files, blobs.store(), ImportMode::TryReference, move |done, bytes| {
            let mut s = progress.lock().unwrap();
            s.status.files_done = done;
            s.status.bytes_done = bytes;
        }) => r?,
        _ = &mut stop => return Ok(()),
    };
    {
        let mut s = shared.lock().unwrap();
        s.status.hash = *tag.hash().as_bytes();
        s.status.has_hash = 1;
        s.status.phase = PHASE_ONLINE;
    }

    let router = iroh::protocol::Router::builder(endpoint).accept(iroh_blobs::ALPN, blobs.clone()).spawn();
    if !no_relay {
        let ep = router.endpoint().clone();
        tokio::select! {
            _ = tokio::time::timeout(Duration::from_secs(30), ep.online()) => {}
            _ = &mut stop => {
                let _ = tokio::time::timeout(Duration::from_secs(2), router.shutdown()).await;
                return Ok(());
            }
        }
    }
    let ticket = BlobTicket::new(router.endpoint().addr(), tag.hash(), BlobFormat::HashSeq);
    {
        let mut s = shared.lock().unwrap();
        s.ticket = ticket.to_string();
        s.status.phase = PHASE_SERVING;
    }

    let watch = tokio::spawn(watch_events(events_rx, shared.clone()));
    let _ = stop.await;
    drop(tag);
    let _ = tokio::time::timeout(Duration::from_secs(2), router.shutdown()).await;
    watch.abort();
    Ok(())
}

// Counts peers, requests and bytes from the provider's events, as
// `sendme`'s progress display reads them.
async fn watch_events(mut rx: mpsc::Receiver<ProviderMessage>, shared: Arc<Mutex<Shared>>) {
    while let Some(item) = rx.recv().await {
        match item {
            ProviderMessage::ClientConnectedNotify(_) => shared.lock().unwrap().status.peers += 1,
            ProviderMessage::ConnectionClosed(_) => {
                let mut s = shared.lock().unwrap();
                s.status.peers = s.status.peers.saturating_sub(1);
            }
            ProviderMessage::GetRequestReceivedNotify(msg) => {
                shared.lock().unwrap().status.requests += 1;
                let shared = shared.clone();
                let mut updates = msg.rx;
                // While a request runs, its progress is estimated from the end
                // offsets it reports, which count a range from the blob's
                // start (a size request sends only the last chunk); when it
                // ends, the estimate is replaced by the bytes it really sent.
                tokio::spawn(async move {
                    let (mut at, mut estimate) = (0u64, 0u64);
                    while let Ok(Some(update)) = updates.recv().await {
                        let sent = match update {
                            RequestUpdate::Started(_) => {
                                at = 0;
                                continue;
                            }
                            RequestUpdate::Progress(p) => {
                                let step = p.end_offset.saturating_sub(at);
                                at = p.end_offset;
                                estimate += step;
                                shared.lock().unwrap().status.bytes_sent += step;
                                continue;
                            }
                            RequestUpdate::Completed(c) => c.stats.payload_bytes_sent,
                            RequestUpdate::Aborted(a) => a.stats.payload_bytes_sent,
                        };
                        let mut s = shared.lock().unwrap();
                        s.status.bytes_sent = s.status.bytes_sent.saturating_sub(estimate) + sent;
                        break;
                    }
                });
            }
            _ => {}
        }
    }
}

// Imports each file, as `sendme`'s `import` does, and stores the collection
// of their names, sorted by bytes. `progress` hears files and bytes done.
async fn import(
    files: Vec<(String, PathBuf)>,
    db: &Store,
    mode: ImportMode,
    progress: impl Fn(u64, u64) + Send + 'static,
) -> anyhow::Result<(TempTag, Collection)> {
    let mut named = Vec::with_capacity(files.len());
    let (mut done, mut bytes) = (0u64, 0u64);
    for (name, path) in files {
        let import = db.add_path_with_opts(AddPathOptions { path: path.clone(), mode, format: BlobFormat::Raw });
        let mut stream = import.stream().await;
        let mut size = 0;
        let tag = loop {
            let item = stream.next().await.context("import stream ended without a tag")?;
            match item {
                AddProgressItem::Size(s) => size = s,
                AddProgressItem::Error(cause) => anyhow::bail!("error importing {}: {}", path.display(), cause),
                AddProgressItem::Done(tt) => break tt,
                _ => {}
            }
        };
        done += 1;
        bytes += size;
        progress(done, bytes);
        named.push((name, tag));
    }
    named.sort_by(|(a, _), (b, _)| a.cmp(b));
    let (collection, tags): (Collection, Vec<_>) =
        named.into_iter().map(|(name, tag)| ((name, tag.hash()), tag)).unzip();
    let tag = collection.clone().store(db).await?;
    drop(tags);
    Ok((tag, collection))
}

fn tempfile_dir(parent: &std::path::Path) -> anyhow::Result<PathBuf> {
    let suffix: u64 = rand::random();
    let dir = parent.join(format!(".sparkles-iroh-send-{suffix:016x}"));
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    Ok(dir)
}

fn fail(shared: &Arc<Mutex<Shared>>, e: anyhow::Error) {
    let mut s = shared.lock().unwrap();
    s.error = format!("{e:#}");
    s.status.phase = PHASE_FAILED;
}

fn failed_session(shared: Arc<Mutex<Shared>>, e: anyhow::Error) -> *mut Session {
    fail(&shared, e);
    Box::into_raw(Box::new(Session { shared, stop: None, thread: None }))
}

unsafe fn read_str(p: *const u8, n: usize) -> anyhow::Result<String> {
    if n == 0 {
        return Ok(String::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(p, n) };
    Ok(std::str::from_utf8(bytes).context("a name or path is not UTF-8")?.to_owned())
}

unsafe fn read_files(files: *const IrohSendFile, n: usize) -> anyhow::Result<Vec<(String, PathBuf)>> {
    let entries = if n == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(files, n) } };
    entries
        .iter()
        .map(|f| {
            let name = unsafe { read_str(f.name, f.name_len) }?;
            let path = unsafe { read_str(f.path, f.path_len) }?;
            Ok((name, PathBuf::from(path)))
        })
        .collect()
}
