// glint-c: A014 call: a struct local whose type holds no address (an enum's tag, a number) is handed to code glint cannot read, then returned
const Seen = struct { kind: enum { open, shut }, n: u32 };
pub fn seen(note: *const fn (*Seen) void) Seen {
    var out: Seen = .{ .kind = .open, .n = 0 };
    out.n = 4;
    note(&out);
    return out;
}
