# Boot-adjacent hybrids (firmware, bootloaders, and the formats they parse)

Superposition where the second reader is not a shell or a language runtime but _firmware_: an ISO 9660 image that is simultaneously an MBR/GPT-partitioned disk, a PE/COFF executable that is simultaneously a Linux kernel plus its initrd and command line, an `x86` `bzImage` that is simultaneously a DOS executable, a BIOS boot sector and a UEFI application, and a Multiboot2 header found by scanning the first 32 KiB of whatever the loader was handed.

| Field           | Value                                                                                                                                                                           |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Format family + the tools that produce it (`isohybrid`, `ukify`) + the loaders that consume it (UEFI firmware, `systemd-stub`, GRUB)                                            |
| Language        | C (`isohybrid`, `systemd-stub`, GRUB), Python (`ukify`), assembly (`isohdpfx.S`, `arch/*/boot`)                                                                                 |
| License         | GPL-2.0 (`syslinux`, GRUB, Linux), LGPL-2.1-or-later (systemd), CC-BY-4.0 (the UKI specification)                                                                               |
| Repository      | [systemd/systemd][systemd-repo] · [uapi-group/specifications][uapi-repo] · [`syslinux`][syslinux-repo] · [rhboot/grub2][grub-repo]                                              |
| Documentation   | [UAPI.5 Unified Kernel Images][uki-spec] · [ECMA-119 (ISO 9660)][ecma119] · [Multiboot2 specification][mb2-spec] · [PE format][pe-format]                                       |
| First release   | ECMA-119 issued December 1986 (ISO 9660 followed by fast-track) · El Torito 1.0: 1995 · `isohybrid` C rewrite: 2010 · `ukify`: systemd 253, 2023-02-15 · Multiboot2: GRUB 2 era |
| Axis profile    | Multiplicity 3 / Reflexivity 1 / Closure 2 / Mutability 0                                                                                                                       |
| Index anchoring | Header-anchored **with a standardized hole** (ISO 9660, PE) and stream-scanned (Multiboot2, within a bounded prefix)                                                            |
| Dispatch owner  | Firmware — BIOS/El Torito/UEFI — then the bootloader or embedded stub; never the kernel, never a shell                                                                          |

> **Revisions surveyed:** systemd `9bb06d5` (2026-08-26), UAPI specifications `1375569`, `syslinux` `5e42653` (2018-10-25, the tip of the surveyed mirror), `rhboot/grub2` `504c9b7`, Linux `e43ffb6`. **Platform:** `x86`/`x86_64` BIOS + UEFI, `aarch64` UEFI. Byte-level measurements in this page were taken on NixOS against `linux-6.18.26`'s `bzImage` (13 222 400 bytes).

---

## Overview

### What it solves

Firmware is the least negotiable consumer in computing. You cannot ask a 2009 BIOS to learn a new container, you cannot patch the UEFI implementation in a laptop you are shipping software to, and in a Confidential Computing guest there may be no bootloader at all between the firmware and your kernel. Every problem in this cluster therefore has the same shape: **a fixed set of parsers already exists, and the artifact must satisfy several of them at once** — because you do not get to choose which one will pick your file up.

Four concrete instances:

| Problem                                                                                    | Artifact                   | Simultaneous parses                                                                                        |
| ------------------------------------------------------------------------------------------ | -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| One download must boot from an optical drive _and_ from a USB stick, on BIOS _and_ on UEFI | `isohybrid`-processed ISO  | ISO 9660 filesystem + MBR partitioned disk + GPT partitioned disk + El Torito catalog + FAT ESP            |
| Kernel, initrd and command line must be updated, signed and measured as **one** unit       | Unified Kernel Image (UKI) | PE/COFF UEFI application + an archive of named blobs (`.linux`, `.initrd`, `.cmdline`, `.osrel`, `.uname`) |
| One kernel image must boot via legacy BIOS, via the EFI stub, and via a modern loader      | `x86` `bzImage`            | MZ/PE32+ executable + BIOS boot sector + Linux boot-protocol image                                         |
| A hobby kernel must be loadable without the loader knowing its executable format           | Multiboot2 image           | ELF (or anything) + a tag stream discovered by scanning                                                    |

The UKI is the case worth dwelling on, because it is this catalog's cleanest instance of **"the container is a tax" being paid deliberately and with eyes open**. Nothing about a kernel, an initrd and a command line requires PE/COFF. PE is chosen because UEFI's `LoadImage()` parses PE, Secure Boot signs PE, and `shim` verifies PE — so an artifact that wants to be authenticated by machinery it does not control must _become_ the format that machinery already reads. The tax buys a signature that covers the whole bundle at once. See [Closure, dedup, and size model](#closure-dedup-and-size-model) for what it costs, and [the ZIP-parasitism page][zip] for the same trade made against a different incumbent parser.

### Design philosophy

ISO 9660 is the load-bearing case, and its philosophy is stated twice in [ECMA-119][ecma119] — once as a permission and once as an _obligation_. §6.2.1:

> _"The Volume Space shall be divided into a System Area and a Data Area. The System Area shall occupy the Logical Sectors with Logical Sector Numbers 0 to 15. The System Area shall be reserved for system use. Its content is not specified by this Standard."_

and §12.4, in the requirements on a _producing_ implementation:

> _"The implementation shall allow the data preparer to supply the information that is to be recorded on the Logical Sectors with Logical Sector Numbers 0 to 15."_

That second sentence is the one that matters, and it is the single most important fact on this page. The 32 KiB hole at the front of an ISO is not an accident of layout that polyglot authors discovered and exploited; it is a reserved region that conforming _writers are required to expose as an API_. ISO 9660 is header-anchored — its volume descriptors begin at a fixed Logical Sector Number 16 — and it is nevertheless prefix-parasitic, because the standard mandated the hole. Compare the ZIP central directory, which is suffix-parasitic because it is footer-anchored and reached by a backwards scan ([footer-indexed formats][footer]): **anchoring predicts composability only in the absence of a reserved hole. A reserved hole is worth as much as a footer anchor, and it is worth more when it is required rather than merely tolerated.**

The UKI's philosophy is stated in the [UAPI.5 specification][uki-spec], and it is a philosophy of _deliberate_ container tax:

> _"UKIs wrap all of the above data in a single file, hence all of the above components can be updated in one go through single file atomic updates, which is useful given that the primary expected storage place for these UKIs is the UEFI System Partition (ESP), which is a vFAT file system, with its limited data safety guarantees."_

and, on why PE specifically:

> _"Given UKIs are regular UEFI PE files, they can thus be signed as one for Secure Boot, protecting all of the individual resources listed above at once, and their combination."_

The phrase _"and their combination"_ is the whole argument. A separately-signed kernel and a separately-signed initrd do not authenticate the pairing; one signature over one PE does.

The `syslinux` side of the family is refreshingly candid that a hybrid is a _forgery_ aimed at a specific reader. From [`mbr/isohdpfx.S`][isohdpfx], the boot code `isohybrid` stamps into the ISO's System Area:

> _"Modified MBR code used on an ISO image in hybrid mode. This doesn't follow the El Torito spec at all -- it is just a stub loader of a hard-coded offset, but that's good enough to load ISOLINUX."_

---

## How it works

### `isohybrid`: writing a disk into a filesystem's reserved hole

[`isohybrid`][isohybrid] is a post-processor. It takes an ISO produced by `mkisofs`/`genisoimage`/`xorriso` and rewrites bytes _only inside regions ISO 9660 does not claim_. Reading [`utils/isohybrid.c`][isohybrid] top to bottom, the sequence is:

1. **Read the Primary Volume Descriptor** at `16 << 11` = byte 32768, to learn the volume size (`descriptor.size * descriptor.block_size`).
2. **Read the Boot Record volume descriptor** at `17 * 2048` and match a 71-byte banner:

   ```c
   /* syslinux utils/isohybrid.c — check_banner() */
   static const char banner[] = "\0CD001\1EL TORITO SPECIFICATION\0\0\0\0" …;
   if (!buf || memcmp(buf, banner, sizeof(banner) - 1))
       return 1;
   buf += sizeof(banner) - 1;
   memcpy(&catoffset, buf, sizeof(catoffset));
   ```

   The banner is exactly ECMA-119 §8.2's Boot Record layout: Volume Descriptor Type `0` (BP 1), Standard Identifier `CD001` (BP 2–6), Version `1` (BP 7), Boot System Identifier `EL TORITO SPECIFICATION` (BP 8–39), Boot Identifier, all zero (BP 40–71). The 32-bit boot-catalog LBA is then read at BP 72 — the first byte of ECMA-119's _second_ reserved hole, `Boot System Use (BP 72 to 2048)`, of which the standard says only _"This field shall be reserved for boot system use. Its content is not specified by this Standard."_

3. **Walk the El Torito boot catalog** at `catoffset * 2048`: validate the validation entry (`ve[0] == 0x0001`, `ve[15] == 0xAA55`, and the 16-bit sum of the whole 32-byte entry ≡ 0), then read the default entry (`de_boot == 0x88`, `de_media == 0`, `de_count == 4`) to obtain `de_lba`, and optionally a section header whose `platform_id == 0xEF` followed by an EFI entry giving `efi_lba`/`efi_count`.
4. **Confirm the boot image is `isolinux.bin`** by checking a four-byte magic at `de_lba * 2048 + 0x40`: `memcmp(buf, "\xFB\xC0\x78\x70", 4)`. That constant is `HYBRID_MAGIC = 0x7078c0fb` from [`mbr/isohdpfx.S`][isohdpfx] — the MBR stub and the boot image agree on a private handshake the firmware knows nothing about.
5. **Write the forged disk metadata**, entirely within the 32 KiB System Area:

| Byte range | What `isohybrid` writes                                                            | Who reads it               |
| ---------- | ---------------------------------------------------------------------------------- | -------------------------- |
| 0–431      | `MBRSIZE` bytes of 16-bit boot code, copied from the built-in `isohdpfx` array     | BIOS, on a USB/HDD boot    |
| 432–435    | `de_lba * 4` — the El Torito boot image's LBA, restated in 512-byte units          | the `isohdpfx` stub itself |
| 440–443    | MBR disk signature (`id`, random if not otherwise set)                             | OS disk enumeration        |
| 446–509    | Four 16-byte MBR partition entries                                                 | BIOS/OS partition scanners |
| 510–511    | `0x55 0xAA`                                                                        | BIOS boot-sector validity  |
| 512–17407  | Primary GPT header (LBA 1) + 128×128-byte partition entries, when `--uefi` is used | UEFI firmware              |
| 2048–…     | Apple Partition Map, when `--mac` is used (`APM_OFFSET 2048`)                      | Apple firmware             |
| 32768+     | _untouched_ — the ISO 9660 volume descriptors and everything after                 | every ISO 9660 reader      |

Every one of these lands below byte 32768. A 512-byte MBR, a 16.5 KiB primary GPT and an APM coexist inside a hole reserved by a 1987 standard, and the ISO 9660 parse is bit-for-bit unaffected.

The partition entries are where the aliasing becomes explicit. From [`initialise_gpt()`][isohybrid]:

```c
/* syslinux utils/isohybrid.c — initialise_gpt() (abridged) */
part->firstLBA = lendian_64(0);
part->lastLBA  = lendian_64(psize - 1);          /* the ENTIRE ISO, incl. this table */
ascii_to_utf16le(part->name, "ISOHybrid ISO");
…
part++;
part->firstLBA = lendian_64(efi_lba * 4);        /* a FILE inside the ISO 9660 tree */
part->lastLBA  = lendian_64(part->firstLBA + efi_count - 1);
```

GPT partition 1 spans the whole image — a partition that contains its own partition table. GPT partition 2 spans the FAT-formatted EFI System Partition image, which is _a regular file inside the ISO 9660 directory tree_, pointed at by the El Torito EFI section entry. The same extent is simultaneously a file (to `mount -t iso9660`), a partition (to a UEFI firmware enumerating GPT on a USB stick) and an El Torito EFI boot image (to a UEFI firmware booting the same bytes off a DVD). No bytes are duplicated; three indexes name the same range.

### El Torito: an indirection chain in a reserved field

The chain is: Boot Record VD at Logical Sector 17 → boot catalog LBA at BP 72 → validation entry + default entry → boot-image LBA. Every link lives in space the base standard declined to specify. El Torito did not have to modify ISO 9660 to add bootability, and consequently a 1995 extension is parsed correctly by a 1987 reader — the reader skips a volume descriptor whose type it does not handle. This is the _third_ structural pattern on this page, distinct from a hole and distinct from aliasing: **an extension standard occupying a reserved field of a base standard**. It composes for the same underlying reason: the base standard specified what unknown bytes mean (nothing) rather than leaving it to implementations, which is exactly the property [the polyglot-craft page][polyglot] argues determines whether formats can be stacked.

### The UKI: PE sections as a general-purpose container

A UKI is a `systemd-stub` PE binary with extra sections appended. The section names are a closed, _ordered_ enumeration in [`src/fundamental/uki.h`][uki-h] / [`uki.c`][uki-c], and the ordering is load-bearing:

```c
/* systemd src/fundamental/uki.h */
/* List of PE sections that have special meaning for us in unified kernels. This is the canonical order in
 * which we measure the sections into TPM PCR 11. PLEASE DO NOT REORDER! */
typedef enum UnifiedSection {
        UNIFIED_SECTION_LINUX,
        UNIFIED_SECTION_OSREL,
        UNIFIED_SECTION_CMDLINE,
        UNIFIED_SECTION_INITRD,
        …
```

| Section    | Contents                                         | Required?                                      |
| ---------- | ------------------------------------------------ | ---------------------------------------------- |
| `.linux`   | the kernel image (itself a PE — see below)       | **yes** — the only mandatory section           |
| `.osrel`   | the target OS's `/etc/os-release`                | optional; menu presentation and ordering       |
| `.cmdline` | the kernel command line                          | optional; if absent, the loader may supply one |
| `.initrd`  | the initrd `cpio` archive                        | optional                                       |
| `.ucode`   | microcode `cpio`, prepended before other initrds | optional                                       |
| `.uname`   | `uname -r` of the embedded kernel                | optional                                       |
| `.sbat`    | SBAT revocation metadata (CSV)                   | optional                                       |
| `.pcrsig`  | signed expected PCR 11 values (JSON)             | optional; **not** measured itself              |
| `.pcrpkey` | the public key those signatures verify against   | optional                                       |
| `.profile` | multi-profile delimiter + `ID=`/`TITLE=`         | optional; may repeat                           |
| `.dtbauto` | per-hardware devicetree candidates               | optional; may repeat                           |
| `.efifw`   | per-hardware firmware blobs                      | optional; may repeat                           |

`ukify` builds this by rewriting the stub's PE headers. The mechanics in [`pe_add_sections()`][ukify] are worth reading closely because they are the concrete price of the container tax:

```python
# systemd src/ukify/ukify.py — pe_add_sections() (abridged)
pe.OPTIONAL_HEADER.SizeOfHeaders = round_up(
    pe.OPTIONAL_HEADER.SizeOfHeaders, pe.OPTIONAL_HEADER.FileAlignment)
…
offset = pe.sections[-1].get_file_offset() + new_section.sizeof()
if offset + new_section.sizeof() > pe.OPTIONAL_HEADER.SizeOfHeaders:
    raise PEError(f'Not enough header space to add section {section.name}.')
…
new_section.PointerToRawData = round_up(len(pe.__data__), pe.OPTIONAL_HEADER.FileAlignment)
new_section.SizeOfRawData    = round_up(len(data),        pe.OPTIONAL_HEADER.FileAlignment)
new_section.VirtualAddress   = round_up(pe.sections[-1].VirtualAddress + pe.sections[-1].Misc_VirtualSize,
                                        pe.OPTIONAL_HEADER.SectionAlignment)
```

Three consequences fall out of those six lines. **(1)** The section table is header-anchored and fixed-capacity: adding a section requires spare bytes inside `SizeOfHeaders`, and `ukify` pads it to `FileAlignment` precisely to manufacture room. A container whose directory lives at the front has a bounded number of entries; a container whose directory lives at the back does not. **(2)** Section names are capped at 8 bytes — `check_name()` rejects longer ones, with the comment in [`uki.c`][uki-c] noting that PE _object_ files can indirect through a string table but PE _executables_ cannot. **(3)** Data is appended at the end and both file and virtual offsets are re-derived, so a UKI is built by _append-then-fix-the-header_, the same shape as `zip -A` offset fixup in [ZIP parasitism][zip], but with the fixup mandatory rather than cosmetic.

The stub then reads its own section table at runtime. `systemd-stub` obtains `EFI_LOADED_IMAGE_PROTOCOL`, and [`pe_memory_locate_sections()`][pe-c] walks the in-memory section headers of the image it is _currently executing from_, filling a `PeSectionVector` per known name:

```c
/* systemd src/boot/pe.c — pe_locate_sections_internal() (abridged) */
sections[i] = (PeSectionVector) {
        .memory_size   = j->VirtualSize,
        .memory_offset = j->VirtualAddress,
        /* … the actual data read from disk is the minimum of these two fields. */
        .file_size     = MIN(j->SizeOfRawData, j->VirtualSize),
        .file_offset   = j->PointerToRawData,
};
/* First matching section wins, ignore the rest */
break;
```

The kernel in `.linux` is then handed to `BS->LoadImage()` from memory, and the initrd is exposed to it through the EFI initrd device path — so a UKI is a PE that loads a PE out of one of its own sections.

### Multiboot2: a header found by scanning

Multiboot goes the other way and gives up on anchoring entirely. From [the Multiboot2 specification][mb2-spec], §3.1:

> _"An OS image must contain an additional header called Multiboot2 header, besides the headers of the format used by the OS image. The Multiboot2 header must be contained completely within the first 32768 bytes of the OS image, and must be 64-bit aligned."_

GRUB implements exactly that, and nothing more. [`include/multiboot2.h`][mb2-h] declares `MULTIBOOT_SEARCH 32768`, `MULTIBOOT_HEADER_ALIGN 8` and `MULTIBOOT2_HEADER_MAGIC 0xe85250d6`; [`grub-core/loader/multiboot_mbi2.c`][mb2-c] reads that prefix into a buffer and brute-forces it:

```c
/* grub2 grub-core/loader/multiboot_mbi2.c — find_header() */
for (header = (struct multiboot_header *) buffer;
     ((char *) header <= (char *) buffer + len - 12);
     header = (struct multiboot_header *) ((grub_uint32_t *) header + MULTIBOOT_HEADER_ALIGN / 4))
  {
    if (header->magic == MULTIBOOT2_HEADER_MAGIC
        && !(header->magic + header->architecture
             + header->header_length + header->checksum)
        && header->architecture == MULTIBOOT2_ARCHITECTURE_CURRENT)
      return header;
  }
```

Two things make this safe enough to ship: the magic is 32 bits wide _and_ the four-field 32-bit sum must be zero, so a false positive needs a 64-bit coincidence at an 8-byte-aligned offset. Multiboot 1 used a 8192-byte window and 4-byte alignment ([`include/multiboot.h`][mb1-h]); doubling the alignment and quadrupling the window is the visible cost of letting the header float. Note also `multiboot_elfxx.c`'s `phlimit = grub_min ((grub_off_t) MULTIBOOT_SEARCH, grub_file_size (mld->file))` — the same 32 KiB bound is applied to ELF program-header parsing, so the loader never reads outside the window it already has.

### The `bzImage`: three parses of one 4 KiB prefix, measured

The Linux `x86` kernel image is the family's densest specimen, and unlike the others it needs no hole at all — it interleaves _fields_ rather than regions. Reading [`arch/x86/boot/header.S`][x86-hdr] and then measuring `linux-6.18.26` on this machine:

| Offset  | Bytes                                                              | Parse it belongs to                                                                   |
| ------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| `0x000` | `4d 5a` (`MZ`)                                                     | DOS/PE signature — `IMAGE_DOS_SIGNATURE`                                              |
| `0x038` | `cd 23 82 81`                                                      | `LINUX_PE_MAGIC` `0x818223cd` — "this PE targets Linux for the declared machine type" |
| `0x03c` | `40 00 00 00`                                                      | `e_lfanew` → the PE header at `0x40`                                                  |
| `0x040` | `PE\0\0`, machine `0x8664`, 4 sections, `SizeOfOptionalHeader` 160 | the PE32+ headers and section table, ending at `0x198`                                |
| `0x1f1` | `27` (39)                                                          | `setup_sects` — first byte of the Linux boot-protocol setup header                    |
| `0x1fe` | `55 aa`                                                            | the BIOS boot-sector signature                                                        |
| `0x202` | `HdrS`, version `0x020f`                                           | the boot-protocol magic and version                                                   |

The PE headers end at `0x198` and the legacy setup header begins at `0x1f1`: the kernel's authors laid a complete PE32+ header set, including a four-entry section table, into the DOS-stub region and stopped 89 bytes short of the field the 1991 boot protocol already owned. `Subsystem` is `0x0A` (`IMAGE_SUBSYSTEM_EFI_APPLICATION`), and `setup_sects` 39 ⇒ `(39+1)*512 = 20480 = 0x5000`, which is exactly `PointerToRawData` of the `.text` section — the two layouts agree on where the compressed kernel starts because they were _made_ to agree, not because either format required it.

`aarch64` is even more direct. The first four bytes of an `arm64` kernel image must be a valid instruction _and_ the ASCII `MZ`, so the kernel emits a no-op whose encoding happens to spell it, from [`arch/arm64/kernel/efi-header.S`][arm64-hdr]:

```asm
	.macro	efi_signature_nop
#ifdef CONFIG_EFI
.L_head:
	/*
	 * This ccmp instruction has no meaningful effect except that
	 * its opcode forms the magic "MZ" signature required by UEFI.
	 */
	ccmp	x18, #0, #0xd, pl
```

That is superposition at the smallest possible granularity: four bytes that are simultaneously an executed instruction and a format magic number.

---

## Format identity and multiplicity

**Score: 3/3 (defining).** Multiplicity is not a side effect here; it is the entire product requirement. A "hybrid ISO" that satisfied only ISO 9660 would be a normal ISO, and a UKI that satisfied only the UKI section conventions would be unbootable.

The important contribution this subject makes to the catalog is a **fourth mechanism of composition**, and a correction to the taxonomy sketched from ZIP. The mechanisms, in increasing order of how much cooperation they demand from the base format:

| Mechanism                | Example                                                | Requires from the base format                       | Fragile against                                                  |
| ------------------------ | ------------------------------------------------------ | --------------------------------------------------- | ---------------------------------------------------------------- |
| **Suffix tolerance**     | ZIP central directory found by backwards `EOCD` scan   | index at the end; offsets relative or fixed up      | writers that rewrite the whole file; strict trailing-byte checks |
| **Reserved hole**        | ISO 9660 System Area (32 KiB); PE's DOS-stub gap       | a region the standard declines to specify           | nothing — the hole is normative                                  |
| **Reserved field**       | El Torito in `Boot System Use` (BP 72–2048)            | an unknown-value-means-nothing rule for descriptors | validators that reject unknown descriptor types                  |
| **Field-level aliasing** | `bzImage` PE header at `0x40`, setup header at `0x1f1` | two parsers reading _disjoint_ offset ranges        | either format growing into the other's range                     |
| **Extent aliasing**      | ISO file = GPT partition = El Torito EFI image         | length-and-offset addressing rather than framing    | producers that relocate files (`xorriso` must be told not to)    |

So the "prefix-tolerant / suffix-tolerant / neither" partial order the [source outline][index] asks about is real but under-specified: **anchoring predicts composability only for formats that specify their whole byte range.** ISO 9660 is header-anchored and yet prefix-parasitic, because §6.2.1 and §12.4 carve out and _mandate access to_ 32 KiB. PE is header-anchored and yet prefix-parasitic, because `e_lfanew` at `0x3c` is an _indirection_ rather than a fixed offset — the region between `0x40` and `e_lfanew` is by construction available, which is precisely the room the Linux `bzImage` and every UEFI application use. The predictive rule is therefore:

> A format composes on a given side iff, on that side, it is either (a) anchored elsewhere, (b) holed by its own standard, or (c) reached through an indirection whose target it does not constrain. Anchoring alone is not the discriminator; **specified-ness of the complement** is.

That is a strictly stronger statement than "footer-anchored formats compose," and it predicts rather than catalogues: it says that PDF composes at _both_ ends — its header is located leniently and its cross-reference table is reached by a tail scan from `startxref` ([see polyglot craft][polyglot]) — that tar composes only by extent aliasing (every byte is in a 512-byte record), and that a hypothetical format with a mandatory whole-file checksum composes nowhere.

**Where the line is drawn against the out-of-scope list.** These artifacts are in scope for the same reason redbean is: the byte stream genuinely satisfies multiple independent parsers, and dispatch is what turns that into behaviour. They are _not_ here as an inventory of interesting boot formats. Where a boot format is merely a container with one reader — a plain `initramfs` `cpio`, an `EFI` binary with no second parse — it is static packaging and belongs in the [application-packaging tree][packaging].

## Index anchoring and random access

Every format on this page is header-anchored or scanned; none is footer-anchored. That makes them the natural control group against [footer-indexed formats][footer], and the comparison is unflattering in one specific way: **the front-anchored index has fixed capacity**.

| Format        | Index                                                  | Cost of finding it           | Cost of adding an entry                                                       |
| ------------- | ------------------------------------------------------ | ---------------------------- | ----------------------------------------------------------------------------- |
| ISO 9660      | Volume descriptors from Logical Sector 16; path tables | one 2 KiB read at byte 32768 | rewrite the directory records; sizes are in the PVD                           |
| El Torito     | Boot Record VD (sector 17) → catalog LBA → catalog     | 3 sequential 2 KiB reads     | append a 32-byte catalog entry                                                |
| MBR           | 4 entries at byte 446                                  | one 512-byte read            | **impossible past 4** — the reason GPT exists                                 |
| GPT           | 128 entries × 128 bytes at LBA 2                       | one 17 KiB read              | bounded by `numParts`, fixed at build time                                    |
| PE/COFF (UKI) | section table immediately after the optional header    | ≈1 KiB read at `e_lfanew`    | needs slack inside `SizeOfHeaders`; `ukify` raises `PEError` when it runs out |
| Multiboot2    | none — magic found by scanning                         | up to 32 768 bytes read      | free (tags are a chain terminated by `MULTIBOOT_TAG_TYPE_END`)                |

The random-access story is genuinely good and largely unexploited. A UKI's section table is ≈40 bytes per section at a location derivable from two reads, so the answer to "what kernel version is in this 90 MiB UKI on a remote mirror" is _three HTTP range requests_: the DOS header for `e_lfanew`, the PE header for `NumberOfSections`/`SizeOfOptionalHeader`, and the section table plus the tiny `.uname`/`.osrel` sections. `.osrel` and `.uname` are text and typically well under 1 KiB. This is the boot-format instance of the question [range-request access][range] asks, and it is easier here than for a SQLite b-tree, because the section table is a flat array with no pointer chasing.

Nothing in the ecosystem does this today. `ukify inspect` opens the file locally through `pefile`, and `bootctl` enumerates the ESP. The gap is tooling, not format — which is the recurring finding of this catalog's index-anchoring cluster.

The negative result belongs to Multiboot: a stream-scanned index gives up random access by construction. GRUB must read and search 32 KiB before it knows whether the file is a Multiboot image at all, and `find_header` walks up to 4 094 candidate offsets. That is cheap on a local disk and structurally hostile to a network fetch, which is the trade a floating header always makes.

## Reflexivity and query surface

**Score: 1/3 (incidental).** This is the axis where boot hybrids are weakest, and the weakness is instructive.

There _is_ self-inspection at runtime, and it is real: `systemd-stub` interrogates the PE image it is executing from, by section name, through [`pe_memory_locate_sections()`][pe-c]. The stub does not receive its kernel as a parameter; it _looks itself up_. Given the axis definition — "can it interrogate itself while running" — that is a genuine 1, arguably generous at that, because the vocabulary is a fixed 15-entry enum in [`uki.h`][uki-h] and the query language is `strcmp` on an 8-byte name.

There is also a build-time query surface. `ukify inspect` reports, per section, size and SHA-256, and decodes text sections, emitting JSON:

```python
# systemd src/ukify/ukify.py — inspect_section()
size = pe_section_size(section)
data = section.get_data(length=size)
digest = sha256(data).hexdigest()
struct: dict[str, Union[int, str]] = {'size': size, 'sha256': digest}
```

That is a flat catalogue of blobs, not a query surface. You cannot ask a UKI which modules its initrd contains, whether its kernel was built with a given config, or what its `.sbat` generation implies about revocation, without unpacking the sections and running format-specific tools on each. The comparison with [`sqlelf`][sqlelf] is exactly the catalog's thesis 1 in miniature: **PE's section table is a hand-rolled table with a fixed schema, a primary key that is an 8-byte `char[8]`, and no join partner**. `ukify` maintains, in Python, the uniqueness constraint the format cannot express:

```python
# systemd src/ukify/ukify.py — UKI.add_section()
if any(section.name == s.name for s in self.sections[start:]
       if s.name not in MULTI_INSTANCE_SECTIONS):
    raise ValueError(f'Duplicate section {section.name}')
```

…while the stub, reading the same file, enforces nothing and simply takes the first match ("First matching section wins, ignore the rest"), and `uki_hash()` in [`pe-binary.c`][pe-binary] treats a duplicate as `EBADMSG`. Three readers of one format with three different duplicate-key policies: a textbook parser differential ([see the differentials page][differentials]).

The sharpest evidence for thesis 2 — _self-description is what makes a format survivable; formats without one accrete conventions_ — is a single line. `ukify`'s display table knows a `.sbom` section:

```python
# systemd src/ukify/ukify.py — DEFAULT_SECTIONS_TO_SHOW
    '.sbat':    'text',
    '.sbom':    'binary',
    '.profile': 'text',
```

The string `sbom` occurs **exactly once in the entire systemd tree** (verified by `grep -rn` over `9bb06d5`), and `.sbom` appears **nowhere in the UAPI.5 specification**. It is not in the canonical measurement order, not in `unified_sections[]`, not measured, not documented. It is a convention that accreted around a format with no schema — precisely the failure mode thesis 2 predicts, occurring inside a specification that is otherwise unusually disciplined about ordering and canonicality. See [embedded provenance][provenance] for what an SBOM-in-artifact is supposed to be.

## Closure, dedup, and size model

**Score: 2/3 (designed-in).** A UKI is a closure by intent: kernel + initrd + microcode + command line + devicetree + firmware, everything needed to reach userspace, in one file. The spec's own justification is atomic update on a vFAT ESP, i.e. closure chosen for _transactional_ reasons rather than portability reasons.

The size model is brutal and openly acknowledged. From [`ukify.py`][ukify], on a limitation of the `pefile` library:

```python
# pefile has an hardcoded limit of 256MB, which is not enough when building an initrd with large firmware
# files and all kernel modules. See: https://github.com/erocarrera/pefile/issues/396
```

A container designed for firmware images in the tens of kilobytes is being asked to hold a quarter of a gigabyte of kernel modules and GPU firmware. Concretely, on the machine this page was written on, the kernel alone — `linux-6.18.26`'s `bzImage` — is 13 222 400 bytes before any initrd, and a distribution initrd carrying `linux-firmware` routinely exceeds it several times over.

Dedup is the axis's bad news, and it is structural:

- **No sharing between UKIs.** Two UKIs for two kernel versions built from the same OS duplicate the entire initrd. There is no equivalent of the [Nix store's][nix] shared closure or [content-addressed chunking][cas]; the ESP is vFAT, which has neither hard links, nor reflinks, nor extent sharing.
- **No sharing within a UKI.** `.ucode` and `.initrd` are separate `cpio` archives; a multi-profile UKI's per-profile `.cmdline` sections are independent blobs.
- **Alignment waste is paid twice.** `ukify` rounds `SizeOfRawData` up to `FileAlignment` and `VirtualAddress` up to `SectionAlignment`. For a dozen small text sections this is negligible; it is mentioned only because it is the direction ISO 9660's 2 048-byte logical sectors also round.

Against this, the _addons_ mechanism is a genuine, if partial, dedup answer: PE Addons are separate signed PE files carrying `.cmdline`/`.dtb`/`.initrd`/`.ucode` sections that the stub merges with the UKI's own at boot, sorted by filename. The UAPI spec places resources shared by every UKI in `/usr/lib/modules/uki.extra.d/` and per-UKI resources in `/usr/lib/modules/$UNAME/$UKI.efi.extra.d/`. That is closure factored into a shared part and a specific part — a store, expressed as a directory naming convention, with the loader as its resolver. It gets you a shared machine-id addon; it does not get you a shared 200 MiB initrd, because `.linux` may not appear in an addon and the initrd merge is _append_, not _substitute_.

The `isohybrid` side has an unusually clean closure story that is worth stating because it is the counter-example: the hybrid adds **zero** bytes of payload. The MBR, GPT and APM all fit in the pre-existing System Area, and the only growth is cylinder-alignment padding plus, when `--uefi` is used, at most 1 MiB more so the secondary GPT has somewhere to live:

```c
/* syslinux utils/isohybrid.c — main() */
if (free_space < orig_gpt_size && padding < orig_gpt_size) {
    padding += 1024 * 1024;
}
```

Multiplicity at a cost of ~0.1% on a 700 MiB image is as cheap as format superposition ever gets, and it is cheap for exactly one reason: the second format was invited in by the first.

## Mutability, dispatch, and trust

**Score: 0/3 (absent), and the zero is a design goal.** A UKI is signed as a whole PE; a hybrid ISO is a read-only optical/USB image. Neither is its own state store, neither self-modifies, and both would be _broken_ by the ability to. This is the axis on which boot hybrids are the polar opposite of [SELF/selfdb][selfdb] and of redbean's `-*` flag, and the contrast is the most useful thing about them.

### Dispatch: the medium chooses the parse

Dispatch here is not `binfmt_misc` and not a shebang ([see the dispatch page][binfmt]); it is the _transport_. The identical byte stream is routed by how it was presented:

| Presentation                 | Dispatcher            | Entry path                                                       |
| ---------------------------- | --------------------- | ---------------------------------------------------------------- |
| Optical drive, BIOS          | El Torito             | sector 17 → catalog → `de_lba` → `isolinux.bin`                  |
| USB/HDD, BIOS                | MBR boot-sector scan  | byte 0 code, `0x55AA` at 510, `de_lba*4` read back from byte 432 |
| USB/HDD, UEFI                | GPT + ESP enumeration | LBA 1 GPT → partition 2 → FAT → `/EFI/BOOT/BOOTX64.EFI`          |
| Optical drive, UEFI          | El Torito EFI section | `platform_id == 0xef` → `efi_lba` → the same FAT image           |
| ESP file, UEFI               | `LoadImage()` on PE   | UKI's `AddressOfEntryPoint` → `systemd-stub`                     |
| `multiboot2` command in GRUB | 32 KiB magic scan     | tag chain → entry address                                        |

Nobody sniffs content to choose among these; each firmware path simply _assumes_ its format and the artifact has been built to survive all of the assumptions. That is a different dispatch model from every other entry in this catalog, and it is the reason multiplicity here is a hard requirement rather than a convenience: there is no negotiation step in which the artifact could declare what it is.

### Trust: one signature over the whole superposition

Secure Boot verifies the UKI as a PE. Authenticode's hash is not "the file"; systemd implements it in [`pe_hash()`][pe-binary] and the omissions are explicit:

```c
/* systemd src/shared/pe-binary.c — pe_hash() (abridged) */
/* Everything from beginning of file to CheckSum field in PE header */
…
/* Everything between the CheckSum field and the Image Data Directory Entry for the Certification Table */
…
/* The rest of the header + the section table */
/* Sort by location in file */
typesafe_qsort(sections, le16toh(pe_header->pe.NumberOfSections), section_offset_cmp);
FOREACH_ARRAY(section, sections, le16toh(pe_header->pe.NumberOfSections)) {
        r = hash_file(fd, mdctx, le32toh(section->PointerToRawData), le32toh(section->SizeOfRawData));
        …
}
```

Three properties follow, and they define what "mutable" can mean for a signed artifact:

1. **The `CheckSum` field and the certificate-table data directory entry are excluded.** Two small windows in a signed file are legitimately writable — which is what makes appending a signature to an already-hashed image possible at all.
2. **Sections are hashed in file-offset order**, not section-table order, and each is hashed as `[PointerToRawData, +SizeOfRawData)`. Bytes not claimed by any section are not covered by that loop; the trailing-data step then hashes from the _accumulated_ section length to end-of-file minus the certificate table. This is why the loaders on this page are so defensive about section geometry, and why systemd added an explicit bound after a hashing-DoS report:

   ```c
   /* Cap on the (VirtualSize - SizeOfRawData) zero-padding the UKI hasher
    * will produce for a single section.  Any value beyond this is treated as
    * a malformed PE — bounds the hash work an attacker can drive (#42344). */
   #define UKI_HASH_VIRTUAL_SIZE_PADDING_MAX (64U * 1024U * 1024U)
   ```

   A 382-byte file that declares `VirtualSize` near `UINT32_MAX` with `SizeOfRawData == 0` drove roughly 4 GiB of SHA-256 work per section. Header-declared sizes that are not cross-checked against the file are the standing hazard of every header-anchored container; see [the threat-model page][threat].

3. **The signature covers `.linux` and `.initrd` as data, so the inner kernel is never independently authenticated.** systemd states this outright in [`UEFI_SECURITY.md`][uefi-sec]:

   > _"Since it is embedded in a PE signed binary, `systemd-stub` will temporarily disable the UEFI authentication protocol while loading the payload kernel it wraps, in order to avoid redundant duplicate authentication of the image, given that the payload kernel was already authenticated and verified as part of the whole image."_

   The implementation is a hook swap on the firmware's own security protocol, and the source is unusually honest about what that is ([`secure-boot.c`][secure-boot]):

   > _"This is a hack as we do not own the security protocol instances and modifying them is not an official part of their spec. But there is little else we can do to circumvent secure boot short of implementing our own PE loader."_

   This is the container tax's dividend and its bill in one place. The dividend: the _combination_ is authenticated, which is what the UKI exists to achieve. The bill: a trusted parser must temporarily suppress the platform's verification to avoid double-verifying, and that suppression is implemented by patching a protocol table the project does not own.

### Immutability enforced at runtime

Because the artifact is signed, the parts of it that would otherwise be knobs must be frozen when Secure Boot is on. `systemd-stub` implements exactly that in [`settle_command_line()`][stub]:

```c
/* We'll suppress the custom cmdline if we are in Secure Boot mode, and if either there is already
 * a cmdline baked into the UKI or we are in confidential VM mode. */
if (secure_boot_enabled() && (PE_SECTION_VECTOR_IS_SET(sections + UNIFIED_SECTION_CMDLINE) || is_confidential_vm()))
        /* Drop the custom cmdline */
        *cmdline = mfree(*cmdline);
```

An externally supplied command line is silently discarded when the image carries its own. Mutability was not "not implemented" — it was implemented and then explicitly revoked under the trust condition, which is the clearest statement in this catalog that **signing and self-modification are in direct opposition**, and the practical answer to the source outline's "how do you sign a mutable executable?" is: this family answers "you don't; you sign an immutable one and route variation into `.profile` sections and separately-signed addons."

Multi-profile UKIs are that routing. Rather than editing `.cmdline`, a UKI carries several, delimited by `.profile` sections and selected by an `@N ` prefix on the stub's invocation parameters, which is stripped before the kernel sees it and _not_ measured. Variation becomes enumeration at build time — a materialized set of the configurations you are willing to sign.

### Measurement: the artifact hashes itself into the TPM

The stub measures its own sections into PCR 11 before using them, in the canonical order of `unified_sections[]`, two events per section ([`stub.c`][stub]):

```c
/* First measure the name of the section */
(void) tpm_log_ipl_event_ascii(TPM2_PCR_KERNEL_BOOT,
                POINTER_TO_PHYSICAL_ADDRESS(unified_sections[section]),
                strsize8(unified_sections[section]), /* including NUL byte */
                unified_sections[section], &m);
/* Then measure the data of the section */
(void) tpm_log_ipl_event_ascii(TPM2_PCR_KERNEL_BOOT,
                POINTER_TO_PHYSICAL_ADDRESS(loaded_image->ImageBase) + sections[section].memory_offset,
                sections[section].memory_size, unified_sections[section], &m);
```

`.pcrsig` is excluded, since it signs the expected outcome of the measurement and cannot be an input to it — `unified_section_measure()` special-cases it. This is why the specification shouts _"PLEASE DO NOT REORDER"_ in both the C enum and the spec's HTML comment: the PCR value is a hash chain over an ordered event list, so section order is part of the artifact's identity in a way no other property is. A container whose _iteration order_ is load-bearing is one more instance of the format doing a database's job by hand — an ordered index maintained by a comment.

---

## Strengths

- **Zero-cost multiplicity where the base format reserved a hole.** A hybrid ISO gains an MBR, a GPT, an APM and UEFI bootability for ~512 bytes of real content plus alignment padding, with the ISO 9660 parse untouched. The 32 KiB System Area is a standardized, _mandatory-to-expose_ extension point, not a hack.
- **One signature over the whole bundle.** A UKI authenticates the kernel/initrd/cmdline _combination_, closing the class of attacks that swap a signed initrd from a different image.
- **Boot without a bootloader.** A UKI can be invoked directly by firmware, which is why it is the format of choice in Confidential Computing guests where the attestation must cover everything after firmware.
- **Atomic updates on a hostile filesystem.** One file replaced on vFAT beats five files that must land together.
- **Self-locating at runtime.** The stub reads its own section table; nothing external needs to describe the image to it.
- **Formats that specify their unknown bytes age well.** El Torito (1995) is parsed correctly by ISO 9660 (1987) readers, and a 2026 `bzImage` still presents a valid 1981-vintage boot sector signature.
- **The scanning design (Multiboot) buys format-independence.** GRUB can boot an image whose executable format it does not fully understand, because the contract lives in a magic-plus-checksum tag stream instead of in the executable header.

## Weaknesses

- **Front-anchored indexes have fixed capacity.** `ukify` raises `Not enough header space to add section` when `SizeOfHeaders` runs out; MBR's four entries forced GPT into existence. A footer index does not have this failure mode.
- **No dedup, at all.** N UKIs for N kernels duplicate N initrds on a vFAT ESP with no sharing primitive. Sizes are large (a 13 MiB kernel is the _small_ component) and the tooling's own library ceiling was 256 MiB.
- **The query surface is a name→blob table.** Section names are 8 bytes, the vocabulary is a hardcoded enum, and there is no way to ask a question that crosses two sections.
- **Undocumented sections accrete.** `.sbom` exists in `ukify`'s display table and in no specification.
- **Three readers, three duplicate-section policies.** `ukify` refuses duplicates, the stub takes the first match, `uki_hash()` errors — a differential in a security-relevant format.
- **Authenticode's hash is not the file's hash.** Excluded fields and section-geometry-driven coverage make "is this the artifact I signed?" a subtler question than it looks, and have already produced a hashing-DoS fix.
- **The trusted stub must suppress the platform's verification** to load its own payload, via an unsanctioned protocol-table patch.
- **Mutability is revoked rather than solved.** Command-line overrides are dropped under Secure Boot; variation must be enumerated at build time as profiles or addons.
- **`isohybrid` is effectively frozen.** The `syslinux` tree surveyed here ends at commit `5e42653`, dated 2018-10-25; ISO producers have largely moved to `xorriso`'s native hybrid support.
- **Scanning costs random access.** Multiboot2 must read 32 KiB and test ~4 094 offsets before it can say "not a Multiboot image."

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                                          | Trade-off                                                                                                                |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| ISO 9660 reserves Logical Sectors 0–15 and _requires_ writers to expose them | Lets media carry system-specific boot data without the filesystem standard knowing about any of it | 32 KiB is unusable for data on every ISO ever written, boot or not                                                       |
| El Torito lives in a Boot Record VD's `Boot System Use` field                | A 1995 extension parsed correctly by 1987 readers; no base-standard revision                       | Boot support is reachable only through a three-hop indirection chain, and validators must tolerate unknown descriptors   |
| `isohybrid` forges an MBR/GPT rather than converting the image               | One artifact for optical and USB, BIOS and UEFI; no payload duplication                            | Partition tables describe extents that are also files; producers must not relocate them; entirely post-hoc and fragile   |
| UKI uses PE/COFF as its container                                            | UEFI already loads PE, Secure Boot already signs PE, `shim` already verifies PE                    | An 8-byte-name, fixed-capacity, front-anchored section table is now the schema for kernels and 100+ MiB initrds          |
| Only `.linux` is mandatory                                                   | Distinguishes a UKI from a PE Addon; everything else is optional and overridable                   | Almost every interesting property of a UKI is optional, so consumers must impose their own requirements (`sd-boot` does) |
| Section order is canonical and frozen                                        | PCR 11 is a hash chain; predictable pre-computation of policies requires a fixed order             | The container's iteration order is part of its identity, enforced only by a comment and a code review                    |
| `.pcrsig` is excluded from measurement                                       | It signs the expected measurement, so it cannot be an input to it                                  | One section is special-cased in every consumer; `ukify` must patch it in-place post-signature into pre-sized space       |
| Sign the whole PE; suppress inner verification                               | Authenticates the _combination_ of kernel + initrd + cmdline, not just the parts                   | The stub patches the firmware's security protocol — a "hack", in the project's own words                                 |
| Drop externally supplied cmdline under Secure Boot                           | A signed artifact whose command line can be edited is not a signed artifact                        | No override exists at build or run time; variation must be enumerated as profiles or shipped as separately signed addons |
| Multi-profile UKIs instead of editable configuration                         | Keeps every bootable configuration inside the signature                                            | Every variant must be anticipated; sections repeat per profile with no sharing                                           |
| Multiboot2 scans a bounded 32 KiB prefix, 8-byte aligned, magic + checksum   | The loader needs no knowledge of the image's executable format                                     | No random access; a 32 KiB read and ~4 094 comparisons before a negative answer; false-positive risk managed by checksum |
| `arm64` emits `ccmp x18, #0, #0xd, pl` to spell `MZ`                         | The first instruction must execute _and_ satisfy UEFI's signature check                            | The image's first four bytes are load-bearing in two languages at once; changing either breaks the other                 |

---

## Sources

- [UAPI Group — UAPI.5 Unified Kernel Images (canonical spec)][uki-spec] and its repository copy, [`specs/unified_kernel_image.md`][uki-spec-src]
- [ECMA-119 — Volume and File Structure of CDROM for Information Interchange, 4th edition (June 2019)][ecma119] — §6.2.1 (System Area), §6.7.1 (descriptor set at LSN 16), §8.2 (Boot Record), §12.4 (producer obligation)
- ["El Torito" Bootable CD-ROM Format Specification 1.0 (Phoenix/IBM, 1995)][eltorito]
- [The Multiboot2 Specification (GNU)][mb2-spec]
- [Microsoft — PE Format reference][pe-format]
- [`systemd-stub(7)`][sd-stub-man] · [`ukify(1)`][ukify-man] · [The Linux/x86 Boot Protocol][x86-boot]
- [`syslinux` `utils/isohybrid.c` — the hybrid post-processor][isohybrid] and [`utils/isohybrid.h`][isohybrid-h]
- [`syslinux` `mbr/isohdpfx.S` — the MBR stub written into the System Area][isohdpfx]
- [systemd `src/ukify/ukify.py` — section building, signing, `inspect`][ukify]
- [systemd `src/boot/pe.c` — PE header/section validation and self-location][pe-c]
- [systemd `src/boot/stub.c` — measurement, addons, `settle_command_line()`][stub]
- [systemd `src/boot/linux.c` — loading the inner kernel from `.linux`][linux-c]
- [systemd `src/boot/secure-boot.c` — the security-protocol override][secure-boot]
- [systemd `src/boot/UEFI_SECURITY.md` — the stated security posture][uefi-sec]
- [systemd `src/fundamental/uki.h`][uki-h] · [`uki.c`][uki-c] — the canonical section enum and names
- [systemd `src/shared/pe-binary.c` — `pe_hash()` (Authenticode) and `uki_hash()`][pe-binary]
- [GRUB `include/multiboot2.h`][mb2-h] · [`include/multiboot.h`][mb1-h] · [`grub-core/loader/multiboot_mbi2.c`][mb2-c]
- [Linux `arch/x86/boot/header.S`][x86-hdr] · [`arch/arm64/kernel/efi-header.S`][arm64-hdr] · [`arch/arm64/kernel/head.S`][arm64-head] · [`include/linux/pe.h`][linux-pe-h] · [`fs/isofs/inode.c`][isofs]
- Related in this catalog: [ZIP parasitism][zip] · [Polyglot craft][polyglot] · [Footer-indexed formats][footer] · [Parser differentials][differentials] · [Dispatch via `binfmt_misc`][binfmt] · [Threat model][threat] · [Embedded provenance][provenance] · [Range-request access][range] · [Cosmopolitan/APE][ape] · [`sqlelf`][sqlelf] · [SELF/selfdb][selfdb] · [Nix store closures][nix] · [Content-addressed chunking][cas] · [Measurement method][measurement] · [Concepts][concepts] · [Catalog index][index]

<!-- References -->

[systemd-repo]: https://github.com/systemd/systemd
[uapi-repo]: https://github.com/uapi-group/specifications
[syslinux-repo]: https://github.com/geneC/syslinux
[grub-repo]: https://github.com/rhboot/grub2
[uki-spec]: https://uapi-group.org/specifications/specs/unified_kernel_image/
[uki-spec-src]: https://github.com/uapi-group/specifications/blob/1375569c37d32dd905a1b1fb2f00d1a191f9ff38/specs/unified_kernel_image.md
[ecma119]: https://ecma-international.org/publications-and-standards/standards/ecma-119/
[eltorito]: https://pdos.csail.mit.edu/6.828/2017/readings/boot-cdrom.pdf
[mb2-spec]: https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html
[pe-format]: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
[sd-stub-man]: https://man.archlinux.org/man/systemd-stub.7
[ukify-man]: https://man.archlinux.org/man/ukify.1
[x86-boot]: https://www.kernel.org/doc/html/latest/arch/x86/boot.html
[isohybrid]: https://github.com/geneC/syslinux/blob/5e426532210bb830d2d7426eb8d8c154d9dfcba6/utils/isohybrid.c
[isohybrid-h]: https://github.com/geneC/syslinux/blob/5e426532210bb830d2d7426eb8d8c154d9dfcba6/utils/isohybrid.h
[isohdpfx]: https://github.com/geneC/syslinux/blob/5e426532210bb830d2d7426eb8d8c154d9dfcba6/mbr/isohdpfx.S
[ukify]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/ukify/ukify.py
[pe-c]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/boot/pe.c
[stub]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/boot/stub.c
[linux-c]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/boot/linux.c
[secure-boot]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/boot/secure-boot.c
[uefi-sec]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/boot/UEFI_SECURITY.md
[uki-h]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/fundamental/uki.h
[uki-c]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/fundamental/uki.c
[pe-binary]: https://github.com/systemd/systemd/blob/9bb06d5cd675820f4219d0be69a54f4e51398710/src/shared/pe-binary.c
[mb2-h]: https://github.com/rhboot/grub2/blob/504c9b79cf0fd0dcddede0f9f26f93710dcf72aa/include/multiboot2.h
[mb1-h]: https://github.com/rhboot/grub2/blob/504c9b79cf0fd0dcddede0f9f26f93710dcf72aa/include/multiboot.h
[mb2-c]: https://github.com/rhboot/grub2/blob/504c9b79cf0fd0dcddede0f9f26f93710dcf72aa/grub-core/loader/multiboot_mbi2.c
[x86-hdr]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/arch/x86/boot/header.S
[arm64-hdr]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/arch/arm64/kernel/efi-header.S
[arm64-head]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/arch/arm64/kernel/head.S
[linux-pe-h]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/linux/pe.h
[isofs]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/fs/isofs/inode.c
[zip]: ./zip-parasitism.md
[polyglot]: ./polyglot-craft.md
[footer]: ./footer-indexed-formats.md
[differentials]: ./parser-differentials.md
[binfmt]: ./binfmt-misc.md
[threat]: ./threat-model.md
[provenance]: ./embedded-provenance.md
[range]: ./range-request-access.md
[ape]: ./cosmopolitan-ape/index.md
[sqlelf]: ./sqlelf.md
[selfdb]: ./self-selfdb/index.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[measurement]: ./measurement.md
[concepts]: ./concepts.md
[index]: ./index.md
[packaging]: ../application-packaging/index.md
