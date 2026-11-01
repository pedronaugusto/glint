// review 4: u/h01_jumps_skip_write.zig
// held? each function skips the write on some path by a jump, then reads (expected: one finding each)
pub fn b1(c: bool) u32 {
    var x: u32 = undefined;
    blk: {
        if (c) break :blk;
        x = 1;
    }
    return x;
}
pub fn b2(c: bool) u32 {
    var x: u32 = undefined;
    for (0..2) |_| {
        if (c) break;
        x = 1;
    }
    return x;
}
pub fn b3(c: bool) u32 {
    var x: u32 = undefined;
    outer: for (0..2) |_| {
        for (0..2) |_| {
            if (c) break :outer;
        }
        x = 1;
    }
    return x;
}
pub fn b4(c: bool, v: u8) u32 {
    var x: u32 = undefined;
    sw: switch (v) {
        0 => {
            if (c) break :sw;
            x = 1;
        },
        else => x = 2,
    }
    return x;
}
pub fn b5(c: bool) u32 {
    var x: u32 = undefined;
    const y: u32 = blk: {
        if (c) break :blk 0;
        x = 1;
        break :blk 1;
    };
    return x + y;
}
pub fn b6(c: bool) u32 {
    var x: u32 = undefined;
    for (0..1) |_| {
        if (c) continue;
        x = 1;
    }
    return x;
}
pub fn b7(c: bool) u32 {
    var x: u32 = undefined;
    blk: {
        while (c) {
            break :blk;
        }
        x = 1;
    }
    return x;
}
pub fn b8(c: bool) u32 {
    var x: u32 = undefined;
    for (0..1) |_| {
        x = if (c) break else 1;
    }
    return x;
}
pub fn b9(c: bool) u32 {
    var x: u32 = undefined;
    blk: {
        x = if (c) break :blk else 1;
    }
    return x;
}
