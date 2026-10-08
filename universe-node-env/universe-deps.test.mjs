// Exercises universe-deps end to end on a Linux host with node and npm on
// PATH: one cold build, warm activations that hard-link the immutable
// snapshot, write protection, a fingerprint that moves when an input moves,
// and retention. Skipped elsewhere: the store relies on hard links and flock.
//
//   node --test universe-node-env/universe-deps.test.mjs
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const linux = process.platform === "linux";
const script = new URL("./universe-deps.sh", import.meta.url).pathname;

// A packed tarball dependency installs as a real copy (a `file:` directory
// would be symlinked), so the job tree has inodes of its own to inspect.
function workspace(root, name, version) {
  const dir = join(root, name);
  mkdirSync(join(dir, "dep"), { recursive: true });
  writeFileSync(join(dir, "dep", "package.json"), JSON.stringify({ name: "dep", version }));
  writeFileSync(join(dir, "dep", "index.js"), "module.exports = 'dep';\n");
  execFileSync("npm", ["pack", "./dep", "--pack-destination", dir], { cwd: dir, stdio: "pipe" });
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name, version: "1.0.0", dependencies: { dep: `file:./dep-${version}.tgz` } }));
  execFileSync("npm", ["install", "--package-lock-only", "--no-audit", "--no-fund", "--ignore-scripts"], { cwd: dir, stdio: "pipe" });
  return dir;
}

function deps(cwd, store, ...args) {
  const result = spawnSync("bash", [script, ...args], {
    cwd,
    encoding: "utf8",
    env: { ...process.env, UNIVERSE_DEP_STORE: store, UNIVERSE_DEP_STORE_KEEP: "1", GITHUB_STEP_SUMMARY: "" },
  });
  return { ...result, out: `${result.stdout}${result.stderr}` };
}

test("universe-deps builds once, then links the immutable snapshot in every job", { skip: !linux && "Linux only" }, () => {
  const root = mkdtempSync(join(tmpdir(), "universe-deps-"));
  try {
    const store = join(root, "store");
    const ws = workspace(root, "app", "1.0.0");
    const key = deps(ws, store, "key");
    assert.equal(key.status, 0, key.out);
    assert.match(key.stdout.trim(), /^universe-deps-v3-linux-x64-(glibc|musl)-node[0-9.]+-abi\d+-npm[0-9.]+-[0-9a-f]{32}$/);

    const cold = deps(ws, store, "activate");
    assert.equal(cold.status, 0, cold.out);
    assert.match(cold.out, /DEPENDENCY CACHE: cold/);
    assert.match(cold.out, /DEPENDENCY BUILT: \d+ files/);
    assert.ok(existsSync(join(store, "trees", key.stdout.trim(), "ready")));

    rmSync(join(ws, "node_modules"), { recursive: true, force: true });
    const warm = deps(ws, store, "activate");
    assert.equal(warm.status, 0, warm.out);
    assert.match(warm.out, /DEPENDENCY CACHE: warm/);
    assert.match(warm.out, /DEPENDENCY SOURCE: local warm state/);
    assert.doesNotMatch(warm.out, /npm ci|DEPENDENCY BUILT/);

    // The job's tree is a private hard-link farm of read-only inodes.
    const linked = join(ws, "node_modules", "dep", "package.json");
    const info = statSync(linked);
    assert.equal(info.nlink, 2, "job tree shares inodes with the snapshot");
    assert.equal(info.mode & 0o222, 0, "snapshot files are read-only");
    assert.throws(() => writeFileSync(linked, "x"), "a job cannot edit the snapshot in place");
    assert.equal(readFileSync(join(ws, "node_modules", "dep", "index.js"), "utf8"), "module.exports = 'dep';\n");

    const verify = deps(ws, store, "verify");
    assert.equal(verify.status, 0, verify.out);

    // Any input change moves the fingerprint and builds exactly once more.
    const changed = workspace(root, "app2", "2.0.0");
    const key2 = deps(changed, store, "key");
    assert.notEqual(key2.stdout.trim(), key.stdout.trim());
    const cold2 = deps(changed, store, "activate");
    assert.match(cold2.out, /DEPENDENCY CACHE: cold/);

    // A drifted snapshot is detected and rebuilt rather than reused.
    const snapshotFile = join(store, "trees", key2.stdout.trim(), "tree", "node_modules", "dep", "index.js");
    execFileSync("chmod", ["u+w", snapshotFile]);
    writeFileSync(snapshotFile, "tampered\n");
    rmSync(join(changed, "node_modules"), { recursive: true, force: true });
    const rebuilt = deps(changed, store, "activate");
    assert.equal(rebuilt.status, 0, rebuilt.out);
    assert.match(rebuilt.out, /DEPENDENCY SNAPSHOT INVALID: rebuilding/);
    assert.equal(readFileSync(join(changed, "node_modules", "dep", "index.js"), "utf8"), "module.exports = 'dep';\n");

    const status = deps(ws, store, "status");
    assert.equal(status.status, 0, status.out);
    assert.match(status.out, /trees=2/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
