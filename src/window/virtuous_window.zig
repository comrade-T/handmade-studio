const std = @import("std");
const Buffer = @import("neo_buffer").Buffer;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Window = struct {
    exa: Allocator,

    buf: *Buffer,
    cursor: Cursor,

    pane_x: f32,
    pane_y: f32,

    pub fn spawn(exa: Allocator, buf: *Buffer, pane_x: f32, pane_y: f32) !*@This() {
        const self = try exa.create(@This());
        self.* = .{
            .exa = exa,

            .buf = buf,
            .cursor = Cursor{},

            .pane_x = pane_x,
            .pane_y = pane_y,
        };
        return self;
    }

    pub fn destroy(self: *@This()) void {
        self.exa.destroy(self);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

const Cursor = struct {
    line: usize = 0,
    col: usize = 0,

    pub fn set(self: *Cursor, line: usize, col: usize) void {
        self.line = line;
        self.col = col;
    }
};
