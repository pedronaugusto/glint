// P008 (review 8, m4): a private function a container's comptime block references is still
// reached from nowhere outside the file.
fn private(a_id: u32, b_id: u32) u32 {
    return a_id +% b_id;
}
comptime {
    _ = &private;
}
