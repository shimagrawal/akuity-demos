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

Validates every demo against schemas pinned to your environment (versions in
the root `Taskfile.yaml`): Kargo resources, Kargo step configs, Argo CD
resources and rendered Kubernetes manifests. What to render comes from each
demo's `demo.yaml`. Step configs are checked with
[`tools/lint-task.py`](tools/lint-task.py), copied from
[curated-custom-promotion-tasks](https://github.com/blakepettersson/curated-custom-promotion-tasks).

```bash
brew install yq

# install flux-schema once (macOS arm64; other platforms on its releases page)
curl -fsSL https://github.com/fluxcd/flux-schema/releases/download/v0.15.0/flux-schema_0.15.0_darwin_arm64.tar.gz \
  | tar -xz -C /opt/homebrew/bin flux-schema

task validate                  # every demo (~1s each)
task validate DEMO=oci-flow    # one demo (or the shortcut: task oci:validate)
task render DEMO=oci-flow STAGE=dev   # preview what a stage renders
```

Bump `KARGO_VERSION`, `ARGOCD_VERSION` or `K8S_VERSION` when your environment
is upgraded; the schemas are regenerated on the next run.

## End-to-end test

Runs a demo for real in a throwaway kind cluster: Kargo and Argo CD (pinned to
the versions in the root `Taskfile.yaml`) apply the demo's own files and promote
each of its stages. An in-cluster registry and Git server stand in for GHCR and
GitHub, so no credentials are needed. The checks come from the demo's
`demo.yaml`: every stage must run the same digest and answer its requests.

```bash
task e2e DEMO=oci-flow          # full run (~5-15 min); deletes the cluster afterwards
KEEP=1 task e2e DEMO=oci-flow   # keep the cluster to inspect Kargo and Argo CD
task e2e:run DEMO=oci-flow      # rerun on a kept cluster (~2-3 min)
task e2e:down                   # delete it
```

Needs Docker, `kind`, `kubectl`, `helm`, `yq`, `jq` and `git`. It tests your
working tree, including uncommitted changes. The test cluster has its own
kubeconfig (`tools/e2e/kubeconfig`), so your `~/.kube/config` is never changed;
`export KUBECONFIG=tools/e2e/kubeconfig` to look around a kept cluster. In CI it runs one job per demo on
pull requests that change a demo's `kargo/`, `argocd/` or `demo.yaml`, or the
shared `tools/e2e/`; weekly; and on demand
([`.github/workflows/e2e.yaml`](.github/workflows/e2e.yaml)).

## Layout

```
Taskfile.yaml        loads .env, includes each demo, shared tasks (validate, e2e, schemas)
.env.example         shared settings (Akuity, GitHub, registry)
tools/
  validate.sh        validates one demo (task validate)
  render.sh          renders a demo's apps per stage (task render)
  lint-task.py       checks Kargo step configs
  e2e/               end-to-end test (task e2e): script, in-cluster infra
<demo>/
  demo.yaml          how the shared tooling validates and tests this demo
  Taskfile.yaml      demo tasks (setup, port-forward) and shortcuts
  README.md
  apps/              what gets deployed
  argocd/            AppProject + ApplicationSet
  kargo/             Project, Warehouse, Stages, PromotionTasks
  secrets.yaml       credentials, filled from .env at apply time (not in kargo/ or argocd/)
```

## Adding a demo

1. Create `<demo>/` with the layout above, using its own Kargo Project name and
   namespace prefix.
2. Write its `demo.yaml` (copy [`oci-flow/demo.yaml`](oci-flow/demo.yaml)):
   `name`, `stages`, how to `render` each app, and the `e2e` checks.
3. Add it to `includes:` in the root `Taskfile.yaml` (for its own tasks).
4. Add a row to the table above.

`task validate` and the CI workflows pick it up automatically.

Keep Kargo's `${{ ... }}` expressions in the YAML files only: Task treats `{{ }}`
in a Taskfile command as its own template syntax. The tooling passes an explicit
variable list to `envsubst`, so those expressions survive substitution.
