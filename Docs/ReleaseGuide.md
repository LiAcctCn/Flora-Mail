# Flora Mail 0.2.0 — first testable release

This is a preview release for manual checkout, not a production-verified mail client. Gmail, Microsoft and iCloud adapters are implemented and fixture-tested; live sign-in, synchronization and mailbox actions still require verification with accounts you control.

## Open the application

1. Expand **Flora-Mail-Release.zip** in Finder.
2. Move **Flora Mail.app** to Applications or another folder you own, and open it.
3. Start with **Demo Mode**. The fictional mailbox needs no credentials, model or network connection. A fresh installation uses **Flora Hybrid**, **Level 2 · Suggestions**, **Demo AI**, and research recording **Off**.

The packaged build is for Apple Silicon and requires macOS 14 or later. It was tested on macOS 26.6 with Swift 6.3.3. It is locally ad hoc signed, without Developer ID signing or notarization; macOS may block a downloaded copy. Do not disable system security. A trusted local development build is available from the source while Developer ID distribution remains unavailable. Intel and macOS 14 runtime behavior have not been verified.

Normal mail operation uses the native interface and does not require Terminal commands. Building from source and setting up an optional model runtime are separate development/setup tasks.

## Connect an account

Choose **Add Account** in the toolbar or **Settings → Accounts**. Google and Microsoft require your registered native application's public client ID, entered or imported in the form, followed by browser sign-in and consent. This release does not ship a shared production OAuth registration. See **Docs/ProviderSetup.md** in the repository for exact registration settings.

For iCloud, enter the mail address and an Apple-generated app-specific password in Flora's secure field. Do not use your primary Apple Account password or paste credentials into chat. Flora stores credentials in macOS Keychain.

Accounts start read-only. Initial synchronization retrieves a bounded recent window into the local cache. Use **Sync Now**, **Load Next Batch**, **Cancel Sync**, or **Restart Recent Sync** in Accounts. Cached mail remains available offline. **Demo Mode** switches the visible mailbox between fictional and real accounts.

To test real actions, explicitly enable mailbox changes and sending for the controlled account and complete any provider consent. Review each exact action preview before confirmation. **Save Draft** stays local; **Sync Draft** writes a provider draft. **Send** requires a separate confirmation. Use **Activity** to inspect outcomes. Never blindly retry an uncertain send; check the provider before resolving it. Read/flag Undo performs a real inverse operation; send, archive and move have no automatic remote Undo.

## Local intelligence

Demo AI is deterministic demonstration logic and is labeled accordingly. **Settings → Local AI** can connect to an already installed Ollama 0.34.0+ runtime and an on-device model; this release was exercised with **gemma3:4b**. **Test Connection** sends no email content. Select **Local AI** to use inference, or **Off** to continue with normal mail controls.

Summaries, categories, extracted actions, smart replies, writing previews, query expansion and source-linked assistant answers use bounded task-specific context. There is no cloud fallback. Model output can be wrong or rejected by validation; original mail and draft text remain available. Accept writing previews explicitly with Replace/Insert. Category acceptance stays local. Semantic search uses local query expansion and ranking, not an embedding index.

Calendar and Contacts context require optional macOS permission through Settings. Checks are limited to the selected sender and a reviewed time interval, remain in memory, and create no events or contacts.

## Automation and research

Levels 3 and 4 do not grant permission by themselves. Define an expiring, exact account/sender/Inbox-age scope for Archive or Mark read, preview its batch and choose **Run Now**. Level 4 also needs a short-lived, one-run approval for the exact messages. No rule sends mail or runs in the background. Revoke and Cancel prevent subsequent dispatches; they cannot retract a request already submitted.

Research Settings provides Traditional, Chat First and Flora Hybrid conditions. Recording is a separate default-off opt-in with local export/clear and explicit task timers. Metrics contain fixed events and durations, never mail content, account IDs, queries or credentials. No participant results or study conclusions are included.

## Storage and current limits

Existing mail, categories, saved drafts and preferences are preserved on upgrade. The local store migrates to schema 2 to retain automation grants and journals. The older v0.1.0 app cannot read that upgraded store; preserve a backup before attempting a downgrade. Do not replace a connected account's store with demo fixtures.

The prototype uses bounded atomic JSON storage rather than a high-volume encrypted mail database. Outgoing attachments are limited to 2 MiB each / 8 MiB total. Formatted HTML blocks scripts, navigation and remote tracking; encrypted mail and universal layout fidelity are not supported. Calendar/Contacts permission behavior, Intel, macOS 14, full accessibility coverage and live provider behavior still need manual verification.

The current phase gates and exact verification limits are in **Docs/RoadmapProgress.md**. This release concludes the implementation iteration; the next step is controlled manual account checkout, not further autonomous feature development.
