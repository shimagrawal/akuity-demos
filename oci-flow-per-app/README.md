# OCI flow, one artifact per app

The same two apps as [`oci-flow`](../oci-flow), **nginx** (Kustomize) and
**hello** (Helm), rendered once and deployed by digest, but shaped for many
apps:

- **One OCI artifact per app**, not one artifact for everything: smaller
  artifacts, and each Argo CD Application pulls only its own app.
- **The artifact is the Freight.** A Warehouse per app watches that app's
  artifact repository, so a new push becomes new Freight. dev, test and prod
  promote it like any image: no `set-metadata`, no `freightMetadata()`.
- **One pipeline per app.** nginx and hello move through dev → test → prod
  independently.

```
Warehouse sources (nginx tag + oci-flow-per-app/apps commit) → Freight
                                │
render  (oci-publish):  git-clone <freight commit> → kustomize-set-image
                        → kustomize-build nginx ×3 → ./out/nginx/<stage>
                        → helm-template   hello ×3 → ./out/hello/<stage>
                        → per app: tar → oci-push :<freight> → retag :latest
                        (deploys nothing)
                                │
          ┌─────────────────────┴─────────────────────┐
Warehouse nginx-manifests                  Warehouse hello-manifests
  (digest behind oci-flow-per-app/nginx:latest)   (…/hello:latest)
          │ Freight = nginx artifact                  │ Freight = hello artifact
          ▼                                           ▼
nginx-dev → nginx-test → nginx-prod        hello-dev → hello-test → hello-prod
  (oci-deploy: argocd-update @ imageFrom(<artifact>).Digest)

Argo CD: oci-flow-per-app-<app>-<stage> → oci://ghcr.io/…/oci-flow-per-app/<app>
         @ sha256:…, path: <stage>
```

Each artifact holds one app for every stage, and each Application reads its own
folder:

```
oci-flow-per-app/nginx@sha256:N      oci-flow-per-app/hello@sha256:H
├── dev/                             ├── dev/
├── test/                            ├── test/
└── prod/                            └── prod/
```

## Compared with `oci-flow`

| | `oci-flow` | `oci-flow-per-app` |
|---|---|---|
| Artifacts | one, with every app | one per app |
| How test and prod get the digest | dev records it on the source Freight (`set-metadata`); they read it back (`freightMetadata()`) | it *is* the Freight they promote (`imageFrom(...).Digest`) |
| Warehouses | 1 | 1 for sources + 1 per app |
| Stages | dev, test, prod | render + dev, test, prod per app |
| Apps promote | together | independently |
| One app's chart breaks | every app is blocked | `render` fails, so new renders of every app are blocked; what is already rendered keeps promoting |

`oci-flow` is simpler for a few apps that ship together. This layout scales to
many apps; with hundreds you would generate the per-app Warehouses, Stages and
Applications rather than write them.

## Setup

From the repository root, after `cp .env.example .env` and `akuity login`:

```bash
task check
task oci-per-app:setup
```

| Created | Where |
|---|---|
| AppProject `oci-flow-per-app`, ApplicationSet `oci-flow-per-app` → apps `oci-flow-per-app-{nginx,hello}-{dev,test,prod}` | Argo CD |
| Project `oci-flow-per-app`, Secrets `gitops-repo` (git) and `ghcr` (image, every repository under `oci-flow-per-app/`), Warehouses `sources`, `nginx-manifests`, `hello-manifests`, PromotionTasks `oci-publish` and `oci-deploy`, Stages `render`, `{nginx,hello}-{dev,test,prod}` | Kargo |

The Applications, and the two `-manifests` Warehouses, show an error until the
first `render` promotion pushes the artifacts.

## First promotion

1. Promote the newest `sources` Freight to `render`. Use Freight that has both
   an image and a commit.
2. The pushes create the GHCR packages `akuity-demos/oci-flow-per-app/nginx`
   and `akuity-demos/oci-flow-per-app/hello`, which are private by default.
   Make both **public**: GitHub → Packages → the package → Package settings →
   Change visibility → Public.
3. Refresh the `nginx-manifests` and `hello-manifests` Warehouses (or wait up
   to 5 minutes): each shows new Freight for its artifact.
4. Promote the nginx Freight to `nginx-dev`, then `nginx-test`, then
   `nginx-prod`. Same for hello.

## Check it

- `oci-flow-per-app-nginx-{dev,test,prod}` show the **same** `sha256:`
  revision, matching the `render` promotion's `pushNginx` step output; the
  hello Applications share another one (`pushHello`).
- `task oci-per-app:port-forward STAGE=dev` → http://localhost:8080 shows
  **NGINX - DEV**; `task oci-per-app:port-forward STAGE=dev APP=hello PORT=8081`
  → `Hello from Helm - DEV`. Same for `test` and `prod`.

## Things to know

- **Every render gives every app new Freight**, even an app whose manifests
  did not change: Kargo's `tar` step records each file's modification time, so
  the same manifests never produce the same digest twice. The apps still move
  independently (promote only the app you mean to), but each app's Warehouse
  shows Freight for every render. To render only what changed, give each app
  its own source Warehouse (`includePaths: [oci-flow-per-app/apps/<app>]`)
  and render Stage.
- **The `latest` tag drives discovery.** The `-manifests` Warehouses use
  `imageSelectionStrategy: Digest` on `latest`, which `render` moves after each
  push. The immutable `:<freight>` tag stays as the record of each push.
- **dev takes the artifact straight from its Warehouse**, so the gate is
  `render` succeeding. test only takes Freight verified in dev, and prod only
  Freight verified in test.
- **Adding an app** means its render steps and a tar/push/retag trio in
  `oci-publish`, a `<app>-manifests` Warehouse, three Stages, and a list element
  in the ApplicationSet. **Adding a stage** means a render step per app, a
  Stage per app, and a list element in the ApplicationSet.
- `tar` must have `gzip: true`, and `argocd-update` needs the **digest**, not a
  tag: see [`oci-flow`](../oci-flow#things-to-know).
- GHCR needs a **classic** PAT with `write:packages`, and repository names
  must be lowercase.
