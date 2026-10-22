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

/// Imports as aegis's own build wires them, then the ways the consumer (source 0) imports aegis.
fn imports() [61]Project.Import {
    return .{
        .{ .from = file(root), .spelling = "secret.zig", .target = file(secret) },
        .{ .from = file(root), .spelling = "sync.zig", .target = file(sync) },
        .{ .from = file(root), .spelling = "int.zig", .target = file(int) },
        .{ .from = file(root), .spelling = "id.zig", .target = file(id) },
        .{ .from = file(root), .spelling = "units.zig", .target = file(units) },
        .{ .from = file(secret), .spelling = "secret/inline.zig", .target = file(secret_inline) },
        .{ .from = file(secret), .spelling = "secret/SecretBytes.zig", .target = file(secret_bytes) },
        .{ .from = file(sync), .spelling = "Guarded.zig", .target = file(guarded) },
        .{ .from = file(sync), .spelling = "BlockingGuarded.zig", .target = file(blocking_guarded) },
        .{ .from = file(sync), .spelling = "RwGuarded.zig", .target = file(rw_guarded) },
        .{ .from = file(sync), .spelling = "SpinRwGuarded.zig", .target = file(spin_rw_guarded) },
        .{ .from = file(sync), .spelling = "Condition.zig", .target = file(condition) },
        .{ .from = file(sync), .spelling = "Once.zig", .target = file(once) },
        .{ .from = file(sync), .spelling = "Lazy.zig", .target = file(lazy) },
        .{ .from = file(sync), .spelling = "Confined.zig", .target = file(confined) },
        .{ .from = file(once), .spelling = "Condition.zig", .target = file(condition) },
        .{ .from = file(int), .spelling = "scalar.zig", .target = file(scalar) },
        .{ .from = file(id), .spelling = "scalar.zig", .target = file(scalar) },
        .{ .from = file(id), .spelling = "units.zig", .target = file(units) },
        .{ .from = file(units), .spelling = "scalar.zig", .target = file(scalar) },
        .{ .from = file(units), .spelling = "int.zig", .target = file(int) },
        .{ .from = file(root), .spelling = "bounded.zig", .target = file(bounded) },
        .{ .from = file(root), .spelling = "own.zig", .target = file(own) },
        .{ .from = file(root), .spelling = "input.zig", .target = file(input) },
        .{ .from = file(root), .spelling = "state.zig", .target = file(state) },
        .{ .from = file(root), .spelling = "scope.zig", .target = file(scope) },
        .{ .from = file(root), .spelling = "handle.zig", .target = file(handle) },
        .{ .from = file(sync), .spelling = "Shared.zig", .target = file(shared) },
        .{ .from = file(secret), .spelling = "secret/value.zig", .target = file(secret_value) },
        .{ .from = file(state), .spelling = "state/edge.zig", .target = file(state_edge) },
        .{ .from = file(state), .spelling = "state/machine.zig", .target = file(state_machine) },
        .{ .from = file(state_machine), .spelling = "edge.zig", .target = file(state_edge) },
        .{ .from = file(state_machine), .spelling = "runtime.zig", .target = file(state_runtime) },
        .{ .from = file(state_machine), .spelling = "stage.zig", .target = file(state_stage) },
        .{ .from = file(scope), .spelling = "scope/ref.zig", .target = file(scope_ref) },
        .{ .from = file(scope), .spelling = "scope/slot.zig", .target = file(scope_slot) },
        .{ .from = file(scope), .spelling = "scope/table.zig", .target = file(scope_table) },
        .{ .from = file(scope_table), .spelling = "ref.zig", .target = file(scope_ref) },
        .{ .from = file(scope_table), .spelling = "slot.zig", .target = file(scope_slot) },
        .{ .from = file(scope_ref), .spelling = "slot.zig", .target = file(scope_slot) },
        .{ .from = file(handle), .spelling = "handle/dense.zig", .target = file(handle_dense) },
        .{ .from = file(handle), .spelling = "handle/Domain.zig", .target = file(handle_domain) },
        .{ .from = file(handle), .spelling = "handle/index.zig", .target = file(handle_index) },
        .{ .from = file(handle), .spelling = "handle/pool.zig", .target = file(handle_pool) },
        .{ .from = file(handle), .spelling = "handle/secondary.zig", .target = file(handle_secondary) },
        .{ .from = file(handle), .spelling = "handle/slot_map.zig", .target = file(handle_slot_map) },
        .{ .from = file(handle_slot_map), .spelling = "Domain.zig", .target = file(handle_domain) },
        .{ .from = file(handle_slot_map), .spelling = "pool.zig", .target = file(handle_pool) },
        .{ .from = file(handle_dense), .spelling = "Domain.zig", .target = file(handle_domain) },
        .{ .from = file(handle_dense), .spelling = "slot_map.zig", .target = file(handle_slot_map) },
        .{ .from = file(handle_pool), .spelling = "Domain.zig", .target = file(handle_domain) },
        .{ .from = file(sync), .spelling = "Atomic.zig", .target = file(atomic) },
        .{ .from = file(sync), .spelling = "Order.zig", .target = file(order) },
        .{ .from = file(order), .spelling = "Condition.zig", .target = file(condition) },
        .{ .from = file(root), .spelling = "err.zig", .target = file(err) },
        .{ .from = file(0), .spelling = "aegis", .target = file(root) },
        .{ .from = file(0), .spelling = "aegis.secret", .target = file(secret) },
        .{ .from = file(0), .spelling = "aegis.sync", .target = file(sync) },
        .{ .from = file(0), .spelling = "aegis.int", .target = file(int) },
        .{ .from = file(0), .spelling = "aegis.id", .target = file(id) },
        .{ .from = file(0), .spelling = "aegis.units", .target = file(units) },
    };
}
fn file(index: u32) Project.FileId {
    return Project.FileId.fromRaw(index);
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
    const lib_file = file(sources.len + 1);
    const mapped = imports();
    var all: [mapped.len + 2]Project.Import = undefined;
    @memcpy(all[0..mapped.len], &mapped);
    all[mapped.len] = .{ .from = file(0), .spelling = "lib", .target = lib_file };
    all[mapped.len + 1] = .{ .from = lib_file, .spelling = "aegis", .target = file(root) };
    return Project.init(gpa, &inputs, &all, .{});
}

/// A source of another module beside aegis's, such as a fixture standing for std.
pub const Extra = struct { name: []const u8, bytes: []const u8 };
/// An import among the extra sources, by their index in what the caller gives; a null `from` is
/// the consumer's.
pub const ExtraImport = struct { from: ?u32 = null, spelling: []const u8, target: u32 };

/// `project`, with `extra` sources after aegis's, none of them selected, and their imports.
pub fn projectWithSources(gpa: std.mem.Allocator, consumer: []const u8, extra: []const Extra, extra_imports: []const ExtraImport) !glint.Project {
    const inputs = try gpa.alloc(Project.Input, sources.len + 1 + extra.len);
    defer gpa.free(inputs);
    inputs[0] = .{ .name = "consumer", .bytes = consumer };
    for (sources, 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .selected = false };
    for (extra, sources.len + 1..) |source, i| inputs[i] = .{ .name = source.name, .bytes = source.bytes, .selected = false };
    const mapped = imports();
    const all = try gpa.alloc(Project.Import, mapped.len + extra_imports.len);
    defer gpa.free(all);
    @memcpy(all[0..mapped.len], &mapped);
    const first: u32 = sources.len + 1;
    for (extra_imports, mapped.len..) |entry, i| all[i] = .{ .from = if (entry.from) |from| file(first + from) else file(0), .spelling = entry.spelling, .target = file(first + entry.target) };
    return Project.init(gpa, inputs, all, .{});
}
