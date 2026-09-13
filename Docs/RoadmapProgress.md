# Flora Mail release development

The `v0.1.0` baseline is preserved. Development continues on `develop/live-account-validation`; each phase is built, tested, committed and pushed before the next phase starts.

## Phase 1 — account and mail compatibility

Implemented an Add Account entry in the main toolbar and welcome dashboard, and native JSON import of public OAuth application identifiers. Imports return only validated public IDs; extra secret fields are not stored. Live account sign-in still requires provider registrations, consent, and iCloud app-specific credentials through the app UI.

Conversation loading uses a provider-neutral service that merges into the local cache while preserving mailbox sync checkpoints. Account identity, source thread, credential generation, size bounds and cancellation are checked before publication. Gmail and Graph can retrieve conversations after provider recreation. IMAP searches validated message-reference headers with bounded work.

MIME compatibility improvements cover common transfer encodings, character sets, nested content and encoded filenames. Invalid IMAP UID flag records are rejected before deletion inference; warning-only body refresh failures retain prior readable cache content with an explicit notice. Content warnings are separate from original mail. Unsupported message bodies retain usable metadata and do not masquerade as original text.

Formatted HTML is optional alongside the plain-text original. The native WebKit surface uses a nonpersistent store, disables content JavaScript, blocks network/file loads, applies a restrictive Content Security Policy and refuses navigation. Remote images and tracking resources stay blocked. Only explicitly downloaded image attachments can be thumbnailed through ImageIO and substituted for CID references; preview decoding has pixel and output-size limits.

Provider fixture tests cover recovery and compatibility. Credential-backed Gmail/Microsoft/iCloud behavior remains **UNVERIFIED** until a user authenticates a controlled account. No credentials or private mail are included in the test corpus.

Verification included the native Add Account dialog, Demo Inbox/reader navigation, classification acceptance and Undo, archive and Undo, and a Local AI writing preview accepted into the composer. The opt-in WebKit test exercised the production renderer against a working loopback probe: approved inline PNG content rendered while mail scripts, remote/file/data resources, frames and navigation stayed blocked. This caught and fixed a WebKit-specific content-rule syntax error before the phase commit.

The actual Ollama 0.34.0 / `gemma3:4b` integration passed the fictional synchronized-store check for five AI capabilities, all writing styles and cache reuse. This verifies integration, not model accuracy: one school message was classified as Work, and the Concise rewrite retained a grammar error. Model output remains a reviewable suggestion.

Phase gate: Release build succeeded; **205 tests passed, zero failed** (65 XCTest + 140 Swift Testing), with both `FLORA_TEST_LOOPBACK=1` and `FLORA_TEST_WEBKIT=1`. Review found no credential signatures in the project files. Live provider authentication remains unverified.

Primary rendering references: [content JavaScript control](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript), [nonpersistent data stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore), [content rules](https://developer.apple.com/documentation/webkit/wkcontentruleliststore).

## Phase 2 — real mail actions

Implemented explicitly enabled Gmail, Microsoft and iCloud writers behind the shared action coordinator. Read/unread, flag, archive, supported folder moves, server drafts and send require a reviewable proposal and user confirmation. OAuth read-only grants remain the default; Google and Microsoft upgrades require consent. iCloud uses validated TLS IMAP and SMTP STARTTLS, with credentials confined to Keychain.

The coordinator durably journals attempts before network dispatch, binds proposals to current account/message/draft state, validates acknowledgements and blocks retries after ambiguous outcomes. Read/flag Undo issues a real inverse provider operation. Sent messages have no pretend Undo. An acknowledged send remains completed even if targeted iCloud draft cleanup fails, with a visible advisory. SMTP success does not trigger a speculative second Sent-folder upload.

The composer now supports Reply All, Cc/Bcc, controlled attachment imports, local draft recovery, separate server-draft synchronization and confirmed real sending. Attachment bytes are bound to previews by SHA-256; cross-account paths, substitution and size violations fail closed. Recovery cannot overwrite private state when the main store is unreadable. Attachments are currently limited to 2 MiB each and 8 MiB total for consistent provider handling.

Phase gate: Release app built successfully; **284 tests passed, zero failed** (86 XCTest + 198 Swift Testing). This included the real native SMTP transport against trusted and untrusted TLS loopback fixtures, plus OAuth loopback and WebKit checks. Review found no secret signatures in project files. Credential-backed Gmail, Microsoft and iCloud writes remain **UNVERIFIED**. The Mac was locked during the new composer UI verification, so that manual check remains pending.

Follow-up native verification after the Mac became available confirmed the updated composer controls, real local Proofread preview, Replace, Undo Rewrite and the discard confirmation. Only a temporary fictional draft was used and discarded; existing saved drafts were preserved.

## Phase 3 — context and intelligence

Added query-only Local AI search expansion with local ranking, plus an optional source-linked assistant. Retrieval requires explicit account scope and provides at most six relevant 1,500-character excerpts. Structured claims require exact source IDs and quotes; stale source snapshots and cancellations cannot publish answers. Off/unavailable modes preserve text search. This is query expansion, not a local embedding index; matching a quote verifies provenance, not the truth of every paraphrase.

Today now explains priority through mail metadata, conservative English text rules and correctly labeled generated evidence, with direct source links, reply/deadline cues, low-priority updates and bounded coverage. Optional category learning derives suggestions from consistent user-confirmed choices for one sender/account. Conflicting corrections suspend a pattern; deleted categories are never recreated. Suggestions still require acceptance. Historical examples whose provider IDs changed and no longer resolve in the cache are excluded.

The reusable Personal Context Layer offers exact-sender Contacts lookups and bounded Calendar conflict checks. OS access is requested only through explicit settings buttons. Meeting dates remain tentative, relative dates use the original message date, and users can review a date/time before checking. Missing/partial/denied context never claims availability. Context stays in memory and is not automatically supplied to AI; no Calendar or Contacts writes are implemented.

Phase gate: **345 tests passed, zero failed** (103 XCTest + 242 Swift Testing), including native OAuth, safe WebKit and SMTP TLS tests. The actual Ollama 0.34.0 / gemma3:4b run passed query expansion, scoped retrieval and cited answer validation using the fictional synchronized fixture. Live account authentication, private-mail inference and native Calendar/Contacts grants remain **UNVERIFIED**.

Native review exercised the explained Today dashboard, actual local assistant answer, citation navigation to the correct original, and Personal Context with permissions still unrequested. The app showed unknown calendar availability and did not open OS consent prompts. Dark appearance rendered correctly. Review also removed repeated dashboard computation and aligned disclosure content. Final phase counts below include the resulting regression coverage.

Final Phase 3 gate: Release build succeeded; **349 tests passed, zero failed** (103 XCTest + 246 Swift Testing), including the preset-search and conditional-update regressions.
