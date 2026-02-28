const std = @import("std");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        try printUsage();
    } else if (std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) {
        try printVersion();
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    try fw.interface.print(
        \\zigcrawler {s} — a web crawler for broken-link detection and image downloading
        \\
        \\Usage: zigcrawler <command> [options]
        \\
        \\Commands:
        \\  check <url>       Crawl a website and report broken links
        \\  download <url>    Download images from a website
        \\
        \\Options:
        \\  -h, --help        Show this help
        \\  -v, --version     Show version
        \\
    , .{version});
    try fw.interface.flush();
}

fn printVersion() !void {
    var buf: [256]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    try fw.interface.print("zigcrawler {s}\n", .{version});
    try fw.interface.flush();
}

test "imports compile" {
    _ = @import("url.zig");
    _ = @import("http.zig");
}
