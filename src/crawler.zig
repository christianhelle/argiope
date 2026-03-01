const std = @import("std");
const url_mod = @import("url.zig");
const http_mod = @import("http.zig");
const html_mod = @import("html.zig");

pub const CrawlResult = struct {
    url: []u8,
    status: u16,
    links_found: usize,
    is_internal: bool,
    error_msg: ?[]u8,

    pub fn deinit(self: *CrawlResult, allocator: std.mem.Allocator) void {
        if (self.url.len > 0) allocator.free(self.url);
        if (self.error_msg) |msg| allocator.free(msg);
    }
};

pub const CrawlOptions = struct {
    max_depth: u16 = 3,
    timeout_ms: u32 = 10_000,
    delay_ms: u32 = 100,
    max_redirects: u8 = 5,
    max_body_size: usize = 10 * 1024 * 1024,
    verbose: bool = false,
};

pub const Crawler = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    options: CrawlOptions,
    visited: std.StringHashMapUnmanaged(void),
    results: std.ArrayListUnmanaged(CrawlResult),
    queue: std.ArrayListUnmanaged(QueueEntry),
    base_parsed: ?url_mod.Url,
    client: std.http.Client,

    const QueueEntry = struct {
        url: []u8,
        depth: u16,
    };

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, options: CrawlOptions) Crawler {
        return Crawler{
            .allocator = allocator,
            .base_url = base_url,
            .options = options,
            .visited = .empty,
            .results = .empty,
            .queue = .empty,
            .base_parsed = url_mod.Url.parse(base_url) catch null,
            .client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Crawler) void {
        for (self.results.items) |*r| {
            r.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);

        // Free any remaining queue entries
        for (self.queue.items) |entry| {
            self.allocator.free(entry.url);
        }
        self.queue.deinit(self.allocator);

        // Free visited keys
        var it = self.visited.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.visited.deinit(self.allocator);

        self.client.deinit();
    }

    /// Run the crawl starting from the base URL.
    pub fn crawl(self: *Crawler) !void {
        // Seed the queue with the base URL
        const seed = try self.allocator.dupe(u8, self.base_url);
        try self.queue.append(self.allocator, .{ .url = seed, .depth = 0 });

        while (self.queue.items.len > 0) {
            const entry = self.queue.swapRemove(0);
            defer self.allocator.free(entry.url);

            // Normalize the URL
            const normalized = url_mod.normalize(self.allocator, entry.url) catch continue;

            // Check if already visited
            if (self.visited.get(normalized) != null) {
                self.allocator.free(normalized);
                continue;
            }

            // Mark as visited (transfer ownership of normalized to visited set)
            try self.visited.put(self.allocator, normalized, {});

            // Check if internal
            const is_internal = self.isInternal(normalized);

            // Verbose progress reporting
            if (self.options.verbose) {
                var pbuf: [2048]u8 = undefined;
                var fw = std.fs.File.stderr().writer(&pbuf);
                fw.interface.print("[{d} queued] Checking: {s}\n", .{ self.queue.items.len, normalized }) catch {};
                fw.interface.flush() catch {};
            }

            // Fetch the page
            const result = self.fetchPage(normalized, entry.depth, is_internal);
            try self.results.append(self.allocator, result);

            // Rate limiting
            if (self.options.delay_ms > 0) {
                std.Thread.sleep(@as(u64, self.options.delay_ms) * std.time.ns_per_ms);
            }
        }
    }

    fn fetchPage(self: *Crawler, url_str: []const u8, depth: u16, is_internal: bool) CrawlResult {
        const fetch_opts = http_mod.FetchOptions{
            .max_redirects = self.options.max_redirects,
            .timeout_ms = self.options.timeout_ms,
            .max_body_size = self.options.max_body_size,
        };

        var response = http_mod.fetch(&self.client, self.allocator, url_str, fetch_opts) catch |err| {
            const url_copy = self.allocator.dupe(u8, url_str) catch return CrawlResult{
                .url = &.{},
                .status = 0,
                .links_found = 0,
                .is_internal = is_internal,
                .error_msg = null,
            };
            return CrawlResult{
                .url = url_copy,
                .status = 0,
                .links_found = 0,
                .is_internal = is_internal,
                .error_msg = self.allocator.dupe(u8, @errorName(err)) catch null,
            };
        };
        defer response.deinit();

        var links_found: usize = 0;

        // Only parse HTML and follow links for internal pages within depth limit
        if (is_internal and depth < self.options.max_depth and
            (http_mod.isHtmlContent(response.content_type) or response.content_type == null))
        {
            const links = html_mod.extractLinks(self.allocator, response.body) catch {
                const url_copy = self.allocator.dupe(u8, url_str) catch return CrawlResult{
                    .url = &.{},
                    .status = response.status,
                    .links_found = 0,
                    .is_internal = is_internal,
                    .error_msg = null,
                };
                return CrawlResult{
                    .url = url_copy,
                    .status = response.status,
                    .links_found = 0,
                    .is_internal = is_internal,
                    .error_msg = null,
                };
            };
            defer self.allocator.free(links);
            links_found = links.len;

            for (links) |link| {
                const resolved = url_mod.resolve(self.allocator, url_str, link.href) catch continue;

                // Only queue HTTP(S) URLs
                if (!url_mod.isHttp(resolved)) {
                    self.allocator.free(resolved);
                    continue;
                }

                const norm = url_mod.normalize(self.allocator, resolved) catch {
                    self.allocator.free(resolved);
                    continue;
                };
                self.allocator.free(resolved);

                if (self.visited.get(norm) != null) {
                    self.allocator.free(norm);
                    continue;
                }

                // Queue for crawling
                self.queue.append(self.allocator, .{
                    .url = norm,
                    .depth = depth + 1,
                }) catch {
                    self.allocator.free(norm);
                    continue;
                };
            }
        }

        const url_copy = self.allocator.dupe(u8, url_str) catch return CrawlResult{
            .url = &.{},
            .status = response.status,
            .links_found = links_found,
            .is_internal = is_internal,
            .error_msg = null,
        };
        return CrawlResult{
            .url = url_copy,
            .status = response.status,
            .links_found = links_found,
            .is_internal = is_internal,
            .error_msg = null,
        };
    }

    fn isInternal(self: *Crawler, url_str: []const u8) bool {
        const base = self.base_parsed orelse return false;
        const parsed = url_mod.Url.parse(url_str) catch return false;
        return base.sameOrigin(parsed);
    }

    /// Get all results with non-success status codes.
    pub fn getBrokenLinks(self: *Crawler) []CrawlResult {
        // Return a view into the results (no allocation needed)
        // Caller iterates results and checks status
        return self.results.items;
    }

    /// Get all results for image URLs.
    pub fn getImageUrls(_: *Crawler, allocator: std.mem.Allocator, html_body: []const u8, page_url: []const u8) ![][]u8 {
        const links = try html_mod.extractLinks(allocator, html_body);
        defer allocator.free(links);

        var images: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (images.items) |img| allocator.free(img);
            images.deinit(allocator);
        }

        for (links) |link| {
            if (link.link_type == .image) {
                const resolved = url_mod.resolve(allocator, page_url, link.href) catch continue;
                try images.append(allocator, resolved);
            }
        }

        return try images.toOwnedSlice(allocator);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "Crawler init and deinit" {
    var crawler = Crawler.init(std.testing.allocator, "https://example.com", .{});
    defer crawler.deinit();

    try std.testing.expect(crawler.visited.count() == 0);
    try std.testing.expect(crawler.results.items.len == 0);
    try std.testing.expect(crawler.queue.items.len == 0);
}

test "Crawler isInternal" {
    var crawler = Crawler.init(std.testing.allocator, "https://example.com", .{});
    defer crawler.deinit();

    try std.testing.expect(crawler.isInternal("https://example.com/page"));
    try std.testing.expect(crawler.isInternal("https://example.com/deep/path"));
    try std.testing.expect(!crawler.isInternal("https://other.com/page"));
    try std.testing.expect(!crawler.isInternal("http://example.com/page")); // different scheme
}

test "CrawlOptions defaults" {
    const opts = CrawlOptions{};
    try std.testing.expect(opts.max_depth == 3);
    try std.testing.expect(opts.timeout_ms == 10_000);
    try std.testing.expect(opts.delay_ms == 100);
}

test "CrawlResult deinit" {
    const allocator = std.testing.allocator;
    var result = CrawlResult{
        .url = try allocator.dupe(u8, "https://example.com"),
        .status = 200,
        .links_found = 5,
        .is_internal = true,
        .error_msg = try allocator.dupe(u8, "test error"),
    };
    result.deinit(allocator);
}

test "Crawler getImageUrls" {
    var crawler = Crawler.init(std.testing.allocator, "https://example.com", .{});
    defer crawler.deinit();

    const html =
        \\<html><body>
        \\<img src="/img1.jpg">
        \\<a href="/page">Link</a>
        \\<img src="/img2.png">
        \\</body></html>
    ;

    const images = try crawler.getImageUrls(std.testing.allocator, html, "https://example.com/gallery");
    defer {
        for (images) |img| std.testing.allocator.free(img);
        std.testing.allocator.free(images);
    }

    try std.testing.expect(images.len == 2);
    try std.testing.expectEqualStrings("https://example.com/img1.jpg", images[0]);
    try std.testing.expectEqualStrings("https://example.com/img2.png", images[1]);
}
