#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const requiredBrowserEngines = Object.freeze([
  "chromium",
  "firefox",
  "webkit",
]);

export const requiredPlaywrightVersion = "1.62.1";

function normalizeShell(source) {
  return source.replace(/\\\n/g, " ").replace(/[ \t]+/g, " ");
}

export function verifyBrowserBundleSource({ runner, verifier, versions }) {
  const failures = [];
  const normalizedRunner = normalizeShell(runner);
  const installMatch = normalizedRunner.match(
    /npx --yes "playwright@\$\{PLAYWRIGHT_VERSION\}" install --with-deps ([a-z ]+)/,
  );

  if (!installMatch) {
    failures.push(
      "runner.sh: expected the pinned Playwright install command with --with-deps",
    );
  } else {
    const installedEngines = new Set(installMatch[1].trim().split(/\s+/));
    for (const engine of requiredBrowserEngines) {
      if (!installedEngines.has(engine)) {
        failures.push(`runner.sh: Playwright ${engine} is not installed`);
      }
    }
  }

  for (const engine of requiredBrowserEngines) {
    const installedDirectoryCheck = `/ms-playwright/${engine}-*`;
    if (!verifier.includes(installedDirectoryCheck)) {
      failures.push(`verify.sh: Playwright ${engine} is not verified`);
    }
  }

  const versionMatch = versions.match(
    /^playwright_version\s*=\s*"([^"]+)"\s*$/m,
  );
  const actualVersion = versionMatch?.[1] ?? "missing";
  if (actualVersion !== requiredPlaywrightVersion) {
    failures.push(
      `versions.pkrvars.hcl: expected Playwright ${requiredPlaywrightVersion}, got ${actualVersion}`,
    );
  }

  return failures;
}

async function main() {
  const sourceRoot = path.dirname(fileURLToPath(import.meta.url));
  const [runner, verifier, versions] = await Promise.all([
    readFile(path.join(sourceRoot, "runner.sh"), "utf8"),
    readFile(path.join(sourceRoot, "verify.sh"), "utf8"),
    readFile(path.join(sourceRoot, "versions.pkrvars.hcl"), "utf8"),
  ]);
  const failures = verifyBrowserBundleSource({ runner, verifier, versions });

  if (failures.length > 0) {
    for (const failure of failures) {
      console.error(`FAIL  ${failure}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log(
    `ok    Playwright ${requiredPlaywrightVersion} installs and verifies ${requiredBrowserEngines.join(", ")} with OS dependencies`,
  );
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main();
}
