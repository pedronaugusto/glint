// A016: identifying names in upper snake (parent_ID, child_ID), one integer type
pub fn link(parent_ID: u32, child_ID: u32) u32 {
    return parent_ID +% child_ID;
}
