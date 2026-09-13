# Architecture and prototype boundaries

## Module layout

```text
Sources/
  FloraCore/                 SwiftUI-independent domain and services
    Domain/                  Provider-neutral mail/account IDs, state and Codable values
    Data/                    Repository, atomic JSON storage, demo fixtures
    Mail/                    Demo/REST/IMAP providers, MIME decoder, sync contracts/coordinator
    Accounts/                OAuth/PKCE and replaceable Keychain credential service
    AI/                      Providers, local transport, versioned prompts, parser, capability cache
    Automation/              Permission policy and action executor
  FloraMail/
    App/                     Composition root, observable model, navigation
    Accounts/                Account controller, browser callback, attachment storage
    Features/                Today, reader, composer, categories, settings, activity, assistant
    SharedUI/                Native colors and small reusable views
Tests/FloraCoreTests/        Domain and fake-transport tests, no model dependency
Tests/FloraMailTests/        AppModel restart, async cancellation and fallback tests
Tools/LocalAICheck/          Opt-in real inference using fictional fixtures
```

The SwiftUI application is the composition root. `AppModel` owns the repository-backed `ActionExecutor` and selected AI provider, exposes committed snapshots, and coordinates async assistance. Views keep presentation state; they do not access files or provider APIs. The account controller coordinates browser authentication, provider-independent sync, and requested attachment downloads. Remote mail clients use TLS to the selected provider; the separate LocalModelClient only performs on-device inference over loopback. No cloud AI provider or third-party Swift dependency is included.

`MailProvider` retains account/folder/message/thread reads and its existing proposed-action gateway. `DemoMailProvider` wraps only demo-account records in the same executor used by the app, avoiding duplicate mutable stores. Real adapters conform to `ReadOnlyMailProvider`; their action gateway rejects every mutation. Provider JSON/MIME/IMAP types terminate at the mapping layer. The synchronized local repository remains the GUI’s source of truth, including while offline.

## Account and sync flow

```text
Accounts settings → AccountController → browser OAuth / Keychain / IMAP authentication
                                      ↓
GmailMailProvider / MicrosoftMailProvider / ICloudMailProvider
                                      ↓
MailSyncCoordinator → normalized page + checkpoint → ActionExecutor → MailRepository
                                                                    ↓
                                                              AppModel → SwiftUI
                                                                    ↓
                                                    selected normalized content → AIProvider
```

`MailAccount` separates local account identity, provider subject identity, provider type, public OAuth client ID, credential reference, status, and sync state. Deterministic message/thread/attachment IDs namespace remote IDs by account ID. Gmail's many-to-many label IDs and IMAP/Microsoft folder IDs are retained alongside conventional GUI folder roles. `isImportant` and `isFlagged` are distinct. Legacy demo snapshots decode with defaults and retain all existing fixture IDs and user edits.

`AccountController` owns connection, sync, and download tasks. OAuth uses a temporary loopback listener and the system browser with PKCE S256 and random state; callback origin/path/state and expiry are validated before exchanging a code. Google uses the supported Desktop client with `gmail.readonly`. Microsoft uses the public-client `common` authority with `Mail.Read`, `User.Read`, and `offline_access`. iCloud uses TLS IMAP and an app-specific password. `KeychainCredentialStore` stores secret bytes; normal account persistence holds only references. Reauthentication validates the newly authenticated identity before replacing an existing account's credential reference. See [provider setup](ProviderSetup.md) and [iCloud implementation](iCloud.md).

Synchronization is explicit and cancellable. Defaults retrieve a 30-day window, at most 200 normalized messages per run, with pages of 50. Settings clamp their limits; the coordinator also caps empty pages to bound work. Initial date windows are preserved across provider page continuations. Every page and its checkpoint commit atomically, preventing a checkpoint from advancing ahead of local mail. Deduplication uses account plus provider message ID. Partial failures preserve earlier committed pages, and cancellation prevents late responses from publishing into disconnected accounts.

Gmail uses history IDs after its paginated initial pass. Microsoft maintains delta links per folder and requests immutable IDs; a folder-removal event is resolved against the mailbox before local deletion because it may represent a move. IMAP maintains UIDVALIDITY/UID checkpoints and refreshes flags/deletions for the newest 500 known UIDs per folder; protocol details and remaining limitations are documented separately. Expired checkpoints surface **Restart Recent Sync**, which preserves cached messages and resets only the provider cursor. Sync status, last success, account metadata, checkpoints, and folder descriptors persist. Loading indicators, current selections and running task handles do not.

Demo Mode filters fictional versus real accounts. Account/folder selection scopes message search, assistant input, and briefing candidates; individual AI requests receive only their selected message context. A real-mail Daily Briefing requires an explicit Generate Briefing action and processes at most 20 recent candidates individually. Turning off AI or losing the network leaves cached mail usable. Disconnect removes local credentials and preserves cached mail; provider-side OAuth consent is managed through the provider's security controls.

## Reasoning is separate from authority

```text
Immutable message + available categories
    → AIProvider
    → Summary / prediction / reply / rewrite preview
    → Explicit GUI acceptance
    → ProposedAction
    → ActionPermissionPolicy
    → ActionExecutor
    → Repository save
    → Committed state + activity entry + inverse operation
```

AI providers receive values only, with no executor, repository, mail mutation or sending reference. Their protocol has informational outputs only. `ActionRisk` and confirmation requirements are derived from the typed action and origin, not from generated explanation text or a serialized confirmation flag. User-origin controls represent explicit manual commands. AI-origin writes require confirmation; accepting a category validates the exact retained suggestion before executing it.

This is an application architecture boundary, not a sandbox against malicious in-process Swift code. A future model tool layer must construct AI-origin proposals in trusted application code, never permit model output to supply a trusted user origin, and retain the same executor boundary.

Category predictions and confirmed assignments are separate fields. Prediction caching never overwrites a confirmed category. Deleting a category removes assignments and associated predictions; classification receives only the remaining categories. No server label operation exists in the prototype; classification is a local Flora assignment even for synchronized mail. Changes to an existing category invalidate the classification cache context and future prompts receive the current categories. No training or adaptive preference learning is implemented.

Real accounts remain read-only in both provider contracts and `ActionPermissionPolicy`. Sending, archive, trash, move, flag, read/unread and demo automation are rejected for real-account records even with user confirmation. Opening a real message does not mutate its read state. Reply/forward/smart-reply controls populate normal local drafts, whose real-account identity also blocks Demo Send. Category edits, accepted local classifications, draft saves, and generated caches remain permitted local operations.

## Persistence and rollback

Foundation `Codable` plus atomic file replacement remains the prototype repository, now holding bounded real-mail batches as well as demo fixtures. Retaining it preserves the working architecture and keeps the build dependency-free. All storage is behind `MailRepository`, allowing a future SwiftData/SQLite repository without changing views or domain models. This is not an encrypted, high-volume production mail database.

The executor constructs a candidate snapshot, validates it, then saves it before publishing state or recording an inverse operation. A save failure leaves prior state and Undo intact. Corrupt or unsupported schema files are preserved. A visible warning explains any in-memory fallback. Real account connection is disabled in that fallback so credentials and real mail are not attached to a temporary session. The existing `demo-store.json` filename is retained for migration compatibility; it is no longer necessarily demo-only.

Undo tracks affected records and preserves unrelated summaries/preferences generated after a mail action. Removing a sent demo message also removes its summary and classification records from the mail store; separate capability cache entries remain until eviction or explicit cache clearing. Undoing category deletion restores the earlier category and confirmed assignments and prevents later predictions from competing with those assignments. The in-memory inverse stack is intentionally session-only; the durable activity log records that a past action was undone.

Sync imports do not create mail Undo operations: they mirror provider state. Confirmed local category changes retain normal Undo. No real external sending is implemented; the reversible local Sent insertion remains restricted to Demo accounts.

## Async AI behavior

`AIProvider` methods are async and Sendable. Both mock and local adapters check cancellation. The reader cancels work when source message, categories, assignment or provider changes. Writing previews retain their exact source text; Replace/Insert is disabled if the draft has changed. Composer dismissal asks the user to save or discard edits; new-message commands cannot replace an already open composer.

Summary failure keeps the original email visible. Classification failure leaves the confirmed category untouched. Local-provider selection reports unavailable even when a demo summary cache exists. Text search works with AI off or unavailable. There is no silent cloud or mock fallback for summaries; a semantic-search failure explicitly falls back to ordinary text matching.

LocalAIProvider now calls the replaceable LocalModelClient. The Ollama implementation checks version, installed model digest, format/capability and remote metadata before requesting structured chat output with explicit `:local` execution. URLSession is ephemeral, disables proxies/redirects/cookies, and imposes request/resource timeouts and body limits. The runtime is instructed to reject context overflow rather than silently truncate/shift it. User-facing errors never include arbitrary HTTP response bodies.

AIPromptLibrary owns versioned prompts and supported structural schemas. AIResponseParser separately validates exact fields/types/counts, category membership, confidence bounds, output lengths and verbatim evidence. Runtime grammar schemas intentionally omit large string maxLength rules because real Ollama/Gemma verification found those caused grammar initialization failures; the application parser still enforces the full bounds.

CachedAIProvider decorates any provider and uses a separate local cache repository. Keys hash capability, prompt version, runtime/model digest, endpoint namespace and message ID/subject/body/sender; classification also includes all category IDs/names. Source state such as read/flag/folder does not invalidate unchanged content. A model identity change during inference is rejected before caching. Cancellation and fresh app request identities prevent obsolete results from being published even when the mode changes away and back. Invalid cache files fail visibly and can be cleared from Settings.

Cache writes and connections stay outside SwiftUI. Classification persistence is independent of summary persistence so a summary parsing failure cannot prevent a valid classification. Draft previews are never written to the capability cache. Only Save Draft or a confirmed demo send persists draft text. Optional writing context is limited to the selected reply source, with account identity checked in AppModel. Real mail is processed through the same normalized AIProvider interface; network authentication and provider-specific objects never enter AI prompts. See [Local AI details](LocalAI.md) for exact context and known limits.

## Automation scope

The core supports only a narrow Demo-account archive rule: exact sender address, Inbox messages, and an explicit minimum age. A rule must be saved, enabled and authorized; changing/enabling it requires fresh confirmation. A proposal is rejected if any selected message falls outside the persisted rule’s scope or if the operation is not archive. Supplying a rule ID never grants permission to a different action origin.

No rule editor, scheduler, learned authorization, or background automation executes in this milestone. Level 0 (AI off), informational assistance and explicit suggestion acceptance are represented in the interface. Higher delegation levels and comparative research modes remain future work.

## Message and attachment safety

Mail bodies are decoded into inert text. Gmail multipart payloads and iCloud MIME use the shared bounded MIME decoder; Graph supplies normalized text or HTML. HTML is retained as source where available but displayed through an inert text projection, with no browser, script execution, remote image loading, or HTML-import networking. Common character sets, encoded headers, quoted-printable/base64, Unicode and quoted replies are handled; layout fidelity and inline-image display remain deferred.

Attachment metadata is separate from payloads. Requested content is limited to 20 MiB for REST providers; IMAP requires encoded payloads below 25 MiB, and the shared local store enforces a 25 MiB ceiling. Downloads are written under controlled application storage using account/message/attachment identities, with sanitized filenames and relative-path validation. Download state persists only after the file is successfully saved. Demo attachment metadata has no remote payload. Sensitive mail/cache JSON is local and access-restricted, but the prototype does not provide an encrypted high-volume database.

The REST transport allows only fixed official HTTPS hosts, rejects redirects, and avoids disk URL caches/cookies. Authorized mail requests are GET-only; OAuth token exchange/refresh are separately scoped POST operations. IMAP uses TLS, EXAMINE and PEEK reads, with no SMTP or write command path. Controlled errors exclude response bodies and secrets. Fake transports test these boundaries; actual provider login, live mailbox behavior and live-message AI require separate credential-backed verification.

## Further work

1. Verify each live provider with controlled accounts, including expired authorization, large folders, moved/deleted mail, and checkpoint recovery; evaluate Local AI on intentionally selected synchronized messages.
2. Broaden MIME/encoding and model-quality fixture coverage, including long conversations and attachment edge cases.
3. Replace whole-file persistence when mailbox scale warrants indexed storage and incremental updates; add a local embedding index only with explicit account scope.
4. Improve safe HTML layout/inline-image presentation without introducing active content or remote tracking.
5. Consider real provider mutations only in a separately authorized phase, preserving preview, permission checks and accurate action history.
6. Add explicit research configuration and privacy-minimized evaluation instrumentation only after defining the study.
