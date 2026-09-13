# Flora Mail

A runnable macOS research prototype for **Designing for Intelligence: A Human-Guided Framework for AI-Augmented Applications**. Built with Swift 6 and SwiftUI, with a complete demo mail workflow, Gmail/Microsoft/iCloud account adapters with explicit mail-action permissions, and real on-device inference through Ollama.

## Launch

Requires macOS 14 or later and Xcode with a Swift 6 toolchain. Demo mode needs no accounts, API keys, Internet connection, model installation, or third-party Swift packages. Local AI optionally connects to an installed local Ollama runtime.

From this project folder:

```sh
./Scripts/build-app.sh
open "build/Flora Mail.app"
```

The build script produces a locally ad-hoc-signed `.app`. It is a development build, not a notarized distribution. The bundled binary targets the Mac on which it is built.

For Xcode development, open `Package.swift`, choose the **FloraMail** executable scheme and **My Mac**, then Run. The project is a Swift package; a separate `.xcodeproj` is unnecessary. Command-line development also works with `swift run FloraMail`.

## Try the demo milestone

1. On a fresh Demo Mode launch, open **Today**, a structured Daily Briefing of the fictional inbox.
2. Open **Inbox**, then Professor Elaine Lin’s **PHYS 204 · Assignment deadline extended**.
3. Read **At a glance**, explicitly labeled as generated mock/demo output. **Show Supporting Quotes** exposes exact evidence.
4. Click **Show Original Email** to read the complete message and quoted conversation.
5. Click **Accept School**. This confirms a local classification and records the action.
6. Use the toolbar **Archive** button. The email leaves Inbox.
7. Click **Undo** in the status bar. The message returns with its earlier state.
8. Open **Drafts → Edit Draft** for the saved reply to John. The body contains “Yes I can meeting tomorrow.”
9. Choose **Proofread → Preview**. The composer stays unchanged while the suggested text is shown.
10. Click **Replace** to accept “Yes, I can meet tomorrow.” **Undo Rewrite** restores the prior text. **Save Draft** persists your edits.

You can also open a blank composer with **⌘N**, reply/forward from a message, or choose a quick reply idea. **Send Demo** requires a second preview and confirmation and creates a local Sent record only. No email is transmitted.

## Implemented

- Native, resizable sidebar, message list and reader; Today dashboard; light/dark appearance; text selection, accessibility labels, keyboard navigation and context menus.
- Conventional mail destinations plus Important, user-owned categories and two demo accounts; 16 realistic fictional messages, conversation links, and a saved draft. Connected real accounts and provider folders appear separately from Demo Mode.
- Conventional search within the current mailbox, plus optional local query expansion and ranked local matching. Search failures return to text matching.
- Demo compose/send, saved drafts, reply, forward, flag, explicit read/unread, archive, reversible Trash, and move back to Inbox. Category creation/rename/removal and local classification remain user-controlled. Real accounts support confirmed read/flag changes, archive, move, draft synchronization and sending after explicit permission. Reply All, Cc/Bcc and bounded composer attachments use the normal composer.
- Embedded source-backed summaries, classification suggestions, action extraction, smart replies and writing previews through either `MockAIProvider` or real `LocalAIProvider`.
- Local AI settings with saved model/loopback endpoint, connection test, timeout, cancellation, cache clearing and visible unavailable states.
- Persistent capability caches keyed by source content, capability, model digest, endpoint and prompt version. Draft rewrites are deliberately not cached.
- Optional read-only assistant with bounded retrieval and source-linked answers, plus explained priority signals in Today. No chat requirement for mail controls.
- Centralized permission checking, transactional local changes, confirmed remote actions, durable send/outcome history, real read/flag inverse operations and session-only local Undo.
- Versioned atomic JSON persistence for account metadata, messages, categories, drafts, preferences, summaries, classifications, rules and action history.
- `AIProvider`, `MailProvider`, `ReadOnlyMailProvider`, `CredentialStore` and `MailRepository` abstractions. Account settings, cancellable bounded sync, persistent checkpoints, offline browsing, safe MIME/HTML-to-text decoding, and requested attachment downloads. Rule authorization and scope checks remain confined to Demo accounts; no automation scheduler or rule editor is enabled.

## Demo and Local AI modes

`DemoMailProvider` operates on fictional local data. `MockAIProvider` uses deterministic extraction, keyword matching, a small synonym map and text substitutions. It is not a language model, embedding engine, or adaptive classifier. Its search and generated answers are explicitly labeled Demo AI.

`LocalAIProvider` performs real inference through Ollama's structured chat API. It never substitutes mock responses or cloud inference. The default mode remains Demo AI; select **Local AI** explicitly to use a model. **Off** keeps the traditional interface available.

## Connect a real account

1. Use **Add Account** in the toolbar or **Settings → Accounts → Add Account** and choose **Google**, **Microsoft Outlook**, or **iCloud Mail**.
2. For Google/Microsoft, enter or import your registered native application's public client ID, then complete sign-in in the system browser. For iCloud, enter the mail address and an Apple-generated app-specific password in the secure field.
3. After connection, Flora retrieves a recent batch into its local store and switches the mail view out of Demo Mode. Browse the account or its folders and open a cached message.
4. Use **Sync Now**, **Load Next Batch**, or **Cancel Sync** in Accounts settings. The **Sync Limits** section controls the recent window and batch limit. The defaults are 30 days, up to 200 messages per run, and an internal page size of 50.
5. If a saved provider checkpoint expires, **Restart Recent Sync** starts a fresh bounded pass while preserving cached messages. Reauthenticate when authorization expires or is revoked.
6. Open a synchronized message with **Local AI** selected to request assistance from the existing local provider. Accepted categories are local Flora assignments and do not alter server labels or folders.

Accounts start read-only. **Allow mailbox changes and sending**, or **Enable Mailbox Actions** in Accounts, is explicit permission to request Gmail `gmail.modify` (including send) or Microsoft `Mail.ReadWrite` + `Mail.Send`. Read-only requests remain `gmail.readonly` or delegated `Mail.Read`; Microsoft also uses `User.Read` for identity and `offline_access` for refresh. iCloud uses TLS IMAP and STARTTLS SMTP with an app-specific password; Flora never requests the primary Apple Account password. All secrets are stored in macOS Keychain. Google/Microsoft registration and consent requirements are described in [provider setup](Docs/ProviderSetup.md); iCloud protocol and setup details are in [iCloud notes](Docs/iCloud.md).

**Demo Mode** selects fictional versus real mail. **Demo AI / Local AI / Off** independently selects assistance. No real account is required to launch or demonstrate the application. Disconnecting removes this device's saved credentials, preserves cached mail, and does not revoke provider-side consent.

Opening a message never changes its read state automatically. Real mail actions require an account permission and an exact confirmation preview. **Save Draft** stays local; **Sync Draft** explicitly updates the provider. Attachments are copied into controlled local storage (2 MiB each, 8 MiB total) and their hashes bind the reviewed content. Local drafts, classifications and AI caches remain available offline. The GUI displays cached conversations and can explicitly load more through each provider. HTML has a plain-text fallback and an optional isolated formatted view; scripts, remote images, tracking resources and navigation are blocked. Downloaded image attachments can be explicitly previewed and included in CID locations.

The connection/sync code is implemented and covered by fake-provider tests. **Live Gmail, Microsoft, and iCloud authentication has not been verified in this environment because account credentials/application registrations were unavailable.** Consequently, Local AI over a live retrieved user's message remains unverified; the same normalized-message path is used by tests and Demo mail.

## Use Local AI

1. Start an installed **Ollama 0.34.0 or later** service with an on-device model available.
2. Open **Settings → Local AI**. The defaults are `gemma3:4b` and `http://127.0.0.1:11434`.
3. If needed, change the model or advanced endpoint, then **Save Configuration**.
4. Click **Test Connection**. This checks the runtime/model without sending email content.
5. Select **Local AI** in the Provider picker. Open an uncategorized inbox message, such as Maya Chen's design review, to see a real summary, classification, actions and reply ideas.
6. Use the normal composer and select **Proofread**, **Professional**, **Friendly**, **Concise**, or **Rewrite**; review the generated preview before Replace/Insert.

Verified here with **Ollama 0.34.0 + gemma3:4b (Q4_K_M)** already installed on this Mac. Flora does not start/stop runtimes, download models, or change Ollama's global configuration. Other compatible installed models can be selected but have not been evaluated for output quality.

Flora checks local model metadata and forces the runtime's `:local` selector on every inference request. Remote endpoints, cloud models, redirects, proxies, cookies and URL caching are blocked. Older runtimes lacking that local-only contract are rejected. See [Local AI privacy and runtime details](Docs/LocalAI.md).

A stopped service, missing model, timeout, cancelled request, invalid JSON or unsupported response leaves the original email and normal composer usable. Semantic search sends only the query to the model for expansion, then ranks scoped cached mail locally. Assistant answers use at most six relevant excerpts of 1,500 characters each; every displayed claim cites a validated original quote. This is query expansion, not an embedding index, and quote validation does not prove a paraphrase is correct.

Optional Personal Context checks use native Calendar and Contacts after explicit macOS permission. A check reads the selected sender and a reviewed meeting interval only, stores results in memory, and never supplies them to AI automatically. Category learning can be enabled in Settings; two consistent confirmed choices for one sender/account establish a reviewable suggestion. Whole-thread generated summaries, research-mode switching and evaluation telemetry remain deferred. Formatted HTML supports a restricted subset of mail presentation; encrypted content and universal layout fidelity are not supported. MIME and HTML are decoded into safe text; attachment metadata is synchronized and files download only on request. Demo attachment rows remain fixture metadata. No interaction metrics or message contents are collected for telemetry.

## Data and Undo

Mail data lives at `~/Library/Application Support/FloraMail/demo-store.json`; the existing filename now contains both demo records and synchronized real mail, isolated by account identity. Versioned AI capability results live beside it in `ai-cache.json`, and requested downloads live under `Attachments/`. Tokens/passwords are in Keychain; the mail store retains only credential references and public OAuth client IDs. Existing stores migrate optional account/sync/configuration fields without reseeding or discarding earlier data. Fixtures are seeded only when the store does not exist; their dates are anchored to that first launch. Data survives rebuilding and reopening the app. The versioned repository rejects corrupt or unsupported stores without overwriting them, then the app visibly uses temporary in-memory demo data for that session.

Local Mail Undo is available through the status bar, Activity, or **⌥⌘Z**. Remote read/flag changes offer **Preview Undo** in Activity when their acknowledged state still matches; this calls the provider with an inverse operation. Sends, archive and move have no automatic remote Undo. It restores changes in reverse order during the current session and preserves unrelated AI caches and preferences. Action history survives relaunch; inverse operations do not. Standard text editing uses **⌘Z**. No permanent deletion is exposed.

For a demo-only installation, quit and move `demo-store.json` to a backup location to start with fresh fixtures. Once real accounts are connected, preserve the store: it contains cached real mail, classifications, and account metadata. Disconnect accounts through Settings before replacing their metadata. Mail/cache JSON files are local, protected with restrictive file permissions, and not an encrypted production database.

Unsaved composer edits have a separate, debounced `composer-recovery.json` copy. A restart offers Review or Discard without replacing saved drafts. Remote writes journal their intent before networking. An ambiguous send/draft outcome remains blocked across restart; **Activity → Review Outcome** records the user's explicit check of the provider. No blind network retry or duplicate send is attempted.

## Validation

```sh
./Scripts/test.sh
```

Verified on Apple Silicon, macOS 26, Xcode 26.6 / Swift 6.3.3:

- Debug application and release `.app` builds succeed.
- The test suite covers permissions, state transitions, repository/AppModel restarts, category order, automation scope, local transport privacy, malformed model responses, grounded quotes, cache boundaries, cancellation, late-result rejection and unsaved draft recovery. Read-only account tests add OAuth scope/state/refresh validation, secure credential references, provider mappings, account isolation, initial/incremental pagination, deletion-versus-move handling, bounded sync, partial failures, safe MIME content and blocked real mutations. The final suite passes 161 tests with the optional loopback callback check enabled. Tests use fictional transports and do not need account credentials or a running model; see the verification record for commands and limits.
- Real `gemma3:4b` inference passed summary, classification, action extraction, smart replies and all five writing tools through the actual application providers and validators. Repeating the summary reused its cached result.
- In the previous iteration, the native demo and real Local AI flows over fictional mail were exercised through the running UI: original/summary comparison, classification acceptance, Archive/Undo, smart reply insertion and accepted proofreading. Custom categories, accepted classifications, saved rewrites and provider settings survived restart.
- Previous native verification of an unreachable loopback runtime produced visible reader/composer errors while preserving original mail and draft text. Demo AI and Off mode remained usable. Session-only Undo is intentionally unavailable after restart; durable history remains.
- The native Quit prompt was exercised in the previous iteration: Keep Editing restored the exact unsaved text and a second Quit still requested a decision. Configuration notices do not offer Undo for an unrelated prior mail action.
- Info.plist and ad-hoc code-signature checks pass.

Run the optional **real** local provider check with fictional fixtures (no mail store mutations):

```sh
swift run FloraLocalAICheck
# Or choose another installed model:
swift run FloraLocalAICheck gemma3:4b
# Verify fictional read-only sync, JSON reload, and actual Local AI:
swift run FloraLocalAICheck --synchronized-fixture
```

This is a live integration check, separate from the hermetic test suite. It requires the configured loopback Ollama service and never downloads a model. Results and confidence are generated predictions; exact quote validation confirms provenance, not the semantic truth of every paraphrase.

Automated XCUITest coverage, Intel hardware, macOS 14 runtime, comprehensive VoiceOver operation and credential-dependent live mail service integration remain unverified. The deployment minimum is macOS 14; actual runtime testing was on macOS 26. The draft-aware Quit flow uses a SwiftUI API available in macOS 15.4 and later. On earlier systems, save or close the composer before quitting. Force-quitting cannot preserve edits that were never saved.

The current account iteration’s build, test and verification limits are recorded in [verification notes](Docs/Verification.md).

See [architecture notes](Docs/Architecture.md) for the reasoning/execution boundary and extension points.
