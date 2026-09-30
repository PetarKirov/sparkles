use std::slice;

// The D caller supplies a readable byte slice for the entire call. Rust slice
// construction requires non-null alignment even at length zero, unlike C APIs.
unsafe fn input<'a>(bytes: *const u8, length: usize) -> &'a [u8] {
    if length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(bytes, length) }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn utf_bench_rust_invalid(bytes: *const u8, length: usize) -> usize {
    match simdutf8::compat::from_utf8(unsafe { input(bytes, length) }) {
        Ok(_) => length,
        Err(error) => error.valid_up_to(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn utf_bench_rust_valid(bytes: *const u8, length: usize) -> i32 {
    simdutf8::basic::from_utf8(unsafe { input(bytes, length) }).is_ok() as i32
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn utf_bench_xutf_width(bytes: *const u8, length: usize) -> usize {
    xutf::width::<xutf::Utf8>(unsafe { input(bytes, length) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn utf_bench_xutf_boundaries(
    bytes: *const u8,
    length: usize,
    ends: *mut usize,
    capacity: usize,
) -> usize {
    let mut count = 0;
    let mut offset = 0;
    for cluster in xutf::graphemes::<xutf::Utf8>(unsafe { input(bytes, length) }) {
        if count == capacity {
            return usize::MAX;
        }
        offset += cluster.units.len();
        unsafe { ends.add(count).write(offset) };
        count += 1;
    }
    count
}
