//! glint's reader of a compiled-facts file (facts_format.zig), written as glint reads any
//! untrusted bytes: each number decoded field by field from the bytes, never through a pointer
//! cast, into records of this file's own (never the shared file's, which only the exporter
//! writes); each count checked against the bytes it claims, against the program's limit and
//! charged to one budget before memory is taken for it; each id typed and checked against what
//! it names before an accessor gives it out; and the file refused whole at the first thing
//! wrong, never read as fewer facts.
const std = @import("std");
const aegis = @import("aegis");
pub const format = @import("facts_format.zig");

/// A value of the file, by its position in the `values` section.
pub const ValueId = enum(u32) { _ };
/// A body of the file, by its position in the `bodies` section.
pub const BodyId = enum(u32) { _ };
/// A source file the file names, by its position in the `files` section.
pub const FileId = enum(u32) { _ };

/// Why a file is refused: one error a reason (`refusalText`).
pub const Refusal = error{
    TooShort,
    NotAFactsFile,
    OtherVersion,
    TooManySections,
    SectionsOutOfBounds,
    SectionSizeMismatch,
    SectionRepeated,
    SectionMissing,
    CutShort,
    TooLarge,
    TextOutOfBounds,
    RunOutOfBounds,
    IdOutOfRange,
    ResultsOutOfOrder,
};

pub const Error = Refusal || std.mem.Allocator.Error;

pub const Limits = struct {
    /// Records of every section together that one file may make the reader decode, and so the
    /// most any one section may hold. The `strings` section's bytes are read in place and are
    /// not charged.
    records: u64 = 1 << 28,
};

/// The most sections a file may list: the format has eight, and a newer one a few more.
const max_sections = 64;

/// Text: a run of the `strings` section, checked within it.
pub const Text = struct { start: u32, len: u32 };
/// Numbers: a run of the `extra` section, checked within it.
pub const Run = struct { start: u32, len: u32 };
pub const Config = struct { key: Text, value: Text };
pub const File = struct { path: Text, hash: [32]u8 };
/// A type or comptime-known value. What `a`, `b`, `c` and `list` hold is the kind's
/// (`format.shapeOf`): each id among them was checked by its role.
pub const Value = struct { kind: format.Value.Kind, a: u32, b: u32, c: u32, list: Run, text: Text };
pub const Body = struct {
    kind: format.Body.Kind,
    file: FileId,
    declaration: u32,
    function: ?ValueId,
    arguments: Run,
    caller: ?BodyId,
    call: u32,
    call_visit: u32,
    result: ?ValueId,
    results_start: u32,
    results_len: u32,
};
pub const Callee = union(enum) { none, runtime, function: ValueId };
pub const Result = struct { instruction: u32, visit: u32, value: ?ValueId, type: ?ValueId, callee: Callee };

/// The records of one file, every id among them checked. `strings` points into the bytes read,
/// which must outlive the records; everything else is the allocator's.
pub const Records = struct {
    strings: []const u8 = &.{},
    extra: []const u32 = &.{},
    config: []const Config = &.{},
    files: []const File = &.{},
    values: []const Value = &.{},
    bodies: []const Body = &.{},
    results: []const Result = &.{},

    pub fn value(records: *const Records, id: ValueId) ?Value {
        const at = @backingInt(id);
        if (at >= records.values.len) return null;
        return records.values[at];
    }

    pub fn body(records: *const Records, id: BodyId) ?Body {
        const at = @backingInt(id);
        if (at >= records.bodies.len) return null;
        return records.bodies[at];
    }

    pub fn file(records: *const Records, id: FileId) ?File {
        const at = @backingInt(id);
        if (at >= records.files.len) return null;
        return records.files[at];
    }

    /// The text `text` names, or null where it is not within the strings.
    pub fn string(records: *const Records, text: Text) ?[]const u8 {
        if (text.start > records.strings.len) return null;
        const rest = records.strings[text.start..];
        if (text.len > rest.len) return null;
        return rest[0..text.len];
    }

    /// The numbers `list` names, or null where they are not within the extra section.
    pub fn run(records: *const Records, list: Run) ?[]const u32 {
        if (list.start > records.extra.len) return null;
        const rest = records.extra[list.start..];
        if (list.len > rest.len) return null;
        return rest[0..list.len];
    }

    /// The results of `of`, in the order of (instruction, visit), or null where they are not
    /// within the results section.
    pub fn resultsOf(records: *const Records, of: Body) ?[]const Result {
        if (of.results_start > records.results.len) return null;
        const rest = records.results[of.results_start..];
        if (of.results_len > rest.len) return null;
        return rest[0..of.results_len];
    }
};

/// The records of the facts file `bytes`, or why it is refused.
pub fn read(gpa: std.mem.Allocator, bytes: aegis.input.Untrusted([]const u8), limits: Limits) Error!Records {
    var reading: Reading = .{ .gpa = gpa, .limit = limits.records, .budget = .init(limits.records) };
    return bytes.parse(&reading, parse);
}

/// Why a file was refused, in words.
pub fn refusalText(refusal: Refusal) []const u8 {
    return switch (refusal) {
        error.TooShort => "too short for its header",
        error.NotAFactsFile => "not a facts file",
        error.OtherVersion => "another version of the format",
        error.TooManySections => "more sections than a facts file has",
        error.SectionsOutOfBounds => "a section outside the file",
        error.SectionSizeMismatch => "a section whose size is not its records'",
        error.SectionRepeated => "a section given twice",
        error.SectionMissing => "a section missing",
        error.CutShort => "cut short",
        error.TooLarge => "more records than glint reads from one file",
        error.TextOutOfBounds => "text outside its section",
        error.RunOutOfBounds => "a list outside its section",
        error.IdOutOfRange => "an id naming what the file does not hold",
        error.ResultsOutOfOrder => "results out of their order",
    };
}

const Reading = struct {
    gpa: std.mem.Allocator,
    /// The most records one section may hold: the program's own limit.
    limit: u64,
    budget: aegis.bounded.Budget(u64),
};

/// A section's entry in the directory.
const Section = struct { tag: u32, count: u32, offset: u64, length: u64 };

/// Where each section the format knows lies.
const Placed = struct {
    strings: ?Section = null,
    extra: ?Section = null,
    config: ?Section = null,
    files: ?Section = null,
    values: ?Section = null,
    bodies: ?Section = null,
    results: ?Section = null,
    end: ?Section = null,
};

fn parse(reading: *Reading, bytes: []const u8) Error!Records {
    var header: std.Io.Reader = .fixed(bytes);
    const given_magic = header.takeArray(format.magic.len) catch return error.TooShort;
    if (!std.mem.eql(u8, given_magic, &format.magic)) return error.NotAFactsFile;
    const given_version = header.takeInt(u32, .little) catch return error.TooShort;
    if (given_version != format.version) return error.OtherVersion;
    const section_count = header.takeInt(u32, .little) catch return error.TooShort;
    if (section_count > max_sections) return error.TooManySections;

    var placed: Placed = .{};
    for (0..max_sections) |position| {
        if (position >= section_count) break;
        const section = decodeSection(&header) catch return error.SectionsOutOfBounds;
        const tag: format.Tag = @fromBackingInt(section.tag);
        const slot: *?Section = switch (tag) {
            .strings => &placed.strings,
            .extra => &placed.extra,
            .config => &placed.config,
            .files => &placed.files,
            .values => &placed.values,
            .bodies => &placed.bodies,
            .results => &placed.results,
            .end => &placed.end,
            // A tag this version does not know: skipped.
            _ => continue,
        };
        if (slot.* != null) return error.SectionRepeated;
        slot.* = section;
    }
    // No section lies over the header or the directory.
    const directory_end = header.seek;

    var records: Records = .{};
    const strings = try sectionBytes(bytes, directory_end, placed.strings);
    if (strings.count != strings.bytes.len) return error.SectionSizeMismatch;
    records.strings = strings.bytes;
    records.extra = try decodeAll(u32, @sizeOf(u32), reading, try sectionBytes(bytes, directory_end, placed.extra), number);
    records.config = try decodeAll(Config, @sizeOf(format.Config), reading, try sectionBytes(bytes, directory_end, placed.config), decodeConfig);
    records.files = try decodeAll(File, @sizeOf(format.File), reading, try sectionBytes(bytes, directory_end, placed.files), decodeFile);
    records.values = try decodeAll(Value, @sizeOf(format.Value), reading, try sectionBytes(bytes, directory_end, placed.values), decodeValue);
    records.bodies = try decodeAll(Body, @sizeOf(format.Body), reading, try sectionBytes(bytes, directory_end, placed.bodies), decodeBody);
    records.results = try decodeAll(Result, @sizeOf(format.Result), reading, try sectionBytes(bytes, directory_end, placed.results), decodeResult);

    // The totals: a file cut short at a section's end is refused, not read as fewer records.
    const end = sectionBytes(bytes, directory_end, placed.end) catch |err| switch (err) {
        error.SectionMissing => return error.CutShort,
        else => |other| return other,
    };
    if (end.count != 1 or end.bytes.len != @sizeOf(format.End)) return error.SectionSizeMismatch;
    var totals: std.Io.Reader = .fixed(end.bytes);
    const files = number(&totals) catch return error.CutShort;
    const values = number(&totals) catch return error.CutShort;
    const bodies = number(&totals) catch return error.CutShort;
    const results = number(&totals) catch return error.CutShort;
    if (files != records.files.len or values != records.values.len or bodies != records.bodies.len or results != records.results.len) return error.CutShort;

    try checkIds(&records);
    return records;
}

const Part = struct { bytes: []const u8, count: u32 };

/// The bytes of the section `placed`, checked within the file and after its directory.
fn sectionBytes(bytes: []const u8, directory_end: usize, placed: ?Section) Refusal!Part {
    const section = placed orelse return error.SectionMissing;
    const start = aegis.int.cast(usize, section.offset) catch return error.SectionsOutOfBounds;
    const len = aegis.int.cast(usize, section.length) catch return error.SectionsOutOfBounds;
    if (start < directory_end or start > bytes.len) return error.SectionsOutOfBounds;
    const rest = bytes[start..];
    if (len > rest.len) return error.SectionsOutOfBounds;
    return .{ .bytes = rest[0..len], .count = section.count };
}

/// Each record of `part`, `size` bytes each, decoded field by field, once its count is shown
/// to be what its bytes hold, within the program's limit, and charged to the budget.
fn decodeAll(comptime T: type, comptime size: usize, reading: *Reading, part: Part, comptime decode: fn (*std.Io.Reader) std.Io.Reader.Error!T) Error![]const T {
    const count = part.count;
    if (part.bytes.len % size != 0 or part.bytes.len / size != count) return error.SectionSizeMismatch;
    if (count > reading.limit) return error.TooLarge;
    var charge = reading.budget.reserve(count) catch return error.TooLarge;
    const out = reading.gpa.alloc(T, count) catch |err| {
        charge.release();
        return err;
    };
    charge.consume();
    var each_record: std.Io.Reader = .fixed(part.bytes);
    for (out) |*each| each.* = decode(&each_record) catch return error.CutShort;
    return out;
}

fn number(r: *std.Io.Reader) std.Io.Reader.Error!u32 {
    return r.takeInt(u32, .little);
}

/// The id `raw` holds, or null for `format.none`; whether it names a record is `checkIds`'.
fn valueId(raw: u32) ?ValueId {
    if (raw == format.none) return null;
    return @fromBackingInt(raw);
}

fn decodeText(r: *std.Io.Reader) std.Io.Reader.Error!Text {
    return .{ .start = try number(r), .len = try number(r) };
}

fn decodeRun(r: *std.Io.Reader) std.Io.Reader.Error!Run {
    return .{ .start = try number(r), .len = try number(r) };
}

fn decodeSection(r: *std.Io.Reader) std.Io.Reader.Error!Section {
    return .{ .tag = try number(r), .count = try number(r), .offset = try r.takeInt(u64, .little), .length = try r.takeInt(u64, .little) };
}

fn decodeConfig(r: *std.Io.Reader) std.Io.Reader.Error!Config {
    return .{ .key = try decodeText(r), .value = try decodeText(r) };
}

fn decodeFile(r: *std.Io.Reader) std.Io.Reader.Error!File {
    return .{ .path = try decodeText(r), .hash = (try r.takeArray(32)).* };
}

fn decodeValue(r: *std.Io.Reader) std.Io.Reader.Error!Value {
    return .{ .kind = @fromBackingInt(try number(r)), .a = try number(r), .b = try number(r), .c = try number(r), .list = try decodeRun(r), .text = try decodeText(r) };
}

fn decodeBody(r: *std.Io.Reader) std.Io.Reader.Error!Body {
    const kind: format.Body.Kind = @fromBackingInt(try number(r));
    const file_raw = try number(r);
    const declaration = try number(r);
    const function = valueId(try number(r));
    const arguments = try decodeRun(r);
    const caller_raw = try number(r);
    return .{
        .kind = kind,
        .file = @fromBackingInt(file_raw),
        .declaration = declaration,
        .function = function,
        .arguments = arguments,
        .caller = if (caller_raw == format.none) null else @fromBackingInt(caller_raw),
        .call = try number(r),
        .call_visit = try number(r),
        .result = valueId(try number(r)),
        .results_start = try number(r),
        .results_len = try number(r),
    };
}

fn decodeResult(r: *std.Io.Reader) std.Io.Reader.Error!Result {
    const instruction = try number(r);
    const visit = try number(r);
    const result_value = valueId(try number(r));
    const result_type = valueId(try number(r));
    const callee_raw = try number(r);
    const callee: Callee = if (callee_raw == format.none) .none else if (callee_raw == format.Result.runtime_callee) .runtime else .{ .function = @fromBackingInt(callee_raw) };
    return .{ .instruction = instruction, .visit = visit, .value = result_value, .type = result_type, .callee = callee };
}

/// Every text, list and id the records hold is within what it names.
fn checkIds(records: *const Records) Refusal!void {
    for (records.config) |each| {
        _ = records.string(each.key) orelse return error.TextOutOfBounds;
        _ = records.string(each.value) orelse return error.TextOutOfBounds;
    }
    for (records.files) |each| _ = records.string(each.path) orelse return error.TextOutOfBounds;
    for (records.values) |each| {
        _ = records.string(each.text) orelse return error.TextOutOfBounds;
        const list = records.run(each.list) orelse return error.RunOutOfBounds;
        const shape = format.shapeOf(each.kind);
        try checkField(records, shape.a, each.a);
        try checkField(records, shape.b, each.b);
        try checkField(records, shape.c, each.c);
        switch (shape.list) {
            .numbers => {},
            .values => for (list) |each_value| try checkValue(records, valueId(each_value)),
            // Each name as a text's start and length.
            .texts => {
                var rest = list;
                while (rest.len >= 2) : (rest = rest[2..]) {
                    _ = records.string(.{ .start = rest[0], .len = rest[1] }) orelse return error.TextOutOfBounds;
                }
            },
            // Each field as its name's start and length, then its type's value.
            .fields => {
                var rest = list;
                while (rest.len >= 3) : (rest = rest[3..]) {
                    _ = records.string(.{ .start = rest[0], .len = rest[1] }) orelse return error.TextOutOfBounds;
                    try checkValue(records, valueId(rest[2]));
                }
            },
        }
    }
    for (records.bodies) |each| {
        _ = records.file(each.file) orelse return error.IdOutOfRange;
        try checkValue(records, each.function);
        const arguments = records.run(each.arguments) orelse return error.RunOutOfBounds;
        for (arguments) |argument| try checkValue(records, valueId(argument));
        if (each.caller) |caller| _ = records.body(caller) orelse return error.IdOutOfRange;
        try checkValue(records, each.result);
        const results = records.resultsOf(each) orelse return error.RunOutOfBounds;
        var previous: ?Result = null;
        for (results) |result| {
            try checkValue(records, result.value);
            try checkValue(records, result.type);
            switch (result.callee) {
                .none, .runtime => {},
                .function => |callee| try checkValue(records, callee),
            }
            if (previous) |before| {
                if (before.instruction > result.instruction or (before.instruction == result.instruction and before.visit >= result.visit)) return error.ResultsOutOfOrder;
            }
            previous = result;
        }
    }
}

fn checkField(records: *const Records, kind: format.Field, raw: u32) Refusal!void {
    if (raw == format.none) return;
    switch (kind) {
        .number => {},
        .value => try checkValue(records, valueId(raw)),
        .file => _ = records.file(@fromBackingInt(raw)) orelse return error.IdOutOfRange,
        .body => _ = records.body(@fromBackingInt(raw)) orelse return error.IdOutOfRange,
    }
}

fn checkValue(records: *const Records, id: ?ValueId) Refusal!void {
    const known = id orelse return;
    _ = records.value(known) orelse return error.IdOutOfRange;
}

test "a facts file written is read back, record for record, its ids typed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var builder: format.Builder = .{ .gpa = gpa };
    try builder.config.append(gpa, .{ .key = try builder.text("zig_version"), .value = try builder.text("0.17.0") });
    try builder.files.append(gpa, .{ .path = try builder.text("src/root.zig"), .hash = @splat(7) });
    try builder.values.append(gpa, .{ .kind = @backingInt(format.Value.Kind.int_type), .a = 32, .b = 0 });
    try builder.values.append(gpa, .{ .kind = @backingInt(format.Value.Kind.function), .a = 0, .b = 12, .c = 0, .text = try builder.text("id") });
    try builder.results.append(gpa, .{ .instruction = 14, .visit = 0, .type = 0, .callee = 1 });
    try builder.results.append(gpa, .{ .instruction = 14, .visit = 1, .value = 0, .callee = format.Result.runtime_callee });
    try builder.bodies.append(gpa, .{ .kind = @backingInt(format.Body.Kind.function), .file = 0, .declaration = 12, .function = 1, .arguments = try builder.list(&.{ 0, format.none }), .results_start = 0, .results_len = 2 });
    const bytes = try builder.finish();

    const records = try read(gpa, .init(bytes), .{});
    try std.testing.expectEqualStrings("0.17.0", records.string(records.config[0].value).?);
    try std.testing.expectEqualStrings("src/root.zig", records.string(records.files[0].path).?);
    const first = records.bodies[0];
    try std.testing.expectEqual(format.Body.Kind.function, first.kind);
    try std.testing.expectEqual(@as(?BodyId, null), first.caller);
    const function = records.value(first.function.?).?;
    try std.testing.expectEqual(format.Value.Kind.function, function.kind);
    try std.testing.expectEqualStrings("id", records.string(function.text).?);
    const results = records.resultsOf(first).?;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(Callee{ .function = first.function.? }, results[0].callee);
    try std.testing.expectEqual(Callee.runtime, results[1].callee);
    try std.testing.expectEqual(@as(?ValueId, null), results[0].value);
    try std.testing.expectEqual(format.none, records.run(first.arguments).?[1]);
    try std.testing.expectEqual(@as(?Value, null), records.value(@fromBackingInt(2)));
}

test "a facts file cut short, of another version, too large or naming what it does not hold is refused whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var builder: format.Builder = .{ .gpa = gpa };
    try builder.files.append(gpa, .{ .path = try builder.text("a.zig"), .hash = @splat(0) });
    try builder.results.append(gpa, .{ .instruction = 3, .visit = 0 });
    try builder.bodies.append(gpa, .{ .kind = 0, .file = 0, .declaration = 1, .results_start = 0, .results_len = 1 });
    const good = try builder.finish();
    _ = try read(gpa, .init(good), .{});

    // Every prefix of it is refused: none reads as fewer facts.
    for (0..good.len) |len| try std.testing.expect(std.meta.isError(read(gpa, .init(good[0..len]), .{})));
    const bad = try gpa.dupe(u8, good);
    bad[0] = 'X';
    try std.testing.expectError(error.NotAFactsFile, read(gpa, .init(bad), .{}));
    @memcpy(bad, good);
    bad[8] = 2;
    try std.testing.expectError(error.OtherVersion, read(gpa, .init(bad), .{}));
    // More records than the limit allows.
    try std.testing.expectError(error.TooLarge, read(gpa, .init(good), .{ .records = 0 }));

    // A body naming a file, a value or results the file does not hold.
    inline for (.{
        .{ "file", error.IdOutOfRange },
        .{ "function", error.IdOutOfRange },
        .{ "result", error.IdOutOfRange },
        .{ "caller", error.IdOutOfRange },
        .{ "results_len", error.RunOutOfBounds },
    }) |case| {
        var broken: format.Builder = .{ .gpa = gpa };
        try broken.files.append(gpa, .{ .path = try broken.text("a.zig"), .hash = @splat(0) });
        var each: format.Body = .{ .kind = 0, .file = 0, .declaration = 1 };
        @field(each, case[0]) = 5;
        try broken.bodies.append(gpa, each);
        try std.testing.expectError(case[1], read(gpa, .init(try broken.finish()), .{}));
    }

    // Results out of the order of (instruction, visit).
    var unordered: format.Builder = .{ .gpa = gpa };
    try unordered.files.append(gpa, .{ .path = try unordered.text("a.zig"), .hash = @splat(0) });
    try unordered.results.append(gpa, .{ .instruction = 9, .visit = 0 });
    try unordered.results.append(gpa, .{ .instruction = 3, .visit = 0 });
    try unordered.bodies.append(gpa, .{ .kind = 0, .file = 0, .declaration = 1, .results_start = 0, .results_len = 2 });
    try std.testing.expectError(error.ResultsOutOfOrder, read(gpa, .init(try unordered.finish()), .{}));
}
