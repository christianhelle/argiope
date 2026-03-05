# argiope – Copilot Instructions

`argiope` is a web crawler CLI tool written in Zig (minimum version 0.15.2) for detecting broken links and downloading images from websites. It has no external dependencies — uses only `std`.

## Build, run, and test

```sh
zig build                          # compile → zig-out/bin/argiope
zig build run -- check <url>       # build + run link checker
zig build run -- download <url>    # build + run image downloader
zig build test                     # run all tests
make build                         # alternative via Makefile
make test
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

| File               | Responsibility                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| `main.zig`         | Entry point; owns `GeneralPurposeAllocator`; wires modules together                                     |
| `cli.zig`          | CLI argument parsing for `check` and `download` subcommands                                             |
| `url.zig`          | URL parsing (wraps `std.Uri`), normalization, relative-to-absolute resolution, same-origin              |
| `http.zig`         | HTTP client wrapper using `std.http.Client` with `request/sendBodiless/receiveHead/reader`              |
| `html.zig`         | HTML scanner: extracts `<a href>`, `<img src>`, `<link href>`, `<script src>`, `<iframe src>`, `srcset` |
| `crawler.zig`      | BFS crawl engine: visited `StringHashMap`, depth limiting, domain restriction, rate limiting            |
| `link_checker.zig` | Broken link reporter: collects URLs, checks status, outputs tabular report                              |
| `downloader.zig`   | Image downloader: saves images to `output_dir/page_N/image_N.ext` structure                             |

## Zig 0.15 API Notes

These are critical differences from older Zig versions:

- **stdout/stderr**: `std.fs.File.stdout().writer(&buf)` → access via `.interface.print()` and `.interface.flush()`
- **ArrayList**: Use `std.ArrayListUnmanaged(T)` with `.empty` init. Methods require explicit allocator: `.append(allocator, item)`, `.toOwnedSlice(allocator)`, `.deinit(allocator)`
- **HashMap**: Use `std.StringHashMapUnmanaged(V)` with `.empty` init. Same explicit allocator pattern.
- **Thread.sleep**: `std.Thread.sleep(nanoseconds)` — NOT `std.time.sleep()`
- **HTTP Client**: No `server_header_buffer`. Use `client.request(.GET, uri, .{})` → `req.sendBodiless()` → `req.receiveHead(&buf)` → `response.reader(&buf)` → `reader.allocRemaining(allocator, .unlimited)`
- **Reader**: New vtable-based `std.Io.Reader`. Key methods: `allocRemaining()`, `streamRemaining()`, `discardRemaining()`. No `.read()` method.
- **File Reader**: `file.reader(&buf)` returns struct with `.interface` field (the `std.Io.Reader`). Use `readFileAlloc()` on Dir for simple reads.

## Key conventions

**Tests are inline.** Every `.zig` file with logic contains `test` blocks.
`main.zig` has a `test "imports compile"` block that imports all modules,
ensuring the test binary transitively covers all inline tests.

**Memory ownership is explicit.** All allocations go through `GeneralPurposeAllocator` (leak detection in debug).
HTTP response bodies are allocated by `http.zig` and freed by the caller via `Response.deinit()`.
Link slices from `html.extractLinks()` borrow from the input HTML — only the slice itself needs freeing.
The visited set uses `StringHashMapUnmanaged` with owned key strings, freed on `Crawler.deinit()`.
`CrawlResult.deinit()` skips freeing zero-length url slices (error fallback path).

**Output buffering:** stdout uses a stack-allocated buffer via `std.fs.File.stdout().writer(&buf)`. Always call `flush()` after printing.

## Source Control and Documentation

**Keep README in sync:** Every feature addition, change, or fix must update the README to reflect the current state of the application. Update usage examples, architecture diagrams, feature lists, or options as needed. The README is the source of truth for users.

**Commits:**

- Make commits in small logical chunks with clear one-liner descriptions for a detailed progress history.
- Use brief commit messages (one line only).
- Always commit as the user (the actual developer), never create commits under fictional identities like "Copilot Agent" or similar.
- **Never commit directly to the main branch.** If you detect that the current branch is `main`, create a feature branch (e.g., `feature/your-feature-name`) before making any commits.
- Use clear, concise commit messages that describe the change in one sentence.
