import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import net from "node:net";

export const DOCKER_VERSION = "29.7.2";

export function sanitizedIdentity(environment = process.env) {
  const identity = [
    environment.GITHUB_RUN_ID,
    environment.GITHUB_RUN_ATTEMPT,
    environment.GITHUB_JOB,
    environment.RUNNER_NAME
  ].join("-").toLowerCase().replace(/[^a-z0-9_.-]/g, "-");
  if (!identity || identity.replace(/-/g, "").length === 0) {
    throw new Error("GitHub Actions run identity is unavailable");
  }
  return identity.slice(0, 90);
}

export function requiredInput(name, environment = process.env) {
  const value = environment[`INPUT_${name.toUpperCase()}`]?.trim();
  if (!value) throw new Error(`Missing required input: ${name}`);
  return value;
}

export function validateFixtureInputs(inputs) {
  if (!inputs.image.includes("@sha256:")) throw new Error("PostgreSQL image must be pinned by sha256 digest");
  if (!/^[A-Za-z0-9_]{1,63}$/.test(inputs.database)) throw new Error("Database name is invalid");
  if (!/^[A-Za-z0-9_]{1,63}$/.test(inputs.user)) throw new Error("Database user is invalid");
  if (inputs.user.toLowerCase() === "postgres") throw new Error("The fixture user must not be postgres");
}

export function command(program, args, options = {}) {
  const result = spawnSync(program, args, {
    encoding: "utf8",
    windowsHide: true,
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : ["ignore", "inherit", "inherit"]
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure) {
    const detail = options.capture ? `: ${(result.stderr || result.stdout).trim()}` : "";
    throw new Error(`${program} exited with ${result.status}${detail}`);
  }
  return result;
}

export function dockerCommand(platform, args, options = {}) {
  if (platform !== "linux") throw new Error(`Unsupported runner platform: ${platform}`);
  return command("docker", args, options);
}

export function appendCommandValue(path, name, value) {
  if (!path) throw new Error(`GitHub command file is unavailable for ${name}`);
  appendFileSync(path, `${name}=${value}\n`, "utf8");
}

export async function waitForTcp(host, port, attempts = 60) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const connected = await new Promise((resolve) => {
      const socket = net.createConnection({ host, port });
      socket.setTimeout(1000);
      socket.once("connect", () => { socket.destroy(); resolve(true); });
      socket.once("timeout", () => { socket.destroy(); resolve(false); });
      socket.once("error", () => resolve(false));
    });
    if (connected) return;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`PostgreSQL fixture did not accept TCP connections on ${host}:${port}`);
}

export async function waitForPostgres(platform, container, database, user, attempts = 90) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const result = dockerCommand(platform, [
      "exec", container, "pg_isready", "--host=127.0.0.1", `--username=${user}`, `--dbname=${database}`
    ], { capture: true, allowFailure: true });
    if (result.status === 0) return;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`PostgreSQL fixture ${container} did not become healthy`);
}
