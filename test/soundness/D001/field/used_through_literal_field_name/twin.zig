// twin: the private function is named by @field with a literal name
fn helper() u8 {
    return 1;
}
pub fn run() u8 {
    return @field(@This(), "helper")();
}
