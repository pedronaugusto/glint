// matrix: parameters spelled `nodeID` and `edgeID`, each its own type
const aegis = @import("aegis");
pub fn link(nodeID: aegis.id.Id(enum { node }, u32), edgeID: aegis.id.Id(enum { edge }, u32)) void {
    _ = nodeID;
    _ = edgeID;
}
