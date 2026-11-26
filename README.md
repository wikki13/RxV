---
title: Project RxV
emoji: 🧬
colorFrom: violet
colorTo: blue
sdk: gradio
sdk_version: 5.9.1
app_file: app.py
pinned: false
---

# Project RxV

**Project RxV** is a public R-package validation platform. Submit a public GitHub repository or a package ZIP, choose a validation profile, and receive a signed, structured quality report with logs and artifacts.

## What it validates

| Domain | Checks |
| --- | --- |
| Package integrity | `R CMD build`, clean install, `R CMD check --as-cran`, required layout, DESCRIPTION, license, README/NEWS and build-ignore policy |
| Tests | `testthat`, tinytest/RUnit discovery, coverage, examples, vignettes, test inventory and failure capture |
| Code quality | AST parsing, decision-point complexity, long-source/long-line thresholds, linting and dependency compatibility |
| Documentation | Rd parseability, roxygen/Rd coverage signals, exported-object documentation, examples, vignettes and pkgdown assets |
| Reproducibility | lockfile detection, pinned remotes, dependency inventory and declared-R-version inspection |
| Visual/UI | `vdiffr` snapshots, detected Shiny test suites (`shinytest2`) and visual asset discovery |
| Security | archive-bomb checks, source provenance, secrets scan, unsafe AST calls, shell-download patterns and isolated execution |
| Release gate | platform-sensitive call detection, CRAN-ready gate and explicit matrix-orchestrator requirements for multi-R/OS testing |

## Architecture

The free-tier Space hosts the intake/reporting UI. Untrusted package code is **never executed in the UI container**. It is sent to an independently deployed RxV Runner, which creates a fresh, no-network, resource-limited R sandbox for every run.

```
browser → RxV Space (FastAPI UI) → queue / runner API → disposable R sandbox
                 ↑                      ↓                   ↓
             report API            callback          logs + report artifacts
```

`docker-compose.yml` is a local development topology. For public production deployments, replace its shared directory with object storage and deploy Runner behind a private network endpoint (Cloud Run Jobs, ECS/Fargate, Kubernetes Jobs, or equivalent).

## Run locally

```bash
cp .env.example .env
docker compose up --build
# Open http://localhost:7860
```

The UI runs at port `7860`; the local Runner is at port `8081`. Set `RXV_DEMO_MODE=true` to explore the interface without invoking R.

## Hugging Face Space

Create a **Gradio Space**, push this repository, then add this Space variable:

```
RXV_API_URL=https://your-rxv-api.example
```

The Space is the Golem/Shiny interface. Deploy the included API gateway and Runner as private services and set the following on the API service:

```
RXV_RUNNER_URL=https://your-private-runner.example
RXV_RUNNER_TOKEN=<long random shared secret>
RXV_CALLBACK_BASE_URL=https://your-rxv-api.example
RXV_STORAGE_MODE=s3                 # production: do not use shared paths
RXV_S3_BUCKET=<private artifact bucket>
RXV_S3_REGION=<region>
```
The Runner must enforce an egress-deny network policy, read-only base image, unprivileged UID, CPU/memory/pid limits, timeouts, and per-job temporary volumes. GitHub URLs should be fetched through a broker with allow-listed domains and commit SHA pinning.

## Public-service safeguards

- GitHub-only source URLs; redirects and private network ranges are rejected.
- ZIP archives are checked for size, path traversal, expansion ratio, and file count before a job is created.
- Rate limits, CAPTCHA/abuse protection, email verification, quotas, and object-store malware scanning should be enabled at the deployment edge.
- Do not expose raw runner logs until secrets redaction completes.
- Retain uploads/artifacts for a defined period; the default suggested policy is 7 days.

## Profiles

- **Rapid** — AST, metadata, install, unit-test discovery and linters.
- **Standard** — rapid plus full check, coverage, docs and examples.
- **Release** — standard plus visual/UI suite, vignettes, multi-R-version matrix and reproducibility checks.

## Status

This repository is a deployable foundation: polished public UI, API contract, local runner topology, and a functional R validation orchestration script. Before opening submissions to the internet, connect a real job queue/object store and apply the runner isolation controls listed above.

## Author
Vigneshwara Chandrasekaran
