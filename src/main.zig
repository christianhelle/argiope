const std = @import("std");
const cli = @import("cli.zig");
const link_checker = @import("link_checker.zig");
const downloader = @import("downloader.zig");
const image_browser = @import("image_browser.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const opts = cli.parseArgs(args) catch |err| {
        const msg = switch (err) {
            cli.ParseError.MissingUrl => "missing URL argument",
            cli.ParseError.InvalidNumber => "invalid numeric argument",
            cli.ParseError.UnknownOption => "unknown option",
            cli.ParseError.UnknownCommand => "unknown command (use 'check' or 'images')",
            cli.ParseError.MissingValue => "missing value for option",
            cli.ParseError.InvalidValue => "invalid value for --report-format (use: text, markdown, html)",
        };
        cli.printError(io, msg);
        try cli.printHelp(io);
        std.process.exit(1);
    };

    switch (opts.command) {
        .help => try cli.printHelp(io),
        .version_cmd => try cli.printVersion(io),
        .check => {
            if (opts.url == null) {
                cli.printError(io, "missing URL argument for 'check' command");
                try cli.printHelp(io);
                std.process.exit(1);
            }
            const exit_code = try link_checker.run(io, allocator, opts);
            if (exit_code != 0) std.process.exit(exit_code);
        },
        .images => {
            if (opts.url == null) {
                cli.printError(io, "missing URL argument for 'images' command");
                try cli.printHelp(io);
                std.process.exit(1);
            }
            const exit_code = try downloader.run(io, allocator, opts);
            if (exit_code != 0) std.process.exit(exit_code);
        },
        .library => {
            const dir = if (opts.url) |u| u else opts.output_dir;
            const exit_code = try image_browser.run(io, allocator, dir);
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
    _ = @import("image_browser.zig");
}
