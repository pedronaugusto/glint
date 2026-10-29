//! The fixes a run's findings carry, applied: each a set of edits of one file's bytes that
//! replaces a raw site with aegis's answer where the answer follows from the site alone
//! (designs/aegis.md §7). The pack's old suppression (`// glint-ignore: A001 -- design: why`)
//! becomes its escape naming that rule, an escape in the older form names the rules it covers,
//! and an escape that covers nothing goes. No fix writes an escape a site did not already have:
//! a reason is the author's to state. A site whose answer is a design choice carries no fix.
const std = @import("std");
const Project = @import("Project.zig");
const File = @import("File.zig");
const Report = @import("Report.zig");

/// A file's bytes after its fixes, and how many edits made them.
pub const Changed = struct { file: Project.FileId, bytes: []const u8, edits: usize };

/// A rule's fix, copied into the report's storage.
pub fn copy(a: std.mem.Allocator, fix: []const Report.Edit) std.mem.Allocator.Error![]const Report.Edit {
    const out = try a.alloc(Report.Edit, fix.len);
    for (fix, out) |e, *o| o.* = .{ .start = e.start, .end = e.end, .text = try a.dupe(u8, e.text), .nests = e.nests };
    return out;
}

/// Each file a run's fixes change, with its bytes after them: every finding's fix and the
/// removal of every escape that covered nothing. Overlapping edits keep the first; an edit two
/// findings share is made once.
pub fn apply(a: std.mem.Allocator, project: *const Project, report: *const Report) std.mem.Allocator.Error![]const Changed {
    var by_file: std.array_hash_map.Auto(u32, std.ArrayList(Report.Edit)) = .empty;
    for (report.diagnostics) |d| {
        if (d.fix.len == 0) continue;
        const entry = try by_file.getOrPut(a, d.span.file.raw());
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(a, d.fix);
    }
    for (report.stale) |stale| {
        if (!std.mem.eql(u8, stale.name, "aegis")) continue;
        const file = &project.files[stale.span.file.raw()];
        const entry = try by_file.getOrPut(a, stale.span.file.raw());
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, removal(file, stale.span.start, stale.span.end));
    }
    for (report.malformed) |entry| {
        const file = &project.files[entry.span.file.raw()];
        const edit = (try oldSuppression(a, file, entry.span.start, entry.span.end)) orelse (try unnamedEscape(a, file, report, entry.span)) orelse continue;
        const slot = try by_file.getOrPut(a, entry.span.file.raw());
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, edit);
    }
    var out: std.ArrayList(Changed) = .empty;
    for (by_file.keys(), by_file.values()) |raw, *edits| {
        const source = project.files[raw].source;
        std.mem.sort(Report.Edit, edits.items, {}, earlier);
        var bytes: std.ArrayList(u8) = .empty;
        var at: u32 = 0;
        var made: usize = 0;
        var last: ?Report.Edit = null;
        for (edits.items) |e| {
            if (last) |l| if (!e.nests and l.start == e.start and l.end == e.end and std.mem.eql(u8, l.text, e.text)) continue;
            if (e.start < at) continue;
            try bytes.appendSlice(a, source[at..e.start]);
            try bytes.appendSlice(a, e.text);
            at = e.end;
            last = e;
            made += 1;
        }
        try bytes.appendSlice(a, source[at..]);
        try out.append(a, .{ .file = Project.FileId.fromRaw(raw), .bytes = bytes.items, .edits = made });
    }
    return out.items;
}

/// The escape for the pack's old suppression, `// glint-ignore: A0NN -- <category>: <why>`: its
/// category becomes the escape's reason (`measured-boundary` is `hot-loop`,
/// `safe-type-internals` `internal`, `c-os-boundary` `boundary`), its words kept.
fn oldSuppression(a: std.mem.Allocator, file: *const File, start: u32, end: u32) std.mem.Allocator.Error!?Report.Edit {
    const text = file.source[start..end];
    const prefix = "// glint-ignore: A0";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const separator = std.mem.find(u8, text, " -- ") orelse return null;
    const rest = text[separator + 4 ..];
    const colon = std.mem.findScalar(u8, rest, ':') orelse return null;
    const categories = [_][2][]const u8{ .{ "no-danger", "no-danger" }, .{ "design", "design" }, .{ "measured-boundary", "hot-loop" }, .{ "safe-type-internals", "internal" }, .{ "c-os-boundary", "boundary" } };
    const rule = std.mem.trim(u8, text["// glint-ignore: ".len..separator], " ");
    for (categories) |category| if (std.mem.eql(u8, std.mem.trim(u8, rest[0..colon], " "), category[0])) {
        return .{ .start = start, .end = end, .text = try a.print("// aegis: {s}({s}):{s}", .{ category[1], rule, rest[colon + 1 ..] }) };
    };
    return null;
}

/// The rules an escape in the older form (`// aegis: <reason>: <why>`) covered on this run,
/// written into it (`// aegis: <reason>(A009, A010): <why>`). One that covered nothing goes as
/// a stale escape instead.
fn unnamedEscape(a: std.mem.Allocator, file: *const File, report: *const Report, span: Report.Span) std.mem.Allocator.Error!?Report.Edit {
    const text = file.source[span.start..span.end];
    if (!std.mem.startsWith(u8, text, "// aegis:")) return null;
    for (report.escapes) |escape| {
        if (!escape.span.file.eql(span.file) or escape.span.start != span.start) continue;
        var names: std.ArrayList(u8) = .empty;
        var seen: std.ArrayList([]const u8) = .empty;
        for (escape.covered) |covered| {
            for (seen.items) |earlier_name| {
                if (std.mem.eql(u8, earlier_name, covered.name)) break;
            } else try seen.append(a, covered.name);
        }
        std.mem.sort([]const u8, seen.items, {}, lessName);
        for (seen.items, 0..) |name, i| {
            if (i != 0) try names.appendSlice(a, ", ");
            try names.appendSlice(a, name);
        }
        const reason_end = std.mem.findScalarPos(u8, text, "// aegis:".len, ':') orelse return null;
        const reason = std.mem.trim(u8, text["// aegis:".len..reason_end], " ");
        return .{ .start = span.start, .end = span.end, .text = try a.print("// aegis: {s}({s}):{s}", .{ reason, names.items, text[reason_end + 1 ..] }) };
    }
    return null;
}

fn lessName(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn earlier(_: void, x: Report.Edit, y: Report.Edit) bool {
    return if (x.start != y.start) x.start < y.start else x.end < y.end;
}

/// The edit that removes a comment: its whole line when it stands alone, else the comment and
/// the spaces before it.
fn removal(file: *const File, start: u32, end: u32) Report.Edit {
    const line = file.line(start);
    const line_start = file.lines[line];
    const line_end: u32 = if (std.mem.findScalarPos(u8, file.source, end, '\n')) |newline| @intCast(newline + 1) else @intCast(file.source.len);
    if (std.mem.trim(u8, file.source[line_start..start], " \t").len == 0 and std.mem.trim(u8, file.source[end..line_end], " \t\r\n").len == 0) {
        return .{ .start = line_start, .end = line_end, .text = "" };
    }
    var from = start;
    while (from > line_start and (file.source[from - 1] == ' ' or file.source[from - 1] == '\t')) from -= 1;
    return .{ .start = from, .end = end, .text = "" };
}

test "the pack's old suppression becomes the escape naming its rule, an unused escape goes" {
    var file = try File.init(std.testing.allocator, "const a = 1; // glint-ignore: A010 -- design: one byte\nconst c = 3; // aegis: no-danger(A009): stale\n", .{});
    defer file.deinit();
    const a = file.arena.allocator();
    const old = (try oldSuppression(a, &file, file.comments[0].start, file.comments[0].end)).?;
    try std.testing.expectEqualStrings("// aegis: design(A010): one byte", old.text);
    const gone = removal(&file, file.comments[1].start, file.comments[1].end);
    try std.testing.expectEqualStrings(" // aegis: no-danger(A009): stale", file.source[gone.start..gone.end]);
}
