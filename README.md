# zigcrawler

A web crawler for broken-link detection and image downloading, written in [Zig](https://ziglang.org/).

[![CI](https://github.com/christianhelle/zigcrawler/actions/workflows/ci.yml/badge.svg)](https://github.com/christianhelle/zigcrawler/actions/workflows/ci.yml)
[![Release](https://github.com/christianhelle/zigcrawler/actions/workflows/release.yml/badge.svg)](https://github.com/christianhelle/zigcrawler/actions/workflows/release.yml)

## Features

- Crawl websites and detect broken links (4xx/5xx/timeout)
- Download images from web pages to organized directories
- Configurable crawl depth, timeouts, and rate limiting
- Zero external dependencies
- Single static binary — no runtime needed
- Cross-platform: Linux, macOS, Windows

## Installation

### Snap

```sh
sudo snap install zigcrawler
```

### Download from GitHub Releases

Pre-built binaries for Linux (x86_64, aarch64), macOS (x86_64, aarch64), and Windows (x86_64) are available on the [Releases](https://github.com/christianhelle/zigcrawler/releases) page.

### Build from source

Requires [Zig 0.15.2+](https://ziglang.org/download/):

```sh
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/zigcrawler`.

## Usage

### Check for broken links

```sh
zigcrawler check https://example.com
zigcrawler check https://example.com --depth 5 --timeout 15
```

### Download images

```sh
zigcrawler download https://example.com/gallery -o ./images
zigcrawler download https://manga-site.com/title/chapter1 -o ./manga/title/ch01
```

### Options

```
Usage: zigcrawler <command> [options]

Commands:
  check <url>       Crawl a website and report broken links
  download <url>    Download images from a website

Options:
  --depth N         Maximum crawl depth (default: 3)
  --timeout N       Request timeout in seconds (default: 10)
  --delay N         Delay between requests in ms (default: 100)
  -o, --output DIR  Output directory for downloads (default: ./download)
  -h, --help        Show help
  -v, --version     Show version
```

## License

MIT
