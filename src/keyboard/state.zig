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

test "eventListToStr" {
    const allocator = std.testing.allocator;
    var arr = [_]c_int{ r.KEY_D, r.KEY_J };
    const result = try eventListToStr(std.testing.allocator, &arr);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("d j", result);
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

///////////////////////////// isMapped & isPrefix

const WIPMap = std.StringHashMap(bool);

fn createTriggerMapForTesting(allocator: std.mem.Allocator) !WIPMap {
    var map = std.StringHashMap(bool).init(allocator);
    try map.put("z", true);
    try map.put("d", true);
    try map.put("d j", true);
    try map.put("d j l", true);
    try map.put("d l", true);
    return map;
}

fn createPrefixMapForTesting(allocator: std.mem.Allocator) !WIPMap {
    var map = std.StringHashMap(bool).init(allocator);
    try map.put("d", true);
    try map.put("d j", true);
    return map;
}

fn getTriggerStatus(allocator: std.mem.Allocator, slice: EventSlice, map: *WIPMap) !struct { mapped: bool, trigger: []const u8 } {
    const trigger = try eventListToStr(allocator, slice);
    _ = map.get(trigger) orelse {
        defer allocator.free(trigger);
        return .{ .mapped = false, .trigger = "" };
    };
    return .{ .mapped = true, .trigger = trigger };
}

fn isPrefix(allocator: std.mem.Allocator, slice: EventSlice, map: *WIPMap) !bool {
    if (slice.len == 0) return false;
    const needle = try eventListToStr(allocator, slice);
    defer allocator.free(needle);
    _ = map.get(needle) orelse return false;
    return true;
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

///////////////////////////// ...

fn getInvokableTrigger(
    allocator: std.mem.Allocator,
    old_slice: EventSlice,
    new_slice: EventSlice,
    trigger_map: *WIPMap,
    prefix_map: *WIPMap,
) !?[]const u8 {
    ///////////////////////////// may invoke new

    const new = try getTriggerStatus(allocator, new_slice, trigger_map);
    const new_is_prefix = try isPrefix(allocator, new_slice, prefix_map);

    if (new.mapped and !new_is_prefix) {
        // if (alreadyInvoked(new, last_invoked_trigger)) return null;
        return new.trigger;
    }
    if (new.mapped and new_is_prefix) return null;

    ///////////////////////////// may invoke old

    const can_consider_invoke_key_up = canConsiderInvokeKeyUp(old_slice, new_slice);
    if (!can_consider_invoke_key_up) return null;

    const old = try getTriggerStatus(allocator, old_slice, trigger_map);
    const old_is_prefix = try isPrefix(allocator, old_slice, prefix_map);

    if (old.mapped and old_is_prefix) return old.trigger;

    return null;
}

test getInvokableTrigger {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var trigger_map = try createTriggerMapForTesting(allocator);
    defer trigger_map.deinit();
    var prefix_map = try createPrefixMapForTesting(allocator);
    defer prefix_map.deinit();

    ///////////////////////////// `z` mapped, not prefix, should trigger immediately on key down

    var nothingness = [_]c_int{};

    var z_down = [_]c_int{r.KEY_Z};
    const z_down_result = try getInvokableTrigger(allocator, &nothingness, &z_down, &trigger_map, &prefix_map);
    try std.testing.expectEqualStrings("z", z_down_result.?);

    ///////////////////////////// `d` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT

    var d_down = [_]c_int{r.KEY_D};
    const d_down_result = try getInvokableTrigger(allocator, &nothingness, &d_down, &trigger_map, &prefix_map);
    try std.testing.expectEqual(null, d_down_result);

    var d_still_down = [_]c_int{r.KEY_D};
    const d_still_down_result = try getInvokableTrigger(allocator, &d_down, &d_still_down, &trigger_map, &prefix_map);
    try std.testing.expectEqual(null, d_still_down_result);

    var d_up = [_]c_int{};
    const d_up_result = try getInvokableTrigger(allocator, &d_still_down, &d_up, &trigger_map, &prefix_map);
    try std.testing.expectEqualStrings("d", d_up_result.?);

    ///////////////////////////// `d l` mapped, not prefix, should trigger immediately on key down

    var d_l = [_]c_int{ r.KEY_D, r.KEY_L };
    const d_l_result = try getInvokableTrigger(allocator, &d_still_down, &d_l, &trigger_map, &prefix_map);
    try std.testing.expectEqualStrings("d l", d_l_result.?);

    ///////////////////////////// `d l k` not mapped, shouldn't trigger

    var d_l_k = [_]c_int{ r.KEY_D, r.KEY_L, r.KEY_K };
    const d_l_k_result = try getInvokableTrigger(allocator, &d_l, &d_l_k, &trigger_map, &prefix_map);
    try std.testing.expectEqual(null, d_l_k_result);
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
