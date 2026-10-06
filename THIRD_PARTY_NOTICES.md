# Simple Reader open-source notices

Simple Reader is distributed under AGPL-3.0-or-later. See LICENSE.

## Readest
Source: https://github.com/readest/readest
Original module: apps/readest-app/src/utils/xcfi.ts
License: GNU Affero General Public License v3.0 (upstream LICENSE).
Copyright: Readest contributors.

EPUBPositionBridge.js adapts DOM/XPointer path traversal, whitespace normalization,
text-node indexing, and cfi-inert/cfi-skip treatment from the upstream XCFI class.
Modified for Simple Reader: removed the foliate-js CFI dependency; added viewport
capture, CSS selectors/text quotes for Readium, strict invalid-offset reporting,
and a native Swift adapter. Readest's application, account service and annotation
sync are not embedded. The adaptation was made on 2026-10-06.

## Readium Swift Toolkit 3.8.0
https://github.com/readium/swift-toolkit/tree/3.8.0
Copyright 2026 Readium Foundation. BSD-3-Clause.
The original license is included under Docs/Licenses/Readium.txt.

Readium's resolved transitive libraries include CryptoSwift (Apache-2.0),
DifferenceKit (Apache-2.0), Fuzi (MIT), ZIPFoundation (MIT), Zip (MIT),
SwiftSoup (MIT). The dependency sources and their license texts are available
in the pinned Swift Package checkouts; see Docs/Licenses for bundled notices.

## KOReader protocol
https://github.com/koreader/koreader
The content digest follows util.partialMD5's sampled MD5 algorithm; progress
fields and authentication follow kosync.koplugin. KOReader engine code is not
embedded in this application. Original project: AGPL-3.0.

## Test oracle and sample book
Readest's sample-alice.json CREngine oracle (707 words), fetched 2026-10-06,
and XHTML spine content extracted from the corresponding sample-alice.epub.
Sources: apps/readest-app/src/__tests__/fixtures/crengine/sample-alice.json and
apps/readest-app/src/__tests__/fixtures/data/sample-alice.epub.
Alice's Adventures in Wonderland: Lewis Carroll, public-domain text; original
EPUB publisher notices are retained in the extracted XHTML. Test oracle
redistributed with attribution under Readest's AGPL-3.0 license.
