# Flora Mail – Beta portfolio

Isolated static portfolio for the native macOS prototype. Product source of truth: the containing Beta repository at `ae3054d` (v0.2.0 preview). No Swift application files are changed.

## Develop

Use Node 22.12 or later. Run commands inside `portfolio/`:

```sh
npm ci
npm run dev
npm run check
npm run lint
npm run build
npm run format:check
npm test
```

The browser suite uses Google Chrome. Install Chrome if it is absent (`npx playwright install chrome` on a supported development machine). Tests start the production preview on port 4322 and cover 1440, 834, 390, and 320 CSS-pixel widths. Reports, traces, and screenshots are ignored by Git. The development server uses port 4321 by default.

Static output is `dist/`. The site has no server, secrets, account connections, analytics, or remote font requests.

## Deploy to Cloudflare Pages

Connect the Git repository, choose `develop/portfolio`, set the root directory to `portfolio`, the build command to `npm run build`, and the output directory to `dist`. The generated assets can also be uploaded to another static host. No Astro server adapter is needed for this static output. Repository visibility and hosting authorization are managed separately. No hosting account is connected by this implementation; publishing is a separate deployment step. See the [Cloudflare Pages build configuration](https://developers.cloudflare.com/pages/configuration/build-configuration/) for repository root and output-directory settings. A `.node-version` file selects Node 22. The included `_headers` sets caching for fingerprinted assets and basic response headers.

## Content

The checked-in Beta has no screenshots, app icon, or paper PDF. Conceptual interface frames are labeled and use fictional demo fixture content. The envelope mark is created for the portfolio, not an authentic app icon. The paper is a working title, evaluation is proposed, and live-provider validation is unverified. Contact details and a paper URL remain intentionally unset.

## Structure and maintenance

- `src/pages/index.astro` composes the complete case study.
- `src/components/` contains product frames, accessible interactions, and narrative sections.
- `src/layouts/Layout.astro` owns semantic structure, navigation, SEO metadata, and reduced-motion-aware reveals.
- `src/styles/` contains the shared theme and responsive product/research layouts.
- `public/` contains the portfolio envelope favicon, robots policy, and static-host headers.
- `tests/portfolio.spec.ts` checks interactions, fragments, status wording, responsive overflow, console errors, and axe accessibility rules.
- `docs/content-provenance.md` maps claims to current Beta evidence.
- `docs/verification.md` records the website verification and its limits.

All narrative content is rendered statically. Small client scripts progressively enhance the experience selector, automation levels, and reveal motion. No JavaScript framework is shipped to visitors. Without JavaScript, every product panel and all automation explanations remain readable.

## Remaining content

Replace the clearly marked paper/contact placeholders in `Journey.astro` when a public manuscript and contact details are available. Optional future additions include an author name/bio and approved screenshots from this Beta. Update the favicon only when an authentic app icon is supplied. Add canonical and sitemap URLs after choosing the real deployment domain; no domain is invented here.
