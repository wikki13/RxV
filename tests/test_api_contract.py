"""Lightweight contract checks; integration tests run in docker compose."""
from pathlib import Path


def test_golem_ui_is_the_space_entrypoint():
    dockerfile = Path(__file__).parents[1] / "Dockerfile"
    content = dockerfile.read_text(encoding="utf-8")
    assert "rocker/shiny" in content
    assert "rxv::run_app()" in content


def test_runner_has_no_public_docs_surface():
    service = (Path(__file__).parents[1] / "runner" / "service.py").read_text(encoding="utf-8")
    assert "docs_url=None" in service
    assert "authorization != f\"Bearer {TOKEN}\"" in service
