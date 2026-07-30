module sample;
// ---cut---
/++
Copies src over dst — D's answer to `memcpy`.

Examples:
---
auto dst = new ubyte[4];
copyInto(dst, [1, 2, 3, 4]);
---

```c
void *memcpy(void *dst, const void *src, size_t n); /* returns dst */
```
+/
void copyInto(ubyte[] dst, const(ubyte)[] src) { dst[] = src[]; }
//   ^?
