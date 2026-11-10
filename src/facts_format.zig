//! The compiled-facts file: what zig's own semantic analysis of one configuration holds for
//! glint, exported by exporter/<zig-version>/ (designs/glint-compiled-facts.md). This file holds
//! what the exporter and glint must agree on, and nothing else: the record layouts, the section
//! tags and their order, the version, what each value kind's fields hold, the `Builder` that
//! writes a file and the `canonical` order it is written in. It imports std alone and names
//! nothing of the compiler, so the exporter copies it as it is. glint reads a file with its own
//! reader of untrusted bytes (compiled_read.zig), never with anything here.
//!
//! Layout, little-endian: `Header`, then `section_count` `Section` entries, then each section's
//! bytes. Every section is an array of fixed-size records; each record is its fields in the
//! order declared here, every number a little-endian `u32` (a `Section`'s offset and length
//! `u64`), with no padding (checked below). A reader skips a tag it does not know. Lists (a
//! body's arguments, an aggregate's elements) are runs of the `extra` section; text is a run of
//! the `strings` section. The `end` section holds the totals, so a file cut short is refused,
//! never read as fewer facts.
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

/// The sections, in the order `Builder.finish` writes them.
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
    /// Records in the section (bytes, for `strings`).
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
/// `list` hold is the kind's (`Value.Kind`, `shapeOf`).
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
    /// The function analysed, as a `function` value: its name, and for an instance the instance.
    function: u32 = none,
    /// Each comptime argument's value, by parameter position: `none` for a runtime parameter.
    arguments: Run = .{},
    /// For a call analysed in place: the body holding the call, and the call's instruction.
    caller: u32 = none,
    call: u32 = none,
    /// Which visit of `call` within the caller it is, from 0.
    call_visit: u32 = 0,
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

// Each record is its fields with no padding, so its size is what a reader decodes field by field.
comptime {
    for (.{ .{ Header, 16 }, .{ Section, 24 }, .{ Config, 16 }, .{ File, 40 }, .{ Value, 32 }, .{ Body, 48 }, .{ Result, 20 }, .{ End, 16 } }) |each| {
        if (@sizeOf(each[0]) != each[1]) @compileError("a facts record is not the size its fields make");
    }
}

/// What a `Value`'s fields hold, by kind: which are values, files or bodies (ids a reader checks
/// and `canonical` renumbers) and which are numbers kept as they are.
pub const Field = enum { number, value, file, body };
pub const Listed = enum { numbers, values, texts, fields };
pub const Shape = struct { a: Field = .number, b: Field = .number, c: Field = .number, list: Listed = .numbers };

pub fn shapeOf(kind: Value.Kind) Shape {
    return switch (kind) {
        .unwritten, .simple_type, .int_type, .simple, .enum_literal => .{},
        .pointer_type, .optional_type, .array_type, .vector_type => .{ .a = .value },
        .error_union_type => .{ .a = .value, .b = .value },
        .error_set_type => .{ .list = .texts },
        .function_type => .{ .a = .value, .list = .values },
        .declared_type => .{ .a = .file, .list = .fields },
        .tuple_type => .{ .list = .values },
        .int, .float, .err, .bytes => .{ .a = .value },
        .enum_tag => .{ .a = .value },
        .aggregate => .{ .a = .value, .list = .values },
        .slice, .union_value => .{ .a = .value, .b = .value, .c = .value },
        .pointer, .optional => .{ .a = .value, .b = .value },
        .function => .{ .a = .file, .c = .body },
        // A kind this version does not know: its fields are kept as numbers.
        _ => .{},
    };
}

/// A facts file being written: records appended, then `finish` lays the sections out. An
/// exporter appends records as its analysis meets them and writes `canonical` of them, so the
/// same sources and configuration give the same bytes.
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
    pub fn finish(self: *const Builder) std.mem.Allocator.Error![]u8 {
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

/// Records that name what they do not hold: a writer's own mistake, never written.
pub const CanonicalError = std.mem.Allocator.Error || error{Inconsistent};

/// The same facts in the one order every exporter run of the same sources and configuration
/// gives: files by path, bodies by their function (file, declaration), kind, arguments and
/// caller, each body's results as they are, config by key, values and text in the order that
/// walk first names them. A value no body names is not kept. The result is the caller's.
pub fn canonical(gpa: std.mem.Allocator, from: *const Builder) CanonicalError!Builder {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var canon: Canon = .{ .arena = arena, .from = from, .out = .{ .gpa = gpa } };
    errdefer canon.out.deinit();
    const files = from.files.items;
    const bodies = from.bodies.items;

    // Files by path.
    const file_order = try arena.alloc(u32, files.len);
    const file_paths = try arena.alloc([]const u8, files.len);
    for (file_order, file_paths, files, 0..) |*each, *path, file, i| {
        each.* = @intCast(i);
        path.* = try canon.textOf(file.path);
    }
    std.mem.sort(u32, file_order, @as([]const []const u8, file_paths), lessByText);
    canon.file_new = try arena.alloc(u32, files.len);
    for (file_order, 0..) |old, new| {
        canon.file_new[old] = @intCast(new);
        try canon.out.files.append(gpa, .{ .path = try canon.out.text(file_paths[old]), .hash = files[old].hash });
    }

    // Bodies by key; equal keys keep the order given.
    canon.body_keys = try arena.alloc(?[]const u8, bodies.len);
    @memset(canon.body_keys, null);
    const keys = try arena.alloc([]const u8, bodies.len);
    const body_order = try arena.alloc(u32, bodies.len);
    for (body_order, keys, 0..) |*each, *key, i| {
        each.* = @intCast(i);
        key.* = try canon.bodyKey(@intCast(i), 0);
    }
    std.mem.sort(u32, body_order, @as([]const []const u8, keys), lessByText);
    canon.body_new = try arena.alloc(u32, bodies.len);
    for (body_order, 0..) |old, new| canon.body_new[old] = @intCast(new);

    // Config by key.
    const config = from.config.items;
    const config_order = try arena.alloc(u32, config.len);
    const config_keys = try arena.alloc([]const u8, config.len);
    for (config_order, config_keys, config, 0..) |*each, *key, entry, i| {
        each.* = @intCast(i);
        key.* = try canon.textOf(entry.key);
    }
    std.mem.sort(u32, config_order, @as([]const []const u8, config_keys), lessByText);
    for (config_order) |old| try canon.out.config.append(gpa, .{ .key = try canon.out.text(config_keys[old]), .value = try canon.out.text(try canon.textOf(config[old].value)) });

    // Values in the order the bodies, so ordered, first name them.
    canon.value_new = try arena.alloc(u32, from.values.items.len);
    @memset(canon.value_new, none);
    for (body_order) |old| {
        const body = bodies[old];
        const given = try canon.runOf(body.arguments);
        const arguments = try arena.alloc(u32, given.len);
        for (arguments, given) |*to, argument| to.* = try canon.value(argument);
        const function = try canon.value(body.function);
        const results_start: u32 = @intCast(canon.out.results.items.len);
        for (try canon.resultsOf(body)) |result| try canon.out.results.append(gpa, .{
            .instruction = result.instruction,
            .visit = result.visit,
            .value = try canon.value(result.value),
            .type = try canon.value(result.type),
            .callee = if (result.callee == Result.runtime_callee) Result.runtime_callee else try canon.value(result.callee),
        });
        try canon.out.bodies.append(gpa, .{
            .kind = body.kind,
            .file = try canon.fileOf(body.file),
            .declaration = body.declaration,
            .function = function,
            .arguments = try canon.out.list(arguments),
            .caller = if (body.caller == none) none else try canon.bodyOf(body.caller),
            .call = body.call,
            .call_visit = body.call_visit,
            .result = try canon.value(body.result),
            .results_start = results_start,
            .results_len = body.results_len,
        });
    }
    return canon.out;
}

fn lessByText(texts: []const []const u8, x: u32, y: u32) bool {
    return switch (std.mem.order(u8, texts[x], texts[y])) {
        .lt => true,
        .gt => false,
        .eq => x < y,
    };
}

const Canon = struct {
    arena: std.mem.Allocator,
    from: *const Builder,
    out: Builder,
    file_new: []u32 = &.{},
    body_new: []u32 = &.{},
    value_new: []u32 = &.{},
    body_keys: []?[]const u8 = &.{},

    fn textOf(self: *const Canon, text: Text) error{Inconsistent}![]const u8 {
        const strings = self.from.strings.items;
        if (text.start > strings.len or text.len > strings.len - text.start) return error.Inconsistent;
        return strings[text.start..][0..text.len];
    }

    fn runOf(self: *const Canon, run: Run) error{Inconsistent}![]const u32 {
        const extra = self.from.extra.items;
        if (run.start > extra.len or run.len > extra.len - run.start) return error.Inconsistent;
        return extra[run.start..][0..run.len];
    }

    fn resultsOf(self: *const Canon, body: Body) error{Inconsistent}![]const Result {
        const results = self.from.results.items;
        if (body.results_start > results.len or body.results_len > results.len - body.results_start) return error.Inconsistent;
        return results[body.results_start..][0..body.results_len];
    }

    fn fileOf(self: *const Canon, old: u32) error{Inconsistent}!u32 {
        if (old >= self.file_new.len) return error.Inconsistent;
        return self.file_new[old];
    }

    fn bodyOf(self: *const Canon, old: u32) error{Inconsistent}!u32 {
        if (old >= self.body_new.len) return error.Inconsistent;
        return self.body_new[old];
    }

    /// The new id of the value `old`, written with everything it names the first time it is
    /// asked. Its slot is taken before its fields are read, so a type that names itself ends.
    fn value(self: *Canon, old: u32) CanonicalError!u32 {
        if (old == none) return none;
        if (old >= self.value_new.len) return error.Inconsistent;
        if (self.value_new[old] != none) return self.value_new[old];
        const from = self.from.values.items[old];
        const new: u32 = @intCast(self.out.values.items.len);
        self.value_new[old] = new;
        try self.out.values.append(self.out.gpa, .{ .kind = from.kind });
        const shape = shapeOf(@fromBackingInt(from.kind));
        const made: Value = .{
            .kind = from.kind,
            .a = try self.field(shape.a, from.a),
            .b = try self.field(shape.b, from.b),
            .c = try self.field(shape.c, from.c),
            .text = try self.out.text(try self.textOf(from.text)),
            .list = try self.listed(shape.list, try self.runOf(from.list)),
        };
        self.out.values.items[new] = made;
        return new;
    }

    fn field(self: *Canon, kind: Field, old: u32) CanonicalError!u32 {
        if (old == none) return none;
        return switch (kind) {
            .number => old,
            .value => self.value(old),
            .file => self.fileOf(old),
            .body => self.bodyOf(old),
        };
    }

    fn listed(self: *Canon, kind: Listed, old: []const u32) CanonicalError!Run {
        const made = try self.arena.dupe(u32, old);
        switch (kind) {
            .numbers => {},
            .values => for (made) |*each| {
                each.* = try self.value(each.*);
            },
            // Each name as a `Text`'s start and length: written again in this order.
            .texts => {
                var at: usize = 0;
                while (at + 2 <= made.len) : (at += 2) {
                    const text = try self.out.text(try self.textOf(.{ .start = made[at], .len = made[at + 1] }));
                    made[at] = text.start;
                    made[at + 1] = text.len;
                }
            },
            // Three numbers a field: its name's start and length, its type's value.
            .fields => {
                var at: usize = 0;
                while (at + 3 <= made.len) : (at += 3) {
                    const text = try self.out.text(try self.textOf(.{ .start = made[at], .len = made[at + 1] }));
                    made[at] = text.start;
                    made[at + 1] = text.len;
                    made[at + 2] = try self.value(made[at + 2]);
                }
            },
        }
        return self.out.list(made);
    }

    /// What orders a body: its function's file and declaration, its kind, each argument by
    /// structure, and for a call analysed in place its caller's key, the call and its visit.
    fn bodyKey(self: *Canon, old: u32, depth: u8) CanonicalError![]const u8 {
        if (old >= self.body_keys.len) return error.Inconsistent;
        if (self.body_keys[old]) |known| return known;
        const body = self.from.bodies.items[old];
        if (body.file >= self.from.files.items.len) return error.Inconsistent;
        var key: std.ArrayList(u8) = .empty;
        try key.appendSlice(self.arena, try self.textOf(self.from.files.items[body.file].path));
        try key.print(self.arena, "\x00{x:0>8}\x00{x:0>8}\x00", .{ body.declaration, body.kind });
        for (try self.runOf(body.arguments)) |argument| {
            try self.valueKey(&key, argument, 0);
            try key.append(self.arena, 0);
        }
        if (body.caller != none and body.caller != old and depth < 64) {
            try key.appendSlice(self.arena, try self.bodyKey(body.caller, depth + 1));
            try key.print(self.arena, "\x00{x:0>8}\x00{x:0>8}", .{ body.call, body.call_visit });
        }
        self.body_keys[old] = key.items;
        return key.items;
    }

    /// A value by structure, never by id. A declared type and a function are their
    /// declaration's file and instruction: what they name in turn is not followed, so a type
    /// that names itself ends.
    fn valueKey(self: *Canon, key: *std.ArrayList(u8), old: u32, depth: u8) CanonicalError!void {
        if (old == none) return key.appendSlice(self.arena, "-");
        if (depth > 32) return key.appendSlice(self.arena, "...");
        if (old >= self.from.values.items.len) return error.Inconsistent;
        const from = self.from.values.items[old];
        const known: Value.Kind = @fromBackingInt(from.kind);
        const shape = shapeOf(known);
        try key.print(self.arena, "({x}:{s}", .{ from.kind, try self.textOf(from.text) });
        const leaf = known == .declared_type or known == .function;
        inline for (.{ .{ shape.a, from.a }, .{ shape.b, from.b }, .{ shape.c, from.c } }) |each| {
            try key.append(self.arena, ' ');
            switch (each[0]) {
                .number, .body => try key.print(self.arena, "{x}", .{each[1]}),
                .file => try key.appendSlice(self.arena, if (each[1] < self.from.files.items.len) try self.textOf(self.from.files.items[each[1]].path) else "-"),
                .value => try self.valueKey(key, each[1], depth + 1),
            }
        }
        if (!leaf) {
            const numbers = try self.runOf(from.list);
            switch (shape.list) {
                .numbers => for (numbers) |n| try key.print(self.arena, " {x}", .{n}),
                .values => for (numbers) |n| {
                    try key.append(self.arena, ' ');
                    try self.valueKey(key, n, depth + 1);
                },
                .texts, .fields => {
                    const step: usize = if (shape.list == .texts) 2 else 3;
                    var at: usize = 0;
                    while (at + step <= numbers.len) : (at += step) try key.print(self.arena, " {s}", .{try self.textOf(.{ .start = numbers[at], .len = numbers[at + 1] })});
                },
            }
        }
        try key.append(self.arena, ')');
    }
};

/// Two instances of one generic in a.zig, an inline call in one of them in b.zig, a type that
/// names itself through a pointer; `way` 1 appends every record the other way round.
fn sample(gpa: std.mem.Allocator, way: usize) std.mem.Allocator.Error!Builder {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.deinit();
    const paths = [_][]const u8{ "src/a.zig", "src/b.zig" };
    const file_of = if (way == 0) [_]u32{ 0, 1 } else [_]u32{ 1, 0 };
    for (0..2) |i| {
        const which = if (way == 0) i else 1 - i;
        try b.files.append(gpa, .{ .path = try b.text(paths[which]), .hash = @splat(@intCast(which)) });
    }
    try b.config.append(gpa, .{ .key = try b.text(if (way == 0) "target" else "zig_version"), .value = try b.text(if (way == 0) "aarch64-macos" else "0.17.0") });
    try b.config.append(gpa, .{ .key = try b.text(if (way == 0) "zig_version" else "target"), .value = try b.text(if (way == 0) "0.17.0" else "aarch64-macos") });
    // Values: u8, a declared Node with a field `next: ?*Node`, the pointer, the optional, and
    // the functions f and g.
    var ids: [6]u32 = @splat(0);
    const order = if (way == 0) [_]usize{ 0, 1, 2, 3, 4, 5 } else [_]usize{ 5, 4, 3, 2, 1, 0 };
    for (order, 0..) |which, at| ids[which] = @intCast(at);
    for (order) |which| switch (which) {
        0 => try b.values.append(gpa, .{ .kind = @backingInt(Value.Kind.int_type), .a = 8, .b = 0 }),
        1 => {
            const field_name = try b.text("next");
            try b.values.append(gpa, .{ .kind = @backingInt(Value.Kind.declared_type), .a = file_of[0], .b = 40, .c = 0, .text = try b.text("Node"), .list = try b.list(&.{ field_name.start, field_name.len, ids[3] }) });
        },
        2 => try b.values.append(gpa, .{ .kind = @backingInt(Value.Kind.pointer_type), .a = ids[1], .b = 0, .c = 0 }),
        3 => try b.values.append(gpa, .{ .kind = @backingInt(Value.Kind.optional_type), .a = ids[2] }),
        4 => try b.values.append(gpa, .{ .kind = @backingInt(Value.Kind.function), .a = file_of[0], .b = 10, .text = try b.text("a.f") }),
        5 => try b.values.append(gpa, .{ .kind = @backingInt(Value.Kind.function), .a = file_of[1], .b = 7, .text = try b.text("b.g") }),
        else => unreachable, // unreachable: `order` holds 0 to 5
    };
    // Bodies: f(u8) and f(Node) in a.zig, and an inline call of g inside f(Node).
    const bodies = if (way == 0) [_]usize{ 0, 1, 2 } else [_]usize{ 2, 1, 0 };
    var body_id: [3]u32 = @splat(0);
    for (bodies, 0..) |which, at| body_id[which] = @intCast(at);
    for (bodies) |which| {
        const start: u32 = @intCast(b.results.items.len);
        switch (which) {
            0 => {
                try b.results.append(gpa, .{ .instruction = 12, .visit = 0, .type = ids[0] });
                try b.bodies.append(gpa, .{ .kind = 0, .file = file_of[0], .declaration = 10, .function = ids[4], .arguments = try b.list(&.{ids[0]}), .results_start = start, .results_len = 1 });
            },
            1 => {
                try b.results.append(gpa, .{ .instruction = 12, .visit = 0, .type = ids[2] });
                try b.results.append(gpa, .{ .instruction = 13, .visit = 0, .value = ids[1] });
                try b.bodies.append(gpa, .{ .kind = 0, .file = file_of[0], .declaration = 10, .function = ids[4], .arguments = try b.list(&.{ids[1]}), .results_start = start, .results_len = 2 });
            },
            2 => try b.bodies.append(gpa, .{ .kind = 1, .file = file_of[1], .declaration = 7, .function = ids[5], .caller = body_id[1], .call = 13, .call_visit = 0, .results_start = start, .results_len = 0 }),
            else => unreachable, // unreachable: `bodies` holds 0 to 2
        }
    }
    return b;
}

test "canonical: the same facts appended in another order give the same bytes, and canonical of canonical is itself" {
    const gpa = std.testing.allocator;
    var forward = try sample(gpa, 0);
    defer forward.deinit();
    var backward = try sample(gpa, 1);
    defer backward.deinit();
    var made = try canonical(gpa, &forward);
    defer made.deinit();
    var made_backward = try canonical(gpa, &backward);
    defer made_backward.deinit();
    const bytes = try made.finish();
    defer gpa.free(bytes);
    const bytes_backward = try made_backward.finish();
    defer gpa.free(bytes_backward);
    try std.testing.expectEqualSlices(u8, bytes, bytes_backward);
    // Files by path, the generic's two instances together, the inline call after its function.
    const c = &made;
    try std.testing.expectEqualStrings("src/a.zig", c.strings.items[c.files.items[0].path.start..][0..c.files.items[0].path.len]);
    try std.testing.expectEqual(@as(usize, 3), c.bodies.items.len);
    try std.testing.expectEqual(@as(u32, 0), c.bodies.items[0].file);
    try std.testing.expectEqual(@as(u32, 0), c.bodies.items[1].file);
    try std.testing.expectEqual(@as(u32, 1), c.bodies.items[2].file);
    try std.testing.expect(c.bodies.items[2].caller < 2);
    // Every value a body names is kept: u8, Node, the pointer, the optional, f and g.
    try std.testing.expectEqual(@as(usize, 6), c.values.items.len);
    var again = try canonical(gpa, c);
    defer again.deinit();
    const twice = try again.finish();
    defer gpa.free(twice);
    try std.testing.expectEqualSlices(u8, bytes, twice);
}

test "canonical: records naming what they do not hold are the writer's mistake, never written" {
    const gpa = std.testing.allocator;
    inline for (.{ "file", "function", "caller", "results_len" }) |name| {
        var b: Builder = .{ .gpa = gpa };
        defer b.deinit();
        try b.files.append(gpa, .{ .path = try b.text("a.zig"), .hash = @splat(0) });
        var body: Body = .{ .kind = 0, .file = 0, .declaration = 1 };
        @field(body, name) = 5;
        try b.bodies.append(gpa, body);
        try std.testing.expectError(error.Inconsistent, canonical(gpa, &b));
    }
}
