# NOTICE

CodeEdit Claude Companion
Copyright (c) 2026 The CodeEdit Claude Companion authors

This product is released under the MIT License (see `LICENSE.md`). It is a fork
of, and includes, third-party open-source software. The components below are the
property of their respective authors and are distributed under their own
licenses. All original copyright and permission notices are retained.

> Note: replace "The CodeEdit Claude Companion authors" above with your
> organization's preferred copyright holder before publishing, if desired. The
> upstream CodeEdit copyright in `LICENSE.md` must be preserved either way.

---

## 1. CodeEdit (macOS app foundation)

The `CodeEdit/`, `CodeEdit.xcodeproj/`, `CodeEditUI/`, `CodeEditTests/`,
`CodeEditUITests/`, `OpenWithCodeEdit/`, and related editor sources are derived
from the CodeEdit project.

- Project: https://github.com/CodeEditApp/CodeEdit
- License: MIT — Copyright (c) 2022 CodeEdit (see `LICENSE.md`)
- Not affiliated with or endorsed by the CodeEdit project.

The Claude terminal companion additions (the remote bridge, terminal session
mirroring, QR pairing, and Markdown streaming) are layered on top of CodeEdit
and are provided under the same MIT License.

## 2. SwiftTerm (terminal emulation / PTY hosting)

Used by the macOS app to host and render local shell sessions.

- Project: https://github.com/migueldeicaza/SwiftTerm
- Fork used: https://github.com/thecoolwinter/SwiftTerm (branch `codeedit`)
- License: MIT — Copyright (c) Miguel de Icaza and SwiftTerm contributors

## 3. Bundled Markdown renderer assets (iOS app)

The iOS app renders Markdown fully offline; the following minified libraries and
their fonts are bundled under
`CodeEditRemoteiOS/CodeEditRemoteiOS/MarkdownRenderer/`.

### KaTeX (math rendering) — v0.16.x
- Project: https://github.com/KaTeX/KaTeX
- Files: `katex.min.js`, `katex.min.css` (KaTeX web fonts inlined as base64)
- License: MIT — Copyright (c) 2013-2020 Khan Academy and other contributors

### marked (Markdown parser) — v15.0.12
- Project: https://github.com/markedjs/marked
- File: `marked.min.js`
- License: MIT — Copyright (c) 2011-2018, Christopher Jeffrey and marked contributors

### DOMPurify (HTML sanitizer) — v3.4.2
- Project: https://github.com/cure53/DOMPurify
- File: `purify.min.js`
- License: Apache-2.0 OR MPL-2.0 (dual-licensed) — Copyright (c) Cure53 and other contributors
- This distribution uses DOMPurify under the Apache License, Version 2.0.

---

## License texts

The MIT License text (covering this project, CodeEdit, SwiftTerm, KaTeX, and
marked) is reproduced in `LICENSE.md`. The Apache-2.0 license for DOMPurify is
available at https://www.apache.org/licenses/LICENSE-2.0 and in the DOMPurify
repository linked above. Full, unmodified license texts for each component are
available in their respective upstream repositories.
