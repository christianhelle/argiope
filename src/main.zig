const std = @import("std");
const cli = @import("cli.zig");
const link_checker = @import("link_checker.zig");
const downloader = @import("downloader.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = cli.parseArgs(args) catch |err| {
        const msg = switch (err) {
            cli.ParseError.MissingUrl => "missing URL argument",
            cli.ParseError.InvalidNumber => "invalid numeric argument",
            cli.ParseError.UnknownOption => "unknown option",
            cli.ParseError.UnknownCommand => "unknown command (use 'check' or 'images')",
        };
        cli.printError(msg);
        try cli.printHelp();
        std.process.exit(1);
    };

    switch (opts.command) {
        .help => try cli.printHelp(),
        .version_cmd => try cli.printVersion(),
        .check => {
            if (opts.url == null) {
                cli.printError("missing URL argument for 'check' command");
                try cli.printHelp();
                std.process.exit(1);
            }
            const exit_code = try link_checker.run(allocator, opts);
            if (exit_code != 0) std.process.exit(exit_code);
        },
        .images => {
            if (opts.url == null) {
                cli.printError("missing URL argument for 'images' command");
                try cli.printHelp();
                std.process.exit(1);
            }
            const exit_code = try downloader.run(allocator, opts);
            if (exit_code != 0) std.process.exit(exit_code);
        },
    }
}

test "imports compile" {
    _ = @import("url.zig");
    _ = @import("http.zig");
    _ = @import("html.zig");
    _ = @import("cli.zig");
    _ = @import("crawler.zig");
    _ = @import("link_checker.zig");
    _ = @import("downloader.zig");
    _ = @import("mangafox.zig");
    _ = @import("report.zig");
    _ = @import("summary.zig");
}
