[![CI](https://github.com/christianhelle/argiope/actions/workflows/ci.yml/badge.svg)](https://github.com/christianhelle/argiope/actions/workflows/ci.yml)
[![Release](https://github.com/christianhelle/argiope/actions/workflows/release.yml/badge.svg)](https://github.com/christianhelle/argiope/actions/workflows/release.yml)

# argiope

A web crawler for broken-link detection and image downloading, written in [Zig](https://ziglang.org/).

## Features

- Crawl websites and detect broken links (4xx/5xx/timeout)
- Download images from web pages to organized directories
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

## Usage

### Check for broken links

```sh
argiope check https://example.com
argiope check https://example.com --depth 5 --timeout 15
```

Output includes a table of broken links with status codes and a summary:

```
Crawling https://example.com (depth=3, timeout=10s)...

------------------------------------------------------------------------------
Status   Type       URL
------------------------------------------------------------------------------
404      internal   https://example.com/missing-page
timeout  external   https://dead-link.example.org/page
------------------------------------------------------------------------------

Summary:
  Total URLs checked: 42
  OK:                 40
  Broken:             1
  Errors:             1
  Internal:           30
  External:           12
```

### Download images

```sh
argiope images https://example.com/gallery -o ./images
argiope images https://manga-site.com/title --depth 2 -o ./manga
```

Images are saved to `output_dir/page_N/image_N.ext` where the extension is derived from the source URL.

### Download manga from MangaFox

Pass a [fanfox.net](https://fanfox.net) manga URL to the `images` command. Chapter pages are downloaded automatically and saved as `[output_dir]/[manga-title]/[chapter]/[page].jpg`.

```sh
# Download all chapters
argiope images https://fanfox.net/manga/naruto -o ./manga

# Download a specific range of chapters
argiope images https://fanfox.net/manga/naruto --chapters 1-10 -o ./manga
```

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

### Options

```
Usage: argiope <command> [options]

Commands:
  check <url>       Crawl a website and report broken links
  images <url>      Download images from a website

Options:
  --depth N         Maximum crawl depth (default: 3)
  --timeout N       Request timeout in seconds (default: 10)
  --delay N         Delay between requests in ms (default: 100)
  -o, --output DIR  Output directory for downloads (default: ./download)
  --chapters N-M    Chapter range to download, e.g. --chapters 1-10 (fanfox.net only)
  --verbose         Print progress for each URL as it is crawled
  --parallel        Crawl URLs in parallel for better performance
  -h, --help        Show help
  -v, --version     Show version
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
