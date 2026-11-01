// review 4: u/xs/main.zig
// A019: parts tracking in main.zig; the @fieldParentPtr that makes c.observer reach all of c is in
// counter.zig, imported but not named on the command line.
const counter = @import("counter.zig");
pub fn run() void {
    var c: counter.Counter = undefined;
    c.observer = .{ .vtable = &counter.Counter.vtable };
    c.observer.see(3);
}
