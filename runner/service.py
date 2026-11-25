"""Development runner for Project RxV.

Production implementations must replace `execute_job` with a job provider that
starts a new egress-denied, non-privileged container/VM for every job. The API
contract remains the same.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path

import httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

TOKEN = os.environ.get("RXV_RUNNER_TOKEN", "")
UPLOAD_ROOT = Path(os.environ.get("RXV_UPLOAD_ROOT", "/data/uploads")).resolve()
REPORT_ROOT = Path(os.environ.get("RXV_REPORT_ROOT", "/data/reports")).resolve()
JOB_SEMAPHORE = asyncio.Semaphore(int(os.environ.get("RXV_MAX_CONCURRENT_JOBS", "1")))
GITHUB_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

app = FastAPI(title="Project RxV Runner", docs_url=None, redoc_url=None)


class Source(BaseModel):
    type: str
    url: str | None = None
    artifact_path: str | None = None
    filename: str | None = None


class Job(BaseModel):
    run_id: str = Field(pattern=r"^[a-f0-9]{32}$")
    source: Source
    profile: str = Field(pattern=r"^(rapid|standard|release)$")
    callback_url: str


def auth(authorization: str | None) -> None:
    if not TOKEN or authorization != f"Bearer {TOKEN}":
        raise HTTPException(401, "unauthorized")


def safe_unzip(archive: Path, target: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        infos = zf.infolist()
        if len(infos) > 10_000 or sum(i.file_size for i in infos) > 2_000_000_000:
            raise ValueError("archive exceeds limits")
        for info in infos:
            destination = (target / info.filename).resolve()
            if not destination.is_relative_to(target.resolve()) or info.is_dir() is False and info.filename.endswith("/"):
                raise ValueError("unsafe archive path")
        zf.extractall(target)


def package_directory(root: Path) -> Path:
    descriptions = list(root.rglob("DESCRIPTION"))
    if len(descriptions) != 1:
        raise ValueError("source must contain exactly one package DESCRIPTION file")
    return descriptions[0].parent


def acquire_source(source: Source, workspace: Path) -> Path:
    source_root = workspace / "source"
    source_root.mkdir()
    if source.type == "github":
        if not source.url or not GITHUB_RE.fullmatch(source.url):
            raise ValueError("invalid GitHub source")
        # Fetch is intentionally the only networked stage. Production uses a URL broker
        # that pins the resulting commit SHA before the isolated run begins.
        subprocess.run(["git", "clone", "--depth", "1", source.url, str(source_root / "repo")], check=True, timeout=90, capture_output=True, text=True)
    elif source.type == "zip":
        if not source.artifact_path:
            raise ValueError("missing archive")
        archive = Path(source.artifact_path).resolve()
        if not archive.is_relative_to(UPLOAD_ROOT) or not archive.is_file():
            raise ValueError("archive is outside the approved store")
        safe_unzip(archive, source_root)
    else:
        raise ValueError("unsupported source type")
    return package_directory(source_root)


def execute_job_sync(job: Job) -> dict:
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"rxv-{job.run_id[:8]}-", dir="/var/lib/rxv") as tmp:
        workspace = Path(tmp)
        package = acquire_source(job.source, workspace)
        report = REPORT_ROOT / f"{job.run_id}.json"
        environment = {"HOME": str(workspace / "home"), "R_DEFAULT_PACKAGES": "stats,graphics,grDevices,utils,datasets,methods,base", "NO_PROXY": "*"}
        (workspace / "home").mkdir()
        completed = subprocess.run(
            ["Rscript", "--vanilla", "/srv/runner/validate.R", str(package), str(report), job.profile],
            cwd=workspace, env={**os.environ, **environment}, timeout={"rapid": 600, "standard": 1200, "release": 2400}[job.profile],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        if not report.exists():
            raise RuntimeError(f"validator did not produce a report (exit {completed.returncode})")
        result = json.loads(report.read_text(encoding="utf-8"))
        result["runner_stdout_tail"] = completed.stdout[-6000:]
        report.write_text(json.dumps(result), encoding="utf-8")
        return result


async def execute_job(job: Job) -> None:
    async with JOB_SEMAPHORE:
        try:
            report = await asyncio.to_thread(execute_job_sync, job)
            statuses = [x.get("status") for x in report.get("suites", [])]
            status = "failed" if "failed" in statuses else "passed"
            payload = {"status": status, "report": report}
        except Exception as exc:
            payload = {"status": "error", "error": "The isolated runner could not complete this validation."}
        async with httpx.AsyncClient(timeout=30) as client:
            await client.post(job.callback_url, json=payload, headers={"Authorization": f"Bearer {TOKEN}"})


@app.post("/jobs", status_code=202)
async def create_job(job: Job, authorization: str | None = Header(default=None)) -> dict:
    auth(authorization)
    asyncio.create_task(execute_job(job))
    return {"accepted": True, "run_id": job.run_id}


@app.get("/health")
async def health() -> dict:
    return {"service": "rxv-runner", "status": "ok", "mode": "development-adapter"}
