//! Build helper used by the `install-*` steps in build.zig.
//!
//! Usage: install_release <source> <prefix> <default-prefix> <dest-name>
//!
//! Copies <source> to <prefix> when `--prefix` was given; otherwise to
//! $INSTALL_DIR, falling back to $HOME/.local/bin or %USERPROFILE%\.local\bin.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: install_release <source> <prefix> <default-prefix> <dest-name>\n", .{});
        std.process.exit(2);
    }
    const source = args[1];
    const prefix = args[2];
    const default_prefix = args[3];
    const dest_name = args[4];

    const dest_dir = if (!std.mem.eql(u8, prefix, default_prefix))
        prefix
    else
        try defaultInstallDir(arena, init.environ_map);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest_dir);
    const dest_path = try std.Io.Dir.path.join(arena, &.{ dest_dir, dest_name });
    try std.Io.Dir.copyFile(cwd, source, cwd, dest_path, io, .{});

    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.print("Installed {s}\n", .{dest_path});
    try out.interface.flush();
}

fn defaultInstallDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("INSTALL_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    for ([_][]const u8{ "HOME", "USERPROFILE" }) |key| {
        if (env.get(key)) |home| {
            if (home.len > 0) return std.Io.Dir.path.join(arena, &.{ home, ".local", "bin" });
        }
    }
    std.debug.print("unable to determine install directory: set HOME, USERPROFILE, or INSTALL_DIR\n", .{});
    std.process.exit(1);
}
