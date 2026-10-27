//! Completed-run verification has no filesystem policy or implicit acceptance.
const std = @import("std");

/// Failure or success class from the CLI's version-one result protocol.
pub const Outcome = enum { running, clean, findings, argument_failure, input_failure, traversal_failure, canceled, output_failure, analysis_incomplete, tool_failure, help };
/// Required fields of a completed-run result. Coverage is reported separately.
pub const Record = struct {
    version: u32,
    run_id: []const u8,
    completed: bool,
    outcome: Outcome,
    sources: usize,
    findings: usize,
    suppressed: usize,
    output_bytes: usize,
    output_sha256: []const u8,
};
/// A malformed/truncated result is input failure, never completion.
pub const VerifyError = std.mem.Allocator.Error || error{InvalidResult};

/// Verifies an exact invocation and captured output. Finding acceptance belongs to callers.
pub fn verify(gpa: std.mem.Allocator, bytes: []const u8, expected_run_id: []const u8, exit_code: u8, output: []const u8) VerifyError!bool {
    const parsed = std.json.parseFromSlice(Record, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResult,
    };
    defer parsed.deinit();
    const record = parsed.value;
    if (record.version != 1 or !record.completed or !std.mem.eql(u8, expected_run_id, record.run_id)) return false;
    if (record.sources == 0 or record.output_bytes != output.len) return false;
    switch (record.outcome) {
        .clean => if (exit_code != 0 or record.findings != 0) return false,
        .findings => if (exit_code != 1 or record.findings == 0) return false,
        else => return false,
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    return std.mem.eql(u8, &std.fmt.bytesToHex(&digest, .lower), record.output_sha256);
}

test "completion verifier refuses truncated, stale and signal-like runs" {
    const output = "finding\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    const a = std.testing.allocator;
    const bytes = try std.json.Stringify.valueAlloc(a, Record{ .version = 1, .run_id = "invocation", .completed = true, .outcome = .findings, .sources = 1, .findings = 1, .suppressed = 0, .output_bytes = output.len, .output_sha256 = &std.fmt.bytesToHex(&digest, .lower) }, .{});
    defer a.free(bytes);
    try std.testing.expect(try verify(a, bytes, "invocation", 1, output));
    try std.testing.expect(!try verify(a, bytes, "other-run", 1, output));
    try std.testing.expect(!try verify(a, bytes, "invocation", 137, output));
    try std.testing.expect(!try verify(a, bytes, "invocation", 1, output[0..4]));
    try std.testing.expectError(error.InvalidResult, verify(a, bytes[0 .. bytes.len - 1], "invocation", 1, output));
}
