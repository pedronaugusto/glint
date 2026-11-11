// Z044 twin: the same done the way the rule leaves
pub fn down(n: u32) u32 {
    if (n == 0) return 0;
    return down(n - 1);
}
