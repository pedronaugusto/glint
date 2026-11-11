//! Hygiene: the count a partial read or write returns, discarded: `_ = X(...)` or
//! `_ = try X(...)` where every callee of X is one of std's functions that may move fewer bytes
//! than asked and say how many by their result (`counted`). Discarding it drops what the short
//! read or write left; std's `*All` forms (`writeAll`, `readSliceAll`) loop until done.
//! The list is closed against Zig 0.17's std: each function there returns `usize` and its own
//! doc says the count may be short. A callee that does not resolve is silent.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Written = @import("Written.zig");

/// std's functions whose `usize` result is the part they moved, which may be less than asked.
pub const counted = [_][]const u8{
    "posix.read",
    "Io.Writer.write",
    "Io.Writer.writeVec",
    "Io.Writer.writeSplat",
    "Io.Writer.splatByte",
    "Io.Writer.splatBytes",
    "Io.Writer.sendFile",
    "Io.Writer.sendFileReading",
    "Io.Reader.readVec",
    "Io.Reader.readSliceShort",
    "Io.Reader.stream",
    "Io.File.readStreaming",
    "Io.File.readPositional",
    "Io.File.writeStreaming",
    "Io.File.writePositional",
};

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .assign) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const target, const value = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(target) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) continue;
        var call = Written.ungrouped(tree, value);
        if (tree.nodeTag(call) == .@"try") call = Written.ungrouped(tree, tree.nodeData(call).node);
        if (!Facts.calls.written(tree, call)) continue;
        for (counted) |path| {
            if (try Governed.stdCall(c, call, path) != .yes) continue;
            try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("the count std.{s} returns is discarded: it may have moved fewer bytes than asked; use the count, or the function's *All form", .{path}));
            break;
        }
    }
}

const breadth = @import("breadth.zig");

test "breadth: discarded count: a partial read or write's count dropped, reported; the All forms and a kept count not" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(b: []u8) !void { _ = try std.posix.read(0, b); }", 1);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(w: *std.Io.Writer, b: []const u8) !void { _ = try w.write(b); }", 1);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(r: *std.Io.Reader, b: []u8) void { _ = r.readSliceShort(b) catch 0; }", 0);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(r: *std.Io.Reader, b: []u8) !void { _ = try r.readSliceShort(b); }", 1);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(w: *std.Io.Writer, b: []const u8) !usize { try w.writeAll(b); return try w.write(b); }", 0);
    try breadth.expectFindings(check, "fn read(b: []u8) !usize { return b.len; } pub fn f(b: []u8) !void { _ = try read(b); }", 0);
}
