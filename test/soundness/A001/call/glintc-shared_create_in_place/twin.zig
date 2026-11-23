// A001: a key built in its shared block by aegis's createInPlace, a tuple as the context, through the Secret's own API (review b9 A2: cloak's createWith sites).
const std = @import("std");
const aegis = @import("aegis");
const Secret = aegis.Secret;
fn release(_: *State) void {}
const Handle = aegis.Shared(State, release);
const State = struct {
    gpa: std.mem.Allocator,
    material: Secret([32]u8),
};
pub const Key = struct {
    state: Handle,
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Key {
        const Build = struct {
            fn run(c: struct { std.mem.Allocator, []const u8 }, state: *State) error{Invalid}!void {
                state.* = .{ .gpa = c[0], .material = .init(undefined) };
                if (c[1].len != 32) return error.Invalid;
                @memcpy(state.material.exposeMut(), c[1][0..32]);
            }
        };
        return .{ .state = try .createInPlace(gpa, .{ gpa, bytes }, Build.run) };
    }
};
