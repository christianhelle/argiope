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
/// Reuses the provided client for connection pooling across requests.
pub fn fetch(client: *std.http.Client, allocator: std.mem.Allocator, url_str: []const u8, options: FetchOptions) !Response {
    const uri = std.Uri.parse(url_str) catch return error.InvalidUrl;

    var req = client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch return error.ConnectionFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.ConnectionFailed;

    var redirect_buf: [16 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.ConnectionFailed;

    const status: u16 = @intFromEnum(response.head.status);

    // Extract content-type before reader invalidates strings
    const content_type: ?[]u8 = if (response.head.content_type) |ct|
        allocator.dupe(u8, ct) catch null
    else
        null;
    errdefer if (content_type) |ct| allocator.free(ct);

    // Read response body up to max_body_size to prevent OOM on large responses
    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(allocator, std.io.Limit.limited(options.max_body_size)) catch
        (allocator.dupe(u8, "") catch return error.ConnectionFailed);

    return Response{
        .status = status,
        .body = body,
        .allocator = allocator,
        .content_type = content_type,
    };
}

/// Check if a URL is reachable by sending a GET request.
/// Returns the HTTP status code, or error if connection fails.
pub fn checkStatus(allocator: std.mem.Allocator, url_str: []const u8, options: FetchOptions) !u16 {
    _ = options;

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url_str },
    }) catch return error.ConnectionFailed;

    return @intFromEnum(result.status);
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
