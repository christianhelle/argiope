const std = @import("std");

pub const version = "0.1.0";

pub const Command = enum {
    check,
    download,
    help,
    version_cmd,
};

pub const Options = struct {
    command: Command,
    url: ?[]const u8,
    depth: u16,
    timeout_ms: u32,
    delay_ms: u32,
    output_dir: []const u8,
    verbose: bool,
    parallel: bool,

    pub const defaults = Options{
        .command = .help,
        .url = null,
        .depth = 3,
        .timeout_ms = 10_000,
        .delay_ms = 100,
        .output_dir = "./download",
        .verbose = false,
        .parallel = false,
    };
};

pub const ParseError = error{
    MissingUrl,
    InvalidNumber,
    UnknownOption,
    UnknownCommand,
};

/// Parse command-line arguments into Options.
/// The returned Options borrows slices from `args`.
pub fn parseArgs(args: []const []const u8) ParseError!Options {
    if (args.len < 2) return Options.defaults;

    var opts = Options.defaults;
    const cmd_str = args[1];

    if (std.mem.eql(u8, cmd_str, "-h") or std.mem.eql(u8, cmd_str, "--help")) {
        opts.command = .help;
        return opts;
    }
    if (std.mem.eql(u8, cmd_str, "-v") or std.mem.eql(u8, cmd_str, "--version")) {
        opts.command = .version_cmd;
        return opts;
    }

    if (std.mem.eql(u8, cmd_str, "check")) {
        opts.command = .check;
    } else if (std.mem.eql(u8, cmd_str, "download")) {
        opts.command = .download;
    } else {
        return ParseError.UnknownCommand;
    }

    // Parse remaining args
    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.command = .help;
            return opts;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            opts.command = .version_cmd;
            return opts;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= args.len) return ParseError.InvalidNumber;
            opts.depth = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return ParseError.InvalidNumber;
            const secs = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.InvalidNumber;
            opts.timeout_ms = secs * 1000;
        } else if (std.mem.eql(u8, arg, "--delay")) {
            i += 1;
            if (i >= args.len) return ParseError.InvalidNumber;
            opts.delay_ms = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.InvalidNumber;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--parallel")) {
            opts.parallel = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return ParseError.UnknownOption;
            opts.output_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnknownOption;
        } else {
            // Positional argument = URL
            opts.url = arg;
        }

        i += 1;
    }

    return opts;
}

pub fn printHelp() !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    try fw.interface.print(
        \\zigcrawler {s} — a web crawler for broken-link detection and image downloading
        \\
        \\Usage: zigcrawler <command> <url> [options]
        \\
        \\Commands:
        \\  check <url>           Crawl a website and report broken links
        \\  download <url>        Download images from a website
        \\
        \\Options:
        \\  --depth N             Maximum crawl depth (default: 3)
        \\  --timeout N           Request timeout in seconds (default: 10)
        \\  --delay N             Delay between requests in ms (default: 100)
        \\  -o, --output DIR      Output directory for downloads (default: ./download)
        \\  --verbose             Print progress for each URL as it is crawled
        \\  --parallel            Crawl URLs in parallel for better performance
        \\  -h, --help            Show this help
        \\  -v, --version         Show version
        \\
        \\Examples:
        \\  zigcrawler check https://example.com
        \\  zigcrawler check https://example.com --depth 5 --timeout 15
        \\  zigcrawler download https://example.com/gallery -o ./images
        \\
    , .{version});
    try fw.interface.flush();
}

pub fn printVersion() !void {
    var buf: [256]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    try fw.interface.print("zigcrawler {s}\n", .{version});
    try fw.interface.flush();
}

pub fn printError(msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stderr().writer(&buf);
    fw.interface.print("error: {s}\n", .{msg}) catch {};
    fw.interface.flush() catch {};
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parse help flag" {
    const args = &[_][]const u8{ "zigcrawler", "--help" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.command == .help);
}

test "parse version flag" {
    const args = &[_][]const u8{ "zigcrawler", "-v" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.command == .version_cmd);
}

test "parse check command" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.command == .check);
    try std.testing.expectEqualStrings("https://example.com", opts.url.?);
}

test "parse download command" {
    const args = &[_][]const u8{ "zigcrawler", "download", "https://example.com", "-o", "./out" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.command == .download);
    try std.testing.expectEqualStrings("https://example.com", opts.url.?);
    try std.testing.expectEqualStrings("./out", opts.output_dir);
}

test "parse depth option" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--depth", "5" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.depth == 5);
}

test "parse timeout option" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--timeout", "30" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.timeout_ms == 30_000);
}

test "parse delay option" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--delay", "500" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.delay_ms == 500);
}

test "no args shows help" {
    const args = &[_][]const u8{"zigcrawler"};
    const opts = try parseArgs(args);
    try std.testing.expect(opts.command == .help);
}

test "unknown command returns error" {
    const args = &[_][]const u8{ "zigcrawler", "invalid" };
    try std.testing.expectError(ParseError.UnknownCommand, parseArgs(args));
}

test "unknown option returns error" {
    const args = &[_][]const u8{ "zigcrawler", "check", "--invalid" };
    try std.testing.expectError(ParseError.UnknownOption, parseArgs(args));
}

test "defaults are correct" {
    const d = Options.defaults;
    try std.testing.expect(d.depth == 3);
    try std.testing.expect(d.timeout_ms == 10_000);
    try std.testing.expect(d.delay_ms == 100);
    try std.testing.expectEqualStrings("./download", d.output_dir);
    try std.testing.expect(d.verbose == false);
}

test "parse verbose flag" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--verbose" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.verbose == true);
    try std.testing.expect(opts.command == .check);
}

test "parse parallel flag" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--parallel" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.parallel == true);
    try std.testing.expect(opts.command == .check);
}

test "parallel defaults to false" {
    const d = Options.defaults;
    try std.testing.expect(d.parallel == false);
}

test "help flag after command" {
    const args = &[_][]const u8{ "zigcrawler", "check", "--help" };
    const opts = try parseArgs(args);
    try std.testing.expect(opts.command == .help);
}

test "missing depth value" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--depth" };
    try std.testing.expectError(ParseError.InvalidNumber, parseArgs(args));
}

test "invalid depth value" {
    const args = &[_][]const u8{ "zigcrawler", "check", "https://example.com", "--depth", "abc" };
    try std.testing.expectError(ParseError.InvalidNumber, parseArgs(args));
}
