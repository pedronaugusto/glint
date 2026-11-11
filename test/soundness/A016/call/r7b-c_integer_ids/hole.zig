// A016: two identifying parameters of a public function, both c_uint
pub fn link(parent_id: c_uint, child_id: c_uint) c_uint {
    return parent_id +% child_id;
}
