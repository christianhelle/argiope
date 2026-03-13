const std = @import("std");
const http_mod = @import("http.zig");
const cli_mod = @import("cli.zig");
const image_browser_mod = @import("image_browser.zig");

/// Browser-like User-Agent so CDNs don't reject us as a bot.
const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

/// A discovered chapter: its display number string and the URL of page 1.
pub const MangafoxChapter = struct {
    number: []const u8, // e.g. "1", "5.5"
    url: []const u8, // absolute URL to page 1 of the chapter
};

/// Manga metadata extracted from the manga landing page.
pub const MangaMetadata = struct {
    version: u32 = 1,
    source: []const u8 = "mangafox",
    slug: []const u8,
    title: []const u8,
    synopsis: ?[]const u8 = null,

    pub fn deinit(self: *MangaMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.title);
        if (self.synopsis) |s| allocator.free(s);
    }
};

const metadata_filename = ".argiope-metadata.json";

fn metadataFilePath(allocator: std.mem.Allocator, output_dir: []const u8, slug: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ output_dir, slug, metadata_filename });
}

fn eqIgnoreAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        var ca = a[i];
        var cb = b[i];
        if (ca >= 'A' and ca <= 'Z') ca += 32;
        if (cb >= 'A' and cb <= 'Z') cb += 32;
        if (ca != cb) return false;
    }
    return true;
}

fn findElementByClass(html: []const u8, class_name: []const u8) ?[]const u8 {
    const class_needle = "class=\"";
    var search_start: usize = 0;

    while (std.mem.indexOf(u8, html[search_start..], class_needle)) |class_pos| {
        const pos = search_start + class_pos;
        const after_class = html[pos + class_needle.len ..];

        // Check if this class contains our target class_name
        const class_value_end = std.mem.indexOfScalar(u8, after_class, '"') orelse continue;
        const class_value = after_class[0..class_value_end];

        // Search for class_name with proper boundary checking
        var is_match = false;
        var match_pos: usize = 0;
        while (std.mem.indexOf(u8, class_value[match_pos..], class_name)) |found| {
            const abs_pos = match_pos + found;
            const before_ok = abs_pos == 0 or class_value[abs_pos - 1] == ' ';
            const after_pos = abs_pos + class_name.len;
            const after_ok = after_pos >= class_value.len or class_value[after_pos] == ' ' or class_value[after_pos] == '"';
            if (before_ok and after_ok) {
                is_match = true;
                break;
            }
            match_pos = abs_pos + 1;
        }

        if (!is_match) {
            search_start = pos + 1;
            continue;
        }

        // Found the right element, now find the tag start
        const tag_start = std.mem.lastIndexOf(u8, html[0..pos], "<") orelse continue;

        // Find the closing > of the opening tag
        const tag_content = html[tag_start..];
        const tag_end = std.mem.indexOfScalar(u8, tag_content, '>') orelse continue;
        const content_start = tag_start + tag_end + 1;

        // Extract the tag name from the opening tag
        const name_start = tag_start + 1;
        var name_end = name_start;
        while (name_end < html.len) : (name_end += 1) {
            const c = html[name_end];
            // Treat any whitespace as a terminator in addition to '>' and '/'
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '>' or c == '/') break;
        }
        const tag_name = html[name_start..name_end];

        // Now scan content while tracking depth for nested tags with the same name
        const search_content = html[content_start..];
        var depth: usize = 1;
        var i: usize = 0;
        while (i < search_content.len) {
            if (search_content[i] == '<') {
                if (i + 1 < search_content.len and search_content[i + 1] == '!') {
                    // Handle comments (<!-- ... -->) and doctypes. If this is a comment opener
                    // starting with "<!--" search for the full terminator "-->". Otherwise
                    // fall back to skipping to the next '>' for doctypes.
                    if (i + 4 <= search_content.len and
                        search_content[i + 2] == '-' and search_content[i + 3] == '-')
                    {
                        // Search for "-->" starting at i+4
                        const term = std.mem.indexOfPos(u8, search_content, i + 4, "-->") orelse break;
                        i = term + 3;
                        continue;
                    } else {
                        const skip_end = std.mem.indexOfScalarPos(u8, search_content, i, '>') orelse break;
                        i = skip_end + 1;
                        continue;
                    }
                }
                const is_closing = (i + 1 < search_content.len and search_content[i + 1] == '/');
                const tag_end_pos = std.mem.indexOfScalarPos(u8, search_content, i, '>') orelse break;
                // Extract candidate tag name
                var tn_start = i + 1;
                if (is_closing) tn_start += 1;
                var tn_end = tn_start;
                // tag_end_pos is an absolute index into search_content; do not add i
                while (tn_end < tag_end_pos) : (tn_end += 1) {
                    const c = search_content[tn_end];
                    // Treat any whitespace as a terminator in addition to '>' and '/'
                    if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '>' or c == '/') break;
                }
                const candidate = search_content[tn_start..tn_end];
                if (eqIgnoreAscii(candidate, tag_name)) {
                    if (is_closing) {
                        if (depth == 1) {
                            return search_content[0..i];
                        } else {
                            depth -= 1;
                        }
                    } else {
                        depth += 1;
                    }
                }
                i = tag_end_pos + 1;
            } else {
                i += 1;
            }
        }

        return search_content;
    }

    return null;
}

fn extractTextContent(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            i = close + 1;
        } else {
            try result.append(allocator, html[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn normalizeWhitespace(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);
    var in_whitespace = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_whitespace and result.items.len > 0) {
                try result.append(allocator, ' ');
                in_whitespace = true;
            }
        } else {
            try result.append(allocator, c);
            in_whitespace = false;
        }
    }
    while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
        result.items.len -= 1;
    }
    return result.toOwnedSlice(allocator);
}

pub fn parseMangaMetadata(
    allocator: std.mem.Allocator,
    html: []const u8,
    slug: []const u8,
) !MangaMetadata {
    var title: []const u8 = slug;
    var title_allocated: ?[]u8 = null;
    var synopsis: ?[]const u8 = null;

    // Try to extract title from the page
    if (findElementByClass(html, "detail-info-right-title-font")) |title_elem| {
        const extracted = try extractTextContent(allocator, title_elem);
        defer allocator.free(extracted);
        const trimmed = std.mem.trim(u8, extracted, " \t\n\r");
        if (trimmed.len > 0) {
            const allocated = try allocator.dupe(u8, trimmed);
            title_allocated = allocated;
            title = allocated;
        }
    }

    // Fallback: extract from <title> tag (e.g., "Naruto Manga - Read Naruto Manga Online for Free")
    if (title_allocated == null) {
        const title_tag = "<title>";
        if (std.mem.indexOf(u8, html, title_tag)) |pos| {
            const content_start = pos + title_tag.len;
            const content_end = std.mem.indexOfScalar(u8, html[content_start..], '<');
            if (content_end) |end| {
                const title_text = html[content_start .. content_start + end];
                const trimmed = std.mem.trim(u8, title_text, " \t\n\r");
                // Extract just the manga name (before " Manga -")
                const dash = " Manga -";
                if (std.mem.indexOf(u8, trimmed, dash)) |dash_pos| {
                    const manga_name = trimmed[0..dash_pos];
                    if (manga_name.len > 0) {
                        const allocated = try allocator.dupe(u8, manga_name);
                        title_allocated = allocated;
                        title = allocated;
                    }
                }
            }
        }
    }

    // Try fullcontent first (hidden full synopsis)
    if (synopsis == null) {
        if (findElementByClass(html, "fullcontent")) |synopsis_elem| {
            const extracted = try extractTextContent(allocator, synopsis_elem);
            defer allocator.free(extracted);
            const trimmed = std.mem.trim(u8, extracted, " \t\n\r");
            if (trimmed.len > 0) {
                synopsis = try normalizeWhitespace(trimmed, allocator);
            }
        }
    }

    // Fallback to the visible truncated content
    if (synopsis == null) {
        if (findElementByClass(html, "detail-info-right-content")) |synopsis_elem| {
            const extracted = try extractTextContent(allocator, synopsis_elem);
            defer allocator.free(extracted);
            const trimmed = std.mem.trim(u8, extracted, " \t\n\r");
            const dotdotdot = "...";
            const more_link = "<a href=\"javascript:void(0)\"";
            var end_idx = trimmed.len;
            if (std.mem.endsWith(u8, trimmed, dotdotdot)) {
                end_idx = trimmed.len - dotdotdot.len;
            }
            if (std.mem.indexOf(u8, trimmed, more_link)) |link_pos| {
                end_idx = @min(end_idx, link_pos);
            }
            if (end_idx > 0) {
                const final_text = trimmed[0..end_idx];
                synopsis = try normalizeWhitespace(final_text, allocator);
            }
        }
    }

    const slug_copy = try allocator.dupe(u8, slug);
    errdefer allocator.free(slug_copy);

    const title_copy = try allocator.dupe(u8, title);
    errdefer allocator.free(title_copy);

    // Free intermediate allocation if still around
    if (title_allocated) |a| {
        allocator.free(a);
    }

    return MangaMetadata{
        .slug = slug_copy,
        .title = title_copy,
        .synopsis = synopsis,
    };
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

fn writeMetadataJson(allocator: std.mem.Allocator, metadata: *MangaMetadata) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\n");
    try list.appendSlice(allocator, "  \"version\": 1,\n");
    try list.appendSlice(allocator, "  \"source\": \"mangafox\",\n");

    const escaped_slug = try escapeJsonString(allocator, metadata.slug);
    defer allocator.free(escaped_slug);
    try list.writer(allocator).print("  \"slug\": \"{s}\",\n", .{escaped_slug});

    const escaped_title = try escapeJsonString(allocator, metadata.title);
    defer allocator.free(escaped_title);
    try list.writer(allocator).print("  \"title\": \"{s}\",\n", .{escaped_title});

    if (metadata.synopsis) |syn| {
        const escaped_syn = try escapeJsonString(allocator, syn);
        defer allocator.free(escaped_syn);
        try list.writer(allocator).print("  \"synopsis\": \"{s}\"\n", .{escaped_syn});
    } else {
        try list.appendSlice(allocator, "  \"synopsis\": null\n");
    }
    try list.appendSlice(allocator, "}\n");

    return list.toOwnedSlice(allocator);
}

/// Extract the manga slug from a fanfox.net URL.
/// e.g. "https://fanfox.net/manga/naruto/" → "naruto"
pub fn extractSlug(url_str: []const u8) ?[]const u8 {
    const needle = "/manga/";
    const start = (std.mem.indexOf(u8, url_str, needle) orelse return null) + needle.len;
    const rest = url_str[start..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// Returns true if the slug is safe to use as a filesystem path component.
/// Rejects empty strings, anything starting with '.' (covers ".", "..", ".hidden"),
/// and anything containing '/' or '\' path separators.
pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len == 0) return false;
    if (std.mem.startsWith(u8, slug, ".")) return false;
    if (std.mem.indexOfScalar(u8, slug, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, slug, '\\') != null) return false;
    return true;
}

/// Parse the chapter list HTML for a given manga slug.
/// Looks for anchor hrefs matching /manga/{slug}/[v.../]c{number}/
/// Returns an owned slice; caller frees each item's fields and the slice itself.
/// If verbose is true, logs all examined hrefs and rejection reasons to stderr for debugging.
pub fn parseChapterList(
    allocator: std.mem.Allocator,
    html: []const u8,
    slug: []const u8,
    base_url: []const u8,
    verbose: bool,
) ![]MangafoxChapter {
    var chapters: std.ArrayListUnmanaged(MangafoxChapter) = .empty;
    errdefer {
        for (chapters.items) |ch| {
            allocator.free(ch.number);
            allocator.free(ch.url);
        }
        chapters.deinit(allocator);
    }

    // Build the path prefix we're searching for: /manga/{slug}/
    var prefix_buf: [512]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "/manga/{s}/", .{slug}) catch |e| {
        if (e == error.NoSpaceLeft) return error.SlugTooLong;
        return e;
    };

    if (verbose) {
        var err_buf: [256]u8 = undefined;
        var efw = std.fs.File.stderr().writer(&err_buf);
        efw.interface.print("[parseChapterList] Searching for pattern: {s}\n", .{prefix}) catch {};
        efw.interface.flush() catch {};
    }

    var pos: usize = 0;
    var href_count: usize = 0;
    while (pos < html.len) {
        // Find next href=" or href='
        const href_start = blk: {
            const dq = std.mem.indexOfPos(u8, html, pos, "href=\"") orelse html.len;
            const sq = std.mem.indexOfPos(u8, html, pos, "href='") orelse html.len;
            if (dq == html.len and sq == html.len) break :blk html.len;
            break :blk @min(dq, sq);
        };
        if (href_start >= html.len) break;

        // Determine quote character and find the value
        const quote_offset: usize = 6; // len("href=\"")
        const quote_char = html[href_start + 5];
        const val_start = href_start + quote_offset;
        pos = val_start;

        const val_end = std.mem.indexOfScalarPos(u8, html, val_start, quote_char) orelse {
            pos = val_start + 1;
            continue;
        };
        const href = html[val_start..val_end];
        pos = val_end + 1;
        href_count += 1;

        // Must contain our prefix
        if (std.mem.indexOf(u8, href, prefix) == null) {
            if (verbose and href_count <= 10) {
                var err_buf: [512]u8 = undefined;
                var efw = std.fs.File.stderr().writer(&err_buf);
                efw.interface.print("  href #{d}: no prefix match: {s}\n", .{ href_count, href }) catch {};
                efw.interface.flush() catch {};
            }
            continue;
        }

        // Extract chapter number: look for /c{number} pattern
        // Accept both /c{N}/ and /c{N}.html formats (with or without trailing slash)
        const c_needle = "/c";
        const c_pos = std.mem.indexOf(u8, href, c_needle) orelse {
            if (verbose and href_count <= 20) {
                var err_buf: [512]u8 = undefined;
                var efw = std.fs.File.stderr().writer(&err_buf);
                efw.interface.print("  href #{d}: no /c pattern: {s}\n", .{ href_count, href }) catch {};
                efw.interface.flush() catch {};
            }
            continue;
        };

        // Validate that /c is followed by a digit (prevents false positives like "/collection")
        const after_c_pos = c_pos + c_needle.len;
        if (after_c_pos >= href.len or href[after_c_pos] < '0' or href[after_c_pos] > '9') {
            if (verbose and href_count <= 20) {
                var err_buf: [512]u8 = undefined;
                var efw = std.fs.File.stderr().writer(&err_buf);
                efw.interface.print("  href #{d}: /c not followed by digit: {s}\n", .{ href_count, href }) catch {};
                efw.interface.flush() catch {};
            }
            continue;
        }

        const num_start = after_c_pos;
        const rest = href[num_start..];

        // Find the end of the chapter number: stop at first '/', '?' or '#'
        const sep_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;

        // Start with that position, then strip optional ".html" suffix immediately before it.
        // This handles URLs like "/c100.html", "/c100.html?foo=bar", and "/c100.html#x".
        var num_end = sep_end;
        const html_suffix = ".html";
        if (sep_end >= html_suffix.len and
            std.mem.endsWith(u8, rest[0..sep_end], html_suffix))
        {
            num_end = sep_end - html_suffix.len;
        }

        if (num_end == 0) {
            if (verbose and href_count <= 20) {
                var err_buf: [512]u8 = undefined;
                var efw = std.fs.File.stderr().writer(&err_buf);
                efw.interface.print("  href #{d}: empty number after /c: {s}\n", .{ href_count, href }) catch {};
                efw.interface.flush() catch {};
            }
            continue;
        }
        const number_str = rest[0..num_end];

        // Validate it looks like a number (digits and optional one dot)
        if (!looksLikeNumber(number_str)) {
            if (verbose and href_count <= 20) {
                var err_buf: [512]u8 = undefined;
                var efw = std.fs.File.stderr().writer(&err_buf);
                efw.interface.print("  href #{d}: invalid number format '{s}': {s}\n", .{ href_count, number_str, href }) catch {};
                efw.interface.flush() catch {};
            }
            continue;
        }

        // Build absolute URL — append "1.html" only when the href doesn't already end with ".html"
        const abs_url = if (std.mem.startsWith(u8, href, "http://") or
            std.mem.startsWith(u8, href, "https://"))
            try allocator.dupe(u8, href)
        else blk: {
            const origin = getOrigin(base_url);
            if (std.mem.endsWith(u8, href, ".html")) {
                break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, href });
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}{s}1.html", .{ origin, href });
            }
        };
        errdefer allocator.free(abs_url);

        const number_copy = try allocator.dupe(u8, number_str);
        errdefer allocator.free(number_copy);

        // Deduplicate by chapter number
        var found = false;
        for (chapters.items) |existing| {
            if (std.mem.eql(u8, existing.number, number_copy)) {
                found = true;
                break;
            }
        }
        if (found) {
            if (verbose and href_count <= 20) {
                var err_buf: [256]u8 = undefined;
                var efw = std.fs.File.stderr().writer(&err_buf);
                efw.interface.print("  href #{d}: duplicate chapter {s}\n", .{ href_count, number_copy }) catch {};
                efw.interface.flush() catch {};
            }
            allocator.free(abs_url);
            allocator.free(number_copy);
            continue;
        }

        if (verbose and href_count <= 20) {
            var err_buf: [256]u8 = undefined;
            var efw = std.fs.File.stderr().writer(&err_buf);
            efw.interface.print("  href #{d}: MATCHED chapter {s}\n", .{ href_count, number_copy }) catch {};
            efw.interface.flush() catch {};
        }

        try chapters.append(allocator, MangafoxChapter{
            .number = number_copy,
            .url = abs_url,
        });
    }

    if (verbose) {
        var err_buf: [256]u8 = undefined;
        var efw = std.fs.File.stderr().writer(&err_buf);
        efw.interface.print("[parseChapterList] Total hrefs examined: {d}, chapters found: {d}\n", .{ href_count, chapters.items.len }) catch {};
        efw.interface.flush() catch {};
    }

    return chapters.toOwnedSlice(allocator);
}

/// Parse the chapter list from a fanfox.net RSS feed.
/// The RSS format has <link>URL</link> elements for each chapter.
/// Returns an owned slice; caller frees each item's fields and the slice itself.
/// If verbose is true, logs parsing diagnostics to stderr.
pub fn parseChapterListFromRss(
    allocator: std.mem.Allocator,
    xml: []const u8,
    slug: []const u8,
    verbose: bool,
) ![]MangafoxChapter {
    var chapters: std.ArrayListUnmanaged(MangafoxChapter) = .empty;
    errdefer {
        for (chapters.items) |ch| {
            allocator.free(ch.number);
            allocator.free(ch.url);
        }
        chapters.deinit(allocator);
    }

    // Build the path prefix we're searching for: /manga/{slug}/
    var prefix_buf: [512]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "/manga/{s}/", .{slug}) catch |e| {
        if (e == error.NoSpaceLeft) return error.SlugTooLong;
        return e;
    };

    if (verbose) {
        var err_buf: [256]u8 = undefined;
        var efw = std.fs.File.stderr().writer(&err_buf);
        efw.interface.print("[parseChapterListFromRss] Searching for pattern: {s}\n", .{prefix}) catch {};
        efw.interface.flush() catch {};
    }

    var pos: usize = 0;
    var link_count: usize = 0;
    while (pos < xml.len) {
        // Find next <link> tag
        const link_open = std.mem.indexOfPos(u8, xml, pos, "<link>") orelse break;
        const val_start = link_open + "<link>".len;
        const link_close = std.mem.indexOfPos(u8, xml, val_start, "</link>") orelse break;
        const link_url = xml[val_start..link_close];
        pos = link_close + "</link>".len;
        link_count += 1;

        // Must contain our prefix
        if (std.mem.indexOf(u8, link_url, prefix) == null) continue;

        // Extract chapter number: look for /c{digit} pattern
        const c_needle = "/c";
        const c_pos = std.mem.indexOf(u8, link_url, c_needle) orelse continue;
        const after_c_pos = c_pos + c_needle.len;
        if (after_c_pos >= link_url.len or link_url[after_c_pos] < '0' or link_url[after_c_pos] > '9') continue;

        const num_start = after_c_pos;
        const rest = link_url[num_start..];

        // Find end of chapter number (slash, question, hash)
        const sep_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var num_end = sep_end;
        // Allow an optional ".html" suffix before any separator or string end
        const search_slice = rest[0..sep_end];
        if (std.mem.lastIndexOf(u8, search_slice, ".html")) |html_pos| {
            num_end = html_pos;
        }
        if (num_end == 0) continue;
        const number_str = rest[0..num_end];

        if (!looksLikeNumber(number_str)) continue;

        // Use the URL as-is if absolute; the RSS always provides absolute URLs
        const abs_url = if (std.mem.startsWith(u8, link_url, "http://") or
            std.mem.startsWith(u8, link_url, "https://"))
            try allocator.dupe(u8, link_url)
        else
            try std.fmt.allocPrint(allocator, "https://fanfox.net{s}", .{link_url});
        errdefer allocator.free(abs_url);

        const number_copy = try allocator.dupe(u8, number_str);
        errdefer allocator.free(number_copy);

        // Deduplicate by chapter number
        var found = false;
        for (chapters.items) |existing| {
            if (std.mem.eql(u8, existing.number, number_copy)) {
                found = true;
                break;
            }
        }
        if (found) {
            allocator.free(abs_url);
            allocator.free(number_copy);
            continue;
        }

        try chapters.append(allocator, MangafoxChapter{
            .number = number_copy,
            .url = abs_url,
        });
    }

    if (verbose) {
        var err_buf: [256]u8 = undefined;
        var efw = std.fs.File.stderr().writer(&err_buf);
        efw.interface.print("[parseChapterListFromRss] Total links examined: {d}, chapters found: {d}\n", .{ link_count, chapters.items.len }) catch {};
        efw.interface.flush() catch {};
    }

    return chapters.toOwnedSlice(allocator);
}

/// Filter chapters by optional from/to range (inclusive).
/// Returns a new slice of pointers into the original; caller frees only the slice itself.
pub fn filterChapters(
    allocator: std.mem.Allocator,
    chapters: []const MangafoxChapter,
    from: ?f32,
    to: ?f32,
) ![]MangafoxChapter {
    if (from == null and to == null) {
        return allocator.dupe(MangafoxChapter, chapters);
    }

    var result: std.ArrayListUnmanaged(MangafoxChapter) = .empty;
    errdefer result.deinit(allocator);

    for (chapters) |ch| {
        const num = std.fmt.parseFloat(f32, ch.number) catch continue;
        if (from) |f| if (num < f) continue;
        if (to) |t| if (num > t) continue;
        try result.append(allocator, ch);
    }

    return result.toOwnedSlice(allocator);
}

/// Sort chapters numerically by chapter number.
/// Handles both integer and decimal chapter numbers (e.g., 1, 5.5, 10, 100.1).
/// Returns a new slice with chapters sorted in ascending numeric order.
/// Caller must free the returned slice (but not the individual chapter fields).
pub fn sortChapters(
    allocator: std.mem.Allocator,
    chapters: []const MangafoxChapter,
) ![]MangafoxChapter {
    if (chapters.len == 0) return try allocator.alloc(MangafoxChapter, 0);

    const ParsedChapter = struct {
        chapter: MangafoxChapter,
        num: f64,
        index: usize,
    };

    var parsed = try allocator.alloc(ParsedChapter, chapters.len);
    errdefer allocator.free(parsed);

    for (chapters, 0..) |ch, i| {
        const num = std.fmt.parseFloat(f64, ch.number) catch std.math.inf(f64);
        parsed[i] = .{
            .chapter = ch,
            .num = num,
            .index = i,
        };
    }

    const Context = struct {
        pub fn lessThan(_: @This(), a: ParsedChapter, b: ParsedChapter) bool {
            if (a.num < b.num) return true;
            if (a.num > b.num) return false;
            // Deterministic tie-breaker preserving original order for equal chapter numbers
            return a.index < b.index;
        }
    };

    std.mem.sort(ParsedChapter, parsed, Context{}, Context.lessThan);

    const sorted = try allocator.alloc(MangafoxChapter, chapters.len);
    errdefer allocator.free(sorted);

    for (parsed, 0..) |p, i| {
        sorted[i] = p.chapter;
    }

    allocator.free(parsed);
    return sorted;
}

/// Scan HTML page for a total page count embedded in script content.
/// Looks for patterns like `var imagecount = N` or `var pcount = N`.
/// Returns 0 if not found (caller should fall back to probing).
pub fn parsePageCount(html: []const u8) usize {
    const patterns = [_][]const u8{
        "var imagecount=",
        "var imagecount =",
        "imagecount:",
        "var pcount=",
        "var pcount =",
        "pcount:",
        "\"total\":",
        "'total':",
        "total_pages:",
        "pagecount:",
    };

    for (patterns) |pat| {
        if (std.mem.indexOf(u8, html, pat)) |p| {
            var i = p + pat.len;
            // Skip whitespace
            while (i < html.len and (html[i] == ' ' or html[i] == '\t')) i += 1;
            // Read digits
            const num_start = i;
            while (i < html.len and html[i] >= '0' and html[i] <= '9') i += 1;
            if (i > num_start) {
                return std.fmt.parseInt(usize, html[num_start..i], 10) catch continue;
            }
        }
    }

    return 0;
}

/// Extract the numeric chapter ID embedded in a fanfox.net reader page.
/// Looks for: `var chapterid=12345` or `var chapterid = 12345`.
pub fn extractChapterId(html: []const u8) ?[]const u8 {
    const patterns = [_][]const u8{ "var chapterid=", "var chapterid =" };
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, html, pat)) |p| {
            var i = p + pat.len;
            while (i < html.len and html[i] == ' ') i += 1;
            const start = i;
            while (i < html.len and html[i] >= '0' and html[i] <= '9') i += 1;
            if (i > start) return html[start..i];
        }
    }
    return null;
}

/// Extract an image URL from a chapter reader page.
/// Strategy:
///   1. Scan <script> tag content for known JS variable assignments containing CDN URLs
///   2. Scan <script> tag content for any CDN URL string (skipping known placeholders)
///   3. Fall back to <img> tags with reader-related id/class hints (skipping placeholders)
pub fn extractImageUrl(allocator: std.mem.Allocator, html: []const u8) !?[]u8 {
    const cdn_hosts = [_][]const u8{
        "//img.mghcdn.com",
        "//img.fanfox.net",
        "//img.mangafox.me",
        "//cdn.fanfox.net",
        "//l.mghcdn.com",
    };

    // --- Strategy 1 & 2: scan script blocks ---
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, "<script")) |script_start| {
        const block_start = std.mem.indexOfPos(u8, html, script_start, ">") orelse break;
        const block_end = std.mem.indexOfPos(u8, html, block_start, "</script>") orelse break;
        const script_content = html[block_start + 1 .. block_end];
        pos = block_end + 9;

        // Strategy 1: known JS variable assignments that hold the current-page image URL.
        // Broader list covers historical and current fanfox.net JS variable names.
        const img_var_patterns = [_][]const u8{
            "imageurl=\"",
            "imageurl = \"",
            "imageurl='",
            "imageurl = '",
            "var imageurl=\"",
            "var imageurl = \"",
            "chapimg_current=\"",
            "chapimg_current = \"",
            "chapimg_current='",
            "curImage=\"",
            "curImage = \"",
            "curImage='",
            "img_url=\"",
            "img_url = \"",
            "img_url='",
            "\"imageurl\":\"",
            "'imageurl':'",
        };
        for (img_var_patterns) |vp| {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, script_content, search, vp)) |vpos| {
                const val_start = vpos + vp.len;
                const quote = vp[vp.len - 1];
                const val_end = std.mem.indexOfScalarPos(u8, script_content, val_start, quote) orelse {
                    search = vpos + 1;
                    continue;
                };
                const raw_url = script_content[val_start..val_end];
                if (raw_url.len > 4 and !isPlaceholderUrl(raw_url)) {
                    return try normalizeImageUrl(allocator, raw_url);
                }
                search = vpos + 1;
            }
        }

        // Strategy 2: any quoted CDN URL string in the script, skipping placeholders.
        for (cdn_hosts) |cdn| {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, script_content, search, cdn)) |cdn_pos| {
                const raw = extractQuotedStringAround(script_content, cdn_pos);
                if (raw) |r| {
                    if (!isPlaceholderUrl(r)) {
                        return try normalizeImageUrl(allocator, r);
                    }
                }
                search = cdn_pos + cdn.len;
            }
        }
    }

    // --- Strategy 3: <img> tag with reader-related id/class ---
    pos = 0;
    while (std.mem.indexOfPos(u8, html, pos, "<img")) |img_start| {
        const tag_end = std.mem.indexOfPos(u8, html, img_start, ">") orelse break;
        const tag = html[img_start..tag_end];
        pos = tag_end + 1;

        const reader_hints = [_][]const u8{ "id=\"image\"", "id='image'", "class=\"reader", "manga-page", "chapter-img" };
        var is_reader = false;
        for (reader_hints) |hint| {
            if (std.mem.indexOf(u8, tag, hint) != null) {
                is_reader = true;
                break;
            }
        }
        if (!is_reader) {
            for (cdn_hosts) |cdn| {
                if (std.mem.indexOf(u8, tag, cdn) != null) {
                    is_reader = true;
                    break;
                }
            }
        }
        if (!is_reader) continue;

        const src = extractAttrValue(tag, "src") orelse continue;
        if (isPlaceholderUrl(src)) continue; // skip default placeholder img src
        return try normalizeImageUrl(allocator, src);
    }

    return null;
}

/// Return true if `url` looks like a known CDN placeholder / anti-hotlink image.
fn isPlaceholderUrl(url: []const u8) bool {
    const placeholders = [_][]const u8{
        "down.png",
        "down.gif",
        "loading.gif",
        "transparent.gif",
        "placeholder",
        "/default.",
        "no_image",
        "noimage",
    };
    for (placeholders) |p| {
        if (std.mem.indexOf(u8, url, p) != null) return true;
    }
    return false;
}

/// Build the page URL for a given chapter and page number.
/// fanfox.net chapter URLs look like: https://fanfox.net/manga/{slug}/c{N}/1.html
/// So page 2 → .../2.html
pub fn buildPageUrl(allocator: std.mem.Allocator, chapter_url: []const u8, page: usize) ![]u8 {
    // chapter_url ends with "1.html" — replace the leading digits before ".html"
    const html_ext = ".html";
    const ext_pos = std.mem.lastIndexOf(u8, chapter_url, html_ext) orelse
        return std.fmt.allocPrint(allocator, "{s}/{d}.html", .{ chapter_url, page });

    // Find last '/' before the page number
    const path_to_ext = chapter_url[0..ext_pos];
    const slash_pos = std.mem.lastIndexOf(u8, path_to_ext, "/") orelse 0;
    const base = chapter_url[0 .. slash_pos + 1];
    return std.fmt.allocPrint(allocator, "{s}{d}.html", .{ base, page });
}

/// Main entry point: download all (or filtered) chapters of a fanfox.net manga.
pub fn run(allocator: std.mem.Allocator, opts: cli_mod.Options) !u8 {
    const url = opts.url orelse return 1;

    const slug = extractSlug(url) orelse {
        printErr("Could not extract manga slug from URL: {s}", .{url});
        return 1;
    };

    // Validate slug to prevent path traversal attacks
    if (!isValidSlug(slug)) {
        printErr("Invalid manga slug in URL: {s}", .{slug});
        return 1;
    }

    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;

    try w.print("MangaFox downloader\n", .{});
    try w.print("  Manga: {s}\n", .{slug});
    try w.print("  URL:   {s}\n", .{url});
    if (opts.chapters_from != null or opts.chapters_to != null) {
        const f = opts.chapters_from orelse 0.0;
        const t = opts.chapters_to orelse std.math.floatMax(f32);
        try w.print("  Chapters: {d} – {d}\n", .{ f, t });
    } else {
        try w.print("  Chapters: all\n", .{});
    }
    try w.print("  Output: {s}/{s}/\n\n", .{ opts.output_dir, slug });
    try w.flush();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const fetch_opts = http_mod.FetchOptions{
        .timeout_ms = opts.timeout_ms,
        .user_agent = user_agent,
    };

    // 1. Try RSS feed first — bypasses JavaScript-rendered chapter lists
    const rss_url = try std.fmt.allocPrint(allocator, "https://fanfox.net/rss/{s}.xml", .{slug});
    defer allocator.free(rss_url);

    if (opts.verbose) {
        try w.print("Fetching chapter list via RSS: {s}\n", .{rss_url});
        try w.flush();
    }

    var rss_chapters: []MangafoxChapter = &.{};
    if (http_mod.fetch(&client, allocator, rss_url, fetch_opts)) |rss_resp_val| {
        var rss_resp = rss_resp_val;
        defer rss_resp.deinit();
        if (rss_resp.isSuccess()) {
            rss_chapters = parseChapterListFromRss(allocator, rss_resp.body, slug, opts.verbose) catch &.{};
        }
    } else |_| {}

    // 2. Fall back to HTML parsing if RSS returned nothing
    var html_chapters: []MangafoxChapter = &.{};
    var index_resp_opt: ?http_mod.Response = null;
    defer if (index_resp_opt) |*r| r.deinit();

    if (rss_chapters.len == 0) {
        if (opts.verbose) {
            try w.print("RSS empty or unavailable, falling back to HTML parsing.\n", .{});
            try w.print("Fetching chapter list from {s}\n", .{url});
            try w.flush();
        }

        var index_resp = http_mod.fetch(&client, allocator, url, fetch_opts) catch |err| {
            printErr("Failed to fetch manga page: {s}", .{@errorName(err)});
            return 1;
        };
        index_resp_opt = index_resp;

        if (!index_resp.isSuccess()) {
            printErr("Manga page returned HTTP {d}", .{index_resp.status});
            return 1;
        }

        html_chapters = parseChapterList(allocator, index_resp.body, slug, url, opts.verbose) catch |err| {
            printErr("Failed to parse chapter list: {s}", .{@errorName(err)});
            return 1;
        };
    } else if (opts.verbose) {
        try w.print("RSS: found {d} chapter(s).\n", .{rss_chapters.len});
        try w.flush();
    }

    // 2b. Always fetch manga page for metadata (even if RSS succeeded)
    if (opts.verbose) {
        try w.print("Fetching manga page for metadata: {s}\n", .{url});
        try w.flush();
    }

    var metadata_resp = http_mod.fetch(&client, allocator, url, fetch_opts) catch null;
    defer if (metadata_resp) |*r| r.deinit();

    var manga_metadata: ?MangaMetadata = null;
    defer if (manga_metadata) |*m| m.deinit(allocator);

    if (metadata_resp) |*resp| {
        if (resp.isSuccess()) {
            manga_metadata = parseMangaMetadata(allocator, resp.body, slug) catch null;
        }
    }

    // Best-effort metadata writing. Retain the parsed metadata in-memory for later use
    // (e.g., generating HTML) and optionally write it to disk.
    if (manga_metadata) |*meta| {
        if (opts.write_metadata) {
            // Compute metadata file path and write best-effort. Errors shouldn't abort the
            // main run; they are reported and ignored.
            const meta_path = metadataFilePath(allocator, opts.output_dir, slug) catch |err| blk: {
                try w.print("Warning: failed to compute metadata path: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            if (meta_path) |path| {
                defer allocator.free(path);

                const jb = writeMetadataJson(allocator, meta) catch |err| blk: {
                    try w.print("Warning: failed to serialize metadata for {s}: {s}\n", .{ slug, @errorName(err) });
                    break :blk null;
                };

                if (jb) |json_buf| {
                    defer allocator.free(json_buf);

                    const cwd = std.fs.cwd();
                    const meta_dir = std.fs.path.dirname(path) orelse opts.output_dir;
                    cwd.makePath(meta_dir) catch |err| {
                        if (err != error.PathAlreadyExists) {
                            try w.print("Warning: could not create metadata directory {s}: {s}\n", .{ meta_dir, @errorName(err) });
                        }
                    };

                    const temp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch |err| blk: {
                        try w.print("Warning: failed to compute temporary metadata path: {s}\n", .{@errorName(err)});
                        break :blk null;
                    };

                    if (temp_path) |t_path| {
                        defer allocator.free(t_path);

                        const f_opt = cwd.createFile(t_path, .{ .truncate = true }) catch |err| blk: {
                            try w.print("Warning: could not create temporary metadata file {s}: {s}\n", .{ t_path, @errorName(err) });
                            break :blk null;
                        };

                        if (f_opt) |file| {
                            var write_success = true;
                            file.writeAll(json_buf) catch |err| {
                                try w.print("Warning: failed to write temporary metadata file {s}: {s}\n", .{ t_path, @errorName(err) });
                                write_success = false;
                            };
                            file.close();

                            if (write_success) {
                                cwd.rename(t_path, path) catch |err| {
                                    try w.print("Warning: failed to move temporary metadata file to {s}: {s}\n", .{ path, @errorName(err) });
                                };
                            } else {
                                // Best-effort cleanup of partial temp file
                                cwd.deleteFile(t_path) catch {};
                            }
                        }
                    }
                }
            }
        }
        if (opts.verbose) {
            try w.print("  Parsed metadata: {s}\n", .{meta.title});
            try w.flush();
        }
    }

    const all_chapters = if (rss_chapters.len > 0) rss_chapters else html_chapters;
    defer {
        for (all_chapters) |ch| {
            allocator.free(ch.number);
            allocator.free(ch.url);
        }
        allocator.free(all_chapters);
    }

    if (all_chapters.len == 0) {
        try w.print("No chapters found at {s}\n", .{url});
        try w.flush();
        return 0;
    }

    try w.print("Found {d} chapter(s).\n", .{all_chapters.len});
    try w.flush();

    // 3. Filter by chapter range
    const filtered = try filterChapters(allocator, all_chapters, opts.chapters_from, opts.chapters_to);
    defer allocator.free(filtered); // elements are borrowed from all_chapters

    if (filtered.len == 0) {
        try w.print("No chapters match the specified range.\n", .{});
        try w.flush();
        return 0;
    }

    // 4. Sort chapters numerically (handles both integers and decimals like 5.5, 100.1)
    const chapters = try sortChapters(allocator, filtered);
    defer allocator.free(chapters); // sorted slice, elements still borrowed from all_chapters

    if (opts.verbose) {
        try w.print("Chapter order after sorting:\n", .{});
        for (chapters) |ch| {
            try w.print("  {s}\n", .{ch.number});
        }
        try w.flush();
    }

    try w.print("Downloading {d} chapter(s).\n\n", .{chapters.len});
    try w.flush();

    var total_downloaded: usize = 0;
    var total_failed: usize = 0;

    // 4. Process each chapter
    for (chapters) |chapter| {
        if (opts.verbose) {
            try w.print("Chapter {s} — {s}\n", .{ chapter.number, chapter.url });
            try w.flush();
        }

        // Fetch page 1 to determine total pages
        var page1_resp = http_mod.fetch(&client, allocator, chapter.url, fetch_opts) catch |err| {
            printErr("Failed to fetch chapter {s}: {s}", .{ chapter.number, @errorName(err) });
            total_failed += 1;
            continue;
        };
        defer page1_resp.deinit();

        if (!page1_resp.isSuccess()) {
            printErr("Chapter {s} returned HTTP {d}", .{ chapter.number, page1_resp.status });
            total_failed += 1;
            continue;
        }

        var page_count = parsePageCount(page1_resp.body);
        const probe_mode = page_count == 0;
        if (page_count == 0) page_count = 100; // upper bound for probe mode

        // Extract the chapter ID needed to call the chapterfun.ashx image API
        const chapter_id = extractChapterId(page1_resp.body) orelse {
            printErr("Chapter {s}: chapterid not found in page HTML", .{chapter.number});
            total_failed += 1;
            continue;
        };

        // Create chapter output directory: {output_dir}/{slug}/{chapter.number}/
        var dir_buf: [1024]u8 = undefined;
        const chapter_dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}/{s}", .{
            opts.output_dir,
            slug,
            chapter.number,
        }) catch continue;

        const cwd = std.fs.cwd();
        cwd.makePath(chapter_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                printErr("Cannot create directory {s}: {s}", .{ chapter_dir, @errorName(err) });
                continue;
            },
        };
        var out_dir = cwd.openDir(chapter_dir, .{}) catch continue;
        defer out_dir.close();

        var page: usize = 1;
        var saved_count: usize = 0;
        while (page <= page_count) : (page += 1) {
            // Call the chapterfun.ashx API to get the real CDN image URL
            const img_url = (fetchChapterfunImageUrl(
                allocator,
                &client,
                chapter.url,
                chapter_id,
                page,
                fetch_opts,
            ) catch null) orelse {
                if (probe_mode and page > 1) break;
                if (opts.verbose) {
                    var pb: [256]u8 = undefined;
                    var pfw = std.fs.File.stderr().writer(&pb);
                    pfw.interface.print("  [ch {s}] page {d}: no image URL from API\n", .{ chapter.number, page }) catch {};
                    pfw.interface.flush() catch {};
                }
                total_failed += 1;
                continue;
            };
            defer allocator.free(img_url);

            if (opts.verbose) {
                try w.print("  [ch {s}] page {d}: {s}\n", .{ chapter.number, page, img_url });
                try w.flush();
            }

            // Build page URL for the Referer header when downloading the image
            const current_page_url = if (page == 1)
                try allocator.dupe(u8, chapter.url)
            else
                buildPageUrl(allocator, chapter.url, page) catch continue;
            defer allocator.free(current_page_url);

            // Determine extension
            const ext = getExtension(img_url) orelse ".jpg";

            // Download the image with Referer to satisfy CDN anti-hotlink check
            const img_fetch_opts = http_mod.FetchOptions{
                .timeout_ms = opts.timeout_ms,
                .user_agent = user_agent,
                .extra_headers = &.{
                    .{ .name = "Referer", .value = current_page_url },
                    .{ .name = "Accept", .value = "image/webp,image/apng,image/*,*/*;q=0.8" },
                },
            };
            var img_resp = http_mod.fetch(&client, allocator, img_url, img_fetch_opts) catch |err| {
                if (opts.verbose) {
                    var pb: [512]u8 = undefined;
                    var pfw = std.fs.File.stderr().writer(&pb);
                    pfw.interface.print("  [ch {s}] page {d}: download failed ({s})\n", .{ chapter.number, page, @errorName(err) }) catch {};
                    pfw.interface.flush() catch {};
                }
                total_failed += 1;
                continue;
            };
            defer img_resp.deinit();

            if (!img_resp.isSuccess()) {
                total_failed += 1;
                continue;
            }

            // Save: {page:0>3}.ext  e.g. 001.jpg
            var name_buf: [32]u8 = undefined;
            const filename = std.fmt.bufPrint(&name_buf, "{d:0>3}{s}", .{ page, ext }) catch continue;

            out_dir.writeFile(.{ .sub_path = filename, .data = img_resp.body }) catch |err| {
                printErr("Failed to save {s}/{s}: {s}", .{ chapter_dir, filename, @errorName(err) });
                total_failed += 1;
                continue;
            };

            total_downloaded += 1;
            saved_count += 1;

            if (!opts.verbose) {
                try w.print("  Saved {s}/{s}\n", .{ chapter_dir, filename });
                try w.flush();
            }

            // Delay between page requests
            if (opts.delay_ms > 0) {
                std.Thread.sleep(@as(u64, opts.delay_ms) * std.time.ns_per_ms);
            }
        }

        try w.print("  Chapter {s}: {d} page(s) saved.\n", .{ chapter.number, saved_count });
        try w.flush();

        // Delay between chapters
        if (opts.delay_ms > 0) {
            std.Thread.sleep(@as(u64, opts.delay_ms) * std.time.ns_per_ms);
        }
    }

    try w.print("\nDone. Downloaded: {d}  Failed: {d}\n", .{ total_downloaded, total_failed });

    const browser_summary = try image_browser_mod.generate(
        allocator,
        opts.output_dir,
    );
    try w.print("HTML browser:\n", .{});
    try w.print("  Landing page:   {s}/{s}\n", .{ opts.output_dir, image_browser_mod.root_page_name });
    try w.print("  Folder pages:   {d}\n", .{browser_summary.directories});
    try w.print("  Reader pages:   {d}\n", .{browser_summary.reader_pages});
    try w.print("  Indexed images: {d}\n", .{browser_summary.images});
    try w.flush();

    return 0;
}

// ── Internal helpers ─────────────────────────────────────────────────────

fn getOrigin(url_str: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url_str, "://")) |after_scheme| {
        const start = after_scheme + 3;
        const rest = url_str[start..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse rest.len;
        return url_str[0 .. start + slash];
    }
    return url_str;
}

fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') {
            dots += 1;
            if (dots > 1) return false;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }
    return true;
}

fn getExtension(url_str: []const u8) ?[]const u8 {
    // Strip query string / fragment
    var end = url_str.len;
    if (std.mem.indexOf(u8, url_str, "?")) |q| end = @min(end, q);
    if (std.mem.indexOf(u8, url_str, "#")) |f| end = @min(end, f);
    const path = url_str[0..end];
    if (std.mem.lastIndexOf(u8, path, ".")) |dot| {
        const ext = path[dot..];
        if (ext.len >= 2 and ext.len <= 5) return ext;
    }
    return null;
}

/// Normalize a potentially protocol-relative URL (e.g. "//cdn.host/img.jpg" → "https://cdn.host/img.jpg").
fn normalizeImageUrl(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, raw, "//")) {
        return std.fmt.allocPrint(allocator, "https:{s}", .{raw});
    }
    return allocator.dupe(u8, raw);
}

/// Find a quoted string in `content` that contains the substring starting at `needle_pos`.
fn extractQuotedStringAround(content: []const u8, needle_pos: usize) ?[]const u8 {
    // Walk backward to find opening quote
    var i: usize = needle_pos;
    while (i > 0) {
        i -= 1;
        if (content[i] == '"' or content[i] == '\'') {
            const q = content[i];
            const val_start = i + 1;
            if (std.mem.indexOfScalarPos(u8, content, val_start, q)) |val_end| {
                return content[val_start..val_end];
            }
            return null;
        }
    }
    return null;
}

/// Extract value of a named attribute from tag content (between < and >).
fn extractAttrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    // Try attr="value"
    const pat_dq = std.fmt.bufPrint(&needle_buf, "{s}=\"", .{attr}) catch return null;
    if (std.mem.indexOf(u8, tag, pat_dq)) |p| {
        const val_start = p + pat_dq.len;
        const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '"') orelse return null;
        return tag[val_start..val_end];
    }
    // Try attr='value'
    var needle_buf2: [64]u8 = undefined;
    const pat_sq = std.fmt.bufPrint(&needle_buf2, "{s}='", .{attr}) catch return null;
    if (std.mem.indexOf(u8, tag, pat_sq)) |p| {
        const val_start = p + pat_sq.len;
        const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '\'') orelse return null;
        return tag[val_start..val_end];
    }
    return null;
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stderr().writer(&buf);
    fw.interface.print("error: " ++ fmt ++ "\n", args) catch {};
    fw.interface.flush() catch {};
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Parse a word token as a base-N number (Dean Edwards packer encoding).
fn parseBaseN(base: u32, word: []const u8) !u64 {
    if (word.len == 0) return error.Empty;
    var result: u64 = 0;
    for (word) |c| {
        const digit: u64 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'z')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'Z')
            // packer uses String.fromCharCode(digit+29) for digits>35: reverse → digit = char-29
            @as(u64, c) - 29
        else
            return error.InvalidChar;
        if (digit >= base) return error.InvalidDigit;
        result = result * base + digit;
    }
    return result;
}

/// Decode a Dean Edwards packed JavaScript response (from chapterfun.ashx).
/// Extracts the CDN image URL for the requested page.
/// The response format: eval(function(p,a,c,k,e,d){...}('ENCODED',BASE,COUNT,'DICT'.split('|'),0,{}))
fn decodeChapterfunResponse(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    // Locate the arguments: }('ENCODED',BASE,COUNT,'DICT'.split('|'),...)
    const opener = "}('";
    const p_raw_start = (std.mem.indexOf(u8, body, opener) orelse return null) + opener.len;

    // Find end of p string (next unescaped single quote)
    var p_raw_end = p_raw_start;
    while (p_raw_end < body.len) {
        if (body[p_raw_end] == '\\') {
            p_raw_end += 2;
        } else if (body[p_raw_end] == '\'') {
            break;
        } else {
            p_raw_end += 1;
        }
    }
    if (p_raw_end >= body.len) return null;
    const p_encoded = body[p_raw_start..p_raw_end];

    // Parse base (first number after closing quote of p)
    var pos = p_raw_end + 1;
    while (pos < body.len and (body[pos] < '0' or body[pos] > '9')) pos += 1;
    const base_start = pos;
    while (pos < body.len and body[pos] >= '0' and body[pos] <= '9') pos += 1;
    const base = std.fmt.parseInt(u32, body[base_start..pos], 10) catch return null;

    // Skip count (second number)
    while (pos < body.len and (body[pos] < '0' or body[pos] > '9')) pos += 1;
    while (pos < body.len and body[pos] >= '0' and body[pos] <= '9') pos += 1;

    // Find k dictionary string (next '...' value)
    while (pos < body.len and body[pos] != '\'') pos += 1;
    if (pos >= body.len) return null;
    pos += 1;
    const k_start = pos;
    while (pos < body.len and body[pos] != '\'') pos += 1;
    if (pos >= body.len) return null;
    const k_string = body[k_start..pos];

    // Build k array by splitting on '|'
    var k_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer k_list.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, k_string, '|');
        while (it.next()) |entry| try k_list.append(allocator, entry);
    }

    // Decode p_encoded: replace each word token (base-N number) with k_list entry
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < p_encoded.len) {
        if (p_encoded[i] == '\\' and i + 1 < p_encoded.len) {
            const esc = p_encoded[i + 1];
            switch (esc) {
                '\'' => try result.append(allocator, '\''),
                '\\' => try result.append(allocator, '\\'),
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, esc);
                },
            }
            i += 2;
        } else if (isWordChar(p_encoded[i])) {
            const w_start = i;
            while (i < p_encoded.len and isWordChar(p_encoded[i])) i += 1;
            const word = p_encoded[w_start..i];
            if (parseBaseN(base, word)) |n| {
                if (n < k_list.items.len and k_list.items[n].len > 0) {
                    try result.appendSlice(allocator, k_list.items[n]);
                } else {
                    try result.appendSlice(allocator, word);
                }
            } else |_| {
                try result.appendSlice(allocator, word);
            }
        } else {
            try result.append(allocator, p_encoded[i]);
            i += 1;
        }
    }

    const decoded = result.items;

    // Extract pix="..." (CDN base URL, ends with '/')
    var pix_val: ?[]const u8 = null;
    const pix_needle = "pix=\"";
    if (std.mem.indexOf(u8, decoded, pix_needle)) |pp| {
        const vstart = pp + pix_needle.len;
        if (std.mem.indexOfScalarPos(u8, decoded, vstart, '"')) |vend| {
            pix_val = decoded[vstart..vend];
        }
    }

    // Extract first element of pvalue=[...] (image path + token)
    var pvalue_first: ?[]const u8 = null;
    const pval_needle = "pvalue=[\"";
    if (std.mem.indexOf(u8, decoded, pval_needle)) |pvp| {
        const vstart = pvp + pval_needle.len;
        if (std.mem.indexOfScalarPos(u8, decoded, vstart, '"')) |vend| {
            pvalue_first = decoded[vstart..vend];
        }
    }

    if (pix_val != null and pvalue_first != null) {
        // pix has no trailing '/', pvalue_first starts with '/' — concatenate directly
        return try std.fmt.allocPrint(allocator, "https:{s}{s}", .{ pix_val.?, pvalue_first.? });
    }

    return null;
}

/// Fetch the image URL for a given chapter page using the chapterfun.ashx API.
/// Returns an owned string (caller must free), or null if not found.
fn fetchChapterfunImageUrl(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    chapter_url: []const u8,
    chapter_id: []const u8,
    page: usize,
    base_opts: http_mod.FetchOptions,
) !?[]u8 {
    // Strip page filename to get the chapter directory URL
    const slash = std.mem.lastIndexOf(u8, chapter_url, "/") orelse chapter_url.len;
    const base_dir = chapter_url[0 .. slash + 1];

    const api_url = try std.fmt.allocPrint(
        allocator,
        "{s}chapterfun.ashx?cid={s}&page={d}&key=",
        .{ base_dir, chapter_id, page },
    );
    defer allocator.free(api_url);

    const api_opts = http_mod.FetchOptions{
        .timeout_ms = base_opts.timeout_ms,
        .user_agent = base_opts.user_agent,
        .extra_headers = &.{
            .{ .name = "Referer", .value = chapter_url },
            .{ .name = "X-Requested-With", .value = "XMLHttpRequest" },
        },
    };

    var resp = http_mod.fetch(client, allocator, api_url, api_opts) catch return null;
    defer resp.deinit();

    if (!resp.isSuccess()) return null;
    return try decodeChapterfunResponse(allocator, resp.body);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "extractSlug basic" {
    try std.testing.expectEqualStrings("naruto", extractSlug("https://fanfox.net/manga/naruto/").?);
    try std.testing.expectEqualStrings("one_piece", extractSlug("https://fanfox.net/manga/one_piece/").?);
    try std.testing.expectEqualStrings("naruto", extractSlug("https://fanfox.net/manga/naruto").?);
}

test "extractSlug no slug" {
    try std.testing.expect(extractSlug("https://fanfox.net/") == null);
    try std.testing.expect(extractSlug("https://example.com/page") == null);
}

test "isValidSlug valid" {
    try std.testing.expect(isValidSlug("naruto"));
    try std.testing.expect(isValidSlug("one_piece"));
    try std.testing.expect(isValidSlug("dragon-ball-z"));
    try std.testing.expect(isValidSlug("x"));
}

test "isValidSlug rejects dot-start" {
    try std.testing.expect(!isValidSlug("."));
    try std.testing.expect(!isValidSlug(".."));
    try std.testing.expect(!isValidSlug(".hidden"));
}

test "isValidSlug rejects path separators" {
    try std.testing.expect(!isValidSlug("a/b"));
    try std.testing.expect(!isValidSlug("a\\b"));
    try std.testing.expect(!isValidSlug("../escape"));
}

test "isValidSlug rejects empty" {
    try std.testing.expect(!isValidSlug(""));
}

test "parseChapterList" {
    const html =
        \\<ul class="detail-main-list">
        \\  <li><a href="/manga/naruto/v72/c700/1.html">Chapter 700</a></li>
        \\  <li><a href="/manga/naruto/c699/1.html">Chapter 699</a></li>
        \\  <li><a href="/manga/naruto/c5.5/1.html">Chapter 5.5</a></li>
        \\</ul>
    ;
    const chapters = try parseChapterList(std.testing.allocator, html, "naruto", "https://fanfox.net", false);
    defer {
        for (chapters) |ch| {
            std.testing.allocator.free(ch.number);
            std.testing.allocator.free(ch.url);
        }
        std.testing.allocator.free(chapters);
    }
    try std.testing.expect(chapters.len == 3);
    try std.testing.expectEqualStrings("700", chapters[0].number);
    try std.testing.expectEqualStrings("https://fanfox.net/manga/naruto/v72/c700/1.html", chapters[0].url);
    try std.testing.expectEqualStrings("699", chapters[1].number);
    try std.testing.expectEqualStrings("https://fanfox.net/manga/naruto/c699/1.html", chapters[1].url);
    try std.testing.expectEqualStrings("5.5", chapters[2].number);
}

test "parseChapterListFromRss basic" {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<rss version="2.0"><channel>
        \\<link>https://fanfox.net/</link>
        \\<item><title>Naruto Ch.700</title><link>https://fanfox.net/manga/naruto/c700/1.html</link></item>
        \\<item><title>Naruto Ch.699</title><link>https://fanfox.net/manga/naruto/c699/1.html</link></item>
        \\<item><title>Naruto Ch.5.5</title><link>https://fanfox.net/manga/naruto/c5.5/1.html</link></item>
        \\</channel></rss>
    ;
    const chapters = try parseChapterListFromRss(std.testing.allocator, xml, "naruto", false);
    defer {
        for (chapters) |ch| {
            std.testing.allocator.free(ch.number);
            std.testing.allocator.free(ch.url);
        }
        std.testing.allocator.free(chapters);
    }
    try std.testing.expect(chapters.len == 3);
    try std.testing.expectEqualStrings("700", chapters[0].number);
    try std.testing.expectEqualStrings("https://fanfox.net/manga/naruto/c700/1.html", chapters[0].url);
    try std.testing.expectEqualStrings("699", chapters[1].number);
    try std.testing.expectEqualStrings("5.5", chapters[2].number);
}

test "parseChapterListFromRss filters non-chapter links" {
    // Channel-level <link> and image <link> should not appear in results
    const xml =
        \\<rss><channel>
        \\<link>https://fanfox.net/</link>
        \\<image><link>https://fanfox.net/</link></image>
        \\<item><title>Seventh Ch.001</title><link>https://fanfox.net/manga/seventh/c001/1.html</link></item>
        \\<item><title>Seventh Ch.002</title><link>https://fanfox.net/manga/seventh/c002/1.html</link></item>
        \\</channel></rss>
    ;
    const chapters = try parseChapterListFromRss(std.testing.allocator, xml, "seventh", false);
    defer {
        for (chapters) |ch| {
            std.testing.allocator.free(ch.number);
            std.testing.allocator.free(ch.url);
        }
        std.testing.allocator.free(chapters);
    }
    try std.testing.expect(chapters.len == 2);
    try std.testing.expectEqualStrings("001", chapters[0].number);
    try std.testing.expectEqualStrings("002", chapters[1].number);
}

test "parseChapterListFromRss deduplicates" {
    const xml =
        \\<rss><channel>
        \\<item><link>https://fanfox.net/manga/naruto/c100/1.html</link></item>
        \\<item><link>https://fanfox.net/manga/naruto/c100/1.html</link></item>
        \\<item><link>https://fanfox.net/manga/naruto/c101/1.html</link></item>
        \\</channel></rss>
    ;
    const chapters = try parseChapterListFromRss(std.testing.allocator, xml, "naruto", false);
    defer {
        for (chapters) |ch| {
            std.testing.allocator.free(ch.number);
            std.testing.allocator.free(ch.url);
        }
        std.testing.allocator.free(chapters);
    }
    try std.testing.expect(chapters.len == 2);
}

test "parseChapterListFromRss empty feed" {
    const xml = "<?xml version=\"1.0\"?><rss><channel></channel></rss>";
    const chapters = try parseChapterListFromRss(std.testing.allocator, xml, "naruto", false);
    defer std.testing.allocator.free(chapters);
    try std.testing.expect(chapters.len == 0);
}

test "parseChapterListFromRss wrong slug filtered" {
    // Links for a different manga should not match
    const xml =
        \\<rss><channel>
        \\<item><link>https://fanfox.net/manga/bleach/c700/1.html</link></item>
        \\</channel></rss>
    ;
    const chapters = try parseChapterListFromRss(std.testing.allocator, xml, "naruto", false);
    defer std.testing.allocator.free(chapters);
    try std.testing.expect(chapters.len == 0);
}

test "filterChapters range" {
    const allocator = std.testing.allocator;
    const chapters = [_]MangafoxChapter{
        .{ .number = "1", .url = "u1" },
        .{ .number = "5", .url = "u5" },
        .{ .number = "5.5", .url = "u5.5" },
        .{ .number = "10", .url = "u10" },
        .{ .number = "20", .url = "u20" },
    };
    const filtered = try filterChapters(allocator, &chapters, 5.0, 10.0);
    defer allocator.free(filtered);
    try std.testing.expect(filtered.len == 3);
    try std.testing.expectEqualStrings("5", filtered[0].number);
    try std.testing.expectEqualStrings("5.5", filtered[1].number);
    try std.testing.expectEqualStrings("10", filtered[2].number);
}

test "filterChapters no range" {
    const allocator = std.testing.allocator;
    const chapters = [_]MangafoxChapter{
        .{ .number = "1", .url = "u1" },
        .{ .number = "2", .url = "u2" },
    };
    const filtered = try filterChapters(allocator, &chapters, null, null);
    defer allocator.free(filtered);
    try std.testing.expect(filtered.len == 2);
}

test "sortChapters numeric order" {
    const allocator = std.testing.allocator;
    const chapters = [_]MangafoxChapter{
        .{ .number = "10", .url = "u10" },
        .{ .number = "1", .url = "u1" },
        .{ .number = "2", .url = "u2" },
        .{ .number = "100", .url = "u100" },
        .{ .number = "5", .url = "u5" },
    };
    const sorted = try sortChapters(allocator, &chapters);
    defer allocator.free(sorted);
    try std.testing.expect(sorted.len == 5);
    try std.testing.expectEqualStrings("1", sorted[0].number);
    try std.testing.expectEqualStrings("2", sorted[1].number);
    try std.testing.expectEqualStrings("5", sorted[2].number);
    try std.testing.expectEqualStrings("10", sorted[3].number);
    try std.testing.expectEqualStrings("100", sorted[4].number);
}

test "sortChapters with decimals" {
    const allocator = std.testing.allocator;
    const chapters = [_]MangafoxChapter{
        .{ .number = "5", .url = "u5" },
        .{ .number = "5.5", .url = "u5.5" },
        .{ .number = "6", .url = "u6" },
        .{ .number = "5.1", .url = "u5.1" },
        .{ .number = "1", .url = "u1" },
    };
    const sorted = try sortChapters(allocator, &chapters);
    defer allocator.free(sorted);
    try std.testing.expect(sorted.len == 5);
    try std.testing.expectEqualStrings("1", sorted[0].number);
    try std.testing.expectEqualStrings("5", sorted[1].number);
    try std.testing.expectEqualStrings("5.1", sorted[2].number);
    try std.testing.expectEqualStrings("5.5", sorted[3].number);
    try std.testing.expectEqualStrings("6", sorted[4].number);
}

test "sortChapters already sorted" {
    const allocator = std.testing.allocator;
    const chapters = [_]MangafoxChapter{
        .{ .number = "1", .url = "u1" },
        .{ .number = "2", .url = "u2" },
        .{ .number = "3", .url = "u3" },
    };
    const sorted = try sortChapters(allocator, &chapters);
    defer allocator.free(sorted);
    try std.testing.expect(sorted.len == 3);
    try std.testing.expectEqualStrings("1", sorted[0].number);
    try std.testing.expectEqualStrings("2", sorted[1].number);
    try std.testing.expectEqualStrings("3", sorted[2].number);
}

test "sortChapters empty" {
    const allocator = std.testing.allocator;
    const chapters = [_]MangafoxChapter{};
    const sorted = try sortChapters(allocator, &chapters);
    defer allocator.free(sorted);
    try std.testing.expect(sorted.len == 0);
}

test "parseChapterList without trailing slash" {
    const html =
        \\<ul>
        \\  <li><a href="/manga/naruto/c100.html">Chapter 100</a></li>
        \\  <li><a href="/manga/naruto/c99.html">Chapter 99</a></li>
        \\  <li><a href="/manga/naruto/c10.5.html">Chapter 10.5</a></li>
        \\</ul>
    ;
    const chapters = try parseChapterList(std.testing.allocator, html, "naruto", "https://fanfox.net", false);
    defer {
        for (chapters) |ch| {
            std.testing.allocator.free(ch.number);
            std.testing.allocator.free(ch.url);
        }
        std.testing.allocator.free(chapters);
    }
    try std.testing.expect(chapters.len == 3);
    try std.testing.expectEqualStrings("100", chapters[0].number);
    try std.testing.expectEqualStrings("99", chapters[1].number);
    try std.testing.expectEqualStrings("10.5", chapters[2].number);
}

test "parsePageCount var pcount" {
    const html = "<script>var pcount=18;</script>";
    try std.testing.expect(parsePageCount(html) == 18);
}

test "parsePageCount with spaces" {
    const html = "<script>var pcount = 24;</script>";
    try std.testing.expect(parsePageCount(html) == 24);
}

test "parsePageCount not found" {
    try std.testing.expect(parsePageCount("<html><body>nothing here</body></html>") == 0);
}

test "extractImageUrl from imageurl var" {
    const html =
        \\<script type="text/javascript">
        \\var imageurl="//img.mghcdn.com/manga/naruto/1/001.jpg";
        \\</script>
    ;
    const url = try extractImageUrl(std.testing.allocator, html);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://img.mghcdn.com/manga/naruto/1/001.jpg", url.?);
}

test "extractImageUrl from img tag with id=image" {
    const html =
        \\<html><body>
        \\<img id="image" src="//img.mghcdn.com/manga/naruto/1/002.jpg" />
        \\</body></html>
    ;
    const url = try extractImageUrl(std.testing.allocator, html);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://img.mghcdn.com/manga/naruto/1/002.jpg", url.?);
}

test "extractImageUrl none found" {
    const html = "<html><body><p>no images here</p></body></html>";
    const url = try extractImageUrl(std.testing.allocator, html);
    try std.testing.expect(url == null);
}

test "extractImageUrl skips placeholder in img tag" {
    // down.png is the fanfox.net anti-hotlink placeholder — should be skipped
    const html =
        \\<img id="image" src="//img.mghcdn.com/down.png" />
    ;
    const url = try extractImageUrl(std.testing.allocator, html);
    try std.testing.expect(url == null);
}

test "extractImageUrl skips placeholder in script, finds real URL" {
    const html =
        \\<script>
        \\var defaultImg="//img.mghcdn.com/down.png";
        \\var imageurl="//img.mghcdn.com/manga/naruto/1/1/001.jpg";
        \\</script>
    ;
    const url = try extractImageUrl(std.testing.allocator, html);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://img.mghcdn.com/manga/naruto/1/1/001.jpg", url.?);
}

test "extractImageUrl curImage variable" {
    const html =
        \\<script>var curImage="//img.mghcdn.com/manga/naruto/1/1/003.jpg";</script>
    ;
    const url = try extractImageUrl(std.testing.allocator, html);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://img.mghcdn.com/manga/naruto/1/1/003.jpg", url.?);
}

test "buildPageUrl" {
    const url = try buildPageUrl(std.testing.allocator, "https://fanfox.net/manga/naruto/c700/1.html", 5);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://fanfox.net/manga/naruto/c700/5.html", url);
}

test "looksLikeNumber" {
    try std.testing.expect(looksLikeNumber("1"));
    try std.testing.expect(looksLikeNumber("700"));
    try std.testing.expect(looksLikeNumber("5.5"));
    try std.testing.expect(!looksLikeNumber("abc"));
    try std.testing.expect(!looksLikeNumber(""));
    try std.testing.expect(!looksLikeNumber("1.2.3"));
}

test "getExtension" {
    try std.testing.expectEqualStrings(".jpg", getExtension("https://cdn.com/img.jpg").?);
    try std.testing.expectEqualStrings(".png", getExtension("https://cdn.com/img.png?v=1").?);
    try std.testing.expect(getExtension("https://cdn.com/page") == null);
}

test "parsePageCount imagecount" {
    try std.testing.expect(parsePageCount("<script>var imagecount=54;</script>") == 54);
    try std.testing.expect(parsePageCount("<script>var imagecount = 12;</script>") == 12);
}

test "extractChapterId" {
    try std.testing.expectEqualStrings("15584", extractChapterId("var chapterid=15584;").?);
    try std.testing.expectEqualStrings("42", extractChapterId("var chapterid = 42;").?);
    try std.testing.expect(extractChapterId("<html>no chapter id here</html>") == null);
}

test "parseBaseN" {
    try std.testing.expectEqual(@as(u64, 0), try parseBaseN(31, "0"));
    try std.testing.expectEqual(@as(u64, 9), try parseBaseN(31, "9"));
    try std.testing.expectEqual(@as(u64, 10), try parseBaseN(31, "a"));
    try std.testing.expectEqual(@as(u64, 29), try parseBaseN(31, "t"));
    try std.testing.expectEqual(@as(u64, 16), try parseBaseN(31, "g"));
}

test "decodeChapterfunResponse" {
    // Real response from fanfox.net chapterfun.ashx for naruto chapter 1, page 1
    const body =
        \\eval(function(p,a,c,k,e,d){e=function(c){return(c<a?"":e(parseInt(c/a)))+((c=c%a)>35?String.fromCharCode(c+29):c.toString(36))};if(!''.replace(/^/,String)){while(c--)d[e(c)]=k[c]||e(c);k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1;};while(c--)if(k[c])p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c]);return p;}('t g(){2 j="//9.7.b/f/6/8/4-5.0/c";2 1=["/l.e?h=o&3=a","/n.e?h=m&3=a"];k(2 i=0;i<1.s;i++){u(i==0){1[i]="//9.7.b/f/6/8/4-5.0/c"+1[i];p}1[i]=j+1[i]}q 1}2 d;d=g();r=0;',31,31,'|pvalue|var|ttl|01|001|manga|mangafox||zjcdn|1772553600|me|compressed||jpg|store|dm5imagefun|token||pix|for|naruto_v01|ac17c7023e740cb461f6b501b8b1570301f10604|naruto_v01_ch001_005|4d09af0539a721ed19697ef3b0a964e3324cf4f0|continue|return|currentimageid|length|function|if'.split('|'),0,{}))
    ;
    const url = try decodeChapterfunResponse(std.testing.allocator, body);
    defer if (url) |u| std.testing.allocator.free(u);
    try std.testing.expect(url != null);
    // Should contain the zjcdn CDN host, the filename, and the token hash
    try std.testing.expect(std.mem.indexOf(u8, url.?, "zjcdn.mangafox.me") != null);
    try std.testing.expect(std.mem.indexOf(u8, url.?, "compressed/naruto_v01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, url.?, "4d09af0539a721ed19697ef3b0a964e3324cf4f0") != null);
}
