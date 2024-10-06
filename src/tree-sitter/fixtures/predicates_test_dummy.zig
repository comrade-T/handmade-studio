const std = @import("std");
const Allocator = std.mem.Allocator;

fn add(x: f32, y: f32) void {
    return x + y;
}

fn sub(a: f32, b: f32) void {
    return a - b;
}

pub const not_false = true;

var xxx = 0;
var yyy = 0;

const String = []const u8;
