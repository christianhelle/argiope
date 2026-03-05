const std = @import("std");
const cli_mod = @import("cli.zig");
const crawler_mod = @import("crawler.zig");
const summary_mod = @import("summary.zig");

/// Escape HTML special characters in a string.
/// Caller owns the returned memory.
fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    for (text) |char| {
        switch (char) {
            '&' => try list.appendSlice(allocator, "&amp;"),
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\'' => try list.appendSlice(allocator, "&#39;"),
            else => try list.append(allocator, char),
        }
    }

    return list.toOwnedSlice(allocator);
}

pub fn write(
    allocator: std.mem.Allocator,
    path: []const u8,
    format: cli_mod.ReportFormat,
    url: []const u8,
    results: []const crawler_mod.CrawlResult,
    summary: summary_mod.CheckSummary,
    include_positives: bool,
) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [65536]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    switch (format) {
        .text => try writeText(w, url, results, summary, include_positives),
        .markdown => try writeMarkdown(w, url, results, summary, include_positives),
        .html => try writeHtml(allocator, w, url, results, summary, include_positives),
    }

    try w.flush();
}

fn writeText(
    w: anytype,
    url: []const u8,
    results: []const crawler_mod.CrawlResult,
    summary: summary_mod.CheckSummary,
    include_positives: bool,
) !void {
    try w.print("Link Check Report\n", .{});
    try w.print("URL: {s}\n\n", .{url});

    const has_broken = summary.broken_count > 0 or summary.error_count > 0;

    if (has_broken) {
        try w.print("BROKEN LINKS ({d})\n\n", .{summary.broken_count + summary.error_count});
        for (results) |r| {
            const is_broken = r.error_msg != null or r.status >= 400;
            if (!is_broken) continue;
            const type_str: []const u8 = if (r.is_internal) "internal" else "external";
            if (r.error_msg) |msg| {
                try w.print("  [{s}] {s}\n", .{ msg, r.url });
            } else {
                try w.print("  [{d}] {s}\n", .{ r.status, r.url });
            }
            try w.print("        {s}  •  {d}ms\n\n", .{ type_str, r.elapsed_ms });
        }
    } else {
        try w.print("BROKEN LINKS\n\n  None found.\n\n", .{});
    }

    if (include_positives) {
        try w.print("OK LINKS ({d})\n\n", .{summary.ok_count});
        for (results) |r| {
            const is_broken = r.error_msg != null or r.status >= 400;
            if (is_broken) continue;
            const type_str: []const u8 = if (r.is_internal) "internal" else "external";
            try w.print("  [{d}] {s}\n", .{ r.status, r.url });
            try w.print("        {s}  •  {d}ms\n\n", .{ type_str, r.elapsed_ms });
        }
    }

    const avg = if (summary.total_urls > 0) summary.total_time_ms / @as(u64, summary.total_urls) else 0;
    const min = if (summary.min_time_ms == std.math.maxInt(u64)) 0 else summary.min_time_ms;

    try w.print("SUMMARY\n\n", .{});
    try w.print("  Checked:   {d}\n", .{summary.total_urls});
    try w.print("  OK:        {d}\n", .{summary.ok_count});
    try w.print("  Broken:    {d}\n", .{summary.broken_count});
    try w.print("  Errors:    {d}\n", .{summary.error_count});
    try w.print("  Internal:  {d}\n", .{summary.internal_count});
    try w.print("  External:  {d}\n\n", .{summary.external_count});
    try w.print("  Total response time:  {d}ms\n", .{summary.total_time_ms});
    try w.print("  Avg:         {d}ms\n", .{avg});
    try w.print("  Min:         {d}ms\n", .{min});
    try w.print("  Max:         {d}ms\n", .{summary.max_time_ms});
}

fn writeMarkdown(
    w: anytype,
    url: []const u8,
    results: []const crawler_mod.CrawlResult,
    summary: summary_mod.CheckSummary,
    include_positives: bool,
) !void {
    try w.print("# Link Check Report\n\n", .{});
    try w.print("**URL:** {s}\n\n", .{url});

    const has_broken = summary.broken_count > 0 or summary.error_count > 0;

    if (has_broken) {
        try w.print("## Broken Links ({d})\n\n", .{summary.broken_count + summary.error_count});
        for (results) |r| {
            const is_broken = r.error_msg != null or r.status >= 400;
            if (!is_broken) continue;
            const type_str: []const u8 = if (r.is_internal) "internal" else "external";
            if (r.error_msg) |msg| {
                try w.print("- **[{s}]** {s}\n  `{s}` · {d}ms\n\n", .{ msg, r.url, type_str, r.elapsed_ms });
            } else {
                try w.print("- **[{d}]** {s}\n  `{s}` · {d}ms\n\n", .{ r.status, r.url, type_str, r.elapsed_ms });
            }
        }
    } else {
        try w.print("## Broken Links\n\nNone found.\n\n", .{});
    }

    if (include_positives) {
        try w.print("## OK Links ({d})\n\n", .{summary.ok_count});
        for (results) |r| {
            const is_broken = r.error_msg != null or r.status >= 400;
            if (is_broken) continue;
            const type_str: []const u8 = if (r.is_internal) "internal" else "external";
            try w.print("- **[{d}]** {s}\n  `{s}` · {d}ms\n\n", .{ r.status, r.url, type_str, r.elapsed_ms });
        }
    }

    const avg = if (summary.total_urls > 0) summary.total_time_ms / @as(u64, summary.total_urls) else 0;
    const min = if (summary.min_time_ms == std.math.maxInt(u64)) 0 else summary.min_time_ms;

    try w.print("## Summary\n\n", .{});
    try w.print("- Checked: {d}\n", .{summary.total_urls});
    try w.print("- OK: {d}\n", .{summary.ok_count});
    try w.print("- Broken: {d}\n", .{summary.broken_count});
    try w.print("- Errors: {d}\n", .{summary.error_count});
    try w.print("- Internal: {d}\n", .{summary.internal_count});
    try w.print("- External: {d}\n\n", .{summary.external_count});
    try w.print("## Timing\n\n", .{});
    try w.print("- Total response time: {d}ms\n", .{summary.total_time_ms});
    try w.print("- Avg: {d}ms\n", .{avg});
    try w.print("- Min: {d}ms\n", .{min});
    try w.print("- Max: {d}ms\n", .{summary.max_time_ms});
}

fn writeHtml(
    allocator: std.mem.Allocator,
    w: anytype,
    url: []const u8,
    results: []const crawler_mod.CrawlResult,
    summary: summary_mod.CheckSummary,
    include_positives: bool,
) !void {
    const escaped_url = try escapeHtml(allocator, url);
    defer allocator.free(escaped_url);

    try w.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>Link Check Report</title>
        \\<style>
        \\  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        \\  body {{ font-family: system-ui, sans-serif; background: #f6f8fa; color: #1a1a1a; padding: 40px 20px; }}
        \\  .container {{ max-width: 860px; margin: 0 auto; }}
        \\  h1 {{ font-size: 1.6rem; font-weight: 700; margin-bottom: 4px; }}
        \\  .subtitle {{ color: #666; font-size: 0.9rem; margin-bottom: 32px; word-break: break-all; }}
        \\  h2 {{ font-size: 1.1rem; font-weight: 600; margin: 32px 0 12px; color: #333; }}
        \\  .link-list {{ display: flex; flex-direction: column; gap: 10px; }}
        \\  .link-item {{ background: #fff; border: 1px solid #e1e4e8; border-radius: 6px; padding: 12px 16px; }}
        \\  .link-item.broken {{ border-left: 4px solid #d73a49; }}
        \\  .link-item.ok {{ border-left: 4px solid #28a745; }}
        \\  .link-url {{ font-size: 0.9rem; word-break: break-all; margin-bottom: 6px; }}
        \\  .link-meta {{ display: flex; gap: 10px; flex-wrap: wrap; }}
        \\  .badge {{ font-size: 0.75rem; padding: 2px 8px; border-radius: 12px; font-weight: 600; }}
        \\  .badge-status-broken {{ background: #ffeef0; color: #d73a49; }}
        \\  .badge-status-ok {{ background: #e6ffed; color: #28a745; }}
        \\  .badge-type {{ background: #f1f8ff; color: #0366d6; }}
        \\  .badge-time {{ background: #f6f8fa; color: #666; }}
        \\  .none-found {{ color: #28a745; font-style: italic; font-size: 0.9rem; }}
        \\  .stats {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; margin-top: 8px; }}
        \\  .stat {{ background: #fff; border: 1px solid #e1e4e8; border-radius: 6px; padding: 12px 16px; }}
        \\  .stat-label {{ font-size: 0.75rem; color: #666; text-transform: uppercase; letter-spacing: 0.04em; }}
        \\  .stat-value {{ font-size: 1.4rem; font-weight: 700; margin-top: 4px; }}
        \\  .stat-value.ok {{ color: #28a745; }}
        \\  .stat-value.broken {{ color: #d73a49; }}
        \\</style>
        \\</head>
        \\<body>
        \\<div class="container">
        \\<h1>Link Check Report</h1>
        \\<p class="subtitle">{s}</p>
        \\
    , .{escaped_url});

    const has_broken = summary.broken_count > 0 or summary.error_count > 0;

    try w.print("<h2>Broken Links</h2>\n", .{});
    if (has_broken) {
        try w.print("<div class=\"link-list\">\n", .{});
        for (results) |r| {
            const is_broken = r.error_msg != null or r.status >= 400;
            if (!is_broken) continue;
            const type_str: []const u8 = if (r.is_internal) "internal" else "external";
            const escaped_r_url = try escapeHtml(allocator, r.url);
            defer allocator.free(escaped_r_url);
            try w.print("<div class=\"link-item broken\">\n", .{});
            try w.print("  <div class=\"link-url\">{s}</div>\n", .{escaped_r_url});
            try w.print("  <div class=\"link-meta\">\n", .{});
            if (r.error_msg) |msg| {
                const escaped_msg = try escapeHtml(allocator, msg);
                defer allocator.free(escaped_msg);
                try w.print("    <span class=\"badge badge-status-broken\">{s}</span>\n", .{escaped_msg});
            } else {
                try w.print("    <span class=\"badge badge-status-broken\">{d}</span>\n", .{r.status});
            }
            try w.print("    <span class=\"badge badge-type\">{s}</span>\n", .{type_str});
            try w.print("    <span class=\"badge badge-time\">{d}ms</span>\n", .{r.elapsed_ms});
            try w.print("  </div>\n</div>\n", .{});
        }
        try w.print("</div>\n", .{});
    } else {
        try w.print("<p class=\"none-found\">None found.</p>\n", .{});
    }

    if (include_positives) {
        try w.print("<h2>OK Links</h2>\n<div class=\"link-list\">\n", .{});
        for (results) |r| {
            const is_broken = r.error_msg != null or r.status >= 400;
            if (is_broken) continue;
            const type_str: []const u8 = if (r.is_internal) "internal" else "external";
            const escaped_r_url = try escapeHtml(allocator, r.url);
            defer allocator.free(escaped_r_url);
            try w.print("<div class=\"link-item ok\">\n", .{});
            try w.print("  <div class=\"link-url\">{s}</div>\n", .{escaped_r_url});
            try w.print("  <div class=\"link-meta\">\n", .{});
            try w.print("    <span class=\"badge badge-status-ok\">{d}</span>\n", .{r.status});
            try w.print("    <span class=\"badge badge-type\">{s}</span>\n", .{type_str});
            try w.print("    <span class=\"badge badge-time\">{d}ms</span>\n", .{r.elapsed_ms});
            try w.print("  </div>\n</div>\n", .{});
        }
        try w.print("</div>\n", .{});
    }

    const avg = if (summary.total_urls > 0) summary.total_time_ms / @as(u64, summary.total_urls) else 0;
    const min = if (summary.min_time_ms == std.math.maxInt(u64)) 0 else summary.min_time_ms;

    try w.print(
        \\<h2>Summary</h2>
        \\<div class="stats">
        \\  <div class="stat"><div class="stat-label">Checked</div><div class="stat-value">{d}</div></div>
        \\  <div class="stat"><div class="stat-label">OK</div><div class="stat-value ok">{d}</div></div>
        \\  <div class="stat"><div class="stat-label">Broken</div><div class="stat-value broken">{d}</div></div>
        \\  <div class="stat"><div class="stat-label">Errors</div><div class="stat-value broken">{d}</div></div>
        \\  <div class="stat"><div class="stat-label">Internal</div><div class="stat-value">{d}</div></div>
        \\  <div class="stat"><div class="stat-label">External</div><div class="stat-value">{d}</div></div>
        \\</div>
        \\<h2>Timing</h2>
        \\<div class="stats">
        \\  <div class="stat"><div class="stat-label">Total response time</div><div class="stat-value">{d}ms</div></div>
        \\  <div class="stat"><div class="stat-label">Avg</div><div class="stat-value">{d}ms</div></div>
        \\  <div class="stat"><div class="stat-label">Min</div><div class="stat-value">{d}ms</div></div>
        \\  <div class="stat"><div class="stat-label">Max</div><div class="stat-value">{d}ms</div></div>
        \\</div>
        \\</div>
        \\</body>
        \\</html>
    , .{
        summary.total_urls,
        summary.ok_count,
        summary.broken_count,
        summary.error_count,
        summary.internal_count,
        summary.external_count,
        summary.total_time_ms,
        avg,
        min,
        summary.max_time_ms,
    });
}

// ── Tests ──────────────────────────────────────────────────────────────

test "write text report to temp file" {
    const allocator = std.testing.allocator;
    const tmp_path = "test_report_text.tmp";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const results = [_]crawler_mod.CrawlResult{
        .{ .url = @constCast("https://example.com"), .status = 200, .links_found = 1, .is_internal = true, .error_msg = null, .elapsed_ms = 50 },
        .{ .url = @constCast("https://example.com/broken"), .status = 404, .links_found = 0, .is_internal = true, .error_msg = null, .elapsed_ms = 30 },
    };
    const summary = summary_mod.CheckSummary{
        .total_urls = 2,
        .ok_count = 1,
        .broken_count = 1,
        .error_count = 0,
        .internal_count = 2,
        .external_count = 0,
        .total_time_ms = 80,
        .min_time_ms = 30,
        .max_time_ms = 50,
    };

    try write(allocator, tmp_path, .text, "https://example.com", &results, summary, false);

    const content = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 65536);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "BROKEN LINKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "https://example.com/broken") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "SUMMARY") != null);
}

test "write markdown report to temp file" {
    const allocator = std.testing.allocator;
    const tmp_path = "test_report_md.tmp";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const results = [_]crawler_mod.CrawlResult{
        .{ .url = @constCast("https://example.com/404"), .status = 404, .links_found = 0, .is_internal = false, .error_msg = null, .elapsed_ms = 20 },
    };
    const summary = summary_mod.CheckSummary{
        .total_urls = 1,
        .ok_count = 0,
        .broken_count = 1,
        .error_count = 0,
        .internal_count = 0,
        .external_count = 1,
        .total_time_ms = 20,
        .min_time_ms = 20,
        .max_time_ms = 20,
    };

    try write(allocator, tmp_path, .markdown, "https://example.com", &results, summary, false);

    const content = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 65536);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "# Link Check Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[404]") != null);
}

test "write html report to temp file" {
    const allocator = std.testing.allocator;
    const tmp_path = "test_report_html.tmp";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const results = [_]crawler_mod.CrawlResult{
        .{ .url = @constCast("https://example.com/ok"), .status = 200, .links_found = 0, .is_internal = true, .error_msg = null, .elapsed_ms = 10 },
    };
    const summary = summary_mod.CheckSummary{
        .total_urls = 1,
        .ok_count = 1,
        .broken_count = 0,
        .error_count = 0,
        .internal_count = 1,
        .external_count = 0,
        .total_time_ms = 10,
        .min_time_ms = 10,
        .max_time_ms = 10,
    };

    try write(allocator, tmp_path, .html, "https://example.com", &results, summary, true);

    const content = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 65536);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "https://example.com/ok") != null);
}

test "include-positives includes ok links in text report" {
    const allocator = std.testing.allocator;
    const tmp_path = "test_report_positives.tmp";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const results = [_]crawler_mod.CrawlResult{
        .{ .url = @constCast("https://example.com/ok"), .status = 200, .links_found = 0, .is_internal = true, .error_msg = null, .elapsed_ms = 10 },
    };
    const summary = summary_mod.CheckSummary{
        .total_urls = 1,
        .ok_count = 1,
        .broken_count = 0,
        .error_count = 0,
        .internal_count = 1,
        .external_count = 0,
        .total_time_ms = 10,
        .min_time_ms = 10,
        .max_time_ms = 10,
    };

    try write(allocator, tmp_path, .text, "https://example.com", &results, summary, true);

    const content = try std.fs.cwd().readFileAlloc(allocator, tmp_path, 65536);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "OK LINKS") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "https://example.com/ok") != null);
}
