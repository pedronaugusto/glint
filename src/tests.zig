//! A test root: the CLI's, the runner's and the library's contract tests. The contract tests are
//! split across roots (test_danger.zig, test_pack.zig) that compile and run as parallel steps.
test {
    _ = @import("Token_test.zig");
    _ = @import("build_gate_test.zig");
    _ = @import("glint");
    _ = @import("cli_test.zig");
    _ = @import("Runner_test.zig");
    _ = @import("contract_test.zig");
}

// The aegis files this binary's tests share (ci/aegis_sources.zig) are as they were frozen,
// whichever tests ran before this one in the shuffled order.
test "the shared base is as it was frozen" {
    try @import("aegis_sources").expectBaseFrozen();
}

// The rule set is what docs/design.md's rule table lists: every row's ids are rules glint has, but
// a row marked "not built", whose ids it has not; and every rule glint has is in one row.
test "the design table's rule inventory is the rule set" {
    const std = @import("std");
    const Rule = @import("glint").Rule;
    const design = @embedFile("design.md");
    const header = "| ID | Kind | Claim and construct list |\n|---|---|---|\n";
    const start = (std.mem.find(u8, design, header) orelse return error.TestUnexpectedResult) + header.len;
    var listed: std.ArrayList(Rule) = .empty;
    defer listed.deinit(std.testing.allocator);
    var rows = std.mem.splitScalar(u8, design[start..], '\n');
    while (rows.next()) |row| {
        if (!std.mem.startsWith(u8, row, "| ")) break;
        var cells = std.mem.splitSequence(u8, row[2..], " | ");
        const ids = cells.next() orelse return error.TestUnexpectedResult;
        const built = !std.mem.eql(u8, cells.next() orelse return error.TestUnexpectedResult, "not built");
        var each = std.mem.tokenizeScalar(u8, ids, ' ');
        while (each.next()) |id| {
            errdefer std.debug.print("design.md's rule table: {s}\n", .{id});
            if (!built) {
                try std.testing.expectEqual(null, Rule.parse(id));
                continue;
            }
            try listed.append(std.testing.allocator, Rule.parse(id) orelse return error.TestUnexpectedResult);
        }
    }
    try std.testing.expectEqual(std.meta.tags(Rule).len, listed.items.len);
    for (std.meta.tags(Rule)) |rule| {
        errdefer std.debug.print("not in design.md's rule table once: {t}\n", .{rule});
        try std.testing.expectEqual(1, std.mem.countScalar(Rule, listed.items, rule));
    }
}
