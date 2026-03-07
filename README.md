[![CI](https://github.com/christianhelle/argiope/actions/workflows/ci.yml/badge.svg)](https://github.com/christianhelle/argiope/actions/workflows/ci.yml)
[![Release](https://github.com/christianhelle/argiope/actions/workflows/release.yml/badge.svg)](https://github.com/christianhelle/argiope/actions/workflows/release.yml)

# argiope

A web crawler for broken-link detection and image downloading, written in [Zig](https://ziglang.org/).

## Features

- Crawl websites and detect broken links (4xx/5xx/timeout)
- Generate reports in text, Markdown, or HTML format
- Download images from web pages to organized directories
- Generate portable HTML browsing pages for downloaded image trees (`library.html`, nested `index.html`, and `reader.html`)
- Download manga chapters from [MangaFox (fanfox.net)](https://fanfox.net) by title, with optional chapter range filtering
- BFS traversal with configurable depth, timeouts, and rate limiting
- Domain-restricted crawling with same-origin checks
- Lightweight HTML scanner for link and image extraction
- URL normalization and relative-to-absolute resolution
- Zero external dependencies — uses only `std`
- Single static binary — no runtime needed
- Cross-platform: Linux, macOS, Windows

## Installation

### Snap

```sh
sudo snap install argiope
```

### Download from GitHub Releases

Pre-built binaries for Linux (x86_64, aarch64), macOS (x86_64, aarch64), and Windows (x86_64) are available on the [Releases](https://github.com/christianhelle/argiope/releases) page.

### Build from source

Requires [Zig 0.15.2+](https://ziglang.org/download/):

```sh
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/argiope`.

Release automation keeps `snapcraft.yaml` and `src/cli.zig` aligned so tagged release builds publish matching package and CLI versions.

## Usage

### Check for broken links

```sh
argiope check https://example.com
argiope check https://example.com --depth 5 --timeout 15
```

Output includes a list of broken links with status codes and a summary:

```text
Crawling https://example.com (depth=3, timeout=10s)...

----------------------------------------------------------------------------------------
Status   Type       Time(ms)   URL
----------------------------------------------------------------------------------------
404      internal   45         https://example.com/missing-page
timeout  external   10001      https://dead-link.example.org/page
----------------------------------------------------------------------------------------

Summary:
  Total URLs checked: 42
  OK:                 40
  Broken:             1
  Errors:             1
  Internal:           30
  External:           12

Timing:
  Total crawl time:   523ms
  Avg response time:  12ms
  Min response time:  5ms
  Max response time:  10001ms
```

### Download images

```sh
argiope images https://example.com/gallery -o ./images
argiope images https://manga-site.com/title --depth 2 -o ./manga
```

Images are saved to `output_dir/page_N/image_N.ext` where the extension is derived from the source URL. After downloads finish, argiope also generates a portable HTML browser rooted at `output_dir/library.html`, plus nested `index.html` and per-folder `reader.html` pages for thumbnails and ordered reading.

The generated browser works for both generic downloads and MangaFox chapter trees, keeps links relative for local file browsing, and includes light / dark / system theme controls with a `localStorage`-backed preference (default: system).

### Download manga from MangaFox

Pass a [fanfox.net](https://fanfox.net) manga URL to the `images` command. Chapter pages are downloaded automatically and saved as `[output_dir]/[manga-title]/[chapter]/[page].jpg`, and the same HTML browser is generated across the manga folder tree for scalable chapter navigation.

```sh
# Download all chapters
argiope images https://fanfox.net/manga/naruto -o ./manga

# Download a specific range of chapters
argiope images https://fanfox.net/manga/naruto --chapters 1-10 -o ./manga
```

**Chapter detection:** The tool fetches the manga's RSS feed (`https://fanfox.net/rss/{slug}.xml`) as the primary chapter source. This reliably detects all chapters, including those on manga titles where the chapter list is loaded dynamically via JavaScript (which static HTML parsing cannot see). If the RSS feed is unavailable or empty, the tool automatically falls back to HTML parsing.

**Chapter ordering:** Chapters are always downloaded in numeric order (1, 2, 10, 11, 100), not alphabetic order. Decimal chapter numbers (e.g., 5.5, 100.1) are fully supported and sorted correctly between their integer neighbors.

**Troubleshooting:** If chapters are missing or not detected, use `--verbose` to see detailed chapter discovery information:

```sh
argiope images https://fanfox.net/manga/title --verbose
```

This will show all chapters found and the order they will be downloaded in.

### Browse downloaded images in HTML

Open the generated root landing page after an `images` run:

```sh
xdg-open ./images/library.html
```

Each folder with downloaded images gets:

- `index.html` for nested navigation and thumbnail overviews
- `reader.html` for ordered prev/next viewing inside that folder
- theme controls for **System**, **Light**, and **Dark**, persisted in `localStorage`

This scales from the generic `page_N/` layout to deep MangaFox trees such as `slug/chapter/page.jpg`.

### Verbose Mode

For detailed progress output while crawling:

```sh
argiope check https://example.com --verbose
```

Each URL will be printed as it is checked, showing the crawling progress in real-time.

### Parallel Crawling

For faster crawling on sites with many links, enable parallel crawling:

```sh
argiope check https://example.com --parallel
```

This crawls multiple URLs concurrently for improved performance.

### Generate reports

Write the results to a file instead of printing to the terminal. In report mode all console output is suppressed, making it suitable for CI pipelines and LLM-based workflows.

```sh
# Text report (default)
argiope check https://example.com --report report.txt

# Markdown report
argiope check https://example.com --report report.md --report-format markdown

# HTML report (self-contained, no external dependencies)
argiope check https://example.com --report report.html --report-format html
```

By default only broken links appear in the report. Add `--include-positives` to include all successfully resolved links as well:

```sh
argiope check https://example.com --report report.md --report-format markdown --include-positives
```

#### Report formats

| Format | Description |
|--------|-------------|
| `text` | Plain-text list with indented type/timing detail per entry (default) |
| `markdown` | GitHub-Flavored Markdown bullet list — suitable for PR comments or wikis |
| `html` | Self-contained HTML file with inline CSS, card layout, and pill badges |

### Options

```text
Usage: argiope <command> [options]

Commands:
  check <url>           Crawl a website and report broken links
  images <url>          Download images from a website

Options:
  --depth N             Maximum crawl depth (default: 3)
  --timeout N           Request timeout in seconds (default: 10)
  --delay N             Delay between requests in ms (default: 100)
  -o, --output DIR      Output directory for downloads (default: ./download)
  --chapters N-M        Chapter range to download, e.g. --chapters 1-10 (fanfox.net only)
  --verbose             Print progress for each URL as it is crawled
  --parallel            Crawl URLs in parallel for better performance
  --report <file>       Write a report to <file>
  --report-format <fmt> Report format: text (default), markdown, html
  --include-positives   Include successful links in the report
  -h, --help            Show help
  -v, --version         Show version
```

## Development

```sh
# Build
zig build

# Run tests
zig build test

# Build release
zig build -Doptimize=ReleaseFast

# Or use Make
make build
make test
make clean
```

## License

MIT
