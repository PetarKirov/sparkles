module sample;
// ---cut---
/// Byte-size units, each computed from the one above it.
enum ByteSize : size_t
{
    KB = 1 << 10,   /// One kibibyte.
    MB = KB * 1024, /// One mebibyte.
    GB = MB * 1024, /// One gibibyte.
}

enum bufferSize = 4 * ByteSize.MB;
//   ^?
//                             ^?
