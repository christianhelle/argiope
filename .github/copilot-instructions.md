# argiope – Copilot Instructions

`argiope` is a web crawler CLI tool written in Zig (minimum version 0.16.0) for detecting broken links and downloading images from websites. It has no external dependencies — uses only `std`. The `images` command now also generates portable HTML browsing pages (root `library.html`, nested `index.html`, and per-folder `reader.html`) after downloads complete. Release automation updates `snapcraft.yaml` and `src/cli.zig` together.

## Source Control and Documentation (MANDATORY)

**Keep README in sync:** After every feature addition, change, or bug fix, update `README.md` to reflect the current state of the application. This must be done automatically — do not wait to be asked. Update usage examples, the options reference, feature lists, and architecture notes as needed. The README is the source of truth for users.

**Keep the description in snapcraft.yaml in sync**: Similar to the README requirement, except that the snapcraft description is limited to 4096 characters.

**Commits:** Make commits in small logical chunks automatically — do not wait to be asked.

- Use brief commit messages (one line only).
- Always commit as the user (the actual developer), never create commits under fictional identities like "Copilot Agent" or similar.
- **Never commit directly to the main branch.** If you detect that the current branch is `main`, create a feature branch (e.g., `your-feature-name`) before making any commits.
- Use clear, concise commit messages that describe the change in one sentence.
- Never add `Co-authored-by` trailers to commits in this repository.

## Build, run, and test

```sh
zig build                          # compile → zig-out/bin/argiope
zig build run -- check <url>       # build + run link checker
zig build run -- images <url>      # build + run image downloader
zig build test                     # run all tests
make build                         # alternative via Makefile
make test
```

## Zig 0.16 API Notes

These are critical project conventions for Zig 0.16:

- **main/process init**: Prefer `pub fn main(init: std.process.Init) !void`; use `init.gpa`, `init.io`, and `init.minimal.args.toSlice(init.arena.allocator())`.
- **stdout/stderr**: Use `std.Io.File.stdout().writer(io, &buf)` / `stderr`; access via `.interface.print()` and `.interface.flush()`.
- **ArrayList**: Use `std.ArrayListUnmanaged(T)` with `.empty` init. Methods require explicit allocator: `.append(allocator, item)`, `.toOwnedSlice(allocator)`, `.deinit(allocator)`
- **HashMap**: Use `std.StringHashMapUnmanaged(V)` with `.empty` init. Same explicit allocator pattern.
- **Allocating writers**: Use `std.Io.Writer.Allocating` for formatted in-memory byte buffers; `ArrayList.writer()` is not available.
- **Sleep/time**: Use `io.sleep(.fromMilliseconds(n), .awake)` and `std.Io.Timestamp.now(io, .awake)`, not `std.Thread.sleep()` or `std.time.milliTimestamp()`.
- **Mutexes**: Use `std.Io.Mutex.init`, `lockUncancelable(io)`/`lock(io)`, and `unlock(io)` instead of `std.Thread.Mutex`.
- **HTTP Client**: Initialize with `.io = io`. No `server_header_buffer`. Use `client.request(.GET, uri, .{})` → `req.sendBodiless()` → `req.receiveHead(&buf)` → `response.reader(&buf)` → `reader.allocRemaining(allocator, .unlimited)`
- **Reader**: New vtable-based `std.Io.Reader`. Key methods: `allocRemaining()`, `streamRemaining()`, `discardRemaining()`. No `.read()` method.
- **File/Dir I/O**: Use `std.Io.File` / `std.Io.Dir`. Pass `io` explicitly to file and directory operations: `createDirPath(io, ...)`, `openDir(io, ...)`, `createFile(io, ...)`, `writeFile(io, ...)`, `readFileAlloc(io, ..., std.Io.Limit.limited(max))`, and `close(io)`.
- **Fixed buffers**: Use `std.Io.Writer.fixed(&buf)` and `writer.buffered()` instead of `std.io.fixedBufferStream()`.
- **Build resources**: Add Windows resource files via `exe.root_module.addWin32ResourceFile(...)`, not on the compile step.

## Key conventions

**Tests are inline.** Every `.zig` file with logic contains `test` blocks.
`main.zig` has a `test "imports compile"` block that imports all modules,
ensuring the test binary transitively covers all inline tests.

**Memory ownership is explicit.** Runtime allocations use the allocator supplied by `std.process.Init`; tests use `std.testing.allocator`/`std.testing.io` for leak and I/O checking.
HTTP response bodies are allocated by `http.zig` and freed by the caller via `Response.deinit()`.
Link slices from `html.extractLinks()` borrow from the input HTML — only the slice itself needs freeing.
The visited set uses `StringHashMapUnmanaged` with owned key strings, freed on `Crawler.deinit()`.
`CrawlResult.deinit()` skips freeing zero-length url slices (error fallback path).

**Output buffering:** stdout uses a stack-allocated buffer via `std.Io.File.stdout().writer(io, &buf)`. Always call `flush()` after printing.
