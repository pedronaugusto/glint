//! The pinned aegis revision's own sources, as glint project inputs for the pack's tests and
//! benchmark. Only the files that publish the pack's members are present; every other import
//! of theirs stays unmapped, as a program that does not use it would leave it.
const std = @import("std");
const glint = @import("glint");
const Project = glint.Project;

const Source = struct { name: []const u8, bytes: []const u8 };
const sources = [_]Source{
    .{ .name = "src/root.zig", .bytes = @embedFile("aegis-root") },
    .{ .name = "src/secret.zig", .bytes = @embedFile("aegis-secret") },
    .{ .name = "src/secret/inline.zig", .bytes = @embedFile("aegis-secret-inline") },
    .{ .name = "src/secret/SecretBytes.zig", .bytes = @embedFile("aegis-secret-bytes") },
    .{ .name = "src/sync.zig", .bytes = @embedFile("aegis-sync") },
    .{ .name = "src/Guarded.zig", .bytes = @embedFile("aegis-guarded") },
    .{ .name = "src/int.zig", .bytes = @embedFile("aegis-int") },
    .{ .name = "src/id.zig", .bytes = @embedFile("aegis-id") },
    .{ .name = "src/units.zig", .bytes = @embedFile("aegis-units") },
    .{ .name = "src/scalar.zig", .bytes = @embedFile("aegis-scalar") },
    .{ .name = "src/BlockingGuarded.zig", .bytes = @embedFile("aegis-blocking-guarded") },
    .{ .name = "src/RwGuarded.zig", .bytes = @embedFile("aegis-rw-guarded") },
    .{ .name = "src/SpinRwGuarded.zig", .bytes = @embedFile("aegis-spin-rw-guarded") },
    .{ .name = "src/Condition.zig", .bytes = @embedFile("aegis-condition") },
    .{ .name = "src/Once.zig", .bytes = @embedFile("aegis-once") },
    .{ .name = "src/Lazy.zig", .bytes = @embedFile("aegis-lazy") },
    .{ .name = "src/Confined.zig", .bytes = @embedFile("aegis-confined") },
    .{ .name = "src/bounded.zig", .bytes = @embedFile("aegis-bounded") },
    .{ .name = "src/own.zig", .bytes = @embedFile("aegis-own") },
    .{ .name = "src/Shared.zig", .bytes = @embedFile("aegis-shared") },
    .{ .name = "src/input.zig", .bytes = @embedFile("aegis-input") },
    .{ .name = "src/secret/value.zig", .bytes = @embedFile("aegis-secret-value") },
    .{ .name = "src/state.zig", .bytes = @embedFile("aegis-state") },
    .{ .name = "src/state/edge.zig", .bytes = @embedFile("aegis-state-edge") },
    .{ .name = "src/state/machine.zig", .bytes = @embedFile("aegis-state-machine") },
    .{ .name = "src/state/stage.zig", .bytes = @embedFile("aegis-state-stage") },
    .{ .name = "src/state/runtime.zig", .bytes = @embedFile("aegis-state-runtime") },
    .{ .name = "src/scope.zig", .bytes = @embedFile("aegis-scope") },
    .{ .name = "src/scope/table.zig", .bytes = @embedFile("aegis-scope-table") },
    .{ .name = "src/scope/ref.zig", .bytes = @embedFile("aegis-scope-ref") },
    .{ .name = "src/scope/slot.zig", .bytes = @embedFile("aegis-scope-slot") },
    .{ .name = "src/handle.zig", .bytes = @embedFile("aegis-handle") },
    .{ .name = "src/handle/pool.zig", .bytes = @embedFile("aegis-handle-pool") },
    .{ .name = "src/handle/slot_map.zig", .bytes = @embedFile("aegis-handle-slot-map") },
    .{ .name = "src/handle/dense.zig", .bytes = @embedFile("aegis-handle-dense") },
    .{ .name = "src/handle/secondary.zig", .bytes = @embedFile("aegis-handle-secondary") },
    .{ .name = "src/handle/Domain.zig", .bytes = @embedFile("aegis-handle-domain") },
    .{ .name = "src/handle/index.zig", .bytes = @embedFile("aegis-handle-index") },
    .{ .name = "src/Atomic.zig", .bytes = @embedFile("aegis-atomic") },
    .{ .name = "src/Order.zig", .bytes = @embedFile("aegis-order") },
    .{ .name = "src/err.zig", .bytes = @embedFile("aegis-err") },
    .{ .name = "src/assert.zig", .bytes = @embedFile("aegis-assert") },
};
const root = 1;
const secret = 2;
const secret_inline = 3;
const secret_bytes = 4;
const sync = 5;
const guarded = 6;
const int = 7;
const id = 8;
const units = 9;
const scalar = 10;
const blocking_guarded = 11;
const rw_guarded = 12;
const spin_rw_guarded = 13;
const condition = 14;
const once = 15;
const lazy = 16;
const confined = 17;
const bounded = 18;
const own = 19;
const shared = 20;
const input = 21;
const secret_value = 22;
const state = 23;
const state_edge = 24;
const state_machine = 25;
const state_stage = 26;
const state_runtime = 27;
const scope = 28;
const scope_table = 29;
const scope_ref = 30;
const scope_slot = 31;
const handle = 32;
const handle_pool = 33;
const handle_slot_map = 34;
const handle_dense = 35;
const handle_secondary = 36;
const handle_domain = 37;
const handle_index = 38;
const atomic = 39;
const order = 40;
const err = 41;
const assert_file = 42;

/// Imports as aegis's own build wires them, then the ways the consumer (source 0) imports aegis.
fn imports() [62]Project.Import {
    return .{
        .{ .from = root, .spelling = "secret.zig", .target = secret },
        .{ .from = root, .spelling = "sync.zig", .target = sync },
        .{ .from = root, .spelling = "int.zig", .target = int },
        .{ .from = root, .spelling = "id.zig", .target = id },
        .{ .from = root, .spelling = "units.zig", .target = units },
        .{ .from = secret, .spelling = "secret/inline.zig", .target = secret_inline },
        .{ .from = secret, .spelling = "secret/SecretBytes.zig", .target = secret_bytes },
        .{ .from = sync, .spelling = "Guarded.zig", .target = guarded },
        .{ .from = sync, .spelling = "BlockingGuarded.zig", .target = blocking_guarded },
        .{ .from = sync, .spelling = "RwGuarded.zig", .target = rw_guarded },
        .{ .from = sync, .spelling = "SpinRwGuarded.zig", .target = spin_rw_guarded },
        .{ .from = sync, .spelling = "Condition.zig", .target = condition },
        .{ .from = sync, .spelling = "Once.zig", .target = once },
        .{ .from = sync, .spelling = "Lazy.zig", .target = lazy },
        .{ .from = sync, .spelling = "Confined.zig", .target = confined },
        .{ .from = once, .spelling = "Condition.zig", .target = condition },
        .{ .from = int, .spelling = "scalar.zig", .target = scalar },
        .{ .from = id, .spelling = "scalar.zig", .target = scalar },
        .{ .from = id, .spelling = "units.zig", .target = units },
        .{ .from = units, .spelling = "scalar.zig", .target = scalar },
        .{ .from = units, .spelling = "int.zig", .target = int },
        .{ .from = root, .spelling = "bounded.zig", .target = bounded },
        .{ .from = root, .spelling = "own.zig", .target = own },
        .{ .from = root, .spelling = "input.zig", .target = input },
        .{ .from = root, .spelling = "state.zig", .target = state },
        .{ .from = root, .spelling = "scope.zig", .target = scope },
        .{ .from = root, .spelling = "handle.zig", .target = handle },
        .{ .from = sync, .spelling = "Shared.zig", .target = shared },
        .{ .from = secret, .spelling = "secret/value.zig", .target = secret_value },
        .{ .from = state, .spelling = "state/edge.zig", .target = state_edge },
        .{ .from = state, .spelling = "state/machine.zig", .target = state_machine },
        .{ .from = state_machine, .spelling = "edge.zig", .target = state_edge },
        .{ .from = state_machine, .spelling = "runtime.zig", .target = state_runtime },
        .{ .from = state_machine, .spelling = "stage.zig", .target = state_stage },
        .{ .from = scope, .spelling = "scope/ref.zig", .target = scope_ref },
        .{ .from = scope, .spelling = "scope/slot.zig", .target = scope_slot },
        .{ .from = scope, .spelling = "scope/table.zig", .target = scope_table },
        .{ .from = scope_table, .spelling = "ref.zig", .target = scope_ref },
        .{ .from = scope_table, .spelling = "slot.zig", .target = scope_slot },
        .{ .from = scope_ref, .spelling = "slot.zig", .target = scope_slot },
        .{ .from = handle, .spelling = "handle/dense.zig", .target = handle_dense },
        .{ .from = handle, .spelling = "handle/Domain.zig", .target = handle_domain },
        .{ .from = handle, .spelling = "handle/index.zig", .target = handle_index },
        .{ .from = handle, .spelling = "handle/pool.zig", .target = handle_pool },
        .{ .from = handle, .spelling = "handle/secondary.zig", .target = handle_secondary },
        .{ .from = handle, .spelling = "handle/slot_map.zig", .target = handle_slot_map },
        .{ .from = handle_slot_map, .spelling = "Domain.zig", .target = handle_domain },
        .{ .from = handle_slot_map, .spelling = "pool.zig", .target = handle_pool },
        .{ .from = handle_dense, .spelling = "Domain.zig", .target = handle_domain },
        .{ .from = handle_dense, .spelling = "slot_map.zig", .target = handle_slot_map },
        .{ .from = handle_pool, .spelling = "Domain.zig", .target = handle_domain },
        .{ .from = sync, .spelling = "Atomic.zig", .target = atomic },
        .{ .from = sync, .spelling = "Order.zig", .target = order },
        .{ .from = order, .spelling = "Condition.zig", .target = condition },
        .{ .from = root, .spelling = "err.zig", .target = err },
        .{ .from = root, .spelling = "assert.zig", .target = assert_file },
        .{ .from = 0, .spelling = "aegis", .target = root },
        .{ .from = 0, .spelling = "aegis.secret", .target = secret },
        .{ .from = 0, .spelling = "aegis.sync", .target = sync },
        .{ .from = 0, .spelling = "aegis.int", .target = int },
        .{ .from = 0, .spelling = "aegis.id", .target = id },
        .{ .from = 0, .spelling = "aegis.units", .target = units },
    };
}

/// A project whose first source is `consumer`, followed by the aegis files, none of them selected.
pub fn project(gpa: std.mem.Allocator, consumer: []const u8) !glint.Project {
    var inputs: [sources.len + 1]Project.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = consumer };
    for (sources, 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .selected = false };
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
    for (sources, 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .selected = false };
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
/// package `package` names (none where empty).
pub const Extra = struct { name: []const u8, bytes: []const u8, package: []const u8 = "" };
/// An import among the extra sources, by their index in what the caller gives; a null `from` is
/// the consumer's, and a `target` of `consumer_file` the consumer itself.
pub const ExtraImport = struct { from: ?u32 = null, spelling: []const u8, target: u32 };
/// The consumer, as an `ExtraImport`'s target.
pub const consumer_file: u32 = std.math.maxInt(u32);

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
        inputs[i] = .{ .name = source.name, .bytes = if (replaced) bytes else source.bytes, .selected = false };
    }
    if (!revised) return error.FileNotFound;
    const mapped = imports();
    return Project.init(gpa, &inputs, &mapped, .{});
}

/// `project`, with `extra` sources after aegis's, none of them selected, and their imports.
pub fn projectWithSources(gpa: std.mem.Allocator, consumer: []const u8, extra: []const Extra, extra_imports: []const ExtraImport) !glint.Project {
    return projectInPackage(gpa, consumer, "", extra, extra_imports);
}

/// `projectWithSources`, the consumer a file of `package`.
pub fn projectInPackage(gpa: std.mem.Allocator, consumer: []const u8, package: []const u8, extra: []const Extra, extra_imports: []const ExtraImport) !glint.Project {
    const inputs = try gpa.alloc(Project.Input, sources.len + 1 + extra.len);
    defer gpa.free(inputs);
    inputs[0] = .{ .name = "consumer", .bytes = consumer, .package = package };
    for (sources, 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .selected = false };
    for (extra, sources.len + 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .selected = false, .package = source.package };
    const mapped = imports();
    const all = try gpa.alloc(Project.Import, mapped.len + extra_imports.len);
    defer gpa.free(all);
    @memcpy(all[0..mapped.len], &mapped);
    const first: u32 = sources.len + 1;
    for (extra_imports, mapped.len..) |entry, i| all[i] = .{ .from = if (entry.from) |from| first + from else 0, .spelling = entry.spelling, .target = if (entry.target == consumer_file) 0 else first + entry.target };
    return Project.init(gpa, inputs, all, .{});
}
