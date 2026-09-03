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
  waitForMysql
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
    rootPassword: requiredInput("root_password"),
    connectionHost: process.env.INPUT_CONNECTION_HOST?.trim() || "auto"
  };
  validateFixtureInputs(inputs);

  container = `universe-ci-mysql-${sanitizedIdentity()}`;
  const publishAddress = "127.0.0.1::3306";
  dockerCommand(platform, [
    "run", "--detach", "--name", container,
    "--label", `universe.ci.run=${process.env.GITHUB_RUN_ID}`,
    "--env", `MYSQL_DATABASE=${inputs.database}`,
    "--env", `MYSQL_USER=${inputs.user}`,
    "--env", `MYSQL_PASSWORD=${inputs.password}`,
    "--env", `MYSQL_ROOT_PASSWORD=${inputs.rootPassword}`,
    "--publish", publishAddress,
    // Fixture data lives in memory: sixty-four concurrent jobs on one NVMe
    // made InnoDB initialisation take minutes on disk, and a fixture never
    // needs to survive the job.
    "--tmpfs", "/var/lib/mysql:rw,size=3g",
    inputs.image,
    // Test runners share finite host AIO capacity with other isolated jobs.
    // MySQL's synchronous fallback is sufficient for fixtures and prevents a
    // host-wide io_setup(EAGAIN) from making clean-schema checks flaky.
    "--skip-innodb-use-native-aio"
  ]);
  appendCommandValue(process.env.GITHUB_STATE, "container", container);

  const port = dockerCommand(platform, ["port", container, "3306/tcp"], { capture: true }).stdout.trim().match(/:(\d+)$/)?.[1];
  if (!port) throw new Error(`Docker did not report a host port for ${container}`);
  await waitForMysql(platform, container, inputs.rootPassword);
  // The fixture is healthy. Now prove the caller's route to it: a runner on
  // the Docker host reaches the published port on its own loopback, a runner
  // that is itself a container reaches it through the bridge gateway or
  // host.docker.internal. The host that answered is the host published.
  const host = await selectReachableHost(hostCandidates(inputs.connectionHost, platform), Number(port), 60, "MySQL fixture");
  console.log(`MySQL fixture ${container} reachable at ${host}:${port}`);

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
