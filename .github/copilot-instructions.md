# zigcrawler – Copilot Instructions

`zigcrawler` is a web crawler CLI tool written in Zig (minimum version 0.15.2) for detecting broken links and downloading images from websites. It has no external dependencies.

## Build, run, and test

```sh
zig build                          # compile → zig-out/bin/zigcrawler
zig build run -- check <url>       # build + run link checker
zig build run -- download <url>    # build + run image downloader
zig build test                     # run all tests
```

## Architecture

All source files live flat in `src/`. The data flow is:

```
main.zig  →  cli.zig  →  crawler.zig  →  http.zig
                              ↓              ↓
                         html.zig       url.zig
                              ↓
                    link_checker.zig  (check mode)
                    downloader.zig   (download mode)
```

| File | Responsibility |
|---|---|
| `main.zig` | Entry point; owns `GeneralPurposeAllocator`; wires modules together |
| `cli.zig` | CLI argument parsing for `check` and `download` subcommands |
| `url.zig` | URL normalization, relative-to-absolute resolution, same-origin checks |
| `http.zig` | HTTP client wrapper: GET requests, status codes, redirect following, timeouts |
| `html.zig` | Lightweight HTML scanner: extracts `<a href>` and `<img src>` attributes |
| `crawler.zig` | BFS crawl engine: visited set, depth limiting, domain restriction |
| `link_checker.zig` | Broken link reporter: collects URLs, checks status, outputs tabular report |
| `downloader.zig` | File downloader: saves images to organized directory structure |

## Key conventions

**Tests are inline.** Every `.zig` file that has logic contains `test` blocks directly in that file.
`main.zig` has a `test "imports compile"` block that imports all other modules,
ensuring the test binary transitively covers all inline tests when `src/main.zig` is the test root.

**Memory ownership is explicit.** All allocations go through `GeneralPurposeAllocator` for leak detection.
HTTP response bodies are allocated by `http.zig` and freed by the caller.
URL lists from the HTML parser use `ArrayList` and are freed by the caller.
The visited set uses a `HashMap` with owned key strings, freed on `deinit`.

**Thread-safety model:** The crawler dispatches work via `Thread.Pool`. Shared state (visited set, results) is mutex-guarded.

**Output buffering:** stdout output uses a stack-allocated buffer passed to `std.fs.File.stdout().writer()`. Always call `flush()`.

**Source control:** Commit progress to git in small logical chunks with clear one-liner messages. Do not change the committer to Copilot and do not add a Co-Author line.
