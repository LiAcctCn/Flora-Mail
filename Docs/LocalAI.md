# Local AI implementation and privacy boundary

Flora uses `AIProvider → LocalAIProvider → LocalModelClient → Ollama → on-device model`. Only the transport understands Ollama HTTP envelopes. Gmail, Microsoft and iCloud adapters synchronize into the local mail store first; AI receives normalized cached message values through the same interface as Demo mail. SwiftUI calls AppModel; providers have no reference to mail mutation services, mail repositories or executors. The cache decorator uses a separate repository for generated results. Extracted actions are informational `ActionItem` values and cannot authorize execution.

## Working runtime contract

The previous local-AI milestone was verified with Ollama **0.34.0**, installed **gemma3:4b**, GGUF Q4_K_M, model digest `a2af6cc3eb7fa8be8504abaf9b04e88f17a119ec3f04a3addf55f92841195f5a`. No installation or download was performed during development. The live check exercises the same providers, prompts, validators and cache wrapper used by the app, using fictional fixtures. Credential-dependent generation over live synchronized mail has not yet been verified; the account integration does not change the local runtime boundary.

The client uses `/api/version`, `/api/tags`, `/api/show`, and non-streaming structured `/api/chat`. The configured model must already be installed with a valid digest, GGUF or safetensors format, and completion capability. Generation disables thinking, uses temperature zero, and bounds output tokens. Structured output follows Ollama's supported schema contract. [Chat API](https://docs.ollama.com/api/chat), [structured outputs](https://docs.ollama.com/capabilities/structured-outputs).

An Ollama server on localhost may still expose cloud aliases. Flora therefore requires version 0.34 or later, verifies installed local model metadata, rejects remote metadata/cloud names, and appends **`:local`** for both model inspection and inference. That selector is enforced by the supported runtime and prevents a model alias changing into a remote route between inspection and generation. Flora never retries without it and does not change the user's global Ollama cloud setting. [Version-pinned model selector](https://github.com/ollama/ollama/blob/v0.34.0/internal/modelref/modelref.go), [server enforcement](https://github.com/ollama/ollama/blob/v0.34.0/server/routes.go).

The local runtime itself is trusted software. Flora validates its declared contract and responses; it does not sandbox or attest a malicious replacement server.

## What the AI layer sends out of the Flora process

| Capability | Data sent to the local model | Data withheld |
| --- | --- | --- |
| Summary | Selected subject and first 12,000 body characters | Account credentials, recipient metadata, unrelated messages |
| Classification | Same message context and current category IDs/names | Rest of mailbox, deleted categories, mutation permissions |
| Action extraction | Selected subject and body prefix | Calendar availability, contacts, execution tools |
| Smart replies | Selected subject and body prefix | Unrelated conversations, user commitments or calendar records |
| Writing tools | Current draft body, editing instruction, and optionally the selected reply source subject/body excerpt (500/2,000 characters) | Recipient field, credentials, unrelated mail/history |
| Test Connection | Configured model name and metadata requests | Email contents and drafts |
| Semantic query expansion | Query text (up to 500 characters) and its meaningful terms only | All message content, account identifiers, credentials |
| Read-only assistant | Question plus at most six relevant excerpts (1,500 characters each), source message IDs and bounded subject/sender-name/date metadata | Other accounts, unrelated messages, full mailbox/thread histories, recipient/email-address fields, attachments, Calendar/Contacts and credentials |
| Traditional text search / AI Off | No generative model request | All mail remains inside the local search service |

Mail-provider synchronization separately contacts the authenticated mail service over TLS to retrieve mail. It does not route mail through an AI service. Demo Mode (fictional versus real mail) and the AI mode (Demo AI, Local AI, Off) are independent settings. Mock results remain labeled as Demo AI even when requested for a synchronized message.

AppModel resolves writing context from the explicit reply source and matching account ID; providers never fetch unrelated messages to enrich a prompt. Summary, classification, action extraction and smart reply operate on one selected message, not an automatically expanded historical thread. A real-mail Today briefing starts only through **Generate Briefing**, processing at most 20 recent inbox candidates individually within the current displayed account scope. Account switches invalidate request identities, and conventional/assistant search respects that scope.

Summary/classification labels disclose when source context was limited to a body prefix. Quotes must occur exactly within the supplied prefix. Writing inputs exceeding 12,000 characters fail rather than silently lose the end of a draft. Runtime truncation and context shifting are disabled; context overflow returns an error. Models still generate fallible paraphrases and self-reported, uncalibrated confidence. The reader retains original mail and source quotes for review.

## Network and storage controls

- Only HTTP endpoints on `127.0.0.1`, `[::1]`, or `localhost` are permitted. `localhost` is normalized to `127.0.0.1`; credentials, non-root paths, queries, fragments and other hosts are rejected.
- Per-request ephemeral URLSession instances disable proxies, automatic proxy discovery, cookies, credential storage, disk URL caching and redirects.
- Each metadata request times out within 10 seconds; inference uses the saved 5–180-second limit (default 60). Response bodies are bounded before decoding.
- Flora does not log HTTP error bodies or raw prompts. Optional DEBUG transport diagnostics show only API paths, status codes and error domain/code.
- Capability results are stored in the app's local `ai-cache.json`, with bounded entry count/total size and file mode 0600. Summaries and classification predictions are also saved with mail state in `demo-store.json`, whose retained filename now includes synchronized real mail as well as demo records. OAuth tokens and iCloud app-specific passwords are stored separately in Keychain, never in either AI or mail JSON. Neither store is an encrypted production database. Clearing AI results in Settings clears both sets of generated records.
- Draft writing previews, search queries, query expansions and assistant conversations are not cached on disk. Saving a draft remains an explicit user action.

## Validation and cache identity

Responses must be exact task-shaped JSON. Unexpected keys, unknown source message IDs, executable fields, malformed values, out-of-range confidence, invented category IDs and missing evidence are rejected. The parser does not repair prose or guess a result.

Cache keys include model identity/digest, runtime version, endpoint namespace, prompt version, capability, local message identity, explicit account/provider identity and relevant content. Synchronized message identities are deterministically namespaced by account and provider message ID, so equal provider IDs in different accounts cannot share a message cache entry. Classification keys include the complete current category structure. A category rename or removal invalidates future predictions without overwriting confirmed assignments. Successful model identity checks are required even on cache hits; an unavailable runtime does not present an old result as a newly successful connection.

Cancellation is checked in transport, provider, cache and AppModel. The reader and composer also track the exact source/configuration request identity. Replacing a message, changing models, toggling AI off/on, or cancelling an operation cannot let its late completion overwrite a different message or draft. Category predictions pass through the existing permission executor only after explicit acceptance. For real mail, that acceptance stores a local Flora category; it does not call a server label/move API. Smart replies and writing output populate normal local draft previews. Real-account sending and mailbox mutations require their separate explicit account permission and proposal/confirmation executor. The assistant and other AI providers hold no writer or executor reference and cannot authorize those operations.

## Scoped search and source-linked assistant

`MailIntelligenceService` requires an explicit set of account IDs and accepts an optional `AIProvider`. With AI Off it performs conventional text matching without inference. Local AI generates structured, query-only synonym groups; the service retains every original meaningful term as a retrieval constraint, adds validated alternatives, and ranks cached sender/subject/body matches on the device. Results disclose **Local semantic expansion**, **Demo synonyms**, or **Text fallback**. This is query expansion over text matching, not an embedding index, and may miss paraphrases or interpret a synonym poorly. Invalid expansion output or unavailable inference falls back to text search; it never falls back to another AI provider.

The optional assistant retrieves at most six messages from that same account scope. It sends one verbatim body window of at most 1,500 characters from each, favoring a window near a query hit. A versioned `retrieval-v1` prompt requests claims with source IDs and exact quotes. Every claim must cite at least one provided excerpt; unknown IDs, quotes outside the supplied window, missing citations and executable extra fields are rejected. An empty claim list means the retrieved evidence was insufficient. Original sources remain accessible when generation fails or is unavailable.

Authoritative metadata and source fingerprints are constructed from cached messages, never reconstructed by the model. Fingerprints include message/account identity, body, subject, sender and date; AppModel checks them again before displaying an answer so late results cannot attach to changed mail or another account scope. Cancellation is rechecked even after a runtime failure before any text fallback or answer is returned. The cache decorator forwards these transient capabilities without storing the questions or excerpts.

Exact quotes establish provenance, not the semantic truth of a model's paraphrase. The UI labels answers as generated and links each claim to its original source. The assistant has no action execution controls. Demo AI uses the same interface, fixed synonym groups and verbatim excerpts, with a distinct extractive-demo label.

The focused test suite covers query-only prompts, explicit account boundaries, six-source context bounds, unknown/forged citations, omitted-context quotes, source changes, cancellation after ignored cancellation or runtime errors, AI-Off behavior, text fallback and provider/cache interchangeability. The Phase 3 live check also passed using Ollama 0.34.0 and gemma3:4b over three fictional messages synchronized in two pages and reloaded from temporary local storage. It retrieved one scoped meeting message and returned six source-linked claims whose quotes passed validation. This was actual local inference, not authenticated live-provider mail or a comprehensive quality evaluation.

## Remaining limits

Ollama is the implemented runtime adapter; other adapters can conform to LocalModelClient. Other installed model names can be configured, but only Gemma was verified end to end here. The current `local-v5` prompt produced a coherent recipient reply without a greeting or reversed question in the synchronized-fixture check. The same run incorrectly classified a school assignment as Work with high confidence, and Concise retained a grammar error. Earlier checks also produced unnecessary questions and commitments. A previous live-inference Daily Briefing over fictional mail rejected a generated quote absent from its source, retained completed items and offered Retry. The prompt and JSON validator cannot guarantee factual accuracy or the user's intent; suggestions must remain editable previews and never send automatically.

Semantic embeddings and autonomous AI actions are not implemented. OAuth and iCloud authentication and user-approved remote writes belong to the separate account/action layer; no AI capability can access its credentials or execute provider writes. Models are installed/started by the user; Flora never downloads one or silently falls back to cloud or Demo AI. `swift run FloraLocalAICheck --replies-only` performs a targeted live check using Maya's fictional design-review email without accessing the mail store.

`swift run FloraLocalAICheck --synchronized-fixture` additionally runs a fictional read-only provider through bounded sync, temporary JSON persistence and reload before invoking the actual local model. It does not authenticate Gmail, Microsoft or iCloud, and never reads the user’s mail store.

`swift run FloraLocalAICheck --intelligence-only` exercises actual local query expansion and a source-linked answer using fictional scoped mail. It does not read the user’s mail store or contact a mail provider.
