//! A value Facts resolved, written in ids that hold across runs, and read back into another
//! run's Facts (designs/glint-summaries.md, step 2). A run's ids are positions: a file is the
//! nth input, a reading or a set of assumptions the nth made. Within one file, a declaration,
//! a scope and a node are fixed by the file's bytes (the front end numbers them in source
//! order), so a file is written by the name its unit gives it and the hash of its bytes, and the
//! rest by index. Reading a value back into a run whose file under that name has other bytes,
//! or none, fails: a summary is never read against sources it was not made from.
//! Readings are read back through `Facts.keptReading` and sets of assumptions through
//! `Facts.intern`, so a value read back is the one the run would make: kept by the same
//! address where the run keys by address.
const std = @import("std");
const Ast = std.zig.Ast;
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Value = Facts.Value;
const Env = Facts.Env;
const Made = Facts.Made;
const Decl = Facts.Decl;

/// The format's version: a reader refuses any other.
pub const version: u32 = 1;

/// The name each file of a run has in its unit (std's `lib/std/mem.zig` as `std/mem.zig`, a
/// dependency's by its path in the package), and the run's file under each name. A file
/// without one is not written: a value naming it is refused (`error.Unnamed`).
pub const Names = struct {
    of: []const ?[]const u8,
    files: std.StringHashMapUnmanaged(Project.FileId) = .empty,

    /// Each file by its input's name, as tests and a single unit's run give them.
    pub fn byInput(gpa: std.mem.Allocator, project: *const Project) !Names {
        const of = try gpa.alloc(?[]const u8, project.sources.len);
        var names: Names = .{ .of = of };
        for (project.sources, of) |source, *name| {
            name.* = source.input.name;
            try names.files.put(gpa, source.input.name, source.id);
        }
        return names;
    }

    pub fn deinit(self: *Names, gpa: std.mem.Allocator) void {
        gpa.free(self.of);
        self.files.deinit(gpa);
    }
};

pub const WriteError = std.mem.Allocator.Error || error{Unnamed};
pub const ReadError = Facts.ResolveError || error{ Truncated, Malformed, Version, Stale };

/// Writes values into one stream. Each file, string, reading, making and set of assumptions is
/// written whole where the stream first meets it and by its number after, so a reader reading
/// the values in the order they were written meets each before any use of it.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    facts: *const Facts,
    names: *const Names,
    bytes: std.ArrayList(u8) = .empty,
    files: std.AutoHashMapUnmanaged(Project.FileId, u32) = .empty,
    strings: std.StringHashMapUnmanaged(u32) = .empty,
    envs: std.AutoHashMapUnmanaged(*const Env, u32) = .empty,
    mades: std.AutoHashMapUnmanaged(*const Made, u32) = .empty,
    sets: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn init(gpa: std.mem.Allocator, facts: *const Facts, names: *const Names) WriteError!Writer {
        var writer: Writer = .{ .gpa = gpa, .facts = facts, .names = names };
        try writer.number(version);
        return writer;
    }

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.gpa);
        self.files.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.envs.deinit(self.gpa);
        self.mades.deinit(self.gpa);
        self.sets.deinit(self.gpa);
    }

    pub fn value(self: *Writer, v: Value) WriteError!void {
        try self.number(@backingInt(std.meta.activeTag(v)));
        switch (v) {
            .unknown => |why| try self.number(@backingInt(why)),
            .primitive => |name| try self.string(name),
            .container, .instance => |k| {
                try self.source(k.file);
                try self.number(@backingInt(k.scope));
                try self.number(@intFromBool(k.symbolic));
                try self.made(k.made_by);
            },
            .function => |d| try self.decl(d),
            .pointer => |p| {
                try self.value(p.child.*);
                try self.number(if (p.size) |size| @as(u32, @backingInt(size)) + 1 else 0);
            },
            .array, .optional, .error_union => |inner| try self.value(inner.*),
            .error_set, .scalar => {},
            .alternatives => |each| {
                try self.number(@intCast(each.len));
                for (each) |one| try self.value(one);
            },
            .reflected => |r| {
                try self.value(r.of.*);
                try self.number(@backingInt(r.at));
            },
            .literal, .fn_type => |k| try self.key(k),
            .reified => |r| {
                try self.value(r.fields.*);
                try self.number(@intFromBool(r.value));
            },
        }
    }

    fn decl(self: *Writer, d: Decl) WriteError!void {
        try self.source(d.file);
        try self.number(@backingInt(d.index));
    }

    pub fn key(self: *Writer, k: Facts.Key) WriteError!void {
        try self.source(k.file);
        try self.number(@backingInt(k.node));
    }

    /// A reference to what `table` numbers: 0 and the thing itself where it is new, its number
    /// plus one after. True where the caller is to write it, then `numbered` it: a thing is
    /// numbered after its parts, as a reader makes it after them. What a run makes refers only
    /// to what it made before, so no part of a thing is the thing.
    fn seen(self: *Writer, table: anytype, k: anytype) WriteError!bool {
        if (table.get(k)) |n| {
            try self.number(n + 1);
            return false;
        }
        try self.number(0);
        return true;
    }

    fn numbered(self: *Writer, table: anytype, k: anytype) WriteError!void {
        try table.putNoClobber(self.gpa, k, table.count());
    }

    fn source(self: *Writer, id: Project.FileId) WriteError!void {
        if (!try self.seen(&self.files, id)) return;
        const name = self.names.of[@backingInt(id)] orelse return error.Unnamed;
        try self.string(name);
        try self.fixed(std.hash.Wyhash.hash(0, self.facts.project.at(id).input.bytes));
        try self.numbered(&self.files, id);
    }

    fn string(self: *Writer, s: []const u8) WriteError!void {
        if (!try self.seen(&self.strings, s)) return;
        try self.number(@intCast(s.len));
        try self.bytes.appendSlice(self.gpa, s);
        try self.numbered(&self.strings, s);
    }

    fn optionalEnv(self: *Writer, env: ?*const Env) WriteError!void {
        try self.number(@intFromBool(env != null));
        if (env) |e| try self.reading(e);
    }

    fn reading(self: *Writer, env: *const Env) WriteError!void {
        if (!try self.seen(&self.envs, env)) return;
        try self.decl(env.function);
        try self.optionalEnv(env.outer);
        try self.number(@intCast(env.depth));
        try self.number(@intCast(env.nested));
        try self.number(@intCast(env.args.len));
        for (env.args) |arg| try self.value(arg);
        try self.number(@intCast(env.truths.len));
        for (env.truths) |truth| try self.number(if (truth) |t| @as(u32, @intFromBool(t)) + 1 else 0);
        try self.number(@intCast(env.spelled.len));
        for (env.spelled) |spelled| {
            const s = spelled orelse {
                try self.number(0);
                continue;
            };
            switch (s) {
                .name => |name| {
                    try self.number(1);
                    try self.string(name);
                },
                .number => |n| {
                    try self.number(2);
                    try self.wide(n);
                },
            }
        }
        try self.number(@intCast(env.values.len));
        for (env.values) |is| try self.number(@intFromBool(is));
        try self.numbered(&self.envs, env);
    }

    fn made(self: *Writer, m: ?*const Made) WriteError!void {
        try self.number(@intFromBool(m != null));
        const one = m orelse return;
        if (!try self.seen(&self.mades, one)) return;
        try self.decl(one.function);
        try self.source(one.file);
        try self.number(@backingInt(one.call));
        try self.optionalEnv(one.env);
        try self.assumed(one.assumed);
        try self.made(one.via);
        try self.optionalEnv(one.reading);
        try self.optionalEnv(one.bound);
        try self.numbered(&self.mades, one);
    }

    fn assumed(self: *Writer, set: @FieldType(Made, "assumed")) WriteError!void {
        try self.number(@intFromBool(set != null));
        const id = set orelse return;
        if (!try self.seen(&self.sets, @backingInt(id))) return;
        const held = self.facts.settled.items[@backingInt(id)].held;
        try self.number(@intCast(held.len));
        for (held) |one| {
            try self.decl(one.parameter);
            switch (one.value) {
                .boolean => |b| try self.number(@intFromBool(b)),
                .tag => |name| {
                    try self.number(2);
                    try self.string(name);
                },
            }
        }
        try self.numbered(&self.sets, @backingInt(id));
    }

    pub fn number(self: *Writer, n: u32) WriteError!void {
        try self.wide(n);
    }

    /// LEB128.
    pub fn wide(self: *Writer, n: usize) WriteError!void {
        var rest: u64 = n;
        while (true) {
            const low: u8 = @truncate(rest & 0x7f);
            rest >>= 7;
            if (rest == 0) return self.bytes.append(self.gpa, low);
            try self.bytes.append(self.gpa, low | 0x80);
        }
    }

    fn fixed(self: *Writer, n: u64) WriteError!void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, n, .little);
        try self.bytes.appendSlice(self.gpa, &buffer);
    }
};

/// Reads values a `Writer` wrote, in the order it wrote them, into `facts`'s run: each file by
/// its name in `names`, its bytes checked against the hash written; each id checked against
/// that file's front end. What it makes lives on `facts.gpa`, as what the run resolves does.
pub const Reader = struct {
    facts: *Facts,
    names: *const Names,
    bytes: []const u8,
    at: usize = 0,
    files: std.ArrayList(Project.FileId) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    envs: std.ArrayList(*const Env) = .empty,
    mades: std.ArrayList(*const Made) = .empty,
    sets: std.ArrayList(@FieldType(Made, "assumed")) = .empty,

    pub fn init(facts: *Facts, names: *const Names, bytes: []const u8) ReadError!Reader {
        var reader: Reader = .{ .facts = facts, .names = names, .bytes = bytes };
        if (try reader.number() != version) return error.Version;
        return reader;
    }

    pub fn deinit(self: *Reader) void {
        const gpa = self.facts.gpa;
        self.files.deinit(gpa);
        self.strings.deinit(gpa);
        self.envs.deinit(gpa);
        self.mades.deinit(gpa);
        self.sets.deinit(gpa);
    }

    /// Whether every value written has been read.
    pub fn done(self: *const Reader) bool {
        return self.at == self.bytes.len;
    }

    pub fn value(self: *Reader) ReadError!Value {
        const tag = try self.enumeration(std.meta.Tag(Value));
        return switch (tag) {
            .unknown => .{ .unknown = try self.enumeration(Facts.Unknown) },
            .primitive => .{ .primitive = try self.string() },
            inline .container, .instance => |t| @unionInit(Value, @tagName(t), try self.container()),
            .function => .{ .function = try self.decl() },
            .pointer => blk: {
                const child = try self.boxed(try self.value());
                const size = try self.number();
                break :blk .{ .pointer = .{ .child = child, .size = if (size == 0) null else try toEnum(Facts.Size, size - 1) } };
            },
            inline .array, .optional, .error_union => |t| @unionInit(Value, @tagName(t), try self.boxed(try self.value())),
            .error_set => .error_set,
            .scalar => .scalar,
            .alternatives => blk: {
                const each = try self.facts.gpa.alloc(Value, try self.count());
                for (each) |*one| one.* = try self.value();
                break :blk .{ .alternatives = each };
            },
            .reflected => blk: {
                const of = try self.boxed(try self.value());
                break :blk .{ .reflected = .{ .of = of, .at = try self.enumeration(@FieldType(Facts.Reflected, "at")) } };
            },
            inline .literal, .fn_type => |t| @unionInit(Value, @tagName(t), try self.key()),
            .reified => blk: {
                const fields = try self.boxed(try self.value());
                break :blk .{ .reified = .{ .fields = fields, .value = try self.flag() } };
            },
        };
    }

    fn container(self: *Reader) ReadError!Facts.Container {
        const file = try self.source();
        const scope = try self.number();
        if (scope >= self.facts.project.at(file).model.scopes.len) return error.Malformed;
        const symbolic = try self.flag();
        return .{ .file = file, .scope = @fromBackingInt(scope), .symbolic = symbolic, .made_by = try self.made() };
    }

    fn decl(self: *Reader) ReadError!Decl {
        const file = try self.source();
        const index = try self.number();
        if (index >= self.facts.project.at(file).model.declarations.len) return error.Malformed;
        return .{ .file = file, .index = @fromBackingInt(index) };
    }

    pub fn key(self: *Reader) ReadError!Facts.Key {
        const file = try self.source();
        return .{ .file = file, .node = try self.node(file) };
    }

    fn node(self: *Reader, file: Project.FileId) ReadError!Ast.Node.Index {
        const index = try self.number();
        if (index >= self.facts.project.at(file).file.tree.nodes.len) return error.Malformed;
        return @fromBackingInt(@intCast(index));
    }

    fn optionalNode(self: *Reader, file: Project.FileId) ReadError!?Ast.Node.Index {
        const n = try self.number();
        if (n == 0) return null;
        if (n - 1 >= self.facts.project.at(file).file.tree.nodes.len) return error.Malformed;
        return @fromBackingInt(@intCast(n - 1));
    }

    /// What a `Writer.seen` reference names: the number of one read before, or null where the
    /// thing itself follows.
    fn reference(self: *Reader, len: usize) ReadError!?usize {
        const n = try self.number();
        if (n == 0) return null;
        if (n - 1 >= len) return error.Malformed;
        return n - 1;
    }

    fn source(self: *Reader) ReadError!Project.FileId {
        if (try self.reference(self.files.items.len)) |at| return self.files.items[at];
        const name = try self.string();
        const hash = try self.fixed();
        const id = self.names.files.get(name) orelse return error.Stale;
        if (std.hash.Wyhash.hash(0, self.facts.project.at(id).input.bytes) != hash) return error.Stale;
        try self.files.append(self.facts.gpa, id);
        return id;
    }

    fn string(self: *Reader) ReadError![]const u8 {
        if (try self.reference(self.strings.items.len)) |at| return self.strings.items[at];
        const len = try self.count();
        if (self.bytes.len - self.at < len) return error.Truncated;
        const s = try self.facts.gpa.dupe(u8, self.bytes[self.at..][0..len]);
        self.at += len;
        try self.strings.append(self.facts.gpa, s);
        return s;
    }

    fn optionalEnv(self: *Reader) ReadError!?*const Env {
        return if (try self.flag()) try self.reading() else null;
    }

    fn reading(self: *Reader) ReadError!*const Env {
        if (try self.reference(self.envs.items.len)) |at| return self.envs.items[at];
        const gpa = self.facts.gpa;
        const function = try self.decl();
        const outer = try self.optionalEnv();
        const depth = try self.wide();
        const nested = try self.wide();
        const args = try gpa.alloc(Value, try self.count());
        for (args) |*arg| arg.* = try self.value();
        const truths = try gpa.alloc(?bool, try self.count());
        for (truths) |*truth| truth.* = switch (try self.number()) {
            0 => null,
            1 => false,
            2 => true,
            else => return error.Malformed,
        };
        const spelled = try gpa.alloc(?Facts.Spelled, try self.count());
        for (spelled) |*s| s.* = switch (try self.number()) {
            0 => null,
            1 => .{ .name = try self.string() },
            2 => .{ .number = try self.wide() },
            else => return error.Malformed,
        };
        const values = try gpa.alloc(bool, try self.count());
        for (values) |*is| is.* = try self.flag();
        const env = try self.facts.keptReading(.{ .function = function, .args = args, .depth = depth, .nested = nested, .truths = truths, .outer = outer, .spelled = spelled, .values = values });
        try self.envs.append(gpa, env);
        return env;
    }

    fn made(self: *Reader) ReadError!?*const Made {
        if (!try self.flag()) return null;
        if (try self.reference(self.mades.items.len)) |at| return self.mades.items[at];
        const one = try self.facts.gpa.create(Made);
        const function = try self.decl();
        const file = try self.source();
        one.* = .{
            .function = function,
            .file = file,
            .call = try self.node(file),
            .env = try self.optionalEnv(),
            .assumed = try self.assumed(),
            .via = try self.made(),
            .reading = try self.optionalEnv(),
            .bound = try self.optionalEnv(),
        };
        try self.mades.append(self.facts.gpa, one);
        return one;
    }

    fn assumed(self: *Reader) ReadError!@FieldType(Made, "assumed") {
        if (!try self.flag()) return null;
        if (try self.reference(self.sets.items.len)) |at| return self.sets.items[at];
        const gpa = self.facts.gpa;
        const held = try gpa.alloc(Facts.Assumption, try self.count());
        for (held) |*one| {
            const parameter = try self.decl();
            one.* = .{ .parameter = parameter, .value = switch (try self.number()) {
                0 => .{ .boolean = false },
                1 => .{ .boolean = true },
                2 => .{ .tag = try self.string() },
                else => return error.Malformed,
            } };
        }
        const id = try self.facts.intern(held);
        try self.sets.append(gpa, id);
        return id;
    }

    fn boxed(self: *Reader, v: Value) ReadError!*const Value {
        const box = try self.facts.gpa.create(Value);
        box.* = v;
        return box;
    }

    fn enumeration(self: *Reader, comptime E: type) ReadError!E {
        return toEnum(E, try self.number());
    }

    fn flag(self: *Reader) ReadError!bool {
        return switch (try self.number()) {
            0 => false,
            1 => true,
            else => error.Malformed,
        };
    }

    /// A length: never more than the bytes left, as each item takes at least one.
    pub fn count(self: *Reader) ReadError!usize {
        const n = try self.wide();
        if (n > self.bytes.len - self.at) return error.Malformed;
        return n;
    }

    pub fn number(self: *Reader) ReadError!u32 {
        return std.math.cast(u32, try self.wide()) orelse error.Malformed;
    }

    pub fn wide(self: *Reader) ReadError!usize {
        var n: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (self.at == self.bytes.len) return error.Truncated;
            const byte = self.bytes[self.at];
            self.at += 1;
            if (shift >= 64) return error.Malformed;
            n |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return std.math.cast(usize, n) orelse error.Malformed;
            shift += 7;
        }
    }

    fn fixed(self: *Reader) ReadError!u64 {
        if (self.bytes.len - self.at < 8) return error.Truncated;
        const n = std.mem.readInt(u64, self.bytes[self.at..][0..8], .little);
        self.at += 8;
        return n;
    }
};

// A file's access index (`accesses.writesOf`, `accesses.readsOf`): every site of the file that
// may write or read a place, each in ids alone. Built from the file and what it resolves to, so
// one summary's record serves every run of the same sources.
const accesses = Facts.accesses;
const Site = accesses.Site;
const Shape = accesses.Shape;

pub fn writeAccesses(w: *Writer, index: *const accesses.File) WriteError!void {
    try w.number(@intCast(index.places.count()));
    var places = index.places.iterator();
    while (places.next()) |entry| {
        try w.number(@backingInt(std.meta.activeTag(entry.key_ptr.*)));
        switch (entry.key_ptr.*) {
            inline else => |d| try w.decl(d),
        }
        try writeSites(w, entry.value_ptr.items);
    }
    try w.number(@intCast(index.shapes.count()));
    var shapes = index.shapes.iterator();
    while (shapes.next()) |entry| {
        try writeShape(w, entry.key_ptr.*);
        try writeSites(w, entry.value_ptr.items);
    }
    try w.number(@intCast(index.named.count()));
    var named = index.named.iterator();
    while (named.next()) |entry| {
        try w.string(entry.key_ptr.*);
        try writeSites(w, entry.value_ptr.items);
    }
    try writeSites(w, index.unresolved.items);
    try writeSites(w, index.stores.items);
    try w.number(@intCast(index.through.count()));
    var through = index.through.iterator();
    while (through.next()) |entry| {
        try w.number(@backingInt(entry.key_ptr.*));
        try w.number(@intCast(entry.value_ptr.items.len));
        for (entry.value_ptr.items) |one| try writeShape(w, one);
    }
}

fn writeShape(w: *Writer, shape: Shape) WriteError!void {
    try w.source(shape.file);
    try w.number(@backingInt(shape.scope));
}

fn writeSites(w: *Writer, sites: []const Site) WriteError!void {
    try w.number(@intCast(sites.len));
    for (sites) |site| {
        try w.source(site.file);
        try w.number(@backingInt(site.node));
        try w.number(if (site.target) |t| @backingInt(t) + 1 else 0);
        try w.number(@backingInt(site.kind));
        try w.number(if (site.value) |v| @backingInt(v) + 1 else 0);
        try w.number(@backingInt(site.reach));
        try w.number(@as(u32, @intFromBool(site.part)) | (@as(u32, @intFromBool(site.through)) << 1) | (@as(u32, @intFromBool(site.deferred)) << 2) | (@as(u32, @intFromBool(site.computed)) << 3));
        const operator = site.operator orelse {
            try w.number(0);
            continue;
        };
        switch (operator) {
            .op => |o| {
                try w.number(1);
                try w.number(@backingInt(o.op));
                try w.number(@backingInt(o.overflow));
            },
            .unknown => |why| {
                try w.number(2);
                try w.number(@backingInt(why));
            },
        }
    }
}

/// A file's access index as `writeAccesses` wrote it, made on `r.facts.gpa`.
pub fn readAccesses(r: *Reader) ReadError!*accesses.File {
    const gpa = r.facts.gpa;
    const index = try gpa.create(accesses.File);
    index.* = .{};
    for (0..try r.count()) |_| {
        const place: accesses.Place = switch (try r.enumeration(std.meta.Tag(accesses.Place))) {
            inline else => |tag| @unionInit(accesses.Place, @tagName(tag), try r.decl()),
        };
        try index.places.putNoClobber(gpa, place, try readSites(r));
    }
    for (0..try r.count()) |_| {
        const shape = try readShape(r);
        try index.shapes.putNoClobber(gpa, shape, try readSites(r));
    }
    for (0..try r.count()) |_| {
        const name = try r.string();
        try index.named.putNoClobber(gpa, name, try readSites(r));
    }
    index.unresolved = try readSites(r);
    index.stores = try readSites(r);
    for (0..try r.count()) |_| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(try r.number()));
        var held: std.ArrayList(Shape) = .empty;
        for (0..try r.count()) |_| try held.append(gpa, try readShape(r));
        try index.through.putNoClobber(gpa, node, held);
    }
    return index;
}

fn readShape(r: *Reader) ReadError!Shape {
    const file = try r.source();
    const scope = try r.number();
    if (scope >= r.facts.project.at(file).model.scopes.len) return error.Malformed;
    return .{ .file = file, .scope = @fromBackingInt(scope) };
}

fn readSites(r: *Reader) ReadError!std.ArrayList(Site) {
    var sites: std.ArrayList(Site) = .empty;
    const n = try r.count();
    try sites.ensureTotalCapacityPrecise(r.facts.gpa, n);
    for (0..n) |_| {
        const file = try r.source();
        const node = try r.node(file);
        const target = try r.optionalNode(file);
        const kind = try r.enumeration(accesses.Kind);
        const value = try r.optionalNode(file);
        const reach = try r.enumeration(accesses.Reach);
        const flags = try r.number();
        if (flags >= 16) return error.Malformed;
        const operator: ?accesses.Update = switch (try r.number()) {
            0 => null,
            1 => blk: {
                const op = try r.enumeration(@FieldType(accesses.Operator, "op"));
                break :blk .{ .op = .{ .op = op, .overflow = try r.enumeration(@FieldType(accesses.Operator, "overflow")) } };
            },
            2 => .{ .unknown = try r.enumeration(Facts.Unknown) },
            else => return error.Malformed,
        };
        sites.appendAssumeCapacity(.{ .file = file, .node = node, .target = target, .kind = kind, .value = value, .reach = reach, .part = flags & 1 != 0, .through = flags & 2 != 0, .deferred = flags & 4 != 0, .computed = flags & 8 != 0, .operator = operator });
    }
    return sites;
}

/// Whether two access indexes hold the same sites, each list in the same order.
pub fn sameAccesses(a: *const accesses.File, b: *const accesses.File) bool {
    if (a.places.count() != b.places.count() or a.shapes.count() != b.shapes.count() or a.named.count() != b.named.count() or a.through.count() != b.through.count()) return false;
    var places = a.places.iterator();
    while (places.next()) |entry| if (!sameSites(entry.value_ptr.items, (b.places.get(entry.key_ptr.*) orelse return false).items)) return false;
    var shapes = a.shapes.iterator();
    while (shapes.next()) |entry| if (!sameSites(entry.value_ptr.items, (b.shapes.get(entry.key_ptr.*) orelse return false).items)) return false;
    var named = a.named.iterator();
    while (named.next()) |entry| if (!sameSites(entry.value_ptr.items, (b.named.get(entry.key_ptr.*) orelse return false).items)) return false;
    var through = a.through.iterator();
    while (through.next()) |entry| {
        const other = (b.through.get(entry.key_ptr.*) orelse return false).items;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(entry.value_ptr.items), std.mem.sliceAsBytes(other))) return false;
    }
    return sameSites(a.unresolved.items, b.unresolved.items) and sameSites(a.stores.items, b.stores.items);
}

fn sameSites(a: []const Site, b: []const Site) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// Each file by its run id: a run's own names, for a check that reads back into the run that
/// wrote (`check`).
const RunNames = struct { names: ?Names = null };

/// The cross-check `Facts.check_records` runs: each kind of record read back as it is built.
pub const check: Facts.RecordCheck = .{ .accesses = checkAccesses, .copies = checkCopies };

/// A writer naming each file by its run id, for a check that reads back into the run.
pub fn checkWriter(facts: *Facts) Facts.ResolveError!Writer {
    const kept = try facts.memo(RunNames);
    if (kept.names == null) {
        const of_file = try facts.gpa.alloc(?[]const u8, facts.project.sources.len);
        var names: Names = .{ .of = of_file };
        for (facts.project.sources, of_file) |source, *name| {
            name.* = try facts.gpa.print("{d}", .{@backingInt(source.id)});
            try names.files.put(facts.gpa, name.*.?, source.id);
        }
        kept.names = names;
    }
    return Writer.init(facts.gpa, facts, &kept.names.?) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unnamed => unreachable, // unreachable: every file of the run is named
    };
}

/// Summaries' cross-check (`Facts.check_records`): `index`, `file`'s access index, written and
/// read back into the same run, must be the same index. A difference is a record that leaves
/// out what the live answer holds, so it stops the run rather than let a record answer for it.
pub fn checkAccesses(facts: *Facts, file: Project.FileId, index: *const accesses.File, of: []const u8) Facts.ResolveError!void {
    var w = try checkWriter(facts);
    defer w.deinit();
    writeAccesses(&w, index) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unnamed => unreachable, // unreachable: every file of the run is named
    };
    var r = Reader.init(facts, w.names, w.bytes.items) catch |err| std.debug.panic("summary cross-check: {s} of {s} does not read back: {t}", .{ of, facts.project.at(file).input.name, err });
    defer r.deinit();
    const back = readAccesses(&r) catch |err| std.debug.panic("summary cross-check: {s} of {s} does not read back: {t}", .{ of, facts.project.at(file).input.name, err });
    if (!r.done() or !sameAccesses(index, back)) std.debug.panic("summary cross-check: {s} of {s} reads back other sites", .{ of, facts.project.at(file).input.name });
}

// The copies each generic function makes of its parameters' values (`Facts.parameterCopies`),
// closed over the calls that pass a parameter on: a unit's record holds them for its functions,
// read as the run reads them.
const ParameterCopy = Facts.ParameterCopy;

pub fn writeCopies(w: *Writer, copies: *const std.AutoHashMapUnmanaged(Decl, []const ParameterCopy)) WriteError!void {
    try w.number(@intCast(copies.count()));
    var each = copies.iterator();
    while (each.next()) |entry| {
        try w.decl(entry.key_ptr.*);
        try w.number(@intCast(entry.value_ptr.len));
        for (entry.value_ptr.*) |copy| {
            try w.wide(copy.position);
            try w.key(copy.site);
            try w.number(@backingInt(copy.kind));
            try w.number(@intFromBool(copy.source != null));
            if (copy.source) |source| try w.key(source);
            try w.number(@intCast(copy.path.len));
            for (copy.path) |step| try w.key(step);
            try w.number(@intFromBool(copy.crowded));
        }
    }
}

pub fn readCopies(r: *Reader) ReadError!std.AutoHashMapUnmanaged(Decl, []const ParameterCopy) {
    const gpa = r.facts.gpa;
    var copies: std.AutoHashMapUnmanaged(Decl, []const ParameterCopy) = .empty;
    for (0..try r.count()) |_| {
        const function = try r.decl();
        const list = try gpa.alloc(ParameterCopy, try r.count());
        for (list) |*copy| {
            const position = try r.wide();
            const site = try r.key();
            const kind = try r.enumeration(@FieldType(ParameterCopy, "kind"));
            const source: ?Facts.Key = if (try r.flag()) try r.key() else null;
            const path = try gpa.alloc(Facts.Key, try r.count());
            for (path) |*step| step.* = try r.key();
            copy.* = .{ .position = position, .site = site, .kind = kind, .source = source, .path = path, .crowded = try r.flag() };
        }
        try copies.putNoClobber(gpa, function, list);
    }
    return copies;
}

pub fn sameCopies(a: *const std.AutoHashMapUnmanaged(Decl, []const ParameterCopy), b: *const std.AutoHashMapUnmanaged(Decl, []const ParameterCopy)) bool {
    if (a.count() != b.count()) return false;
    var each = a.iterator();
    while (each.next()) |entry| {
        const other = b.get(entry.key_ptr.*) orelse return false;
        if (other.len != entry.value_ptr.len) return false;
        for (entry.value_ptr.*, other) |x, y| {
            if (x.position != y.position or !std.meta.eql(x.site, y.site) or x.kind != y.kind or !std.meta.eql(x.source, y.source) or x.crowded != y.crowded) return false;
            if (!std.mem.eql(u8, std.mem.sliceAsBytes(x.path), std.mem.sliceAsBytes(y.path))) return false;
        }
    }
    return true;
}

/// `checkAccesses`'s cross-check, of the run's closed parameter copies.
pub fn checkCopies(facts: *Facts, copies: *const std.AutoHashMapUnmanaged(Decl, []const ParameterCopy)) Facts.ResolveError!void {
    var w = try checkWriter(facts);
    defer w.deinit();
    writeCopies(&w, copies) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unnamed => unreachable, // unreachable: every file of the run is named
    };
    var r = Reader.init(facts, w.names, w.bytes.items) catch |err| std.debug.panic("summary cross-check: parameter copies do not read back: {t}", .{err});
    defer r.deinit();
    const back = readCopies(&r) catch |err| std.debug.panic("summary cross-check: parameter copies do not read back: {t}", .{err});
    if (!r.done() or !sameCopies(copies, &back)) std.debug.panic("summary cross-check: parameter copies read back other copies", .{});
}

fn toEnum(comptime E: type, n: u32) error{Malformed}!E {
    return std.enums.fromInt(E, n) orelse error.Malformed;
}

test {
    _ = @import("Summary_test.zig");
}
