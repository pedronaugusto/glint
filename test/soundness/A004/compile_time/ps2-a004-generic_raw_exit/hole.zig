const std = @import("std");
const aegis = @import("aegis");
const Bytes = aegis.units.Bytes(usize);
const Span = struct { start: Bytes, end: Bytes };

const It = struct {
    at: usize = 0,
    fn nextSpan(it: *It) ?Span {
        if (it.at == 3) return null;
        it.at += 1;
        return .{ .start = .fromRaw(it.at - 1), .end = .fromRaw(it.at) };
    }
};

fn ends(out: []usize, it: anytype) usize {
    var n: usize = 0;
    var start: usize = 0;
    while (it.nextSpan()) |span| {
        if (!span.start.eql(.fromRaw(start))) return 0;
        out[n] = span.end.raw();
        start = span.end.raw();
        start += 1;
        n += 1;
    }
    return n;
}

pub fn count() usize {
    var out: [4]usize = undefined;
    var it: It = .{};
    return ends(&out, &it);
}
