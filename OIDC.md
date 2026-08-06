# OIDC integration with Octopus

Both CI systems in this repo (`.buildkite/pipeline.yml` and
`.github/workflows/publish.yml`) authenticate to Octopus (`creid.octopus.app`)
using OIDC instead of a stored API key. This doc covers the design decisions
that apply to *both* pipelines, so neither workflow file has to repeat them
inline. Each file keeps only the comments specific to its own steps.

## Service accounts

OIDC in Octopus only works for service accounts, one per automation source,
matching the existing `Automation-MCP` / `Automation-RunbookRunner`
convention:

| CI system  | Service account | Team                | Role                                                             |
| ---------- | ---------------- | -------------------- | ----------------------------------------------------------------- |
| Buildkite  | `SA-Buildkite`    | `Automation-Buildkite` | Built-in **Build server** role, scoped to the `Kubernetes - Krane` project |
| GitHub Actions | `SA-GHA`      | `Automation-GHA`     | Same — **Build server**, scoped to `Kubernetes - Krane`            |

**Build server** covers exactly what CI needs — push packages, create/update
build information, create releases, deploy — nothing broader.

## OIDC identity per issuer

Each service account has one OIDC identity, configured differently because
Buildkite and GitHub Actions are different classes of issuer in Octopus:

- **Buildkite** is an "Other Issuer" (no first-class UI support), so the
  identity is hand-configured: Issuer `https://agent.buildkite.com`, Subject
  `organization:octopus-deploy:pipeline:creid-oidc-buildinfo:ref:*:commit:*:step:*`
  (wildcarded on ref/commit/step since the pipeline's steps are still young —
  tighten later with `buildkite-agent oidc request-token --subject-claim
  pipeline_id` and the pipeline's UUID for an exact match), Audience = the
  service account's GUID. The pipeline requests its own token via
  `buildkite-agent oidc request-token` and exchanges it explicitly with
  `octopus login`.
- **GitHub Actions** has first-class support: issuer type "GitHub Actions" in
  the Octopus portal, Subject `repo:creid-octopus/*:ref:*` (any repo in the
  org, any branch/tag push — not PR-triggered or environment-scoped runs,
  which use a different subject shape entirely). The `OctopusDeploy/login`
  action requests and exchanges the token automatically; no manual token
  plumbing needed in the workflow.

## Facts both pipelines depend on

- **GHCR is registered as an external feed**, not a package upload target —
  `Feeds-1021` / `GHCR-creid-octopus`, pointing at `ghcr.io` as user
  `creid-octopus`. Neither pipeline runs a package-push step; they build and
  push the image straight to GHCR, then reference it by tag.
- **Package ID vs. `--package` for release create** — build information is
  keyed by the real feed package ID, `creid-octopus/demo-kubernetes-krane`.
  Release creation's `--package` flag is different: the confirmed working
  form, from the Octopus CLI's own interactive mode (which prints the
  equivalent non-interactive command), is a literal wildcard —
  `--package '*:<version>'` — meaning "use this version for every package
  in the release," not "use this version for this specific package." For
  this project's single-package deployment process that lands the same as
  naming the package reference explicitly (`demo-kubernetes-krane:<version>`,
  untested but likely equally valid). Worth naming it explicitly instead of
  `*` if this project ever grows a second package, so a new release doesn't
  silently apply the same version to both. `OctopusDeploy/create-release-action`'s
  `package_version` input is the GitHub Actions equivalent of the wildcard
  form, which is why `publish.yml` never had to make this choice.
- **The `Default` channel has a version rule**: the package version must
  carry a `sha-<7 hex chars>` pre-release tag to match it. Both pipelines
  compute version as `{major}.{minor}.{build number}-sha-{short commit sha}`
  for this reason — a plain incrementing counter won't land in `Default`.
- **Both pipelines build the image themselves**, rather than depending on a
  separate build workflow having already pushed it. The reason: `main` gets
  builds triggered from more than one place (CI systems, manual dispatch),
  and any counter-based versioning scheme (GitHub's `run_number`, Buildkite's
  build number) is scoped per-workflow/pipeline, not per-commit — a shared
  build step's version would only coincidentally match what a downstream
  step recomputes independently, and one out-of-band manual run desyncs them
  permanently. Building the image inline sidesteps that at the cost of
  building it more than once per merge across the two systems — an accepted
  tradeoff while both are running in parallel.

## Release custom fields

Both pipelines stamp the same three custom fields onto every release they
create (`--custom-field` on the CLI, `custom_fields:` on
`OctopusDeploy/create-release-action`):

| Field       | Value                                          |
| ----------- | ---------------------------------------------- |
| `BuildUrl`  | Direct link to the CI run that made the release |
| `CommitSha` | Full 40-char commit SHA                         |
| `Branch`    | Branch the build ran on                         |

Two decisions worth keeping:

- **No `BuildNumber`.** A build counter is a reliable backtrackable identity
  when one CI system owns the project — it stops being one the moment two do,
  because Buildkite's build number and GitHub's `run_number` increment
  independently and can collide on the same value while pointing at entirely
  different builds. (This is the same mismatch that made a perfectly healthy
  image look missing from the GHCR feed: `.8` from Buildkite where `.18` was
  expected from Actions.) `BuildUrl` is unambiguous, still embeds the number,
  and is directly clickable.
- **Values render as plain text.** Custom fields do *not* resolve Markdown, so
  a `[#12](url)` value displays literally. URLs go in raw.

Unlike build information, custom fields live on the release resource itself
and are readable anywhere — including from deployment steps, which is where
`Octopus.Release.Package` / `Octopus.Release.Builds` are unavailable.

## Where the actual pipeline logic lives

- Buildkite: `.buildkite/pipeline.yml`
- GitHub Actions: `.github/workflows/publish.yml`
