//! The receive half of the iroh bridge: a collection read from a peer, its
//! names first, then the chosen files' verified bytes (`fsx` `XR2`–`XR6`,
//! docs/specs/fsx).
//!
//! `sparkles_iroh_receive_open` connects to the ticket's node and asks for the
//! hash sequence and the metadata blob, nothing else; the filter is then the
//! caller's to evaluate over the names. No size is asked for: iroh sends a
//! blob in groups of 16 KiB, so proving a small file's size would fetch the
//! file. `sparkles_iroh_receive_fetch` asks for the
//! chosen files whole, and `sparkles_iroh_receive_next` hands out what
//! arrives, a file at a time in the collection's order: its start, its data
//! in order, each piece verified against the file's BLAKE3 tree before it is
//! handed out, and its end.
//!
//! As in the send half, every function is `extern "C"`, strings cross as a
//! pointer and a length, and a receiver is an opaque pointer freed by
//! `sparkles_iroh_receive_close`.

use std::{str::FromStr, time::Duration};

use anyhow::Context;
use bao_tree::io::fsm::BaoContentItem;
use iroh::{endpoint::presets, Endpoint, RelayMode, SecretKey};
use iroh_blobs::{
    format::collection::Collection,
    get::fsm,
    protocol::{ChunkRanges, GetRequest},
    ticket::BlobTicket,
    BlobFormat, Hash,
};
use tokio::sync::mpsc;

/// The flag that disables relays: the peer is reached at its direct addresses.
pub const FLAG_NO_RELAY: u32 = 1;

/// How long reaching the peer may take before the receive fails (`XR6`).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// What `sparkles_iroh_receive_next` returns.
pub const NEXT_DONE: i32 = 0;
pub const NEXT_START: i32 = 1;
pub const NEXT_DATA: i32 = 2;
pub const NEXT_END: i32 = 3;
pub const NEXT_ERROR: i32 = -1;

/// One file of the collection: its name and its digest. `name` points into
/// the receiver and lives as long as it.
#[repr(C)]
pub struct IrohReceiveEntry {
    pub name: *const u8,
    pub name_len: usize,
    pub hash: [u8; 32],
}

/// What has been read from the peer.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct IrohReceiveStats {
    pub payload_bytes_read: u64,
    pub other_bytes_read: u64,
}

enum Event {
    Start { index: u64, size: u64 },
    Data { index: u64, offset: u64, data: Vec<u8> },
    End { index: u64 },
    Error(String),
}

/// An open collection.
pub struct Receiver {
    runtime: tokio::runtime::Runtime,
    endpoint: Option<Endpoint>,
    connection: Option<iroh::endpoint::Connection>,
    root: Hash,
    entries: Vec<(String, Hash)>,
    stats: std::sync::Arc<std::sync::Mutex<IrohReceiveStats>>,
    error: String,
    events: Option<mpsc::Receiver<Event>>,
    pending: Option<(u64, u64, Vec<u8>, usize)>,
}

/// Connects to the ticket's node and reads the collection's names (`XR2`). Never null: a receiver that could not open holds the
/// reason, `sparkles_iroh_receive_text` reads it, and it lists nothing.
///
/// # Safety
/// `ticket` names `ticket_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_open(ticket: *const u8, ticket_len: usize, flags: u32) -> *mut Receiver {
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(rt) => rt,
        Err(e) => panic!("cannot start a runtime: {e}"),
    };
    let mut r = Receiver {
        runtime,
        endpoint: None,
        connection: None,
        root: Hash::EMPTY,
        entries: Vec::new(),
        stats: Default::default(),
        error: String::new(),
        events: None,
        pending: None,
    };
    let text = if ticket_len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(ticket, ticket_len) } };
    let opened = match std::str::from_utf8(text) {
        Ok(t) => {
            let t = t.to_owned();
            r.runtime.block_on(open(t, flags))
        }
        Err(_) => Err(anyhow::anyhow!("the ticket is not UTF-8")),
    };
    match opened {
        Ok(o) => {
            r.endpoint = Some(o.endpoint);
            r.connection = Some(o.connection);
            r.root = o.root;
            r.entries = o.entries;
            *r.stats.lock().unwrap() = o.stats;
        }
        Err(e) => r.error = format!("{e:#}"),
    }
    Box::into_raw(Box::new(r))
}

/// The number of files the collection lists; 0 for one that did not open.
///
/// # Safety
/// `r` came from `sparkles_iroh_receive_open` and is not closed.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_count(r: *const Receiver) -> usize {
    unsafe { &*r }.entries.len()
}

/// Copies entry `i` into `out`.
///
/// # Safety
/// As `sparkles_iroh_receive_count`; `i` is below the count, `out` writable.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_entry(r: *const Receiver, i: usize, out: *mut IrohReceiveEntry) {
    let (name, hash) = &unsafe { &*r }.entries[i];
    unsafe {
        *out = IrohReceiveEntry { name: name.as_ptr(), name_len: name.len(), hash: *hash.as_bytes() };
    }
}

/// Copies the bytes read so far into `out`.
///
/// # Safety
/// As `sparkles_iroh_receive_count`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_stats(r: *const Receiver, out: *mut IrohReceiveStats) {
    unsafe { *out = *(&*r).stats.lock().unwrap() };
}

/// Copies the receiver's error into `buf`, up to `cap` bytes, and returns its
/// whole length; 0 when there is none.
///
/// # Safety
/// As `sparkles_iroh_receive_count`; `buf` holds `cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_text(r: *const Receiver, buf: *mut u8, cap: usize) -> usize {
    let text = &unsafe { &*r }.error;
    let n = text.len().min(cap);
    if n > 0 {
        unsafe { std::ptr::copy_nonoverlapping(text.as_ptr(), buf, n) };
    }
    text.len()
}

/// Asks for the files at `indices`, ascending and each below the count, whole
/// (`XR3`). Returns 0, or -1 with the reason in the receiver's text.
///
/// # Safety
/// As `sparkles_iroh_receive_count`; `indices` holds `n` readable entries.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_fetch(r: *mut Receiver, indices: *const u64, n: usize) -> i32 {
    let r = unsafe { &mut *r };
    let Some(connection) = r.connection.clone() else {
        if r.error.is_empty() {
            r.error = "the collection is not open".into();
        }
        return -1;
    };
    let chosen = if n == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(indices, n) } }.to_vec();
    if chosen.windows(2).any(|w| w[0] >= w[1]) || chosen.iter().any(|&i| i as usize >= r.entries.len()) {
        r.error = "the files to fetch are not ascending indices of the collection".into();
        return -1;
    }
    let root = r.root;
    let (tx, rx) = mpsc::channel(64);
    let stats = r.stats.clone();
    let hashes: Vec<Hash> = chosen.iter().map(|&i| r.entries[i as usize].1).collect();
    r.runtime.spawn(async move {
        if let Err(e) = stream(connection, root, chosen, hashes, tx.clone(), stats).await {
            let _ = tx.send(Event::Error(format!("{e:#}"))).await;
        }
    });
    r.events = Some(rx);
    0
}

/// Waits for what arrives next and returns its kind: `NEXT_START` with the
/// file's `index` and its size in `len`, as the peer states it; `NEXT_END`
/// proves it, the last chunk having verified; `NEXT_DATA` with `index`, `offset`
/// and `len` bytes written to `buf` (up to `cap`; the rest follows at the next
/// call); `NEXT_END` with `index`; `NEXT_DONE` when every chosen file has
/// ended; `NEXT_ERROR` with the reason in the receiver's text (`XR4`).
///
/// # Safety
/// As `sparkles_iroh_receive_count`, after `sparkles_iroh_receive_fetch`;
/// `index`, `offset` and `len` are writable and `buf` holds `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_next(
    r: *mut Receiver,
    index: *mut u64,
    offset: *mut u64,
    buf: *mut u8,
    cap: usize,
    len: *mut usize,
) -> i32 {
    let r = unsafe { &mut *r };
    if let Some((i, at, data, from)) = r.pending.take() {
        return unsafe { hand_out(r, i, at, data, from, index, offset, buf, cap, len) };
    }
    let Some(events) = r.events.as_mut() else {
        r.error = "nothing was asked for".into();
        return NEXT_ERROR;
    };
    match r.runtime.block_on(events.recv()) {
        None => NEXT_DONE,
        Some(Event::Start { index: i, size }) => {
            unsafe {
                *index = i;
                *len = size as usize;
            }
            NEXT_START
        }
        Some(Event::Data { index: i, offset: at, data }) => unsafe { hand_out(r, i, at, data, 0, index, offset, buf, cap, len) },
        Some(Event::End { index: i }) => {
            unsafe { *index = i };
            NEXT_END
        }
        Some(Event::Error(e)) => {
            r.error = e;
            r.events = None;
            NEXT_ERROR
        }
    }
}

/// Closes the connection and frees the receiver.
///
/// # Safety
/// `r` came from `sparkles_iroh_receive_open` and is not used again.
#[no_mangle]
pub unsafe extern "C" fn sparkles_iroh_receive_close(r: *mut Receiver) {
    let mut r = unsafe { Box::from_raw(r) };
    r.events = None;
    if let Some(c) = r.connection.take() {
        c.close(0u32.into(), b"done");
    }
    if let Some(ep) = r.endpoint.take() {
        // The timer belongs to the runtime, so it is made inside it.
        r.runtime.block_on(async move {
            let _ = tokio::time::timeout(Duration::from_secs(2), ep.close()).await;
        });
    }
}

// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
unsafe fn hand_out(
    r: &mut Receiver,
    i: u64,
    at: u64,
    data: Vec<u8>,
    from: usize,
    index: *mut u64,
    offset: *mut u64,
    buf: *mut u8,
    cap: usize,
    len: *mut usize,
) -> i32 {
    let n = (data.len() - from).min(cap);
    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr().add(from), buf, n);
        *index = i;
        *offset = at + from as u64;
        *len = n;
    }
    if from + n < data.len() {
        r.pending = Some((i, at, data, from + n));
    }
    NEXT_DATA
}

struct Opened {
    endpoint: Endpoint,
    connection: iroh::endpoint::Connection,
    root: Hash,
    entries: Vec<(String, Hash)>,
    stats: IrohReceiveStats,
}

async fn open(ticket: String, flags: u32) -> anyhow::Result<Opened> {
    let ticket = BlobTicket::from_str(ticket.trim()).context("not a sendme ticket")?;
    anyhow::ensure!(
        ticket.format() == BlobFormat::HashSeq,
        "the ticket names a single blob; fsx reads collections, as sendme sends a directory"
    );
    let no_relay = flags & FLAG_NO_RELAY != 0;
    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(SecretKey::generate())
        .relay_mode(if no_relay { RelayMode::Disabled } else { RelayMode::Default })
        .bind()
        .await?;
    let connection = tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect(ticket.addr().clone(), iroh_blobs::protocol::ALPN))
        .await
        .context("the peer could not be reached in 30 seconds")??;

    // The sequence and the names, and nothing of any file.
    let request = GetRequest::builder()
        .root(ChunkRanges::all())
        .next(ChunkRanges::all())
        .build(ticket.hash());
    let start = fsm::start(connection.clone(), request, Default::default());
    let connected = start.next().await?;
    let fsm::ConnectedNext::StartRoot(root) = connected.next().await? else {
        anyhow::bail!("the peer answered without the collection");
    };
    let (next, _links, collection) = Collection::read_fsm(root).await?;
    let closing = match next {
        fsm::EndBlobNext::MoreChildren(child) => child.finish(),
        fsm::EndBlobNext::Closing(closing) => closing,
    };
    let s = closing.next().await?;
    let stats = IrohReceiveStats { payload_bytes_read: s.payload_bytes_read, other_bytes_read: s.other_bytes_read };
    let entries: Vec<(String, Hash)> = collection.iter().cloned().collect();
    Ok(Opened { endpoint, connection, root: ticket.hash(), entries, stats })
}

// Streams the files at `chosen` (indices into the collection's files), in
// order, each leaf verified by the decoder before it is sent on.
async fn stream(
    connection: iroh::endpoint::Connection,
    root: Hash,
    chosen: Vec<u64>,
    hashes: Vec<Hash>,
    tx: mpsc::Sender<Event>,
    stats: std::sync::Arc<std::sync::Mutex<IrohReceiveStats>>,
) -> anyhow::Result<()> {
    if chosen.is_empty() {
        return Ok(());
    }
    let mut builder = GetRequest::builder();
    for &i in &chosen {
        builder = builder.child(i + 1, ChunkRanges::all());
    }
    let request = builder.build(root);
    let start = fsm::start(connection, request, Default::default());
    let connected = start.next().await?;
    let mut at = match connected.next().await? {
        fsm::ConnectedNext::StartChild(child) => fsm::EndBlobNext::MoreChildren(child),
        fsm::ConnectedNext::Closing(closing) => fsm::EndBlobNext::Closing(closing),
        fsm::ConnectedNext::StartRoot(_) => anyhow::bail!("the peer sent the collection again"),
    };
    let mut k = 0;
    let closing = loop {
        match at {
            fsm::EndBlobNext::MoreChildren(child) => {
                anyhow::ensure!(k < chosen.len(), "the peer sent more files than were asked for");
                let index = chosen[k];
                anyhow::ensure!(child.offset() == index + 2, "the peer sent the files out of order");
                let header = child.next(hashes[k]);
                let (mut content, size) = header.next().await?;
                if tx.send(Event::Start { index, size }).await.is_err() {
                    return Ok(());
                }
                let end = loop {
                    match content.next().await {
                        fsm::BlobContentNext::More((next, item)) => {
                            match item.with_context(|| format!("file {index} did not verify"))? {
                                BaoContentItem::Leaf(leaf) => {
                                    let data = leaf.data[..].to_vec();
                                    if tx.send(Event::Data { index, offset: leaf.offset, data }).await.is_err() {
                                        return Ok(());
                                    }
                                }
                                BaoContentItem::Parent(_) => {}
                            }
                            content = next;
                        }
                        fsm::BlobContentNext::Done(end) => break end,
                    }
                };
                if tx.send(Event::End { index }).await.is_err() {
                    return Ok(());
                }
                k += 1;
                at = end.next();
            }
            fsm::EndBlobNext::Closing(closing) => break closing,
        }
    };
    anyhow::ensure!(k == chosen.len(), "the peer sent {k} of the {} files asked for", chosen.len());
    let s = closing.next().await?;
    let mut st = stats.lock().unwrap();
    st.payload_bytes_read += s.payload_bytes_read;
    st.other_bytes_read += s.other_bytes_read;
    Ok(())
}
