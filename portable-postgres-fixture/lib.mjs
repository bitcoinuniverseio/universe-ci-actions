import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { promises as dns } from "node:dns";
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
  validateConnectionHost(inputs.connectionHost);
}

export function validateConnectionHost(connectionHost) {
  if (!/^[A-Za-z0-9.:-]{1,253}$/.test(connectionHost)) throw new Error("Connection host is invalid");
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

/**
 * The address of the Docker bridge as seen from a container on it. When the
 * runner itself is a container, the host's published ports are reached
 * through this gateway (or through `host.docker.internal`, which maps to it
 * on a daemon started with `host-gateway`), never through the container's
 * own loopback.
 */
export function dockerBridgeGateway(platform) {
  const result = dockerCommand(platform, [
    "network", "inspect", "bridge", "--format", "{{(index .IPAM.Config 0).Gateway}}"
  ], { capture: true, allowFailure: true });
  const gateway = result.status === 0 ? result.stdout.trim() : "";
  return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(gateway) ? gateway : null;
}

/**
 * The hosts a caller may reach the fixture through, in the order they are
 * tried. An explicit `connection_host` is used as given and nothing else is
 * tried, so a caller that names the wrong topology fails loudly. `auto`
 * tries the runner's own loopback first (a runner running natively on the
 * Docker host), then the bridge gateway and `host.docker.internal` (a runner
 * that is itself a container).
 */
export function hostCandidates(requested, platform) {
  if (requested && requested !== "auto") return [requested];
  const candidates = ["127.0.0.1"];
  const gateway = dockerBridgeGateway(platform);
  if (gateway) candidates.push(gateway);
  candidates.push("host.docker.internal");
  return candidates;
}

export function tcpReachable(host, port, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ host, port });
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => { socket.destroy(); resolve(true); });
    socket.once("timeout", () => { socket.destroy(); resolve(false); });
    socket.once("error", () => resolve(false));
  });
}

/**
 * Wait until one of the candidate hosts accepts a TCP connection on the
 * published port and return that host. The fixture is already healthy inside
 * its container when this runs, so this proves the caller's route to it.
 */
/**
 * A name that answered is published as the address it resolved to. A
 * containerized runner resolves `host.docker.internal` through the engine's
 * embedded DNS, and that lookup is what intermittently fails later, inside the
 * tests, with EAI_AGAIN or a hook timeout. The route was proved once, to an
 * address; the address is what every later connection gets.
 */
export async function publishedAddress(host, port) {
  if (net.isIP(host)) return host;
  try {
    const { address } = await dns.lookup(host, { family: 4 });
    if (await tcpReachable(address, port)) return address;
  } catch {
    /* fall through: the name answered and is published as given */
  }
  return host;
}

export async function selectReachableHost(candidates, port, attempts = 60, service = "fixture") {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    for (const host of candidates) {
      if (await tcpReachable(host, port)) return publishedAddress(host, port);
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`${service} did not accept TCP connections on any of ${candidates.map((host) => `${host}:${port}`).join(", ")}`);
}

export async function waitForTcp(host, port, attempts = 60) {
  await selectReachableHost([host], port, attempts, "PostgreSQL fixture");
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
