const std = @import("std");
const rl = @import("raylib");

const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqDeep = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const Key = rl.KeyboardKey;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EventArray = [400]bool;
pub const EventList = std.ArrayList(rl.KeyboardKey);
pub const EventSlice = []const rl.KeyboardKey;
pub const EventTimeList = std.ArrayList(i64);
pub const EventTimeSlice = []i64;

pub fn updateEventList(arr: *EventArray, e_list: *EventList, may_t_list: ?*EventTimeList) !void {
    for (e_list.items, 0..) |key, i| {
        if (rl.isKeyUp(key)) {
            _ = e_list.orderedRemove(i);
            arr.*[@intCast(@intFromEnum(key))] = false;
            if (may_t_list) |t_list| _ = t_list.orderedRemove(i);
        }
    }

    for (supported_keys) |key| {
        const code = @intFromEnum(key);
        if (rl.isKeyDown(key)) {
            if (arr[@intCast(code)]) continue;
            try e_list.append(key);
            if (may_t_list) |t_list| try t_list.append(std.time.milliTimestamp());
            arr[@intCast(code)] = true;
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const InputStepList = std.ArrayList(InputStep);
const InputStep = struct {
    old: EventSlice,
    new: EventSlice,
    time: EventTimeSlice,
};

fn getInputSteps(
    a: Allocator,
    real_old: EventSlice,
    real_new: EventSlice,
    real_time: EventTimeSlice,
) !InputStepList {
    var list = std.ArrayList(InputStep).init(a);
    errdefer list.deinit();

    const should_return_as_is =
        real_old.len == real_new.len or
        real_old.len > real_new.len and real_old.len - real_new.len <= 1 or
        real_new.len > real_old.len and real_new.len - real_old.len <= 1;

    if (should_return_as_is) {
        try list.append(InputStep{ .old = real_old, .new = real_new, .time = real_time });
        return list;
    }

    if (real_old.len < real_new.len) {
        const diff = real_new.len - real_old.len;
        var old = real_new[0 .. real_new.len - 1];
        var new = real_new[0..real_new.len];
        var time = real_time[0..real_time.len];
        try list.resize(real_new.len);
        for (0..diff) |_| {
            list.items[new.len - 1] = InputStep{ .old = old, .new = new, .time = time };
            old = old[0..old.len -| 1];
            new = new[0..new.len -| 1];
            time = time[0..time.len -| 1];
        }
    }

    return list;
}

test getInputSteps {
    const a = std.testing.allocator;

    ///////////////////////////// Split things

    {
        var real_old = [_]Key{};
        var real_new = [_]Key{ Key.key_d, Key.key_l };
        var real_time = [_]i64{ 0, 1 };
        const steps = try getInputSteps(a, &real_old, &real_new, &real_time);
        defer steps.deinit();
        try eq(2, steps.items.len);

        var nothingness = [_]Key{};
        var d = [_]Key{Key.key_d};
        var time_1 = [_]i64{0};
        try eqStep(steps.items[0], &nothingness, &d, &time_1);

        var d_l = [_]Key{ Key.key_d, Key.key_l };
        var time_2 = [_]i64{ 0, 1 };
        try eqStep(steps.items[1], &d, &d_l, &time_2);
    }

    ///////////////////////////// Keep things as is

    {
        var real_old = [_]Key{};
        var real_new = [_]Key{};
        var real_time = [_]i64{};
        const steps = try getInputSteps(a, &real_old, &real_new, &real_time);
        defer steps.deinit();
        try eq(1, steps.items.len);
        try eqStep(steps.items[0], &real_old, &real_new, &real_time);
    }
    {
        var real_old = [_]Key{};
        var real_new = [_]Key{Key.key_d};
        var real_time = [_]i64{0};
        const steps = try getInputSteps(a, &real_old, &real_new, &real_time);
        defer steps.deinit();
        try eq(1, steps.items.len);
        try eqStep(steps.items[0], &real_old, &real_new, &real_time);
    }
    {
        var real_old = [_]Key{Key.key_d};
        var real_new = [_]Key{};
        var real_time = [_]i64{0};
        const steps = try getInputSteps(a, &real_old, &real_new, &real_time);
        defer steps.deinit();
        try eq(1, steps.items.len);
        try eqStep(steps.items[0], &real_old, &real_new, &real_time);
    }
    {
        var real_old = [_]Key{Key.key_d};
        var real_new = [_]Key{Key.key_d};
        var real_time = [_]i64{20};
        const steps = try getInputSteps(a, &real_old, &real_new, &real_time);
        defer steps.deinit();
        try eq(1, steps.items.len);
        try eqStep(steps.items[0], &real_old, &real_new, &real_time);
    }
}

fn eqStep(step: InputStep, real_old: EventSlice, real_new: EventSlice, real_time: EventTimeSlice) !void {
    try expect(eql(Key, step.old, real_old));
    try expect(eql(Key, step.new, real_new));
    try expect(eql(i64, step.time, real_time));
}

pub const KeyboardEventsManager = struct {
    a: Allocator,

    old_arr: EventArray = [_]bool{false} ** 400,
    new_arr: EventArray = [_]bool{false} ** 400,

    old_list: EventList,
    new_list: EventList,

    time_list: EventTimeList,

    pub fn init(a: Allocator) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .old_list = EventList.init(a),
            .new_list = EventList.init(a),
            .time_list = EventTimeList.init(a),
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.old_list.deinit();
        self.new_list.deinit();
        self.time_list.deinit();
        self.a.destroy(self);
    }

    pub fn startHandlingInputs(self: *@This()) !void {
        try updateEventList(&self.new_arr, &self.new_list, &self.time_list);
    }

    pub fn finishHandlingInputs(self: *@This()) !void {
        try updateEventList(&self.old_arr, &self.old_list, null);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

pub const TestTriggerMap = std.StringHashMap([]const u8);
pub const TestPrefixMap = std.StringHashMap(bool);

pub fn createTriggerMapForTesting(a: Allocator) !TestTriggerMap {
    var map = TestTriggerMap.init(a);

    try map.put("z", "Zed");

    try map.put("1", "1");
    try map.put("lshift 1", "!");

    try map.put("d", "Dee");
    try map.put("d j", "DJ");
    try map.put("d j l", "DJ's Life");
    try map.put("d j k", "DJ Kick");
    try map.put("d l", "Download");

    try map.put("d k", "DecK");
    try map.put("d k l", "D & K & L");

    try map.put("i", "i");

    try map.put("s", "s");
    try map.put("s o", "so so");

    return map;
}

pub fn createPrefixMapForTesting(a: Allocator) !TestPrefixMap {
    var map = TestPrefixMap.init(a);
    try map.put("d", true);
    try map.put("d j", true);
    try map.put("d k", true);
    try map.put("s", true);
    try map.put("lshift", true);
    return map;
}

////////////////////////////////////////////////////////////////////////////////////////////// Shared Functions

fn eventListToStr(a: Allocator, e_slice: EventSlice) ![]const u8 {
    var str_list = std.ArrayList(u8).init(a);
    errdefer str_list.deinit();
    for (e_slice, 0..) |code, i| {
        const str = getStringRepresentationOfKey(code);
        if (i > 0) try str_list.appendSlice(" ");
        try str_list.appendSlice(str);
    }
    return str_list.toOwnedSlice();
}

fn testEventListToStr(a: Allocator, want: []const u8, slice: EventSlice) !void {
    const result = try eventListToStr(std.testing.allocator, slice);
    defer a.free(result);
    try eqStr(want, result);
}

test eventListToStr {
    const a = std.testing.allocator;
    try testEventListToStr(a, "d j", &[_]Key{ Key.key_d, Key.key_j });
    try testEventListToStr(a, "", &[_]Key{});
    try testEventListToStr(a, "z", &[_]Key{Key.key_z});
}

////////////////////////////////////////////////////////////////////////////////////////////// GenericTriggerComposer

const Candidate = struct {
    trigger: []const u8,
    up: bool = false,
    last: bool = false,
};

pub fn GenericTriggerCandidateComposer(comptime trigger_map_type: type, comptime prefix_map_type: type) type {
    return struct {
        a: Allocator,
        trigger_map: *trigger_map_type,
        prefix_map: *prefix_map_type,
        latest_trigger: EventList,

        ///////////////////////////// getTriggerStatus

        fn getTriggerStatus(a: Allocator, slice: EventSlice, map: *trigger_map_type) !struct { mapped: bool, trigger: []const u8 } {
            const trigger = try eventListToStr(a, slice);
            errdefer a.free(trigger);
            _ = map.get(trigger) orelse {
                a.free(trigger);
                return .{ .mapped = false, .trigger = "" };
            };
            return .{ .mapped = true, .trigger = trigger };
        }

        fn testGetTriggerStatus(a: Allocator, trigger_map: *trigger_map_type, mapped: bool, trigger: []const u8, slice: EventSlice) !void {
            const status = try getTriggerStatus(a, slice, trigger_map);
            defer a.free(status.trigger);
            try eq(mapped, status.mapped);
            try eqStr(trigger, status.trigger);
        }

        test getTriggerStatus {
            const a = std.testing.allocator;
            var tm: TestTriggerMap = try createTriggerMapForTesting(a);
            defer tm.deinit();

            try testGetTriggerStatus(a, &tm, true, "d j", &[_]Key{ Key.key_d, Key.key_j });
            try testGetTriggerStatus(a, &tm, false, "", &[_]Key{});
            try testGetTriggerStatus(a, &tm, true, "z", &[_]Key{Key.key_z});
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

            try expect(try isPrefix(a, &[_]Key{Key.key_d}, &prefix_map));
            try expect(!try isPrefix(a, &[_]Key{Key.key_z}, &prefix_map));
            try expect(!try isPrefix(a, &[_]Key{ Key.key_d, Key.key_z }, &prefix_map));
        }

        ///////////////////////////// canConsiderInvokeKeyUp

        fn canConsiderInvokeKeyUp(old: EventSlice, new: EventSlice) bool {
            if (old.len < new.len) return false;
            for (0..new.len) |i| if (old[i] != new[i]) return false;
            return true;
        }

        test canConsiderInvokeKeyUp {
            try expect(canConsiderInvokeKeyUp(&[_]Key{ Key.key_a, Key.key_b, Key.key_c }, &[_]Key{ Key.key_a, Key.key_b }));
            try expect(!canConsiderInvokeKeyUp(&[_]Key{ Key.key_a, Key.key_b, Key.key_c }, &[_]Key{ Key.key_a, Key.key_b, Key.key_c, Key.key_d }));
            try expect(canConsiderInvokeKeyUp(&[_]Key{ Key.key_a, Key.key_b, Key.key_c }, &[_]Key{Key.key_a}));
            try expect(!canConsiderInvokeKeyUp(&[_]Key{ Key.key_a, Key.key_b, Key.key_c }, &[_]Key{ Key.key_b, Key.key_c }));
        }

        ///////////////////////////// init

        pub fn init(a: Allocator, trigger_map: *trigger_map_type, prefix_map: *prefix_map_type) !*@This() {
            const composer = try a.create(@This());
            composer.* = .{
                .a = a,
                .trigger_map = trigger_map,
                .prefix_map = prefix_map,
                .latest_trigger = std.ArrayList(Key).init(a),
            };
            return composer;
        }

        pub fn deinit(self: *@This()) void {
            self.latest_trigger.deinit();
            self.a.destroy(self);
        }

        fn setLatestTrigger(self: *@This(), old: EventSlice) !void {
            try self.latest_trigger.replaceRange(0, self.latest_trigger.items.len, old);
        }

        pub fn getTriggerCandidate(self: *@This(), old: EventSlice, new: EventSlice) !?Candidate {
            if (std.mem.eql(Key, old, new)) return null;

            ///////////////////////////// may invoke on key down

            const new_status = try getTriggerStatus(self.a, new, self.trigger_map);
            const new_is_prefix = try isPrefix(self.a, new, self.prefix_map);

            if (new_status.mapped and !new_is_prefix and new.len >= old.len) {
                try self.setLatestTrigger(new);
                return .{ .trigger = new_status.trigger };
            }
            if (new_status.mapped and new_is_prefix) {
                if (new.len > old.len or new.len < self.latest_trigger.items.len) {
                    try self.setLatestTrigger(old);
                    self.a.free(new_status.trigger);
                    return null;
                }
            }

            ///////////////////////////// may invoke on key up

            self.a.free(new_status.trigger);

            if (!canConsiderInvokeKeyUp(old, new)) return null;

            const old_status = try getTriggerStatus(self.a, old, self.trigger_map);
            const old_is_prefix = try isPrefix(self.a, old, self.prefix_map);

            if (old_status.mapped and old_is_prefix) {
                if (old.len < self.latest_trigger.items.len) {
                    try self.setLatestTrigger(old);
                    self.a.free(old_status.trigger);
                    return null;
                }
                try self.setLatestTrigger(old);
                return .{ .trigger = old_status.trigger, .up = true };
            }

            self.a.free(old_status.trigger);
            return null;
        }
    };
}

test GenericTriggerCandidateComposer {
    const allocator = std.testing.allocator;

    var trigger_map = try createTriggerMapForTesting(allocator);
    defer trigger_map.deinit();
    var prefix_map = try createPrefixMapForTesting(allocator);
    defer prefix_map.deinit();

    const TestComposer = GenericTriggerCandidateComposer(TestTriggerMap, TestPrefixMap);
    var composer = try TestComposer.init(allocator, &trigger_map, &prefix_map);
    defer composer.deinit();

    ///////////////////////////// Start the session with nothingness

    var nothingness = [_]Key{};
    try eq(null, try composer.getTriggerCandidate(&nothingness, &nothingness));
    try eqDeep(&nothingness, composer.latest_trigger.items);

    // `z` mapped, not prefix, should trigger immediately on key down
    var z = [_]Key{Key.key_z};
    {
        const result = (try composer.getTriggerCandidate(&nothingness, &z)).?;
        defer allocator.free(result.trigger);
        try eqDeep("z", result.trigger);
        try eqDeep(&z, composer.latest_trigger.items);
    }

    // `z` mapped, not prefix, but already invoked, so shouldn't repeat here
    try eq(null, try composer.getTriggerCandidate(&z, &z));

    // `d` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT
    var d = [_]Key{Key.key_d};
    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));
    {
        const result = (try composer.getTriggerCandidate(&d, &nothingness)).?;
        defer allocator.free(result.trigger);
        try eqStr("d", result.trigger);
    }
    try eqDeep(&d, composer.latest_trigger.items);

    // `d l` mapped, not prefix, should trigger immediately on key down
    var d_l = [_]Key{ Key.key_d, Key.key_l };
    {
        const result = (try composer.getTriggerCandidate(&d, &d_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d l", result.trigger);
    }
    try eqDeep(&d_l, composer.latest_trigger.items);

    // `d l k` not mapped, shouldn't trigger
    var d_l_k = [_]Key{ Key.key_d, Key.key_l, Key.key_r };
    try eq(null, try composer.getTriggerCandidate(&d_l, &d_l_k));

    // `d l k` not mapped, not prefix, should do nothing here
    var d_k = [_]Key{ Key.key_d, Key.key_k };
    try eq(null, try composer.getTriggerCandidate(&d_l_k, &d_k));

    // `d k` is mapped, is prefix, but shouldn't trigger here
    try eq(null, try composer.getTriggerCandidate(&d_k, &d));

    // `d` is mapped, is prefix, but shouldn't trigger here
    try eq(null, try composer.getTriggerCandidate(&d, &nothingness));

    /////////////////////////////

    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));

    // `d j` mapped, is prefix, should trigger on key up, IF NOTHING ELSE TRIGGERS ON TOP OF IT
    var d_j = [_]Key{ Key.key_d, Key.key_j };
    try eq(null, try composer.getTriggerCandidate(&d, &d_j));

    // `d j l` mapped, not prefix, should trigger immediately on key down
    var d_j_l = [_]Key{ Key.key_d, Key.key_j, Key.key_l };
    {
        const result = (try composer.getTriggerCandidate(&d_j, &d_j_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d j l", result.trigger);
    }
    try eqDeep(&d_j_l, composer.latest_trigger.items);

    // `d j l` mapped, not prefix, should not trigger on key up
    try eq(null, try composer.getTriggerCandidate(&d_j_l, &d_j));

    // `d j` mapped, is prefix, should not trigger on key up here due to `d j l` aready been invoked
    try eq(null, try composer.getTriggerCandidate(&d_j, &d));

    // `d` mapped, is prefix, should not trigger on key up here due to `d j l` aready been invoked
    try eq(null, try composer.getTriggerCandidate(&d, &nothingness));
    try eqDeep(&d, composer.latest_trigger.items);

    /////////////////////////////

    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d_j));
    {
        const result = (try composer.getTriggerCandidate(&d_j, &d)).?;
        defer allocator.free(result.trigger);
        try eqStr("d j", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d, &d_k));
    {
        const result = (try composer.getTriggerCandidate(&d_k, &d)).?;
        defer allocator.free(result.trigger);
        try eqStr("d k", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_k, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &nothingness));

    /////////////////////////////

    var d_j_k = [_]Key{ Key.key_d, Key.key_j, Key.key_k };
    var d_k_l = [_]Key{ Key.key_d, Key.key_k, Key.key_l };
    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d_j));
    {
        const result = (try composer.getTriggerCandidate(&d_j, &d_j_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d j l", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_j_l, &d_j_l));
    try eq(null, try composer.getTriggerCandidate(&d_j_l, &d_j));
    {
        const result = (try composer.getTriggerCandidate(&d_j, &d_j_k)).?;
        defer allocator.free(result.trigger);
        try eqStr("d j k", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_j_k, &d_j_k));
    try eq(null, try composer.getTriggerCandidate(&d_j_k, &d_k));
    {
        const result = (try composer.getTriggerCandidate(&d_k, &d_k_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d k l", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_k_l, &d_k));
    try eq(null, try composer.getTriggerCandidate(&d_k, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d_j));
    try eq(null, try composer.getTriggerCandidate(&d, &d_j));
    {
        const result = (try composer.getTriggerCandidate(&d_j, &d)).?;
        defer allocator.free(result.trigger);
        try eqStr("d j", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_j, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &nothingness));

    /////////////////////////////

    var j = [_]Key{Key.key_j};
    var j_l = [_]Key{ Key.key_j, Key.key_l };
    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d_j));
    {
        const result = (try composer.getTriggerCandidate(&d_j, &d_j_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d j l", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_j_l, &j_l));
    try eq(null, try composer.getTriggerCandidate(&j_l, &j));
    try eq(null, try composer.getTriggerCandidate(&j, &nothingness));

    ///////////////////////////// Prevent Repeating Test

    try eq(null, try composer.getTriggerCandidate(&nothingness, &nothingness));
    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d));

    /////////////////////////////

    var s = [_]Key{Key.key_s};
    var s_o = [_]Key{ Key.key_s, Key.key_o };
    try eq(null, try composer.getTriggerCandidate(&nothingness, &s));
    {
        const result = (try composer.getTriggerCandidate(&s, &s_o)).?;
        defer allocator.free(result.trigger);
        try eqStr("s o", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&s_o, &s_o));
    try eq(null, try composer.getTriggerCandidate(&s_o, &s_o));
    try eq(null, try composer.getTriggerCandidate(&s_o, &s_o));
    try eq(null, try composer.getTriggerCandidate(&s_o, &s));
    try eq(null, try composer.getTriggerCandidate(&s_o, &s));
    try eq(null, try composer.getTriggerCandidate(&s_o, &s));
    try eq(null, try composer.getTriggerCandidate(&s, &s));
    try eq(null, try composer.getTriggerCandidate(&s, &s));
    try eq(null, try composer.getTriggerCandidate(&s, &s));
    try eq(null, try composer.getTriggerCandidate(&s, &s));
    try eq(null, try composer.getTriggerCandidate(&s, &nothingness));
    try eq(null, try composer.getTriggerCandidate(&nothingness, &nothingness));

    /////////////////////////////

    var i = [_]Key{Key.key_i};
    var i_s = [_]Key{ Key.key_i, Key.key_s };

    {
        const result = (try composer.getTriggerCandidate(&nothingness, &i)).?;
        defer allocator.free(result.trigger);
        try eqStr("i", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&i, &i));
    try eq(null, try composer.getTriggerCandidate(&i, &i));
    try eq(null, try composer.getTriggerCandidate(&i, &i));
    try eq(null, try composer.getTriggerCandidate(&i, &i_s));
    try eq(null, try composer.getTriggerCandidate(&i_s, &i_s));
    try eq(null, try composer.getTriggerCandidate(&i_s, &i_s));
    try eq(null, try composer.getTriggerCandidate(&i_s, &i_s));
    try eq(null, try composer.getTriggerCandidate(&i_s, &i));
    try eq(null, try composer.getTriggerCandidate(&i, &i));
    try eq(null, try composer.getTriggerCandidate(&i, &i));
    try eq(null, try composer.getTriggerCandidate(&i, &nothingness));

    ///////////////////////////// Consecutive key down combo emits

    try eq(null, try composer.getTriggerCandidate(&nothingness, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d));
    {
        const result = (try composer.getTriggerCandidate(&d, &d_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d l", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_l, &d_l));
    try eq(null, try composer.getTriggerCandidate(&d_l, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d));
    {
        const result = (try composer.getTriggerCandidate(&d, &d_l)).?;
        defer allocator.free(result.trigger);
        try eqStr("d l", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&d_l, &d_l));
    try eq(null, try composer.getTriggerCandidate(&d_l, &d_l));
    try eq(null, try composer.getTriggerCandidate(&d_l, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &d));
    try eq(null, try composer.getTriggerCandidate(&d, &nothingness));

    /////////////////////////////

    var lshift = [_]Key{Key.key_left_shift};
    var one = [_]Key{Key.key_one};
    var lshift_1 = [_]Key{ Key.key_left_shift, Key.key_one };

    try eq(null, try composer.getTriggerCandidate(&nothingness, &lshift));
    try eq(null, try composer.getTriggerCandidate(&lshift, &lshift));
    {
        const result = (try composer.getTriggerCandidate(&lshift, &lshift_1)).?;
        defer allocator.free(result.trigger);
        try eqStr("lshift 1", result.trigger);
    }
    try eq(null, try composer.getTriggerCandidate(&lshift_1, &lshift_1));
    try eq(null, try composer.getTriggerCandidate(&lshift_1, &one));
}

////////////////////////////////////////////////////////////////////////////////////////////// Invoker

pub fn GenericTriggerPicker(comptime trigger_map_type: type) type {
    return struct {
        a: Allocator,
        new: *EventList,
        old: *EventList,
        time: *EventTimeList,
        trigger_map: *trigger_map_type,
        previous_trigger: ?Candidate = null,
        threshold: i64 = 100,

        pub fn init(a: std.mem.Allocator, old: *EventList, new: *EventList, time: *EventTimeList, trigger_map: *trigger_map_type) !*@This() {
            const picker = try a.create(@This());
            picker.* = .{
                .a = a,
                .old = old,
                .new = new,
                .time = time,
                .trigger_map = trigger_map,
            };
            return picker;
        }

        pub fn deinit(self: *@This()) void {
            if (self.previous_trigger) |latest| self.a.free(latest.trigger);
            self.a.destroy(self);
        }

        fn updatePreviousTrigger(self: *@This(), final_candidate: ?Candidate) !void {
            if (self.previous_trigger) |latest| self.a.free(latest.trigger);
            if (final_candidate) |fc| {
                self.previous_trigger = .{
                    .last = fc.last,
                    .up = fc.up,
                    .trigger = try self.a.dupe(u8, fc.trigger),
                };
                return;
            }
            self.previous_trigger = null;
        }

        fn process(self: *@This(), candidate: ?Candidate) !?Candidate {
            const old, const new, const time = .{ self.old.items, self.new.items, self.time.items };

            if (new.len == 0) { // return null and clean up candidate
                if (candidate) |c| self.a.free(c.trigger);
                return null;
            }

            if (new.len > 1 and time[1] -| time[0] < self.threshold) { // timing in threshold, clean up candidate and return last key
                const trigger = try eventListToStr(self.a, new[new.len - 1 ..]);
                const first_char = try eventListToStr(self.a, new[0..1]);
                defer self.a.free(first_char);

                if (self.trigger_map.get(first_char) != null and self.trigger_map.get(trigger) != null) {
                    if (candidate) |c| self.a.free(c.trigger);
                    return .{ .last = true, .trigger = trigger };
                }
                self.a.free(trigger);
            }

            if (candidate) |c| return c; // return non-null candidate

            if (new.len == 1 and old.len == 0) { // single key down
                // a trigger for this key might exist, but it might be a prefix as well.
                // if it's a prefix, candidate will be null.
                // since we're in Insert Mode, we want to emit it right away on key down despite it being a prefix
                const trigger = try eventListToStr(self.a, new[new.len - 1 ..]);
                if (self.trigger_map.get(trigger) != null) return .{ .last = true, .trigger = trigger };
                self.a.free(trigger);
            }

            return null;
        }

        pub fn getFinalTrigger(self: *@This(), potential_candidate: ?Candidate) !?[]const u8 {
            const final = try self.process(potential_candidate);

            if (final == null) {
                try self.updatePreviousTrigger(null);
                return null;
            }

            if (self.previous_trigger) |latest| { // prevent repeating previous trigger
                if (std.mem.eql(u8, latest.trigger, final.?.trigger)) {
                    self.a.free(final.?.trigger);
                    return null;
                }
            }

            try self.updatePreviousTrigger(final.?);
            return final.?.trigger;
        }
    };
}

test GenericTriggerPicker {
    const a = std.testing.allocator;

    var old = EventList.init(a);
    defer old.deinit();

    var new = EventList.init(a);
    defer new.deinit();

    var time = EventTimeList.init(a);
    defer time.deinit();

    var trigger_map = try createTriggerMapForTesting(a);
    defer trigger_map.deinit();

    const TriggerPicker = GenericTriggerPicker(TestTriggerMap);

    var picker = try TriggerPicker.init(a, &old, &new, &time, &trigger_map);
    defer picker.deinit();

    // single key case
    {
        try new.append(Key.key_d);
        try time.append(0);
        { // d down
            const trigger = try std.fmt.allocPrint(a, "d", .{});
            const result = try picker.getFinalTrigger(Candidate{ .trigger = trigger });
            defer a.free(result.?);
            try eqStr("d", result.?);
        }
        try old.append(Key.key_d);

        { // d hold
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }

        _ = new.orderedRemove(0);
        _ = time.orderedRemove(0);
        { // d up
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }
        _ = old.orderedRemove(0);
    }

    // single combo case
    {
        try new.append(Key.key_s);
        try time.append(0);
        { // s down
            const result = try picker.getFinalTrigger(null);
            defer a.free(result.?);
            try eqStr("s", result.?);
        }
        try old.append(Key.key_s);

        { // s hold
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }

        try new.append(Key.key_o);
        try time.append(200);
        { // `s o` down
            const trigger = try std.fmt.allocPrint(a, "s o", .{});
            const result = try picker.getFinalTrigger(Candidate{ .trigger = trigger });
            defer a.free(result.?);
            try eqStr("s o", result.?);
        }
        try old.append(Key.key_o);

        { // `s o` hold
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }

        _ = new.orderedRemove(1);
        _ = time.orderedRemove(1);
        { // o up
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }
        _ = old.orderedRemove(1);

        _ = new.orderedRemove(0);
        _ = time.orderedRemove(0);
        {
            // s up
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }
        _ = old.orderedRemove(0);
    }

    // don't short circuit triggers not in map
    {
        try new.append(Key.key_left_shift);
        try time.append(0);
        {
            const result = try picker.getFinalTrigger(null);
            try eq(null, result);
        }
        _ = new.orderedRemove(0);
        _ = time.orderedRemove(0);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const supported_keys = [_]Key{
    Key.key_a,         Key.key_b,            Key.key_c,             Key.key_d,
    Key.key_e,         Key.key_f,            Key.key_g,             Key.key_h,
    Key.key_i,         Key.key_j,            Key.key_k,             Key.key_l,
    Key.key_m,         Key.key_n,            Key.key_o,             Key.key_p,
    Key.key_q,         Key.key_r,            Key.key_s,             Key.key_t,
    Key.key_u,         Key.key_v,            Key.key_w,             Key.key_x,
    Key.key_y,         Key.key_z,            Key.key_tab,           Key.key_space,
    Key.key_enter,     Key.key_backspace,    Key.key_delete,        Key.key_down,
    Key.key_up,        Key.key_left,         Key.key_right,         Key.key_home,
    Key.key_end,       Key.key_one,          Key.key_two,           Key.key_three,
    Key.key_four,      Key.key_five,         Key.key_six,           Key.key_seven,
    Key.key_eight,     Key.key_nine,         Key.key_zero,          Key.key_f1,
    Key.key_f2,        Key.key_f3,           Key.key_f4,            Key.key_f5,
    Key.key_f6,        Key.key_f7,           Key.key_f8,            Key.key_f9,
    Key.key_f10,       Key.key_f11,          Key.key_f12,           Key.key_equal,
    Key.key_minus,     Key.key_left_bracket, Key.key_right_bracket, Key.key_backslash,
    Key.key_semicolon, Key.key_apostrophe,   Key.key_comma,         Key.key_period,
    Key.key_slash,     Key.key_grave,        Key.key_left_shift,    Key.key_right_shift,
};

fn getStringRepresentationOfKey(key: Key) []const u8 {
    return switch (key) {
        Key.key_a => "a",
        Key.key_b => "b",
        Key.key_c => "c",
        Key.key_d => "d",
        Key.key_e => "e",
        Key.key_f => "f",
        Key.key_g => "g",
        Key.key_h => "h",
        Key.key_i => "i",
        Key.key_j => "j",
        Key.key_k => "k",
        Key.key_l => "l",
        Key.key_m => "m",
        Key.key_n => "n",
        Key.key_o => "o",
        Key.key_p => "p",
        Key.key_q => "q",
        Key.key_r => "r",
        Key.key_s => "s",
        Key.key_t => "t",
        Key.key_u => "u",
        Key.key_v => "v",
        Key.key_w => "w",
        Key.key_x => "x",
        Key.key_y => "y",
        Key.key_z => "z",

        Key.key_one => "1",
        Key.key_two => "2",
        Key.key_three => "3",
        Key.key_four => "4",
        Key.key_five => "5",
        Key.key_six => "6",
        Key.key_seven => "7",
        Key.key_eight => "8",
        Key.key_nine => "9",
        Key.key_zero => "0",

        Key.key_tab => "tab",
        Key.key_space => "space",
        Key.key_enter => "enter",

        Key.key_backspace => "backspace",
        Key.key_delete => "delete",

        Key.key_equal => "=",
        Key.key_minus => "-",
        Key.key_left_bracket => "[",
        Key.key_right_bracket => "]",
        Key.key_backslash => "\\",
        Key.key_semicolon => ";",
        Key.key_apostrophe => "'",
        Key.key_comma => ",",
        Key.key_period => ".",
        Key.key_slash => "/",

        Key.key_down => "down",
        Key.key_up => "up",
        Key.key_left => "left",
        Key.key_right => "right",

        Key.key_home => "home",
        Key.key_end => "end",

        Key.key_left_shift => "lshift",
        Key.key_right_shift => "rshift",

        Key.key_f1 => "<f1>",
        Key.key_f2 => "<f2>",
        Key.key_f3 => "<f3>",
        Key.key_f4 => "<f4>",
        Key.key_f5 => "<f5>",
        Key.key_f6 => "<f6>",
        Key.key_f7 => "<f7>",
        Key.key_f8 => "<f8>",
        Key.key_f9 => "<f9>",
        Key.key_f10 => "<f10>",
        Key.key_f11 => "<f11>",
        Key.key_f12 => "<f12>",

        else => "",
    };
}
