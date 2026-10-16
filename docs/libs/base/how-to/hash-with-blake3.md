# Hash bytes with BLAKE3

`sparkles.base.hash.blake3` implements [BLAKE3](https://github.com/BLAKE3-team/BLAKE3-specs/blob/ea51a3ac997288bf690ee82ac9cfc8b3e0e60f2a/blake3.pdf)
with no allocation and no C dependency. Every function is
`@safe pure nothrow @nogc`, and works in CTFE.

## Hash a whole input

```d
import sparkles.base.hash.blake3 : blake3;

ubyte[32] digest = blake3("hello, world");     // a string
ubyte[32] other = blake3(fileBytes);           // or any const(ubyte)[]
```

The 32-byte digest is the plain BLAKE3 hash of the raw bytes — the identity
the [content-addressing recommendations](../../../research/content-addressing/recommendations.md)
use for blobs.

## Hash a stream

`Blake3` is an output range of bytes and byte or `char` slices, and a
`std.digest` digest:

```d
import sparkles.base.hash.blake3 : Blake3;

Blake3 hasher;
foreach (chunk; file.byChunk(64 * 1024))
    hasher.put(chunk);
ubyte[32] digest = hasher.finish();
```

`finish` does not consume the hasher: more input may follow, and a later
`finish` covers all of it. `reset` forgets the input and keeps the mode.

## Read more than 32 bytes

BLAKE3 is an extendable-output function. `finishXof` fills a buffer of any
length, optionally from an offset; every prefix agrees with a shorter output:

```d
ubyte[128] stream;
hasher.finishXof(stream[]);                 // stream[0 .. 32] == hasher.finish()
ubyte[16] tail;
hasher.finishXof(tail[], seek: 1 << 20);    // bytes 1 MiB .. 1 MiB + 16
```

## Authenticate or derive keys

The keyed mode is a MAC and PRF under a 32-byte key; the key-derivation mode
turns key material into a key for one purpose, named by a context string that
is hardcoded and globally unique (never a secret or a per-call value):

```d
import sparkles.base.hash.blake3 : blake3DeriveKey, blake3Keyed, Blake3;

ubyte[32] tag = blake3Keyed(key, message);
ubyte[32] sessionKey = blake3DeriveKey("example.com 2026-10-16 session keys v1",
    masterSecret);

auto mac = Blake3.keyed(key);                // or Blake3.deriveKey(context)
mac.put(message);
```

## Choose the implementation

By default each call takes the fastest backend this CPU supports: AVX-512,
AVX2 or SSE4.1 on x86_64, NEON on AArch64 (LDC builds), and plain D
otherwise. All backends produce identical output. Pin one for testing or
measurement — it must be supported:

```d
import sparkles.base.hash.blake3 : Blake3, Blake3Backend, isSupported;

if (isSupported(Blake3Backend.avx2))
{
    auto hasher = Blake3.withBackend(Blake3Backend.avx2);
    // ...
}
```

`bestBlake3Backend` is `pure` too: CPU features cannot change during a run,
and the dispatch reads them from immutable data initialized before `main`.

## How fast it is

On an AMD Ryzen 9 7940HX (one thread, LDC 1.42 `-O3 -mcpu=native`), against
the official C implementation (`libblake3` 1.8.5, its own SIMD dispatch):

| Input  | Portable D |  D SSE4.1 |    D AVX2 | D AVX-512 | C reference |
| ------ | ---------: | --------: | --------: | --------: | ----------: |
| 1 KiB  |  0.96 GB/s | 1.19 GB/s | 1.19 GB/s | 1.19 GB/s |   1.23 GB/s |
| 64 KiB |  0.92 GB/s | 3.62 GB/s | 6.93 GB/s | 7.86 GB/s |   8.89 GB/s |
| 1 MiB  |  0.91 GB/s | 3.62 GB/s | 7.00 GB/s | 7.93 GB/s |   9.01 GB/s |

Reproduce with the comparison bench in `libs/base/bench/blake3` (its README
has the commands), or the per-backend rows alone with
`dub test :base -b bench -- --bench -i blake3.bench --group-by=size`.
