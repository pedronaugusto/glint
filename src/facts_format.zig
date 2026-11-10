//! The compiled-facts file: what zig's own semantic analysis of one configuration holds for
//! glint, exported by exporter/<zig-version>/ (designs/glint-compiled-facts.md). This file is the
//! format's one definition: glint reads with `View`, the exporter writes with `Builder`. It
//! imports std alone and names nothing of the compiler, so the exporter copies it as it is.
//!
//! Layout, little-endian: `Header`, then `section_count` `Section` entries, then each section's
//! bytes. Every section is an array of fixed-size records; a reader skips a tag it does not
//! know. Lists (a body's arguments, an aggregate's elements) are runs of the `extra` section;
//! text is a run of the `strings` section. The `end` section holds the totals, so a file cut
//! short is refused, never read as fewer facts.
const std = @import("std");

pub const magic = "GLFACTS\x00".*;
pub const version: u32 = 1;

/// No value, body or file: the id a field holds where it names none.
pub const none: u32 = std.math.maxInt(u32);

pub const Header = extern struct {
    magic: [8]u8 = magic,
    version: u32 = version,
    section_count: u32,
};

pub const Tag = enum(u32) {
    strings = 1,
    extra = 2,
    config = 3,
    files = 4,
    values = 5,
    bodies = 6,
    results = 7,
    end = 8,
    _,
};

pub const Section = extern struct {
    tag: u32,
    /// Records in the section.
    count: u32,
    /// From the file's start.
    offset: u64,
    /// `count` times the record's size.
    length: u64,
};

/// Text: a run of the `strings` section.
pub const Text = extern struct { start: u32 = 0, len: u32 = 0 };
/// A list of ids or numbers: a run of the `extra` section.
pub const Run = extern struct { start: u32 = 0, len: u32 = 0 };

/// One fact of the analysed configuration: `key` is `zig_version`, `target`, `optimize`,
/// `root` or a build option's name.
pub const Config = extern struct { key: Text, value: Text };

/// A source file the analysis read, by its path and the SHA-256 of its bytes: a file of the run
/// whose bytes differ makes the whole facts file stale.
pub const File = extern struct { path: Text, hash: [32]u8 };

/// A type or a comptime-known value, written once and by structure. What `a`, `b`, `c` and
/// `list` hold is the kind's (`Value.Kind`).
pub const Value = extern struct {
    kind: u32,
    a: u32 = none,
    b: u32 = none,
    c: u32 = none,
    list: Run = .{},
    text: Text = .{},

    pub const Kind = enum(u32) {
        /// What the exporter does not write by structure: `text` says which kind it was. A
        /// reader takes it as not known.
        unwritten = 0,
        /// `text`: `u8`, `bool`, `void`, `type`, `anyerror`, `noreturn`, `comptime_int`, ...
        simple_type = 1,
        /// `a` bits, `b` 1 where signed.
        int_type = 2,
        /// `a` the child's value, `b` the size (0 one, 1 many, 2 slice, 3 c), `c` 1 where const.
        pointer_type = 3,
        /// `a` the child.
        optional_type = 4,
        /// `a` the element, `list` the length's two halves, low first.
        array_type = 5,
        /// `a` the element, `b` the length.
        vector_type = 6,
        /// `a` the error set (`none` where inferred or any), `b` the payload.
        error_union_type = 7,
        /// `list` each name as two numbers, a `Text`'s start and length.
        error_set_type = 8,
        /// `a` the result, `list` each parameter's type (`none` for a generic one).
        function_type = 9,
        /// A declared type. `a` the file of its declaration, `b` the declaration's ZIR
        /// instruction, `c` which (0 struct, 1 union, 2 enum, 3 opaque), `text` its name,
        /// `list` three numbers a field: its name's start and length, its type's value.
        declared_type = 10,
        /// `list` each element's type.
        tuple_type = 11,

        /// `a` the type, `list` the magnitude's two halves, low first, `b` 1 where negative.
        int = 32,
        /// `a` the type, `list` the float's bits as two halves, low first (an f64's).
        float = 33,
        /// `text`: `true`, `false`, `void`, `null`, `undefined`, `unreachable`.
        simple = 34,
        /// `a` the enum's type, `b` the field's position, `c` the tag's integer value.
        enum_tag = 35,
        /// `text` the name.
        enum_literal = 36,
        /// `a` the type, `text` the error's name.
        err = 37,
        /// `a` the type, `list` each element or field in order.
        aggregate = 38,
        /// `a` the type, `text` the bytes of an array of `u8`.
        bytes = 39,
        /// `a` the type, `b` the pointer's value, `c` the length's value.
        slice = 40,
        /// `a` the type, `b` what it points at: a value, or `none` where that is not written.
        pointer = 41,
        /// `a` the type, `b` the payload or `none` for null.
        optional = 42,
        /// `a` the type, `b` the tag's value, `c` the payload.
        union_value = 43,
        /// A function. `a` the file of its declaration, `b` the declaration's ZIR instruction,
        /// `c` the body analysed for it or `none`, `text` its name.
        function = 44,
        _,
    };
};

/// One body the compiler analysed: a function instance, or a call it analysed in place.
pub const Body = extern struct {
    kind: u32,
    /// The file of the function's declaration.
    file: u32,
    /// The function declaration's ZIR instruction in that file.
    declaration: u32,
    /// Each comptime argument's value, by parameter position: `none` for a runtime parameter.
    arguments: Run = .{},
    /// For a call analysed in place: the body holding the call, and the call's instruction.
    caller: u32 = none,
    call: u32 = none,
    /// A comptime call's result.
    result: u32 = none,
    /// Its results: a run of the `results` section, in the order of (instruction, visit).
    results_start: u32 = 0,
    results_len: u32 = 0,

    pub const Kind = enum(u32) { function = 0, inline_call = 1, comptime_call = 2, _ };
};

/// What one visit of one ZIR instruction of a body gave.
pub const Result = extern struct {
    /// The ZIR instruction, in the body's function's file.
    instruction: u32,
    /// Which visit of it within its body, from 0: an `inline for`'s iterations.
    visit: u32,
    /// The comptime-known value, or `none` for a runtime result.
    value: u32 = none,
    /// A runtime result's type, or `none` where the exporter does not give one.
    type: u32 = none,
    /// For a call: the function called as a `function` value, `runtime_callee` where it is a
    /// pointer known only at run time, `none` for any other instruction.
    callee: u32 = none,

    pub const runtime_callee: u32 = none - 1;
};

pub const End = extern struct { files: u32, values: u32, bodies: u32, results: u32 };

/// Why a facts file is refused. A refused file is no facts for its configuration.
pub const Refusal = enum {
    too_short,
    not_a_facts_file,
    other_version,
    sections_out_of_bounds,
    section_size_mismatch,
    section_repeated,
    section_missing,
    cut_short,
    text_out_of_bounds,
    run_out_of_bounds,
    id_out_of_range,
    results_out_of_order,
};

pub const Error = error{Refused};

/// A facts file read whole and checked: every count, offset and id is within what it indexes
/// before any accessor gives it out.
pub const View = struct {
    strings: []const u8 = &.{},
    extra: []align(1) const u32 = &.{},
    config: []align(1) const Config = &.{},
    files: []align(1) const File = &.{},
    values: []align(1) const Value = &.{},
    bodies: []align(1) const Body = &.{},
    results: []align(1) const Result = &.{},

    /// The checked view of `bytes`, or why it is refused (`refusal`).
    pub fn init(bytes: []const u8, refusal: *Refusal) Error!View {
        return check(bytes) catch |err| switch (err) {
            error.too_short => refuse(refusal, .too_short),
            error.not_a_facts_file => refuse(refusal, .not_a_facts_file),
            error.other_version => refuse(refusal, .other_version),
            error.sections_out_of_bounds => refuse(refusal, .sections_out_of_bounds),
            error.section_size_mismatch => refuse(refusal, .section_size_mismatch),
            error.section_repeated => refuse(refusal, .section_repeated),
            error.section_missing => refuse(refusal, .section_missing),
            error.cut_short => refuse(refusal, .cut_short),
            error.text_out_of_bounds => refuse(refusal, .text_out_of_bounds),
            error.run_out_of_bounds => refuse(refusal, .run_out_of_bounds),
            error.id_out_of_range => refuse(refusal, .id_out_of_range),
            error.results_out_of_order => refuse(refusal, .results_out_of_order),
        };
    }

    fn refuse(refusal: *Refusal, why: Refusal) Error {
        refusal.* = why;
        return error.Refused;
    }

    const Reason = error{ too_short, not_a_facts_file, other_version, sections_out_of_bounds, section_size_mismatch, section_repeated, section_missing, cut_short, text_out_of_bounds, run_out_of_bounds, id_out_of_range, results_out_of_order };

    fn check(bytes: []const u8) Reason!View {
        if (bytes.len < @sizeOf(Header)) return error.too_short;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.not_a_facts_file;
        if (std.mem.littleToNative(u32, header.version) != version) return error.other_version;
        const count: u64 = std.mem.littleToNative(u32, header.section_count);
        const directory_end = @sizeOf(Header) + count * @sizeOf(Section);
        if (directory_end > bytes.len) return error.sections_out_of_bounds;
        var view: View = .{};
        var seen: u32 = 0;
        var end: ?End = null;
        var at: usize = @sizeOf(Header);
        while (at < directory_end) : (at += @sizeOf(Section)) {
            const section = std.mem.bytesToValue(Section, bytes[at..][0..@sizeOf(Section)]);
            const offset = std.mem.littleToNative(u64, section.offset);
            const length = std.mem.littleToNative(u64, section.length);
            const records: u64 = std.mem.littleToNative(u32, section.count);
            if (offset < directory_end or offset > bytes.len or length > bytes.len - offset) return error.sections_out_of_bounds;
            const tag_raw = std.mem.littleToNative(u32, section.tag);
            // A tag this version does not know: skipped.
            if (tag_raw == 0 or tag_raw > @backingInt(Tag.end)) continue;
            const bit = @as(u32, 1) << @intCast(tag_raw);
            if (seen & bit != 0) return error.section_repeated;
            seen |= bit;
            const body = bytes[@intCast(offset)..][0..@intCast(length)];
            const tag: Tag = @fromBackingInt(tag_raw);
            switch (tag) {
                .strings => {
                    if (records != length) return error.section_size_mismatch;
                    view.strings = body;
                },
                .extra => view.extra = try records_of(u32, body, records),
                .config => view.config = try records_of(Config, body, records),
                .files => view.files = try records_of(File, body, records),
                .values => view.values = try records_of(Value, body, records),
                .bodies => view.bodies = try records_of(Body, body, records),
                .results => view.results = try records_of(Result, body, records),
                .end => {
                    const ends = try records_of(End, body, records);
                    if (ends.len != 1) return error.section_size_mismatch;
                    end = ends[0];
                },
                _ => unreachable, // unreachable: a tag past `end` is skipped above
            }
        }
        const required = [_]Tag{ .strings, .extra, .config, .files, .values, .bodies, .results };
        for (required) |tag| if (seen & (@as(u32, 1) << @intCast(@backingInt(tag))) == 0) return error.section_missing;
        const totals = end orelse return error.cut_short;
        if (little(totals.files) != view.files.len or little(totals.values) != view.values.len or little(totals.bodies) != view.bodies.len or little(totals.results) != view.results.len) return error.cut_short;
        try view.checkIds();
        return view;
    }

    fn records_of(comptime T: type, body: []const u8, records: u64) Reason![]align(1) const T {
        if (records * @sizeOf(T) != body.len) return error.section_size_mismatch;
        return @as([*]align(1) const T, @ptrCast(body.ptr))[0..@intCast(records)];
    }

    fn little(x: u32) u32 {
        return std.mem.littleToNative(u32, x);
    }

    fn checkIds(view: *const View) Reason!void {
        for (view.config) |each| {
            try view.checkText(each.key);
            try view.checkText(each.value);
        }
        for (view.files) |each| try view.checkText(each.path);
        for (view.values) |each| {
            try view.checkText(each.text);
            try view.checkRun(each.list);
        }
        for (view.bodies) |each| {
            if (little(each.file) >= view.files.len) return error.id_out_of_range;
            try view.checkRun(each.arguments);
            for (view.run(each.arguments)) |argument| try view.checkValue(argument);
            if (little(each.caller) != none and little(each.caller) >= view.bodies.len) return error.id_out_of_range;
            try view.checkValue(each.result);
            const start: u64 = little(each.results_start);
            const len: u64 = little(each.results_len);
            if (start > view.results.len or len > view.results.len - start) return error.run_out_of_bounds;
            var previous: ?Result = null;
            for (view.results[@intCast(start)..][0..@intCast(len)]) |result| {
                try view.checkValue(result.value);
                try view.checkValue(result.type);
                if (little(result.callee) != Result.runtime_callee) try view.checkValue(result.callee);
                if (previous) |before| {
                    const a = .{ little(before.instruction), little(before.visit) };
                    const b = .{ little(result.instruction), little(result.visit) };
                    if (a[0] > b[0] or (a[0] == b[0] and a[1] >= b[1])) return error.results_out_of_order;
                }
                previous = result;
            }
        }
    }

    fn checkText(view: *const View, text: Text) Reason!void {
        const start: u64 = little(text.start);
        const len: u64 = little(text.len);
        if (start > view.strings.len or len > view.strings.len - start) return error.text_out_of_bounds;
    }

    fn checkRun(view: *const View, list: Run) Reason!void {
        const start: u64 = little(list.start);
        const len: u64 = little(list.len);
        if (start > view.extra.len or len > view.extra.len - start) return error.run_out_of_bounds;
    }

    fn checkValue(view: *const View, id: u32) Reason!void {
        if (little(id) != none and little(id) >= view.values.len) return error.id_out_of_range;
    }

    /// The text of `text`, checked at `init`.
    pub fn string(view: *const View, text: Text) []const u8 {
        return view.strings[little(text.start)..][0..little(text.len)];
    }

    /// The numbers of `list`, checked at `init`. Each is little-endian as stored.
    pub fn run(view: *const View, list: Run) []align(1) const u32 {
        return view.extra[little(list.start)..][0..little(list.len)];
    }

    /// The results of `body`, in the order of (instruction, visit).
    pub fn resultsOf(view: *const View, body: Body) []align(1) const Result {
        return view.results[little(body.results_start)..][0..little(body.results_len)];
    }
};

/// A facts file being written: records appended, then `finish` lays the sections out. The
/// exporter gives it records in a canonical order of its own (files by path, bodies by file,
/// declaration, then arguments), so the same sources and configuration give the same bytes.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    strings: std.ArrayList(u8) = .empty,
    extra: std.ArrayList(u32) = .empty,
    config: std.ArrayList(Config) = .empty,
    files: std.ArrayList(File) = .empty,
    values: std.ArrayList(Value) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    results: std.ArrayList(Result) = .empty,

    pub fn deinit(self: *Builder) void {
        self.strings.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.config.deinit(self.gpa);
        self.files.deinit(self.gpa);
        self.values.deinit(self.gpa);
        self.bodies.deinit(self.gpa);
        self.results.deinit(self.gpa);
    }

    pub fn text(self: *Builder, bytes: []const u8) std.mem.Allocator.Error!Text {
        const start: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.gpa, bytes);
        return .{ .start = start, .len = @intCast(bytes.len) };
    }

    pub fn list(self: *Builder, numbers: []const u32) std.mem.Allocator.Error!Run {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.gpa, numbers);
        return .{ .start = start, .len = @intCast(numbers.len) };
    }

    /// The file's bytes, owned by the caller. Fields are written as the host has them: the
    /// format is little-endian and so is every host the exporter runs on (checked here).
    pub fn finish(self: *Builder) std.mem.Allocator.Error![]u8 {
        comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
        const end: End = .{ .files = @intCast(self.files.items.len), .values = @intCast(self.values.items.len), .bodies = @intCast(self.bodies.items.len), .results = @intCast(self.results.items.len) };
        const parts = [_]struct { tag: Tag, count: usize, bytes: []const u8 }{
            .{ .tag = .strings, .count = self.strings.items.len, .bytes = self.strings.items },
            .{ .tag = .extra, .count = self.extra.items.len, .bytes = std.mem.sliceAsBytes(self.extra.items) },
            .{ .tag = .config, .count = self.config.items.len, .bytes = std.mem.sliceAsBytes(self.config.items) },
            .{ .tag = .files, .count = self.files.items.len, .bytes = std.mem.sliceAsBytes(self.files.items) },
            .{ .tag = .values, .count = self.values.items.len, .bytes = std.mem.sliceAsBytes(self.values.items) },
            .{ .tag = .bodies, .count = self.bodies.items.len, .bytes = std.mem.sliceAsBytes(self.bodies.items) },
            .{ .tag = .results, .count = self.results.items.len, .bytes = std.mem.sliceAsBytes(self.results.items) },
            .{ .tag = .end, .count = 1, .bytes = std.mem.asBytes(&end) },
        };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        const header: Header = .{ .section_count = parts.len };
        try out.appendSlice(self.gpa, std.mem.asBytes(&header));
        var offset: u64 = @sizeOf(Header) + parts.len * @sizeOf(Section);
        for (parts) |part| {
            const section: Section = .{ .tag = @backingInt(part.tag), .count = @intCast(part.count), .offset = offset, .length = part.bytes.len };
            try out.appendSlice(self.gpa, std.mem.asBytes(&section));
            offset += part.bytes.len;
        }
        for (parts) |part| try out.appendSlice(self.gpa, part.bytes);
        return out.toOwnedSlice(self.gpa);
    }
};

test "a facts file written is read back, record for record" {
    const gpa = std.testing.allocator;
    var builder: Builder = .{ .gpa = gpa };
    defer builder.deinit();
    try builder.config.append(gpa, .{ .key = try builder.text("zig_version"), .value = try builder.text("0.17.0") });
    try builder.files.append(gpa, .{ .path = try builder.text("src/root.zig"), .hash = @splat(7) });
    try builder.values.append(gpa, .{ .kind = @backingInt(Value.Kind.int_type), .a = 32, .b = 0 });
    try builder.values.append(gpa, .{ .kind = @backingInt(Value.Kind.function), .a = 0, .b = 12, .c = 0, .text = try builder.text("id") });
    try builder.results.append(gpa, .{ .instruction = 14, .visit = 0, .type = 0, .callee = 1 });
    try builder.results.append(gpa, .{ .instruction = 14, .visit = 1, .value = 0 });
    try builder.bodies.append(gpa, .{ .kind = @backingInt(Body.Kind.function), .file = 0, .declaration = 12, .arguments = try builder.list(&.{ 0, none }), .results_start = 0, .results_len = 2 });
    const bytes = try builder.finish();
    defer gpa.free(bytes);

    var refusal: Refusal = undefined;
    const view = try View.init(bytes, &refusal);
    try std.testing.expectEqualStrings("0.17.0", view.string(view.config[0].value));
    try std.testing.expectEqualStrings("src/root.zig", view.string(view.files[0].path));
    try std.testing.expectEqual(@as(usize, 2), view.values.len);
    try std.testing.expectEqual(@as(usize, 2), view.resultsOf(view.bodies[0]).len);
    try std.testing.expectEqual(@as(u32, 1), view.resultsOf(view.bodies[0])[0].callee);
    try std.testing.expectEqual(none, view.run(view.bodies[0].arguments)[1]);
}

test "a facts file cut short, of another version, or naming what it does not hold is refused whole" {
    const gpa = std.testing.allocator;
    var builder: Builder = .{ .gpa = gpa };
    defer builder.deinit();
    try builder.files.append(gpa, .{ .path = try builder.text("a.zig"), .hash = @splat(0) });
    try builder.results.append(gpa, .{ .instruction = 3, .visit = 0 });
    try builder.bodies.append(gpa, .{ .kind = 0, .file = 0, .declaration = 1, .results_start = 0, .results_len = 1 });
    const good = try builder.finish();
    defer gpa.free(good);
    var refusal: Refusal = undefined;
    _ = try View.init(good, &refusal);

    // Every prefix of it is refused: none reads as fewer facts.
    for (0..good.len) |len| {
        try std.testing.expectError(error.Refused, View.init(good[0..len], &refusal));
    }
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    bad[0] = 'X';
    try std.testing.expectError(error.Refused, View.init(bad, &refusal));
    try std.testing.expectEqual(Refusal.not_a_facts_file, refusal);
    @memcpy(bad, good);
    bad[8] = 2;
    try std.testing.expectError(error.Refused, View.init(bad, &refusal));
    try std.testing.expectEqual(Refusal.other_version, refusal);

    // A body naming a file, a value or results the file does not hold.
    inline for (.{
        .{ "file", Refusal.id_out_of_range },
        .{ "result", Refusal.id_out_of_range },
        .{ "results_len", Refusal.run_out_of_bounds },
    }) |case| {
        var broken: Builder = .{ .gpa = gpa };
        defer broken.deinit();
        try broken.files.append(gpa, .{ .path = try broken.text("a.zig"), .hash = @splat(0) });
        var body: Body = .{ .kind = 0, .file = 0, .declaration = 1 };
        @field(body, case[0]) = 5;
        try broken.bodies.append(gpa, body);
        const bytes = try broken.finish();
        defer gpa.free(bytes);
        try std.testing.expectError(error.Refused, View.init(bytes, &refusal));
        try std.testing.expectEqual(case[1], refusal);
    }

    // Results out of the order of (instruction, visit).
    var unordered: Builder = .{ .gpa = gpa };
    defer unordered.deinit();
    try unordered.files.append(gpa, .{ .path = try unordered.text("a.zig"), .hash = @splat(0) });
    try unordered.results.append(gpa, .{ .instruction = 9, .visit = 0 });
    try unordered.results.append(gpa, .{ .instruction = 3, .visit = 0 });
    try unordered.bodies.append(gpa, .{ .kind = 0, .file = 0, .declaration = 1, .results_start = 0, .results_len = 2 });
    const bytes = try unordered.finish();
    defer gpa.free(bytes);
    try std.testing.expectError(error.Refused, View.init(bytes, &refusal));
    try std.testing.expectEqual(Refusal.results_out_of_order, refusal);
}
