const std = @import("std");
const cli_mod = @import("cli.zig");

pub fn run(allocator: std.mem.Allocator, output_dir: []const u8) !u8 {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;

    const summary = generate(allocator, output_dir) catch |err| {
        cli_mod.printError("Failed to generate library");
        if (err == error.FileNotFound) {
            cli_mod.printError("Directory not found");
        }
        return 1;
    };

    try w.print("HTML browser generated:\n", .{});
    try w.print("  Landing page:     {s}/{s}\n", .{ output_dir, root_page_name });
    try w.print("  Folder pages:     {d}\n", .{summary.directories});
    try w.print("  Reader pages:     {d}\n", .{summary.reader_pages});
    try w.print("  Indexed images:   {d}\n", .{summary.images});
    try w.flush();

    return 0;
}

pub const root_page_name = "library.html";

pub const Summary = struct {
    directories: usize,
    reader_pages: usize,
    images: usize,
};

const ImageEntry = struct {
    name: []const u8,
    rel_path: []const u8,
};

const DirNode = struct {
    name: []const u8,
    rel_path: []const u8,
    parent: ?usize,
    subdirs: std.ArrayListUnmanaged(usize) = .empty,
    images: std.ArrayListUnmanaged(ImageEntry) = .empty,
    total_images: usize = 0,

    fn deinit(self: *DirNode, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
        for (self.images.items) |image| {
            allocator.free(image.name);
            allocator.free(image.rel_path);
        }
        self.images.deinit(allocator);
        self.subdirs.deinit(allocator);
    }
};

const SiteTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(DirNode) = .empty,
    path_map: std.StringHashMapUnmanaged(usize) = .empty,

    fn init(allocator: std.mem.Allocator) !SiteTree {
        var tree = SiteTree{ .allocator = allocator };
        const root_name = try allocator.dupe(u8, "");
        errdefer allocator.free(root_name);
        const root_path = try allocator.dupe(u8, "");
        errdefer allocator.free(root_path);

        try tree.nodes.append(allocator, .{
            .name = root_name,
            .rel_path = root_path,
            .parent = null,
        });
        try tree.path_map.put(allocator, root_path, 0);
        return tree;
    }

    fn deinit(self: *SiteTree) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.path_map.deinit(self.allocator);
    }

    fn getOrAddDir(self: *SiteTree, rel_path: []const u8) !usize {
        if (self.path_map.get(rel_path)) |index| return index;

        const name_slice = if (rel_path.len == 0) "" else std.fs.path.basename(rel_path);
        const parent_rel = std.fs.path.dirname(rel_path) orelse "";
        const parent_index = try self.getOrAddDir(parent_rel);

        const name = try self.allocator.dupe(u8, name_slice);
        errdefer self.allocator.free(name);
        const rel_copy = try self.allocator.dupe(u8, rel_path);
        errdefer self.allocator.free(rel_copy);

        const index = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .name = name,
            .rel_path = rel_copy,
            .parent = parent_index,
        });
        try self.path_map.put(self.allocator, rel_copy, index);
        try self.nodes.items[parent_index].subdirs.append(self.allocator, index);
        return index;
    }

    fn addImage(self: *SiteTree, rel_path: []const u8) !void {
        const parent_rel = std.fs.path.dirname(rel_path) orelse "";
        const parent_index = try self.getOrAddDir(parent_rel);
        const image_name = std.fs.path.basename(rel_path);

        try self.nodes.items[parent_index].images.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, image_name),
            .rel_path = try self.allocator.dupe(u8, rel_path),
        });
    }

    fn sortAndCount(self: *SiteTree) void {
        for (self.nodes.items) |*node| {
            std.mem.sort(ImageEntry, node.images.items, {}, struct {
                fn lessThan(_: void, a: ImageEntry, b: ImageEntry) bool {
                    return naturalLessThan(a.name, b.name);
                }
            }.lessThan);

            std.mem.sort(usize, node.subdirs.items, self, struct {
                fn lessThan(tree: *SiteTree, a: usize, b: usize) bool {
                    return naturalLessThan(tree.nodes.items[a].name, tree.nodes.items[b].name);
                }
            }.lessThan);
        }

        _ = self.countDescendants(0);
    }

    fn countDescendants(self: *SiteTree, index: usize) usize {
        const node = &self.nodes.items[index];
        var total = node.images.items.len;
        for (node.subdirs.items) |child_index| {
            total += self.countDescendants(child_index);
        }
        node.total_images = total;
        return total;
    }
};

pub fn generate(allocator: std.mem.Allocator, output_dir: []const u8) !Summary {
    const cwd = std.fs.cwd();
    cwd.makePath(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var root_dir = try cwd.openDir(output_dir, .{ .iterate = true });
    defer root_dir.close();

    var tree = try SiteTree.init(allocator);
    defer tree.deinit();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => _ = try tree.getOrAddDir(entry.path),
            .file => if (isImagePath(entry.basename)) try tree.addImage(entry.path),
            else => {},
        }
    }

    tree.sortAndCount();

    var directories_with_pages: usize = 0;
    var reader_pages: usize = 0;

    var index: usize = 0;
    while (index < tree.nodes.items.len) : (index += 1) {
        const node = tree.nodes.items[index];
        const page_name = if (index == 0) root_page_name else "index.html";
        try writeDirectoryPage(allocator, root_dir, &tree, index, page_name, output_dir);
        directories_with_pages += 1;

        if (node.images.items.len > 0) {
            try writeReaderPage(allocator, root_dir, &tree, index, output_dir);
            reader_pages += 1;
        }
    }

    return .{
        .directories = directories_with_pages,
        .reader_pages = reader_pages,
        .images = tree.nodes.items[0].total_images,
    };
}

fn isImagePath(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len == 0) return false;

    const image_exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".avif", ".svg" };
    for (image_exts) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn naturalLessThan(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;

    while (i < a.len and j < b.len) {
        const a_is_digit = std.ascii.isDigit(a[i]);
        const b_is_digit = std.ascii.isDigit(b[j]);

        if (a_is_digit and b_is_digit) {
            const a_start = i;
            const b_start = j;
            while (i < a.len and std.ascii.isDigit(a[i])) : (i += 1) {}
            while (j < b.len and std.ascii.isDigit(b[j])) : (j += 1) {}

            const a_num = a[a_start..i];
            const b_num = b[b_start..j];
            const cmp = compareDigitRuns(a_num, b_num);
            if (cmp < 0) return true;
            if (cmp > 0) return false;
            continue;
        }

        const a_lower = std.ascii.toLower(a[i]);
        const b_lower = std.ascii.toLower(b[j]);
        if (a_lower < b_lower) return true;
        if (a_lower > b_lower) return false;
        i += 1;
        j += 1;
    }

    return a.len < b.len;
}

fn compareDigitRuns(a: []const u8, b: []const u8) i8 {
    var a_trim = a;
    while (a_trim.len > 1 and a_trim[0] == '0') a_trim = a_trim[1..];
    var b_trim = b;
    while (b_trim.len > 1 and b_trim[0] == '0') b_trim = b_trim[1..];

    if (a_trim.len < b_trim.len) return -1;
    if (a_trim.len > b_trim.len) return 1;

    const order = std.mem.order(u8, a_trim, b_trim);
    return switch (order) {
        .lt => -1,
        .gt => 1,
        .eq => switch (std.mem.order(u8, a, b)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        },
    };
}

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

fn escapeHtmlAttribute(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return escapeHtml(allocator, text);
}

fn appendPercentEncodedByte(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, byte: u8) !void {
    const hex = "0123456789ABCDEF";
    try list.append(allocator, '%');
    try list.append(allocator, hex[byte >> 4]);
    try list.append(allocator, hex[byte & 0x0f]);
}

fn isUnreservedUrlByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn encodeRelativeUrlPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    for (path) |byte| {
        if (byte == '/') {
            try list.append(allocator, byte);
        } else if (isUnreservedUrlByte(byte)) {
            try list.append(allocator, byte);
        } else {
            try appendPercentEncodedByte(&list, allocator, byte);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn encodeRelativeUrlAttribute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const encoded_path = try encodeRelativeUrlPath(allocator, path);
    defer allocator.free(encoded_path);
    return escapeHtmlAttribute(allocator, encoded_path);
}

fn targetPath(allocator: std.mem.Allocator, dir_rel_path: []const u8, file_name: []const u8) ![]u8 {
    if (dir_rel_path.len == 0) return allocator.dupe(u8, file_name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_rel_path, file_name });
}

fn splitPath(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |part| {
        try list.append(allocator, part);
    }

    return list.toOwnedSlice(allocator);
}

fn relativeLink(allocator: std.mem.Allocator, from_dir_rel_path: []const u8, target_rel_path: []const u8) ![]u8 {
    if (from_dir_rel_path.len == 0) return allocator.dupe(u8, target_rel_path);

    const from_parts = try splitPath(allocator, from_dir_rel_path);
    defer allocator.free(from_parts);
    const target_parts = try splitPath(allocator, target_rel_path);
    defer allocator.free(target_parts);

    var common: usize = 0;
    while (common < from_parts.len and common < target_parts.len and std.mem.eql(u8, from_parts[common], target_parts[common])) : (common += 1) {}

    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    for (from_parts[common..]) |_| {
        try list.appendSlice(allocator, "../");
    }
    for (target_parts[common..], 0..) |part, idx| {
        if (idx > 0) try list.append(allocator, '/');
        try list.appendSlice(allocator, part);
    }

    if (list.items.len == 0) try list.appendSlice(allocator, ".");
    return list.toOwnedSlice(allocator);
}

fn writePageStart(w: anytype, title: []const u8) !void {
    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en" data-theme="system">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
    );
    try w.print("<title>{s}</title>\n", .{title});
    try w.writeAll(
        \\<style>
        \\  :root {
        \\    color-scheme: light dark;
        \\    --bg: #f6f8fa;
        \\    --surface: #ffffff;
        \\    --surface-alt: #eef2f7;
        \\    --border: #d0d7de;
        \\    --text: #1f2328;
        \\    --muted: #59636e;
        \\    --accent: #0969da;
        \\    --accent-strong: #0550ae;
        \\    --accent-soft: rgba(9, 105, 218, 0.14);
        \\    --shadow: 0 14px 40px rgba(31, 35, 40, 0.08);
        \\  }
        \\  :root[data-theme="light"] {
        \\    color-scheme: light;
        \\  }
        \\  :root[data-theme="dark"] {
        \\    color-scheme: dark;
        \\    --bg: #0d1117;
        \\    --surface: #161b22;
        \\    --surface-alt: #21262d;
        \\    --border: #30363d;
        \\    --text: #e6edf3;
        \\    --muted: #8b949e;
        \\    --accent: #58a6ff;
        \\    --accent-strong: #79c0ff;
        \\    --accent-soft: rgba(88, 166, 255, 0.18);
        \\    --shadow: 0 18px 48px rgba(1, 4, 9, 0.38);
        \\  }
        \\  @media (prefers-color-scheme: dark) {
        \\    :root[data-theme="system"] {
        \\      --bg: #0d1117;
        \\      --surface: #161b22;
        \\      --surface-alt: #21262d;
        \\      --border: #30363d;
        \\      --text: #e6edf3;
        \\      --muted: #8b949e;
        \\      --accent: #58a6ff;
        \\      --accent-strong: #79c0ff;
        \\      --accent-soft: rgba(88, 166, 255, 0.18);
        \\      --shadow: 0 18px 48px rgba(1, 4, 9, 0.38);
        \\    }
        \\  }
        \\  * { box-sizing: border-box; }
        \\  body {
        \\    margin: 0;
        \\    font-family: system-ui, sans-serif;
        \\    background: var(--bg);
        \\    color: var(--text);
        \\    min-height: 100vh;
        \\  }
        \\  a { color: var(--accent); text-decoration: none; }
        \\  a:hover { color: var(--accent-strong); }
        \\  img { display: block; max-width: 100%; }
        \\  .shell { margin: 0 auto; padding: 32px 20px 48px; }
        \\  .hero {
        \\    background: linear-gradient(180deg, var(--surface), var(--surface-alt));
        \\    border: 1px solid var(--border);
        \\    border-radius: 20px;
        \\    box-shadow: var(--shadow);
        \\    padding: 24px;
        \\    margin-bottom: 24px;
        \\  }
        \\  .hero-top { display: flex; justify-content: space-between; gap: 16px; align-items: flex-start; flex-wrap: wrap; }
        \\  .hero h1 { margin: 0 0 8px; font-size: clamp(1.7rem, 2vw, 2.3rem); }
        \\  .hero p { margin: 0; color: var(--muted); line-height: 1.5; }
        \\  .stats { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 18px; }
        \\  .stat {
        \\    min-width: 130px;
        \\    background: var(--surface-alt);
        \\    border: 1px solid var(--border);
        \\    border-radius: 14px;
        \\    padding: 12px 14px;
        \\  }
        \\  .stat-label { color: var(--muted); font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.06em; }
        \\  .stat-value { margin-top: 4px; font-size: 1.2rem; font-weight: 700; }
        \\  .theme-picker { display: inline-flex; padding: 4px; gap: 4px; background: var(--surface-alt); border: 1px solid var(--border); border-radius: 999px; }
        \\  .theme-picker button {
        \\    border: 0;
        \\    background: transparent;
        \\    color: var(--muted);
        \\    padding: 8px 12px;
        \\    border-radius: 999px;
        \\    cursor: pointer;
        \\    font: inherit;
        \\  }
        \\  :root[data-theme="system"] [data-theme-value="system"],
        \\  :root[data-theme="light"] [data-theme-value="light"],
        \\  :root[data-theme="dark"] [data-theme-value="dark"] {
        \\    background: var(--accent);
        \\    color: #fff;
        \\  }
        \\  .breadcrumbs { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 20px; color: var(--muted); }
        \\  .breadcrumbs .sep { opacity: 0.6; }
        \\  .section { margin-top: 28px; }
        \\  .section h2 { margin: 0 0 14px; font-size: 1.15rem; }
        \\  .folder-grid, .thumb-grid {
        \\    display: grid;
        \\    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        \\    gap: 16px;
        \\  }
        \\  .card {
        \\    background: var(--surface);
        \\    border: 1px solid var(--border);
        \\    border-radius: 18px;
        \\    box-shadow: var(--shadow);
        \\    overflow: hidden;
        \\  }
        \\  .folder-card { padding: 18px; }
        \\  .folder-card h3 { margin: 0 0 8px; font-size: 1rem; }
        \\  .folder-card p { margin: 0; color: var(--muted); }
        \\  .thumb-card { display: block; }
        \\  .thumb-image {
        \\    aspect-ratio: 4 / 3;
        \\    background: var(--surface-alt);
        \\    overflow: hidden;
        \\  }
        \\  .thumb-image img { width: 100%; height: 100%; object-fit: cover; }
        \\  .thumb-meta { padding: 12px 14px 14px; }
        \\  .thumb-meta strong { display: block; margin-bottom: 4px; }
        \\  .thumb-meta span { color: var(--muted); font-size: 0.92rem; }
        \\  .actions { display: flex; flex-wrap: wrap; gap: 12px; margin: 18px 0 0; }
        \\  .button {
        \\    display: inline-flex;
        \\    align-items: center;
        \\    gap: 8px;
        \\    padding: 10px 14px;
        \\    border-radius: 999px;
        \\    border: 1px solid var(--border);
        \\    background: var(--surface-alt);
        \\    color: var(--text);
        \\    font-weight: 600;
        \\  }
        \\  .button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
        \\  .empty {
        \\    padding: 20px;
        \\    border: 1px dashed var(--border);
        \\    border-radius: 18px;
        \\    color: var(--muted);
        \\    background: var(--surface-alt);
        \\  }
        \\  .viewer {
        \\    background: var(--surface);
        \\    border: 1px solid var(--border);
        \\    border-radius: 20px;
        \\    box-shadow: var(--shadow);
        \\    padding: 18px;
        \\  }
        \\  .viewer-frame {
        \\    border-radius: 18px;
        \\    overflow: hidden;
        \\    background: var(--surface-alt);
        \\    display: flex;
        \\    align-items: center;
        \\    justify-content: center;
        \\    min-height: 280px;
        \\  }
        \\  .viewer-frame img { object-fit: fill; }
        \\  .viewer-controls { display: flex; flex-wrap: wrap; gap: 12px; justify-content: space-between; align-items: center; margin-top: 16px; }
        \\  .viewer-nav { display: flex; gap: 8px; flex-wrap: wrap; }
        \\  .viewer-status { color: var(--muted); font-weight: 600; }
        \\  .thumb-strip { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); margin-top: 18px; }
        \\  .strip-item {
        \\    border-radius: 14px;
        \\    overflow: hidden;
        \\    border: 1px solid var(--border);
        \\    background: var(--surface-alt);
        \\  }
        \\  .strip-item img { aspect-ratio: 1 / 1; width: 100%; object-fit: cover; }
        \\  .footer { margin-top: 28px; color: var(--muted); font-size: 0.9rem; }
        \\  @media (max-width: 640px) {
        \\    .shell { padding-inline: 14px; }
        \\    .hero { padding: 18px; border-radius: 16px; }
        \\    .viewer { padding: 14px; }
        \\  }
        \\</style>
        \\<script>
        \\  (() => {
        \\    const storageKey = 'argiope-theme';
        \\    const root = document.documentElement;
        \\    const allowed = new Set(['system', 'light', 'dark']);
        \\    const setTheme = (value) => {
        \\      const next = allowed.has(value) ? value : 'system';
        \\      root.dataset.theme = next;
        \\      try { localStorage.setItem(storageKey, next); } catch (_) {}
        \\      document.querySelectorAll('[data-theme-value]').forEach((button) => {
        \\        button.setAttribute('aria-pressed', button.dataset.themeValue === next ? 'true' : 'false');
        \\      });
        \\    };
        \\    let initial = 'system';
        \\    try {
        \\      const stored = localStorage.getItem(storageKey);
        \\      if (stored && allowed.has(stored)) initial = stored;
        \\    } catch (_) {}
        \\    root.dataset.theme = initial;
        \\    window.addEventListener('DOMContentLoaded', () => {
        \\      document.querySelectorAll('[data-theme-value]').forEach((button) => {
        \\        button.addEventListener('click', () => setTheme(button.dataset.themeValue));
        \\      });
        \\      setTheme(initial);
        \\    });
        \\  })();
        \\</script>
        \\</head>
        \\<body>
        \\<div class="shell">
    );
}

fn writeThemeControls(w: anytype) !void {
    try w.writeAll(
        \\<div class="theme-picker" role="group" aria-label="Theme selection">
        \\  <button type="button" data-theme-value="system" aria-pressed="true">System</button>
        \\  <button type="button" data-theme-value="light" aria-pressed="false">Light</button>
        \\  <button type="button" data-theme-value="dark" aria-pressed="false">Dark</button>
        \\</div>
    );
}

fn writeFooter(w: anytype) !void {
    try w.print("<p class=\"footer\">Generated by argiope {s}.</p>\n", .{cli_mod.version});
    try w.writeAll("</div>\n</body>\n</html>\n");
}

fn writeBreadcrumbs(allocator: std.mem.Allocator, w: anytype, tree: *const SiteTree, index: usize) !void {
    try w.writeAll("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\">\n");
    const home_href = try relativeLink(allocator, tree.nodes.items[index].rel_path, root_page_name);
    defer allocator.free(home_href);
    const home_href_attr = try encodeRelativeUrlAttribute(allocator, home_href);
    defer allocator.free(home_href_attr);
    try w.print("<a href=\"{s}\">Library</a>\n", .{home_href_attr});

    var chain: std.ArrayListUnmanaged(usize) = .empty;
    defer chain.deinit(allocator);

    var current = tree.nodes.items[index].parent;
    while (current) |value| {
        if (value == 0) break;
        try chain.append(allocator, value);
        current = tree.nodes.items[value].parent;
    }

    var pos = chain.items.len;
    while (pos > 0) {
        pos -= 1;
        const node = tree.nodes.items[chain.items[pos]];
        const target = try targetPath(allocator, node.rel_path, "index.html");
        defer allocator.free(target);
        const href = try relativeLink(allocator, tree.nodes.items[index].rel_path, target);
        defer allocator.free(href);
        const href_attr = try encodeRelativeUrlAttribute(allocator, href);
        defer allocator.free(href_attr);
        const escaped_name = try escapeHtml(allocator, node.name);
        defer allocator.free(escaped_name);
        try w.writeAll("<span class=\"sep\">/</span>\n");
        try w.print("<a href=\"{s}\">{s}</a>\n", .{ href_attr, escaped_name });
    }

    if (index != 0) {
        const current_name = try escapeHtml(allocator, tree.nodes.items[index].name);
        defer allocator.free(current_name);
        try w.writeAll("<span class=\"sep\">/</span>\n");
        try w.print("<span>{s}</span>\n", .{current_name});
    }

    try w.writeAll("</nav>\n");
}

fn writeDirectoryPage(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    tree: *const SiteTree,
    index: usize,
    page_name: []const u8,
    output_dir: []const u8,
) !void {
    const node = tree.nodes.items[index];
    const file_path = try targetPath(allocator, node.rel_path, page_name);
    defer allocator.free(file_path);

    const file = try root_dir.createFile(file_path, .{ .truncate = true });
    defer file.close();

    var buffer: [65536]u8 = undefined;
    var fw = file.writer(&buffer);
    const w = &fw.interface;

    const title = if (index == 0)
        try std.fmt.allocPrint(allocator, "Argiope Image Library — {s}", .{output_dir})
    else
        try std.fmt.allocPrint(allocator, "{s} — Argiope Image Browser", .{node.name});
    defer allocator.free(title);

    const escaped_title = try escapeHtml(allocator, title);
    defer allocator.free(escaped_title);
    try writePageStart(w, escaped_title);

    const subtitle = if (index == 0)
        try std.fmt.allocPrint(allocator, "Browse thumbnails, nested folders, and reader views for downloads stored in {s}.", .{output_dir})
    else if (node.rel_path.len == 0)
        try allocator.dupe(u8, "Browse downloaded images.")
    else
        try std.fmt.allocPrint(allocator, "Folder: {s}", .{node.rel_path});
    defer allocator.free(subtitle);
    const escaped_subtitle = try escapeHtml(allocator, subtitle);
    defer allocator.free(escaped_subtitle);

    try w.writeAll("<section class=\"hero\">\n<div class=\"hero-top\">\n<div>\n");
    if (index == 0) {
        try w.writeAll("<h1>Image Library</h1>\n");
    } else {
        const heading = try escapeHtml(allocator, node.name);
        defer allocator.free(heading);
        try w.print("<h1>{s}</h1>\n", .{heading});
    }
    try w.print("<p>{s}</p>\n</div>\n", .{escaped_subtitle});
    try writeThemeControls(w);
    try w.writeAll("</div>\n<div class=\"stats\">\n");
    try w.print("<div class=\"stat\"><div class=\"stat-label\">Images here</div><div class=\"stat-value\">{d}</div></div>\n", .{node.images.items.len});
    try w.print("<div class=\"stat\"><div class=\"stat-label\">Folders</div><div class=\"stat-value\">{d}</div></div>\n", .{node.subdirs.items.len});
    try w.print("<div class=\"stat\"><div class=\"stat-label\">Images below</div><div class=\"stat-value\">{d}</div></div>\n", .{node.total_images});
    try w.writeAll("</div>\n");

    if (node.images.items.len > 0) {
        const reader_target = try targetPath(allocator, node.rel_path, "reader.html");
        defer allocator.free(reader_target);
        const reader_href = try relativeLink(allocator, node.rel_path, reader_target);
        defer allocator.free(reader_href);
        const reader_href_attr = try encodeRelativeUrlAttribute(allocator, reader_href);
        defer allocator.free(reader_href_attr);
        try w.writeAll("<div class=\"actions\">\n");
        try w.print("<a class=\"button primary\" href=\"{s}#1\">Open reader</a>\n", .{reader_href_attr});
        try w.writeAll("</div>\n");
    }
    try w.writeAll("</section>\n");

    try writeBreadcrumbs(allocator, w, tree, index);

    if (node.subdirs.items.len > 0) {
        try w.writeAll("<section class=\"section\">\n<h2>Folders</h2>\n<div class=\"folder-grid\">\n");
        for (node.subdirs.items) |child_index| {
            const child = tree.nodes.items[child_index];
            const child_target = try targetPath(allocator, child.rel_path, "index.html");
            defer allocator.free(child_target);
            const child_href = try relativeLink(allocator, node.rel_path, child_target);
            defer allocator.free(child_href);
            const child_href_attr = try encodeRelativeUrlAttribute(allocator, child_href);
            defer allocator.free(child_href_attr);
            const escaped_name = try escapeHtml(allocator, child.name);
            defer allocator.free(escaped_name);
            try w.writeAll("<article class=\"card folder-card\">\n");
            try w.print("<h3><a href=\"{s}\">{s}</a></h3>\n", .{ child_href_attr, escaped_name });
            try w.print("<p>{d} image(s) across {d} subfolder(s).</p>\n", .{ child.total_images, child.subdirs.items.len });
            if (child.images.items.len > 0) {
                const child_reader_target = try targetPath(allocator, child.rel_path, "reader.html");
                defer allocator.free(child_reader_target);
                const child_reader_href = try relativeLink(allocator, node.rel_path, child_reader_target);
                defer allocator.free(child_reader_href);
                const child_reader_href_attr = try encodeRelativeUrlAttribute(allocator, child_reader_href);
                defer allocator.free(child_reader_href_attr);
                try w.print("<div class=\"actions\"><a class=\"button\" href=\"{s}#1\">Start reading</a></div>\n", .{child_reader_href_attr});
            }
            try w.writeAll("</article>\n");
        }
        try w.writeAll("</div>\n</section>\n");
    }

    if (node.images.items.len > 0) {
        try w.writeAll("<section class=\"section\">\n<h2>Thumbnails</h2>\n<div class=\"thumb-grid\">\n");
        const reader_file_attr = try encodeRelativeUrlAttribute(allocator, "reader.html");
        defer allocator.free(reader_file_attr);
        for (node.images.items, 0..) |image, image_index| {
            const escaped_name = try escapeHtml(allocator, image.name);
            defer allocator.free(escaped_name);
            const image_src_attr = try encodeRelativeUrlAttribute(allocator, image.name);
            defer allocator.free(image_src_attr);
            try w.print("<a class=\"card thumb-card\" href=\"{s}#{d}\">\n<div class=\"thumb-image\">\n<img loading=\"lazy\" src=\"", .{ reader_file_attr, image_index + 1 });
            try w.print("{s}", .{image_src_attr});
            try w.writeAll("\" alt=\"");
            try w.print("{s}", .{escaped_name});
            try w.writeAll("\">\n</div>\n<div class=\"thumb-meta\">\n<strong>");
            try w.print("{s}", .{escaped_name});
            try w.writeAll("</strong>\n<span>Open in reader</span>\n</div>\n</a>\n");
        }
        try w.writeAll("</div>\n</section>\n");
    } else if (node.subdirs.items.len == 0) {
        try w.writeAll("<div class=\"empty\">No downloaded images were found in this folder yet.</div>\n");
    }

    try writeFooter(w);
    try w.flush();
}

fn writeReaderPage(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    tree: *const SiteTree,
    index: usize,
    output_dir: []const u8,
) !void {
    const node = tree.nodes.items[index];
    const file_path = try targetPath(allocator, node.rel_path, "reader.html");
    defer allocator.free(file_path);

    const file = try root_dir.createFile(file_path, .{ .truncate = true });
    defer file.close();

    var buffer: [65536]u8 = undefined;
    var fw = file.writer(&buffer);
    const w = &fw.interface;

    const title = if (index == 0)
        try std.fmt.allocPrint(allocator, "Reader — {s}", .{output_dir})
    else
        try std.fmt.allocPrint(allocator, "Reader — {s}", .{node.name});
    defer allocator.free(title);
    const escaped_title = try escapeHtml(allocator, title);
    defer allocator.free(escaped_title);
    try writePageStart(w, escaped_title);

    const subtitle = if (index == 0)
        try std.fmt.allocPrint(allocator, "Reader mode for downloads stored in {s}.", .{output_dir})
    else
        try std.fmt.allocPrint(allocator, "Ordered viewer for {s}.", .{node.rel_path});
    defer allocator.free(subtitle);
    const escaped_subtitle = try escapeHtml(allocator, subtitle);
    defer allocator.free(escaped_subtitle);

    try w.writeAll("<section class=\"hero\">\n<div class=\"hero-top\">\n<div>\n<h1>Reader</h1>\n");
    try w.print("<p>{s}</p>\n</div>\n", .{escaped_subtitle});
    try writeThemeControls(w);
    try w.writeAll("</div>\n<div class=\"actions\">\n");
    const overview_file = if (index == 0) root_page_name else "index.html";
    const overview_href_attr = try encodeRelativeUrlAttribute(allocator, overview_file);
    defer allocator.free(overview_href_attr);
    try w.print("<a class=\"button\" href=\"{s}\">Back to overview</a>\n", .{overview_href_attr});
    try w.writeAll("</div>\n</section>\n");

    var next_chapter: ?[]const u8 = null;
    var prev_chapter: ?[]const u8 = null;
    var prev_chapter_pages: usize = 0;

    if (node.parent) |parent_idx| {
        const parent_node = tree.nodes.items[parent_idx];
        // Find self in parent's subdirs
        for (parent_node.subdirs.items, 0..) |child_idx, i| {
            if (child_idx == index) {
                if (i + 1 < parent_node.subdirs.items.len) {
                    const next_idx = parent_node.subdirs.items[i + 1];
                    const next_node = tree.nodes.items[next_idx];
                    if (next_node.images.items.len > 0) {
                        const target = try targetPath(allocator, next_node.rel_path, "reader.html");
                        defer allocator.free(target);
                        const href = try relativeLink(allocator, node.rel_path, target);
                        next_chapter = href;
                        // Don't free href yet, we need it for printing
                    }
                }
                if (i > 0) {
                    const prev_idx = parent_node.subdirs.items[i - 1];
                    const prev_node = tree.nodes.items[prev_idx];
                    if (prev_node.images.items.len > 0) {
                        const target = try targetPath(allocator, prev_node.rel_path, "reader.html");
                        defer allocator.free(target);
                        const href = try relativeLink(allocator, node.rel_path, target);
                        prev_chapter = href;
                        prev_chapter_pages = prev_node.images.items.len;
                        // Don't free href yet
                    }
                }
                break;
            }
        }
    }

    try writeBreadcrumbs(allocator, w, tree, index);

    try w.writeAll(
        \\<section class="viewer">
        \\  <div class="viewer-frame"><img id="viewer-image" alt="Selected image"></div>
        \\  <div class="viewer-controls">
        \\    <div class="viewer-nav">
        \\      <button class="button" type="button" id="prev-image">Previous</button>
        \\      <button class="button" type="button" id="next-image">Next</button>
        \\    </div>
        \\    <div class="viewer-status" id="viewer-status">0 / 0</div>
        \\  </div>
        \\  <div id="reader-items" hidden>
    );

    for (node.images.items) |image| {
        const escaped_name = try escapeHtml(allocator, image.name);
        defer allocator.free(escaped_name);
        const image_src_attr = try encodeRelativeUrlAttribute(allocator, image.name);
        defer allocator.free(image_src_attr);
        try w.print("<a data-src=\"{s}\" data-label=\"{s}\"></a>\n", .{ image_src_attr, escaped_name });
    }

    try w.writeAll(
        \\  </div>
        \\  <div class="thumb-strip">
    );
    for (node.images.items, 0..) |image, image_index| {
        const escaped_name = try escapeHtml(allocator, image.name);
        defer allocator.free(escaped_name);
        const image_src_attr = try encodeRelativeUrlAttribute(allocator, image.name);
        defer allocator.free(image_src_attr);
        try w.print(
            "<a class=\"strip-item\" href=\"#{d}\"><img loading=\"lazy\" src=\"{s}\" alt=\"{s}\"></a>\n",
            .{ image_index + 1, image_src_attr, escaped_name },
        );
    }

    try w.writeAll(
        \\  </div>
        \\</section>
        \\<script>
        \\  (() => {
        \\    const items = Array.from(document.querySelectorAll('#reader-items [data-src]')).map((node) => ({
        \\      src: node.dataset.src,
        \\      label: node.dataset.label,
        \\    }));
    );

    if (next_chapter) |href| {
        const href_attr = try encodeRelativeUrlAttribute(allocator, href);
        defer allocator.free(href_attr);
        try w.print("    const nextChapter = \"{s}\";\n", .{href_attr});
        allocator.free(href);
    } else {
        try w.writeAll("    const nextChapter = null;\n");
    }

    if (prev_chapter) |href| {
        const href_attr = try encodeRelativeUrlAttribute(allocator, href);
        defer allocator.free(href_attr);
        try w.print("    const prevChapter = \"{s}#{d}\";\n", .{ href_attr, prev_chapter_pages });
        allocator.free(href);
    } else {
        try w.writeAll("    const prevChapter = null;\n");
    }

    try w.writeAll(
        \\    const image = document.getElementById('viewer-image');
        \\    const status = document.getElementById('viewer-status');
        \\    const prev = document.getElementById('prev-image');
        \\    const next = document.getElementById('next-image');
        \\    const parseIndex = () => {
        \\      const value = Number.parseInt(window.location.hash.replace('#', ''), 10);
        \\      if (!Number.isFinite(value) || value < 1 || value > items.length) return 0;
        \\      return value - 1;
        \\    };
        \\    const setHash = (index) => {
        \\      const nextHash = `#${index + 1}`;
        \\      if (window.location.hash !== nextHash) window.location.hash = nextHash;
        \\      render(index);
        \\    };
        \\    const render = (index) => {
        \\      if (!items.length) {
        \\        image.removeAttribute('src');
        \\        image.alt = 'No images available';
        \\        status.textContent = '0 / 0';
        \\        prev.disabled = true;
        \\        next.disabled = true;
        \\        return;
        \\      }
        \\      const item = items[index];
        \\      image.src = item.src;
        \\      image.alt = item.label;
        \\      status.textContent = `${index + 1} / ${items.length} — ${item.label}`;
        \\      prev.disabled = index === 0 && !prevChapter;
        \\      next.disabled = index === items.length - 1 && !nextChapter;
        \\    };
        \\    prev.addEventListener('click', () => {
        \\      const index = parseIndex();
        \\      if (index > 0) {
        \\          setHash(index - 1);
        \\      } else if (prevChapter) {
        \\          window.location.href = prevChapter;
        \\      }
        \\    });
        \\    next.addEventListener('click', () => {
        \\      const index = parseIndex();
        \\      if (index < items.length - 1) {
        \\          setHash(index + 1);
        \\      } else if (nextChapter) {
        \\          window.location.href = nextChapter + "#1";
        \\      }
        \\    });
        \\    window.addEventListener('hashchange', () => render(parseIndex()));
        \\    window.addEventListener('keydown', (event) => {
        \\      if (event.key === 'ArrowLeft' && !prev.disabled) prev.click();
        \\      if (event.key === 'ArrowRight' && !next.disabled) next.click();
        \\    });
        \\    if (!window.location.hash && items.length) {
        \\      window.location.hash = '#1';
        \\    }
        \\    render(parseIndex());
        \\  })();
        \\</script>
    );

    try writeFooter(w);
    try w.flush();
}

// ── Tests ──────────────────────────────────────────────────────────────

test "naturalLessThan sorts numbered names naturally" {
    try std.testing.expect(naturalLessThan("page_2", "page_10"));
    try std.testing.expect(naturalLessThan("2", "10"));
    try std.testing.expect(!naturalLessThan("10", "2"));
}

test "relativeLink handles nested directories" {
    const allocator = std.testing.allocator;
    const nested_to_root = try relativeLink(allocator, "series/2", root_page_name);
    defer allocator.free(nested_to_root);
    try std.testing.expectEqualStrings("../../library.html", nested_to_root);

    const nested_to_sibling = try relativeLink(allocator, "series/2", "series/10/index.html");
    defer allocator.free(nested_to_sibling);
    try std.testing.expectEqualStrings("../10/index.html", nested_to_sibling);
}

test "encodeRelativeUrlPath percent-encodes unsafe path bytes" {
    const allocator = std.testing.allocator;
    const encoded = try encodeRelativeUrlPath(allocator, "folder name/100% #1?\"'&.png");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("folder%20name/100%25%20%231%3F%22%27%26.png", encoded);
}

test "generate creates root, nested indexes, and reader pages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("page_10");
    try tmp.dir.makePath("page_2");
    try tmp.dir.makePath("manga/10");
    try tmp.dir.makePath("manga/2");
    try tmp.dir.writeFile(.{ .sub_path = "page_10/10.jpg", .data = "ten" });
    try tmp.dir.writeFile(.{ .sub_path = "page_2/2.jpg", .data = "two" });
    try tmp.dir.writeFile(.{ .sub_path = "manga/10/010.jpg", .data = "010" });
    try tmp.dir.writeFile(.{ .sub_path = "manga/2/001.jpg", .data = "001" });
    try tmp.dir.writeFile(.{ .sub_path = "manga/2/010.jpg", .data = "010" });

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    const summary = try generate(allocator, root_path);
    try std.testing.expectEqual(@as(usize, 5), summary.images);
    try std.testing.expect(summary.directories >= 5);
    try std.testing.expect(summary.reader_pages >= 4);

    const library_html = try tmp.dir.readFileAlloc(allocator, root_page_name, 65536);
    defer allocator.free(library_html);
    try std.testing.expect(std.mem.indexOf(u8, library_html, "data-theme-value=\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, library_html, "localStorage") != null);
    try std.testing.expect(std.mem.indexOf(u8, library_html, "page_2/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, library_html, "page_10/index.html") != null);
    const page_2_pos = std.mem.indexOfPos(u8, library_html, 0, "page_2/index.html").?;
    const page_10_pos = std.mem.indexOfPos(u8, library_html, 0, "page_10/index.html").?;
    try std.testing.expect(page_2_pos < page_10_pos);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("index.html", .{}));

    const manga_index = try tmp.dir.readFileAlloc(allocator, "manga/index.html", 65536);
    defer allocator.free(manga_index);
    try std.testing.expect(std.mem.indexOf(u8, manga_index, "2/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, manga_index, "10/index.html") != null);
    const chapter_2_pos = std.mem.indexOfPos(u8, manga_index, 0, "2/index.html").?;
    const chapter_10_pos = std.mem.indexOfPos(u8, manga_index, 0, "10/index.html").?;
    try std.testing.expect(chapter_2_pos < chapter_10_pos);

    const chapter_index = try tmp.dir.readFileAlloc(allocator, "manga/2/index.html", 65536);
    defer allocator.free(chapter_index);
    try std.testing.expect(std.mem.indexOf(u8, chapter_index, "../../library.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, chapter_index, "reader.html#1") != null);

    const reader_html = try tmp.dir.readFileAlloc(allocator, "manga/2/reader.html", 65536);
    defer allocator.free(reader_html);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "#1") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "ArrowRight") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "001.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "010.jpg") != null);
    const image_001_pos = std.mem.indexOfPos(u8, reader_html, 0, "001.jpg").?;
    const image_010_pos = std.mem.indexOfPos(u8, reader_html, 0, "010.jpg").?;
    try std.testing.expect(image_001_pos < image_010_pos);
}

test "generate encodes unsafe filenames and folder names in HTML attributes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Use characters that are valid on Windows but require URL encoding
    // Avoid: < > : " / \ | ? *
    const dir_name = "gallery & 'special' #1";
    const file_name = "cover 'special' & 100% #1.png";

    try tmp.dir.makePath(dir_name);
    try tmp.dir.writeFile(.{
        .sub_path = dir_name ++ "/" ++ file_name,
        .data = "image",
    });

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    const summary = try generate(allocator, root_path);
    try std.testing.expectEqual(@as(usize, 1), summary.images);
    try std.testing.expect(summary.directories >= 2);
    try std.testing.expect(summary.reader_pages >= 1);

    // Expected encoded values
    // Space -> %20
    // & -> %26
    // ' -> %27
    // # -> %23
    // % -> %25
    const encoded_dir = "gallery%20%26%20%27special%27%20%231";
    const encoded_image = "cover%20%27special%27%20%26%20100%25%20%231.png";

    const library_html = try tmp.dir.readFileAlloc(allocator, root_page_name, 65536);
    defer allocator.free(library_html);
    try std.testing.expect(std.mem.indexOf(u8, library_html, encoded_dir ++ "/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, library_html, encoded_dir ++ "/reader.html#1") != null);
    // HTML escaping: & -> &amp;, ' -> &#39;
    try std.testing.expect(std.mem.indexOf(u8, library_html, "gallery &amp; &#39;special&#39; #1") != null);

    const folder_index = try tmp.dir.readFileAlloc(allocator, dir_name ++ "/index.html", 65536);
    defer allocator.free(folder_index);
    try std.testing.expect(std.mem.indexOf(u8, folder_index, "src=\"" ++ encoded_image ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, folder_index, "src=\"cover 'special' & 100% #1.png\"") == null);
    // Check for escaped name (e.g. in alt attribute)
    try std.testing.expect(std.mem.indexOf(u8, folder_index, "cover &#39;special&#39; &amp; 100% #1.png") != null);

    const reader_html = try tmp.dir.readFileAlloc(allocator, dir_name ++ "/reader.html", 65536);
    defer allocator.free(reader_html);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "data-src=\"" ++ encoded_image ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "src=\"" ++ encoded_image ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reader_html, "cover &#39;special&#39; &amp; 100% #1.png") != null);
}

test "generate links next and previous chapters" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("manga/ch1");
    try tmp.dir.makePath("manga/ch2");
    try tmp.dir.makePath("manga/ch3");

    try tmp.dir.writeFile(.{ .sub_path = "manga/ch1/1.jpg", .data = "img" });
    try tmp.dir.writeFile(.{ .sub_path = "manga/ch2/1.jpg", .data = "img" });
    try tmp.dir.writeFile(.{ .sub_path = "manga/ch3/1.jpg", .data = "img" });

    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    _ = try generate(allocator, root_path);

    const ch1_reader = try tmp.dir.readFileAlloc(allocator, "manga/ch1/reader.html", 65536);
    defer allocator.free(ch1_reader);
    try std.testing.expect(std.mem.indexOf(u8, ch1_reader, "const nextChapter = \"../ch2/reader.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ch1_reader, "const prevChapter = null") != null);

    const ch2_reader = try tmp.dir.readFileAlloc(allocator, "manga/ch2/reader.html", 65536);
    defer allocator.free(ch2_reader);
    try std.testing.expect(std.mem.indexOf(u8, ch2_reader, "const nextChapter = \"../ch3/reader.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ch2_reader, "const prevChapter = \"../ch1/reader.html#1\"") != null);

    const ch3_reader = try tmp.dir.readFileAlloc(allocator, "manga/ch3/reader.html", 65536);
    defer allocator.free(ch3_reader);
    try std.testing.expect(std.mem.indexOf(u8, ch3_reader, "const nextChapter = null") != null);
    try std.testing.expect(std.mem.indexOf(u8, ch3_reader, "const prevChapter = \"../ch2/reader.html#1\"") != null);
}
