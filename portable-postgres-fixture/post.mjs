import process from "node:process";
import { dockerCommand } from "./lib.mjs";

function cleanup() {
  const platform = process.env.STATE_PLATFORM;
  const container = process.env.STATE_CONTAINER;
  if (container && platform === "linux") {
    dockerCommand(platform, ["rm", "--force", container], { capture: true, allowFailure: true });
  }
}

try {
  cleanup();
} catch (error) {
  console.error(`::error::Portable PostgreSQL cleanup failed: ${error.message}`);
  process.exitCode = 1;
}
