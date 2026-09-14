# Flora Mail v0.2.0 — first testable preview

This release packages the four development milestones as a local-first macOS mail prototype. It is a **preview for controlled manual checkout**, not a claim of live-provider or production validation.

## Included

- Gmail, Microsoft Outlook / Microsoft 365 and iCloud adapters, secure credential references, bounded incremental synchronization and offline cached mail.
- Safer MIME/HTML rendering, explicit attachment downloads and provider-neutral conversations.
- Confirmed mailbox read/flag/archive/move actions, local and server drafts, Reply All, Forward, composer attachments and sending through the centralized action gateway.
- Local summaries, classification, extracted actions, smart replies, writing previews, query expansion and a source-linked assistant. No cloud inference fallback.
- Explained Daily Briefing, optional category learning and read-only Calendar/Contacts context.
- Explicit automation levels, scoped Run Now rules, expiring one-run grants, revocation and durable history.
- Traditional, Chat First and Flora Hybrid research modes with optional local metrics. No study participants or results are fabricated.

The separate phase commits were built, tested and pushed in order:

| Phase | Commit |
| --- | --- |
| Account / MIME compatibility | `6451671` |
| Provider-backed mail actions | `590a930` |
| Context and intelligence | `b04384c` |
| Automation and research | `2fe49d9` |

## Verification and limits

Final automated gate: **422 tests passed, zero failed** (130 XCTest + 292 Swift Testing). Stabilization fixes preserve dirty editor state through Quit, clear recovery only after an explicit close decision, prevent unresolved recovery from being overwritten, and retain strict attachment checks when optional MIME metadata lookup fails.

The final Release build succeeded. Native checks covered the demo workflow, local writing/assistant results, Traditional and Chat First views, light/dark appearance, window resizing, keyboard Inbox navigation, and Quit Keep Editing/Discard with a clean restart. Native Save-on-Quit is covered by automated persistence tests rather than a new manual run.

The automated suites use fictional mail, injected credentials and provider fixtures. Optional native checks exercise OAuth loopback callbacks, WebKit content isolation and trusted/untrusted SMTP TLS. Actual local inference was exercised using Ollama 0.34.0 and gemma3:4b, including a fictional synchronized-store reload and cited assistant answers. These checks do not prove model accuracy or live provider behavior.

**Live Gmail, Microsoft and iCloud sign-in, synchronization and writes remain UNVERIFIED.** Google/Microsoft require a registered native public client ID and interactive consent; iCloud requires an app-specific password entered in Flora. The package does not ship a shared production OAuth registration. Calendar/Contacts permissions also remain unverified.

The build is **Apple Silicon, macOS 14+**, locally ad hoc signed. Developer ID signing and notarization are unavailable; downloaded copies may be blocked by macOS. Actual runtime testing used macOS 26.6. Intel, macOS 14, comprehensive VoiceOver operation and automated native UI coverage remain unverified.

Storage is a bounded atomic JSON prototype, not an encrypted high-volume mail database. Outgoing attachments are limited to 2 MiB each / 8 MiB total. Encrypted mail and universal HTML fidelity are unsupported. Semantic search uses query expansion and local ranking, not embeddings. Automation runs only on explicit Run Now; there is no background scheduler. Sends have no fake Undo or blind retry.

The existing `v0.1.0` tag is preserved. This version migrates local mail storage to schema 2 to protect automation journals and consumed grants; the old binary cannot read that upgraded store.

## Download and first use

Expand **Flora-Mail-Release.zip**, then open **Flora Mail.app**. The archive includes **Read Me.txt** and the build revision. Demo Mode works without credentials or model installation. Normal operation uses the native GUI; see [the first-use guide](ReleaseGuide.md).

Development stops at this release for manual checkout. The next phase is controlled live-account verification, consent/permission testing and model-quality evaluation before wider distribution.
