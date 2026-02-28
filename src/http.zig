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
};

/// Fetch a URL via GET, following redirects. Returns response with body.
/// Caller owns the returned Response and must call deinit().
pub fn fetch(allocator: std.mem.Allocator, url_str: []const u8, options: FetchOptions) !Response {
    const uri = std.Uri.parse(url_str) catch return error.InvalidUrl;

    var server_header_buf: [16 * 1024]u8 = undefined;
    var client: std.http.Client = .{ .allocator = allocator, .server_header_buffer = &server_header_buf };
    defer client.deinit();

    var req = client.open(.GET, uri, .{
        .redirect_behavior = if (options.max_redirects > 0)
            .{ .limited = options.max_redirects }
        else
            .unresolved,
    }) catch return error.ConnectionFailed;
    defer req.deinit();

    req.send() catch return error.ConnectionFailed;
    req.wait() catch return error.ConnectionFailed;

    const status: u16 = @intFromEnum(req.status);

    // Extract content-type
    const content_type: ?[]u8 = blk: {
        const ct_header = req.response.content_type orelse break :blk null;
        const ct_str = switch (ct_header) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
        break :blk try allocator.dupe(u8, ct_str);
    };
    errdefer if (content_type) |ct| allocator.free(ct);

    // Read response body
    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_list.deinit(allocator);

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = req.read(&read_buf) catch break;
        if (n == 0) break;
        if (body_list.items.len + n > options.max_body_size) break;
        try body_list.appendSlice(allocator, read_buf[0..n]);
    }

    const body = try body_list.toOwnedSlice(allocator);

    return Response{
        .status = status,
        .body = body,
        .allocator = allocator,
        .content_type = content_type,
    };
}

/// Check if a URL is reachable by sending a GET request and reading only headers.
/// Returns the HTTP status code, or error if connection fails.
pub fn checkStatus(allocator: std.mem.Allocator, url_str: []const u8, options: FetchOptions) !u16 {
    const uri = std.Uri.parse(url_str) catch return error.InvalidUrl;

    var server_header_buf: [16 * 1024]u8 = undefined;
    var client: std.http.Client = .{ .allocator = allocator, .server_header_buffer = &server_header_buf };
    defer client.deinit();

    var req = client.open(.GET, uri, .{
        .redirect_behavior = if (options.max_redirects > 0)
            .{ .limited = options.max_redirects }
        else
            .unresolved,
    }) catch return error.ConnectionFailed;
    defer req.deinit();

    req.send() catch return error.ConnectionFailed;
    req.wait() catch return error.ConnectionFailed;

    return @intFromEnum(req.status);
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
