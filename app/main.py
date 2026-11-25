"""Project RxV public intake and report API.

The web process stores metadata only. It never checks out, installs, or executes
submitted R code; that work belongs to the separately isolated Runner service.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
import zipfile
from contextlib import closing
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

import httpx
from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, HttpUrl

APP_ROOT = Path(__file__).parent
DATA_ROOT = Path(os.getenv("RXV_DATA_ROOT", "/data"))
UPLOAD_ROOT = Path(os.getenv("RXV_UPLOAD_ROOT", str(DATA_ROOT / "uploads")))
REPORT_ROOT = Path(os.getenv("RXV_REPORT_ROOT", str(DATA_ROOT / "reports")))
DB_PATH = DATA_ROOT / "rxv.sqlite3"
MAX_UPLOAD_BYTES = int(os.getenv("RXV_MAX_UPLOAD_BYTES", "262144000"))
RUNNER_URL = os.getenv("RXV_RUNNER_URL", "")
RUNNER_TOKEN = os.getenv("RXV_RUNNER_TOKEN", "")
CALLBACK_BASE_URL = os.getenv("RXV_CALLBACK_BASE_URL", "")
DEMO_MODE = os.getenv("RXV_DEMO_MODE", "false").lower() == "true"
GITHUB_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$")

app = FastAPI(title="Project RxV", version="0.1.0")
app.mount("/static", StaticFiles(directory=APP_ROOT / "static"), name="static")


def db() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    return connection


def initialize() -> None:
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    with closing(db()) as con:
        con.execute("""CREATE TABLE IF NOT EXISTS runs (
          id TEXT PRIMARY KEY, source_type TEXT NOT NULL, source_ref TEXT NOT NULL,
          profile TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL, report_json TEXT, error TEXT, sha256 TEXT
        )""")
        con.commit()


@app.on_event("startup")
async def startup() -> None:
    initialize()


class CallbackPayload(BaseModel):
    status: Literal["passed", "failed", "error"]
    report: dict | None = None
    error: str | None = None


def fetch_run(run_id: str) -> dict:
    with closing(db()) as con:
        row = con.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Validation run not found")
    item = dict(row)
    item["report"] = json.loads(item.pop("report_json")) if item.get("report_json") else None
    return item


def update_run(run_id: str, *, status: str, report: dict | None = None, error: str | None = None) -> None:
    with closing(db()) as con:
        con.execute(
            "UPDATE runs SET status=?, updated_at=?, report_json=?, error=? WHERE id=?",
            (status, int(time.time()), json.dumps(report) if report else None, error, run_id),
        )
        con.commit()


def validate_github_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.username or parsed.password or parsed.hostname != "github.com" or parsed.query or parsed.fragment:
        raise HTTPException(422, "Use a public github.com owner/repository URL without query parameters.")
    normal = value.rstrip("/")
    if not GITHUB_RE.fullmatch(normal):
        raise HTTPException(422, "Use a public github.com owner/repository URL.")
    return normal


async def save_upload(upload: UploadFile, run_id: str) -> tuple[str, str]:
    if not upload.filename or not upload.filename.lower().endswith(".zip"):
        raise HTTPException(422, "Upload an R package source ZIP file.")
    target = UPLOAD_ROOT / f"{run_id}.zip"
    digest = hashlib.sha256()
    size = 0
    with target.open("wb") as output:
        while chunk := await upload.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_UPLOAD_BYTES:
                output.close()
                target.unlink(missing_ok=True)
                raise HTTPException(413, "ZIP exceeds the configured upload limit.")
            digest.update(chunk)
            output.write(chunk)
    try:
        with zipfile.ZipFile(target) as archive:
            entries = archive.infolist()
            expanded = sum(i.file_size for i in entries)
            if len(entries) > 10_000 or expanded > 2_000_000_000 or (size and expanded / size > 200):
                raise HTTPException(422, "ZIP archive exceeds safe expansion limits.")
            for entry in entries:
                path = Path(entry.filename)
                if path.is_absolute() or ".." in path.parts:
                    raise HTTPException(422, "ZIP contains an unsafe path.")
    except zipfile.BadZipFile as exc:
        target.unlink(missing_ok=True)
        raise HTTPException(422, "Invalid ZIP archive.") from exc
    return str(target), digest.hexdigest()


def demo_report(run_id: str) -> dict:
    return {
        "run_id": run_id, "score": 88, "verdict": "passed_with_warnings",
        "environment": {"r_version": "4.4", "platform": "linux", "network": "disabled"},
        "suites": [
            {"name": "Package structure", "status": "passed", "summary": "Required package components and test layout detected."},
            {"name": "Metadata, license & repository hygiene", "status": "passed", "summary": "Metadata, license, README, NEWS, and build-ignore policy passed."},
            {"name": "AST & security", "status": "warning", "summary": "1 external-command call requires review."},
            {"name": "Secrets, supply-chain & unsafe-content scan", "status": "passed", "summary": "No credential or shell-download patterns detected."},
            {"name": "Maintainability & complexity", "status": "passed", "summary": "Complexity and source-size thresholds passed."},
            {"name": "Dependency compatibility", "status": "passed", "summary": "Declared dependencies resolved in the validation image."},
            {"name": "Package integrity", "status": "passed", "summary": "Build and clean install completed."},
            {"name": "CRAN readiness", "status": "passed", "summary": "R CMD check --as-cran completed."},
            {"name": "Test confidence", "status": "passed", "summary": "48 tests passed · 84% coverage."},
            {"name": "Documentation", "status": "passed", "summary": "All exported objects documented."},
            {"name": "Visual & UI regression", "status": "skipped", "summary": "No vdiffr or Shiny snapshots discovered."},
        ],
        "findings": [{"severity": "medium", "rule": "RXV-AST-004", "file": "R/import.R", "line": 22, "message": "system2() call should be allow-listed or replaced."}],
        "artifacts": [],
    }


async def dispatch(run_id: str, source: dict, profile: str) -> None:
    if DEMO_MODE:
        await asyncio.sleep(1.2)
        update_run(run_id, status="passed", report=demo_report(run_id))
        return
    if not RUNNER_URL or not RUNNER_TOKEN or not CALLBACK_BASE_URL:
        update_run(run_id, status="error", error="Runner is not configured. The package was not executed.")
        return
    payload = {"run_id": run_id, "source": source, "profile": profile, "callback_url": f"{CALLBACK_BASE_URL.rstrip('/')}/api/runs/{run_id}/complete"}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(f"{RUNNER_URL.rstrip('/')}/jobs", json=payload, headers={"Authorization": f"Bearer {RUNNER_TOKEN}"})
            response.raise_for_status()
    except Exception as exc:  # runner errors intentionally do not expose internals to public clients
        update_run(run_id, status="error", error=f"Runner dispatch failed: {type(exc).__name__}")


@app.get("/", response_class=HTMLResponse)
async def index() -> HTMLResponse:
    return HTMLResponse("<h1>Project RxV API</h1><p>This service is consumed by the Project RxV Golem interface.</p>")


@app.post("/api/submissions", status_code=202)
async def create_submission(
    background_tasks: BackgroundTasks,
    github_url: str | None = Form(default=None),
    package_zip: UploadFile | None = File(default=None),
    profile: Literal["rapid", "standard", "release"] = Form(default="standard"),
) -> dict:
    if bool(github_url) == bool(package_zip):
        raise HTTPException(422, "Provide exactly one source: a GitHub URL or a ZIP upload.")
    run_id = uuid.uuid4().hex
    source: dict
    sha = None
    if github_url:
        source = {"type": "github", "url": validate_github_url(github_url)}
        source_ref = source["url"]
    else:
        artifact_path, sha = await save_upload(package_zip, run_id)  # type: ignore[arg-type]
        source = {"type": "zip", "artifact_path": artifact_path, "filename": package_zip.filename}
        source_ref = package_zip.filename or "package.zip"
    now = int(time.time())
    with closing(db()) as con:
        con.execute("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (run_id, source["type"], source_ref, profile, "queued", now, now, None, None, sha))
        con.commit()
    background_tasks.add_task(dispatch, run_id, source, profile)
    return {"id": run_id, "status": "queued", "poll_url": f"/api/runs/{run_id}"}


@app.get("/api/runs/{run_id}")
async def get_run(run_id: str) -> dict:
    return fetch_run(run_id)


@app.post("/api/runs/{run_id}/complete")
async def complete_run(run_id: str, payload: CallbackPayload, request: Request) -> dict:
    # Runner-to-UI shared token. In production replace with workload identity/mTLS.
    expected = f"Bearer {RUNNER_TOKEN}"
    if not RUNNER_TOKEN or not secrets.compare_digest(request.headers.get("Authorization", ""), expected):
        raise HTTPException(401, "Invalid runner credential")
    fetch_run(run_id)
    update_run(run_id, status=payload.status, report=payload.report, error=payload.error)
    return {"ok": True}


@app.get("/api/health")
async def health() -> dict:
    return {"service": "project-rxv", "status": "ok", "demo_mode": DEMO_MODE}
