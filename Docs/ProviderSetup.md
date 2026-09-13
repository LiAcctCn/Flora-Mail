# Read-only account setup

Flora Mail continues to launch in Demo Mode without authentication. Real accounts require the account owner's interactive sign-in. Gmail and Microsoft also need a native application registration; Flora does not ship a shared production OAuth registration. `Config/Accounts.example.json` describes the public identifiers; it is documentation, not an automatically imported configuration file. Enter the public application ID in **Settings → Accounts → Add Account**.

## Gmail

1. Create a Google Cloud project and enable the Gmail API.
2. Configure the OAuth consent screen. During development, add the account owner as a test user if the application's audience is in Testing.
3. Create an OAuth client with application type **Desktop app**. Copy its public client ID, ending in `.apps.googleusercontent.com`, into Flora's Google account form.
4. Connect. Flora opens the system browser and listens temporarily on `127.0.0.1` at an operating-system-assigned port. The authorization code is exchanged using PKCE S256 and a random state value.

The only requested scope is `https://www.googleapis.com/auth/gmail.readonly`. The authenticated mailbox's address comes from Gmail's profile endpoint, so no extra identity scope is required. Google classifies full read-only Gmail access as a restricted scope; distribution beyond a development/testing audience can require Google's verification process. Google currently documents `client_secret` as optional for native-app code exchange and refresh; Flora uses the public-client PKCE flow and never asks for a client secret.

The adapter retrieves Gmail labels without treating them as exclusive folders. All label IDs, including user labels and `IMPORTANT`, remain on each normalized message. Inbox, Sent, Drafts, and Trash are conventional GUI projections; starred and important remain separate values. Initial sync uses a fixed, bounded recent-date query with page tokens, then Gmail history IDs retrieve changed messages only. A message that disappeared between list and retrieval is skipped. Expired history positions require restarting the recent sync; already cached mail remains available. Full message/thread reads and requested attachment downloads use Gmail's supported APIs.

Official references: [native desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [synchronization](https://developers.google.com/workspace/gmail/api/guides/sync), [history pagination](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list).

## Microsoft Outlook / Microsoft 365

1. Register an application in Microsoft Entra. To support both Outlook.com and Microsoft 365, choose **Accounts in any organizational directory and personal Microsoft accounts**.
2. Configure the **Mobile and desktop applications** platform with loopback redirect **`http://localhost/oauth/callback`**. Flora chooses an available port, which Microsoft ignores when matching a registered localhost redirect. The path must match exactly. The listener itself binds only to `127.0.0.1`; no network-facing listener is opened.
3. Enable the native/public-client configuration. Do not create a confidential web client or application secret for Flora.
4. Add delegated Microsoft Graph permissions `Mail.Read` and `User.Read`. Flora also requests `offline_access` for refresh tokens.
5. Paste the application's public Application (client) ID into Flora's Microsoft account form and connect through the system browser.

`Mail.Read` grants message reading; `User.Read` supplies the signed-in account's ID/display name/mail address. Flora never requests `Mail.ReadWrite`, `Mail.Send`, or application-wide mail permissions. The `common` authorization authority supports personal and work/school accounts, subject to the organization's consent policies. National-cloud Graph endpoints are not included in this prototype.

The adapter discovers conventional and nested folders and uses a separate Graph delta checkpoint for each folder. Every message request asks for immutable IDs. Folder removal events are resolved against the mailbox before removal from the local store, because a move is not a message deletion. A saved continuation URL must remain on the expected `https://graph.microsoft.com/v1.0/me/…` resource. Invalid/expired delta tokens require restarting recent sync. Conversation retrieval uses the conversation ID and pagination, with a 500-message safety bound. The GUI displays the locally synchronized portion of a conversation.

Official references: [native authorization code flow and PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow), [redirect URI restrictions](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url), [message delta](https://learn.microsoft.com/en-us/graph/api/message-delta?view=graph-rest-1.0), [immutable identifiers](https://learn.microsoft.com/en-us/graph/outlook-immutable-id).

## Credential and network boundaries

OAuth access/refresh tokens and iCloud app-specific passwords are stored only through `CredentialStore`, whose application implementation is macOS Keychain. Items are device-local, nonsynchronizing, and available when the login Keychain is unlocked. The normal mail store retains an opaque credential reference and public client ID, never secret bytes. `MemoryCredentialStore` is an explicit hermetic-test implementation. Reauthentication uses a fresh reference, validates account identity, then replaces the old reference so signing into the wrong account does not replace an existing account's credentials.

All REST mail reads use HTTPS to fixed official Google/Microsoft hosts. URLSession redirects are refused, cookies/credential caches/disk response caches are disabled, and bearer tokens appear only in request headers. Token exchange and refresh are the only REST POST operations. The authorized mail reader has no mutation methods. Responses are bounded to 32 MiB; requested attachments are bounded to 20 MiB. Raw response bodies, authorization codes, and token values are never logged or shown in errors. Timeouts and controlled error mapping preserve offline cached mail.

Disconnect removes this device's saved credentials and preserves cached mail. It does not revoke the application's grant at Google or Microsoft. Users can also remove consent through the provider's account security controls.

## Rendering and limits

Plain text, decoded MIME, Unicode, and an inert text projection of HTML are used in the reader and AI context. Original HTML is retained in the local normalized record where supplied, but is never executed in a web view. Scripts, remote images/tracking pixels, and active content are not loaded. Image rendering and arbitrary HTML layout fidelity are intentionally deferred. Text is bounded to 512 KiB per message; unsupported/encrypted formats retain attachment metadata or show an unavailable-body message.

Attachment metadata is synchronized without automatically downloading every file. Gmail full-message responses can already contain small inline MIME data; Flora does not separately download binary attachments during sync. Large text MIME parts needed for the reader may be fetched within the text bound. Microsoft attachment metadata is requested when the message reports attachments or references inline CID content; attachment bytes are fetched only on user request. Downloaded files go through the controlled application attachment store.

## Verification status

The provider/auth code is exercised with fake HTTPS responses and an in-memory credential store. Tests cover mapping, account namespaces, PKCE/state, token refresh, read-only scopes, rejected scope escalation, continuation host restrictions, pagination, history/delta changes, moved-versus-deleted mail, cancellation, and forbidden mutation. A successful test run is not evidence that a real OAuth registration or user's live mailbox has authenticated. Live Gmail, Microsoft, and iCloud results must be reported separately by the iteration's implementation report.
