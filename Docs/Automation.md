# Explicit automation in Flora Mail

Automation runs only from **Run Now** in the application. Launching Flora, opening Settings, synchronizing mail, receiving a message, and generating an AI suggestion do not start a rule. There is no scheduler or background agent.

Rules are restricted to one account, one exact sender address, cached Inbox messages older than the chosen number of days, and a bounded maximum count. The implemented actions are **Archive** and **Mark read**. They do not send messages, create drafts, delete mail permanently, or create calendar events. Real accounts also require the existing, separately authorized mailbox write access; a rule does not upgrade OAuth scopes or restore revoked account permission.

## Reviewing and authorizing

1. Choose the automation level explicitly. Manual, Information and Suggestions do not permit rule execution.
2. Define the account, sender, age, maximum count, action and expiry. Review the scope before enabling the rule.
3. Preview the matching messages. This captures the displayed messages and a fingerprint of the full matching candidate set. The preview does not mutate mail.
4. At **Approved rules** (Level 3), an enabled, unexpired reusable rule permits this scoped run. At **Narrow delegation** (Level 4), separately authorize the exact preview for one run of at most ten messages, expiring within one hour. Authorization does not start the run.
5. Choose **Run Now**. Changing the rule, permissions, matching messages or grant can invalidate the preview or stop further dispatches. Re-preview after changes; the app never substitutes newly arrived mail into a running batch.

A Level 4 rule remains delegation-only after lowering the global level. A consumed or revoked one-run grant cannot be reused. Changing a preview clears the controller's selected grant; it does not invent a replacement authorization. Saved grants remain inspectable and revocable until expiry.

## Execution and history

`AutomationController` is a presentation layer in `FloraMail/Automation`. It depends on the shared executor and account controller, and has no AI-provider or inference-runtime dependency. `AutomationCoordinator` owns validation and the durable run journal. Only it can issue a single-message `AuthorizedAutomationDispatch` capability.

For Demo mail, the capability goes through `ActionExecutor.executeAutomation`. For real mail, `AccountController.executeAutomation` acquires the account's existing write lock, cancels and awaits current synchronization/download/thread requests, and calls `RemoteActionCoordinator.executeAutomation`. The normal manual-confirmation method is not used to bypass automation policy. The writer still receives the existing validated remote-action capability, and provider-specific networking stays outside the controller.

The grant is consumed and the run journal is saved before the first callback. A failed local save blocks subsequent dispatch. Each message is revalidated before its action begins. Acknowledged changes are recorded separately from failed or uncertain actions. Rule history shows the account, rule, exact selected IDs, completed count, action references and recovery guidance; it is ordinary local application data, not the content-free research metrics export.

**Cancel** keeps the UI busy while an in-flight provider response resolves, then prevents later messages from being submitted. **Revoke** remains available during a run and prevents later actions under that authorization. Neither control claims to retract a request already submitted to a server. Partial completion remains visible. Unknown outcomes require account review; the controller never retries automatically.

Demo read/archive changes retain the existing local Undo behavior. Real read changes retain the gateway's acknowledged inverse operation when available. An archive may not have a reliable inverse destination, so there is no fabricated server Undo.

## Verification boundary

Automation controller tests use fictional accounts and injected providers. They exercise preview-only behavior, account isolation, Demo compatibility, the central real-action gateway, local-storage failures, permission changes, one-run grants, cancellation, revocation, uncertain outcomes and synchronization serialization. They do not authenticate a provider, send external mail, or mutate a live mailbox. Credential-backed automation remains unverified unless a user explicitly authorizes a controlled live test.
