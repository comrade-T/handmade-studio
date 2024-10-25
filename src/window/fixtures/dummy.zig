const std = @import("std");
const Allocator = std.mem.Allocator;

fn add(x: f32, y: f32) f32 {
    return x + y;
}

fn sub(a: f64, b: f64) f64 {
    return a - b;
}

fn callAddExample() void {
    _ = add(1, 1);
}

pub const not_false = true;

var xxx = 0;
var yyy = 0;

const String = []const u8;
