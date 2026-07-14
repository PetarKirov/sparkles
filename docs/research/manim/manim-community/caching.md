# Manim's caching: deterministic frames and per-`play()` content hashing

Why re-running an unchanged scene is nearly free. Manim Community caches at the
granularity of a single `self.play(...)` call: it hashes the camera, the
animations, and the scene's mobjects into one string, and if a partial movie file
with that name already exists on disk, it skips rendering entirely. The whole
scheme rests on **deterministic frame sampling** — without it, the same input
could produce different frames and the cache would be unsound. This is the
determinism/caching companion to the Manim Community deep-dive; shared terms are
in [`../concepts.md`][concepts].

---

## How it works

### Determinism: a fixed frame grid

An animation's frames are sampled on a fixed grid, not by wall-clock. In
`Scene.get_time_progression` ([`scene.py:1051`][scene]):

```python
# scene.py:1087 — frames land on a fixed 1/fps grid, independent of render speed
step = 1 / config["frame_rate"]
times = np.arange(0, run_time, step)
```

and `update_to_time` ([`scene.py:1687`][scene]) maps each sampled `t` to a
normalized progress `alpha = t / animation.run_time` before interpolating. The
same `(animation, run_time, frame_rate)` therefore always visits the same `t`
values and produces the same `alpha` sequence — [deterministic frame
sampling][deterministic]. Interpolation itself is pure array math
(`self.points = path_func(m1.points, m2.points, alpha)`,
[`mobject.py:3149`][mobject]), so a given `alpha` always yields the same
geometry, and Cairo rasterizes it identically. The [`frame-capture.d`][ex-frame]
probe demonstrates the invariant the cache depends on: identical input bytes →
identical checksum across runs.

### The content hash of a `play()` call

Before rendering, `CairoRenderer.play` ([`cairo_renderer.py:64`][cairo-r])
computes a hash and short-circuits on a cache hit:

```python
# cairo_renderer.py:87 — hash this play() call; skip rendering if already cached
hash_current_animation = get_hash_from_play_call(
    scene, self.camera, scene.animations, scene.mobjects)
if self.file_writer.is_already_cached(hash_current_animation):
    self.skip_animations = True
    self.time += scene.duration
```

`get_hash_from_play_call` ([`hashing.py:333`][hashing]) hashes **three** inputs
independently and concatenates them. Its docstring defines the key exactly:

> _"A string concatenation of the respective hashes of `camera_object`,
> `animations_list` and `current_mobjects_list`, separated by `_`."_ —
[`hashing.py:358`][hashing]

```python
# hashing.py:363 — serialize each input to JSON, crc32 it, join with "_"
camera_json = get_json(camera_object)
animations_list_json = [get_json(x) for x in sorted(animations_list, key=str)]
current_mobjects_list_json = [get_json(x) for x in current_mobjects_list]
hash_camera, hash_animations, hash_current_mobjects = (
    zlib.crc32(repr(json_val).encode())
    for json_val in [camera_json, animations_list_json, current_mobjects_list_json])
hash_complete = f"{hash_camera}_{hash_animations}_{hash_current_mobjects}"
```

Each component is a `zlib.crc32` over a custom JSON serialization (`get_json` →
`_CustomEncoder`, [`hashing.py:317`][hashing]). Two subtleties make the JSON
stable:

- **Run-dependent fields are stripped.** `KEYS_TO_FILTER_OUT = {"original_id",
"background", "pixel_array", "pixel_array_to_cairo_context"}`
  ([`hashing.py:29`][hashing]), flagged in-source because _"Sometimes there are
  elements that are not suitable for hashing (too long or run-dependent). This is
  used to filter them out."_ ([`hashing.py:27`][hashing]). A per-run object id or
  the live pixel buffer would otherwise poison the hash.
- **Circular references are broken.** The scene graph is a tree with shared
  references, so `_Memoizer` ([`hashing.py:37`][hashing]) tracks every object it
  has serialized — keyed by `hash`, falling back to `id`
  ([`hashing.py:135`][hashing]) — and replaces a second sighting with the
  placeholder `"AP"` (`ALREADY_PROCESSED_PLACEHOLDER`, [`hashing.py:53`][hashing]).
  After each hash the registry is reset (`reset_already_processed`,
  [`hashing.py:374`][hashing]) so the next `play()` starts clean.

### The hash _is_ the filename

There is no separate cache index. `add_partial_movie_file`
([`scene_file_writer.py:249`][writer]) names the clip after the hash directly:

```python
# scene_file_writer.py:270 — the content hash becomes the partial-movie filename
new_partial_movie_file = str(
    self.partial_movie_directory / f"{hash_animation}{config['movie_file_extension']}")
```

so `is_already_cached` ([`scene_file_writer.py:606`][writer]) is a single
filesystem check — `path.exists()` on
`partial_movie_directory / f"{hash_invocation}{movie_file_extension}"`. Each
`play()` writes one **partial movie file** (`open_partial_movie_stream`,
[`scene_file_writer.py:540`][writer]); `finish()` concatenates all of them with
FFmpeg's `concat` demuxer into the final video ([`scene_file_writer.py:652`][writer]).
On a cache hit, rendering is skipped and the existing partial file is reused in
that concat list — the concrete payoff of the whole scheme.

### Cache eviction and disabling

`clean_cache` ([`scene_file_writer.py:857`][writer]) keeps the partial-movie
directory bounded: when the file count exceeds `config["max_files_cached"]`
(default `100`, [`default.cfg`][default-cfg]), it deletes the oldest files ranked
by access time (`st_atime`, [`scene_file_writer.py:870`][writer]) — an LRU
policy. Caching can be turned off with `disable_caching`
([`cairo_renderer.py:82`][cairo-r], which names each animation
`f"uncached_{self.num_plays:05}"` instead), and the whole directory flushed with
`flush_cache_directory` ([`scene_file_writer.py:879`][writer]).

---

## Determinism, caching & performance (analysis)

| Property             | Mechanism                                                   | Source                                                  |
| -------------------- | ----------------------------------------------------------- | ------------------------------------------------------- |
| Frame determinism    | `np.arange(0, run_time, 1/frame_rate)` fixed grid           | [`scene.py:1087`][scene]                                |
| Progress determinism | `alpha = t / run_time`; pure `path_func` lerp               | [`scene.py:1693`][scene] · [`mobject.py:3149`][mobject] |
| Cache granularity    | one hash + one partial movie file **per `play()`**          | [`cairo_renderer.py:64`][cairo-r]                       |
| Cache key            | `crc32(camera)_crc32(anims)_crc32(mobjects)` of custom JSON | [`hashing.py:333`][hashing]                             |
| Hash stability       | `KEYS_TO_FILTER_OUT` + `_Memoizer` circular-ref placeholder | [`hashing.py:27`][hashing]                              |
| Cache lookup         | `path.exists()` — the hash is the filename                  | [`scene_file_writer.py:606`][writer]                    |
| Eviction             | LRU by `st_atime`, capped at `max_files_cached` (100)       | [`scene_file_writer.py:857`][writer]                    |

> [!WARNING]
> The soundness of the cache is only as good as the hash's coverage. Because
> `KEYS_TO_FILTER_OUT` and the custom encoder _omit_ fields, a change confined to
> an un-serialized attribute would **not** invalidate the cache — the engine
> would silently reuse a stale frame. This is the standard [content-hash][content]
> trade-off: cheap lookups in exchange for trusting that the hashed subset fully
> determines the output. The default guard is `disable_caching`, and the
> per-`play()` granularity keeps any staleness localized to one clip.

The performance win compounds with the static/moving split: `begin_animations`
([`scene.py:1334`][scene]) paints non-moving mobjects once into a static image so
only `moving_mobjects` are re-rasterized per frame. Together, deterministic
sampling (correctness), content hashing (skip unchanged clips), and the static
image (skip unchanged pixels within a clip) are the three layers that make
iterative editing of a long scene practical on a single-threaded CPU rasterizer.

---

## Sources

- [`manim/utils/hashing.py`][hashing] — `get_hash_from_play_call`, `get_json` /
  `_CustomEncoder`, `KEYS_TO_FILTER_OUT`, `_Memoizer` circular-ref handling.
- [`manim/renderer/cairo_renderer.py`][cairo-r] — the `play` cache check,
  `disable_caching`.
- [`manim/scene/scene.py`][scene] — deterministic time progression,
  `update_to_time`, static/moving split.
- [`manim/scene/scene_file_writer.py`][writer] — partial movie files,
  `is_already_cached`, concat, LRU `clean_cache` / `flush_cache_directory`.
- [`manim/_config/default.cfg`][default-cfg] — `max_files_cached`,
  `disable_caching`, `frame_rate`.

Related: the Manim Community deep-dive · [`scene-graph.md`][scene-graph] ·
[`text-pipeline.md`][text-pipeline] · [`../concepts.md`][concepts] ·
[`manimgl`][manimgl]. Probe: [`frame-capture.d`][ex-frame].

<!-- References -->

[scene-graph]: ./scene-graph.md
[text-pipeline]: ./text-pipeline.md
[concepts]: ../concepts.md
[manimgl]: ../manimgl.md
[deterministic]: ../concepts.md#deterministic-frame-sampling
[content]: ../concepts.md#content-hash-caching
[ex-frame]: ../examples/frame-capture.d
[hashing]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/utils/hashing.py
[cairo-r]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/renderer/cairo_renderer.py
[scene]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/scene/scene.py
[mobject]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/mobject/mobject.py
[writer]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/scene/scene_file_writer.py
[default-cfg]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/_config/default.cfg
