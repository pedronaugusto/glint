//! The fixes a run's findings carry, applied: each a set of edits of one file's bytes that
//! replaces a raw site with aegis's answer where the answer follows from the site alone
//! (designs/aegis.md §7). A written reason the family kept beside a site (`// safe: why`,
//! `// unreachable: why`) becomes the pack's escape, and an escape that covers nothing goes.
//! A site whose answer is a design choice carries no fix.
const std = @import("std");
const Project = @import("Project.zig");
const File = @import("File.zig");
const Report = @import("Report.zig");

/// A file's bytes after its fixes, and how many edits made them.
pub const Changed = struct { file: Project.FileId, bytes: []const u8, edits: usize };

/// A rule's fix, copied into the report's storage.
pub fn copy(a: std.mem.Allocator, fix: []const Report.Edit) std.mem.Allocator.Error![]const Report.Edit {
    const out = try a.alloc(Report.Edit, fix.len);
    for (fix, out) |e, *o| o.* = .{ .start = e.start, .end = e.end, .text = try a.dupe(u8, e.text) };
    return out;
}

/// The escape a pack finding's line already states in the family's older words: the comment
/// `// safe: <why>` or `// unreachable: <why>` on the finding's line, or alone on the line
/// before it, rewritten `// aegis: <reason>: <why>`. The reason follows from the site: a C or
/// OS declaration or assembly is a boundary, safety switched off a hot loop, anything else
/// a site where the written reason says the danger is absent.
pub fn escapeOf(a: std.mem.Allocator, file: *const File, line: u32, rule: []const u8, message: []const u8) std.mem.Allocator.Error![]const Report.Edit {
    const reason: []const u8 = if (std.mem.eql(u8, rule, "A019") and (std.mem.startsWith(u8, message, "extern") or std.mem.startsWith(u8, message, "inline assembly")))
        "boundary"
    else if (std.mem.startsWith(u8, message, "@setRuntimeSafety(false)"))
        "hot-loop"
    else
        "no-danger";
    for (file.comments) |comment| {
        const on_line = comment.line == line;
        const before = comment.line + 1 == line and std.mem.trim(u8, file.source[file.lines[comment.line]..comment.start], " \t").len == 0;
        if (!on_line and !before) continue;
        const text = file.source[comment.start..comment.end];
        for ([_][]const u8{ "// safe: ", "// unreachable: " }) |prefix| if (std.mem.startsWith(u8, text, prefix)) {
            const edits = try a.alloc(Report.Edit, 1);
            edits[0] = .{ .start = comment.start, .end = comment.start + @as(u32, @intCast(prefix.len)), .text = try std.fmt.allocPrint(a, "// aegis: {s}: ", .{reason}) };
            return edits;
        };
    }
    return &.{};
}

/// Each file a run's fixes change, with its bytes after them: every finding's fix and the
/// removal of every escape that covered nothing. Overlapping edits keep the first; an edit two
/// findings share is made once.
pub fn apply(a: std.mem.Allocator, project: *const Project, report: *const Report) std.mem.Allocator.Error![]const Changed {
    var by_file: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(Report.Edit)) = .empty;
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
    var out: std.ArrayList(Changed) = .empty;
    for (by_file.keys(), by_file.values()) |raw, *edits| {
        const source = project.files[raw].source;
        std.mem.sort(Report.Edit, edits.items, {}, earlier);
        var bytes: std.ArrayList(u8) = .empty;
        var at: u32 = 0;
        var made: usize = 0;
        var last: ?Report.Edit = null;
        for (edits.items) |e| {
            if (last) |l| if (l.start == e.start and l.end == e.end and std.mem.eql(u8, l.text, e.text)) continue;
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

test "an older reason becomes the escape, an unused escape goes, overlapping edits keep the first" {
    var file = try File.init(std.testing.allocator, "const a = 1; // safe: one byte\n// unreachable: never\nconst b = 2;\nconst c = 3; // aegis: no-danger: stale\n", .{});
    defer file.deinit();
    const a = file.arena.allocator();
    const first = try escapeOf(a, &file, 0, "A010", "@intCast of input");
    try std.testing.expectEqualStrings("// aegis: no-danger: ", first[0].text);
    const second = try escapeOf(a, &file, 2, "A013", "unreachable");
    try std.testing.expectEqual(@as(usize, 1), second.len); // safe: a fixture count.
    try std.testing.expectEqualStrings("// unreachable: ", file.source[second[0].start..second[0].end]);
    const gone = removal(&file, file.comments[2].start, file.comments[2].end);
    try std.testing.expectEqualStrings(" // aegis: no-danger: stale", file.source[gone.start..gone.end]);
}
