# OCI flow

Promote nginx through `dev → test → prod`, delivering rendered manifests as OCI
artifacts instead of Git branches.

```
Warehouse (nginx tags) → Freight
                           │
Stage promotion:  git-clone main → kustomize-set-image → kustomize-build
                  → tar (gzip) → oci-push ghcr.io/…/oci-flow/nginx:<stage>
                  → argocd-update (desiredRevision = pushed digest)
                           │
Argo CD:          oci-flow-nginx-<stage>  source oci://ghcr.io/…/oci-flow/nginx @ sha256:…
                  → namespace oci-flow-<stage>
```

Requires Kargo v1.12.0+ (`tar` step and `oci-push` `srcPath`) and Argo CD with
OCI source support.

## Setup

From the repository root, after `cp .env.example .env` and `akuity login`:

```bash
task check
task oci:render STAGE=dev   # optional: preview what dev renders
task oci:setup
```

| Created | Where |
|---|---|
| AppProject `oci-flow`, ApplicationSet `oci-flow` → apps `oci-flow-nginx-{dev,test,prod}` | Argo CD |
| Project `oci-flow`, Secrets `gitops-repo` (git) and `ghcr` (image), Warehouse `nginx`, PromotionTask `oci-promotion`, Stages `dev`, `test`, `prod` | Kargo |

The Applications show **Unknown** until the first promotion pushes the
`:<stage>` tag.

## First promotion

1. Promote the newest Freight to `dev` in the Kargo UI.
2. The `push` step creates the GHCR package `akuity-demos/oci-flow/nginx`,
   which is private by default. Make it public: GitHub → Packages → the
   package → Package settings → Change visibility → Public.
3. Re-run the `dev` promotion if `deploy` failed waiting on Argo CD.

## Check it

- Argo CD shows `oci-flow-nginx-dev` with an `oci://` source and a `sha256:`
  revision matching the `push` step's `digest` output.
- `task oci:port-forward STAGE=dev` → http://localhost:8080 shows **NGINX - DEV**.
- The repository has no `stage/*` branches.

Then promote to `test` and `prod` (`task oci:port-forward STAGE=test PORT=8081`).

## Gotchas

- `tar` must have `gzip: true`. It defaults to uncompressed, `oci-push` labels
  the layer as gzip, and Argo CD cannot read the mismatch — while the promotion
  still goes green.
- `argocd-update` needs the **digest** as `desiredRevision`. A tag never
  matches what Argo CD records, and the step waits until it times out.
- GHCR needs a **classic** PAT with `write:packages`, and repository names
  must be lowercase.
