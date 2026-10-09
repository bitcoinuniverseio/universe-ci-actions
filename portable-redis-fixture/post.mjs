import process from "node:process";
import { dockerCommand } from "./lib.mjs";

export function cleanup(environment = process.env, command = dockerCommand) {
  const platform = environment.STATE_platform ?? environment.STATE_PLATFORM;
  const container = environment.STATE_container ?? environment.STATE_CONTAINER;
  if (container && platform === "linux") {
    command(platform, ["rm", "--force", container], { capture: true, allowFailure: true });
  }
}

try {
  cleanup();
} catch (error) {
  console.error(`::error::Portable Redis cleanup failed: ${error.message}`);
  process.exitCode = 1;
}
