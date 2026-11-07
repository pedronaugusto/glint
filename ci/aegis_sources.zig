//! The pinned aegis revision's own sources, as glint project inputs for the pack's tests and
//! benchmark: every file of its module, so each import among them is mapped as aegis's build
//! wires it; std and every other import stay unmapped.
const std = @import("std");
const glint = @import("glint");
const Project = glint.Project;

const Source = struct { name: []const u8, bytes: []const u8 };
const sources = [_]Source{
    .{ .name = "src/root.zig", .bytes = @embedFile("aegis-root") },
    .{ .name = "src/assert.zig", .bytes = @embedFile("aegis-assert") },
    .{ .name = "src/Atomic.zig", .bytes = @embedFile("aegis-Atomic") },
    .{ .name = "src/BlockingGuarded.zig", .bytes = @embedFile("aegis-BlockingGuarded") },
    .{ .name = "src/bounded.zig", .bytes = @embedFile("aegis-bounded") },
    .{ .name = "src/Condition.zig", .bytes = @embedFile("aegis-Condition") },
    .{ .name = "src/Confined.zig", .bytes = @embedFile("aegis-Confined") },
    .{ .name = "src/err.zig", .bytes = @embedFile("aegis-err") },
    .{ .name = "src/flat.zig", .bytes = @embedFile("aegis-flat") },
    .{ .name = "src/Guarded.zig", .bytes = @embedFile("aegis-Guarded") },
    .{ .name = "src/handle.zig", .bytes = @embedFile("aegis-handle") },
    .{ .name = "src/handle/dense.zig", .bytes = @embedFile("aegis-handle-dense") },
    .{ .name = "src/handle/Domain.zig", .bytes = @embedFile("aegis-handle-Domain") },
    .{ .name = "src/handle/index.zig", .bytes = @embedFile("aegis-handle-index") },
    .{ .name = "src/handle/offset.zig", .bytes = @embedFile("aegis-handle-offset") },
    .{ .name = "src/handle/overlap.zig", .bytes = @embedFile("aegis-handle-overlap") },
    .{ .name = "src/handle/run_pool.zig", .bytes = @embedFile("aegis-handle-run_pool") },
    .{ .name = "src/handle/secondary.zig", .bytes = @embedFile("aegis-handle-secondary") },
    .{ .name = "src/handle/slot_pool.zig", .bytes = @embedFile("aegis-handle-slot_pool") },
    .{ .name = "src/id.zig", .bytes = @embedFile("aegis-id") },
    .{ .name = "src/input.zig", .bytes = @embedFile("aegis-input") },
    .{ .name = "src/int.zig", .bytes = @embedFile("aegis-int") },
    .{ .name = "src/interior.zig", .bytes = @embedFile("aegis-interior") },
    .{ .name = "src/Lazy.zig", .bytes = @embedFile("aegis-Lazy") },
    .{ .name = "src/measure.zig", .bytes = @embedFile("aegis-measure") },
    .{ .name = "src/move.zig", .bytes = @embedFile("aegis-move") },
    .{ .name = "src/Once.zig", .bytes = @embedFile("aegis-Once") },
    .{ .name = "src/Order.zig", .bytes = @embedFile("aegis-Order") },
    .{ .name = "src/own.zig", .bytes = @embedFile("aegis-own") },
    .{ .name = "src/parts.zig", .bytes = @embedFile("aegis-parts") },
    .{ .name = "src/Region.zig", .bytes = @embedFile("aegis-Region") },
    .{ .name = "src/RwGuarded.zig", .bytes = @embedFile("aegis-RwGuarded") },
    .{ .name = "src/scalar.zig", .bytes = @embedFile("aegis-scalar") },
    .{ .name = "src/scope.zig", .bytes = @embedFile("aegis-scope") },
    .{ .name = "src/scope/ref.zig", .bytes = @embedFile("aegis-scope-ref") },
    .{ .name = "src/scope/slot.zig", .bytes = @embedFile("aegis-scope-slot") },
    .{ .name = "src/scope/table.zig", .bytes = @embedFile("aegis-scope-table") },
    .{ .name = "src/secret.zig", .bytes = @embedFile("aegis-secret") },
    .{ .name = "src/secret/inline.zig", .bytes = @embedFile("aegis-secret-inline") },
    .{ .name = "src/secret/machine.zig", .bytes = @embedFile("aegis-secret-machine") },
    .{ .name = "src/secret/profiles.zig", .bytes = @embedFile("aegis-secret-profiles") },
    .{ .name = "src/secret/SecretBytes.zig", .bytes = @embedFile("aegis-secret-SecretBytes") },
    .{ .name = "src/secret/value.zig", .bytes = @embedFile("aegis-secret-value") },
    .{ .name = "src/Shared.zig", .bytes = @embedFile("aegis-Shared") },
    .{ .name = "src/SpinRwGuarded.zig", .bytes = @embedFile("aegis-SpinRwGuarded") },
    .{ .name = "src/state.zig", .bytes = @embedFile("aegis-state") },
    .{ .name = "src/state/carrying.zig", .bytes = @embedFile("aegis-state-carrying") },
    .{ .name = "src/state/edge.zig", .bytes = @embedFile("aegis-state-edge") },
    .{ .name = "src/state/machine.zig", .bytes = @embedFile("aegis-state-machine") },
    .{ .name = "src/state/runtime.zig", .bytes = @embedFile("aegis-state-runtime") },
    .{ .name = "src/state/stage.zig", .bytes = @embedFile("aegis-state-stage") },
    .{ .name = "src/sync.zig", .bytes = @embedFile("aegis-sync") },
    .{ .name = "src/units.zig", .bytes = @embedFile("aegis-units") },
};
/// Aegis's root, the module `aegis` (aegis exports no other).
const root = blk: {
    @setEvalBranchQuota(sources.len * 64);
    break :blk index("src/root.zig");
};

/// Each import among aegis's files: the importing file, its spelling, the file it names.
const wired = [_][3][]const u8{
    .{ "src/BlockingGuarded.zig", "Condition.zig", "src/Condition.zig" },
    .{ "src/bounded.zig", "move.zig", "src/move.zig" },
    .{ "src/flat.zig", "assert.zig", "src/assert.zig" },
    .{ "src/flat.zig", "bounded.zig", "src/bounded.zig" },
    .{ "src/flat.zig", "input.zig", "src/input.zig" },
    .{ "src/flat.zig", "measure.zig", "src/measure.zig" },
    .{ "src/flat.zig", "Region.zig", "src/Region.zig" },
    .{ "src/handle.zig", "handle/dense.zig", "src/handle/dense.zig" },
    .{ "src/handle.zig", "handle/Domain.zig", "src/handle/Domain.zig" },
    .{ "src/handle.zig", "handle/index.zig", "src/handle/index.zig" },
    .{ "src/handle.zig", "handle/offset.zig", "src/handle/offset.zig" },
    .{ "src/handle.zig", "handle/run_pool.zig", "src/handle/run_pool.zig" },
    .{ "src/handle.zig", "handle/secondary.zig", "src/handle/secondary.zig" },
    .{ "src/handle.zig", "handle/slot_pool.zig", "src/handle/slot_pool.zig" },
    .{ "src/handle/dense.zig", "../move.zig", "src/move.zig" },
    .{ "src/handle/dense.zig", "../Region.zig", "src/Region.zig" },
    .{ "src/handle/dense.zig", "Domain.zig", "src/handle/Domain.zig" },
    .{ "src/handle/dense.zig", "overlap.zig", "src/handle/overlap.zig" },
    .{ "src/handle/dense.zig", "slot_pool.zig", "src/handle/slot_pool.zig" },
    .{ "src/handle/offset.zig", "../Region.zig", "src/Region.zig" },
    .{ "src/handle/run_pool.zig", "../assert.zig", "src/assert.zig" },
    .{ "src/handle/run_pool.zig", "../Region.zig", "src/Region.zig" },
    .{ "src/handle/run_pool.zig", "index.zig", "src/handle/index.zig" },
    .{ "src/handle/run_pool.zig", "slot_pool.zig", "src/handle/slot_pool.zig" },
    .{ "src/handle/secondary.zig", "../move.zig", "src/move.zig" },
    .{ "src/handle/secondary.zig", "../Region.zig", "src/Region.zig" },
    .{ "src/handle/secondary.zig", "overlap.zig", "src/handle/overlap.zig" },
    .{ "src/handle/slot_pool.zig", "../assert.zig", "src/assert.zig" },
    .{ "src/handle/slot_pool.zig", "../move.zig", "src/move.zig" },
    .{ "src/handle/slot_pool.zig", "../Region.zig", "src/Region.zig" },
    .{ "src/handle/slot_pool.zig", "Domain.zig", "src/handle/Domain.zig" },
    .{ "src/handle/slot_pool.zig", "index.zig", "src/handle/index.zig" },
    .{ "src/handle/slot_pool.zig", "overlap.zig", "src/handle/overlap.zig" },
    .{ "src/id.zig", "scalar.zig", "src/scalar.zig" },
    .{ "src/id.zig", "units.zig", "src/units.zig" },
    .{ "src/int.zig", "scalar.zig", "src/scalar.zig" },
    .{ "src/Lazy.zig", "interior.zig", "src/interior.zig" },
    .{ "src/Once.zig", "Condition.zig", "src/Condition.zig" },
    .{ "src/Order.zig", "Condition.zig", "src/Condition.zig" },
    .{ "src/own.zig", "move.zig", "src/move.zig" },
    .{ "src/own.zig", "units.zig", "src/units.zig" },
    .{ "src/parts.zig", "assert.zig", "src/assert.zig" },
    .{ "src/parts.zig", "measure.zig", "src/measure.zig" },
    .{ "src/parts.zig", "units.zig", "src/units.zig" },
    .{ "src/Region.zig", "bounded.zig", "src/bounded.zig" },
    .{ "src/Region.zig", "units.zig", "src/units.zig" },
    .{ "src/root.zig", "assert.zig", "src/assert.zig" },
    .{ "src/root.zig", "bounded.zig", "src/bounded.zig" },
    .{ "src/root.zig", "err.zig", "src/err.zig" },
    .{ "src/root.zig", "flat.zig", "src/flat.zig" },
    .{ "src/root.zig", "handle.zig", "src/handle.zig" },
    .{ "src/root.zig", "id.zig", "src/id.zig" },
    .{ "src/root.zig", "input.zig", "src/input.zig" },
    .{ "src/root.zig", "int.zig", "src/int.zig" },
    .{ "src/root.zig", "Order.zig", "src/Order.zig" },
    .{ "src/root.zig", "own.zig", "src/own.zig" },
    .{ "src/root.zig", "parts.zig", "src/parts.zig" },
    .{ "src/root.zig", "Region.zig", "src/Region.zig" },
    .{ "src/root.zig", "scope.zig", "src/scope.zig" },
    .{ "src/root.zig", "secret.zig", "src/secret.zig" },
    .{ "src/root.zig", "secret/inline.zig", "src/secret/inline.zig" },
    .{ "src/root.zig", "secret/SecretBytes.zig", "src/secret/SecretBytes.zig" },
    .{ "src/root.zig", "state.zig", "src/state.zig" },
    .{ "src/root.zig", "sync.zig", "src/sync.zig" },
    .{ "src/root.zig", "units.zig", "src/units.zig" },
    .{ "src/scope.zig", "scope/ref.zig", "src/scope/ref.zig" },
    .{ "src/scope.zig", "scope/slot.zig", "src/scope/slot.zig" },
    .{ "src/scope.zig", "scope/table.zig", "src/scope/table.zig" },
    .{ "src/scope/ref.zig", "slot.zig", "src/scope/slot.zig" },
    .{ "src/scope/table.zig", "ref.zig", "src/scope/ref.zig" },
    .{ "src/scope/table.zig", "slot.zig", "src/scope/slot.zig" },
    .{ "src/secret.zig", "secret/machine.zig", "src/secret/machine.zig" },
    .{ "src/secret.zig", "secret/profiles.zig", "src/secret/profiles.zig" },
    .{ "src/secret.zig", "secret/value.zig", "src/secret/value.zig" },
    .{ "src/secret/value.zig", "profiles.zig", "src/secret/profiles.zig" },
    .{ "src/Shared.zig", "interior.zig", "src/interior.zig" },
    .{ "src/Shared.zig", "move.zig", "src/move.zig" },
    .{ "src/state.zig", "state/edge.zig", "src/state/edge.zig" },
    .{ "src/state.zig", "state/machine.zig", "src/state/machine.zig" },
    .{ "src/state/carrying.zig", "../move.zig", "src/move.zig" },
    .{ "src/state/machine.zig", "carrying.zig", "src/state/carrying.zig" },
    .{ "src/state/machine.zig", "edge.zig", "src/state/edge.zig" },
    .{ "src/state/machine.zig", "runtime.zig", "src/state/runtime.zig" },
    .{ "src/state/machine.zig", "stage.zig", "src/state/stage.zig" },
    .{ "src/state/stage.zig", "../move.zig", "src/move.zig" },
    .{ "src/sync.zig", "Atomic.zig", "src/Atomic.zig" },
    .{ "src/sync.zig", "BlockingGuarded.zig", "src/BlockingGuarded.zig" },
    .{ "src/sync.zig", "Condition.zig", "src/Condition.zig" },
    .{ "src/sync.zig", "Confined.zig", "src/Confined.zig" },
    .{ "src/sync.zig", "Guarded.zig", "src/Guarded.zig" },
    .{ "src/sync.zig", "Lazy.zig", "src/Lazy.zig" },
    .{ "src/sync.zig", "Once.zig", "src/Once.zig" },
    .{ "src/sync.zig", "Order.zig", "src/Order.zig" },
    .{ "src/sync.zig", "RwGuarded.zig", "src/RwGuarded.zig" },
    .{ "src/sync.zig", "Shared.zig", "src/Shared.zig" },
    .{ "src/sync.zig", "SpinRwGuarded.zig", "src/SpinRwGuarded.zig" },
    .{ "src/units.zig", "assert.zig", "src/assert.zig" },
    .{ "src/units.zig", "int.zig", "src/int.zig" },
    .{ "src/units.zig", "scalar.zig", "src/scalar.zig" },
};

/// A pinned source's place among the project's inputs (the consumer is 0).
fn index(comptime name: []const u8) u32 {
    for (sources, 1..) |source, i| if (std.mem.eql(u8, source.name, name)) return i;
    @compileError("not a pinned aegis source: " ++ name);
}

/// Imports as aegis's own build wires them, then the consumer's (source 0) of aegis.
fn imports() [wired.len + 1]Project.Import {
    return imported;
}
const imported = blk: {
    // Each of the wired imports looks up two names among the sources.
    @setEvalBranchQuota(4 * wired.len * sources.len * 64);
    var all: [wired.len + 1]Project.Import = undefined;
    for (wired, 0..) |entry, i| all[i] = .{ .from = index(entry[0]), .spelling = entry[1], .target = index(entry[2]) };
    all[wired.len] = .{ .from = 0, .spelling = "aegis", .target = root };
    break :blk all;
};
/// A project whose first source is `consumer`, followed by the aegis files, none of them selected.
pub fn project(gpa: std.mem.Allocator, consumer: []const u8) !glint.Project {
    var inputs: [sources.len + 1]Project.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = consumer };
    for (sources, 1..) |source, i| inputs[i] = aegisInput(source);
    return Project.init(gpa, &inputs, &imports(), .{});
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
    const mapped = imports();
    var all: [mapped.len + 2]Project.Import = undefined;
    @memcpy(all[0..mapped.len], &mapped);
    all[mapped.len] = .{ .from = 0, .spelling = "lib", .target = lib_file };
    all[mapped.len + 1] = .{ .from = lib_file, .spelling = "aegis", .target = root };
    return Project.init(gpa, &inputs, &all, .{});
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
        var rest = source.bytes;
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
    const mapped = imports();
    return Project.init(gpa, &inputs, &mapped, .{});
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
    /// The compilations of aegis's files and the extra sources, where not as above: `.build` for
    /// a project only build scripts import (`Project.compiledBy` gives std's files `.build`).
    others: ?Project.Compilations = null,
};

/// `projectWithSources`, the consumer as `as` says.
pub fn projectAs(gpa: std.mem.Allocator, consumer: []const u8, as: Consumer, extra: []const Extra, extra_imports: []const ExtraImport) !glint.Project {
    const inputs = try gpa.alloc(Project.Input, sources.len + 1 + extra.len);
    defer gpa.free(inputs);
    const others: Project.Compilations = as.others orelse if (as.compilations == .program) .program else .both;
    inputs[0] = .{ .name = "consumer", .bytes = consumer, .package = as.package, .compilations = as.compilations };
    for (sources, 1..) |source, i| {
        inputs[i] = aegisInput(source);
        inputs[i].compilations = others;
    }
    for (extra, sources.len + 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .kind = source.kind, .selected = false, .package = source.package, .compilations = others };
    const mapped = imports();
    const all = try gpa.alloc(Project.Import, mapped.len + extra_imports.len);
    defer gpa.free(all);
    @memcpy(all[0..mapped.len], &mapped);
    const first: u32 = sources.len + 1;
    for (extra_imports, mapped.len..) |entry, i| all[i] = .{ .from = if (entry.from) |from| first + from else 0, .spelling = entry.spelling, .target = switch (entry.target) {
        consumer_file => 0,
        aegis_file => root,
        else => first + entry.target,
    } };
    return Project.init(gpa, inputs, all, .{});
}

/// An aegis source as a caller states it: not selected, a file of aegis's package.
fn aegisInput(source: anytype) Project.Input {
    return .{ .name = source.name, .bytes = source.bytes, .selected = false, .package = glint.AegisPack.package.name, .fingerprint = glint.AegisPack.package.fingerprint };
}
