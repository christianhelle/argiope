const std = @import("std");
const crawler_mod = @import("crawler.zig");
const cli_mod = @import("cli.zig");
const report_mod = @import("report.zig");

pub const CheckSummary = struct {
    total_urls: usize,
    ok_count: usize,
    broken_count: usize,
    error_count: usize,
    internal_count: usize,
    external_count: usize,
    total_time_ms: u64,
    min_time_ms: u64,
    max_time_ms: u64,
};

/// Run the link checker: crawl the site and report broken links.
pub fn run(allocator: std.mem.Allocator, opts: cli_mod.Options) !u8 {
    const url = opts.url orelse return 1;

    const silent = opts.report != null;

    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;

    if (!silent) {
        try w.print("Crawling {s} (depth={d}, timeout={d}s)...\n\n", .{
            url,
            opts.depth,
            opts.timeout_ms / 1000,
        });
        try w.flush();
    }

    const crawl_start = std.time.milliTimestamp();

    var c = crawler_mod.Crawler.init(allocator, url, .{
        .max_depth = opts.depth,
        .timeout_ms = opts.timeout_ms,
        .delay_ms = opts.delay_ms,
        .verbose = opts.verbose and !silent,
        .parallel = opts.parallel,
    });
    defer c.deinit();

    try c.crawl();

    const crawl_elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - crawl_start);

    // Collect results and build summary
    const results = c.results.items;
    var summary = CheckSummary{
        .total_urls = results.len,
        .ok_count = 0,
        .broken_count = 0,
        .error_count = 0,
        .internal_count = 0,
        .external_count = 0,
        .total_time_ms = 0,
        .min_time_ms = std.math.maxInt(u64),
        .max_time_ms = 0,
    };

    // Collect broken links for display
    var broken: std.ArrayListUnmanaged(usize) = .empty;
    defer broken.deinit(allocator);

    for (results, 0..) |r, i| {
        if (r.is_internal) {
            summary.internal_count += 1;
        } else {
            summary.external_count += 1;
        }

        summary.total_time_ms += r.elapsed_ms;
        if (r.elapsed_ms < summary.min_time_ms) summary.min_time_ms = r.elapsed_ms;
        if (r.elapsed_ms > summary.max_time_ms) summary.max_time_ms = r.elapsed_ms;

        if (r.error_msg != null) {
            summary.error_count += 1;
            try broken.append(allocator, i);
        } else if (r.status >= 400) {
            summary.broken_count += 1;
            try broken.append(allocator, i);
        } else {
            summary.ok_count += 1;
        }
    }

    if (!silent) {
        // Print broken links table
        if (broken.items.len > 0) {
            try w.print("{s}\n", .{"-" ** 88});
            try w.print("{s:<8} {s:<10} {s:<10} {s}\n", .{ "Status", "Type", "Time(ms)", "URL" });
            try w.print("{s}\n", .{"-" ** 88});
            try w.flush();

            for (broken.items) |idx| {
                const r = results[idx];
                const type_str: []const u8 = if (r.is_internal) "internal" else "external";
                if (r.error_msg) |msg| {
                    try w.print("{s:<8} {s:<10} {d:<10} {s}\n", .{ msg, type_str, r.elapsed_ms, r.url });
                } else {
                    try w.print("{d:<8} {s:<10} {d:<10} {s}\n", .{ r.status, type_str, r.elapsed_ms, r.url });
                }
                try w.flush();
            }

            try w.print("{s}\n", .{"-" ** 88});
            try w.flush();
        }

        // Print summary
        const avg_time_ms = if (results.len > 0) summary.total_time_ms / results.len else 0;
        const min_time = if (summary.min_time_ms == std.math.maxInt(u64)) 0 else summary.min_time_ms;
        try w.print("\nSummary:\n", .{});
        try w.print("  Total URLs checked: {d}\n", .{summary.total_urls});
        try w.print("  OK:                 {d}\n", .{summary.ok_count});
        try w.print("  Broken:             {d}\n", .{summary.broken_count});
        try w.print("  Errors:             {d}\n", .{summary.error_count});
        try w.print("  Internal:           {d}\n", .{summary.internal_count});
        try w.print("  External:           {d}\n", .{summary.external_count});
        try w.print("\nTiming:\n", .{});
        try w.print("  Total crawl time:   {d}ms\n", .{crawl_elapsed_ms});
        try w.print("  Avg response time:  {d}ms\n", .{avg_time_ms});
        try w.print("  Min response time:  {d}ms\n", .{min_time});
        try w.print("  Max response time:  {d}ms\n", .{summary.max_time_ms});
        try w.flush();
    }

    // Write report file if requested
    var report_write_failed = false;
    if (opts.report) |report_path| {
        report_mod.write(
            allocator,
            report_path,
            opts.report_format,
            url,
            results,
            summary,
            opts.include_positives,
        ) catch |err| {
            var ebuf: [256]u8 = undefined;
            var efw = std.fs.File.stderr().writer(&ebuf);
            efw.interface.print("error: failed to write report to '{s}': {}\n", .{ report_path, err }) catch {};
            efw.interface.flush() catch {};
            report_write_failed = true;
        };
    }

    // Return non-zero exit code if broken links found or report write failed
    return if (summary.broken_count > 0 or summary.error_count > 0 or report_write_failed) 1 else 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "CheckSummary defaults" {
    const s = CheckSummary{
        .total_urls = 10,
        .ok_count = 8,
        .broken_count = 1,
        .error_count = 1,
        .internal_count = 7,
        .external_count = 3,
        .total_time_ms = 500,
        .min_time_ms = 20,
        .max_time_ms = 150,
    };
    try std.testing.expect(s.total_urls == 10);
    try std.testing.expect(s.ok_count == 8);
    try std.testing.expect(s.broken_count == 1);
    try std.testing.expect(s.error_count == 1);
    try std.testing.expect(s.total_time_ms == 500);
    try std.testing.expect(s.min_time_ms == 20);
    try std.testing.expect(s.max_time_ms == 150);
}
