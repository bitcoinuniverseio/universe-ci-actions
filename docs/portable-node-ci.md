# `portable-node-ci`

Runs the shared Node build and test contract in one step: resolve Node, pin npm,
install, optionally audit, build, test.

**Prefer [`universe-node-env`](universe-node-env.md) for anything on the Linux
fleet.** `portable-node-ci` uses `actions/setup-node`, which downloads a Node.js
distribution instead of selecting the one already in the runner's tool cache, and
it runs `npm ci` on every job instead of reusing an exact dependency tree. It
exists for jobs that need the whole contract in one step under PowerShell.

## Usage

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: bitcoinuniverseio/universe-ci-actions/portable-node-ci@be40d57392687ec250a02b1096cb1c4db5782b74
  with:
    node-version-file: .nvmrc
    audit-script: audit:prod
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `node-version-file` | empty | Repository-relative Node version file. Used when present. |
| `node-version` | `24.19.0` | Version used when no version file is given or found. |
| `audit-script` | empty | An npm script to run before the build. Skipped when empty. |

No outputs.

## What it runs

1. **Resolve the Node version.** The version file if it exists, otherwise
   `node-version`. An empty result fails the step.
2. **`actions/setup-node`** with that version.
3. **Pin npm to 11.17.0.** Installs it if the resolved npm differs, then fails
   the step if it still differs.
4. **Install.** `npm ci --legacy-peer-deps` when a `package-lock.json` exists,
   otherwise `npm install --legacy-peer-deps`.
5. **Audit,** only when `audit-script` is set.
6. **Build.** `npm run build --if-present`.
7. **Test.** `npm test --if-present`, with `CI=true`. A repository whose
   `package.json` mentions `react-scripts` gets
   `npm test -- --watchAll=false --passWithNoTests` instead, because the default
   would otherwise hang in watch mode.

Every step runs `shell: pwsh`.

## Choosing between the two

| | `universe-node-env` | `portable-node-ci` |
| --- | --- | --- |
| Toolchain | Selected from the tool cache, no download | Downloaded by `actions/setup-node` |
| Dependencies | Exact tree reused, content-addressed | `npm ci` every job |
| Build and test | You write the steps | Included |
| Shell | bash | pwsh |
| Use it when | Anything on the Linux fleet | You need the whole contract in one step under PowerShell |
