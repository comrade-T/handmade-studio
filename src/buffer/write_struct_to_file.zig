const std = @import("std");
const s2s = @import("s2s");

//////////////////////////////////////////////////////////////////////////////////////////////

fn testSerDesAlloc(comptime cmp_type: enum { eq, eqSlices, eqPtrContent }, comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try s2s.serialize(data.writer(), T, value);

    var stream = std.io.fixedBufferStream(data.items);
    var deserialized = try s2s.deserializeAlloc(stream.reader(), T, std.testing.allocator);
    defer s2s.free(std.testing.allocator, T, &deserialized);

    switch (cmp_type) {
        .eq => try std.testing.expectEqual(value, deserialized),
        .eqSlices => try std.testing.expectEqualSlices(std.meta.Child(T), value, deserialized),
        .eqPtrContent => try std.testing.expectEqual(value.*, deserialized.*),
    }
}

test "ser/des" {
    try testSerDesAlloc(.eq, void, {});
    try testSerDesAlloc(.eq, bool, false);
    try testSerDesAlloc(.eq, bool, true);
    try testSerDesAlloc(.eq, u1, 0);
    try testSerDesAlloc(.eq, u1, 1);
    try testSerDesAlloc(.eq, u8, 0xFF);
    try testSerDesAlloc(.eq, u32, 0xDEADBEEF);
    try testSerDesAlloc(.eq, usize, 0xDEADBEEF);

    try testSerDesAlloc(.eq, f16, std.math.pi);
    try testSerDesAlloc(.eq, f32, std.math.pi);
    try testSerDesAlloc(.eq, f64, std.math.pi);
    try testSerDesAlloc(.eq, f80, std.math.pi);
    try testSerDesAlloc(.eq, f128, std.math.pi);

    try testSerDesAlloc(.eq, [3]u8, "hi!".*);
    try testSerDesAlloc(.eqSlices, []const u8, "Hello, World!");
    try testSerDesAlloc(.eqPtrContent, *const [3]u8, "foo");

    try testSerDesAlloc(.eq, enum { a, b, c }, .a);
    try testSerDesAlloc(.eq, enum { a, b, c }, .b);
    try testSerDesAlloc(.eq, enum { a, b, c }, .c);

    try testSerDesAlloc(.eq, enum(u8) { a, b, c }, .a);
    try testSerDesAlloc(.eq, enum(u8) { a, b, c }, .b);
    try testSerDesAlloc(.eq, enum(u8) { a, b, c }, .c);

    try testSerDesAlloc(.eq, enum(usize) { a, b, c }, .a);
    try testSerDesAlloc(.eq, enum(usize) { a, b, c }, .b);
    try testSerDesAlloc(.eq, enum(usize) { a, b, c }, .c);

    try testSerDesAlloc(.eq, enum(isize) { a, b, c }, .a);
    try testSerDesAlloc(.eq, enum(isize) { a, b, c }, .b);
    try testSerDesAlloc(.eq, enum(isize) { a, b, c }, .c);

    const TestEnum = enum(u8) { a, b, c, _ };
    try testSerDesAlloc(.eq, TestEnum, .a);
    try testSerDesAlloc(.eq, TestEnum, .b);
    try testSerDesAlloc(.eq, TestEnum, .c);
    try testSerDesAlloc(.eq, TestEnum, @as(TestEnum, @enumFromInt(0xB1)));

    try testSerDesAlloc(.eq, union(enum) { a: f32, b: u32 }, .{ .a = 1.5 });
    try testSerDesAlloc(.eq, union(enum) { a: f32, b: u32 }, .{ .b = 2.0 });

    try testSerDesAlloc(.eq, ?u32, null);
    try testSerDesAlloc(.eq, ?u32, 143);
}

test "fails to compile" {
    // // It seems like I can't serialize error values.

    // try testSerDesAlloc(struct { val: error{ Foo, Bar } }, .{ .val = error.Foo });
    // try testSerDesAlloc(struct { val: error{ Bar, Foo } }, .{ .val = error.Bar });

    // try testSerDesAlloc(struct { val: error{ Bar, Foo }!u32 }, .{ .val = error.Bar });
    // try testSerDesAlloc(struct { val: error{ Bar, Foo }!u32 }, .{ .val = 0xFF });
}
