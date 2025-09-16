#!/usr/bin/env bash
# Portable strict mode
set -euo pipefail

# gh_self_attest_v11.sh
# - Fixes arithmetic increment portability (no ((var++)); uses POSIX-safe math)
# - Styled HTML -> PDF; outputs to CWD; loud path banners; verbose mode
#
# Usage:
#   ./gh_self_attest_v11.sh owner/repo [--out report.pdf] [--days 90] [--verbose]

REPO=""
OUT="report.pdf"
DAYS=90
VERBOSE=0

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    -v|--verbose) VERBOSE=1; shift;;
    *) if [[ -z "$REPO" ]]; then REPO="$1"; shift; else echo "Unknown arg: $1"; exit 1; fi;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 owner/repo [--out report.pdf] [--days 365] [--verbose]"
  exit 1
fi

# ---------- verbose / tracing ----------
if [[ "$VERBOSE" -eq 1 ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ${FUNCNAME[0]:-main}() -> '
  set -x
fi

log()   { printf '[attest] %s\n' "$*"; }
outln() { printf '%s\n' "$*"; }

# ---------- compute output paths FIRST ----------
CWD="$(pwd)"
FILENAME_NOEXT="$(basename "${OUT%.*}")"
BASENAME="${CWD}/${FILENAME_NOEXT}"
PDF_OUT="${BASENAME}.pdf"
HTML_OUT="${BASENAME}.html"
MD_OUT="${BASENAME}.md"

outln "=============================================="
outln "[OUTPUT] Working directory : $CWD"
outln "[OUTPUT] HTML report       : $HTML_OUT"
outln "[OUTPUT] PDF report        : $PDF_OUT"
outln "[OUTPUT] Markdown summary  : $MD_OUT"
outln "=============================================="

# ---------- error trap ----------
on_error() {
  local exit_code=$?
  outln ""
  outln "[ERROR] Script failed at line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"
  outln "[ERROR] Exit code: $exit_code"
  outln ""
  outln "Troubleshooting tips:"
  outln "  • Ensure 'gh' is authenticated:  gh auth login"
  outln "  • Check API rate limit:         gh api rate_limit"
  outln "  • Verify repo access:           gh repo view \"$REPO\""
  outln "  • Re-run with --verbose for shell trace."
  outln ""
  outln "Artifacts so far (if any):"
  outln "  HTML: $HTML_OUT"
  outln "  PDF : $PDF_OUT (if render reached)"
  outln "  MD  : $MD_OUT (summary)"
  exit "$exit_code"
}
trap on_error ERR

# ---------- deps ----------
need() { command -v "$1" >/dev/null 2>&1 || { outln "Missing dependency: $1"; exit 1; }; }
need gh
need jq

if ! gh auth status >/dev/null 2>&1; then
  outln "[ERROR] GitHub CLI not authenticated. Run: gh auth login"
  exit 1
fi

# ---------- helpers ----------
status_label_text() {
  case "$1" in
    GREEN) echo "Pass";;
    AMBER) echo "Warning";;
    RED)   echo "Fail";;
    *)     echo "$1";;
  esac
}
status_chip() { local s="$1"; echo "<span class=\"chip $s\">$(status_label_text "$s")</span>"; }
traffic_light_count() { local c="$1" g="$2" w="$3"; if [ "$c" -ge "$g" ]; then echo GREEN; elif [ "$c" -ge "$w" ]; then echo AMBER; else echo RED; fi; }
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
inc() { # POSIX-safe integer increment for possibly unset vars
  # usage: inc varname
  # shellcheck disable=SC2140
  eval "$1=\$(( \${$1:-0} + 1 ))"
}

# ---------- fetch repo data ----------
log "Collecting repository data for $REPO (window: last ${DAYS} days) ..."

repo_json="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}")"
default_branch="$(jq -r '.default_branch' <<<"$repo_json")"
repo_name="$(jq -r '.name' <<<"$repo_json")"
repo_full="$(jq -r '.full_name' <<<"$repo_json")"
repo_url="$(jq -r '.html_url' <<<"$repo_json")"
repo_desc="$(jq -r '.description // ""' <<<"$repo_json")"

since_utc="$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
since_180="$(date -u -d "-180 days" +%Y-%m-%dT%H:%M:%SZ)"
since_30="$(date -u -d "-30 days" +%Y-%m-%dT%H:%M:%SZ)"
generated_on="$(date -u '+%Y-%m-%d %H:%M UTC')"

root_contents="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/contents?ref=${default_branch}")"

MUST_FILES=( "LICENSE" "README.md" "CONTRIBUTING.md" "SECURITY.md" "CODE_OF_CONDUCT.md" "GOVERNANCE.md" "SUPPORT.md" "CHANGELOG.md" )

has_top_file() {
  local name="$1"
  if [[ "$name" == "LICENSE" ]]; then
    jq -r '.[].name' <<<"$root_contents" | grep -E -q '^LICENSE(\.md)?$'
  else
    jq -r '.[].name' <<<"$root_contents" | grep -Fx -q "$name"
  fi
}

# ---------- signals ----------
workflows_count=0
if gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/contents/.github/workflows?ref=${default_branch}" >/dev/null 2>&1; then
  workflows_count="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/contents/.github/workflows?ref=${default_branch}" | jq '[.[] | select(.type=="file") | select(.name|test("\\.ya?ml$"))] | length')"
fi

codescan_status="Not enabled"; codescan_label="AMBER"
if gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/code-scanning/alerts?per_page=1" >/dev/null 2>&1; then
  codescan_status="Enabled"; codescan_label="GREEN"
fi

releases_json="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/releases?per_page=100")"
releases_count="$(jq 'length' <<<"$releases_json")"
latest_release_tag="$(jq -r '.[0].tag_name // empty' <<<"$releases_json")"
latest_release_date="$(jq -r '.[0].published_at // ""' <<<"$releases_json")"

open_issues_count="$(gh api -H 'Accept: application/vnd.github+json' "/search/issues?q=repo:${REPO}+is:issue+is:open&per_page=1" | jq '.total_count')"
closed_issues_count="$(gh api -H 'Accept: application/vnd.github+json' "/search/issues?q=repo:${REPO}+is:issue+is:closed&per_page=1" | jq '.total_count')"

commits_30="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?sha=${default_branch}&since=${since_30}&per_page=100" | jq 'length')"
commits_90="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?sha=${default_branch}&since=${since_utc}&per_page=100" | jq 'length')"
commits_180_json="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?sha=${default_branch}&since=${since_180}&per_page=100")"
contributors_180="$(jq -r '.[].commit.author.email // empty' <<<"$commits_180_json" | awk 'NF' | sort -u | wc -l | tr -d ' ')"

maintainers_present="false"
if jq -r '.[].name' <<<"$root_contents" | grep -E -q '^(CODEOWNERS|MAINTAINERS(\.md)?|OWNERS)$'; then
  maintainers_present="true"
fi

# ---------- checklist ----------
passes=0; ambers=0; reds=0
checklist_rows=""
for f in "${MUST_FILES[@]}"; do
  status=""; note=""
  if has_top_file "$f"; then
    status="GREEN"; note="present"
  else
    if [[ "$f" == "SECURITY.md" ]]; then status="RED"; else status="AMBER"; fi
    note="missing (top level)"
  fi

  case "$status" in
    GREEN) inc passes ;;
    AMBER) inc ambers ;;
    RED)   inc reds ;;
    *)     : ;;
  esac

  checklist_rows+="<tr><td><code>${f}</code></td><td>$(status_chip "$status")</td><td>${note}</td></tr>"
done

ci_status="$(traffic_light_count "$workflows_count" 1 0)"
sec_status="$codescan_label"
activity_status="$(traffic_light_count "$commits_90" 10 1)"
contributors_status="$(traffic_light_count "$contributors_180" 5 2)"
release_status="$(traffic_light_count "$releases_count" 1 0)"

overall="GREEN"
if [ "$reds" -gt 0 ] || [ "$sec_status" = "RED" ] || [ "$activity_status" = "RED" ]; then
  overall="RED"
elif [ "$ambers" -gt 0 ] || [ "$sec_status" = "AMBER" ] || [ "$activity_status" = "AMBER" ]; then
  overall="AMBER"
fi

# KPI cards
kpi_cards=""
kpi_card() { local label="$1" value="$2" sub="$3"; kpi_cards+="<div class=\"card\"><div class=\"card-value\">${value}</div><div class=\"card-label\">${label}</div><div class=\"card-sub\">${sub}</div></div>"; }
kpi_card "Commits (30d)" "$commits_30" "$default_branch"
kpi_card "Commits (${DAYS}d)" "$commits_90" "$default_branch"
kpi_card "Contributors (180d)" "$contributors_180" "unique emails"
kpi_card "Issues" "${open_issues_count} open" "${closed_issues_count} closed"
if [[ -n "$latest_release_tag" ]]; then
  kpi_card "Releases" "$releases_count" "Latest ${latest_release_tag}"
else
  kpi_card "Releases" "$releases_count" "No tagged release"
fi

elig_rows=""
elig_rows+="<tr><td>Repo Health</td><td>$(status_chip "$(traffic_light_count "$passes" 6 4)")</td><td>License/README/CONTRIBUTING; ${commits_30} commits in 30d</td></tr>"
elig_rows+="<tr><td>Governance</td><td>$(status_chip "$( [[ "$maintainers_present" == true ]] && echo GREEN || echo AMBER )")</td><td>Maintainers/CODEOWNERS presence</td></tr>"
elig_rows+="<tr><td>Delivery</td><td>$(status_chip "$ci_status")</td><td>${workflows_count} workflow(s) detected</td></tr>"
elig_rows+="<tr><td>Security & Risk</td><td>$(status_chip "$sec_status")</td><td>${codescan_status}</td></tr>"
elig_rows+="<tr><td>Community Signals</td><td>$(status_chip "$contributors_status")</td><td>${contributors_180} contributors in 180d</td></tr>"

# ---------- write HTML ----------
cat > "$HTML_OUT" <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title><!--TITLE--></title>
  <style>
    :root { --bg:#0b1020; --panel:#121a33; --panel-2:#0f1630; --text:#e8ecf8; --muted:#b7c0da; --green:#2ecc71; --amber:#f39c12; --red:#e74c3c; --blue:#3da5ff; --border:#2a375c; }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,Noto Sans,Helvetica,Arial,"Apple Color Emoji","Segoe UI Emoji"}
    .container{max-width:1024px;margin:32px auto;padding:0 16px}
    .header{background:linear-gradient(135deg,#1b2a6b 0%,#0f1630 100%);padding:24px;border-radius:16px;border:1px solid var(--border);box-shadow:0 8px 24px rgba(0,0,0,.35)}
    .h-title{font-size:24px;margin:0 0 6px;display:flex;align-items:center;gap:10px}
    .h-sub{color:var(--muted);margin:0 0 4px}
    .h-meta{color:var(--muted);font-size:13px}
    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-top:16px}
    .card{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:14px}
    .card-value{font-size:24px;font-weight:700}
    .card-label{color:var(--muted);font-size:12px;margin-top:4px}
    .card-sub{color:var(--muted);font-size:11px;margin-top:2px;opacity:.85}
    .section{margin-top:24px}
    .section h2{font-size:16px;margin:0 0 10px;color:#d7def5}
    .panel{background:var(--panel-2);border:1px solid var(--border);border-radius:14px;padding:14px}
    table{width:100%;border-collapse:collapse}
    th,td{text-align:left;padding:10px 8px;border-bottom:1px solid var(--border)}
    th{color:#d7def5;font-weight:600;background:#0d1531;position:sticky;top:0}
    tr:last-child td{border-bottom:none}
    code{background:#0a1230;padding:2px 6px;border-radius:6px;border:1px solid var(--border)}
    .row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
    .chip{padding:4px 8px;border-radius:999px;font-size:12px;font-weight:600;border:1px solid transparent}
    .GREEN{background:rgba(46,204,113,.15);color:#a6f4c5;border-color:#2ecc71}
    .AMBER{background:rgba(243,156,18,.16);color:#ffd699;border-color:#f39c12}
    .RED{background:rgba(231,76,60,.16);color:#ffb3a7;border-color:#e74c3c}
    .legend{display:flex;gap:8px;align-items:center;color:var(--muted);font-size:12px}
    .legend .chip{font-weight:700}
    .footer{color:var(--muted);font-size:12px;margin-top:18px;text-align:center}
    a{color:#9dcaff;text-decoration:none}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="row">
        <h1 class="h-title">📄 <!--REPO_FULL--></h1>
        <div class="chip <!--OVERALL-->">Overall: <!--OVERALL_TEXT--></div>
      </div>
      <p class="h-sub"><!--REPO_DESC--></p>
      <p class="h-meta">
        Default branch: <b><!--BRANCH--></b> •
        Generated: <b><!--GENERATED--></b> •
        Source: <a href="<!--REPO_URL-->"><!--REPO_URL--></a>
      </p>
      <div class="grid">
        <!--KPI_CARDS-->
      </div>
    </div>

    <div class="section">
      <h2>Eligibility Overview</h2>
      <div class="panel">
        <table>
          <thead><tr><th>Category</th><th>Status</th><th>Notes</th></tr></thead>
          <tbody><!--ELIG_ROWS--></tbody>
        </table>
      </div>
    </div>

    <div class="section">
      <h2>Must-Have Checklist (Top-level only)</h2>
      <div class="panel">
        <table>
          <thead><tr><th>File</th><th>Status</th><th>Detail</th></tr></thead>
          <tbody><!--CHECKLIST_ROWS--></tbody>
        </table>
        <div class="legend" style="margin-top:10px;">
          Legend: <span class="chip GREEN">Pass</span>
                  <span class="chip AMBER">Warning</span>
                  <span class="chip RED">Fail</span>
        </div>
      </div>
    </div>

    <div class="section">
      <h2>Notes & Next Steps</h2>
      <div class="panel">
        <ul style="margin:0 0 0 18px;">
          <li>Ensure <code>SECURITY.md</code> exists and enable CodeQL/code scanning.</li>
          <li>Configure CI in <code>.github/workflows</code> to run build/test on PRs.</li>
          <li>Use Releases for tagged versions and changelogs.</li>
          <li>Keep README up to date; add GOVERNANCE/SUPPORT where applicable.</li>
        </ul>
      </div>
    </div>

    <div class="footer">Generated by gh_self_attest_v11.sh</div>
  </div>
</body>
</html>
EOF

# inject values
OVERALL_TEXT="$(status_label_text "$overall")"
sed -i \
  -e "s|<!--TITLE-->|${repo_full} • Self-Attestation|g" \
  -e "s|<!--REPO_FULL-->|$(echo "$repo_full" | esc)|g" \
  -e "s|<!--REPO_DESC-->|$(echo "$repo_desc" | esc)|g" \
  -e "s|<!--BRANCH-->|$(echo "$default_branch" | esc)|g" \
  -e "s|<!--GENERATED-->|$(echo "$generated_on" | esc)|g" \
  -e "s|<!--REPO_URL-->|$(echo "$repo_url" | esc)|g" \
  -e "s|<!--OVERALL-->|$overall|g" \
  -e "s|<!--OVERALL_TEXT-->|$OVERALL_TEXT|g" \
  -e "s|<!--KPI_CARDS-->|$kpi_cards|g" \
  -e "s|<!--ELIG_ROWS-->|$elig_rows|g" \
  -e "s|<!--CHECKLIST_ROWS-->|$checklist_rows|g" \
  "$HTML_OUT"

# small MD companion
{
  echo "# ${repo_name} • Self-Attestation (Summary)"
  echo ""
  echo "- Repo: ${repo_url}"
  echo "- Generated: ${generated_on}"
  echo "- Overall: $(status_label_text "$overall")"
} > "$MD_OUT"

# ---------- render PDF ----------
if command -v wkhtmltopdf >/dev/null 2>&1; then
  log "Using wkhtmltopdf to render PDF ..."
  if wkhtmltopdf "$HTML_OUT" "$PDF_OUT" >/dev/null 2>&1; then
    outln "[OUTPUT] ✅ PDF created successfully at: $PDF_OUT"
    outln "[OUTPUT] HTML also saved at: $HTML_OUT"
    outln "[OUTPUT] MD summary at: $MD_OUT"
    exit 0
  else
    outln "[OUTPUT] ❌ wkhtmltopdf failed; open HTML at: $HTML_OUT"
    exit 1
  fi
elif command -v pandoc >/dev/null 2>&1; then
  log "wkhtmltopdf not found; using pandoc (reduced CSS fidelity) ..."
  if pandoc "$HTML_OUT" -o "$PDF_OUT" 2>/dev/null; then
    outln "[OUTPUT] ✅ PDF created successfully at: $PDF_OUT"
    outln "[OUTPUT] HTML also saved at: $HTML_OUT"
    outln "[OUTPUT] MD summary at: $MD_OUT"
    exit 0
  else
    outln "[OUTPUT] ❌ pandoc failed; open HTML at: $HTML_OUT"
    exit 1
  fi
else
  outln "[OUTPUT] ⚠️ No PDF engine found. Open the HTML directly at: $HTML_OUT"
  outln "[OUTPUT] You can install one of:"
  outln "  • wkhtmltopdf   (best CSS fidelity)"
  outln "  • pandoc        (fallback)"
  exit 0
fi
