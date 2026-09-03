import assert from "node:assert/strict";
import test from "node:test";

import {
  requiredPlaywrightVersion,
  verifyBrowserBundleSource,
} from "./verify-browser-bundle-source.mjs";

const validSource = {
  runner:
    'npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium firefox webkit\n',
  verifier: [
    "ls -d /ms-playwright/chromium-*",
    "ls -d /ms-playwright/firefox-*",
    "ls -d /ms-playwright/webkit-*",
  ].join("\n"),
  versions: `playwright_version = "${requiredPlaywrightVersion}"\n`,
};

test("accepts the complete pinned Playwright browser bundle", () => {
  assert.deepEqual(verifyBrowserBundleSource(validSource), []);
});

test("rejects a browser install without Linux dependencies", () => {
  const runner = validSource.runner.replace(" --with-deps", "");
  assert.deepEqual(verifyBrowserBundleSource({ ...validSource, runner }), [
    "runner.sh: expected the pinned Playwright install command with --with-deps",
  ]);
});

test("rejects a missing browser install and image verification", () => {
  const runner = validSource.runner.replace(" firefox", "");
  const verifier = validSource.verifier.replace(
    "ls -d /ms-playwright/firefox-*\n",
    "",
  );
  assert.deepEqual(
    verifyBrowserBundleSource({ ...validSource, runner, verifier }),
    [
      "runner.sh: Playwright firefox is not installed",
      "verify.sh: Playwright firefox is not verified",
    ],
  );
});

test("rejects Playwright version drift", () => {
  const versions = 'playwright_version = "1.62.0"\n';
  assert.deepEqual(
    verifyBrowserBundleSource({ ...validSource, versions }),
    [
      `versions.pkrvars.hcl: expected Playwright ${requiredPlaywrightVersion}, got 1.62.0`,
    ],
  );
});
