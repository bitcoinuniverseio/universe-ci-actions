import process from "node:process";
import {
  DOCKER_VERSION,
  appendCommandValue,
  dockerCommand,
  hostCandidates,
  requiredInput,
  sanitizedIdentity,
  selectReachableHost,
  validateFixtureInputs,
  waitForPostgres
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
    database: requiredInput("database"),
    user: process.env.INPUT_USER?.trim() || "universe_ci",
    password: requiredInput("password"),
    connectionHost: process.env.INPUT_CONNECTION_HOST?.trim() || "auto"
  };
  validateFixtureInputs(inputs);

  container = `universe-ci-postgres-${sanitizedIdentity()}`;
  const publishAddress = "127.0.0.1::5432";
  dockerCommand(platform, [
    "run", "--detach", "--name", container,
    "--label", `universe.ci.run=${process.env.GITHUB_RUN_ID}`,
    "--env", `POSTGRES_DB=${inputs.database}`,
    "--env", `POSTGRES_USER=${inputs.user}`,
    "--env", `POSTGRES_PASSWORD=${inputs.password}`,
    "--publish", publishAddress,
    // Fixture data lives in memory; see the MySQL fixture.
    "--tmpfs", "/var/lib/postgresql/data:rw,size=3g",
    inputs.image
  ]);
  appendCommandValue(process.env.GITHUB_STATE, "container", container);

  const port = dockerCommand(platform, ["port", container, "5432/tcp"], { capture: true }).stdout.trim().match(/:(\d+)$/)?.[1];
  if (!port) throw new Error(`Docker did not report a host port for ${container}`);
  await waitForPostgres(platform, container, inputs.database, inputs.user);
  // The fixture is healthy. Now prove the caller's route to it: a runner on
  // the Docker host reaches the published port on its own loopback, a runner
  // that is itself a container reaches it through the bridge gateway or
  // host.docker.internal. The host that answered is the host published.
  const host = await selectReachableHost(hostCandidates(inputs.connectionHost, platform), Number(port), 60, "PostgreSQL fixture");
  console.log(`PostgreSQL fixture ${container} reachable at ${host}:${port}`);

  appendCommandValue(process.env.GITHUB_OUTPUT, "host", host);
  appendCommandValue(process.env.GITHUB_OUTPUT, "port", port);
  appendCommandValue(process.env.GITHUB_OUTPUT, "container", container);
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
