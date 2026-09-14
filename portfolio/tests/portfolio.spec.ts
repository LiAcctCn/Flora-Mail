import { test as base, expect, type Page } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

// Every browser check also watches for script errors and failed local assets.
// No requests are made to private repositories or real mail accounts.
const test = base.extend<{ browserHealth: void }>({
  browserHealth: [
    async ({ page, baseURL }, use) => {
      const errors: string[] = [];
      const localOrigin = new URL(baseURL!).origin;
      page.on("pageerror", (error) => errors.push(`Runtime: ${error.message}`));
      page.on("console", (message) => {
        if (message.type() === "error")
          errors.push(`Console: ${message.text()}`);
      });
      page.on("response", (response) => {
        if (
          new URL(response.url()).origin === localOrigin &&
          response.status() >= 400
        ) {
          errors.push(`HTTP ${response.status()}: ${response.url()}`);
        }
      });
      await use();
      expect(errors, "No runtime, console, or local HTTP errors").toEqual([]);
    },
    { auto: true },
  ],
});

const experiences = ["reader", "briefing", "composer", "accounts"];
const automationNames = [
  "Manual",
  "Information",
  "Suggestion",
  "Approved Rules",
  "Delegation",
];

async function expectNoOverflow(page: Page) {
  const dimensions = await page.evaluate(() => ({
    content: document.documentElement.scrollWidth,
    viewport: window.innerWidth,
  }));
  expect(
    dimensions.content,
    `Content width ${dimensions.content}; viewport ${dimensions.viewport}`,
  ).toBeLessThanOrEqual(dimensions.viewport + 1);
}

async function expectSelectedExperience(page: Page, id: string) {
  await expect(page.locator(`#tab-${id}`)).toHaveAttribute(
    "aria-selected",
    "true",
  );
  await expect(page.locator(`#tab-${id}`)).toHaveAttribute("tabindex", "0");
  await expect(page.locator(`#panel-${id}`)).toBeVisible();
  await expect(page.getByRole("tab", { selected: true })).toHaveCount(1);
  await expect(page.getByRole("tabpanel")).toHaveCount(1);
  await expect(page.locator(`#panel-${id} .concept-label`)).toBeVisible();
  await expectNoOverflow(page);
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
});

test("navigation, semantics, metadata, and truthful project status", async ({
  page,
}) => {
  await expect(page).toHaveTitle(/Flora Mail/);
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(page.locator('meta[name="description"]')).toHaveAttribute(
    "content",
    /local-first/i,
  );
  await expect(page.getByRole("main")).toHaveCount(1);
  await expect(page.getByRole("heading", { level: 1 })).toHaveCount(1);
  await expect(page.locator(".hero")).toContainText("v0.2.0 Prerelease");
  await expect(page.locator("#engineering")).toContainText("422");
  await expect(page.locator("#engineering")).toContainText(/automated tests/i);
  await expect(page.locator("#research")).toContainText(/Proposed Evaluation/i);
  await expect(page.locator("body")).toContainText(/research prototype/i);
  await expect(page.locator(".hero-figure figcaption")).toContainText(
    /Conceptual presentation/i,
  );

  const problems = await page.locator('a[href^="#"]').evaluateAll((links) =>
    links.flatMap((link) => {
      const href = link.getAttribute("href")!;
      return href.length > 1 &&
        document.getElementById(decodeURIComponent(href.slice(1)))
        ? []
        : [`Missing fragment destination: ${href}`];
    }),
  );
  expect(problems).toEqual([]);
  const duplicateIds = await page.locator("[id]").evaluateAll((elements) => {
    const ids = elements.map((element) => element.id);
    return ids.filter((id, index) => ids.indexOf(id) !== index);
  });
  expect(duplicateIds).toEqual([]);

  for (const name of ["Experience", "Framework", "Engineering", "Research"]) {
    const link = page
      .getByRole("navigation", { name: "Main navigation" })
      .getByRole("link", { name, exact: true });
    const destination = await link.getAttribute("href");
    await link.click();
    await expect(page).toHaveURL(new RegExp(`${destination}$`));
    await expect(page.locator(destination!)).toBeInViewport({ ratio: 0.05 });
  }
  const github = page
    .locator('a[href="https://github.com/LiAcctCn/Flora-Mail"]')
    .first();
  await expect(github).toBeVisible();
  await expect(github).toHaveAttribute("rel", /noopener/);
  await expect(github).toHaveAccessibleName(/may require access/i);
});

test("all four product experiences select with pointer input", async ({
  page,
}) => {
  for (const id of experiences) {
    await page.locator(`#tab-${id}`).click();
    await expectSelectedExperience(page, id);
  }
  await expect(page.locator("#panel-accounts")).toContainText(
    /Live sign-in, sync, and writes remain unverified/i,
  );
});

test("product experiences support arrow keys, wrapping, Home, and End", async ({
  page,
}) => {
  const first = page.locator("#tab-reader");
  await first.focus();
  for (const id of ["briefing", "composer", "accounts", "reader"]) {
    await page.keyboard.press("ArrowRight");
    await expectSelectedExperience(page, id);
    await expect(page.locator(`#tab-${id}`)).toBeFocused();
  }
  await page.keyboard.press("ArrowLeft");
  await expectSelectedExperience(page, "accounts");
  await page.keyboard.press("Home");
  await expectSelectedExperience(page, "reader");
  await page.keyboard.press("End");
  await expectSelectedExperience(page, "accounts");
  await page.keyboard.press("Tab");
  await expect(page.locator("#panel-accounts")).toBeFocused();
});

test("all automation levels update the visible detail and pressed state", async ({
  page,
}) => {
  const panel = page.locator("#automation-detail");
  const content = new Set<string>();
  for (let level = 0; level < automationNames.length; level++) {
    const button = page.locator(`button[data-level="${level}"]`);
    await button.click();
    await expect(button).toHaveAttribute("aria-pressed", "true");
    await expect(
      page.locator('button[data-level][aria-pressed="true"]'),
    ).toHaveCount(1);
    await expect(panel).toBeVisible();
    await expect(panel).toContainText(new RegExp(automationNames[level], "i"));
    content.add((await panel.textContent())!.trim());
    await expectNoOverflow(page);
  }
  expect(content.size, "Each level explains its own authority boundary").toBe(
    5,
  );
  const manual = page.locator('button[data-level="0"]');
  await manual.focus();
  await page.keyboard.press("Enter");
  await expect(manual).toHaveAttribute("aria-pressed", "true");
  const suggestion = page.locator('button[data-level="2"]');
  await suggestion.focus();
  await page.keyboard.press("Space");
  await expect(suggestion).toHaveAttribute("aria-pressed", "true");
  await expect(panel).toContainText(/suggestion/i);
});

test("research evaluation disclosures work with pointer and keyboard", async ({
  page,
}) => {
  const disclosures = page.locator("#research details");
  expect(
    await disclosures.count(),
    "Research contains native disclosure content",
  ).toBeGreaterThan(0);
  for (const disclosure of await disclosures.all()) {
    const summary = disclosure.locator("summary");
    await expect(summary).toHaveCount(1);
    if ((await disclosure.getAttribute("open")) !== null) await summary.click();
    await summary.click();
    await expect(disclosure).toHaveAttribute("open", "");
    await summary.focus();
    await page.keyboard.press("Space");
    await expect(disclosure).not.toHaveAttribute("open", "");
    await page.keyboard.press("Enter");
    await expect(disclosure).toHaveAttribute("open", "");
  }
  await expectNoOverflow(page);
});

test("skip navigation reaches the main content", async ({ page }) => {
  await page.keyboard.press("Tab");
  const skipLink = page.getByRole("link", {
    name: "Skip to content",
    exact: true,
  });
  await expect(skipLink).toBeFocused();
  await expect(skipLink).toBeInViewport();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/#main$/);
});

test("WCAG AA scan includes the expanded research and product interface", async ({
  page,
}) => {
  for (const disclosure of await page.locator("#research details").all()) {
    if ((await disclosure.getAttribute("open")) === null)
      await disclosure.locator("summary").click();
  }
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
    .analyze();
  expect(
    results.violations.map((violation) => ({
      id: violation.id,
      impact: violation.impact,
      description: violation.description,
      nodes: violation.nodes.map((node) => ({
        target: node.target,
        summary: node.failureSummary,
      })),
    })),
  ).toEqual([]);
});

test("responsive page renders without horizontal overflow", async ({
  page,
}, testInfo) => {
  await page.evaluate(async () => {
    await document.fonts.ready;
  });
  await expectNoOverflow(page);
  const images = await page.locator("img").evaluateAll((elements) =>
    elements
      .filter(
        (element): element is HTMLImageElement =>
          element instanceof HTMLImageElement,
      )
      .filter((image) => !image.complete || image.naturalWidth === 0)
      .map((image) => image.src),
  );
  expect(images, "All image assets decode successfully").toEqual([]);
  await page.screenshot({
    path: testInfo.outputPath("portfolio-full.png"),
    fullPage: true,
  });
  await page.locator("#experience").scrollIntoViewIfNeeded();
  await page.screenshot({
    path: testInfo.outputPath("product-experience.png"),
  });
});
