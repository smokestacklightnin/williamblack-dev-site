+++
title = "williamblack.dev"
description = "A static personal site served from Cloudflare R2, with infrastructure managed by OpenTofu and a GitHub Actions deploy pipeline."
date = 2026-05-14
slug = "williamblack-dev"
+++

This site, the one you're reading right now, is a Hugo-built static site
served directly from a Cloudflare R2 bucket bound to the apex domain. Every
moving piece, from the GCS state bucket to the Cloudflare rulesets that fix
up directory URLs, is declared in OpenTofu and reconciled from version
control. Deploys happen automatically from GitHub Actions on every push to
`main`.

I wanted three things from this setup:

1. **Reproducibility**: I can tear the whole stack down and rebuild it
   from code, including the state backend.
2. **Cheap to run**: static assets on R2 with zero egress fees, no
   compute to babysit.
3. **No long-lived cloud credentials in GitHub**: deploys authenticate
   via OIDC where possible, and the rest live in scoped repo secrets.

## Infrastructure with OpenTofu

The infrastructure lives in a separate repository and is split into two
OpenTofu layers.

### Bootstrap layer

The bootstrap layer provisions the resources that have to exist *before* a
remote state backend can: a GCS bucket to hold Terraform state, a KMS
keyring and CMEK with a 90-day rotation policy to encrypt that bucket, and
the IAM bindings that let GCS encrypt objects with the key. The bucket is
versioned, has uniform bucket-level access, and explicitly enforces
`public_access_prevention`.

I picked GCS over a second R2 bucket for state storage because OpenTofu
state benefits from features GCS exposes natively: customer-managed
encryption at rest with key rotation, object versioning so I can recover
from a corrupted apply, and built-in state locking as a first-class
backend. R2 only works through the `s3` backend shim against the
S3-compatible API and doesn't expose an equivalent locking primitive,
which is a poor fit for shared state that needs to be applied safely
from both CI and a local machine.

After the first apply, the layer writes its own `backend.tf` to disk so
subsequent applies of the bootstrap layer migrate into the remote backend
it just created. It's a small chicken-and-egg trick that keeps the layer
self-hosting.

### App layer

The app layer wires together the actual public-facing site:

- A **Cloudflare R2 bucket** named with a random ID so the resource is
  stable across re-creations.
- A **`cloudflare_r2_custom_domain`** that binds the bucket to
  `williamblack.dev` and creates the apex A/AAAA records server-side, with
  TLS 1.3 as the floor.
- A **proxied `AAAA` sinkhole record** for `www.williamblack.dev` pointing
  at the RFC 6666 discard prefix. The address is ignored at the edge, but
  the proxied flag means Cloudflare actually receives the request so the
  redirect ruleset can run.
- An **`http_request_transform` ruleset** that appends `index.html` to any
  path ending in `/`, so directory-style URLs resolve against the bucket
  layout Hugo emits.
- An **`http_request_dynamic_redirect` ruleset** that 301s `www` to the
  apex, preserving the request path and query string.
- A **Google Workload Identity Pool** and OIDC provider for GitHub
  Actions, scoped by `repository_owner` so only my repos can mint tokens,
  with per-repo `iam.workloadIdentityUser` bindings to a dedicated
  `tofu-app-infra` service account.

State for this layer is stored under the `app-infra` prefix in the same
GCS bucket the bootstrap layer created, encrypted with the same KMS key.

## Hugo and the hugo-coder theme

The site itself is built with [Hugo](https://gohugo.io/) using the
[hugo-coder](https://github.com/luizdepra/hugo-coder) theme, vendored in
as a git submodule. Content lives as a handful of Markdown files under
`content/` (`about.md`, `experience.md`, this `projects/` section, and
`contact.md`), and the theme handles the rest. The site config in
`hugo.toml` sets up the menu, the social links, and the dark/light color
scheme toggle.

The Hugo binary itself is pinned by SHA in a `.hugo_version` file and run
through Docker so local builds, CI builds, and any future contributors
all produce byte-identical output. The `Makefile` exposes three targets
(`make init`, `make dev`, `make build`) that wrap `docker compose` and
`docker run` so I never have to remember the exact incantation.

## Deploying from GitHub Actions

Two workflows live under `.github/workflows/`:

- **`checks.yml`** runs `pre-commit` on every PR and every push to `main`,
  with the pre-commit environment cached by config hash.
- **`deploy.yml`** is the actual deploy pipeline.

`deploy.yml` triggers on PRs (to confirm the site still builds), on
pushes to `main`, and on manual `workflow_dispatch`. Direct pushes to
`main` are forbidden in both the site and infrastructure repositories by
branch protection rules, so in practice the `push` trigger only fires
when a pull request merges to `main`. Every deploy has gone through
code review and passing checks before it can run. The job:

1. Checks out the repo with `submodules: recursive` so the hugo-coder
   theme is present.
2. Runs `make build`, which invokes the pinned Hugo Docker image against
   the site directory with `--minify`. This step runs on every trigger,
   so a broken build fails the PR before it can merge.
3. **Only on pushes to `main`**, syncs `williamblack-dev/public/` to the
   R2 bucket using `aws s3 sync --delete` against R2's S3-compatible
   endpoint. Credentials come from repo secrets, and the `--delete` flag
   keeps the bucket in lockstep with the build output.

A `concurrency` group on `deploy-site` with `cancel-in-progress: false`
makes sure two pushes in quick succession don't race each other into the
bucket.

The full path from `git push` to live site is roughly: GitHub Actions
runner pulls the pinned Hugo image, builds the site inside the container,
then streams the output to R2 over the S3 API. Cloudflare's edge serves
the bucket directly via the R2 custom domain binding, and the transform
ruleset rewrites trailing-slash URLs to `index.html` so the URL structure
Hugo generates Just Works.

## Source

- **Site**: [github.com/smokestacklightnin/williamblack-dev-site](https://github.com/smokestacklightnin/williamblack-dev-site)
- **Infrastructure**: [github.com/smokestacklightnin/williamblack-dev-infra](https://github.com/smokestacklightnin/williamblack-dev-infra)

## Takeaways

- **Full-stack control was the point.** Cloudflare Pages would have
  built and deployed the site with a single connector and almost no
  infrastructure code. I went with R2 plus a Hugo build in CI instead
  because I wanted every piece of the pipeline (the bucket, the DNS,
  the `www`-to-apex redirect, the directory-path rewrite, the OIDC
  trust against GCP) to live in version-controlled OpenTofu that I can
  audit, diff, and rebuild from scratch. The trade-off is that I now
  own a small handful of resources Pages would have hidden behind a
  single managed product, and that's fine because owning them was the
  goal.

- **State belongs in GCS, not in another R2 bucket.** The deployed site
  is fine on R2, but OpenTofu state is a different workload with
  stricter requirements: customer-managed encryption at rest with key
  rotation, object versioning so I can recover from a bad apply, and a
  first-class backend with built-in state locking. R2 only works
  through the `s3` backend shim against the S3-compatible API and
  doesn't expose an equivalent locking primitive, which is a poor fit
  for shared state that has to be applied safely from both CI and a
  local machine.

- **The bootstrap layer is how I solved the chicken-and-egg problem.**
  Remote state needs a bucket. The bucket has to be provisioned by
  OpenTofu. OpenTofu wants a backend. The bootstrap layer breaks that
  cycle: it starts with no backend configured at all, creates the GCS
  bucket, KMS keyring, and IAM bindings under local state, then writes
  its own `backend.tf` to disk. The next apply migrates the bootstrap
  layer's state *into* the bucket it just created, and from then on
  the layer is self-hosting: it lives in the same backend it was
  responsible for standing up.
