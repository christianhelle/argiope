const std = @import("std");

pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    query: ?[]const u8,

    /// Parse a URL string into components.
    /// The returned Url borrows slices from the input string.
    pub fn parse(raw: []const u8) !Url {
        const uri = std.Uri.parse(raw) catch return error.InvalidUrl;

        const scheme = if (uri.scheme.len > 0) uri.scheme else return error.InvalidUrl;
        const host_raw = uri.host orelse return error.InvalidUrl;
        const host = switch (host_raw) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
        if (host.len == 0) return error.InvalidUrl;

        return Url{
            .scheme = scheme,
            .host = host,
            .port = uri.port,
            .path = if (uri.path.isEmpty()) "/" else switch (uri.path) {
                .raw => |r| r,
                .percent_encoded => |p| p,
            },
            .query = blk: {
                if (uri.query) |q| {
                    break :blk switch (q) {
                        .raw => |r| r,
                        .percent_encoded => |p| p,
                    };
                }
                break :blk null;
            },
        };
    }

    /// Return the origin string: "scheme://host[:port]"
    pub fn origin(self: Url, buf: []u8) ![]const u8 {
        var writer = std.Io.Writer.fixed(buf);
        if (self.port) |p| {
            try writer.print("{s}://{s}:{d}", .{ self.scheme, self.host, p });
        } else {
            try writer.print("{s}://{s}", .{ self.scheme, self.host });
        }
        return writer.buffered();
    }

    /// Check if two URLs share the same origin (scheme + host + port).
    pub fn sameOrigin(self: Url, other: Url) bool {
        if (!std.mem.eql(u8, self.scheme, other.scheme)) return false;
        if (!std.ascii.eqlIgnoreCase(self.host, other.host)) return false;
        const p1 = self.effectivePort();
        const p2 = other.effectivePort();
        return p1 == p2;
    }

    fn effectivePort(self: Url) u16 {
        if (self.port) |p| return p;
        if (std.mem.eql(u8, self.scheme, "https")) return 443;
        if (std.mem.eql(u8, self.scheme, "http")) return 80;
        return 0;
    }
};

/// Resolve a possibly-relative href against a base URL.
/// Returns a newly allocated absolute URL string. Caller must free.
pub fn resolve(allocator: std.mem.Allocator, base: []const u8, href: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, href, " \t\n\r");
    if (trimmed.len == 0) return error.EmptyHref;

    // Already absolute
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        return try allocator.dupe(u8, trimmed);
    }

    const base_url = try Url.parse(base);
    var buf: [4096]u8 = undefined;

    if (std.mem.startsWith(u8, trimmed, "//")) {
        // Protocol-relative
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print("{s}:{s}", .{ base_url.scheme, trimmed });
        return try allocator.dupe(u8, writer.buffered());
    }

    const origin_str = try base_url.origin(&buf);

    if (trimmed[0] == '/') {
        // Absolute path
        const result = try allocator.alloc(u8, origin_str.len + trimmed.len);
        @memcpy(result[0..origin_str.len], origin_str);
        @memcpy(result[origin_str.len..], trimmed);
        return result;
    }

    // Relative path — resolve against base path directory
    const base_path = base_url.path;
    const dir_end = if (std.mem.lastIndexOf(u8, base_path, "/")) |i| i + 1 else 1;
    const base_dir = base_path[0..dir_end];

    // Copy origin to separate buffer to avoid aliasing
    var origin_copy: [512]u8 = undefined;
    @memcpy(origin_copy[0..origin_str.len], origin_str);
    const origin_safe = origin_copy[0..origin_str.len];

    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{s}{s}{s}", .{ origin_safe, base_dir, trimmed });
    return try allocator.dupe(u8, writer.buffered());
}

/// Normalize a URL by removing the fragment and trailing slash from path.
/// Returns a newly allocated string. Caller must free.
pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Strip fragment
    const no_frag = if (std.mem.indexOf(u8, raw, "#")) |i| raw[0..i] else raw;

    // Strip trailing slash (but keep if it's part of origin like "https://example.com/")
    var clean = no_frag;
    if (clean.len > 0) {
        // Find the end of the scheme+authority to know where path starts
        const path_start = if (std.mem.indexOf(u8, clean, "://")) |i| blk: {
            // Find next / after authority
            break :blk std.mem.indexOfPos(u8, clean, i + 3, "/") orelse clean.len;
        } else 0;

        // Only strip trailing slashes from the path portion, keep root "/"
        while (clean.len > path_start + 1 and clean[clean.len - 1] == '/') {
            clean = clean[0 .. clean.len - 1];
        }
    }

    // Also remove trailing ? if query is empty
    if (clean.len > 0 and clean[clean.len - 1] == '?') {
        clean = clean[0 .. clean.len - 1];
    }

    return try allocator.dupe(u8, clean);
}

/// Check if a URL string is an HTTP/HTTPS URL.
pub fn isHttp(raw: []const u8) bool {
    return std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://");
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse absolute URL" {
    const u = try Url.parse("https://example.com/path?q=1");
    try std.testing.expectEqualStrings("https", u.scheme);
    try std.testing.expectEqualStrings("example.com", u.host);
    try std.testing.expect(u.port == null);
    try std.testing.expectEqualStrings("/path", u.path);
    try std.testing.expectEqualStrings("q=1", u.query.?);
}

test "parse URL with port" {
    const u = try Url.parse("http://localhost:8080/api");
    try std.testing.expectEqualStrings("http", u.scheme);
    try std.testing.expectEqualStrings("localhost", u.host);
    try std.testing.expect(u.port.? == 8080);
    try std.testing.expectEqualStrings("/api", u.path);
}

test "parse URL without path" {
    const u = try Url.parse("https://example.com");
    try std.testing.expectEqualStrings("/", u.path);
}

test "parse invalid URL" {
    try std.testing.expectError(error.InvalidUrl, Url.parse("not-a-url"));
    try std.testing.expectError(error.InvalidUrl, Url.parse("://missing-scheme"));
}

test "sameOrigin" {
    const a = try Url.parse("https://example.com/page1");
    const b = try Url.parse("https://example.com/page2");
    const c = try Url.parse("http://example.com/page1");
    const d = try Url.parse("https://other.com/page1");
    try std.testing.expect(a.sameOrigin(b));
    try std.testing.expect(!a.sameOrigin(c)); // different scheme
    try std.testing.expect(!a.sameOrigin(d)); // different host
}

test "sameOrigin with ports" {
    const a = try Url.parse("http://example.com:80/path");
    const b = try Url.parse("http://example.com/path");
    try std.testing.expect(a.sameOrigin(b)); // port 80 is default for http
}

test "resolve absolute href" {
    const result = try resolve(std.testing.allocator, "https://base.com", "https://other.com/page");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://other.com/page", result);
}

test "resolve root-relative href" {
    const result = try resolve(std.testing.allocator, "https://example.com/dir/page", "/about");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/about", result);
}

test "resolve relative href" {
    const result = try resolve(std.testing.allocator, "https://example.com/dir/page.html", "other.html");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/dir/other.html", result);
}

test "resolve protocol-relative href" {
    const result = try resolve(std.testing.allocator, "https://example.com/page", "//cdn.example.com/img.png");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://cdn.example.com/img.png", result);
}

test "resolve empty href" {
    try std.testing.expectError(error.EmptyHref, resolve(std.testing.allocator, "https://example.com", ""));
    try std.testing.expectError(error.EmptyHref, resolve(std.testing.allocator, "https://example.com", "   "));
}

test "normalize strips fragment" {
    const result = try normalize(std.testing.allocator, "https://example.com/page#section");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/page", result);
}

test "normalize strips trailing slash" {
    const result = try normalize(std.testing.allocator, "https://example.com/path/");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/path", result);
}

test "normalize preserves root path" {
    const result = try normalize(std.testing.allocator, "https://example.com/");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/", result);
}

test "normalize strips empty query" {
    const result = try normalize(std.testing.allocator, "https://example.com/page?");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/page", result);
}

test "isHttp" {
    try std.testing.expect(isHttp("http://example.com"));
    try std.testing.expect(isHttp("https://example.com"));
    try std.testing.expect(!isHttp("ftp://example.com"));
    try std.testing.expect(!isHttp("mailto:user@example.com"));
    try std.testing.expect(!isHttp("javascript:void(0)"));
}

test "origin" {
    const u = try Url.parse("https://example.com/path?q=1");
    var buf: [256]u8 = undefined;
    const o = try u.origin(&buf);
    try std.testing.expectEqualStrings("https://example.com", o);
}

test "origin with port" {
    const u = try Url.parse("http://localhost:3000/api");
    var buf: [256]u8 = undefined;
    const o = try u.origin(&buf);
    try std.testing.expectEqualStrings("http://localhost:3000", o);
}
