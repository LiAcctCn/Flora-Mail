# Flora Mail — Beta portfolio content provenance

Content was checked exclusively against `/Users/chubai/Documents/Development/Flora Mail - Beta` at application revision `ae3054d8912f74885f84473d059719f592238a0a`, the target of the existing annotated `v0.2.0` tag. Repository remote: `https://github.com/LiAcctCn/Flora-Mail.git`. No similarly named older workspace was used.

## Source map

References below are relative to the Beta repository. Line numbers describe the audited revision.

| Portfolio claim                                                                                                                    | Repository evidence                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Native macOS Swift / SwiftUI research prototype; Swift Package Manager                                                             | `README.md:3,7,20`                                                                   |
| Demo Mode, Inbox/Reader, Today briefing, composer/drafts, search, categories, settings/accounts, local cache, attachments, history | `README.md:39–51`                                                                    |
| Gmail, Microsoft Outlook / Microsoft 365 and iCloud provider architecture                                                          | `Docs/ReleaseNotes-0.2.0.md:7–9`                                                     |
| Local summary, classification, action extraction, smart reply, writing tools, query expansion and source-linked assistant          | `Docs/ReleaseNotes-0.2.0.md:10–11`; `Docs/LocalAI.md:17–27`                          |
| Local AI via Ollama and gemma3:4b; no silent cloud fallback                                                                        | `Docs/LocalAI.md:3–11,68`                                                            |
| Scoped context, validation, cancellation and AI caching                                                                            | `Docs/LocalAI.md:17–50`                                                              |
| Suggest → Confirm → Execute; informational AI outputs do not hold mail execution authority                                         | `Docs/Architecture.md:52–72`                                                         |
| Five automation levels, scoped authorization, reviewed Run Now execution                                                           | `Docs/Automation.md:3–15`; `Sources/FloraCore/Automation/AutomationModels.swift:4–9` |
| Traditional, Chat First and Flora Hybrid research presentation conditions                                                          | `Docs/Research.md:7–13`                                                              |
| Optional, default-off local research instrumentation; no participant findings                                                      | `Docs/Research.md:17–46`                                                             |
| 422 automated tests passed: 130 XCTest + 292 Swift Testing                                                                         | `Docs/ReleaseNotes-0.2.0.md:26`; `Docs/RoadmapProgress.md:69`                        |
| Debug and Release builds passed in the recorded application verification                                                           | `README.md:117`; `Docs/RoadmapProgress.md:73`                                        |
| Preview status and lack of production validation                                                                                   | `Docs/ReleaseNotes-0.2.0.md:3,30–36`                                                 |

The working paper title, _Designing for Intelligence: A Human-Guided Framework for AI-Augmented Applications_, is recorded in `README.md:3` and `Docs/Research.md:3`. The Chinese title and central framing were supplied in the website brief. A published paper or final PDF is not established.

## Required distinctions

- **v0.2.0 prerelease / research prototype:** a working implementation, with production readiness not claimed.
- **Provider architecture implemented; real-account validation ongoing:** credential-backed Gmail, Microsoft and iCloud sign-in, synchronization and writes remain unverified in the recorded release (`Docs/ReleaseNotes-0.2.0.md:32`).
- **422 is an application engineering verification result:** fixtures and local integration checks do not establish live-provider behavior, usability results or model accuracy.
- **Proposed Evaluation:** conditions and instrumentation prepare future study. No validated protocol, participants, statistical results or research conclusions are reported (`Docs/Research.md:3,13,46`).
- **Level 4 is narrow delegation:** a separate, expiring one-run grant for an exact preview of at most ten messages. The app requires Run Now and has no scheduler or autonomous background agent. Implemented rule actions are Archive and Mark read (`Docs/Automation.md:3–15`).
- **Local AI privacy is scoped:** mail synchronization still contacts the chosen mail provider. Local JSON stores are access-restricted, not an encrypted production database (`Docs/LocalAI.md:29,41`).
- **Semantic search means query expansion plus local ranking:** no embedding index is implemented. Exact quote checks establish provenance, not guaranteed truth (`Docs/LocalAI.md:54–60`).
- **Undo has limits:** local session Undo and confirmed remote read/flag inverses exist; sending, archive and move have no automatic remote Undo (`README.md:103`).

`Docs/Verification.md` describes an older read-only, 161-test iteration. Its older no-write/no-Git statements must not override current release notes and roadmap.

## Asset provenance

- **Authentic Beta assets:** none were found by the initial tracked/discoverable image, icon, PDF, slide and document asset search. A screenshot captured separately from this Beta application would require its own provenance record before being described as authentic.
- **Conceptual assets:** website-native CSS/SVG diagrams and designed macOS presentation frames are explanatory illustrations. They must carry a visible label such as “Conceptual interface · based on the Beta implementation,” and must never be described as an app screenshot.
- **Placeholders:** contact details and an unpublished paper link may use explicit “To be added” or “Paper forthcoming” text. Inactive placeholders should not masquerade as working destinations.
- Demo names or messages used in conceptual frames must remain fictional; no private mail or account data belongs in the website.

## Remaining content needed

- Portfolio owner bio and preferred public contact details, if desired.
- Public working-paper URL or final PDF, when available.
- Authentic current Beta screenshots or approved demo capture, if desired.
- Confirmation of public repository access, or an alternative public project link.
- Optional resume link.

## Browser regression assertions

Use assertions against rendered, visible content rather than comments or hidden metadata:

1. The main heading names Flora Mail; the hero visibly identifies the Beta and v0.2.0 prerelease.
2. The current-status section visibly identifies a research prototype, ongoing real-account validation, proposed evaluation and no claim of production readiness.
3. The engineering section shows 422 automated tests, with nearby wording identifying a recorded application verification result rather than live-provider or research validation.
4. The research section contains “Proposed Evaluation” or “Evaluation Protocol” and an explicit statement that no participant results are reported.
5. All three experimental modes are rendered; Flora Hybrid visibly combines Traditional GUI, Embedded AI and Optional Assistant.
6. Selecting each automation level updates visible level details. Level 4 describes explicit limited authorization; the section visibly states Run Now and the absence of a background scheduler.
7. Every designed product frame has a visible conceptual label in its frame or figure caption. Image alternative text and captions must not call these authentic screenshots.
8. The local-AI section renders Ollama, gemma3:4b and no silent cloud fallback. The authority flow preserves user review and confirmation before execution.
9. Provider content names Gmail, Microsoft and iCloud and includes visible validation caveats.
10. The GitHub link targets the exact supplied repository and makes no guarantee of public access. Paper and contact placeholders have no fabricated destination or empty `href="#"` action.
11. Navigation anchors resolve to real section IDs; keyboard navigation can operate interactive controls; visible status/captions persist at desktop, tablet and mobile widths.

Avoid brittle negative checks for isolated words such as “participants,” “production” or “validated”: truthful caveats require these terms. Instead assert the explicit status wording and review any numeric study claims separately.
