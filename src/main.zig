const std = @import("std");
const cli = @import("cli.zig");

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
            cli.ParseError.UnknownCommand => "unknown command (use 'check' or 'download')",
        };
        cli.printError(msg);
        try cli.printHelp();
        std.process.exit(1);
    };

    switch (opts.command) {
        .help => try cli.printHelp(),
        .version_cmd => try cli.printVersion(),
        .check => {
            const url = opts.url orelse {
                cli.printError("missing URL argument for 'check' command");
                try cli.printHelp();
                std.process.exit(1);
            };
            _ = url;
            // TODO: implement link checker
            cli.printError("'check' command not yet implemented");
            std.process.exit(1);
        },
        .download => {
            const url = opts.url orelse {
                cli.printError("missing URL argument for 'download' command");
                try cli.printHelp();
                std.process.exit(1);
            };
            _ = url;
            // TODO: implement downloader
            cli.printError("'download' command not yet implemented");
            std.process.exit(1);
        },
    }
}

test "imports compile" {
    _ = @import("url.zig");
    _ = @import("http.zig");
    _ = @import("html.zig");
    _ = @import("cli.zig");
}
