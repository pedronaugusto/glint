const std = @import("std");
const glint = @import("glint");

pub fn main() !void {
    var project = try glint.Project.init(std.heap.page_allocator, &.{.{ .name = "consumer", .bytes = "const dependency = @import(\"dependency\");" }}, &.{}, .{});
    defer project.deinit();
    const handle = try project.handle(glint.Project.FileId.fromRaw(0)); // safe: the fixture creates source zero.
    if ((try project.declarations(handle)).len != 1) return error.MissingDeclaration;
    var report = try glint.run(std.heap.page_allocator, &project, .{});
    defer report.deinit();
    if (!report.complete or report.diagnostics.len != 1 or report.diagnostics[0].rule != .Z013) return error.UnexpectedDiagnostic;
    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer output.deinit();
    try report.write(&output.writer, &project, .json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, output.written(), .{});
    defer parsed.deinit();
    if (parsed.value.object.get("version").?.integer != 1) return error.InvalidSchema;
}
