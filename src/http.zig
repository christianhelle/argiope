const std = @import("std");

pub const HttpError = error{
    ConnectionFailed,
    TooManyRedirects,
    InvalidResponse,
    Timeout,
};

pub const Response = struct {
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,
    content_type: ?[]u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        if (self.content_type) |ct| self.allocator.free(ct);
    }

    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    pub fn isRedirect(self: Response) bool {
        return self.status >= 300 and self.status < 400;
    }

    pub fn isClientError(self: Response) bool {
        return self.status >= 400 and self.status < 500;
    }

    pub fn isServerError(self: Response) bool {
        return self.status >= 500;
    }
};

pub const FetchOptions = struct {
    max_redirects: u8 = 5,
    timeout_ms: u32 = 10_000,
    max_body_size: usize = 10 * 1024 * 1024, // 10 MB
    extra_headers: []const std.http.Header = &.{},
    /// Override the User-Agent header. When null the Zig default is used.
    user_agent: ?[]const u8 = null,
};

fn resolveRedirectUrl(uri: std.Uri, location: []const u8, location_buf: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, location, "http://") or
        std.mem.startsWith(u8, location, "https://"))
    {
        return location;
    }

    const scheme = uri.scheme;
    const host = switch (uri.host orelse std.Uri.Component{ .raw = "" }) {
        .raw => |r| r,
        .percent_encoded => |r| r,
    };

    if (std.mem.startsWith(u8, location, "//")) {
        var fbs = std.io.fixedBufferStream(location_buf);
        const writer = fbs.writer();
        try writer.print("{s}:{s}", .{ scheme, location });
        return fbs.getWritten();
    }

    var fbs = std.io.fixedBufferStream(location_buf);
    const writer = fbs.writer();
    if (uri.port) |port| {
        try writer.print("{s}://{s}:{d}", .{ scheme, host, port });
    } else {
        try writer.print("{s}://{s}", .{ scheme, host });
    }

    if (location.len > 0 and location[0] == '/') {
        try writer.writeAll(location);
        return fbs.getWritten();
    }

    const base_path = if (uri.path.isEmpty()) "/" else switch (uri.path) {
        .raw => |path| path,
        .percent_encoded => |path| path,
    };
    const dir_end = if (std.mem.lastIndexOf(u8, base_path, "/")) |i| i + 1 else 1;
    const base_dir = if (std.mem.eql(u8, base_path, "/")) "/" else base_path[0..dir_end];
    try writer.print("{s}{s}", .{ base_dir, location });
    return fbs.getWritten();
}

fn transitionResponseState(response: anytype) void {
    var drain_buf: [8192]u8 = undefined;
    _ = response.reader(&drain_buf);
}

/// Fetch a URL via GET, following redirects. Returns response with body.
/// Caller owns the returned Response and must call deinit().
/// Reuses the provided client for connection pooling across requests.
pub fn fetch(client: *std.http.Client, allocator: std.mem.Allocator, url_str: []const u8, options: FetchOptions) !Response {
    var redirect_count: u8 = 0;
    var location_buf: [4096]u8 = undefined;
    var current_url: []const u8 = url_str;

    while (true) {
        const uri = std.Uri.parse(current_url) catch return error.ConnectionFailed;

        // Use .unhandled so receiveHead never calls bodyReader(&.{}, ...) internally,
        // which panics when redirect response body bytes are already buffered.
        var req = client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = if (options.user_agent) |ua| .{ .override = ua } else .default,
            },
            .extra_headers = options.extra_headers,
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buf: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return error.ConnectionFailed;

        const status: u16 = @intFromEnum(response.head.status);

        // Follow redirects manually so we can drain the body with a real buffer.
        if (status >= 300 and status < 400) {
            redirect_count += 1;
            if (redirect_count > options.max_redirects) return error.TooManyRedirects;

            const location = response.head.location orelse return error.ConnectionFailed;

            // Resolve relative Location values against the current URL.
            const new_url = resolveRedirectUrl(uri, location, &location_buf) catch return error.ConnectionFailed;

            if (new_url.ptr != location_buf[0..].ptr) {
                // absolute URL not yet in location_buf — copy it in
                if (new_url.len > location_buf.len) return error.ConnectionFailed;
                @memcpy(location_buf[0..new_url.len], new_url);
                current_url = location_buf[0..new_url.len];
            } else {
                current_url = new_url;
            }

            // Transition reader state out of .received_head before deinit().
            // If state stays .received_head, deinit() calls bodyReader(&.{}, ...)
            // which returns reader.in for body-less redirects, then discardRemaining()
            // triggers defaultDiscard's assert(seek == end) when bytes are buffered.
            // Calling reader() here sets state to .body_none / .body_remaining_*,
            // causing deinit() to take the `else => closing = true` path instead.
            transitionResponseState(&response);

            continue;
        }

        // Extract content-type before reader invalidates strings
        const content_type: ?[]u8 = if (response.head.content_type) |ct|
            allocator.dupe(u8, ct) catch null
        else
            null;
        errdefer if (content_type) |ct| allocator.free(ct);

        // Read response body up to max_body_size to prevent OOM on large responses
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(allocator, .{ .limited = options.max_body_size }) catch
            (allocator.dupe(u8, "") catch return error.ConnectionFailed);

        return Response{
            .status = status,
            .body = body,
            .allocator = allocator,
            .content_type = content_type,
        };
    }
}

/// Check if a URL is reachable by sending a GET request.
/// Returns the HTTP status code, or error if connection fails.
pub fn checkStatus(allocator: std.mem.Allocator, url_str: []const u8, options: FetchOptions) !u16 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var redirect_count: u8 = 0;
    var location_buf: [4096]u8 = undefined;
    var current_url: []const u8 = url_str;

    while (true) {
        const uri = std.Uri.parse(current_url) catch return error.ConnectionFailed;

        var req = client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = if (options.user_agent) |ua| .{ .override = ua } else .default,
            },
            .extra_headers = options.extra_headers,
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buf: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return error.ConnectionFailed;
        const status: u16 = @intFromEnum(response.head.status);

        if (status >= 300 and status < 400) {
            redirect_count += 1;
            if (redirect_count > options.max_redirects) return error.TooManyRedirects;

            const location = response.head.location orelse return error.ConnectionFailed;
            const new_url = resolveRedirectUrl(uri, location, &location_buf) catch return error.ConnectionFailed;

            if (new_url.ptr != location_buf[0..].ptr) {
                if (new_url.len > location_buf.len) return error.ConnectionFailed;
                @memcpy(location_buf[0..new_url.len], new_url);
                current_url = location_buf[0..new_url.len];
            } else {
                current_url = new_url;
            }

            // Creating the reader is enough to leave .received_head; req.deinit() then closes without draining.
            transitionResponseState(&response);
            continue;
        }

        // Creating the reader is enough to leave .received_head; req.deinit() then closes without draining.
        transitionResponseState(&response);
        return status;
    }
}

/// Check if a content-type header indicates HTML content.
pub fn isHtmlContent(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    return std.mem.indexOf(u8, ct, "text/html") != null or
        std.mem.indexOf(u8, ct, "application/xhtml") != null;
}

/// Check if a content-type header indicates an image.
pub fn isImageContent(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    return std.mem.startsWith(u8, ct, "image/");
}

/// Get a human-readable status description.
pub fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "Response.isSuccess" {
    var resp = Response{
        .status = 200,
        .body = try std.testing.allocator.dupe(u8, "ok"),
        .allocator = std.testing.allocator,
        .content_type = null,
    };
    defer resp.deinit();
    try std.testing.expect(resp.isSuccess());
    try std.testing.expect(!resp.isRedirect());
    try std.testing.expect(!resp.isClientError());
    try std.testing.expect(!resp.isServerError());
}

test "Response.isClientError" {
    var resp = Response{
        .status = 404,
        .body = try std.testing.allocator.dupe(u8, "not found"),
        .allocator = std.testing.allocator,
        .content_type = null,
    };
    defer resp.deinit();
    try std.testing.expect(!resp.isSuccess());
    try std.testing.expect(resp.isClientError());
}

test "Response.isServerError" {
    var resp = Response{
        .status = 500,
        .body = try std.testing.allocator.dupe(u8, "error"),
        .allocator = std.testing.allocator,
        .content_type = null,
    };
    defer resp.deinit();
    try std.testing.expect(resp.isServerError());
}

test "Response.isRedirect" {
    var resp = Response{
        .status = 301,
        .body = try std.testing.allocator.dupe(u8, ""),
        .allocator = std.testing.allocator,
        .content_type = null,
    };
    defer resp.deinit();
    try std.testing.expect(resp.isRedirect());
}

test "Response.deinit frees body and content_type" {
    var resp = Response{
        .status = 200,
        .body = try std.testing.allocator.dupe(u8, "body content"),
        .allocator = std.testing.allocator,
        .content_type = try std.testing.allocator.dupe(u8, "text/html"),
    };
    resp.deinit();
    // No leak = test passes (GeneralPurposeAllocator would catch leaks)
}

test "isHtmlContent" {
    try std.testing.expect(isHtmlContent("text/html; charset=utf-8"));
    try std.testing.expect(isHtmlContent("text/html"));
    try std.testing.expect(isHtmlContent("application/xhtml+xml"));
    try std.testing.expect(!isHtmlContent("application/json"));
    try std.testing.expect(!isHtmlContent("image/png"));
    try std.testing.expect(!isHtmlContent(null));
}

test "isImageContent" {
    try std.testing.expect(isImageContent("image/png"));
    try std.testing.expect(isImageContent("image/jpeg"));
    try std.testing.expect(isImageContent("image/gif"));
    try std.testing.expect(!isImageContent("text/html"));
    try std.testing.expect(!isImageContent(null));
}

test "statusText" {
    try std.testing.expectEqualStrings("OK", statusText(200));
    try std.testing.expectEqualStrings("Not Found", statusText(404));
    try std.testing.expectEqualStrings("Internal Server Error", statusText(500));
    try std.testing.expectEqualStrings("Unknown", statusText(999));
}

test "FetchOptions defaults" {
    const opts = FetchOptions{};
    try std.testing.expect(opts.max_redirects == 5);
    try std.testing.expect(opts.timeout_ms == 10_000);
    try std.testing.expect(opts.max_body_size == 10 * 1024 * 1024);
}

test "resolveRedirectUrl preserves absolute locations" {
    const uri = try std.Uri.parse("https://example.com/base/page");
    var buf: [256]u8 = undefined;
    const resolved = try resolveRedirectUrl(uri, "https://cdn.example.com/image.png", &buf);
    try std.testing.expectEqualStrings("https://cdn.example.com/image.png", resolved);
}

test "resolveRedirectUrl handles root-relative locations" {
    const uri = try std.Uri.parse("https://example.com/base/page");
    var buf: [256]u8 = undefined;
    const resolved = try resolveRedirectUrl(uri, "/images/pic.jpg", &buf);
    try std.testing.expectEqualStrings("https://example.com/images/pic.jpg", resolved);
}

test "resolveRedirectUrl handles path-relative locations" {
    const uri = try std.Uri.parse("https://example.com/base/page");
    var buf: [256]u8 = undefined;
    const resolved = try resolveRedirectUrl(uri, "next/page.html", &buf);
    try std.testing.expectEqualStrings("https://example.com/base/next/page.html", resolved);
}

test "resolveRedirectUrl handles protocol-relative locations" {
    const uri = try std.Uri.parse("https://example.com/base/page");
    var buf: [256]u8 = undefined;
    const resolved = try resolveRedirectUrl(uri, "//cdn.example.com/image.png", &buf);
    try std.testing.expectEqualStrings("https://cdn.example.com/image.png", resolved);
}
