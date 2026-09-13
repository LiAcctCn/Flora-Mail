# Research conditions and optional local interaction metrics

Flora Mail is an implementation prototype for *Designing for Intelligence: A Human-Guided Framework for AI-Augmented Applications*. The research controls support demonstrations and later study preparation. They are not participant results, a validated experimental protocol, or evidence that one interface improves performance.

## Interaction conditions

The saved `ResearchMode` defaults to **Flora Hybrid**:

- **Traditional** keeps the ordinary graphical mail interface and hides AI/context assistance.
- **Chat First** presents the read-only assistant as the main Today surface while retaining normal mail navigation and controls. Embedded reader/composer AI is hidden.
- **Flora Hybrid** keeps the daily briefing, contextual AI and optional assistant alongside the traditional interface.

Changing conditions does not change mail-provider write permissions, OAuth scopes, account data, category ownership, action confirmation requirements or automation authority. A research mode is a presentation condition, not a grant of permission. These conditions do not establish feature parity or a controlled study design; tasks must be chosen and reviewed for suitability in each condition. Neither Chat First nor any generated answer can execute a mail operation.

## Recording and consent

Interaction recording is **off by default**, independently of the selected research mode and Demo/real mail settings. The app's ordinary preferences store the user's opt-in. The metrics recorder starts disabled even when a previous metrics file exists; the application must explicitly reapply the saved opt-in. Merely opening Settings, reading prior metrics or exporting them does not enable recording.

While enabled, only calls through the fixed `ResearchInteraction` enum can record interactions: navigation, opening a message, search, composing, confirmed action execution, AI requests/acceptance/rejection, corrections, Undo, errors/recovery and showing an original. Event names are static code values; the API has no freeform event labels or metadata dictionary. Counts reflect instrumented callbacks, not inferred intent or a claim that every possible user interaction was measured.

A task timer starts only when the user chooses a predefined `ResearchTask` and starts it. The user marks it completed or abandoned. Completion records the user's marker; it does not infer task correctness. Starting another task abandons the previous attempt. Changing research mode abandons any active task in its original mode before recording the new mode. Opting out stops immediately and drops the active timer without writing a final event; the prior start remains incomplete. App termination or a crash similarly does not invent a completion/abandonment marker. Tasks do not resume automatically after restart.

Each enabled session receives a fresh random UUID unrelated to mail, account, device, participant or Keychain identifiers. Events carry their condition, sequence, elapsed session milliseconds, fixed interaction/task values, and a duration for terminal task markers. Time comes from an injected monotonic clock; no wall-clock dates are exported. Durations and session offsets are capped at 24 hours, so this instrument is intended for short, user-started tasks rather than longitudinal tracking.

## Privacy and local storage

The metrics schema contains only:

- Schema version and number of evicted events.
- A sequence number, random session UUID, mode and event kind.
- Optional fixed interaction/task enum values.
- Elapsed milliseconds and task durations.

It has **no fields** for message/account/provider IDs, subjects, sender or recipient addresses, email bodies, attachments, queries, assistant answers, filesystem paths, credentials, participant names or notes. Mail IDs are never passed into recorder methods. The recorder has no mail repository, AI provider, account controller, network transport or telemetry endpoint.

Metrics use a separate local `research-metrics.json` file and are excluded from Git. The versioned store atomically replaces a file with mode 0600 in a directory with mode 0700. It retains at most 1,000 events and is limited to 1 MiB. Oldest events are evicted with an explicit `droppedEventCount`; displayed completion and interaction counts describe the retained window. Event pairs can be truncated by retention, so an export is not necessarily a complete session history. This is a prototype JSON store, not encrypted storage.

Unknown JSON fields, unsupported versions, malformed event shapes, invalid clocks, oversized files and symlink file targets are rejected. Existing unreadable data is preserved. Saving failures stop recording without interrupting mail. The controller exposes only fixed error descriptions, never arbitrary filesystem/provider errors. It does not silently restart recording after a save failure; the user can explicitly enable or choose **Retry Recording** after recovery without deleting retained records, or clear invalid data. If saving the opt-out preference fails, recording remains off for the session and **Retry Saving Opt-Out** persists the preference without re-enabling recording. Error-recovery bookkeeping is scoped to the enabled recording epoch: mode changes, opt-out, restart, retry and clearing data cannot carry an error from an earlier condition or before consent into a later session.

**Clear** removes stored metrics and active timers. If recording was already enabled, subsequent interactions belong to a fresh random session; clearing itself does not fabricate a task result. **Export** returns only a newly encoded, validated metrics snapshot to the native file exporter. The user chooses the destination; nothing is uploaded automatically. A metrics file can still reveal activity patterns and should be shared deliberately.

## Verification and limits

Domain/controller tests use fictional interactions and injected clocks/repositories. They cover default-off behavior, immediate opt-out, explicit timers, mode-change abandonment, restart isolation, random session identity, bounded retention, clear/export semantics, fixed-schema privacy, corrupt/oversized stores, local permissions, invalid clocks and safe write failures. These are developer checks, not participant observations or study outcomes.

No participant recruitment, consent-management system, assignment randomization, study counterbalancing, task-correctness scoring, statistical analysis, longitudinal telemetry or research conclusions are implemented. A real evaluation still needs a reviewed study protocol, suitable tasks for every condition, explicit participant consent and a data-handling plan appropriate to that study. Do not describe exported developer-fixture events as user-study results.
