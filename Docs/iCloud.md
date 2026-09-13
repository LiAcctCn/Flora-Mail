# iCloud Mail read-only adapter

Flora uses Apple's documented incoming server, `imap.mail.me.com`, with implicit TLS on port 993. The server and port are centralized in `IMAPConfiguration`; there is no SMTP implementation or plaintext connection mode. Network.framework performs certificate and hostname verification with a TLS 1.2 minimum.

Connect in **Settings → Accounts → Add Account → iCloud Mail** using the full iCloud Mail address and an **app-specific password** generated in Apple Account settings. The primary Apple Account password must not be entered. Flora checks the generated password's four groups of four letters before writing credentials; that shape check cannot establish which kind of password a user supplied. Custom-domain users should enter the underlying iCloud Mail account address as the sign-in identity. Apple's documentation notes that some clients use only the local username; Flora currently uses the full address, which Apple also supports.

The app-specific password and login username are encoded only as a Keychain credential payload. The ordinary local account record stores an opaque credential reference and public account metadata. Disconnect removes the credential while retaining previously synchronized messages for offline reading. Tests use an explicitly injected in-memory credential store and fictional generated values; the app uses Keychain.

## Reads and synchronization

`ICloudMailProvider` conforms to the same read-only provider protocol as Gmail and Microsoft. It creates a short-lived `IMAPSession` for each bounded page, normalizes values into Flora domain models, and returns them to the shared sync coordinator. The provider never writes the message repository itself.

The command vocabulary contains only capability discovery, login, folder listing, `EXAMINE`, UID search/fetch and logout. It has no `SELECT`, `STORE`, `EXPUNGE`, `APPEND`, `MOVE` or SMTP path. `EXAMINE` opens mailboxes read-only; all content retrieval uses `BODY.PEEK`, so opening or summarizing a message does not mark the server message read.

Initial synchronization searches the configured recent date window, then retrieves newest UIDs first in bounded pages. Each checkpoint contains the account identity, mailbox wire name, UIDVALIDITY and highest retrieved UID. Pending UIDs are saved in the page continuation, and the shared coordinator atomically commits messages with their checkpoint. Interrupted pages can be retried without duplicating committed messages. UIDVALIDITY changes generate a new identity namespace; old cached messages are retained because their relationship to replacement UIDs cannot safely be inferred.

Later syncs search for newer UIDs. For the newest **500 known UIDs per folder**, a metadata-only UID/FLAGS request refreshes read/flag state and confirms removed messages without downloading their bodies again. Older cached messages remain available but their flags/deletions are outside this bounded reconciliation window. Renamed folders are not reconciled across names automatically.

Folder discovery understands `SPECIAL-USE` attributes when the server includes them, common iCloud folder names, and modified UTF-7 display names. Wire mailbox names remain intact for commands and identity. Custom folders remain separately identified even when their conventional Flora role is Archive.

## MIME and attachment handling

For each message Flora requests selected headers and `BODYSTRUCTURE`. Multipart structure is traversed within depth and count limits. Plain text is preferred; HTML-only mail is projected to inert text. Scripts, styles, document headers, embedded frames and other non-content markup are removed. No email is loaded into a WebView, JavaScript engine or HTML attributed-string importer. Images, tracking URLs and other remote resources are not fetched.

The MIME utilities handle UTF-8 and platform-supported character sets, RFC 2047 encoded headers, quoted-printable and base64, folded headers, common address/date formats and single extended RFC 2231 filename parameters. Inline and other attachment metadata includes MIME type, filename, content ID, section and download state. IMAP attachment byte counts are estimated from the transfer-encoded size when base64 is used.

Only selected text sections are fetched automatically, with a combined 512 KiB encoded preview budget and at most 20 text parts. Oversized previews carry a truncation notice. Attachments are fetched only on a user download request, capped at 25 MiB encoded content, using `BODY.PEEK`. The shared attachment service saves the result under its controlled local storage directory. Inline images are listed as attachments; they are not automatically displayed.

Encrypted mail, unusual `message/rfc822` nesting, multipart selection semantics beyond ordinary text alternatives, continued RFC 2231 parameters, and complete graphical HTML fidelity are not implemented. Unsupported structures produce a recoverable sync/preview error. No unsupported MIME is executed.

## Protocol boundaries and validation

Authentication and mailbox names are quoted with escaping and reject control characters. UID and part selectors are numeric validated values, never raw commands assembled from mail content. The response reader honors exact octet counts for literals, so a literal containing a fake command completion cannot end a request. Parser nesting, token counts, line length, literal length and total response size are bounded. Each command has an overall timeout; cancellation closes the socket and prevents a page commit. Server error text is not copied into logs or UI errors.

Automated tests inject IMAP transcript responses and cover folders, encoded MIME, command injection, literal framing, initial and incremental pages, stable identity, UIDVALIDITY changes, flags/deletions, on-demand attachments, missing credentials, partial failures and cancellation. The TLS transport has been compiled on Apple Silicon macOS, but authenticated iCloud interoperability remains unverified until a user supplies an app-specific password through the UI. No real or guessed credentials were used during development.

Sources: [Apple's iCloud Mail server settings](https://support.apple.com/en-us/102525), [Apple app-specific passwords](https://support.apple.com/en-us/102654), [IMAP4rev1 / RFC 3501](https://www.rfc-editor.org/rfc/rfc3501), [IMAP4rev2 / RFC 9051](https://www.rfc-editor.org/rfc/rfc9051), [MIME media types / RFC 2046](https://www.rfc-editor.org/rfc/rfc2046), [encoded headers / RFC 2047](https://www.rfc-editor.org/rfc/rfc2047), [extended MIME parameters / RFC 2231](https://www.rfc-editor.org/rfc/rfc2231).
