// P009: std.mem.swap exchanges the values two pointers reach; it keeps neither pointer.
const std = @import("std");
pub fn f(row: []i32, k: usize) i32 {
    var j: i32 = 1;
    std.mem.swap(i32, &j, &row[k]);
    return j;
}
