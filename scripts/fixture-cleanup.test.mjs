import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const fixtures = ["mysql", "postgres", "redis"];
const temporaryRoot = path.resolve(tmpdir());
function scratch(context) {
  const directory = mkdtempSync(path.join(temporaryRoot, "fixture-cleanup-test-"));
  context.after(() => {
    assert.equal(path.dirname(path.resolve(directory)), temporaryRoot);
    assert.ok(path.basename(directory).startsWith("fixture-cleanup-test-"));
    rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}
function savedState(appendCommandValue, directory, fixture) {
  const state = path.join(directory, "state");
  const container = `universe-ci-${fixture}-42-1-tests-runner-01`;
  appendCommandValue(state, "platform", "linux");
  appendCommandValue(state, "container", container);
  return {
    container,
    environment: Object.fromEntries(readFileSync(state, "utf8").trim().split("\n").map((line) => {
      const separator = line.indexOf("=");
      return [`STATE_${line.slice(0, separator)}`, line.slice(separator + 1)];
    }))
  };
}

for (const fixture of fixtures) {
  const post = new URL(`../portable-${fixture}-fixture/post.mjs`, import.meta.url);
  const { cleanup } = await import(post);
  const { appendCommandValue } = await import(new URL(`../portable-${fixture}-fixture/lib.mjs`, import.meta.url));
  function commands(environment) {
    const calls = [];
    cleanup(environment, (...arguments_) => calls.push(arguments_));
    return calls;
  }
  function expected(container) {
    return [["linux", ["rm", "--force", container], { capture: true, allowFailure: true }]];
  }
  test(`${fixture}: real saved-state names trigger cleanup`, (context) => {
    const state = savedState(appendCommandValue, scratch(context), fixture);
    assert.deepEqual(commands(state.environment), expected(state.container));
  });
  test(`${fixture}: uppercase legacy state remains supported`, () => {
    assert.deepEqual(commands({ STATE_PLATFORM: "linux", STATE_CONTAINER: "legacy-fixture" }), expected("legacy-fixture"));
  });
  test(`${fixture}: exact saved-state keys take precedence over legacy state`, () => {
    assert.deepEqual(commands({ STATE_platform: "linux", STATE_container: "current-fixture", STATE_PLATFORM: "win32", STATE_CONTAINER: "legacy-fixture" }), expected("current-fixture"));
  });
  test(`${fixture}: mixed legacy state remains supported`, () => {
    assert.deepEqual(commands({ STATE_platform: "linux", STATE_CONTAINER: "legacy-fixture" }), expected("legacy-fixture"));
  });
  test(`${fixture}: missing container performs no Docker operation`, () => {
    assert.deepEqual(commands({ STATE_platform: "linux" }), []);
  });
  test(`${fixture}: unsupported platform performs no Docker operation`, () => {
    assert.deepEqual(commands({ STATE_platform: "win32", STATE_container: "fixture" }), []);
  });
  test(`${fixture}: explicitly empty state does not remove a legacy container`, () => {
    assert.deepEqual(commands({ STATE_platform: "linux", STATE_container: "", STATE_CONTAINER: "legacy-fixture" }), []);
  });
  for (const legacy of [false, true]) {
    test(`${fixture}: real post process removes ${legacy ? "legacy" : "saved"} fixture identity`, { skip: process.platform !== "linux" }, (context) => {
      const directory = scratch(context);
      const state = savedState(appendCommandValue, directory, fixture);
      const record = path.join(directory, "docker-calls");
      writeFileSync(path.join(directory, "docker"), '#!/usr/bin/env node\nimport("node:fs").then(({appendFileSync}) => appendFileSync(process.env.FIXTURE_DOCKER_CALLS, JSON.stringify(process.argv.slice(2)) + "\\n"));\n', { mode: 0o755 });
      const environment = { ...process.env, PATH: `${directory}:${process.env.PATH}`, FIXTURE_DOCKER_CALLS: record };
      for (const name of ["STATE_platform", "STATE_container", "STATE_PLATFORM", "STATE_CONTAINER"]) delete environment[name];
      for (const [name, value] of Object.entries(state.environment)) environment[legacy ? name.toUpperCase() : name] = value;
      const result = spawnSync(process.execPath, [fileURLToPath(post)], { env: environment, encoding: "utf8", timeout: 10000 });
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, result.stderr);
      assert.deepEqual(readFileSync(record, "utf8").trim().split("\n").map(JSON.parse), [["rm", "--force", state.container]]);
    });
  }
}
