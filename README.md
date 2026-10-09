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
