# PDF reader verification

Version: **5.13.0**. Binding scope: Q-001--Q-003, DEC-001--DEC-003,
F-001's Resolution and discussion.md. Technical choices: DEC-004.

## Acceptance evidence

| Requirement / criteria | Shipping implementation | Automated evidence |
| --- | --- | --- |
| REQ-001: rendered PDF tab and duplicate reuse | `DocumentState.swift`, `WorkspaceManager.openFile`, `ContentView`, `PDFReaderView` | Extracted shipping routing and tab store execute on PDF URLs; reuse preserves the tab ID, source text stays empty, saving never reaches the text writer. The shipping SwiftUI container mounts its PDF canvas and thumbnails. |
| REQ-001 / REQ-002: every page, scans, ordering and controls | `PDFReaderLoading`, `PDFReaderPDFView`, reader controls | Generated three-page mixed and two-page scanned fixtures render all pages; first/last order, page jumps, invalid jumps, zoom and distinct fit-page/width scales are checked. Detached/recreated views retain the reading page. |
| REQ-001 / REQ-002: thumbnails | Native `PDFThumbnailView` bound to the current canvas | Mounted SwiftUI reader and native selection checks verify the PDF/thumbnail binding and current selected page. Native PDFKit supplies selectable thumbnail navigation. |
| REQ-001 / REQ-002: outline | `PDFReaderOutline`, SwiftUI `OutlineGroup`, controller destinations | Nested outline survives loading and navigates to the last page; image-only documents with no outline load normally. |
| REQ-001 / REQ-003: search and result navigation | Asynchronous `PDFDocument.beginFindString`, controller result navigation | Search finds text on both text pages, skips image-only pages, wraps both ways and discards replaced queries. Clearing a query clears results. |
| REQ-001 / REQ-003: selection and copy | Native `PDFView`, permission-enforcing copy action | Embedded selection reaches the pasteboard. A scan has no recognized selection. A password-unlocked PDF without copying permission leaves the pasteboard unchanged. |
| REQ-001 / REQ-003: internal and external links | Reader action allowlist and URL delegate | Loaded internal links and named navigation reach their target page; foreign-document destinations are blocked. Only HTTP/HTTPS/mailto actions reach the injected opener; file, custom, executable, data, relative, credential-bearing and control-character URLs are blocked. Native delegate cannot bypass the policy. |
| REQ-001: read-only, no saved markup | Non-text tab/save boundary, read-only widgets, restricted actions and copy-only context menu | Source PDF bytes remain exactly equal after reading, searching, copying, navigation and password unlocking. Loaded form widgets are read-only. There is no PDF writer, markup toolbar or saved-annotation flow in the reader. |
| REQ-001 / REQ-003: no OCR | Rendering and embedded-text APIs only | Image-only scans have no text selection, search results or feature-source recognized text. No OCR API or OCR command is added. |
| REQ-001: no new workspace search or AI | PDF route returns before text loading; reader holds no AI/index dependency | Shipping-route harness rejects entering text/data/watch/save paths. Existing project-search regression suite passes; its binary PDF exclusion is unchanged. |
| REQ-001: preserve feature-source ingestion | `FeatureIngest.swift` unchanged | The existing `readableText` method is extracted and executed against mixed and scanned fixtures: embedded text remains available, scans produce none. |
| Failure handling and permissions | Async loading, password and error states | Missing, malformed, empty, non-file, directory and unreadable inputs fail explicitly; incorrect passwords are reported and correct passwords unlock without overriding copying restrictions. |
| Session and adjacent behavior | PDF tab archive variant, editor bypass | Window session checks preserve a PDF URL with spaces without a draft. Existing file/Explain, editor routing, project search, PDF export and document-file suites pass. |

## Commands and observed results

```text
tools/tests/pdf-reader-tests.sh
PDF workspace routing: dedicated tabs, duplicate reuse, no text/AI/indexing/save path passed
PDF SwiftUI integration: document canvas, thumbnails and controls mounted successfully
PDF reader checks: 66, failures: 0

bash tools/tests/window-session-tests.sh
Window session checks: 21, failures: 0

bash tools/tests/all-files-explain-tests.sh
All file/Explain checks passed.

bash tools/tests/project-search-tests.sh
All project search checks passed.

bash tools/tests/book-pdf-tests.sh /private/tmp/markview-pdf-reader-book-regression
Book PDF: source/draft/deduplication, protected transformation, 16 pages, Cyrillic,
complete tables, bookmarks and 102 links passed.
Folder selection, long contents, Letter pages, sanitized HTML anchors and
cancellation during long layout passed.

bash tools/tests/editor-document-routing-tests.sh
0 WebKit failures

bash tools/tests/document-files-tests.sh
ALL OK (policy, node, page and scheme-handler checks)

xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug \
  -derivedDataPath /tmp/MarkViewPDFReaderDerivedData CODE_SIGNING_ALLOWED=NO build
** BUILD SUCCEEDED **

git diff --check
(exit 0)
plutil -lint MarkView/Info.plist
MarkView/Info.plist: OK

git diff --exit-code origin/main -- MarkView/Models/FeatureIngest.swift \
  MarkView/Models/ProjectSearch.swift MarkView/Bridge/PDFExporter.swift \
  MarkView/Bridge/BookPDFRenderer.swift
(exit 0: existing ingestion, indexing and PDF export implementations unchanged)
```

`PDF Reader Checks` runs the new native suite and adjacent window/file checks on
the PR. Other existing PR workflows retain their tests and app builds. The native
fixture harness intentionally supplies malformed/empty documents, for which
CoreGraphics may emit its generic diagnostic; these cases are explicitly asserted.

No MarkView browser tab was used for checking this feature. The existing editor and
document-file regression commands use their standalone WebKit harnesses, not a tab
in the user's app. No stakeholder manual-test checklist is required.

## Delivery evidence

The feature PR records its green CI checks and merge commit. Issues #274--#278 stay
open until merge, then record the merge and deployment results. The signed,
notarized installer is published as
[v5.13.0](https://github.com/t-boris/MarkView/releases/tag/v5.13.0).
Final Release/notarization/deployment command output is retained with the session
artifacts and summarized in the completion checklist, rather than claiming that
publication was already complete at this local-verification checkpoint.

**Deployment is currently blocked by F-002:** no local Developer ID identity or
notary profile, and no CI signing secrets. The release link above is the intended
target, not evidence that a release exists. Do not treat implementation verification
as completion of the full signed-release objective.
