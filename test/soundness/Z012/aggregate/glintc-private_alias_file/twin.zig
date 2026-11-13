// Z012: the file is reached only through a private alias: its public Recorder never reaches a
// consumer, and its private field type says nothing (gantry's tokens.zig, 8f).
const tokens = @import("module/tokens.zig");
pub fn first() u8 {
    const r: tokens.Recorder = .{ .named = .{ .n = 1 } };
    return r.named.n;
}
