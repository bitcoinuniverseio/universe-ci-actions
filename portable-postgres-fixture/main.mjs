import process from "node:process";
import {
  DOCKER_VERSION,
  appendCommandValue,
  dockerCommand,
  requiredInput,
  sanitizedIdentity,
  validateFixtureInputs,
  waitForPostgres,
  waitForTcp
} from "./lib.mjs";

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
    password: requiredInput("password")
  };
  validateFixtureInputs(inputs);

  const container = `universe-ci-postgres-${sanitizedIdentity()}`;
  const publishAddress = "127.0.0.1::5432";
  dockerCommand(platform, [
    "run", "--detach", "--name", container,
    "--label", `universe.ci.run=${process.env.GITHUB_RUN_ID}`,
    "--env", `POSTGRES_DB=${inputs.database}`,
    "--env", `POSTGRES_USER=${inputs.user}`,
    "--env", `POSTGRES_PASSWORD=${inputs.password}`,
    "--publish", publishAddress,
    inputs.image
  ]);
  appendCommandValue(process.env.GITHUB_STATE, "container", container);

  const port = dockerCommand(platform, ["port", container, "5432/tcp"], { capture: true }).stdout.trim().match(/:(\d+)$/)?.[1];
  if (!port) throw new Error(`Docker did not report a host port for ${container}`);
  const host = "127.0.0.1";
  await waitForPostgres(platform, container, inputs.database, inputs.user);
  await waitForTcp(host, Number(port));

  appendCommandValue(process.env.GITHUB_OUTPUT, "host", host);
  appendCommandValue(process.env.GITHUB_OUTPUT, "port", port);
  appendCommandValue(process.env.GITHUB_OUTPUT, "container", container);
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
