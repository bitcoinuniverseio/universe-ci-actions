# GCP runner image

Golden VM image for WarpBuild BYOC runners in GCP project `universe-507319`.

The runner arrives ready to work. No CI job spends time on `apt install`,
`install Node`, or downloading a toolchain: everything below is baked in.

## What is in it

Measured from all 218 workflow and action files across the 151 repositories in
the organization, then pinned to the versions AGENTS.md requires.

| tool | version | why |
|---|---|---|
| Node | 24.19.0 | 33 workflows pin it |
| npm | 11.17.0 | AGENTS.md pin |
| pnpm, Yarn | via corepack | no job-time download |
| Deno | latest | 16 workflows call setup-deno |
| Rust | 1.89.0 + clippy, rustfmt | 3 workflows pin it |
| Python | 3.11 + uv | 5 workflows pin it |
| Docker | 29.7.2 + buildx, compose | AGENTS.md pin |
| git, gh, jq, cmake, build-essential, OpenSSL headers | distro | used across the fleet |

Baking Docker 29.7.2 is what will let the `docker` runner class take cloud
overflow. That class is local-only today precisely because the cloud image
shipped a different engine and failed the version gate before building
anything.

## Build

```
gcloud auth login
packer init .
packer build -var-file=versions.pkrvars.hcl .
```

`verify.sh` runs inside the build and fails it if any pinned version drifts, so
a bad image never reaches a runner. Changing a version in
`versions.pkrvars.hcl` produces a new immutable image name rather than mutating
one in place.

## Capacity

`build_on_spot` is `false` while GCP project `universe-507319` is on the free
trial, because `PREEMPTIBLE_CPUS` there is 0 and a preemptible build host
cannot start. Set it to `true` once Spot quota exists: an image build is
interruptible work that belongs on Spot.

Routing and runner-class configuration live in
`bitcoinuniverseio/.github-private` under `infra/gcp/`.
