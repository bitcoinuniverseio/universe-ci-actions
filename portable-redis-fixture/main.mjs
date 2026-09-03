import process from "node:process";
import {
  DOCKER_VERSION,
  appendCommandValue,
  dockerCommand,
  hostCandidates,
  requiredInput,
  sanitizedIdentity,
  selectReachableHost,
  validateConnectionHost,
  waitForRedis
} from "./lib.mjs";

let container;

async function main() {
  const platform = process.platform;
  appendCommandValue(process.env.GITHUB_STATE, "platform", platform);
  if (platform !== "linux") throw new Error(`Unsupported runner platform: ${platform}`);

  const version = dockerCommand(platform, ["version", "--format", "{{.Server.Version}}"], { capture: true }).stdout.trim();
  if (version !== DOCKER_VERSION) throw new Error(`Expected Docker ${DOCKER_VERSION}, received ${version}`);

  const inputs = {
    image: requiredInput("image"),
    connectionHost: process.env.INPUT_CONNECTION_HOST?.trim() || "auto"
  };
  if (!inputs.image.includes("@sha256:")) throw new Error("Redis image must be pinned by sha256 digest");
  validateConnectionHost(inputs.connectionHost);

  container = `universe-ci-redis-${sanitizedIdentity()}`;
  dockerCommand(platform, [
    "run", "--detach", "--name", container,
    "--label", `universe.ci.run=${process.env.GITHUB_RUN_ID}`,
    "--publish", "127.0.0.1::6379",
    inputs.image
  ]);
  appendCommandValue(process.env.GITHUB_STATE, "container", container);

  const port = dockerCommand(platform, ["port", container, "6379/tcp"], { capture: true }).stdout.trim().match(/:(\d+)$/)?.[1];
  if (!port) throw new Error(`Docker did not report a host port for ${container}`);
  await waitForRedis(platform, container);
  const host = await selectReachableHost(hostCandidates(inputs.connectionHost, platform), Number(port), 60, "Redis fixture");
  console.log(`Redis fixture ${container} reachable at ${host}:${port}`);

  appendCommandValue(process.env.GITHUB_OUTPUT, "host", host);
  appendCommandValue(process.env.GITHUB_OUTPUT, "port", port);
  appendCommandValue(process.env.GITHUB_OUTPUT, "container", container);
  appendCommandValue(process.env.GITHUB_OUTPUT, "url", `redis://${host}:${port}`);
}

main().catch((error) => {
  if (container) {
    dockerCommand(process.platform, ["rm", "--force", container], {
      capture: true,
      allowFailure: true
    });
  }
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
