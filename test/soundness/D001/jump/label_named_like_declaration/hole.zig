// D001: a private function named nowhere; a block label spells its name
fn total() u8 {
    return 1;
}
pub fn run(x: u8) u8 {
    return total: {
        if (x == 0) break :total 0;
        break :total x;
    };
}
