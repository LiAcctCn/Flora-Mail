# Read-only account iteration — verification record

Verified on 13 September 2026 with Apple Silicon, macOS 26, Xcode 26.6 and Swift 6.3.3.

## Build and tests

- The existing baseline built successfully and passed 94 tests before integration.
- The final debug application/test targets compile. The complete suite passes **161 tests: 51 XCTest tests and 110 Swift Testing tests**, with zero failures or skips when the optional loopback test is enabled.
- The release application builds at `build/Flora Mail.app`. It is a local development build with an ad-hoc signature, not a notarized distribution.
- Test logs: `.build/read-only-final-tests.log`; release log: `.build/read-only-release-build.log`.

```sh
./Scripts/test.sh
# Includes a real local listener, with a fake browser opener and fictional codes:
FLORA_TEST_LOOPBACK=1 ./Scripts/test.sh
./Scripts/build-app.sh
open "build/Flora Mail.app"
```

The listener test requires permission to bind loopback. It verified both Google's `127.0.0.1` callback and Microsoft's `localhost` callback, rejection of unrelated state, successful callback delivery, and cancellation without opening a browser or contacting an account provider. The default suite skips only this opt-in test. A headless callback crash found by this test was fixed.

New coverage includes account namespaces and Demo isolation, provider mapping, OAuth PKCE/state/scopes/refresh, rejected credential scope escalation, bounded initial/incremental pagination, duplicate prevention, moved/deleted mail handling, cancellation and partial failure, persistence/restart, unavailable providers, MIME safety, attachment path containment, and rejection of all real mail mutation origins. Account-controller tests cover delayed Keychain deletion versus reauthentication, preservation of the last committed checkpoint, source-link account scope, and locally saved drafts. Keychain secret payloads are represented by explicit in-memory credentials in the account tests; no actual account secret was used.

## Actual Local AI

The installed **Ollama 0.34.0 / gemma3:4b** ran the real `LocalAIProvider`, response parser and cache after three fictional Gmail-type messages were synchronized in two pages, saved to temporary JSON, and reloaded. This exercises the sync → local store → Local AI path without impersonating an authenticated mailbox.

```sh
swift run FloraLocalAICheck --synchronized-fixture
```

Summary, allowed-category classification, action extraction, smart reply, five writing tools with selected-message context, and repeated-summary cache reuse completed successfully. The final `local-v5` run is recorded in `.build/local-ai-synchronized-v5.log`.

Passing structural validation is not a claim of semantic accuracy. That run incorrectly classified a school assignment as Work with 0.9 confidence, and Concise retained a grammar error. A focused prompt revision removed a reversed-perspective greeting/question from the earlier smart reply. The revised run returned: “Thanks for the update. I need to check my availability before confirming.” Suggestions remain editable and require user acceptance; they cannot execute mail operations.

## Credential-dependent and native UI verification

- **Gmail:** OAuth, refresh, label/message/thread mapping, history sync and requested attachment code implemented; fake transport tests pass. No live sign-in or mailbox sync was attempted because a Google Desktop client registration and account authorization were unavailable.
- **Microsoft:** public-client OAuth, refresh, identity, folders, immutable IDs, per-folder delta, conversations and requested attachments implemented; fake transport tests pass. Personal and work/school account sign-in remain unverified without an app registration and consent.
- **iCloud:** TLS IMAP, app-specific credentials, folder/body/flag reads, UID checkpoints and requested attachments implemented; scripted IMAP/MIME tests pass. No live app-specific password was available, so authenticated iCloud behavior remains unverified.
- **Real-message Local AI:** the synchronized fixture path is verified; inference over an authenticated user's retrieved message is not.
- **Native UI:** computer-use verification could not proceed because the Mac was locked and automatic unlock failed. The new account screens and final native Demo flow were not manually exercised in this iteration. The previous iteration's successful native Demo/Local AI verification is retained separately in README; automated Demo, reader-model, composer, persistence and unavailable-AI regressions pass here.

Existing user/demo storage was not reset or replaced. There is no XCUITest suite; Intel, the macOS 14 runtime and full VoiceOver interaction remain unverified.

## Security and remaining limits

Source/config/test/documentation scans found no apparent real tokens, passwords or private keys, and no credential logging calls. OAuth examples contain public identifier placeholders only. Keychain is the application credential implementation; normal persistence contains opaque references. REST mail requests are GET-only on fixed HTTPS hosts with redirects refused. OAuth exchange/refresh are separate POST operations. IMAP has no write-command or SMTP path and uses TLS with `EXAMINE` / `BODY.PEEK`. HTML is displayed as inert text or literal source, without scripts or remote-resource loading.

The supplied directory has no `.git` repository, so commit-history secret inspection was unavailable. The working source and configuration were scanned; this is not a claim about any absent Git history.

HTML layout and inline-image fidelity are deferred. Conversations contain the locally synchronized portion. IMAP reconciles flags/deletions for up to 500 recent known UIDs per folder. Mail/cache JSON is access-restricted local storage, not an encrypted or high-volume indexed database. Attachment limits vary by provider and are documented in the provider notes. No real sending, archive, delete, move, flag/read changes or autonomous background actions are enabled.

The next phase should validate controlled live accounts and recovery scenarios, broaden real-world MIME coverage, and assess Local AI quality before considering separately authorized write operations.
