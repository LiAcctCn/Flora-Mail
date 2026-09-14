# Portfolio verification

Verified on 2026-09-14 in `/Users/chubai/Documents/Development/Flora Mail - Beta/portfolio`.

## Identity and isolation

The task initially opened in an empty `Flora Lab - Beta` directory. The requested `Flora Mail - Beta` repository was located and verified before editing. The older `Flora Mail` workspace was not inspected or used.

Product baseline: `ae3054d8912f74885f84473d059719f592238a0a`, the v0.2.0 prerelease implementation. Initial branch: `develop/live-account-validation`. Website branch: `develop/portfolio`. Remote: `https://github.com/LiAcctCn/Flora-Mail.git`.

All website changes are inside `portfolio/`. Swift source, native tests, app configuration, release files, and both existing release tags remain unchanged. No private mail, runtime stores, model caches, or credentials are included.

## Website checks

- Production static build: passed (`npm run build`).
- Type checks: passed with zero errors, warnings, or hints (`npm run check`).
- ESLint and formatting checks: passed (`npm run lint`, `npm run format:check`).
- Browser suite: 32 checks passed, eight checks each at 1440×1000, 834×1112, 390×844, and 320×844 in Chrome.
- Coverage: pointer and keyboard product tabs, all five automation levels, native research disclosures, skip link, section navigation, fragment destinations, unique IDs, metadata, truthful status, console/runtime errors, local HTTP failures, and horizontal overflow.
- axe WCAG 2/2.1 A and AA scans: no violations in tested states, including expanded research disclosures.
- Visual review: desktop hero, tablet research composition, mobile hero and product experience; full-page screenshots generated for every viewport.
- No-JavaScript check: all four product panels and five automation explanations remain visible and readable.
- Reduced motion is honored; content is never dependent on a reveal animation.
- Production dependency audit: zero reported vulnerabilities (`npm audit --omit=dev`).
- Output is a small collection of static HTML, CSS, JavaScript, favicon, robots, and headers. No server runtime, remote fonts, analytics, or mail/AI connections are shipped.

## Product evidence is separate

The 422 automated native tests (130 XCTest + 292 Swift Testing) and Debug/Release build status are documented in the Beta repository. They were not rerun for this website-only change. The site labels them as the documented v0.2.0 verification gate. They do not establish live-account validation, AI accuracy, user-study outcomes, or production readiness.

Source accuracy received an independent read-only review. Level 4 explicitly requires Run Now and has no background scheduler. No authentic screenshots, icon, or paper PDF are tracked in the Beta source; all interface frames are labeled conceptual and contain fictional demo material.

## Practical limits

The website has not been deployed to a hosting account. Cloudflare Pages-compatible static output and deployment instructions are supplied. The GitHub link targets the verified remote but may require access. Paper and contact links are intentionally unavailable until real details are supplied. Automated accessibility checks and Chrome viewport checks are not a comprehensive screen-reader or cross-browser certification.
