#!/usr/bin/env python3
"""Assemble importable n8n workflows from the templates and src/terminal/*.js.

n8n stores a workflow as one JSON document with every Code node's body inlined
as a string. That is unreviewable in git: a one-line logic change shows up as a
diff inside a JSON string. So the Code-node bodies live in src/terminal/ as real
.js files, and the templates in workflows/ carry placeholders instead:

  "jsCode": "@file:a.js+b.js"         -> contents of a.js and b.js, concatenated
  "id":     "@postgres_credential_id" -> the credential id passed on the CLI

Concatenation is how two Code nodes share a helper (redirect_base.js): n8n has
no import mechanism between Code nodes.

Usage:
  scripts/build_workflows.py <postgres-credential-id>   writes workflows/dist/*.json
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "terminal"
TEMPLATES = ROOT / "workflows"
DIST = TEMPLATES / "dist"


def resolve(value, cred_id):
    if isinstance(value, dict):
        return {k: resolve(v, cred_id) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, cred_id) for v in value]
    if value == "@postgres_credential_id":
        return cred_id
    if isinstance(value, str) and value.startswith("@file:"):
        parts = value[len("@file:"):].split("+")
        return "\n".join((SRC / p).read_text().rstrip("\n") for p in parts) + "\n"
    return value


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    cred_id = sys.argv[1]
    DIST.mkdir(exist_ok=True)
    for tpl in sorted(TEMPLATES.glob("*.template.json")):
        wf = resolve(json.loads(tpl.read_text()), cred_id)
        out = DIST / tpl.name.replace(".template", "")
        out.write_text(json.dumps(wf, indent=2, ensure_ascii=False) + "\n")
        print(f"built {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
