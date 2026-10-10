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

/// Imports as aegis's own build wires them, then the ways the consumer (source 0) imports aegis.
fn imports() [18]Project.Import {
    return .{
        .{ .from = file(root), .spelling = "secret", .target = file(secret) },
        .{ .from = file(root), .spelling = "sync", .target = file(sync) },
        .{ .from = file(root), .spelling = "int", .target = file(int) },
        .{ .from = file(root), .spelling = "id", .target = file(id) },
        .{ .from = file(root), .spelling = "units", .target = file(units) },
        .{ .from = file(secret), .spelling = "secret/inline.zig", .target = file(secret_inline) },
        .{ .from = file(secret), .spelling = "secret/SecretBytes.zig", .target = file(secret_bytes) },
        .{ .from = file(sync), .spelling = "Guarded.zig", .target = file(guarded) },
        .{ .from = file(int), .spelling = "scalar", .target = file(scalar) },
        .{ .from = file(id), .spelling = "scalar", .target = file(scalar) },
        .{ .from = file(units), .spelling = "scalar", .target = file(scalar) },
        .{ .from = file(units), .spelling = "int", .target = file(int) },
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
