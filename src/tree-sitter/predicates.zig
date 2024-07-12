// Copied & Edited from https://github.com/ziglibs/treez

const std = @import("std");
const b = @import("bindings.zig");
const Query = b.Query;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EqualPredicate = struct {
    a: []const u8,
    b: union(enum) { string: []const u8, capture: []const u8 },
};
const PredicateList = std.ArrayListUnmanaged(EqualPredicate);
const PredicateMap = std.AutoHashMapUnmanaged(u32, packed struct { index: u32, len: u32 });
const CaptureIdNameMap = std.StringHashMapUnmanaged(u32);

//////////////////////////////////////////////////////////////////////////////////////////////

pub const CursorWithValidation = struct {
    allocator: std.mem.Allocator,
    predicates: PredicateList,
    predicate_map: PredicateMap,
    capture_name_to_id: CaptureIdNameMap,

    pub fn init(allocator: std.mem.Allocator, query: *const Query) !CursorWithValidation {
        var predicates = PredicateList{};
        var predicate_map = PredicateMap{};

        var capture_name_to_id = CaptureIdNameMap{};

        for (0..query.getPatternCount()) |pattern| {
            const preds = query.getPredicatesForPattern(@as(u32, @intCast(pattern)));

            var index: usize = 0;
            var predicate_len: u32 = 0;
            while (index < preds.len) {
                if (preds[index].type != .string) @panic("Unexpected predicate value");
                if (!std.mem.eql(u8, query.getStringValueForId(@as(u32, @intCast(preds[index].value_id))), "eq?"))
                    @panic("Only the 'eq?' predicate is supported by treez at the moment.");
                if (preds[index + 1].type != .capture) @panic("Unexpected predicate value");

                switch (preds[index + 2].type) {
                    .string => {
                        try predicates.append(allocator, .{
                            .a = query.getCaptureNameForId(@as(u32, @intCast(preds[index + 1].value_id))),
                            .b = .{ .string = query.getStringValueForId(@as(u32, @intCast(preds[index + 2].value_id))) },
                        });
                    },
                    .capture => {
                        try predicates.append(allocator, .{
                            .a = query.getCaptureNameForId(@as(u32, @intCast(preds[index + 1].value_id))),
                            .b = .{ .capture = query.getCaptureNameForId(@as(u32, @intCast(preds[index + 2].value_id))) },
                        });
                    },
                    else => @panic("Unexpected predicate value"),
                }

                if (preds[index + 3].type != .done) @panic("Unexpected predicate value");

                // TODO: This is here as we'll need to tweak these to support future predicates
                predicate_len += 1;
                index += 4;
            }

            try predicate_map.put(allocator, @as(u32, @intCast(pattern)), .{
                .index = @as(u32, @intCast(predicates.items.len - predicate_len)),
                .len = @as(u32, @intCast(predicate_len)),
            });
        }

        for (0..query.getCaptureCount()) |cap| {
            try capture_name_to_id.put(allocator, query.getCaptureNameForId(@as(u32, @intCast(cap))), @as(u32, @intCast(cap)));
        }

        return .{
            .allocator = allocator,
            .predicates = predicates,
            .predicate_map = predicate_map,
            .capture_name_to_id = capture_name_to_id,
        };
    }

    pub fn deinit(validator: *CursorWithValidation) void {
        validator.predicates.deinit(validator.allocator);
        validator.* = undefined;
    }

    pub fn isValid(validator: CursorWithValidation, source: []const u8, match: Query.Match) bool {
        if (validator.predicate_map.get(match.pattern_index)) |pred_loc| {
            const predicates: []const EqualPredicate = validator.predicates.items[pred_loc.index .. pred_loc.index + pred_loc.len];
            for (predicates) |pred| {
                const a = validator.capture_name_to_id.get(pred.a).?;
                const b_capture = switch (pred.b) {
                    .string => null,
                    .capture => |c| validator.capture_name_to_id.get(c).?,
                };

                var a_value: ?[]const u8 = null;
                var b_value: ?[]const u8 = switch (pred.b) {
                    .string => |v| v,
                    .capture => null,
                };

                for (match.captures()) |cap| {
                    if (cap.id == a) a_value = source[cap.node.getStartByte()..cap.node.getEndByte()];
                    if (b_capture != null and cap.id == b_capture.?) b_value = source[cap.node.getStartByte()..cap.node.getEndByte()];
                }

                const av = a_value orelse @panic("Impossible!");
                const bv = b_value orelse @panic("Impossible!");

                std.log.info("{s} {s}", .{ av, bv });

                return std.mem.eql(u8, av, bv);
            }
        }

        return true;
    }

    pub fn nextMatch(validator: CursorWithValidation, source: []const u8, cursor: *Query.Cursor) ?Query.Match {
        while (true) {
            const match = cursor.nextMatch() orelse return null;
            if (validator.isValid(source, match)) {
                return match;
            }
        }
    }

    pub fn nextCapture(validator: CursorWithValidation, source: []const u8, cursor: *Query.Cursor) ?Query.Capture {
        while (true) {
            const capture = cursor.nextCapture() orelse return null;
            if (validator.isValid(source, capture[0])) {
                return capture[0].captures()[capture[1]];
            }
        }
    }
};
