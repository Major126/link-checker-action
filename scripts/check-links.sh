#!/bin/bash
#===============================================================================
# Markdown Link Checker - checks all http/https links in markdown files
#===============================================================================
set -euo pipefail

REPORT_DIR="${RUNNER_TEMP:-/tmp}"
REPORT_FILE="$REPORT_DIR/link-checker-report.md"
TIMEOUT="${TIMEOUT:-10}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-10}"
FAIL_ON_BROKEN="${FAIL_ON_BROKEN:-false}"
FILES_PATH="${FILES_PATH:-**/*.md}"
EXCLUDE_FILES="${EXCLUDE_FILES:-}"
BASE_URL="${BASE_URL:-}"

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Initialize report
echo "# 🔗 Markdown Link Check Report" > "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "**Scan time:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$REPORT_FILE"
echo "**Timeout per link:** ${TIMEOUT}s" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Collect markdown files
echo "## 📁 Files Scanned" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

MD_FILES=()
EXCLUDE_PATTERNS=()
IFS=',' read -ra EXCL <<< "$EXCLUDE_FILES"
for pattern in "${EXCL[@]}"; do
  pattern=$(echo "$pattern" | xargs)
  [ -n "$pattern" ] && EXCLUDE_PATTERNS+=("$pattern")
done

# Use find with glob
while IFS= read -r file; do
  skip=false
  for excl in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ "$file" == $excl ]]; then
      skip=true
      break
    fi
  done
  if [ "$skip" = false ]; then
    MD_FILES+=("$file")
  fi
done < <(find . -type f -name '*.md' -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | sort)

FILE_COUNT=${#MD_FILES[@]}
echo "- **Total markdown files found:** $FILE_COUNT" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "⚠️ No markdown files found to scan." >> "$REPORT_FILE"
  cat "$REPORT_FILE"
  exit 0
fi

for f in "${MD_FILES[@]}"; do
  echo "  - \`$f\"" >> "$REPORT_FILE"
done
echo "" >> "$REPORT_FILE"

# Extract all URLs from markdown files
echo "## 🔍 Link Check Results" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

URLS_FILE="$TEMP_DIR/all_urls.txt"
> "$URLS_FILE"

for file in "${MD_FILES[@]}"; do
  # Extract markdown links: [text](url)
  grep -oP '\]\(https?://[^)\s]+' "$file" 2>/dev/null | sed 's/]\(//' >> "$URLS_FILE" || true
  # Extract bare URLs: https://... not inside parentheses
  grep -oP '(?<!\()https?://[^)\s"<>`]+' "$file" 2>/dev/null >> "$URLS_FILE" || true
done

# Filter and deduplicate URLs
sort -u "$URLS_FILE" > "$TEMP_DIR/unique_urls.txt"
# Filter out obviously invalid/truncated URLs
grep -E '^https?://[a-zA-Z0-9]' "$TEMP_DIR/unique_urls.txt" > "$TEMP_DIR/filtered_urls.txt" || true

TOTAL_URLS=$(wc -l < "$TEMP_DIR/filtered_urls.txt")
echo "- **Total unique links to check:** $TOTAL_URLS" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ "$TOTAL_URLS" -eq 0 ]; then
  echo "✅ No links found to check." >> "$REPORT_FILE"
  cat "$REPORT_FILE"
  exit 0
fi

# Check each URL
echo "| # | Status | URL | File (first occurrence) |" >> "$REPORT_FILE"
echo "|--:|:------:|------|:------------------------|" >> "$REPORT_FILE"

BROKEN_COUNT=0
CHECKED_COUNT=0
BROKEN_URLS=()

# Process URLs with parallel workers for speed
WORKER_DIR="$TEMP_DIR/workers"
mkdir -p "$WORKER_DIR"
RESULTS_DIR="$TEMP_DIR/results"
mkdir -p "$RESULTS_DIR"

# Split URLs into chunks for parallel processing
split -l $(( TOTAL_URLS > MAX_CONCURRENCY ? TOTAL_URLS / MAX_CONCURRENCY + 1 : 1 )) \
  "$TEMP_DIR/filtered_urls.txt" "$WORKER_DIR/chunk_"

check_url() {
  local url="$1"
  local outfile="$2"
  local timeout="${3:-10}"
  
  # Skip certain known-problematic patterns
  case "$url" in
    *"example.com"*|*"localhost"*|*"127.0.0.1"*|*"0.0.0.0"*)
      echo "SKIP|$url" >> "$outfile"
      return 0
      ;;
  esac
  
  # Check with curl (follow redirects, check HTTP status)
  local http_code
  http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time "$timeout" \
    --user-agent "Mozilla/5.0 (compatible; LinkChecker/1.0)" \
    "$url" 2>/dev/null) || http_code="000"
  
  case "$http_code" in
    2[0-9][0-9])
      echo "OK|$url" >> "$outfile"
      ;;
    3[0-9][0-9])
      # Redirect that curl followed successfully
      echo "OK|$url" >> "$outfile"
      ;;
    4[0-9][0-9]|5[0-9][0-9])
      echo "BROKEN|$url ($http_code)" >> "$outfile"
      ;;
    *)
      echo "ERROR|$url ($http_code)" >> "$outfile"
      ;;
  esac
}

export -f check_url

# Run parallel checks
PIDS=()
for chunk in "$WORKER_DIR"/chunk_*; do
  (
    while IFS= read -r url; do
      [ -z "$url" ] && continue
      check_url "$url" "$RESULTS_DIR/result_${chunk##*_}" "$TIMEOUT"
    done < "$chunk"
  ) &
  PIDS+=($!)
done

# Wait for all workers to finish
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# Collect results
INDEX=0
cat "$RESULTS_DIR"/*.txt 2>/dev/null | sort -t'|' -k1 > "$TEMP_DIR/all_results.txt"

while IFS='|' read -r status url info; do
  INDEX=$((INDEX + 1))
  CHECKED_COUNT=$((CHECKED_COUNT + 1))
  
  # Find first occurrence file
  FIRST_FILE=""
  for file in "${MD_FILES[@]}"; do
    if grep -q "$url" "$file" 2>/dev/null; then
      FIRST_FILE="$file"
      break
    fi
  done
  
  case "$status" in
    "OK"|"SKIP")
      echo "| $INDEX | ✅ | \`$url\` | $FIRST_FILE |" >> "$REPORT_FILE"
      ;;
    "BROKEN")
      BROKEN_COUNT=$((BROKEN_COUNT + 1))
      BROKEN_URLS+=("$url")
      echo "| $INDEX | ❌ | \`$url\` → **$info** | $FIRST_FILE |" >> "$REPORT_FILE"
      ;;
    "ERROR")
      BROKEN_COUNT=$((BROKEN_COUNT + 1))
      BROKEN_URLS+=("$url")
      echo "| $INDEX | ⚠️ | \`$url\` → $info | $FIRST_FILE |" >> "$REPORT_FILE"
      ;;
  esac
done < "$TEMP_DIR/all_results.txt"

echo "" >> "$REPORT_FILE"

# Summary
echo "## 📊 Summary" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "- **Total links checked:** $CHECKED_COUNT" >> "$REPORT_FILE"
echo "- **Broken/Error links:** $BROKEN_COUNT" >> "$REPORT_FILE"
echo "- **Health:** " >> "$REPORT_FILE"
if [ "$BROKEN_COUNT" -eq 0 ]; then
  echo "  ✅ **All links are healthy!**" >> "$REPORT_FILE"
else
  echo "  ❌ **$BROKEN_COUNT broken link(s) found.**" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  echo "### 🛠 Broken URLs to fix" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  for burl in "${BROKEN_URLS[@]}"; do
    echo "- \`$burl\`" >> "$REPORT_FILE"
  done
fi

echo "" >> "$REPORT_FILE"
echo "---" >> "$REPORT_FILE"
echo "_Generated by [Markdown Link Checker](https://github.com/marketplace/actions/markdown-link-checker)_" >> "$REPORT_FILE"

# Output the report
cat "$REPORT_FILE"

# Set outputs for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "total-links=$CHECKED_COUNT" >> "$GITHUB_OUTPUT"
  echo "broken-links=$BROKEN_COUNT" >> "$GITHUB_OUTPUT"
  echo "report-file=$REPORT_FILE" >> "$GITHUB_OUTPUT"
fi

# Fail if required
if [ "$FAIL_ON_BROKEN" = "true" ] && [ "$BROKEN_COUNT" -gt 0 ]; then
  echo "❌ FAIL_ON_BROKEN is true, exiting with error."
  exit 1
fi

exit 0
