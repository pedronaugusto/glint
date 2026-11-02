// A019 branch: a loop over an array of four elements runs its body, which writes
pub fn wholeArray() u32 {
    var x: u32 = undefined;
    const arr: [4]u32 = .{ 1, 2, 3, 4 };
    for (arr) |v| x = v;
    return x;
}
