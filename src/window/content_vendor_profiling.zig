const std = @import("std");
const ztracy = @import("ztracy");

const _neo_buffer = @import("neo_buffer");
const Buffer = _neo_buffer.Buffer;
const ContentVendor = @import("content_vendor").ContentVendor;

pub fn main() !void {
    // const tracy_zone = ztracy.ZoneN(@src(), "main_zone");
    // defer tracy_zone.End();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = @embedFile("./content_vendor.zig");

    const buf_create_zone = ztracy.ZoneN(@src(), "buf_create_zone");
    var buf = try Buffer.create(allocator, .string, content);
    buf_create_zone.End();
    defer buf.destroy();

    const buf_init_ts_zone = ztracy.ZoneN(@src(), "buf_init_ts_zone");
    try buf.initiateTreeSitter(.zig);
    buf_init_ts_zone.End();

    const vendor = try ContentVendor.init(allocator, buf);
    defer vendor.deinit();

    for (0..1) |_| {
        const for_loop_zone = ztracy.ZoneNC(@src(), "for_loop_zone", 0x00_ff_00_00);
        defer for_loop_zone.End();

        const request_lines_zone = ztracy.ZoneNC(@src(), "request_lines_zone", 0x00_00_00_ff);
        const start_line = 0;
        const end_line = 9999;
        const iter = try vendor.requestLines(start_line, end_line);
        request_lines_zone.End();
        defer iter.deinit();

        var buf_: [10]u8 = undefined;
        while (true) {
            const iter_zone = ztracy.ZoneN(@src(), "iter.nextChar()");
            defer iter_zone.End();
            const result = iter.nextChar(&buf_);
            if (result == null) break;
        }
    }
}
