//! `bao-outboard <file>...` prints, for each file, one line: the hex BLAKE3
//! root and the hex pre-order outboard that bao-tree computes for it at
//! iroh's chunk-group size (16 KiB, `BlockSize(4)`): the layout of iroh's
//! `.obao4` files. The oracle of sparkles' outboards (content-addressing
//! decision C2); it does nothing else.
use bao_tree::io::outboard::PreOrderMemOutboard;
use bao_tree::BlockSize;
use std::io::Write;

fn hex(bytes: &[u8], out: &mut impl Write) -> std::io::Result<()> {
    for b in bytes {
        write!(out, "{b:02x}")?;
    }
    Ok(())
}

fn main() -> std::io::Result<()> {
    let iroh = BlockSize::from_chunk_log(4);
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for path in std::env::args().skip(1) {
        let data = std::fs::read(&path)?;
        let ob = PreOrderMemOutboard::create(&data, iroh);
        hex(ob.root.as_bytes(), &mut out)?;
        write!(out, " ")?;
        hex(&ob.data, &mut out)?;
        writeln!(out)?;
    }
    Ok(())
}
