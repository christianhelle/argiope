const std = @import("std");
const crawler_mod = @import("crawler.zig");
const http_mod = @import("http.zig");
const html_mod = @import("html.zig");
const url_mod = @import("url.zig");
const cli_mod = @import("cli.zig");
const mangafox_mod = @import("mangafox.zig");

pub const DownloadResult = struct {
    total_pages: usize,
    downloaded: usize,
    failed: usize,
    skipped: usize,
};

/// Extract the file extension from a URL path (e.g., ".jpg", ".png").
/// Returns null if no extension found.
pub fn getExtension(url_str: []const u8) ?[]const u8 {
    // Find the path portion (after scheme+authority, before query/fragment)
    const path = getPathFromUrl(url_str);
    // Find last '.' in path
    if (std.mem.lastIndexOf(u8, path, ".")) |dot| {
        const ext = path[dot..];
        // Validate it looks like an image extension
        if (ext.len >= 2 and ext.len <= 5) return ext;
    }
    return null;
}

/// Extract the path portion of a URL.
fn getPathFromUrl(url_str: []const u8) []const u8 {
    // Skip scheme
    var start: usize = 0;
    if (std.mem.indexOf(u8, url_str, "://")) |s| {
        start = s + 3;
    }
    // Skip authority (host:port)
    if (std.mem.indexOfPos(u8, url_str, start, "/")) |slash| {
        const rest = url_str[slash..];
        // Trim query string and fragment
        const q = std.mem.indexOf(u8, rest, "?") orelse rest.len;
        const f = std.mem.indexOf(u8, rest, "#") orelse rest.len;
        const end = @min(q, f);
        return rest[0..end];
    }
    return "/";
}

/// Save binary data to a file within the given directory.
fn saveFile(dir: std.fs.Dir, filename: []const u8, data: []const u8) !void {
    dir.writeFile(.{ .sub_path = filename, .data = data }) catch |err| {
        return err;
    };
}

/// Create nested directory structure, returning the deepest Dir handle.
fn ensureDir(allocator: std.mem.Allocator, base_path: []const u8) !std.fs.Dir {
    // Use cwd-relative path
    const cwd = std.fs.cwd();
    cwd.makePath(base_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    _ = allocator;
    return cwd.openDir(base_path, .{}) catch return error.FileNotFound;
}

/// Run the downloader: crawl the site, find images, and save them.
pub fn run(allocator: std.mem.Allocator, opts: cli_mod.Options) !u8 {
    const url = opts.url orelse return 1;

    // Delegate to the MangaFox-specific downloader for fanfox.net URLs (by host)
    const is_fanfox = blk: {
        const parsed = url_mod.Url.parse(url) catch break :blk false;
        const host = parsed.host;
        const base = "fanfox.net";
        if (host.len == base.len) {
            break :blk std.ascii.eqlIgnoreCase(host, base);
        }
        const sub_suffix = ".fanfox.net";
        if (host.len > sub_suffix.len and
            std.ascii.eqlIgnoreCase(host[host.len - sub_suffix.len ..], sub_suffix))
        {
            break :blk true;
        }
        break :blk false;
    };
    if (is_fanfox) {
        return mangafox_mod.run(allocator, opts);
    }

    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;

    try w.print("Downloading images from {s}\n", .{url});
    try w.print("Output: {s}, Depth: {d}\n\n", .{ opts.output_dir, opts.depth });
    try w.flush();

    const crawl_start = std.time.milliTimestamp();

    var c = crawler_mod.Crawler.init(allocator, url, .{
        .max_depth = opts.depth,
        .timeout_ms = opts.timeout_ms,
        .delay_ms = opts.delay_ms,
        .parallel = opts.parallel,
    });
    defer c.deinit();

    try c.crawl();

    const crawl_elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - crawl_start);

    var result = DownloadResult{
        .total_pages = c.results.items.len,
        .downloaded = 0,
        .failed = 0,
        .skipped = 0,
    };

    // For each crawled page, find and download images
    var page_num: usize = 0;
    for (c.results.items) |r| {
        if (r.status < 200 or r.status >= 300) continue;
        page_num += 1;

        // Re-fetch the page to get body for image extraction
        const fetch_opts = http_mod.FetchOptions{
            .timeout_ms = opts.timeout_ms,
        };
        var response = http_mod.fetch(&c.client, allocator, r.url, fetch_opts) catch continue;
        defer response.deinit();

        if (!http_mod.isHtmlContent(response.content_type)) continue;

        // Extract image URLs
        const links = html_mod.extractLinks(allocator, response.body) catch continue;
        defer allocator.free(links);

        var img_num: usize = 0;
        for (links) |link| {
            if (link.link_type != .image) continue;
            img_num += 1;

            const img_url = url_mod.resolve(allocator, r.url, link.href) catch continue;
            defer allocator.free(img_url);

            if (!url_mod.isHttp(img_url)) {
                result.skipped += 1;
                continue;
            }

            // Determine file extension
            const ext = getExtension(img_url) orelse ".jpg";

            // Build output path: output_dir/page_N/image_N.ext
            var path_buf: [1024]u8 = undefined;
            const page_dir = std.fmt.bufPrint(&path_buf, "{s}/page_{d}", .{
                opts.output_dir,
                page_num,
            }) catch continue;

            var dir = ensureDir(allocator, page_dir) catch continue;
            defer dir.close();

            // Download the image
            var img_response = http_mod.fetch(&c.client, allocator, img_url, fetch_opts) catch {
                result.failed += 1;
                continue;
            };
            defer img_response.deinit();

            if (!img_response.isSuccess()) {
                result.failed += 1;
                continue;
            }

            // Save to file
            var name_buf: [256]u8 = undefined;
            const filename = std.fmt.bufPrint(&name_buf, "{d}{s}", .{
                img_num,
                ext,
            }) catch continue;

            saveFile(dir, filename, img_response.body) catch {
                result.failed += 1;
                continue;
            };

            result.downloaded += 1;

            try w.print("  Saved {s}/{s}\n", .{ page_dir, filename });
            try w.flush();
        }
    }

    // Print summary
    try w.print("\nDownload complete:\n", .{});
    try w.print("  Pages crawled:    {d}\n", .{result.total_pages});
    try w.print("  Images downloaded: {d}\n", .{result.downloaded});
    try w.print("  Failed:           {d}\n", .{result.failed});
    try w.print("  Skipped:          {d}\n", .{result.skipped});
    try w.print("\nTiming:\n", .{});
    try w.print("  Total crawl time: {d}ms\n", .{crawl_elapsed_ms});
    try w.flush();

    return 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "getExtension basic" {
    try std.testing.expectEqualStrings(".jpg", getExtension("https://example.com/img/photo.jpg").?);
    try std.testing.expectEqualStrings(".png", getExtension("https://example.com/photo.png").?);
    try std.testing.expectEqualStrings(".gif", getExtension("https://example.com/a.gif").?);
    try std.testing.expectEqualStrings(".webp", getExtension("https://example.com/x.webp").?);
}

test "getExtension with query string" {
    try std.testing.expectEqualStrings(".jpg", getExtension("https://example.com/photo.jpg?w=100").?);
}

test "getExtension with fragment" {
    try std.testing.expectEqualStrings(".png", getExtension("https://example.com/img.png#top").?);
}

test "getExtension no extension" {
    try std.testing.expect(getExtension("https://example.com/page") == null);
    try std.testing.expect(getExtension("https://example.com/") == null);
}

test "getPathFromUrl" {
    try std.testing.expectEqualStrings("/img/photo.jpg", getPathFromUrl("https://example.com/img/photo.jpg"));
    try std.testing.expectEqualStrings("/a.png", getPathFromUrl("https://example.com/a.png?q=1"));
    try std.testing.expectEqualStrings("/", getPathFromUrl("https://example.com"));
}

test "DownloadResult defaults" {
    const r = DownloadResult{
        .total_pages = 5,
        .downloaded = 3,
        .failed = 1,
        .skipped = 1,
    };
    try std.testing.expect(r.total_pages == 5);
    try std.testing.expect(r.downloaded == 3);
    try std.testing.expect(r.failed == 1);
    try std.testing.expect(r.skipped == 1);
}

test "saveFile and read back" {
    // Use a temp directory for testing
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "test image data";
    try saveFile(tmp.dir, "test.jpg", data);

    // Read it back
    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "test.jpg", 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("test image data", content);
}

test "getExtension edge cases" {
    // Very long extension should be rejected
    try std.testing.expect(getExtension("https://example.com/file.toolongext") == null);
    // Single char extension
    try std.testing.expectEqualStrings(".a", getExtension("https://example.com/file.a").?);
}
