//! The program contract: what a caller that runs glint as a program writes (the project file)
//! and reads back (the report, the result record, the surface lines), by version. A change is
//! additive where it can be and keeps its version; a breaking one is read beside the old for
//! exactly one release, and the release after deletes the old reader (docs/design.md, "The
//! program contract").
const std = @import("std");

/// The project-file versions this glint reads, oldest first: two only inside a window.
pub const versions = [_]u32{1};

/// `glint --contract`'s answer, the line a caller parses before it writes a project file:
/// `glint-contract` and each version this glint reads.
pub fn writeVersions(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("glint-contract");
    for (versions) |version| try writer.print(" {d}", .{version});
    try writer.writeByte('\n');
}

test "the contract's answer is one plain line a caller parses" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeVersions(&writer);
    try std.testing.expectEqualStrings("glint-contract 1\n", writer.buffered());
}
