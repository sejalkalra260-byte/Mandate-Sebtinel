#!/usr/bin/env bash
set -e
# Prefer a modern python (3.11+) for langgraph/sqlmodel
PY=$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)
[ -d .venv ] || "$PY" -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt
[ -f mandate_sentinel.db ] || python -m app.seed
echo ""
echo "  Mandate Sentinel running at  http://localhost:8000"
echo "  (you will land on the login page first — any email/password works)"
echo ""
uvicorn app.main:app --reload --port 8000
