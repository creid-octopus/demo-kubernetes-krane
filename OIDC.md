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

## Annotations vs. labels — what Octopus actually reads

`Octopus.Action.Package[<ref>].Image.Labels[...]` appears to expose OCI
**manifest annotations**, not Docker **image config labels**. These are two
different metadata channels that share the `org.opencontainers.image.*` naming
convention, and a Dockerfile `LABEL` instruction writes only the second one.

The evidence, from `Kubernetes - Krane`:

- With attestations enabled, the only values Octopus reported were
  `vnd.docker.reference.digest` and `vnd.docker.reference.type` — annotations
  on the buildx attestation manifest.
- With attestations disabled, Octopus reported **no labels at all**, while the
  image itself carried all three expected labels:

  ```
  docker buildx imagetools inspect <image>:<tag> \
    --format '{{json .Image.Config.Labels}}'
  { "org.opencontainers.image.revision": "135edd59...",
    "org.opencontainers.image.source":   "https://github.com/...",
    "org.opencontainers.image.version":  "0.1.21-sha-135edd5" }
  ```

So both pipelines now pass explicit annotations as well as keeping the
Dockerfile `LABEL` block (the labels remain useful to anything inspecting the
image directly — `docker inspect`, registry UIs, scanners):

- Buildkite: `--annotation "org.opencontainers.image.revision=$BUILDKITE_COMMIT"` etc.
- GitHub Actions: the `annotations:` input on `docker/build-push-action`.

This conclusion is inference from those two observations, not confirmed
against Octopus's implementation — treat it as unverified until a build with
annotations shows up in a deployment's variable snapshot.
`scripts/validate-processtemplate.sh` falls back to parsing the `sha-<7 hex>`
suffix off the package version, which is the proven path, so the gate works
either way.

## Image attestations are disabled on purpose

Both pipelines build with attestations off — `--provenance=false --sbom=false`
on the Buildkite `docker build`, `provenance: false` / `sbom: false` on
`docker/build-push-action` in `publish.yml`.

With attestations on (BuildKit's default when pushing), a tag doesn't resolve
to an image — it resolves to an OCI image *index* holding two manifests:

```
Platform: linux/amd64          <- the actual image
Platform: unknown/unknown      <- attestation manifest
  Annotations:
    vnd.docker.reference.digest: sha256:...
    vnd.docker.reference.type:   attestation-manifest
```

Octopus surfaces the *attestation* manifest's annotations as the package's
`Octopus.Action.Package[<ref>].Image.Labels[...]` values, so the
`org.opencontainers.image.revision` label that `scripts/validate-release.sh`
reads is invisible, and the gate silently falls back to parsing the short SHA
out of the version string. A single-manifest push fixes it.

Secondary benefit: `docker pull` against a single-platform index fails on any
host whose platform isn't listed (e.g. pulling an amd64-only index onto an
arm64 Mac). Without the index, the plain image pulls fine.

## Octopus owns release creation, not the pipelines

Neither pipeline calls `release create` or `release deploy`. Both stop after
pushing the image. Release creation belongs to the project's **New Image
Version Pushed** trigger (`ProjectTriggers-21`), a feed filter on the
`validate-release` step's `demo-kubernetes-krane` package reference, whose
action is `CreateRelease` on the `Default` channel. Octopus polls the GHCR
feed roughly every 3 minutes; the `Fast Dev` lifecycle's Development phase has
`Environments-1` as an automatic deployment target, so the release deploys
itself from there.

Why this is better than driving it from CI:

- **It fixes a race.** The image push is what triggers the release, so
  creating the release in-pipeline meant deployments started seconds after the
  push — while the post-merge CI for that same commit was often still running.
  The `Validate Release` gate then blocked on "not completed yet", which is a
  timing artifact rather than a real failure. The feed's polling interval
  gives checks time to settle. (The gate polls too, so both halves tolerate
  the timing rather than depending on it.)
- **One release per image, not one per CI system.** With both pipelines
  creating releases, every merge produced two, on independent build counters.
- **The two pipelines converge.** Their only job now is "produce an image and
  its build information"; everything downstream is identical regardless of
  origin.

The cost: **release custom fields are gone.** A trigger-created release has no
way to set them, so `BuildUrl` / `CommitSha` / `Branch` are no longer stamped
on the release. That metadata isn't lost — it all lives in the build
information each pipeline uploads (`BuildUrl`, `BuildNumber`,
`BuildEnvironment`, `VcsCommitNumber`, `Branch`, and the per-commit
`Commits[]` array) — but it's reachable through build information and release
notes rather than as release fields.

**Ordering matters in both pipelines**: build information is uploaded *before*
the image is pushed. The push is the trigger, so anything the release needs
has to exist first, or the trigger can fire against a version with no build
information attached. Build information is keyed by package ID + version and
stored independently of the package, so uploading it before the image exists
is fine.

## Release custom fields (historical)

Superseded by the section above — releases are now created by the feed
trigger, which can't set custom fields. Kept because the reasoning still
applies to the equivalent build information fields, and in case release
creation ever moves back into the pipelines.

Both pipelines used to stamp three custom fields onto every release they
created (`--custom-field` on the CLI, `custom_fields:` on
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
