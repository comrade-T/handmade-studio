const std = @import("std");
const Cursor = @import("cursor").Cursor;
const Buffer = @import("neo_buffer").Buffer;
const ContentVendor = @import("content_vendor").ContentVendor;
const testIter = ContentVendor.CurrentJobIterator.testIter;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Window = struct {
    a: Allocator,
    vendor: *ContentVendor,

    // TODO: let's work on single cursor first,
    // then we can move on to multiple cursors after that.
    // either it's simultanious or individual separate cursors.
    // cursors: ArrayList(Cursor),

    cursor: Cursor,

    x: i32,
    y: i32,

    // Taking in a `ContentVendor` feels weird here.
    // So there's another `orchestrator` in place...

    // What am I trying to accomplish with @This?

    // An API to spawn windows
    // - Window.spawn(.{ .x = 10, .y = 20 }) perhaps?

    // An API to move around the cursor(s)
    // An API to interact with the Buffer (insert, delete)
    // ==> These are managed internally, not externally.
    //     @This receives input triggers, and act accordingly.

    pub fn spawn(a: Allocator, vendor: *ContentVendor, x: i32, y: i32) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .cursor = Cursor{},
            .vendor = vendor,

            .x = x,
            .y = y,
        };
        return self;
    }

    pub fn destroy(self: *@This()) void {
        // self.cursors.deinit();
        self.a.destroy(self);
    }

    pub fn insertChars(self: *@This(), chars: []const u8) void {
        self.insertCharsInternal(chars) catch @panic("error calling Window.insertCharsInternal()");
    }

    pub fn doCustomStuffs(self: *@This(), trigger: []const u8) !void {
        if (eql(u8, trigger, "up")) self.cursor.up(1);
        if (eql(u8, trigger, "down")) self.cursor.down(1, self.vendor.buffer.roperoot.weights().bols);
        if (eql(u8, trigger, "left")) self.cursor.left(1);
        if (eql(u8, trigger, "right")) {
            const buf_size = 1;
            var buf: [buf_size]u8 = undefined;
            const start_byte = try self.vendor.buffer.roperoot.getByteOffsetOfPosition(self.cursor.line, self.cursor.col);
            const content, const eol = self.vendor.buffer.roperoot.getRestOfLine(start_byte, &buf, buf_size);
            if (eol)
                self.cursor.set(self.cursor.line + 1, 0)
            else if (content.len > 0)
                self.cursor.set(self.cursor.line, self.cursor.col + 1);
        }
    }

    fn insertCharsInternal(self: *@This(), chars: []const u8) !void {
        const new_line, const new_col = try self.vendor.buffer.insertChars(chars, self.cursor.line, self.cursor.col);
        self.cursor.set(new_line, new_col);
    }
    test insertCharsInternal {
        var buf = try Buffer.create(testing_allocator, .string, "");
        try buf.initiateTreeSitter(.zig);
        defer buf.destroy();

        const vendor = try ContentVendor.init(testing_allocator, buf);
        defer vendor.deinit();

        const win = try Window.spawn(testing_allocator, vendor, 100, 100);
        defer win.destroy();

        {
            win.insertChars("c");
            const iter = try vendor.requestLines(0, 9999);
            defer iter.deinit();
            try testIter(iter, "c", "variable");
        }
        {
            win.insertChars("o");
            const iter = try vendor.requestLines(0, 9999);
            defer iter.deinit();
            try testIter(iter, "co", "variable");
        }
        {
            win.insertChars("n");
            const iter = try vendor.requestLines(0, 9999);
            defer iter.deinit();
            try testIter(iter, "con", "variable");
        }
        {
            win.insertChars("s");
            const iter = try vendor.requestLines(0, 9999);
            defer iter.deinit();
            try testIter(iter, "cons", "variable");
        }
        {
            win.insertChars("t");
            const iter = try vendor.requestLines(0, 9999);
            defer iter.deinit();
            try testIter(iter, "const", "type.qualifier");
        }
    }
};

test {
    std.testing.refAllDeclsRecursive(Window);
}
