import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { verifySource } from "./verify-source.mjs";

async function withFixture(files, run) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "universe-runner-source-"));
  try {
    await Promise.all(
      Object.entries(files).map(([name, contents]) =>
        writeFile(path.join(directory, name), contents),
      ),
    );
    await run(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test("accepts LF-only runner image inputs", async () => {
  await withFixture(
    {
      "bootstrap.sh": "#!/usr/bin/env bash\nset -euo pipefail\n",
      "runner.service": "[Service]\nExecStart=/opt/runner/bootstrap.sh\n",
      "variables.hcl": 'variable "name" {\n  type = string\n}\n',
    },
    async (directory) => {
      assert.deepEqual(await verifySource(directory), { checked: 3, failures: [] });
    },
  );
});

test("rejects CRLF in a copied bootstrap script", async () => {
  await withFixture(
    { "bootstrap.sh": "#!/usr/bin/env bash\r\nset -euo pipefail\r\n" },
    async (directory) => {
      const result = await verifySource(directory);
      assert.deepEqual(result.failures, [
        "bootstrap.sh: contains CR bytes",
        "bootstrap.sh: expected #!/usr/bin/env bash as the first line",
      ]);
    },
  );
});

test("rejects a shell script without the required interpreter", async () => {
  await withFixture(
    { "bootstrap.sh": "#!/bin/sh\nset -eu\n" },
    async (directory) => {
      const result = await verifySource(directory);
      assert.deepEqual(result.failures, [
        "bootstrap.sh: expected #!/usr/bin/env bash as the first line",
      ]);
    },
  );
});
