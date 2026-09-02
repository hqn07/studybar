#!/usr/bin/env bash
# deps-check.sh — compare the versions pinned in Package.resolved against each
# project's latest GitHub release/tag, so you know what to bump in project.yml.
#
# Runtime "auto-update" isn't a thing for compiled SPM deps — this is the dev-side
# check. Uses `gh` for auth (higher rate limit) if present, else unauthenticated curl.
set -euo pipefail
cd "$(dirname "$0")/.."

RES="StudyBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -f "$RES" ] || { echo "No Package.resolved — run scripts/build.sh once first."; exit 1; }

have_gh=0; command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && have_gh=1

python3 - "$RES" "$have_gh" <<'PY'
import json, sys, re, subprocess, urllib.request

resolved, have_gh = sys.argv[1], sys.argv[2] == "1"
pins = json.load(open(resolved)).get("pins", [])

def latest_tag(owner_repo):
    if have_gh:
        try:
            out = subprocess.run(["gh", "api", f"repos/{owner_repo}/releases/latest",
                                  "--jq", ".tag_name"], capture_output=True, text=True, timeout=15)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
            out = subprocess.run(["gh", "api", f"repos/{owner_repo}/tags", "--jq", ".[0].name"],
                                 capture_output=True, text=True, timeout=15)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except Exception:
            pass
        return "?"
    try:
        req = urllib.request.Request(f"https://api.github.com/repos/{owner_repo}/releases/latest",
                                     headers={"User-Agent": "studybar-deps-check"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r).get("tag_name", "?")
    except Exception:
        return "?"

def norm(v): return re.sub(r'^v', '', (v or "").strip())

print(f"{'package':26} {'current':12} {'latest':12} status")
print("-" * 60)
outdated = 0
for p in pins:
    ident = p.get("identity", "?")
    ver = p.get("state", {}).get("version") or p.get("state", {}).get("revision", "")[:8] or "?"
    loc = p.get("location", "")
    m = re.search(r'github\.com[/:]([^/]+/[^/.]+)', loc)
    latest = latest_tag(m.group(1)) if m else "?"
    cur, lat = norm(ver), norm(latest)
    status = "up to date"
    if lat not in ("?", "") and cur != lat:
        status = "↑ update available"; outdated += 1
    print(f"{ident:26} {ver:12} {latest:12} {status}")
print("-" * 60)
print(f"{outdated} update(s) available." if outdated else "All pinned deps at their latest release.")
print("Bump a version in project.yml, then: xcodegen && scripts/build.sh")
PY
