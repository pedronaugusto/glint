//! The pinned aegis revision's own sources, as glint project inputs for the pack's tests and
//! benchmark: its whole `src/` tree (build.zig's generated `aegis_tree`), each import between
//! its files read from the file's own `@import` spelling, as Zig resolves it against the
//! importing file's path. A module aegis's build binds (std, builtin, a test's) stays unmapped;
//! a file spelling the tree lacks is an error, so the inputs cannot drift from the revision.
const std = @import("std");
const builtin = @import("builtin");
const glint = @import("glint");
const Project = glint.Project;

const tree = @import("aegis_tree");
const sources = tree.files;

/// The aegis files read once per test binary (`-Dunit-shared`, build.zig's `aegis_tree.shared`):
/// a store every project made here reads first, through a const pointer, and its own store reads
/// only what the base lacks (the consumer, a revised file, the extra sources). The base is built
/// on first use from memory of its own and then frozen: it allocates no more, the OS makes its
/// pages read-only, and a blake3 fingerprint of its bytes is taken. A write into it ends the run
/// where it is made; `expectBaseFrozen` compares the fingerprint, once per run in each root's
/// test, and before every project made over the base in the proof run (`-Dunit-proof`).
const Base = struct {
    store: ?*const Project.Store = null,
    /// The pages the base is in, each from the page allocator. The list itself is not among
    /// them, so it stays writable.
    chunks: std.ArrayList([]u8) = .empty,
    /// The bytes taken in the last chunk.
    used: usize = 0,
    frozen: bool = false,
    print: [32]u8 = undefined,

    const chunk_bytes = 4 * 1024 * 1024;
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *Base) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn unfrozen(self: *const Base) void {
        if (self.frozen) @panic("aegis_sources: the shared base was asked for memory after it was frozen");
    }

    /// Bump allocation: from the last chunk where the bytes fit, else from a new one.
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Base = @ptrCast(@alignCast(context));
        self.unfrozen();
        if (self.chunks.items.len != 0) {
            const last = self.chunks.items[self.chunks.items.len - 1];
            const start = alignment.forward(@intFromPtr(last.ptr) + self.used) - @intFromPtr(last.ptr);
            if (start <= last.len and len <= last.len - start) {
                self.used = start + len;
                return last.ptr + start;
            }
        }
        const wanted = std.math.add(usize, len, alignment.toByteUnits()) catch return null;
        const size = std.mem.alignForward(usize, @max(chunk_bytes, wanted), std.heap.pageSize());
        const chunk = std.heap.page_allocator.alloc(u8, size) catch return null;
        self.chunks.append(std.heap.page_allocator, chunk) catch {
            std.heap.page_allocator.free(chunk);
            return null;
        };
        const start = alignment.forward(@intFromPtr(chunk.ptr)) - @intFromPtr(chunk.ptr);
        self.used = start + len;
        return chunk.ptr + start;
    }

    /// Whether `memory` is the last allocation made: the one that may grow, or be given back.
    fn tail(self: *const Base, memory: []u8) ?[]u8 {
        if (self.chunks.items.len == 0) return null;
        const chunk = self.chunks.items[self.chunks.items.len - 1];
        const start = @intFromPtr(memory.ptr);
        if (start < @intFromPtr(chunk.ptr) or start + memory.len != @intFromPtr(chunk.ptr) + self.used) return null;
        return chunk;
    }

    /// The last allocation grows or shrinks in place; any other only shrinks, keeping its bytes.
    fn resize(context: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *Base = @ptrCast(@alignCast(context));
        self.unfrozen();
        const chunk = self.tail(memory) orelse return new_len <= memory.len;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(chunk.ptr);
        if (new_len > chunk.len - start) return false;
        self.used = start + new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    /// The last allocation is given back; any other stays until the binary ends.
    fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Base = @ptrCast(@alignCast(context));
        self.unfrozen();
        if (self.tail(memory) != null) self.used -= memory.len;
    }

    fn freeze(self: *Base) error{Unprotected}!void {
        self.frozen = true;
        for (self.chunks.items) |chunk| try readOnly(chunk);
        self.print = self.fingerprint();
    }

    fn fingerprint(self: *const Base) [32]u8 {
        var hash: std.crypto.hash.Blake3 = .init(.{});
        for (self.chunks.items) |chunk| hash.update(chunk);
        var out: [32]u8 = undefined;
        hash.final(&out);
        return out;
    }

    fn check(self: *const Base) error{SharedBaseChanged}!void {
        if (!std.mem.eql(u8, &self.fingerprint(), &self.print)) return error.SharedBaseChanged;
    }

    /// Makes `chunk`'s pages read-only: mprotect on Linux (its system call, as a test binary
    /// there links no libc) and where libc declares it (Darwin, the BSDs, illumos, Haiku),
    /// NtProtectVirtualMemory on Windows. A target with neither (WASI, freestanding) has the
    /// fingerprint alone.
    fn readOnly(chunk: []u8) error{Unprotected}!void {
        switch (builtin.os.tag) {
            .linux => if (std.os.linux.errno(std.os.linux.mprotect(chunk.ptr, chunk.len, .{ .READ = true })) != .SUCCESS) return error.Unprotected,
            .windows => {
                const windows = std.os.windows;
                var address: ?*anyopaque = chunk.ptr;
                var size: usize = chunk.len;
                var old: windows.PAGE = undefined;
                if (windows.ntdll.NtProtectVirtualMemory(windows.GetCurrentProcess(), &address, &size, .{ .READONLY = true }, &old) != .SUCCESS) return error.Unprotected;
            },
            else => if (comptime std.c.PROT != void) {
                if (std.c.mprotect(@ptrCast(@alignCast(chunk.ptr)), chunk.len, .{ .READ = true }) != 0) return error.Unprotected;
            },
        }
    }
};

var base: Base = .{};

/// The shared base, built on first use: every aegis file, read as a project reads it by default.
fn shared() !*const Project.Store {
    if (base.store) |store| {
        if (tree.proof) try base.check();
        return store;
    }
    const a = base.allocator();
    const store = try a.create(Project.Store);
    store.* = .init(a);
    var inputs: [sources.len + 1]Project.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = "" };
    for (sources, 1..) |source, i| inputs[i] = aegisInput(source);
    const mapped = try imports(std.heap.page_allocator);
    defer std.heap.page_allocator.free(mapped);
    var built = try Project.init(std.heap.page_allocator, &inputs, mapped, .{ .store = store });
    built.deinit();
    try base.freeze();
    base.store = store;
    return store;
}

/// The options every project here is made with: over the shared base where there is one.
fn options() !Project.Options {
    return if (tree.shared) .{ .base = try shared() } else .{};
}

/// Fails where the shared base's bytes are not those it was frozen with; built first where no
/// test has yet. Nothing to check where `-Dunit-shared=false`.
pub fn expectBaseFrozen() !void {
    if (!tree.shared) return;
    _ = try shared();
    try base.check();
}

/// The input index of aegis's source `name`: the consumer is input 0, aegis's sources follow.
fn input(comptime name: []const u8) u32 {
    @setEvalBranchQuota(100_000);
    inline for (sources, 1..) |source, i| if (comptime std.mem.eql(u8, source.name, name)) return i;
    @compileError("aegis's src/ has no " ++ name);
}

const root = input("src/root.zig");

/// The consumer's (input 0) import of aegis: the module `aegis`, the only one aegis exports.
const consumer_imports = [_]Project.Import{.{ .from = 0, .spelling = "aegis", .target = root }};

/// Imports as aegis's files spell them, then the consumer's (`consumer_imports`); the caller
/// frees them. A spelling of a `.zig` or `.zon` file that names none of the tree's is
/// `error.UnpinnedImport`.
fn imports(gpa: std.mem.Allocator) ![]Project.Import {
    var found: std.ArrayList(Project.Import) = .empty;
    errdefer found.deinit(gpa);
    for (sources, 1..) |source, from| {
        var tokens: std.zig.Tokenizer = .init(source.bytes);
        // The two tokens before this one: `@import` `(` before a string is an import.
        var before: [2]std.zig.Token = @splat(.{ .tag = .invalid, .loc = .{ .start = 0, .end = 0 } });
        while (true) {
            const token = tokens.next();
            if (token.tag == .eof) break;
            defer before = .{ before[1], token };
            if (token.tag != .string_literal or before[1].tag != .l_paren or before[0].tag != .builtin) continue;
            if (!std.mem.eql(u8, source.bytes[before[0].loc.start..before[0].loc.end], "@import")) continue;
            const spelling = source.bytes[token.loc.start + 1 .. token.loc.end - 1];
            if (!std.mem.endsWith(u8, spelling, ".zig") and !std.mem.endsWith(u8, spelling, ".zon")) continue;
            const path = try std.fs.path.resolveAllocPosix(gpa, &.{ std.fs.path.dirnamePosix(source.name) orelse ".", spelling });
            defer gpa.free(path);
            const target = for (sources, 1..) |each, i| {
                if (std.mem.eql(u8, each.name, path)) break i;
            } else {
                std.log.err("aegis_sources: {s} imports {s}, which aegis's src/ does not hold", .{ source.name, spelling });
                return error.UnpinnedImport;
            };
            // A file that writes a spelling twice imports one file: one edge.
            for (found.items) |edge| {
                if (edge.from == from and std.mem.eql(u8, edge.spelling, spelling)) break;
            } else try found.append(gpa, .{ .from = @intCast(from), .spelling = spelling, .target = @intCast(target) });
        }
    }
    try found.appendSlice(gpa, &consumer_imports);
    return found.toOwnedSlice(gpa);
}

/// A project whose first source is `consumer`, followed by the aegis files, none of them selected.
pub fn project(gpa: std.mem.Allocator, consumer: []const u8) !glint.Project {
    var inputs: [sources.len + 1]Project.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = consumer };
    for (sources, 1..) |source, i| inputs[i] = aegisInput(source);
    const mapped = try imports(gpa);
    defer gpa.free(mapped);
    return Project.init(gpa, &inputs, mapped, try options());
}

/// `project`, with a second source of the program's own, imported by the consumer as `lib`
/// and importing aegis as `aegis`: a module a program reaches its types through.
pub fn projectWith(gpa: std.mem.Allocator, consumer: []const u8, lib: []const u8) !glint.Project {
    return withLib(gpa, consumer, lib, true);
}

/// `projectWith`, the second source a dependency's: outside the program's own sources.
pub fn projectWithDependency(gpa: std.mem.Allocator, consumer: []const u8, lib: []const u8) !glint.Project {
    return withLib(gpa, consumer, lib, false);
}

fn withLib(gpa: std.mem.Allocator, consumer: []const u8, lib: []const u8, selected: bool) !glint.Project {
    var inputs: [sources.len + 2]Project.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = consumer };
    for (sources, 1..) |source, i| inputs[i] = aegisInput(source);
    inputs[sources.len + 1] = .{ .name = "lib", .bytes = lib, .selected = selected };
    const lib_file = sources.len + 1;
    const mapped = try imports(gpa);
    defer gpa.free(mapped);
    const all = try gpa.alloc(Project.Import, mapped.len + 2);
    defer gpa.free(all);
    @memcpy(all[0..mapped.len], mapped);
    all[mapped.len] = .{ .from = 0, .spelling = "lib", .target = lib_file };
    all[mapped.len + 1] = .{ .from = lib_file, .spelling = "aegis", .target = root };
    return Project.init(gpa, &inputs, all, try options());
}

/// A source of another module beside aegis's, such as a fixture standing for std, in the
/// package `package` names (none where empty); ZON data a Zig file imports where `kind` says.
pub const Extra = struct { name: []const u8, bytes: []const u8, package: []const u8 = "", kind: @FieldType(Project.Input, "kind") = .zig };
/// An import among the extra sources, by their index in what the caller gives; a null `from` is
/// the consumer's, a `target` of `consumer_file` the consumer itself and of `aegis_file` aegis's
/// root.
pub const ExtraImport = struct { from: ?u32 = null, spelling: []const u8, target: u32 };
/// The consumer, as an `ExtraImport`'s target.
pub const consumer_file: u32 = std.math.maxInt(u32);
/// Aegis's root, as an `ExtraImport`'s target.
pub const aegis_file: u32 = std.math.maxInt(u32) - 1;

/// Writes the pinned files under `dir` as aegis lays them out, and each `.zig` file one of
/// them imports that is not among them as an empty file: a tree glint loads from disk, whose
/// root publishes what the pinned revision does.
pub fn writeTree(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    for (sources) |source| {
        if (std.fs.path.dirnamePosix(source.name)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = source.name, .data = source.bytes });
    }
    for (sources) |source| {
        var rest: []const u8 = source.bytes;
        while (std.mem.find(u8, rest, "@import(\"")) |at| {
            rest = rest[at + "@import(\"".len ..];
            const end = std.mem.findScalar(u8, rest, '"') orelse break;
            if (!std.mem.endsWith(u8, rest[0..end], ".zig")) continue;
            const path = try std.fs.path.resolveAllocPosix(gpa, &.{ std.fs.path.dirnamePosix(source.name) orelse ".", rest[0..end] });
            defer gpa.free(path);
            if (pinned(path) != null) continue;
            if (std.fs.path.dirnamePosix(path)) |parent| try dir.createDirPath(io, parent);
            try dir.writeFile(io, .{ .sub_path = path, .data = "" });
        }
    }
}

/// The pinned revision's source `name`.
pub fn pinned(name: []const u8) ?[]const u8 {
    for (sources) |each| if (std.mem.eql(u8, each.name, name)) return each.bytes;
    return null;
}

/// `project`, with aegis's source `name` read as `bytes`: a revision that publishes other names.
pub fn projectRevised(gpa: std.mem.Allocator, consumer: []const u8, name: []const u8, bytes: []const u8) !glint.Project {
    var inputs: [sources.len + 1]Project.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = consumer };
    var revised = false;
    for (sources, 1..) |source, i| {
        const replaced = std.mem.eql(u8, source.name, name);
        revised = revised or replaced;
        inputs[i] = aegisInput(source);
        if (replaced) inputs[i].bytes = bytes;
    }
    if (!revised) return error.FileNotFound;
    const mapped = try imports(gpa);
    defer gpa.free(mapped);
    return Project.init(gpa, &inputs, mapped, try options());
}

/// `project`, with `extra` sources after aegis's, none of them selected, and their imports.
pub fn projectWithSources(gpa: std.mem.Allocator, consumer: []const u8, extra: []const Extra, extra_imports: []const ExtraImport) !glint.Project {
    return projectAs(gpa, consumer, .{}, extra, extra_imports);
}

/// What the consumer is in `projectAs`: a file of `package`, compiled by `compilations`.
pub const Consumer = struct {
    package: []const u8 = "",
    /// `.build`: a build script, which only the build runner compiles; aegis's files and the
    /// extra sources (std's) are then compiled by both, as std is.
    compilations: Project.Compilations = .program,
};

/// `projectWithSources`, the consumer as `as` says.
pub fn projectAs(gpa: std.mem.Allocator, consumer: []const u8, as: Consumer, extra: []const Extra, extra_imports: []const ExtraImport) !glint.Project {
    const inputs = try gpa.alloc(Project.Input, sources.len + 1 + extra.len);
    defer gpa.free(inputs);
    const others: Project.Compilations = if (as.compilations == .program) .program else .both;
    inputs[0] = .{ .name = "consumer", .bytes = consumer, .package = as.package, .compilations = as.compilations };
    for (sources, 1..) |source, i| {
        inputs[i] = aegisInput(source);
        inputs[i].compilations = others;
    }
    for (extra, sources.len + 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .kind = source.kind, .selected = false, .package = source.package, .compilations = others };
    const mapped = try imports(gpa);
    defer gpa.free(mapped);
    // The std the consumer imports is aegis's too, as one build binds one std for every module.
    const std_target: ?u32 = for (extra_imports) |entry| {
        if (entry.from == null and std.mem.eql(u8, entry.spelling, "std")) break entry.target;
    } else null;
    const aegis_std: usize = if (std_target != null) sources.len else 0;
    const all = try gpa.alloc(Project.Import, mapped.len + extra_imports.len + aegis_std);
    defer gpa.free(all);
    @memcpy(all[0..mapped.len], mapped);
    const first: u32 = sources.len + 1;
    for (extra_imports, mapped.len..) |entry, i| all[i] = .{ .from = if (entry.from) |from| first + from else 0, .spelling = entry.spelling, .target = switch (entry.target) {
        consumer_file => 0,
        aegis_file => root,
        else => first + entry.target,
    } };
    if (std_target) |target| for (all[mapped.len + extra_imports.len ..], 1..) |*edge, from| {
        edge.* = .{ .from = @intCast(from), .spelling = "std", .target = first + target };
    };
    return Project.init(gpa, inputs, all, try options());
}

/// aegis's package, as its `build.zig.zon` names it.
pub const package: struct { name: []const u8, fingerprint: u64 } = .{ .name = "aegis", .fingerprint = 0x5e23831cba68ccae };

/// An aegis source as a caller states it: not selected, a file of aegis's package.
fn aegisInput(source: anytype) Project.Input {
    return .{ .name = source.name, .bytes = source.bytes, .selected = false, .package = package.name, .fingerprint = package.fingerprint };
}
