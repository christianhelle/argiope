const std = @import("std");
const http_mod = @import("http.zig");
const cli_mod = @import("cli.zig");

/// Browser-like User-Agent so CDNs don't reject us as a bot.
const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

/// A discovered chapter: its display number string and the URL of page 1.
pub const MangafoxChapter = struct {
    number: []const u8, // e.g. "1", "5.5"
    url: []const u8, // absolute URL to page 1 of the chapter
};

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
pub fn parseChapterList(
    allocator: std.mem.Allocator,
    html: []const u8,
    slug: []const u8,
    base_url: []const u8,
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

    var pos: usize = 0;
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

        // Must contain our prefix
        if (std.mem.indexOf(u8, href, prefix) == null) continue;

        // Extract chapter number: look for /c{number} pattern
        // Accept both /c{N}/ and /c{N}.html formats (with or without trailing slash)
        const c_needle = "/c";
        const c_pos = std.mem.indexOf(u8, href, c_needle) orelse continue;
        const num_start = c_pos + c_needle.len;
        const rest = href[num_start..];
        
        // Find the end of the chapter number
        // First check if there's a slash, question mark, or hash (standard path separators)
        const sep_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        
        // If no separator was found, check for .html extension
        var num_end = sep_end;
        if (sep_end == rest.len) {
            if (std.mem.indexOf(u8, rest, ".html")) |html_pos| {
                num_end = html_pos;
            }
        }
        
        if (num_end == 0) continue;
        const number_str = rest[0..num_end];

        // Validate it looks like a number (digits and optional one dot)
        if (!looksLikeNumber(number_str)) continue;

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
            allocator.free(abs_url);
            allocator.free(number_copy);
            continue;
        }

        try chapters.append(allocator, MangafoxChapter{
            .number = number_copy,
            .url = abs_url,
        });
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

    // Create a mutable copy for sorting
    const sorted = try allocator.dupe(MangafoxChapter, chapters);
    errdefer allocator.free(sorted);

    // Sort using numeric comparison of chapter numbers
    const Context = struct {
        pub fn lessThan(_: @This(), a: MangafoxChapter, b: MangafoxChapter) bool {
            const a_num = std.fmt.parseFloat(f32, a.number) catch return false;
            const b_num = std.fmt.parseFloat(f32, b.number) catch return true;
            return a_num < b_num;
        }
    };

    std.mem.sort(MangafoxChapter, sorted, Context{}, Context.lessThan);
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

    // 1. Fetch manga index page
    if (opts.verbose) {
        try w.print("Fetching chapter list from {s}\n", .{url});
        try w.flush();
    }

    var index_resp = http_mod.fetch(&client, allocator, url, fetch_opts) catch |err| {
        printErr("Failed to fetch manga page: {s}", .{@errorName(err)});
        return 1;
    };
    defer index_resp.deinit();

    if (!index_resp.isSuccess()) {
        printErr("Manga page returned HTTP {d}", .{index_resp.status});
        return 1;
    }

    // 2. Parse chapter list
    const all_chapters = parseChapterList(allocator, index_resp.body, slug, url) catch |err| {
        printErr("Failed to parse chapter list: {s}", .{@errorName(err)});
        return 1;
    };
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
    const chapters = try parseChapterList(std.testing.allocator, html, "naruto", "https://fanfox.net");
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
    const chapters = try parseChapterList(std.testing.allocator, html, "naruto", "https://fanfox.net");
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
