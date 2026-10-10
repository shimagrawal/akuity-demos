# Akuity demos

Kargo + Argo CD demos on the Akuity Platform, one folder per demo. Every demo
has its own Kargo Project, Argo CD AppProject and namespace prefix, so they
never collide.

| Demo | What it shows |
|---|---|
| [`oci-flow/`](oci-flow) | Kargo renders each stage, publishes it to GHCR as an OCI artifact, and points Argo CD at the pushed digest. No stage branches. |

## Getting started

```bash
cp .env.example .env     # fill it in; never commit .env
akuity login
task check
task --list              # every demo's tasks, e.g. task oci:setup
```

Tools: `brew install akuity kargo go-task gettext kubectl`.

## Local validation

Validates Kargo resources, Kargo step configs, Argo CD resources and rendered
Kubernetes manifests against schemas pinned to your environment (versions in
the root `Taskfile.yaml`). Step configs are checked with
[`tools/lint-task.py`](tools/lint-task.py), copied from
[curated-custom-promotion-tasks](https://github.com/blakepettersson/curated-custom-promotion-tasks).

```bash
brew install yq

# install flux-schema once (macOS arm64; other platforms on its releases page)
curl -fsSL https://github.com/fluxcd/flux-schema/releases/download/v0.15.0/flux-schema_0.15.0_darwin_arm64.tar.gz \
  | tar -xz -C /opt/homebrew/bin flux-schema

task oci:validate
```

Bump `KARGO_VERSION`, `ARGOCD_VERSION` or `K8S_VERSION` when your environment
is upgraded; the schemas are regenerated on the next run.

## Layout

```
Taskfile.yaml        loads .env, includes each demo, `task check`
.env.example         shared settings (Akuity, GitHub, registry)
<demo>/
  Taskfile.yaml      task <prefix>:setup, ...
  README.md
  app/               what gets deployed
  argocd/            AppProject + ApplicationSet
  kargo/             Project, Warehouse, Stages, PromotionTask
  secrets.yaml       credentials, filled from .env at apply time
```

## Adding a demo

1. Create `<demo>/` with the layout above, using its own Kargo Project name and
   namespace prefix.
2. Add it to `includes:` in the root `Taskfile.yaml`.
3. Add a row to the table above.

Keep Kargo's `${{ ... }}` expressions in the YAML files only: Task treats `{{ }}`
in a Taskfile command as its own template syntax. The Taskfiles pass an explicit
variable list to `envsubst`, so those expressions survive substitution.
