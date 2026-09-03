#!/usr/bin/env node

import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const checkedExtensions = new Set([".hcl", ".service", ".sh", ".yaml", ".yml"]);

export async function verifySource(sourceRoot) {
  const entries = await readdir(sourceRoot, { withFileTypes: true });
  const files = entries
    .filter((entry) => entry.isFile() && checkedExtensions.has(path.extname(entry.name)))
    .map((entry) => entry.name)
    .sort();
  const failures = [];

  for (const file of files) {
    const bytes = await readFile(path.join(sourceRoot, file));
    if (bytes.includes(0x0d)) {
      failures.push(`${file}: contains CR bytes`);
    }

    if (path.extname(file) === ".sh") {
      const source = bytes.toString("utf8");
      const firstLine = source.split("\n", 1)[0];
      if (firstLine !== "#!/usr/bin/env bash") {
        failures.push(`${file}: expected #!/usr/bin/env bash as the first line`);
      }
      if (file === "verify.sh") {
        const portCheckIndex = source.indexOf("ss -ltn");
        const finalExitIndex = source.lastIndexOf('exit "$fail"');
        if (
          portCheckIndex < 0 ||
          finalExitIndex < 0 ||
          portCheckIndex > finalExitIndex
        ) {
          failures.push(
            `${file}: expected the PostgreSQL port check before the final exit`,
          );
        }
      }
    }
  }

  return { checked: files.length, failures };
}

async function main() {
  const defaultRoot = path.dirname(fileURLToPath(import.meta.url));
  const sourceRoot = path.resolve(process.argv[2] ?? defaultRoot);
  const result = await verifySource(sourceRoot);

  if (result.failures.length > 0) {
    for (const failure of result.failures) {
      console.error(`FAIL  ${failure}`);
    }
    console.error("Build from a clean checkout whose Git attributes are applied.");
    process.exitCode = 1;
    return;
  }

  console.log(`ok    ${result.checked} runner image inputs use LF line endings`);
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main();
}
