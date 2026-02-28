const std = @import("std");

pub const LinkType = enum {
    anchor,
    image,
};

pub const Link = struct {
    href: []const u8,
    link_type: LinkType,
};

/// Extract all links and image sources from an HTML document.
/// The returned slices borrow from the input `html` — do not free them individually.
/// Caller must free the returned slice itself.
pub fn extractLinks(allocator: std.mem.Allocator, html: []const u8) ![]Link {
    var links: std.ArrayListUnmanaged(Link) = .empty;
    errdefer links.deinit(allocator);

    var pos: usize = 0;
    while (pos < html.len) {
        // Find next '<'
        const tag_start = std.mem.indexOfPos(u8, html, pos, "<") orelse break;
        pos = tag_start + 1;
        if (pos >= html.len) break;

        // Skip comments
        if (pos + 2 < html.len and html[pos] == '!' and html[pos + 1] == '-' and html[pos + 2] == '-') {
            const comment_end = std.mem.indexOfPos(u8, html, pos, "-->") orelse break;
            pos = comment_end + 3;
            continue;
        }

        // Read tag name
        const tag_name_start = pos;
        while (pos < html.len and html[pos] != ' ' and html[pos] != '\t' and
            html[pos] != '\n' and html[pos] != '\r' and
            html[pos] != '>' and html[pos] != '/')
        {
            pos += 1;
        }
        const tag_name = html[tag_name_start..pos];

        // Determine what attribute we're looking for
        const attr_name: ?[]const u8 = blk: {
            if (asciiEqlIgnoreCase(tag_name, "a") or
                asciiEqlIgnoreCase(tag_name, "link") or
                asciiEqlIgnoreCase(tag_name, "area") or
                asciiEqlIgnoreCase(tag_name, "base"))
            {
                break :blk "href";
            }
            if (asciiEqlIgnoreCase(tag_name, "img") or
                asciiEqlIgnoreCase(tag_name, "script") or
                asciiEqlIgnoreCase(tag_name, "source") or
                asciiEqlIgnoreCase(tag_name, "iframe") or
                asciiEqlIgnoreCase(tag_name, "embed") or
                asciiEqlIgnoreCase(tag_name, "video") or
                asciiEqlIgnoreCase(tag_name, "audio"))
            {
                break :blk "src";
            }
            break :blk null;
        };

        if (attr_name == null) continue;

        const link_type: LinkType = if (asciiEqlIgnoreCase(tag_name, "img") or
            asciiEqlIgnoreCase(tag_name, "source") or
            asciiEqlIgnoreCase(tag_name, "video") or
            asciiEqlIgnoreCase(tag_name, "audio"))
            .image
        else
            .anchor;

        // Find the attribute value within this tag
        const tag_end = std.mem.indexOfPos(u8, html, pos, ">") orelse break;
        const tag_content = html[pos..tag_end];

        if (findAttributeValue(tag_content, attr_name.?)) |href| {
            // Skip empty, javascript:, mailto:, tel:, and data: URLs
            if (href.len > 0 and
                !std.mem.startsWith(u8, href, "javascript:") and
                !std.mem.startsWith(u8, href, "mailto:") and
                !std.mem.startsWith(u8, href, "tel:") and
                !std.mem.startsWith(u8, href, "data:") and
                !std.mem.startsWith(u8, href, "#"))
            {
                try links.append(allocator, Link{
                    .href = href,
                    .link_type = link_type,
                });
            }
        }

        // Also check for srcset on img tags
        if (asciiEqlIgnoreCase(tag_name, "img")) {
            if (findAttributeValue(tag_content, "srcset")) |srcset| {
                var it = std.mem.splitScalar(u8, srcset, ',');
                while (it.next()) |entry| {
                    const trimmed = std.mem.trim(u8, entry, " \t\n\r");
                    // srcset entries are "url [descriptor]"
                    const url_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
                    const img_url = trimmed[0..url_end];
                    if (img_url.len > 0) {
                        try links.append(allocator, Link{
                            .href = img_url,
                            .link_type = .image,
                        });
                    }
                }
            }
        }

        pos = tag_end + 1;
    }

    return try links.toOwnedSlice(allocator);
}

/// Find the value of a named attribute in tag content.
/// Returns a slice of the input string (between quotes or until whitespace for unquoted).
fn findAttributeValue(tag_content: []const u8, attr_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag_content.len) {
        // Skip whitespace
        while (pos < tag_content.len and isWhitespace(tag_content[pos])) pos += 1;
        if (pos >= tag_content.len) break;

        // Read attribute name
        const name_start = pos;
        while (pos < tag_content.len and tag_content[pos] != '=' and
            !isWhitespace(tag_content[pos]) and tag_content[pos] != '>')
        {
            pos += 1;
        }
        const name = tag_content[name_start..pos];

        // Skip whitespace around '='
        while (pos < tag_content.len and isWhitespace(tag_content[pos])) pos += 1;
        if (pos >= tag_content.len or tag_content[pos] != '=') {
            // Attribute without value; continue
            continue;
        }
        pos += 1; // skip '='
        while (pos < tag_content.len and isWhitespace(tag_content[pos])) pos += 1;
        if (pos >= tag_content.len) break;

        // Read attribute value
        const value = blk: {
            if (tag_content[pos] == '"') {
                pos += 1;
                const val_start = pos;
                while (pos < tag_content.len and tag_content[pos] != '"') pos += 1;
                const val = tag_content[val_start..pos];
                if (pos < tag_content.len) pos += 1; // skip closing quote
                break :blk val;
            } else if (tag_content[pos] == '\'') {
                pos += 1;
                const val_start = pos;
                while (pos < tag_content.len and tag_content[pos] != '\'') pos += 1;
                const val = tag_content[val_start..pos];
                if (pos < tag_content.len) pos += 1;
                break :blk val;
            } else {
                // Unquoted value
                const val_start = pos;
                while (pos < tag_content.len and !isWhitespace(tag_content[pos]) and
                    tag_content[pos] != '>')
                {
                    pos += 1;
                }
                break :blk tag_content[val_start..pos];
            }
        };

        if (asciiEqlIgnoreCase(name, attr_name)) {
            return value;
        }
    }
    return null;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "extract anchor links" {
    const html =
        \\<html><body>
        \\<a href="https://example.com">Example</a>
        \\<a href="/about">About</a>
        \\</body></html>
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 2);
    try std.testing.expectEqualStrings("https://example.com", links[0].href);
    try std.testing.expect(links[0].link_type == .anchor);
    try std.testing.expectEqualStrings("/about", links[1].href);
}

test "extract image sources" {
    const html =
        \\<img src="photo.jpg" alt="photo">
        \\<img src="/images/logo.png">
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 2);
    try std.testing.expectEqualStrings("photo.jpg", links[0].href);
    try std.testing.expect(links[0].link_type == .image);
    try std.testing.expectEqualStrings("/images/logo.png", links[1].href);
}

test "extract mixed links and images" {
    const html =
        \\<a href="/page1">Page 1</a>
        \\<img src="/img1.jpg">
        \\<a href="/page2">Page 2</a>
        \\<img src="/img2.png">
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 4);
    try std.testing.expect(links[0].link_type == .anchor);
    try std.testing.expect(links[1].link_type == .image);
    try std.testing.expect(links[2].link_type == .anchor);
    try std.testing.expect(links[3].link_type == .image);
}

test "skip javascript and mailto links" {
    const html =
        \\<a href="javascript:void(0)">JS</a>
        \\<a href="mailto:user@example.com">Email</a>
        \\<a href="tel:+1234567890">Phone</a>
        \\<a href="data:text/html,hello">Data</a>
        \\<a href="#section">Anchor</a>
        \\<a href="/real-link">Real</a>
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/real-link", links[0].href);
}

test "handle single-quoted attributes" {
    const html = "<a href='/path'>Link</a>";
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/path", links[0].href);
}

test "handle unquoted attributes" {
    const html = "<a href=/path>Link</a>";
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/path", links[0].href);
}

test "case-insensitive tag names" {
    const html =
        \\<A HREF="/link1">Link</A>
        \\<IMG SRC="/img1.jpg">
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 2);
    try std.testing.expectEqualStrings("/link1", links[0].href);
    try std.testing.expectEqualStrings("/img1.jpg", links[1].href);
}

test "skip HTML comments" {
    const html =
        \\<!-- <a href="/commented-out">Hidden</a> -->
        \\<a href="/visible">Visible</a>
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/visible", links[0].href);
}

test "extract link and script tags" {
    const html =
        \\<link href="/style.css" rel="stylesheet">
        \\<script src="/app.js"></script>
    ;
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 2);
    try std.testing.expectEqualStrings("/style.css", links[0].href);
    try std.testing.expect(links[0].link_type == .anchor);
    try std.testing.expectEqualStrings("/app.js", links[1].href);
    try std.testing.expect(links[1].link_type == .anchor);
}

test "extract iframe src" {
    const html = "<iframe src=\"/embed\"></iframe>";
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/embed", links[0].href);
}

test "empty HTML" {
    const links = try extractLinks(std.testing.allocator, "");
    defer std.testing.allocator.free(links);
    try std.testing.expect(links.len == 0);
}

test "no links in plain text" {
    const links = try extractLinks(std.testing.allocator, "Hello, world! No links here.");
    defer std.testing.allocator.free(links);
    try std.testing.expect(links.len == 0);
}

test "srcset extraction" {
    const html = "<img src=\"/main.jpg\" srcset=\"/small.jpg 300w, /medium.jpg 600w, /large.jpg 1200w\">";
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 4); // 1 src + 3 srcset
    try std.testing.expectEqualStrings("/main.jpg", links[0].href);
    try std.testing.expectEqualStrings("/small.jpg", links[1].href);
    try std.testing.expectEqualStrings("/medium.jpg", links[2].href);
    try std.testing.expectEqualStrings("/large.jpg", links[3].href);
}

test "attributes with extra whitespace" {
    const html = "<a   href = \"/spaced\"  >Link</a>";
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/spaced", links[0].href);
}

test "multiple attributes before href" {
    const html = "<a class=\"btn\" id=\"link1\" href=\"/target\">Link</a>";
    const links = try extractLinks(std.testing.allocator, html);
    defer std.testing.allocator.free(links);

    try std.testing.expect(links.len == 1);
    try std.testing.expectEqualStrings("/target", links[0].href);
}
