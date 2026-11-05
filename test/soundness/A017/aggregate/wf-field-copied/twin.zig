// gantry src/types.zig:23 (Edge.kind) as src/graph/Storage.zig writes it (:96, :117, :199): each new edge
// takes its kind from the edge it is made from (`dest.* = .{ ..., .kind = edge.kind }`), a merge compares
// neighbours' kinds, and a check switches on it. A kind is copied from one record into another, never
// moved from one value to another in any record: there is no state machine.
const std = @import("std");
pub const Kind = enum { import, include, reference };
pub const Edge = struct { from: []const u8, to: []const u8, kind: Kind = .import, count: u32 = 1 };
pub fn copyInto(edges: []const Edge, out: []Edge) void {
    for (edges, out) |edge, *dest| dest.* = .{ .from = edge.from, .to = edge.to, .kind = edge.kind, .count = edge.count };
}
pub fn byDirectory(edges: []const Edge, out: []Edge, depth: usize) void {
    for (edges, out) |edge, *dest| dest.* = .{ .from = edge.from[0..@min(depth, edge.from.len)], .to = edge.to[0..@min(depth, edge.to.len)], .kind = edge.kind, .count = edge.count };
}
pub fn merged(edges: []const Edge, out: []Edge) usize {
    var n: usize = 0;
    for (edges) |edge| {
        if (n > 0 and std.mem.eql(u8, out[n - 1].from, edge.from) and std.mem.eql(u8, out[n - 1].to, edge.to) and out[n - 1].kind == edge.kind) {
            out[n - 1].count += edge.count;
            continue;
        }
        out[n] = .{ .from = edge.from, .to = edge.to, .kind = edge.kind };
        n += 1;
    }
    return n;
}
pub fn weight(e: Edge) u32 {
    return switch (e.kind) {
        .import => 2 * e.count,
        .include => e.count,
        .reference => 0,
    };
}
