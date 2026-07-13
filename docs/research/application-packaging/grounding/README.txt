Application-packaging Apple evidence snapshot
=============================================

Captured: July 13, 2026
Purpose: durable grounding for macOS trust claims whose canonical Apple URLs and local
manual pages are mutable. These files are research evidence, not VitePress pages.

Files
-----

apple-host-evidence-2026-07-13.txt
    Selected macOS 26.3.1 `codesign(1)` and `stapler help` output.
    SHA-256: 4bc0e1eb0d3fcc73ef817d0d7c36a9d658a0c7dcc9bf05f2d623cb23bf3b7383

apple-tn2206-2026-07-13.txt
    Text snapshot retrieved from Apple's TN2206 code-signing technote URL.
    Canonical URL: https://developer.apple.com/library/archive/technotes/tn2206/_index.html
    SHA-256: cab11cd74a53b1355c59ffdd813abfbda6053c6f9ec821b2204ab0762bc9f482

apple-platform-security-2026-07-13.txt
    Text snapshot retrieved from Apple's Platform Security code-signing page.
    Canonical URL: https://support.apple.com/guide/security/app-code-signing-process-sec3ad8e6e53/web
    SHA-256: 4233853bc403be4cb0f8f5ab5c5668b583f2d4c0ed01eaf149546b8b4eb0ebc0

apple-gatekeeper-2026-07-13.html.gz
    Gzip-compressed HTML snapshot of Apple's Gatekeeper/runtime protection page.
    Canonical URL: https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
    SHA-256: 279c9802e1db69ebd4ff8af556a22d0f323bfbc0352403dc3294b6f96e62be50

apple-notarization-2026-07-13.html.txt
    HTML snapshot of Apple's notarization workflow page.
    Canonical URL: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
    SHA-256: 7bdb7b19126ae9ea4aaed597c7dff3a1f50e2d60e2a5dc5aab625ae3116cfc5b

apple-notarization-issues-2026-07-13.html.txt
    HTML snapshot of Apple's common notarization issues page.
    Canonical URL: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
    SHA-256: 9d8b09687ca3cc596303d321ff5d6fa425ba7100bc51a918a87671b722b3e189

The canonical URLs remain in the reader-facing deep-dive. The snapshots preserve the
reviewed bytes; they are not a substitute for checking current Apple policy before a
release.
