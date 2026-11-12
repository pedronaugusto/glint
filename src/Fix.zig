//! The fixes a run's findings carry, applied: each a set of edits of one file's bytes where the
//! answer follows from the site alone. A suppression in a form glint reads no more is rewritten
//! into the one it reads, `// glint-ignore: <rule>, ... -- <reason>`: the aegis pack's escape
//! (`// aegis: <reason>(<rule>, ...): <why>`, its reason kept in the words), one in the escape's
//! older form naming the rules a record of an earlier run shows it covered, and a suppression
//! naming a rule the pack had under the name glint gives it now (A019 is P007, A016 P008, A014
//! P009). A rule 0.8 removed (A003, those that went with the flow engine, and A012's input-sized
//! work) is dropped from it, and so is a rule that ran and met no site under it; one naming none
//! left goes. No fix writes a suppression a site did not already have: a reason is the author's
//! to state.
const std = @import("std");
const aegis = @import("aegis");
const Project = @import("Project.zig");
const File = @import("File.zig");
const Report = @import("Report.zig");
const Rule = @import("Rule.zig");

/// A file's bytes after its fixes, how many edits made them, and how many sites they fix (a
/// fix may be several edits: Z034's two parentheses).
pub const Changed = struct { file: Project.FileId, bytes: []const u8, edits: usize, sites: usize = 0 };

/// A rule's fix, copied into the report's storage.
pub fn copy(a: std.mem.Allocator, fix: []const Report.Edit) std.mem.Allocator.Error![]const Report.Edit {
    const out = try a.alloc(Report.Edit, fix.len);
    for (fix, out) |e, *o| o.* = .{ .start = e.start, .end = e.end, .text = try a.dupe(u8, e.text), .nests = e.nests };
    return out;
}

/// An escape a run before this one reported, with the rules it covered then: a line of the
/// report's text, `escape: src/a.zig:12:30: no-danger: why (A010 at 12:5, A013 at 12:9)`, or
/// preflight's record of it, `glint: escape: src/a.zig:12:30: no-danger: why (A010, A013)`.
/// It is the escape at that place with that reason and why, and no other: one moved or
/// reworded since is not it.
pub const Escaped = struct { path: []const u8, line: u32, column: u32, reason: []const u8, why: []const u8, rules: []const []const u8 };

pub const Options = struct {
    /// The escapes of a run before, by which an escape in the older form is named: a migration
    /// aid, for the release that named the rules escapes cover.
    escapes_before: []const Escaped = &.{},
};

/// The escapes a report's text lists: each line that starts `escape: ` or `glint: escape: `;
/// every other line is left. A line that starts so and is not an escape's in that exact form,
/// `path:line:column: reason: why (rules)`, each rule alone or followed by ` at line:column`, is
/// `error.InvalidEscapeRecord`.
pub fn escapeRecord(a: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, InvalidEscapeRecord }![]const Escaped {
    var out: std.ArrayList(Escaped) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const rest = if (std.mem.startsWith(u8, line, "escape: "))
            line["escape: ".len..]
        else if (std.mem.startsWith(u8, line, "glint: escape: "))
            line["glint: escape: ".len..]
        else
            continue;
        try out.append(a, try escapeLine(a, rest));
    }
    return out.items;
}

/// One record line after its `escape: `: `path:line:column: reason: why (rules)`.
fn escapeLine(a: std.mem.Allocator, rest: []const u8) error{ OutOfMemory, InvalidEscapeRecord }!Escaped {
    const path, const after_path = std.mem.cutScalar(u8, rest, ':') orelse return error.InvalidEscapeRecord;
    if (path.len == 0) return error.InvalidEscapeRecord;
    const line_digits, const after_line = std.mem.cutScalar(u8, after_path, ':') orelse return error.InvalidEscapeRecord;
    const column_digits, const after_column = std.mem.cutScalar(u8, after_line, ':') orelse return error.InvalidEscapeRecord;
    const line = position(line_digits) orelse return error.InvalidEscapeRecord;
    const column = position(column_digits) orelse return error.InvalidEscapeRecord;
    const text = std.mem.cutPrefix(u8, after_column, " ") orelse return error.InvalidEscapeRecord;
    const reason, const after_reason = std.mem.cut(u8, text, ": ") orelse return error.InvalidEscapeRecord;
    if (reason.len == 0 or std.mem.findAny(u8, reason, " ()") != null) return error.InvalidEscapeRecord;
    const listed_whole = std.mem.cutSuffix(u8, after_reason, ")") orelse return error.InvalidEscapeRecord;
    const why, const listed = std.mem.cutLast(u8, listed_whole, " (") orelse return error.InvalidEscapeRecord;
    var rules: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.splitSequence(u8, listed, ", ");
    while (entries.next()) |entry| {
        // A rule's name, its place after it where glint's own report gives one (`A010 at 4:18`).
        const name, const place = std.mem.cutScalar(u8, entry, ' ') orelse .{ entry, null };
        if (name.len == 0 or !ruleName(name)) return error.InvalidEscapeRecord;
        if (place) |words| {
            const at = std.mem.cutPrefix(u8, words, "at ") orelse return error.InvalidEscapeRecord;
            const at_line, const at_column = std.mem.cutScalar(u8, at, ':') orelse return error.InvalidEscapeRecord;
            _ = position(at_line) orelse return error.InvalidEscapeRecord;
            _ = position(at_column) orelse return error.InvalidEscapeRecord;
        }
        try rules.append(a, name);
    }
    return .{ .path = path, .line = line, .column = column, .reason = reason, .why = why, .rules = rules.items };
}

/// A line or column number: decimal digits alone.
fn position(digits: []const u8) ?u32 {
    if (digits.len == 0) return null;
    for (digits) |d| if (!std.ascii.isDigit(d)) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// A rule's name as a report spells it: letters and digits.
fn ruleName(name: []const u8) bool {
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

/// Each file a run's fixes change, with its bytes after them: every finding's fix, the rewrite of
/// a suppression in a form glint reads no more, and each rule dropped from a suppression it met
/// no site under (the suppression gone where none is left). Overlapping edits keep the first; an edit two
/// findings share is made once.
/// An edit outside its file's bytes is no edit glint makes: `InvalidEdit`.
pub fn apply(a: std.mem.Allocator, project: *const Project, report: *const Report, options: Options) error{ OutOfMemory, InvalidEdit }![]const Changed {
    var by_file: std.array_hash_map.Auto(Project.FileId, std.ArrayList(Report.Edit)) = .empty;
    var sites: std.AutoHashMapUnmanaged(Project.FileId, usize) = .empty;
    for (report.diagnostics) |d| {
        if (d.fix.len == 0) continue;
        const entry = try by_file.getOrPut(a, d.span.file);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.appendSlice(a, d.fix);
        (try sites.getOrPutValue(a, d.span.file, 0)).value_ptr.* += 1;
    }
    for (report.malformed) |entry| {
        const file = project.at(entry.span.file).file;
        const edit = (try oldSuppression(a, file, entry.span.start, entry.span.end)) orelse (try oldEscape(a, project, entry.span, options.escapes_before)) orelse continue;
        const slot = try by_file.getOrPut(a, entry.span.file);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, edit);
        (try sites.getOrPutValue(a, entry.span.file, 0)).value_ptr.* += 1;
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

/// The name glint gives now to a rule an old suppression or escape names, by the removed-rule
/// table (`Rule.removed_rules`): a renamed one its successor (A019 is P007), a removed one none
/// (A003, and those that went with the flow engine), one a package now declares its own id.
/// A012 named the flow engine's input-sized work, which went; aegis's A012 is another check.
fn renamed(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "A012")) return null;
    const gone = Rule.removed(name) orelse return name;
    return switch (gone.now) {
        .renamed => |id| id,
        .removed => null,
        .declared => name,
    };
}

/// The rules `names` lists under today's names, sorted and each once; whether any was renamed or
/// dropped.
fn today(a: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error!struct { list: []const u8, changed: bool, empty: bool } {
    var kept: std.ArrayList([]const u8) = .empty;
    var changed = false;
    for (names) |name| {
        const now = renamed(name) orelse {
            changed = true;
            continue;
        };
        if (!std.mem.eql(u8, now, name)) changed = true;
        for (kept.items) |earlier_name| {
            if (std.mem.eql(u8, earlier_name, now)) break;
        } else try kept.append(a, now);
    }
    std.mem.sort([]const u8, kept.items, {}, lessName);
    var list: std.ArrayList(u8) = .empty;
    for (kept.items, 0..) |name, i| {
        if (i != 0) try list.appendSlice(a, ", ");
        try list.appendSlice(a, name);
    }
    return .{ .list = list.items, .changed = changed, .empty = kept.items.len == 0 };
}

/// A suppression naming a rule under the pack's old name (`// glint-ignore: A019 -- why`),
/// under today's names; one naming none left goes.
fn oldSuppression(a: std.mem.Allocator, file: *const File, start: u32, end: u32) std.mem.Allocator.Error!?Report.Edit {
    const text = spanned(file, start, end) orelse return null;
    const after = std.mem.cutPrefix(u8, text, "// glint-ignore: ") orelse return null;
    const listed, const why = std.mem.cut(u8, after, " -- ") orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    var each = std.mem.tokenizeAny(u8, listed, ", \t");
    while (each.next()) |name| try names.append(a, name);
    const now = try today(a, names.items);
    if (!now.changed) return null;
    if (now.empty) return removal(file, start, end);
    return .{ .start = start, .end = end, .text = try a.print("// glint-ignore: {s} -- {s}", .{ now.list, why }) };
}

/// A suppression without the rules `stale` names, which suppress nothing under it: the rest with
/// its reason, or its removal where none is left.
fn staleSuppression(a: std.mem.Allocator, file: *const File, start: u32, end: u32, stale: []const []const u8) std.mem.Allocator.Error!?Report.Edit {
    const text = spanned(file, start, end) orelse return null;
    const after = std.mem.cutPrefix(u8, text, "// glint-ignore: ") orelse return null;
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
    return .{ .start = start, .end = end, .text = try a.print("// glint-ignore: {s} -- {s}", .{ kept.items, why }) };
}

/// An escape in the aegis pack's form, as the suppression glint reads: `// aegis: <reason>(<rules>):
/// <why>` becomes `// glint-ignore: <rules> -- <reason>: <why>` under today's names. One in the
/// older form, naming no rules, takes those a record of a run before shows it covered, at that
/// place with those words; with no record it is left for its owner to name, as no fix writes in
/// rules a run only guesses it covered.
fn oldEscape(a: std.mem.Allocator, project: *const Project, span: Report.Span, before: []const Escaped) std.mem.Allocator.Error!?Report.Edit {
    const file = project.at(span.file).file;
    const text = spanned(file, span.start, span.end) orelse return null;
    const rest = std.mem.trim(u8, std.mem.cutPrefix(u8, text, "// aegis:") orelse return null, " ");
    const head, const why_raw = std.mem.cutScalar(u8, rest, ':') orelse return null;
    const why = std.mem.trim(u8, why_raw, " ");
    const reason, const listed = std.mem.cutScalar(u8, head, '(') orelse .{ std.mem.trim(u8, head, " "), null };
    var names: std.ArrayList([]const u8) = .empty;
    if (listed) |inside| {
        var each = std.mem.tokenizeAny(u8, std.mem.cutSuffix(u8, inside, ")") orelse return null, ", \t");
        while (each.next()) |name| try names.append(a, name);
    } else {
        const recorded = for (before) |escaped| {
            if (escaped.line != span.line or escaped.column != span.column) continue;
            if (!std.mem.eql(u8, escaped.path, project.at(span.file).input.name)) continue;
            if (std.mem.eql(u8, escaped.reason, reason) and std.mem.eql(u8, escaped.why, why)) break escaped;
        } else null;
        // An escape no record names is its owner's to rewrite: no fix writes rules in that a
        // run only guesses it covered.
        try names.appendSlice(a, (recorded orelse return null).rules);
    }
    const now = try today(a, names.items);
    if (now.empty) return removal(file, span.start, span.end);
    return .{ .start = span.start, .end = span.end, .text = try a.print("// glint-ignore: {s} -- {s}: {s}", .{ now.list, std.mem.trim(u8, reason, " "), why }) };
}

/// A span's bytes of `file`; null for a span outside them.
fn spanned(file: *const File, start: u32, end: u32) ?[]const u8 {
    if (start > end or end > file.source.len) return null;
    return file.source[start..end];
}

fn lessName(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
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

test "an old suppression takes today's names, and one naming only a rule that went goes" {
    var file = try File.init(std.testing.allocator, "const a = 1; // glint-ignore: A019, A014 -- design: one cast\nconst c = 3; // glint-ignore: A010 -- design: gone\nconst d = 4; // glint-ignore: Z013 -- kept\n", .{});
    defer file.deinit();
    const a = file.arena.allocator();
    const renamed_one = (try oldSuppression(a, &file, file.comments[0].start, file.comments[0].end)).?;
    try std.testing.expectEqualStrings("// glint-ignore: P007, P009 -- design: one cast", renamed_one.text);
    const gone = (try oldSuppression(a, &file, file.comments[1].start, file.comments[1].end)).?;
    try std.testing.expectEqualStrings(" // glint-ignore: A010 -- design: gone", file.source[gone.start..gone.end]);
    try std.testing.expectEqual(null, try oldSuppression(a, &file, file.comments[2].start, file.comments[2].end));
}

test "fuzz: an escape record (--escapes-before, a file the caller hands in)" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [4096]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            // A record refused for its form is the answer: the CLI says so.
            const escapes = escapeRecord(arena.allocator(), bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidEscapeRecord => return,
            };
            for (escapes) |escaped| {
                if (escaped.path.len == 0 or escaped.reason.len == 0) return error.TestUnexpectedResult;
                for (escaped.rules) |rule| if (rule.len == 0) return error.TestUnexpectedResult;
            }
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = &.{
        "escape: src/a.zig:12:30: no-danger: why (A010 at 12:5, A013 at 12:9)\n",
        "glint: escape: src/a.zig:12:30: no-danger: why (A010, A013)\n",
        "other line\nescape: x:1:1: r: w (P007)\n",
        "escape: :1:1: r: w (P007)\n",
    } });
}
