#!/usr/bin/env python3
"""Genera el fragmento HTML de métricas comparadas (24h / 24-48h / 7d) para el dashboard Torre de Mando.

Fuentes: Linear (issues Done, paginado) + GitHub via gh CLI (PRs merged/created, drafts en cola).
Uso: python3 gen-metricas-fragment.py  → imprime el fragmento (filas <tr> + timestamp) en stdout.
El repo/token se toman del clon del repo de producto de la instancia (TF_CLONE); ampliar a multi-repo cuando F2 tenga volumen.
"""
import json, os, subprocess, sys, urllib.request
from datetime import datetime, timedelta, timezone

# [TAL-8037] Sin ruta de casa: el clon del repo de producto de la instancia viene de TF_CLONE (fail-closed).
REPO_DIR = os.environ.get("TF_CLONE", "")
if not REPO_DIR or not os.path.isdir(REPO_DIR):
    sys.exit("gen-metricas-fragment: TF_CLONE sin definir o no es un directorio (clon del repo de producto de la instancia; sin default de casa)")
NOW = datetime.now(timezone.utc)
H24 = NOW - timedelta(hours=24)
H48 = NOW - timedelta(hours=48)
D7 = NOW - timedelta(days=7)

def win(dates):
    d24 = sum(1 for d in dates if d >= H24)
    d48 = sum(1 for d in dates if H48 <= d < H24)
    d7 = sum(1 for d in dates if d >= D7)
    return d24, d48, d7

def parse(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def gh(args):
    return subprocess.run(["gh"] + args, capture_output=True, text=True, cwd=REPO_DIR).stdout

# --- Linear: issues Done últimos 7d (paginado) ---
key = subprocess.run(["grep", "-oP", r"^LINEAR_API_KEY=\K.*", ".env.local"],
                     capture_output=True, text=True, cwd=REPO_DIR).stdout.strip().strip('"')
done_dates, cursor = [], None
for _ in range(8):
    after = f', after: "{cursor}"' if cursor else ""
    q = {"query": f'query{{ issues(filter:{{completedAt:{{gt:"-P7D"}}}}, first: 250{after})'
                  '{ nodes{ completedAt } pageInfo{ hasNextPage endCursor } } }'}
    req = urllib.request.Request("https://api.linear.app/graphql", json.dumps(q).encode(),
                                 {"Authorization": key, "Content-Type": "application/json"})
    d = json.loads(urllib.request.urlopen(req, timeout=30).read())["data"]["issues"]
    done_dates += [parse(n["completedAt"]) for n in d["nodes"] if n["completedAt"]]
    if not d["pageInfo"]["hasNextPage"]:
        break
    cursor = d["pageInfo"]["endCursor"]

# --- GitHub ---
merged = [parse(x) for x in gh(["pr", "list", "--state", "merged", "--limit", "300",
                                "--json", "mergedAt", "--jq", ".[].mergedAt"]).split()]
created = [parse(x) for x in gh(["pr", "list", "--state", "all", "--limit", "300",
                                 "--json", "createdAt", "--jq", ".[].createdAt"]).split()]
drafts = gh(["pr", "list", "--draft", "--state", "open", "--json", "number", "--jq", "length"]).strip() or "?"

rows = [("Issues Done (Linear)",) + win(done_dates),
        ("PRs mergeados",) + win(merged),
        ("PRs creados",) + win(created)]

def cmp_cls(a, b):
    return "up" if a > b else ("down" if a < b else "eq")

out = []
for name, d24, d48, d7 in rows:
    arrow = {"up": "▲", "down": "▼", "eq": "•"}[cmp_cls(d24, d48)]
    out.append(f'<tr><td>{name}</td><td class="num">{d24} <span class="cmp {cmp_cls(d24,d48)}">{arrow}</span></td>'
               f'<td class="num">{d48}</td><td class="num">{d7}</td></tr>')
cdmx = NOW - timedelta(hours=6)
print("\n".join(out))
print(f"<!--METRICAS-META drafts={drafts} corte={cdmx.strftime('%d %b %H:%M')} CDMX-->")
