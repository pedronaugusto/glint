//! The fixes a run's findings carry, applied: each a set of edits of one file's bytes where the
//! answer follows from the site alone. A suppression a rule that ran met no site under loses that
//! rule, and goes where it names none left. No fix writes a suppression a site did not already
//! have: a reason is the author's to state.
const std = @import("std");
const aegis = @import("aegis");
const Project = @import("Project.zig");
const File = @import("File.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");

/// A file's bytes after its fixes, how many edits made them, and how many sites they fix (a
/// fix may be several edits: Z034's two parentheses).
pub const Changed = struct { file: Project.FileId, bytes: []const u8, edits: usize, sites: usize = 0 };

/// A rule's fix, copied into the report's storage.
pub fn copy(a: std.mem.Allocator, fix: []const Report.Edit) std.mem.Allocator.Error![]const Report.Edit {
    const out = try a.alloc(Report.Edit, fix.len);
    for (fix, out) |e, *o| o.* = .{ .start = e.start, .end = e.end, .text = try a.dupe(u8, e.text), .nests = e.nests };
    return out;
}

/// Each file a run's fixes change, with its bytes after them: every finding's fix, and each rule
/// dropped from a suppression it met no site under (the suppression gone where none is left). Overlapping edits keep the first; an edit two
/// findings share is made once.
/// An edit outside its file's bytes is no edit glint makes: `InvalidEdit`.
pub fn apply(a: std.mem.Allocator, project: *const Project, report: *const Report) error{ OutOfMemory, InvalidEdit }![]const Changed {
    var by_file: std.array_hash_map.Auto(Project.FileId, std.ArrayList(Report.Edit)) = .empty;
    var sites: std.AutoHashMapUnmanaged(Project.FileId, usize) = .empty;
    for (report.diagnostics) |d| {
        if (d.fix.len == 0) continue;
        const entry = try by_file.getOrPut(a, d.span.file);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(a, d.fix);
        (try sites.getOrPutValue(a, d.span.file, 0)).value_ptr.* += 1;
    }
    // A suppression a rule that ran met no site under (`Report.stale`): that rule dropped from
    // it, its reason kept, and the comment gone where it names no rule left.
    var stale: std.array_hash_map.Auto(struct { Project.FileId, u32, u32 }, std.ArrayList([]const u8)) = .empty;
    for (report.stale) |entry| {
        const slot = try stale.getOrPut(a, .{ entry.span.file, entry.span.start, entry.span.end });
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, entry.name);
    }
    for (stale.keys(), stale.values()) |at, names| {
        const edit = (try staleSuppression(a, project.at(at[0]).file, at[1], at[2], names.items)) orelse continue;
        const slot = try by_file.getOrPut(a, at[0]);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, edit);
        (try sites.getOrPutValue(a, at[0], 0)).value_ptr.* += 1;
    }
    var out: std.ArrayList(Changed) = .empty;
    for (by_file.keys(), by_file.values()) |file, *edits| {
        const source = project.at(file).file.source;
        std.mem.sort(Report.Edit, edits.items, {}, earlier);
        var bytes: std.ArrayList(u8) = .empty;
        var at: u32 = 0;
        var made: usize = 0;
        var last: ?Report.Edit = null;
        for (edits.items) |e| {
            if (last) |l| if (!e.nests and l.start == e.start and l.end == e.end and std.mem.eql(u8, l.text, e.text)) continue;
            if (e.start < at) continue;
            if (e.start > e.end or e.start > source.len or e.end > source.len) return error.InvalidEdit;
            try bytes.appendSlice(a, source[at..e.start]);
            try bytes.appendSlice(a, e.text);
            at = e.end;
            last = e;
            made += 1;
        }
        if (at > source.len) return error.InvalidEdit;
        try bytes.appendSlice(a, source[at..]);
        try out.append(a, .{ .file = file, .bytes = bytes.items, .edits = made, .sites = sites.get(file) orelse 0 });
    }
    return out.items;
}

/// A suppression without the rules `stale` names, which suppress nothing under it: the rest with
/// its reason, or its removal where none is left.
fn staleSuppression(a: std.mem.Allocator, file: *const File, start: u32, end: u32, stale: []const []const u8) std.mem.Allocator.Error!?Report.Edit {
    const text = spanned(file, start, end) orelse return null;
    const after = std.mem.cutPrefix(u8, text, Suppression.opening) orelse return null;
    const listed, const why = std.mem.cut(u8, after, " -- ") orelse return null;
    var kept: std.ArrayList(u8) = .empty;
    var each = std.mem.tokenizeAny(u8, listed, ", \t");
    while (each.next()) |name| {
        const gone = for (stale) |one| {
            if (std.mem.eql(u8, one, name)) break true;
        } else false;
        if (gone) continue;
        if (kept.items.len != 0) try kept.appendSlice(a, ", ");
        try kept.appendSlice(a, name);
    }
    if (kept.items.len == 0) return removal(file, start, end);
    return .{ .start = start, .end = end, .text = try a.print(Suppression.opening ++ "{s} -- {s}", .{ kept.items, why }) };
}

/// A span's bytes of `file`; null for a span outside them.
fn spanned(file: *const File, start: u32, end: u32) ?[]const u8 {
    if (start > end or end > file.source.len) return null;
    return file.source[start..end];
}

fn earlier(_: void, x: Report.Edit, y: Report.Edit) bool {
    return if (x.start != y.start) x.start < y.start else x.end < y.end;
}

/// The edit that removes a comment: its whole line when it stands alone, else the comment and
/// the spaces before it.
fn removal(file: *const File, start: u32, end: u32) ?Report.Edit {
    const source = file.source;
    if (start > end or start > source.len or end > source.len) return null;
    const line = file.line(start);
    const line_start = file.lines[line];
    const whole = aegis.int.cast(u32, source.len) catch return null;
    const line_end = if (line + 1 < file.lines.len) file.lines[line + 1] else whole;
    if (line_start > start or line_end < end or line_end > source.len) return null;
    if (std.mem.trim(u8, source[line_start..start], " \t").len == 0 and std.mem.trim(u8, source[end..line_end], " \t\r\n").len == 0) {
        return .{ .start = line_start, .end = line_end, .text = "" };
    }
    var from = start;
    while (from > line_start and from <= source.len and (source[from - 1] == ' ' or source[from - 1] == '\t')) from -= 1;
    return .{ .start = from, .end = end, .text = "" };
}
