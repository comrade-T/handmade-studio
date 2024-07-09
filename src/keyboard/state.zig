const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqDeep = std.testing.expectEqualDeep;
const Allocator = std.mem.Allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EventArray = [400]bool;
pub const EventList = std.ArrayList(c_int);
pub const EventTimeList = std.ArrayList(i64);

pub fn updateEventList(arr: *EventArray, e_list: *EventList, may_t_list: ?*EventTimeList) !void {
    for (e_list.items, 0..) |code, i| {
        if (r.IsKeyUp(code)) {
            _ = e_list.orderedRemove(i);
            arr[@intCast(code)] = false;
            if (may_t_list) |t_list| _ = t_list.orderedRemove(i);
        }
    }
    for (supported_key_codes) |code| {
        if (r.IsKeyDown(code)) {
            if (arr[@intCast(code)]) continue;
            try e_list.append(code);
            if (may_t_list) |t_list| try t_list.append(std.time.milliTimestamp());
            arr[@intCast(code)] = true;
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const TestTriggerMap = std.StringHashMap([]const u8);
pub const TestPrefixMap = std.StringHashMap(bool);

pub fn createTriggerMapForTesting(a: Allocator) !TestTriggerMap {
    var map = std.StringHashMap([]const u8).init(a);
    try map.put("z", "Zed");
    try map.put("d", "Dee");
    try map.put("d j", "DJ");
    try map.put("d j l", "DJ's Life");
    try map.put("d j k", "DJ Kick");
    try map.put("d l", "Download");

    try map.put("d k", "DecK");
    try map.put("d k l", "D & K & L");
    return map;
}

pub fn createPrefixMapForTesting(a: Allocator) !TestPrefixMap {
    var map = std.StringHashMap(bool).init(a);
    try map.put("d", true);
    try map.put("d j", true);
    try map.put("d k", true);
    return map;
}

////////////////////////////////////////////////////////////////////////////////////////////// GenericInvoker

pub fn GenericInvoker(comptime trigger_map_type: type, comptime prefix_map_type: type) type {
    return struct {
        a: Allocator,
        trigger_map: *trigger_map_type,
        prefix_map: *prefix_map_type,
        latest_trigger: EventList,

        const EventSlice = []const c_int;

        ///////////////////////////// eventListToStr

        fn eventListToStr(a: Allocator, e_slice: EventSlice) ![]const u8 {
            var str_list = std.ArrayList(u8).init(a);
            errdefer str_list.deinit();
            for (e_slice, 0..) |code, i| {
                const str = getStringRepresentationOfKeyCode(code);
                if (i > 0) try str_list.appendSlice(" ");
                try str_list.appendSlice(str);
            }
            return str_list.toOwnedSlice();
        }

        fn testEventListToStr(a: Allocator, want: []const u8, slice: EventSlice) !void {
            const result = try eventListToStr(std.testing.allocator, slice);
            defer a.free(result);
            try std.testing.expectEqualStrings(want, result);
        }

        test eventListToStr {
            const a = std.testing.allocator;
            try testEventListToStr(a, "d j", &[_]c_int{ r.KEY_D, r.KEY_J });
            try testEventListToStr(a, "", &[_]c_int{});
            try testEventListToStr(a, "z", &[_]c_int{r.KEY_Z});
        }

        ///////////////////////////// getTriggerStatus

        fn getTriggerStatus(a: Allocator, slice: EventSlice, map: *trigger_map_type) !struct { mapped: bool, trigger: []const u8 } {
            const trigger = try eventListToStr(a, slice);
            _ = map.get(trigger) orelse {
                defer a.free(trigger);
                return .{ .mapped = false, .trigger = "" };
            };
            return .{ .mapped = true, .trigger = trigger };
        }

        fn testGetTriggerStatus(a: Allocator, trigger_map: *trigger_map_type, mapped: bool, trigger: []const u8, slice: EventSlice) !void {
            const status = try getTriggerStatus(a, slice, trigger_map);
            defer a.free(status.trigger);
            try std.testing.expectEqual(mapped, status.mapped);
            try std.testing.expectEqualStrings(trigger, status.trigger);
        }

        test getTriggerStatus {
            const a = std.testing.allocator;
            var tm: TestTriggerMap = try createTriggerMapForTesting(a);
            defer tm.deinit();

            try testGetTriggerStatus(a, &tm, true, "d j", &[_]c_int{ r.KEY_D, r.KEY_J });
            try testGetTriggerStatus(a, &tm, false, "", &[_]c_int{});
            try testGetTriggerStatus(a, &tm, true, "z", &[_]c_int{r.KEY_Z});
        }

        ///////////////////////////// isPrefix

        fn isPrefix(a: Allocator, slice: EventSlice, map: *prefix_map_type) !bool {
            if (slice.len == 0) return false;
            const needle = try eventListToStr(a, slice);
            defer a.free(needle);
            _ = map.get(needle) orelse return false;
            return true;
        }

        test isPrefix {
            const a = std.testing.allocator;
            var prefix_map = try createPrefixMapForTesting(a);
            defer prefix_map.deinit();

            try std.testing.expect(try isPrefix(a, &[_]c_int{r.KEY_D}, &prefix_map));
            try std.testing.expect(!try isPrefix(a, &[_]c_int{r.KEY_Z}, &prefix_map));
            try std.testing.expect(!try isPrefix(a, &[_]c_int{ r.KEY_D, r.KEY_L }, &prefix_map));
        }

        ///////////////////////////// canConsiderInvokeKeyUp

        fn canConsiderInvokeKeyUp(old: EventSlice, new: EventSlice) bool {
            if (old.len < new.len) return false;
            for (0..new.len) |i| if (old[i] != new[i]) return false;
            return true;
        }

        test canConsiderInvokeKeyUp {
            try std.testing.expect(canConsiderInvokeKeyUp(&[_]c_int{ 1, 2, 3 }, &[_]c_int{ 1, 2 }));
            try std.testing.expect(!canConsiderInvokeKeyUp(&[_]c_int{ 1, 2, 3 }, &[_]c_int{ 1, 2, 3, 4 }));
            try std.testing.expect(canConsiderInvokeKeyUp(&[_]c_int{ 1, 2, 3 }, &[_]c_int{1}));
            try std.testing.expect(!canConsiderInvokeKeyUp(&[_]c_int{ 1, 2, 3 }, &[_]c_int{ 2, 3 }));
        }

        ///////////////////////////// init

        pub fn init(a: Allocator, trigger_map: *trigger_map_type, prefix_map: *prefix_map_type) !*@This() {
            const invoker = try a.create(@This());
            invoker.* = .{
                .a = a,
                .trigger_map = trigger_map,
                .prefix_map = prefix_map,
                .latest_trigger = std.ArrayList(c_int).init(a),
            };
            return invoker;
        }

        fn setLatestTrigger(self: *@This(), old: EventSlice) !void {
            try self.latest_trigger.replaceRange(0, self.latest_trigger.items.len, old);
        }

        pub fn getTrigger(self: *@This(), old: EventSlice, new: EventSlice) !?[]const u8 {
            if (std.mem.eql(c_int, old, new)) return null;

            ///////////////////////////// may invoke on key down

            const new_status = try getTriggerStatus(self.a, new, self.trigger_map);
            const new_is_prefix = try isPrefix(self.a, new, self.prefix_map);

            if (new_status.mapped and !new_is_prefix) {
                try self.setLatestTrigger(new);
                return new_status.trigger;
            }
            if (new_status.mapped and new_is_prefix) {
                if (new.len > old.len or new.len < self.latest_trigger.items.len) {
                    try self.setLatestTrigger(old);
                    return null;
                }
            }

            ///////////////////////////// may invoke on key up

            if (!canConsiderInvokeKeyUp(old, new)) return null;

            const old_status = try getTriggerStatus(self.a, old, self.trigger_map);
            const old_is_prefix = try isPrefix(self.a, old, self.prefix_map);

            if (old_status.mapped and old_is_prefix) {
                if (old.len < self.latest_trigger.items.len) {
                    try self.setLatestTrigger(old);
                    return null;
                }
                try self.setLatestTrigger(old);
                return old_status.trigger;
            }

            return null;
        }
    };
}

test GenericInvoker {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var trigger_map = try createTriggerMapForTesting(allocator);
    var prefix_map = try createPrefixMapForTesting(allocator);

    const TestInvoker = GenericInvoker(TestTriggerMap, TestPrefixMap);
    var iv = try TestInvoker.init(allocator, &trigger_map, &prefix_map);

    ///////////////////////////// Initialize invoker with nothingness

    var nothingness = [_]c_int{};
    try eq(null, try iv.getTrigger(&nothingness, &nothingness));
    try eqDeep(&nothingness, iv.latest_trigger.items);

    // `z` mapped, not prefix, should trigger immediately on key down
    var z = [_]c_int{r.KEY_Z};
    try eqStr("z", (try iv.getTrigger(&nothingness, &z)).?);
    try eqDeep(&z, iv.latest_trigger.items);

    // `z` mapped, not prefix, but already invoked, so shouldn't repeat here
    try eq(null, try iv.getTrigger(&z, &z));

    // `d` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT
    var d = [_]c_int{r.KEY_D};
    try eq(null, try iv.getTrigger(&nothingness, &d));
    try eqStr("d", (try iv.getTrigger(&d, &nothingness)).?);
    try eqDeep(&d, iv.latest_trigger.items);

    // `d l` mapped, not prefix, should trigger immediately on key down
    var d_l = [_]c_int{ r.KEY_D, r.KEY_L };
    try eqStr("d l", (try iv.getTrigger(&d, &d_l)).?);
    try eqDeep(&d_l, iv.latest_trigger.items);

    // `d l k` not mapped, shouldn't trigger
    var d_l_k = [_]c_int{ r.KEY_D, r.KEY_L, r.KEY_K };
    try eq(null, try iv.getTrigger(&d_l, &d_l_k));

    // `d l k` not mapped, not prefix, should do nothing here
    var d_k = [_]c_int{ r.KEY_D, r.KEY_K };
    try eq(null, try iv.getTrigger(&d_l_k, &d_k));

    // `d k` is mapped, is prefix, but shouldn't trigger here
    try eq(null, try iv.getTrigger(&d_k, &d));

    // `d` is mapped, is prefix, but shouldn't trigger here
    try eq(null, try iv.getTrigger(&d, &nothingness));

    //////////////////////////////////////////////////////////////////////////////////////////////

    try eq(null, try iv.getTrigger(&nothingness, &d));

    // `d j` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT
    var d_j = [_]c_int{ r.KEY_D, r.KEY_J };
    try eq(null, try iv.getTrigger(&d, &d_j));

    // `d j l` mapped, not prefix, should trigger immediately on key down
    var d_j_l = [_]c_int{ r.KEY_D, r.KEY_J, r.KEY_L };
    try eqStr("d j l", (try iv.getTrigger(&d_j, &d_j_l)).?);
    try eqDeep(&d_j_l, iv.latest_trigger.items);

    // `d j l` mapped, not prefix, should not trigger on key up
    try eq(null, try iv.getTrigger(&d_j_l, &d_j));

    // `d j` mapped, is prefix, should not trigger on key up here due to `d j l` aready been invoked
    try eq(null, try iv.getTrigger(&d_j, &d));

    // `d` mapped, is prefix, should not trigger on key up here due to `d j l` aready been invoked
    try eq(null, try iv.getTrigger(&d, &nothingness));
    try eqDeep(&d, iv.latest_trigger.items);

    //////////////////////////////////////////////////////////////////////////////////////////////

    try eq(null, try iv.getTrigger(&nothingness, &d));
    try eq(null, try iv.getTrigger(&d, &d_j));
    try eqStr("d j", (try iv.getTrigger(&d_j, &d)).?);
    try eq(null, try iv.getTrigger(&d, &d_k));
    try eqStr("d k", (try iv.getTrigger(&d_k, &d)).?);
    try eq(null, try iv.getTrigger(&d_k, &d));
    try eq(null, try iv.getTrigger(&d, &nothingness));

    //////////////////////////////////////////////////////////////////////////////////////////////

    var d_j_k = [_]c_int{ r.KEY_D, r.KEY_J, r.KEY_K };
    var d_k_l = [_]c_int{ r.KEY_D, r.KEY_K, r.KEY_L };
    try eq(null, try iv.getTrigger(&nothingness, &d));
    try eq(null, try iv.getTrigger(&d, &d_j));
    try eqStr("d j l", (try iv.getTrigger(&d_j, &d_j_l)).?);
    try eq(null, try iv.getTrigger(&d_j_l, &d_j_l));
    try eq(null, try iv.getTrigger(&d_j_l, &d_j));
    try eqStr("d j k", (try iv.getTrigger(&d_j, &d_j_k)).?);
    try eq(null, try iv.getTrigger(&d_j_k, &d_j_k));
    try eq(null, try iv.getTrigger(&d_j_k, &d_k));
    try eqStr("d k l", (try iv.getTrigger(&d_k, &d_k_l)).?);
    try eq(null, try iv.getTrigger(&d_k_l, &d_k));
    try eq(null, try iv.getTrigger(&d_k, &d));
    try eq(null, try iv.getTrigger(&d, &d_j));
    try eq(null, try iv.getTrigger(&d, &d_j));
    try eqStr("d j", (try iv.getTrigger(&d_j, &d)).?);
    try eq(null, try iv.getTrigger(&d_j, &d));
    try eq(null, try iv.getTrigger(&d, &nothingness));

    //////////////////////////////////////////////////////////////////////////////////////////////

    var j = [_]c_int{r.KEY_J};
    var j_l = [_]c_int{ r.KEY_J, r.KEY_L };
    try eq(null, try iv.getTrigger(&nothingness, &d));
    try eq(null, try iv.getTrigger(&d, &d_j));
    try eqStr("d j l", (try iv.getTrigger(&d_j, &d_j_l)).?);
    try eq(null, try iv.getTrigger(&d_j_l, &j_l));
    try eq(null, try iv.getTrigger(&j_l, &j));
    try eq(null, try iv.getTrigger(&j, &nothingness));

    ////////////////////////////////////////////////////////////////////////////////////////////// Prevent Repeating Test

    try eq(null, try iv.getTrigger(&nothingness, &nothingness));
    try eq(null, try iv.getTrigger(&nothingness, &d));
    try eq(null, try iv.getTrigger(&d, &d));
    try eq(null, try iv.getTrigger(&d, &d));
    try eq(null, try iv.getTrigger(&d, &d));
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

    r.KEY_TAB,
    r.KEY_SPACE,

    r.KEY_BACKSPACE,
    r.KEY_DELETE,

    r.KEY_DOWN,
    r.KEY_UP,
    r.KEY_LEFT,
    r.KEY_RIGHT,
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

        r.KEY_TAB => "tab",
        r.KEY_SPACE => "space",

        r.KEY_BACKSPACE => "backspace",
        r.KEY_DELETE => "delete",

        r.KEY_DOWN => "down",
        r.KEY_UP => "up",
        r.KEY_LEFT => "left",
        r.KEY_RIGHT => "right",

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
