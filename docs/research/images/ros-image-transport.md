# ROS `image_transport` and `cv_bridge` (C++)

The robotics middleware's image stack: a self-describing frame message (`sensor_msgs/msg/Image`) stamped with acquisition time and a coordinate frame, a string vocabulary of pixel encodings, runtime-loaded transport plugins that re-encode the frame per subscriber, and a bridge that views the message bytes as an OpenCV `cv::Mat` without copying.

| Field         | Value                                                                                                                                                                                                                                                                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 (Python bindings in `image_transport_py` and `cv_bridge/python`); messages in the ROS 2 IDL (`.msg`)                                                                                                                                                                                                                                        |
| License       | `image_transport`: BSD-3-Clause ([`package.xml`][it-pkg]); `cv_bridge`: Apache-2.0 and BSD ([`package.xml`][cvb-pkg]); `sensor_msgs`: Apache-2.0                                                                                                                                                                                                  |
| Repository    | [ros-perception/image_common][it-repo] (`image_transport`); [ros-perception/vision_opencv][cvb-repo] (`cv_bridge`); read alongside [ros2/common_interfaces][ci-repo] (`sensor_msgs`) and [ros-perception/image_transport_plugins][itp-repo] (`compressed`, `theora`)                                                                              |
| Revision read | `image_common` `faf0db265fa97d15631d343f79d64d86c423ee8f` (October 22, 2026, "7.0.5"); `vision_opencv` `50f6f1feccc65dd2ef87f863cb812a8aa0789062` (December 29, 2025); `common_interfaces` `05a5c4e6a42f89b71745320c34c467cb391a94b9` (October 28, 2026); `image_transport_plugins` `8deb0498fd1bb611738dc47f026a1f6eedd13011` (October 14, 2026) |
| Documentation | [`image_transport/doc/overview.rst`][it-overview]; [`Image.msg`][img-msg]; [`image_encodings.hpp`][enc]; [REP 2007, type adaptation][rep2007]                                                                                                                                                                                                     |
| Category      | Architectural libraries (interchange message and transport)                                                                                                                                                                                                                                                                                       |
| Tier          | B                                                                                                                                                                                                                                                                                                                                                 |
| Last reviewed | November 7, 2026                                                                                                                                                                                                                                                                                                                                  |

## Overview

### What it solves

A robot publishes camera frames on a topic; perception nodes on the same host or across a network subscribe to them. The frame must describe itself completely (no side channel says what the bytes are), it must say _when_ it was captured and _which sensor frame_ it lives in, and it must be cheap to move. ROS splits the job three ways:

- **`sensor_msgs/msg/Image`** is the frame on the wire: six fields plus a header.
- **`image_transport`** puts a plugin layer under the publisher and subscriber so that one camera topic is also available as `…/compressed`, `…/theora` and so on, each subscriber choosing one.
- **`cv_bridge`** converts between the message and `cv::Mat`, sharing the bytes when it can.

The `image_transport` overview states the motivation and the shape ([`overview.rst`][it-overview]):

> _"Raw images are large. A single 1080p colour frame is roughly 6 MB. Sending these frames over a network at 30 Hz consumes nearly 1.5 Gbit/s of bandwidth."_
>
> _"The publisher side creates one sub-publisher per installed transport plugin. The subscriber side picks exactly one transport based on the `image_transport` parameter (default: `raw`)."_

### Design philosophy

- **The message is the contract.** `Image.msg` fixes what every node can rely on; libraries on either side (OpenCV, PCL, Python) adapt to it.
- **Transport is not the application's business.** `image_transport` _"acts as a transparent layer on top of standard ROS 2 publishers and subscribers, allowing image data to be transported in raw or compressed form without any changes to the application code"_ ([`overview.rst`][it-overview]).
- **Share, then copy only when forced.** `toCvShare` returns a read-only view _"sharing the image data if possible"_ and copies only when the encoding or byte order must change ([`cv_bridge.hpp`][cvb-share-doc]).

## How it works

### The frame message

`sensor_msgs/msg/Image`, its header and six fields with the comments abridged ([`Image.msg`][img-msg]):

```text
std_msgs/Header header # Header timestamp should be acquisition time of image
                       # Header frame_id should be optical frame of camera
uint32 height          # image height, that is, number of rows
uint32 width           # image width, that is, number of columns
string encoding        # Encoding of pixels -- channel meaning, ordering, size
uint8 is_bigendian     # is this data bigendian?
uint32 step            # Full row length in bytes
uint8[] data           # actual matrix data, size is (step * rows)
```

`std_msgs/Header` is `builtin_interfaces/Time stamp` plus `string frame_id` ([`Header.msg`][header-msg]). The header comment pins the optical-frame convention: origin at the optical centre, +x right, +y down, +z into the image, and _"If the frame_id here and the frame_id of the CameraInfo message associated with the image conflict the behavior is undefined"_ ([`Image.msg`][img-msg-header]). Intrinsics live in a separate `sensor_msgs/msg/CameraInfo` (distortion model and coefficients `d`, the 3x3 `k`, rectification `r`, the 3x4 projection `p`, `binning_x`/`binning_y`, `roi`) published on a sibling topic with the same stamp ([`CameraInfo.msg`][caminfo-msg]).

The layout model is one interleaved [plane][c-plane] with one [stride][c-stride] (`step`) and a byte-order flag. Nothing in the message names a colour space, a transfer function, alpha association, range, or an [ICC profile][c-icc]/[CICP][c-cicp] tag.

### The encoding vocabulary

The legal `encoding` values are string constants in `sensor_msgs/image_encodings.hpp` ([`image_encodings.hpp`][enc-consts]). Five families:

| Family       | Strings                                                                         | Meaning carried by the string                          |
| ------------ | ------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Named colour | `rgb8`, `rgba8`, `rgb16`, `rgba16`, `bgr8`, `bgra8`, `bgr16`, `bgra16`          | channel order and per-channel depth                    |
| Mono         | `mono8`, `mono16`                                                               | one luminance-like channel                             |
| OpenCV types | `8UC1` … `64FC4` (`8U`, `8S`, `16U`, `16S`, `32S`, `32F`, `64F`), `C1`–`C4`     | element type and channel count, no semantics           |
| Bayer        | `bayer_rggb8`, `bayer_bggr8`, `bayer_gbrg8`, `bayer_grbg8`, and `…16`           | raw sensor mosaic, one sample per site                 |
| YUV          | `uyvy`, `yuyv` (and deprecated `yuv422`, `yuv422_yuy2`), `nv12`, `nv21`, `nv24` | V4L2 FourCC layouts ([`image_encodings.hpp`][enc-yuv]) |

Helpers inspect a string: `isColor`, `isMono`, `isBayer`, `hasAlpha`, `isPlanar`, `numChannels`, `bitDepth`, `getHeightScaling`. The OpenCV family is parsed with a regex, so any channel count is accepted (excerpt of lines 119 and 194-197, [`image_encodings.hpp`][enc-num]):

```cpp
const std::regex cv_type_regex("(8|16|32|64)(U|S|F)C([0-9]*)");
// ex. 8UC -> 1, 8UC5 -> 5
if (std::regex_match(encoding.c_str(), m, cv_type_regex)) {
  return (m[3] == "") ? 1 : std::atoi(m[3].str().c_str());
}
```

Semi-planar 4:2:0 is bolted onto the one-plane model: `nv12` reports one channel and a height scale of 1.5 ([`getHeightScaling`][enc-scale]), so its byte size is `step * height * 1.5`, not the `step * rows` the message comment promises.

### Transport plugins

Plugins are `pluginlib` classes registered in a manifest; the built-in one is `raw` ([`default_plugins.xml`][it-plugins]). `Publisher` loads every declared `*_pub` class, filters by the per-topic parameter `<topic>.enable_pub_plugins`, and calls `advertise` on each ([`publisher.cpp`][it-pub-load]). A plugin's topic defaults to `base_topic + "/" + getTransportName()` ([`simple_publisher_plugin.hpp`][it-simple-topic]). Publishing fans out only to plugins that currently have subscribers ([`publisher.cpp`][it-pub-publish]):

```cpp
for (const auto & pub : impl_->publishers_) {
  if (pub->getNumSubscribers() > 0) {
    pub->publish(message);
  }
}
```

`PublisherPlugin` offers four entry points: `publish(const Image &)`, `publishPtr(ConstSharedPtr)`, `publishUniquePtr(UniquePtr)` gated by `supportsUniquePtrPub()`, and `publishData(message, const uint8_t * data)` _"to avoid useless copies"_ of filling a message first ([`publisher_plugin.hpp`][it-plugin-api]). For a `UniquePtr` publish, the first plugin that supports ownership gets the message; all others get a reference first ([`publisher.cpp`][it-pub-unique]).

The `compressed` plugin (in `image_transport_plugins`) publishes `sensor_msgs/msg/CompressedImage`, whose only descriptive field is a `format` string ([`CompressedImage.msg`][cimg-msg]). The publisher writes the source `encoding`, then `"; jpeg compressed bgr8"` or the PNG/TIFF equivalent; colour images are converted to BGR before encoding through OpenCV `imencode` ([`compressed_publisher.cpp`][cpub-format]). The subscriber `imdecode`s the bytes, then takes the encoding text before `;` as the output encoding and swaps channels back ([`compressed_subscriber.cpp`][csub]).

The `theora` plugin streams `theora_image_transport/msg/Packet`, an adaptation of libogg's `ogg_packet` (its `packet` and `bytes` merged into one `data` array) with the original image header ([`Packet.msg`][theora-packet]). The encoder is 4:2:0 (`TH_PF_420`), frames are padded to multiples of 16, and the encoding context is recreated when the image size changes ([`theora_publisher.cpp`][theora-ctx]). Header packets are published once, when the context is created; the subscriber drops packets until it has the headers and a keyframe ([`theora_subscriber.cpp`][theora-sub]).

`CameraPublisher` pairs an `Image` with its `CameraInfo` and stamps both with the same time ([`camera_publisher.cpp`][it-campub]); `CameraSubscriber` re-pairs them with a `message_filters::TimeSynchronizer` ([`camera_subscriber.cpp`][it-camsub]); the info topic is the image topic's sibling `camera_info` ([`camera_common.cpp`][it-caminfo-topic]).

### `cv_bridge`: views and copies

`CvImage` is `header`, `encoding` and `cv::Mat image`, plus a protected `std::shared_ptr<void const> tracked_object_` _"for sharing ownership"_ ([`cv_bridge.hpp`][cvb-cvimage]). `toCvShare` keeps the source message alive through that pointer and wraps its bytes ([`cv_bridge.cpp`][cvb-share]):

```cpp
// If the encoding different or the endianness different, you have to copy
if ((!encoding.empty() && source.encoding != encoding) || (!source.is_bigendian !=
  (rcpputils::endian::native != rcpputils::endian::big)))
{
  return toCvCopy(source, encoding);
}
ptr->tracked_object_ = tracked_object;
ptr->image = matFromImage(source);
```

`matFromImage` maps the encoding to an OpenCV type (`getCvType`, [`cv_bridge.cpp`][cvb-cvtype]), checks the size, and builds a `cv::Mat` header over `&source.data[0]` with `source.step` as the stride; for a foreign byte order it reinterprets the row as bytes and swaps them with `cv::mixChannels` ([`cv_bridge.cpp`][cvb-matfrom]). `toCvCopy` with a different target encoding chains `cv::cvtColor` codes (Bayer demosaic, YUV 4:2:2 unpack, RGB/BGR swaps) and scales 8-to-16-bit by `65535/255` ([`cv_bridge.cpp`][cvb-copyimpl]). `toImageMsg` always copies, row by row when the `Mat` is not continuous, and always writes native byte order ([`cv_bridge.cpp`][cvb-toimg]).

ROS 2 adds type adaptation ([REP 2007][rep2007]): `cv_bridge::ROSCvMatContainer` is registered as `rclcpp::TypeAdapter<ROSCvMatContainer, sensor_msgs::msg::Image>` so intra-process subscribers receive a `cv::Mat` without serialisation ([`cv_mat_sensor_msgs_image_type_adapter.hpp`][cvb-adapter]). Its storage is a `std::variant` of `nullptr`, `unique_ptr<Image>` and `shared_ptr<Image>`, and the header warns callers to `clone()` before letting the container go ([`…type_adapter.hpp`][cvb-adapter-doc]).

## Analysis

### 1. Pixel and memory model

The wire model is exactly a 2-D strided interleaved image: `height`, `width`, `step`, a byte vector, and an element type folded into `encoding`. It has no offset, no per-plane stride, no N-D extent and no [tiling][c-tiling]. That suffices for every named, Bayer and OpenCV encoding, and fails for semi-planar YUV, which the vocabulary patches with `getHeightScaling` while the message comment still says `step * rows`. `cv_bridge` itself has no branch for `nv12`, `nv21`, `nv24`, `uyvy` or `yuyv`: `getCvType` recognises only the deprecated `yuv422` and `yuv422_yuy2` names, so the newer strings throw `"Unrecognized image encoding"` ([`cv_bridge.cpp`][cvb-cvtype]). The in-memory side is `cv::Mat` ([OpenCV deep-dive][opencv]), so a share is a `Mat` header over message bytes with the message's stride.

Demonstrated (scratch program in `/tmp/ros-image-demo/demo.cpp`, compiled against `image_encodings.hpp` at the pinned revision with GCC from nix):

```text
8UC0         channels=0 bitDepth=8 heightScale=1.0 color=0
8UC10        channels=10 bitDepth=8 heightScale=1.0 color=0
nv12         channels=1 bitDepth=8 heightScale=1.5 color=1
nv24         channels=2 bitDepth=8 heightScale=1.0 color=1
srgb8: Unknown encoding srgb8
4x4 nv12, step 4, 24 bytes:     rejected: size
```

A correctly sized 4x4 NV12 frame would also fail the `height * step == size` rule `cv_bridge` applies to every encoding (in `cv_bridge` itself, `getCvType` throws on `nv12` before that check is reached), and the regex admits zero channels.

### 2. Genericity mechanism

Three mechanisms meet. The pixel type is a runtime string, dispatched by `==` chains and a regex. Transports are runtime `pluginlib` classes behind virtual `PublisherPlugin`/`SubscriberPlugin` interfaces, with `SimplePublisherPlugin<M>` templated on the transport's message type. Type adaptation is a C++ template specialisation (`rclcpp::TypeAdapter<Custom, Ros>` with `convert_to_ros_message`/`convert_to_custom`), so a node can publish its native type and pay conversion only on the inter-process path. The string vocabulary is open (extending it is an email to a mailing list, per [`Image.msg`][img-msg-enc]) but every consumer re-implements the dispatch, and they drift: the type adapter maps `mono16` to `CV_16SC1` and back, so a `CV_16UC1` matrix (what `mono16` means in `cv_bridge`) throws `"unsupported encoding type"`, and it names `CV_8UC3` `bgr8` but `CV_8UC4` `rgba8` ([`…type_adapter.cpp`][cvb-adapter-enc], [`…type_adapter.hpp`][cvb-adapter-fill]).

### 3. Colour and metadata

What robotics adds is temporal and spatial metadata: an acquisition `stamp`, a `frame_id` naming the camera's optical frame in the transform tree, and the calibrated projection in `CameraInfo`. What it omits is colour: `rgb8` does not say sRGB, linear or camera-native; there is no [CICP][c-cicp], [ICC][c-icc], range or alpha association. The `compressed` transport discards anything the codec might have carried, since its only metadata is the `format` string ([`CompressedImage.msg`][cimg-msg]). See [image metadata][c-meta] for what stills formats carry instead.

### 4. I/O and codec architecture

Codecs sit outside the image type as transport plugins, chosen per subscriber and run only when someone subscribes. `compressed` is stateless, one OpenCV `imencode`/`imdecode` per frame (the codecs themselves are [libjpeg-turbo][ljt], [libpng][libpng] and [libtiff][libtiff] behind OpenCV). `theora` is stateful: headers, keyframes, and a decoder context that must see the header packets first. The [container and bitstream][c-container] split is improvised in the `format` string grammar `ORIG_PIXFMT; CODEC compressed [COMPRESSED_PIXFMT]`, and the subscriber falls back to `bgr8`/`mono8` when the string lacks a `;` ([`compressed_subscriber.cpp`][csub]). `stream_header_` is stored by the theora publisher, but at this revision it is published only when the encoder context is created, so a subscriber that joins later waits for the next context rebuild ([`theora_publisher.cpp`][theora-ctx]); the ROS 1 `connectCallback` that would send headers to new clients is commented out under a TODO ([`theora_publisher.hpp`][theora-todo]).

### 5. Hostile input and safety

Every message is input from another process or host. The checks are thin:

- `matFromImage` validates with 32-bit arithmetic: `source.height * source.step` is a `uint32_t` product compared with `data.size()` ([`cv_bridge.cpp`][cvb-matfrom]). Demonstrated with the same field types in `/tmp/ros-image-demo/demo.cpp`: a `mono16` frame with `height` 65536, `width` 32768 and `step` 65536 and an empty `data` passes both checks (`height*step = 0`). `cv_bridge` would then build a `cv::Mat` over `&source.data[0]` of an empty vector; this consequence is read, not run.
- `ROSCvMatContainer`'s constructors wrap `data.data()` with the message's `height`, `width` and `step` and perform no size check at all ([`…type_adapter.cpp`][cvb-adapter-ctor]).
- The `compressed` subscriber trusts the sender's `format`: the decoded `Mat` keeps whatever channels and depth the codec produced, while `encoding` is set from the string ([`compressed_subscriber.cpp`][csub]). No pixel limit is set by the transport; it inherits OpenCV's ([OpenCV, hostile input][opencv-5]).
- `numChannels` and `bitDepth` throw `std::runtime_error` on unknown strings, so an unexpected `encoding` becomes an exception in the subscriber callback.

See [hostile input][c-hostile].

### 6. Allocation and ownership

Ownership is `shared_ptr` throughout. `toCvShare` stores the message (or any containing object) in `tracked_object_`, the same keep-alive-by-deleter pattern as [DLPack][dlpack]'s managed tensor. Intra-process ROS 2 moves `unique_ptr<Image>` through the graph, which is why `Publisher::publish(UniquePtr)` hands ownership to at most one plugin (the first subscribed one that supports it) and passes the others a const reference before the move ([`publisher.cpp`][it-pub-unique]). The message itself owns its bytes as `std::vector<uint8_t>`, so a camera driver that has the frame in its own buffer must copy once into the message, or use `publishData` (which copies inside the default implementation, [`publisher_plugin.hpp`][it-plugin-api]).

### 7. CPU parallelism and SIMD

Not applicable to these packages, because they contain no threading or vector code of their own: every pixel operation (`cvtColor`, `mixChannels`, `convertTo`, `imencode`/`imdecode`) is an OpenCV call and inherits OpenCV's dispatch and thread pool ([OpenCV, CPU parallelism][opencv-7]). `Publisher::publish` runs the subscribed plugins one after another in the caller's thread ([`publisher.cpp`][it-pub-publish]); concurrency comes from the ROS executor, not from the image stack.

### 8. GPU offload and interop

Not applicable, because neither `image_transport` nor the `cv_bridge` C++ library has a GPU path at the pinned revisions: a search of their `src` and `include` trees finds no CUDA, OpenCL or `cv::UMat` use (the only `UMatData` hits are the NumPy allocator of the Python binding, `module_opencv4.cpp`). Frames travel as host byte vectors, and a GPU consumer uploads after `toCvShare`.

### 9. Temporal, animation and containers

The image type is a stream element: each frame carries its own `stamp`, and the pairing of image and calibration is by exact timestamp. `theora` shows what an inter-frame codec costs a pub/sub system: per-subscriber state, header replay, keyframe waits and a context reset on resolution change. There is no notion of a sequence container, frame duration or animation; time is the header stamp and nothing else.

### 10. Testing and conformance

`image_transport` tests exercise plumbing (remapping, QoS overrides, lifecycle nodes, single-subscriber publishers) rather than pixels ([`test/`][it-tests]). `cv_bridge`'s endianness test builds a 1x1 big-endian `32SC2` frame, calls `toCvShare` and reads `at<cv::Vec2i>` ([`test_endian.cpp`][cvb-test-endian]). The swap branch of `matFromImage` ends with `mat_swap.reshape(num_channels);`, discarding the returned header, so it returns an 8-bit, 8-channel matrix. Demonstrated with OpenCV 4.12.0 from nix (`/tmp/ros-image-demo/reshape.cpp`, the branch transcribed): the result is `depth=0 channels=8 elemSize=8`; with `-DNDEBUG`, `at<cv::Vec2i>` reads `1 2` because the element sizes match, and without it OpenCV's `at` debug assertion throws a `cv::Exception` (uncaught, it aborts the scratch program; under gtest the test would fail). The test therefore passes for a reason other than the one it checks, depending on build type.

## Lessons for Sparkles

- **Q1** The six-field frame (extent, stride, element encoding, byte order, bytes, header) is the smallest descriptor that lets an unknown receiver interpret a 2-D image. It does not stretch to semi-planar or planar data without a plane list; ROS's `getHeightScaling` patch is the cautionary version of that gap. An in-memory view and a wire descriptor can stay separate types.
- **Q2** An open string vocabulary lets anyone add an encoding but makes every consumer re-implement dispatch, and the dispatches drift (`mono16` as signed in the type adapter, unsigned in `cv_bridge`). A closed D enum whose member names are the wire strings would keep one source of truth; whether the set should be closed is a design question this survey leaves open.
- **Q4** Codec choice as a per-consumer transport, run only when someone subscribes, is a clean separation of "what the image is" from "how it travels". The `format` string grammar shows the cost of not having a binary description: `sparkles:wired` could describe both `Image` and `CompressedImage` as a test of what it must express (strings, variable-length byte arrays, nested header).
- **Q5** Robotics' minimum metadata is time and place (`stamp`, `frame_id`, a calibration on a sibling channel), not colour. The ROS model shows what is lost without colour tags: `rgb8` is ambiguous across cameras. A Sparkles minimum model has to decide whether capture time and spatial frame are image metadata or a separate envelope.
- **Q6** `toCvShare`'s keep-alive pointer and REP 2007 type adaptation are the zero-copy story for a message bus: borrow while the owner lives, move ownership intra-process. `sparkles:base`'s `SharedBuffer`/`UniqueBuffer` split maps onto the `shared_ptr`/`unique_ptr` storage variant; the ROS API makes "may or may not own" a documented hazard.
- **Q8** Two latent defects found here (32-bit size validation, a discarded `reshape`) survived because tests check values through accessors that do not check type. Oracles for a Sparkles image type should assert the descriptor (depth, channels, stride) as well as sample values, and size arithmetic belongs in checked 64-bit operations at the boundary.
- **Q9** Evidence for a three-way split: the message vocabulary (`sensor_msgs`), the transport/codec plugins (`image_transport` and its plugins) and the library bridge (`cv_bridge`) live in separate repositories and release independently. The bridge is where the type mismatches accumulate.

## Strengths

- A frame describes itself completely on the wire, including byte order, and carries capture time and coordinate frame.
- Transport is invisible to application code and negotiated per subscriber; unused encoders never run.
- `toCvShare` gives zero-copy read access with lifetime tied to the message.
- Type adaptation removes serialisation for intra-process pipelines without changing the topic type.
- Calibration is a first-class sibling message, time-synchronised with the frame.

## Weaknesses

- No colour space, transfer function, range or alpha association anywhere in the message.
- One stride and one plane; semi-planar YUV is a scaling hack the bridge does not implement.
- The encoding is a free string, parsed by regex and `==` chains, with throwing helpers and inconsistent mappings across packages.
- Validation uses 32-bit arithmetic in `cv_bridge` and is absent in the type adapter; the `compressed` subscriber trusts the sender's `format`.
- The theora transport does not replay stream headers to late subscribers at this revision.
- Tests do not assert the matrix type the bridge returns.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                        | Trade-off                                                                       |
| ------------------------------------------------ | ---------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| One interleaved plane, one `step`, a byte vector | The smallest self-describing frame any node can parse            | Semi-planar YUV needs `getHeightScaling`; no planes, offsets or tiling          |
| Encoding as an open string                       | Anyone can add a format without changing the message type        | Every consumer re-implements dispatch, and `cv_bridge` and the adapter disagree |
| Codecs as per-subscriber transport plugins       | Application code is unchanged; encoders run only when subscribed | Codec metadata collapses into the `format` string; stateful codecs need replay  |
| `toCvShare` keeps the message alive              | Zero-copy read access with a lifetime tied to the message        | An encoding or byte-order change silently becomes a copy                        |
| Type adaptation (REP 2007)                       | Intra-process pipelines skip serialisation                       | Ownership is "may or may not own", documented as a hazard                       |

## Sources

- `sensor_msgs` message definitions and encodings: [`Image.msg`][img-msg], [`CompressedImage.msg`][cimg-msg], [`CameraInfo.msg`][caminfo-msg], [`Header.msg`][header-msg], [`image_encodings.hpp`][enc].
- `image_transport`: [`overview.rst`][it-overview], [`default_plugins.xml`][it-plugins], [`publisher_plugin.hpp`][it-plugin-api], [`publisher.cpp`][it-pub-load], [`simple_publisher_plugin.hpp`][it-simple-topic], [`camera_publisher.cpp`][it-campub], [`camera_subscriber.cpp`][it-camsub], [`camera_common.cpp`][it-caminfo-topic].
- `image_transport_plugins`: [`compressed_publisher.cpp`][cpub-format], [`compressed_subscriber.cpp`][csub], [`Packet.msg`][theora-packet], [`theora_publisher.cpp`][theora-ctx], [`theora_subscriber.cpp`][theora-sub].
- `cv_bridge`: [`cv_bridge.hpp`][cvb-cvimage], [`cv_bridge.cpp`][cvb-matfrom], [`cv_mat_sensor_msgs_image_type_adapter.hpp`][cvb-adapter], [`cv_mat_sensor_msgs_image_type_adapter.cpp`][cvb-adapter-enc], [`test_endian.cpp`][cvb-test-endian].
- [REP 2007: Type Adaptation Feature][rep2007].
- Related deep-dives: [OpenCV][opencv], [DLPack][dlpack], [NumPy buffer protocol][numpy]; shared terms in [concepts][c-stride]; Sparkles baseline in [existing code][bl-existing].

<!-- References -->

[it-repo]: https://github.com/ros-perception/image_common/tree/faf0db265fa97d15631d343f79d64d86c423ee8f
[cvb-repo]: https://github.com/ros-perception/vision_opencv/tree/50f6f1feccc65dd2ef87f863cb812a8aa0789062
[ci-repo]: https://github.com/ros2/common_interfaces/tree/05a5c4e6a42f89b71745320c34c467cb391a94b9
[itp-repo]: https://github.com/ros-perception/image_transport_plugins/tree/8deb0498fd1bb611738dc47f026a1f6eedd13011
[it-pkg]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/package.xml#L18
[cvb-pkg]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/package.xml#L9-L10
[it-overview]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/doc/overview.rst#L1-L40
[it-plugins]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/default_plugins.xml#L1-L21
[it-plugin-api]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/include/image_transport/publisher_plugin.hpp#L89-L166
[it-pub-load]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/src/publisher.cpp#L119-L164
[it-pub-publish]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/src/publisher.cpp#L178-L191
[it-pub-unique]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/src/publisher.cpp#L208-L236
[it-simple-topic]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/include/image_transport/simple_publisher_plugin.hpp#L168-L176
[it-campub]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/src/camera_publisher.cpp#L178-L212
[it-camsub]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/src/camera_subscriber.cpp#L66
[it-caminfo-topic]: https://github.com/ros-perception/image_common/blob/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/src/camera_common.cpp#L70-L84
[it-tests]: https://github.com/ros-perception/image_common/tree/faf0db265fa97d15631d343f79d64d86c423ee8f/image_transport/test
[img-msg]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/msg/Image.msg#L1-L26
[img-msg-header]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/msg/Image.msg#L4-L12
[img-msg-enc]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/msg/Image.msg#L17-L22
[cimg-msg]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/msg/CompressedImage.msg#L1-L41
[caminfo-msg]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/msg/CameraInfo.msg#L30-L131
[header-msg]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/std_msgs/msg/Header.msg#L1-L9
[enc]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/include/sensor_msgs/image_encodings.hpp
[enc-consts]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/include/sensor_msgs/image_encodings.hpp#L44-L93
[enc-yuv]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/include/sensor_msgs/image_encodings.hpp#L95-L112
[enc-num]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/include/sensor_msgs/image_encodings.hpp#L119-L215
[enc-scale]: https://github.com/ros2/common_interfaces/blob/05a5c4e6a42f89b71745320c34c467cb391a94b9/sensor_msgs/include/sensor_msgs/image_encodings.hpp#L270-L280
[cpub-format]: https://github.com/ros-perception/image_transport_plugins/blob/8deb0498fd1bb611738dc47f026a1f6eedd13011/compressed_image_transport/src/compressed_publisher.cpp#L184-L230
[csub]: https://github.com/ros-perception/image_transport_plugins/blob/8deb0498fd1bb611738dc47f026a1f6eedd13011/compressed_image_transport/src/compressed_subscriber.cpp#L95-L182
[theora-packet]: https://github.com/ros-perception/image_transport_plugins/blob/8deb0498fd1bb611738dc47f026a1f6eedd13011/theora_image_transport/msg/Packet.msg#L1-L9
[theora-ctx]: https://github.com/ros-perception/image_transport_plugins/blob/8deb0498fd1bb611738dc47f026a1f6eedd13011/theora_image_transport/src/theora_publisher.cpp#L359-L403
[theora-todo]: https://github.com/ros-perception/image_transport_plugins/blob/8deb0498fd1bb611738dc47f026a1f6eedd13011/theora_image_transport/include/theora_image_transport/theora_publisher.hpp#L71-L72
[theora-sub]: https://github.com/ros-perception/image_transport_plugins/blob/8deb0498fd1bb611738dc47f026a1f6eedd13011/theora_image_transport/src/theora_subscriber.cpp#L200-L242
[cvb-cvimage]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/include/cv_bridge/cv_bridge.hpp#L85-L158
[cvb-share-doc]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/include/cv_bridge/cv_bridge.hpp#L212-L263
[cvb-cvtype]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_bridge.cpp#L75-L119
[cvb-matfrom]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_bridge.cpp#L276-L328
[cvb-copyimpl]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_bridge.cpp#L330-L378
[cvb-toimg]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_bridge.cpp#L389-L412
[cvb-share]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_bridge.cpp#L438-L456
[cvb-adapter]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/include/cv_bridge/cv_mat_sensor_msgs_image_type_adapter.hpp#L269-L290
[cvb-adapter-doc]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/include/cv_bridge/cv_mat_sensor_msgs_image_type_adapter.hpp#L53-L95
[cvb-adapter-fill]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/include/cv_bridge/cv_mat_sensor_msgs_image_type_adapter.hpp#L232-L267
[cvb-adapter-enc]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_mat_sensor_msgs_image_type_adapter.cpp#L33-L55
[cvb-adapter-ctor]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/src/cv_mat_sensor_msgs_image_type_adapter.cpp#L73-L98
[cvb-test-endian]: https://github.com/ros-perception/vision_opencv/blob/50f6f1feccc65dd2ef87f863cb812a8aa0789062/cv_bridge/test/test_endian.cpp#L6-L38
[rep2007]: https://ros.org/reps/rep-2007.html
[opencv]: ./opencv.md
[opencv-5]: ./opencv.md#_5-hostile-input-and-safety
[opencv-7]: ./opencv.md#_7-cpu-parallelism-and-simd
[dlpack]: ./dlpack.md
[numpy]: ./numpy-buffer-protocol.md
[ljt]: ./libjpeg-turbo.md
[libpng]: ./libpng.md
[libtiff]: ./libtiff.md
[c-plane]: ./concepts.md#plane
[c-stride]: ./concepts.md#stride
[c-tiling]: ./concepts.md#tiling
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-meta]: ./concepts.md#image-metadata
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[bl-existing]: ./baseline/existing-code.md
