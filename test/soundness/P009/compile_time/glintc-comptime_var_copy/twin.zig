// P009: a `comptime var`'s value is compiled in, and so is a const copied from it: its address is
// static memory, not the frame (lookout's CompiledFilter.sep; tycho-b9's report, 8i).
pub fn separators(comptime p: []const u8) []const u8 {
    comptime var buffer: [p.len]u8 = undefined;
    comptime for (p, &buffer) |ch, *slot| {
        slot.* = if (ch == '/') '\\' else ch;
    };
    const final = buffer;
    return &final;
}
