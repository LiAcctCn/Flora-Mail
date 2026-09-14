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
```

Static output is `dist/`. The site has no server, secrets, account connections, analytics, or remote font requests.

## Deploy to Cloudflare Pages

Connect the Git repository, choose `develop/portfolio`, set the root directory to `portfolio`, the build command to `npm run build`, and the output directory to `dist`. The generated assets can also be uploaded to another static host. No Astro server adapter is needed for this static output. Repository visibility and hosting authorization are managed separately.

## Content

The checked-in Beta has no screenshots, app icon, or paper PDF. Conceptual interface frames are labeled and use fictional demo fixture content. The envelope mark is created for the portfolio, not an authentic app icon. The paper is a working title, evaluation is proposed, and live-provider validation is unverified. Contact details and a paper URL remain intentionally unset.
