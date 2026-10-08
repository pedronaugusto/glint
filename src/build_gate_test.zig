const std = @import("std");
const glint = @import("glint");
const Gate = @import("BuildGate.zig");
fn accepts(output: []const u8, completed: bool, outcome: glint.Completion.Outcome, findings: usize, status: u8, nonce: []const u8) !bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    const a = std.testing.allocator;
    const receipt = try std.json.Stringify.valueAlloc(a, glint.Completion.Record{ .version = 1, .run_id = "fresh", .completed = completed, .outcome = outcome, .sources = 1, .findings = findings, .suppressed = 0, .output_bytes = output.len, .output_sha256 = &std.fmt.bytesToHex(&digest, .lower) }, .{});
    defer a.free(receipt);
    return Gate.accepted(a, receipt, nonce, status, output);
}
test "G2 build helper accepts complete reports and rejects gates incomplete signals and stale receipt" {
    const report = "{\"analysis_complete\":true,\"diagnostics\":[{\"level\":\"report\"}]}";
    const gate = "{\"analysis_complete\":true,\"diagnostics\":[{\"level\":\"gate\"}]}";
    const incomplete_allowed = "{\"analysis_complete\":false,\"diagnostics\":[]}";
    try std.testing.expect(try accepts(report, true, .findings, 1, 1, "fresh"));
    try std.testing.expect(try accepts("{\"analysis_complete\":true,\"diagnostics\":[]}", true, .clean, 0, 0, "fresh"));
    try std.testing.expect(!try accepts(gate, true, .findings, 1, 1, "fresh"));
    try std.testing.expect(!try accepts(incomplete_allowed, false, .analysis_incomplete, 0, 2, "fresh"));
    try std.testing.expect(!try accepts(incomplete_allowed, true, .clean, 0, 0, "fresh"));
    try std.testing.expect(!try accepts(report, true, .findings, 1, 137, "fresh"));
    try std.testing.expect(!try accepts(report, true, .findings, 1, 1, "stale"));
}
