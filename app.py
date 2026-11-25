"""Free-tier Hugging Face interface for Project RxV.

The Space is intentionally a control plane: it receives public repository URLs
and renders reports, while the private Runner executes every package in a fresh
sandbox. Never enable an embedded runner in this public process.
"""
from __future__ import annotations

import html
import json
import os
import re
import time
from typing import Any
from urllib.parse import urlparse

import gradio as gr
import httpx

API_URL = os.getenv("RXV_API_URL", "").rstrip("/")
GITHUB_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$")

CSS = """
:root{--rxv:#9b7bff;--aqua:#4de0cd;--ink:#070a12;--panel:#101725;--line:#263450}
body,.gradio-container{background:radial-gradient(950px 480px at 83% -5%,#382473 0%,transparent 58%),var(--ink)!important;color:#f4f7ff!important;font-family:Inter,ui-sans-serif,system-ui}
.gradio-container{max-width:1240px!important}.hero{padding:55px 0 23px}.eyebrow{color:var(--aqua);font-size:11px;font-weight:800;letter-spacing:.18em}.hero h1{font-size:clamp(42px,6vw,76px);line-height:.95;letter-spacing:-.065em;margin:13px 0}.hero h1 span{display:block;color:#ad93ff}.hero p{color:#afbbd1;max-width:760px;font-size:17px;line-height:1.6}.metric{border-left:1px solid #33425e;padding-left:15px;margin-right:26px;display:inline-flex;flex-direction:column}.metric b{font-size:22px}.metric small{color:#95a2bb;text-transform:uppercase;font-size:10px;letter-spacing:.08em}.card{background:linear-gradient(145deg,rgba(21,30,48,.97),rgba(11,16,28,.97));border:1px solid var(--line);border-radius:16px;padding:20px!important}.section-title{font-weight:800;font-size:16px}.hint{color:#9ba9c1;font-size:13px}.primary button{background:linear-gradient(90deg,#8561f6,#aa80ff)!important;border:0!important;font-weight:800!important;height:48px!important}.status{border:1px solid #30415e;border-radius:10px;padding:14px 16px;background:#0b101b}.suite{display:grid;grid-template-columns:13px 1fr auto;gap:10px;padding:12px 0;border-bottom:1px solid #253149}.suite:last-child{border:0}.dot-pass{color:#4de0cd}.dot-warning{color:#ffc668}.dot-fail{color:#ff7286}.tag{font-size:10px;letter-spacing:.1em;color:#aab7d0}.empty{color:#98a6c0;padding:22px 0}.notice{margin:16px 0;padding:12px 14px;border:1px solid #4a397d;border-radius:10px;color:#d4c8ff;background:rgba(141,105,255,.09)}
"""


def validate_repo_url(value: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urlparse(value)
    if parsed.hostname != "github.com" or parsed.username or parsed.password or parsed.query or parsed.fragment or not GITHUB_RE.fullmatch(value):
        raise gr.Error("Enter a public GitHub repository URL, for example https://github.com/org/package.")
    return value


def suite_html(report: dict[str, Any] | None) -> str:
    if not report:
        return '<div class="empty">Submit a repository to see integrity, AST, security, test, documentation, visual, and release-gate results here.</div>'
    rows = []
    for suite in report.get("suites", []):
        status = suite.get("status", "skipped")
        tone = "pass" if status == "passed" else "fail" if status in {"failed", "error"} else "warning"
        rows.append(f'<div class="suite"><span class="dot-{tone}">●</span><div><b>{html.escape(suite.get("name", "Validation suite"))}</b><br><span class="hint">{html.escape(suite.get("summary", ""))}</span></div><span class="tag">{html.escape(status.upper())}</span></div>')
    return "".join(rows)


def score_html(report: dict[str, Any] | None) -> str:
    if not report:
        return '<div class="empty"><b>FINAL RELEASE DECISION</b><br><br>Your quality score and release verdict will appear after the isolated runner finishes.</div>'
    score = html.escape(str(report.get("score", "—")))
    verdict = html.escape(str(report.get("verdict", "complete")).replace("_", " ").upper())
    return f'<div class="eyebrow">RXV QUALITY SCORE</div><div style="font-size:70px;font-weight:850;line-height:1;margin:9px 0">{score}<span style="font-size:20px;color:#92a0bb">/100</span></div><b style="color:#cfc0ff;letter-spacing:.08em;font-size:12px">{verdict}</b><p class="hint">Weighted across correctness, security, test confidence, reproducibility, and release risk.</p>'


def findings_html(report: dict[str, Any] | None) -> str:
    if not report or not report.get("findings"):
        return '<div class="empty">No findings are available yet.</div>'
    rows = []
    for finding in report["findings"]:
        rows.append(f"<div class='suite'><span class='dot-{'fail' if finding.get('severity') == 'high' else 'warning'}'>●</span><div><b>{html.escape(str(finding.get('rule', 'RXV')))} · {html.escape(str(finding.get('file', '')))}:{html.escape(str(finding.get('line', 0)))}</b><br><span class='hint'>{html.escape(str(finding.get('message', '')))}</span></div><span class='tag'>{html.escape(str(finding.get('severity', ''))).upper()}</span></div>")
    return "".join(rows)


def validate_repository(repo_url: str, profile: str, progress=gr.Progress()):
    repo_url = validate_repo_url(repo_url)
    if not API_URL:
        raise gr.Error("The public UI is deployed, but the private RxV Runner has not been configured. Set the RXV_API_URL Space variable to enable real validation.")
    progress(0.05, desc="Submitting isolated validation job")
    try:
        with httpx.Client(timeout=30) as client:
            submit = client.post(f"{API_URL}/api/submissions", data={"github_url": repo_url, "profile": profile})
            submit.raise_for_status()
            run_id = submit.json()["id"]
            for attempt in range(90):
                progress(min(0.1 + attempt / 100, 0.97), desc="Running package validation in isolated sandbox")
                response = client.get(f"{API_URL}/api/runs/{run_id}")
                response.raise_for_status()
                run = response.json()
                if run["status"] in {"passed", "failed", "error"}:
                    report = run.get("report")
                    status = f"### Run `{run_id[:12]}` · **{run['status'].upper()}**\nRepository: `{repo_url}` · Profile: **{profile.title()}**"
                    return status, score_html(report), suite_html(report), findings_html(report), report or {"error": run.get("error")}
                time.sleep(2)
    except httpx.HTTPError as exc:
        raise gr.Error("RxV could not contact its private validation service. Try again shortly.") from exc
    raise gr.Error("This validation exceeded the public UI wait limit. Check the run history service for its final report.")


with gr.Blocks(title="Project RxV · R Package Validation", css=CSS, theme=gr.themes.Base()) as demo:
    gr.HTML("""<section class='hero'><div class='eyebrow'>PUBLIC R PACKAGE QUALITY INTELLIGENCE</div><h1>Prove your package is ready.<span>Before CRAN does.</span></h1><p>Paste a public GitHub repository. Project RxV runs a deep, isolated validation across package integrity, AST risk, security, tests, coverage, documentation, visual snapshots, reproducibility, and release readiness.</p><div><span class='metric'><b>14+</b><small>validation domains</small></span><span class='metric'><b>0</b><small>network access in test sandbox</small></span><span class='metric'><b>1</b><small>final release verdict</small></span></div></section>""")
    if not API_URL:
        gr.HTML("<div class='notice'><b>RUNNER CONFIGURATION REQUIRED</b> · This free public Space is ready for its private validation endpoint. Set <code>RXV_API_URL</code> in Space Variables to enable real test runs.</div>")
    with gr.Row():
        with gr.Column(scale=7, elem_classes=["card"]):
            gr.HTML("<div class='section-title'>01 · Package source</div><p class='hint'>Only public GitHub owner/repository URLs are accepted.</p>")
            repo = gr.Textbox(label="Public GitHub repository", placeholder="https://github.com/organisation/package")
            profile = gr.Radio([("Rapid · static, structure, install", "rapid"), ("Standard · full package confidence", "standard"), ("Release · visual, portability, release gate", "release")], value="standard", label="Validation depth")
            submit = gr.Button("Start isolated validation  →", variant="primary", elem_classes=["primary"])
        with gr.Column(scale=5, elem_classes=["card"]):
            gr.HTML("<div class='section-title'>What RxV validates</div><p class='hint'>Package layout · metadata · license · AST · secrets · dependencies · build · CRAN check · tests · coverage · lint · docs · vignettes · visual/UI · reproducibility · release gate</p><div class='status'>Every submission is executed outside this public UI in a disposable sandbox. Public visitors never need an account.</div>")
    gr.HTML("<div class='eyebrow' style='margin-top:40px'>LIVE VALIDATION REPORT</div>")
    run_status = gr.Markdown("### No validation run selected\nSubmit a repository above to generate an evidence-backed release report.")
    with gr.Row():
        with gr.Column(scale=4, elem_classes=["card"]): score = gr.HTML(score_html(None))
        with gr.Column(scale=8, elem_classes=["card"]): suites = gr.HTML(suite_html(None))
    with gr.Column(elem_classes=["card"]):
        gr.HTML("<div class='section-title'>Findings</div>")
        findings = gr.HTML(findings_html(None))
    raw = gr.JSON(label="Structured RxV report", visible=False)
    submit.click(validate_repository, inputs=[repo, profile], outputs=[run_status, score, suites, findings, raw])

demo.queue(default_concurrency_limit=8).launch()
