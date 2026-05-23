# 🔗 Markdown Link Checker (GitHub Action)

Scans all `.md` files in your repository and checks every external link for validity. Posts a detailed report as a PR comment or workflow artifact.

## Features

- ✅ **Automatic discovery** — finds all markdown files in the repo
- ✅ **Parallel checking** — configurable concurrency for speed
- ✅ **PR comments** — posts results directly on the pull request
- ✅ **Detailed report** — per-link status, broken URLs summary
- ✅ **Fail option** — optionally fail the workflow on broken links
- ✅ **Exclusion support** — skip specific files/patterns
- ✅ **No external dependencies** — pure bash + curl

## Usage

### Basic (PR check)

```yaml
name: Check Links
on:
  pull_request:
    paths:
      - '**.md'

jobs:
  link-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: Major126/link-checker-action@v1
```

### Full configuration

```yaml
- uses: Major126/link-checker-action@v1
  with:
    # Glob pattern for markdown files (default: '**/*.md')
    files-path: 'docs/**/*.md'
    # Files to exclude (comma-separated glob patterns)
    exclude-files: '**/CHANGELOG.md,**/node_modules/**'
    # Max concurrent link checks (default: 10)
    max-concurrency: '20'
    # Timeout per link in seconds (default: 10)
    timeout: '15'
    # Fail the workflow if broken links found (default: false)
    fail-on-broken: 'true'
```

## Outputs

| Output | Description |
|--------|-------------|
| `total-links` | Total number of links checked |
| `broken-links` | Number of broken/error links |
| `report-file` | Path to the generated report |

## Workflow

1. Scans all markdown files matching the glob pattern
2. Extracts all `http://` and `https://` URLs
3. Checks each URL with `curl` (respects redirects)
4. Generates a markdown report
5. Comments on the PR (if triggered by PR) or uploads as artifact
6. Optionally fails the workflow

## License

MIT
