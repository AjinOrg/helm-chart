# helm-chart

How every microservice runs on the platform: **one shared Helm chart** and, per service, its values per environment.

| Repository | Owner | Contains |
|---|---|---|
| `AjinOrg/<service>` (e.g. `my-app`) | Developers | Code, Dockerfile, build pipeline (pushes the image, opens the dev deployment PR here) |
| **`AjinOrg/helm-chart`** (this one) | Release team | Shared chart, values per service and environment, release/verify workflows |
| `AjinOrg/aws-platform` | Infra team | AWS (Terraform), cluster add-ons, namespaces, Kyverno policies, the ArgoCD project and ApplicationSet that read this repository |

## Table of Contents
1. [Layout](#1-layout)
2. [How a Change Reaches the Cluster](#2-how-a-change-reaches-the-cluster)
3. [Chart Versions per Environment](#3-chart-versions-per-environment)
4. [Add a New Service](#4-add-a-new-service)
5. [Release to Staging and Production](#5-release-to-staging-and-production)
6. [Checks on Every Pull Request](#6-checks-on-every-pull-request)
7. [Setup (One Time)](#7-setup-one-time)
8. [Why a Shared Chart, Not an Umbrella Chart](#8-why-a-shared-chart-not-an-umbrella-chart)

---

## 1. Layout
```text
helm-chart/
├── charts/microservice/          the ONE chart all services use (Deployment, Service, Ingress, HPA, PDB,
│                                 ServiceAccount, ExternalSecret)
├── apps/
│   └── my-app/                   one folder per service; the folder name IS the service name
│       ├── values.yaml           all environments: image repository, IRSA role, ...
│       ├── values-dev.yaml       per environment: image tag, replicas, resources
│       ├── values-staging.yaml
│       ├── values-production.yaml
│       └── smoke-test.sh         optional extra checks after a deploy
├── environments/
│   ├── dev.yaml                  chartRevision: main            (dev always runs the newest chart)
│   ├── staging.yaml              chartRevision: chart-v0.1.0    (pinned)
│   └── production.yaml           chartRevision: chart-v0.1.0    (pinned)
├── scripts/
│   ├── render-all.sh             render everything exactly as ArgoCD does (CI and locally)
│   └── release.sh                interactive release (menus) → starts release.yaml
└── .github/
    ├── workflows/                ci, chart-release, release, verify
    ├── rulesets/                 branch protection of main, protection of chart-v* tags
    └── CODEOWNERS
```

Values are layered, later wins: `charts/microservice/values.yaml` → `apps/<service>/values.yaml` →
`apps/<service>/values-<env>.yaml`.

## 2. How a Change Reaches the Cluster
```text
aws-platform (infra team)
  gitops/apps/microservices.yaml
    AppProject "apps"          may read ONLY this repository, deploy ONLY to dev/staging/production,
                               ONLY namespaced kinds the chart uses
    ApplicationSet "microservices"
      for every folder apps/<service>/  ×  every file environments/<env>.yaml
        → ArgoCD Application "<service>-<env>"
            chart:  charts/microservice at chartRevision (environments/<env>.yaml)
            values: apps/<service>/values.yaml + values-<env>.yaml (main)
            into namespace <env>, Helm release name <service>
```
- **New service** = new folder under `apps/`. ArgoCD creates its three Applications by itself; no platform PR.
- **New environment** = new file under `environments/` **and** a platform PR (namespace + AppProject destination).
  The AppProject refuses any other namespace.
- **Remove a service** = delete its folder. Its Applications and everything they deployed are removed.

URLs (one shared load balancer, no domain yet): `http://<alb-dns>/<environment>/<service>`, e.g.
`http://<alb-dns>/dev/my-app`. Find the address:
```bash
kubectl get ingress -n dev -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

## 3. Chart Versions per Environment
A chart change affects every service, so environments do not all take it at once:

| Step | What | Who / approval |
|---|---|---|
| 1 | PR changes `charts/` **and bumps `version`** in `Chart.yaml` (CI fails otherwise) | Code Owner |
| 2 | Merge → `chart-release.yaml` tags `chart-v<version>`; **dev runs it immediately** (dev follows `main`) | automatic |
| 3 | PR: `environments/staging.yaml` → `chartRevision: chart-v<version>` | no approval |
| 4 | PR: `environments/production.yaml` → `chartRevision: chart-v<version>` | Code Owner |

- Released tags cannot be moved or deleted (ruleset `chart-tags`): production always gets exactly what was tested.
- CI renders staging/production with their pinned chart **and** with the newest chart (`*.next.yaml`), so a chart
  change is checked against every service before anyone pins it.
- Values always come from `main`. A new chart value must therefore have a default in the chart, and values files
  should only use a new value once the environment runs a chart version that knows it.

## 4. Add a New Service
**Infra team first** (aws-platform, Terraform): ECR repository `<service>`, Secrets Manager entries
`platform-dev/<service>/<env>`, optional IRSA role, and in `bootstrap/state-backend.yaml` the service repo's
ECR push role. Then here:
```bash
mkdir apps/orders
cat > apps/orders/values.yaml <<'EOF'
image:
  repository: 471112815218.dkr.ecr.ap-south-1.amazonaws.com/orders
serviceAccount:
  roleArn: arn:aws:iam::471112815218:role/platform-dev-orders   # or leave out: no AWS access
EOF
for e in dev staging production; do
  printf 'environment: %s\nimage:\n  tag: "<first-sha>"\n' "$e" > "apps/orders/values-$e.yaml"
done
bash scripts/render-all.sh     # renders orders in every environment
```
Contract every service must meet (the chart and `verify.yaml` rely on it):

| | |
|---|---|
| Port | listens on `PORT` (default 8080) |
| Health | `GET /healthz` (liveness), `GET /readyz` (readiness) |
| Path | requests arrive with the prefix `/<env>/<service>`; answer them (or ignore the prefix) |
| Smoke test | `GET /<env>/<service>` returns JSON with `version` (= `APP_VERSION`) and `environment` (= `APP_ENV`) |
| Security | runs as non-root (UID 65532 works), read-only root filesystem |
| Secrets | read from files in `SECRETS_DIR` (one file per JSON key of the Secrets Manager entry) |

## 5. Release to Staging and Production
Dev is automatic: the service's pipeline opens a PR changing `apps/<service>/values-dev.yaml` (merges itself after CI).
Staging and production are released on purpose, one service at a time:
```bash
bash scripts/release.sh          # menus: service → environment → tested tag → confirm
# or: GitHub → Actions → release → Run workflow (service, environment, tag)
```
| | staging | production |
|---|---|---|
| Tag must have run in | dev | staging |
| Pull request | merges itself after CI | waits for a Code Owner |
| After merge | `verify.yaml` smoke-tests it | `verify.yaml` smoke-tests it |

## 6. Checks on Every Pull Request
| Job (`ci.yaml`) | Checks |
|---|---|
| Secrets scan (Gitleaks) | no credentials in the history |
| Chart version bumped | `charts/` changed → `version` must be new |
| Render + kubeconform + Kyverno | `helm lint`; every service × environment renders; Kubernetes schemas; the platform's Kyverno policies (read from `AjinOrg/aws-platform`, the same ones the cluster enforces) |
| Security scan (Checkov) | rendered manifests; skipped checks with reasons in `.checkov.yaml` |

Locally: `bash scripts/render-all.sh && ls rendered/`.

## 7. Setup (One Time)
Done in this order; every command was run from `~/workspace/Task`.

**7a. Create the repository** (public, like the others: rulesets on a free organization need public repositories)
```bash
cd ~/workspace/Task/helm-chart
git init -b main
chmod +x scripts/*.sh apps/*/smoke-test.sh .github/scripts/*.sh
git add .
git status                                   # must not list rendered/
gitleaks git --pre-commit --staged -v        # "no leaks found"
git commit -m "helm-chart: shared microservice chart, my-app values, CI and release workflows"
git tag chart-v0.1.0                         # staging/production pin it; CI needs it on the first run
gh repo create AjinOrg/helm-chart --public --source=. --remote=origin
git push origin main chart-v0.1.0            # branch and tag in ONE push: the first CI run finds the tag
```

**7b. Repository settings, rulesets**
```bash
gh repo edit AjinOrg/helm-chart --enable-auto-merge --delete-branch-on-merge
gh api -X POST repos/AjinOrg/helm-chart/rulesets --input .github/rulesets/helm-chart-main.json --jq '"\(.id) \(.name) \(.enforcement)"'
gh api -X POST repos/AjinOrg/helm-chart/rulesets --input .github/rulesets/chart-tags.json      --jq '"\(.id) \(.name) \(.enforcement)"'
```

**7c. GitHub App** (the same app that opens deployment PRs today)
1. https://github.com/organizations/AjinOrg/settings/installations → the app → *Configure* → *Repository access*
   → add `helm-chart` → Save.
2. App settings → *Generate a private key* (a second key; the first one was deleted after setup).
```bash
APP_ID=<app-id>; KEY=/mnt/c/Users/<you>/Downloads/<name>.private-key.pem
gh variable set PLATFORM_APP_ID -R AjinOrg/helm-chart --body "$APP_ID"
gh secret set PLATFORM_APP_PRIVATE_KEY -R AjinOrg/helm-chart < "$KEY"
gh secret set PLATFORM_APP_PRIVATE_KEY -R AjinOrg/my-app < "$KEY"   # optional: same key everywhere
shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
```

**7d. AWS role for release/verify** (`helm-chart-readonly`, in aws-platform `bootstrap/state-backend.yaml`)
```bash
gh api repos/AjinOrg/helm-chart --jq .id                                  # → HelmChartRepoId
gh api repos/AjinOrg/helm-chart/actions/oidc/customization/sub            # use_immutable_subject: true expected
```
Then update the bootstrap stack as described in the aws-platform README ("Changing a parameter later"), adding
`HelmChartRepoId=<id>` to the parameters.

## 8. Why a Shared Chart, Not an Umbrella Chart
| | Shared chart (this repo) | Umbrella chart |
|---|---|---|
| Release unit | one service in one environment | all services of an environment together |
| Roll back one service | change one tag | re-release the whole umbrella |
| ArgoCD | one Application per service and environment: own health, history, sync | one big Application |
| A broken service | blocks only itself | can fail the whole environment's sync |
| New service | add a folder | edit the umbrella's dependencies and values |

An umbrella chart helps when services must always be released together as one versioned bundle. Services that are
released independently, as here, are simpler with one shared chart.
