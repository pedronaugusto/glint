//! The totals of check-rule-readers' reports, printed whole: per rule, per class of finding (by the
//! opening words of the message each form writes, `forms`) and per file. The reports themselves
//! are installed beside them (zig-out/rule-readers/), so no count is ever read off a build
//! runner's cut output. Arguments: the reports, each a glint JSON report.
const std = @import("std");
const aegis = @import("aegis");

/// Each form of finding the guard writes, by the rule and the opening words of its message.
const Form = struct { rule: []const u8, opening: []const u8, class: []const u8 };
const forms = [_]Form{
    .{ .rule = "RULE_READERS", .opening = "a node's syntax tag reads by its shape", .class = "shape" },
    .{ .rule = "RULE_READERS", .opening = "std's ", .class = "spelling" },
    .{ .rule = "RULE_READERS", .opening = "the allowed reads of ", .class = "stale allowance" },
    .{ .rule = "NAME_TABLES", .opening = "std's ", .class = "text table" },
    .{ .rule = "NAME_TABLES", .opening = "the allowed text table at ", .class = "stale allowance" },
};

const Count = struct { key: []const u8, n: u32 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    var rules: std.ArrayList(Count) = .empty;
    var classes: std.ArrayList(Count) = .empty;
    var files: std.ArrayList(Count) = .empty;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.skip();
    while (args.next()) |path| {
        const bytes = try aegis.own.readFile(io, std.Io.Dir.cwd(), path, gpa, .fromRaw(256 * 1024 * 1024));
        const report = try std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{});
        const diagnostics = report.object.get("diagnostics") orelse continue;
        for (diagnostics.array.items) |each| {
            const rule = each.object.get("rule").?.string;
            const message = each.object.get("message").?.string;
            const source = each.object.get("source").?.string;
            try add(gpa, &rules, rule);
            var class: []const u8 = "other";
            for (forms) |form| if (std.mem.eql(u8, form.rule, rule) and std.mem.startsWith(u8, message, form.opening)) {
                class = form.class;
                break;
            };
            try add(gpa, &classes, try gpa.print("{s} {s}", .{ rule, class }));
            const at = std.mem.find(u8, source, "/src/") orelse 0;
            try add(gpa, &files, try gpa.print("{s} {s}", .{ rule, source[at + 1 ..] }));
        }
    }
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    const w = &out.interface;
    try w.writeAll("rule readers: totals\n");
    for ([_]*std.ArrayList(Count){ &rules, &classes, &files }) |list| {
        std.mem.sort(Count, list.items, {}, struct {
            fn less(_: void, x: Count, y: Count) bool {
                return x.n > y.n or (x.n == y.n and std.mem.order(u8, x.key, y.key) == .lt);
            }
        }.less);
        for (list.items) |each| try w.print("  {d: >5} {s}\n", .{ each.n, each.key });
        try w.writeAll("\n");
    }
    try w.flush();
}

fn add(gpa: std.mem.Allocator, list: *std.ArrayList(Count), key: []const u8) !void {
    for (list.items) |*each| if (std.mem.eql(u8, each.key, key)) {
        each.n += 1;
        return;
    };
    try list.append(gpa, .{ .key = key, .n = 1 });
}
