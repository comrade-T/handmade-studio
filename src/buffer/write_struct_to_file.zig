const std = @import("std");
const s2s = @import("s2s");

fn testSerDesAlloc(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try s2s.serialize(data.writer(), T, value);

    var stream = std.io.fixedBufferStream(data.items);

    var deserialized = try s2s.deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer s2s.free(std.testing.allocator, T, &deserialized);

    try std.testing.expectEqual(value, deserialized);
}

test "example" {
    try testSerDesAlloc(void, {});
    try testSerDesAlloc(bool, false);
    try testSerDesAlloc(bool, true);
    try testSerDesAlloc(u1, 0);
    try testSerDesAlloc(u1, 1);
    try testSerDesAlloc(u8, 0xFF);
    try testSerDesAlloc(u32, 0xDEADBEEF);
    try testSerDesAlloc(usize, 0xDEADBEEF);
}
