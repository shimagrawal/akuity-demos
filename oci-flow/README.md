# OCI flow

Promote nginx through `dev → test → prod`, delivering rendered manifests as
**one OCI artifact** that every stage deploys by digest. No stage branches, and
prod runs exactly the bytes dev produced.

```
Warehouse (nginx tag + oci-flow/app commit) → Freight
                                │
dev   (oci-publish):  git-clone <freight commit> → kustomize-set-image
                      → kustomize-build dev  → ./out/dev
                      → kustomize-build test → ./out/test
                      → kustomize-build prod → ./out/prod
                      → tar → oci-push :<freight>  → retag :latest
                      → set-metadata (digest → Freight)
                      → argocd-update oci-flow-nginx-dev  @ sha256:X
test  (oci-deploy):   argocd-update oci-flow-nginx-test   @ sha256:X  (from Freight)
prod  (oci-deploy):   argocd-update oci-flow-nginx-prod   @ sha256:X  (from Freight)

Argo CD: every app → oci://ghcr.io/…/oci-flow/nginx @ sha256:X, path: <stage>
```

The artifact holds every stage, and each Application reads its own folder:

```
sha256:X
├── dev/manifests.yaml
├── test/manifests.yaml
└── prod/manifests.yaml
```

Requires Kargo v1.12.0+ (`tar` step and `oci-push` `srcPath`) and Argo CD with
OCI source support.

## Setup

From the repository root, after `cp .env.example .env` and `akuity login`:

```bash
task check
task oci:render-all         # optional: build the artifact layout locally into oci-flow/.out
task oci:setup
```

| Created | Where |
|---|---|
| AppProject `oci-flow`, ApplicationSet `oci-flow` → apps `oci-flow-nginx-{dev,test,prod}` | Argo CD |
| Project `oci-flow`, Secrets `gitops-repo` (git) and `ghcr` (image), Warehouse `nginx`, PromotionTasks `oci-publish` and `oci-deploy`, Stages `dev`, `test`, `prod` | Kargo |

The Applications show an error until the first dev promotion pushes the
`:latest` tag.

## First promotion

1. Promote the newest Freight to `dev` in the Kargo UI. Use Freight that has
   both an image and a commit: Freight from before the Warehouse watched Git
   has no commit, and `oci-publish` needs one.
2. The `push` step creates the GHCR package `akuity-demos/oci-flow/nginx`,
   which is private by default. This demo keeps it **public**: GitHub →
   Packages → the package → Package settings → Change visibility → Public.
3. Promote the same Freight to `test`, then `prod`.

## Check it

- All three Applications show the **same** `sha256:` revision, matching the
  dev promotion's `push` step `digest` output, with `path` `dev`, `test` and
  `prod`.
- `task oci:port-forward STAGE=dev` → http://localhost:8080 shows
  **NGINX - DEV** (`STAGE=test PORT=8081`, `STAGE=prod PORT=8082` likewise).
- The repository has no `stage/*` branches.

## Things to know

- **Config changes enter at dev.** Editing `app/overlays/prod` creates new
  Freight (the Warehouse watches `oci-flow/app`), but prod only gets it after
  that Freight passes dev and test. That is the point: prod never runs config
  that dev did not render.
- **Adding a stage** means adding a `kustomize-build` step to `oci-publish`, a
  Stage, and a list element in the ApplicationSet. Promotion steps cannot loop.
- **Every stage's manifests are in every artifact.** Fine here; never put
  Secrets in rendered manifests, especially in a public package.
- `tar` must have `gzip: true`. It defaults to uncompressed, `oci-push` labels
  the layer as gzip, and Argo CD cannot read the mismatch — while the promotion
  still goes green.
- `argocd-update` needs the **digest** as `desiredRevision`. A tag never
  matches what Argo CD records, and the step waits until it times out.
- GHCR needs a **classic** PAT with `write:packages`, and repository names
  must be lowercase.
