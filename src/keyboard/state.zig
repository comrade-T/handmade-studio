const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const game = @import("../game.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EventArray = [400]bool;
pub const EventList = std.ArrayList(c_int);
pub const EventSlice = []c_int;

pub fn updateEventList(arr: *EventArray, list: *EventList) !void {
    for (list.items, 0..) |code, i| {
        if (r.IsKeyUp(code)) {
            _ = list.orderedRemove(i);
            arr[@intCast(code)] = false;
        }
    }
    for (supported_key_codes) |code| {
        if (r.IsKeyDown(code)) {
            if (arr[@intCast(code)]) continue;
            try list.append(code);
            arr[@intCast(code)] = true;
        }
    }
}

fn eventListToStr(allocator: std.mem.Allocator, e_list: EventSlice) ![]const u8 {
    var str_list = std.ArrayList(u8).init(allocator);
    errdefer str_list.deinit();
    for (e_list, 0..) |code, i| {
        const str = getStringRepresentationOfKeyCode(code);
        if (i > 0) try str_list.appendSlice(" ");
        try str_list.appendSlice(str);
    }
    return str_list.toOwnedSlice();
}

test eventListToStr {
    const allocator = std.testing.allocator;

    var arr = [_]c_int{ r.KEY_D, r.KEY_J };
    const result = try eventListToStr(std.testing.allocator, &arr);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("d j", result);

    var arr2 = [_]c_int{};
    const result2 = try eventListToStr(std.testing.allocator, &arr2);
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("", result2);

    var arr3 = [_]c_int{r.KEY_Z};
    const result3 = try eventListToStr(std.testing.allocator, &arr3);
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("z", result3);
}

pub fn printEventList(allocator: std.mem.Allocator, list: *EventList) !void {
    const str = try eventListToStr(allocator, list.items);
    defer allocator.free(str);
    std.debug.print("{s}\n", .{str});
}

//////////////////////////////////////////////////////////////////////////////////////////////

///////////////////////////// canConsiderInvokeKeyUp

fn canConsiderInvokeKeyUp(old: EventSlice, new: EventSlice) bool {
    if (old.len < new.len) return false;
    for (0..new.len) |i| if (old[i] != new[i]) return false;
    return true;
}

test canConsiderInvokeKeyUp {
    var old1 = [_]c_int{ 1, 2, 3 };
    var new1 = [_]c_int{ 1, 2 };
    try std.testing.expect(canConsiderInvokeKeyUp(&old1, &new1));

    var old2 = [_]c_int{ 1, 2, 3 };
    var new2 = [_]c_int{ 1, 2, 3, 4 };
    try std.testing.expect(!canConsiderInvokeKeyUp(&old2, &new2));

    var old3 = [_]c_int{ 1, 2, 3 };
    var new3 = [_]c_int{1};
    try std.testing.expect(canConsiderInvokeKeyUp(&old3, &new3));

    var old4 = [_]c_int{ 1, 2, 3 };
    var new4 = [_]c_int{ 2, 3 };
    try std.testing.expect(!canConsiderInvokeKeyUp(&old4, &new4));
}

///////////////////////////// HashMaps for testing

const WIPMap = std.StringHashMap(bool);

fn createTriggerMapForTesting(allocator: std.mem.Allocator) !WIPMap {
    var map = std.StringHashMap(bool).init(allocator);
    try map.put("z", true);
    try map.put("d", true);
    try map.put("d j", true);
    try map.put("d j l", true);
    try map.put("d l", true);

    try map.put("d k", true);
    try map.put("d k l", true);
    return map;
}

fn createPrefixMapForTesting(allocator: std.mem.Allocator) !WIPMap {
    var map = std.StringHashMap(bool).init(allocator);
    try map.put("d", true);
    try map.put("d j", true);
    try map.put("d k", true);
    return map;
}

///////////////////////////// getTriggerStatus

fn getTriggerStatus(allocator: std.mem.Allocator, slice: EventSlice, map: *WIPMap) !struct { mapped: bool, trigger: []const u8 } {
    const trigger = try eventListToStr(allocator, slice);
    _ = map.get(trigger) orelse {
        defer allocator.free(trigger);
        return .{ .mapped = false, .trigger = "" };
    };
    return .{ .mapped = true, .trigger = trigger };
}

test getTriggerStatus {
    const allocator = std.testing.allocator;
    var trigger_map = try createTriggerMapForTesting(allocator);
    defer trigger_map.deinit();

    var trigger1 = [_]c_int{ r.KEY_D, r.KEY_J };
    const trigger1_status = try getTriggerStatus(allocator, &trigger1, &trigger_map);
    defer allocator.free(trigger1_status.trigger);
    try std.testing.expect(trigger1_status.mapped);

    var trigger2 = [_]c_int{ r.KEY_D, r.KEY_Z };
    const trigger2_status = try getTriggerStatus(allocator, &trigger2, &trigger_map);
    defer allocator.free(trigger2_status.trigger);
    try std.testing.expect(!trigger2_status.mapped);

    var trigger3 = [_]c_int{r.KEY_Z};
    const trigger3_status = try getTriggerStatus(allocator, &trigger3, &trigger_map);
    defer allocator.free(trigger3_status.trigger);
    try std.testing.expect(trigger3_status.mapped);
}

///////////////////////////// isPrefix

fn isPrefix(allocator: std.mem.Allocator, slice: EventSlice, map: *WIPMap) !bool {
    if (slice.len == 0) return false;
    const needle = try eventListToStr(allocator, slice);
    defer allocator.free(needle);
    _ = map.get(needle) orelse return false;
    return true;
}

test isPrefix {
    const allocator = std.testing.allocator;
    var prefix_map = try createPrefixMapForTesting(allocator);
    defer prefix_map.deinit();

    var prefix1 = [_]c_int{r.KEY_D};
    try std.testing.expect(try isPrefix(allocator, &prefix1, &prefix_map));

    var prefix2 = [_]c_int{r.KEY_Z};
    try std.testing.expect(!try isPrefix(allocator, &prefix2, &prefix_map));

    var prefix3 = [_]c_int{ r.KEY_D, r.KEY_L };
    try std.testing.expect(!try isPrefix(allocator, &prefix3, &prefix_map));
}

///////////////////////////// Invoker

const Invoker = struct {
    allocator: std.mem.Allocator,
    trigger_map: *WIPMap,
    prefix_map: *WIPMap,
    latest_trigger: EventList,

    fn init(allocator: std.mem.Allocator, trigger_map: *WIPMap, prefix_map: *WIPMap) !*Invoker {
        const invoker = try allocator.create(Invoker);
        invoker.* = .{
            .allocator = allocator,
            .trigger_map = trigger_map,
            .prefix_map = prefix_map,
            .latest_trigger = std.ArrayList(c_int).init(allocator),
        };
        return invoker;
    }

    fn setLastTrigger(self: *Invoker, old: EventSlice) !void {
        try self.latest_trigger.replaceRange(0, self.latest_trigger.items.len, old);
    }

    fn getTrigger(self: *Invoker, old: EventSlice, new: EventSlice) !?[]const u8 {
        ///////////////////////////// may invoke on key down

        const new_status = try getTriggerStatus(self.allocator, new, self.trigger_map);
        const new_is_prefix = try isPrefix(self.allocator, new, self.prefix_map);

        if (new_status.mapped and !new_is_prefix) {
            if (std.mem.eql(c_int, new, self.latest_trigger.items)) return null;
            try self.setLastTrigger(new);
            return new_status.trigger;
        }
        if (new_status.mapped and new_is_prefix) {
            if (new.len > old.len or new.len < self.latest_trigger.items.len) {
                try self.setLastTrigger(old);
                return null;
            }
        }

        ///////////////////////////// may invoke on key up

        if (!canConsiderInvokeKeyUp(old, new)) return null;

        const old_status = try getTriggerStatus(self.allocator, old, self.trigger_map);
        const old_is_prefix = try isPrefix(self.allocator, old, self.prefix_map);

        if (old_status.mapped and old_is_prefix) {
            if (old.len < self.latest_trigger.items.len) {
                try self.setLastTrigger(old);
                return null;
            }
            try self.setLastTrigger(old);
            return old_status.trigger;
        }

        return null;
    }
};

test Invoker {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var trigger_map = try createTriggerMapForTesting(allocator);
    var prefix_map = try createPrefixMapForTesting(allocator);

    ///////////////////////////// Initialize invoker with nothingness

    var nothingness = [_]c_int{};
    var invoker = try Invoker.init(allocator, &trigger_map, &prefix_map);
    try std.testing.expectEqual(null, try invoker.getTrigger(&nothingness, &nothingness));
    try std.testing.expectEqualDeep(&nothingness, invoker.latest_trigger.items);

    // `z` mapped, not prefix, should trigger immediately on key down
    var z = [_]c_int{r.KEY_Z};
    try std.testing.expectEqualStrings("z", (try invoker.getTrigger(&nothingness, &z)).?);
    try std.testing.expectEqualDeep(&z, invoker.latest_trigger.items);

    // `z` mapped, not prefix, but already invoked, so shouldn't repeat here
    try std.testing.expectEqual(null, try invoker.getTrigger(&z, &z));

    // `d` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT
    var d = [_]c_int{r.KEY_D};
    try std.testing.expectEqual(null, try invoker.getTrigger(&nothingness, &d));
    try std.testing.expectEqualStrings("d", (try invoker.getTrigger(&d, &nothingness)).?);
    try std.testing.expectEqualDeep(&d, invoker.latest_trigger.items);

    // `d l` mapped, not prefix, should trigger immediately on key down
    var d_l = [_]c_int{ r.KEY_D, r.KEY_L };
    try std.testing.expectEqualStrings("d l", (try invoker.getTrigger(&d, &d_l)).?);
    try std.testing.expectEqualDeep(&d_l, invoker.latest_trigger.items);

    // `d l k` not mapped, shouldn't trigger
    var d_l_k = [_]c_int{ r.KEY_D, r.KEY_L, r.KEY_K };
    try std.testing.expectEqual(null, try invoker.getTrigger(&d_l, &d_l_k));

    // `d l k` not mapped, not prefix, should do nothing here
    var d_k = [_]c_int{ r.KEY_D, r.KEY_K };
    try std.testing.expectEqual(null, try invoker.getTrigger(&d_l_k, &d_k));

    // `d k` is mapped, is prefix, but shouldn't trigger here
    try std.testing.expectEqual(null, try invoker.getTrigger(&d_k, &d));

    // `d` is mapped, is prefix, but shouldn't trigger here
    try std.testing.expectEqual(null, try invoker.getTrigger(&d, &nothingness));

    //////////////////////////////////////////////////////////////////////////////////////////////

    try std.testing.expectEqual(null, try invoker.getTrigger(&nothingness, &d));

    // `d j` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT
    var d_j = [_]c_int{ r.KEY_D, r.KEY_J };
    try std.testing.expectEqual(null, try invoker.getTrigger(&d, &d_j));

    // `d j l` mapped, not prefix, should trigger immediately on key down
    var d_j_l = [_]c_int{ r.KEY_D, r.KEY_J, r.KEY_L };
    try std.testing.expectEqualStrings("d j l", (try invoker.getTrigger(&d_j, &d_j_l)).?);
    try std.testing.expectEqualDeep(&d_j_l, invoker.latest_trigger.items);

    // `d j l` mapped, not prefix, should not trigger on key up
    try std.testing.expectEqual(null, try invoker.getTrigger(&d_j_l, &d_j));

    // `d j` mapped, is prefix, should not trigger on key up here due to `d j l` aready been invoked
    try std.testing.expectEqual(null, try invoker.getTrigger(&d_j, &d));

    // `dj` mapped, is prefix, should not trigger on key up here due to `d j l` aready been invoked
    try std.testing.expectEqual(null, try invoker.getTrigger(&d, &nothingness));
    try std.testing.expectEqualDeep(&d, invoker.latest_trigger.items);

    //////////////////////////////////////////////////////////////////////////////////////////////

    try std.testing.expectEqual(null, try invoker.getTrigger(&nothingness, &d));
    try std.testing.expectEqual(null, try invoker.getTrigger(&d, &d_j));
    try std.testing.expectEqualStrings("d j", (try invoker.getTrigger(&d_j, &d)).?);
    try std.testing.expectEqual(null, try invoker.getTrigger(&d, &d_k));
    try std.testing.expectEqualStrings("d k", (try invoker.getTrigger(&d_k, &d)).?);
    try std.testing.expectEqual(null, try invoker.getTrigger(&d_k, &d));
    try std.testing.expectEqual(null, try invoker.getTrigger(&d, &nothingness));
}

//////////////////////////////////////////////////////////////////////////////////////////////

const supported_key_codes = [_]c_int{
    r.KEY_A,
    r.KEY_B,
    r.KEY_C,
    r.KEY_D,
    r.KEY_E,
    r.KEY_F,
    r.KEY_G,
    r.KEY_H,
    r.KEY_I,
    r.KEY_J,
    r.KEY_K,
    r.KEY_L,
    r.KEY_M,
    r.KEY_N,
    r.KEY_O,
    r.KEY_P,
    r.KEY_Q,
    r.KEY_R,
    r.KEY_S,
    r.KEY_T,
    r.KEY_U,
    r.KEY_V,
    r.KEY_W,
    r.KEY_X,
    r.KEY_Y,
    r.KEY_Z,

    r.KEY_ONE,
    r.KEY_TWO,
    r.KEY_THREE,
    r.KEY_FOUR,
    r.KEY_FIVE,
    r.KEY_SIX,
    r.KEY_SEVEN,
    r.KEY_EIGHT,
    r.KEY_NINE,
    r.KEY_ZERO,

    r.KEY_F1,
    r.KEY_F2,
    r.KEY_F3,
    r.KEY_F4,
    r.KEY_F5,
    r.KEY_F6,
    r.KEY_F7,
    r.KEY_F8,
    r.KEY_F9,
    r.KEY_F10,
    r.KEY_F11,
    r.KEY_F12,

    r.KEY_ENTER,
    r.KEY_SPACE,
    // ...
};

fn getStringRepresentationOfKeyCode(c: c_int) []const u8 {
    return switch (c) {
        r.KEY_A => "a",
        r.KEY_B => "b",
        r.KEY_C => "c",
        r.KEY_D => "d",
        r.KEY_E => "e",
        r.KEY_F => "f",
        r.KEY_G => "g",
        r.KEY_H => "h",
        r.KEY_I => "i",
        r.KEY_J => "j",
        r.KEY_K => "k",
        r.KEY_L => "l",
        r.KEY_M => "m",
        r.KEY_N => "n",
        r.KEY_O => "o",
        r.KEY_P => "p",
        r.KEY_Q => "q",
        r.KEY_R => "r",
        r.KEY_S => "s",
        r.KEY_T => "t",
        r.KEY_U => "u",
        r.KEY_V => "v",
        r.KEY_W => "w",
        r.KEY_X => "x",
        r.KEY_Y => "y",
        r.KEY_Z => "z",

        r.KEY_ONE => "1",
        r.KEY_TWO => "2",
        r.KEY_THREE => "3",
        r.KEY_FOUR => "4",
        r.KEY_FIVE => "5",
        r.KEY_SIX => "6",
        r.KEY_SEVEN => "7",
        r.KEY_EIGHT => "8",
        r.KEY_NINE => "9",
        r.KEY_ZERO => "0",

        r.KEY_F1 => "<F1>",
        r.KEY_F2 => "<F2>",
        r.KEY_F3 => "<F3>",
        r.KEY_F4 => "<F4>",
        r.KEY_F5 => "<F5>",
        r.KEY_F6 => "<F6>",
        r.KEY_F7 => "<F7>",
        r.KEY_F8 => "<F8>",
        r.KEY_F9 => "<F9>",
        r.KEY_F10 => "<F10>",
        r.KEY_F11 => "<F11>",
        r.KEY_F12 => "<F12>",

        else => "",
    };
}
