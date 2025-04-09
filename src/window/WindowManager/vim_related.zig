// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const WindowManager = @import("../WindowManager.zig");
const WindowSource = WindowManager.WindowSource;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn mapKeys(wm: *WindowManager, council: *WindowManager.MappingCouncil) !void {
    try mapNormalMode(wm, council);
    try mapVisualMode(wm, council);
    try mapInsertMode(wm, council);
}

const NORMAL = "normal";
const VISUAL = "visual";
const INSERT = "insert";

const NORMAL_TO_INSERT = WindowManager.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{INSERT} };
const INSERT_TO_NORMAL = WindowManager.Callback.Contexts{ .remove = &.{INSERT}, .add = &.{NORMAL} };
const NORMAL_TO_VISUAL = WindowManager.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{VISUAL} };
const VISUAL_TO_NORMAL = WindowManager.Callback.Contexts{ .remove = &.{VISUAL}, .add = &.{NORMAL} };
const VISUAL_TO_INSERT = WindowManager.Callback.Contexts{ .remove = &.{VISUAL}, .add = &.{INSERT} };

fn mapNormalMode(wm: *WindowManager, council: *WindowManager.MappingCouncil) !void {

    // hjkl
    try council.map(NORMAL, &.{.j}, .{ .f = moveCursorDown, .ctx = wm });
    try council.map(NORMAL, &.{.k}, .{ .f = moveCursorUp, .ctx = wm });
    try council.map(NORMAL, &.{.h}, .{ .f = moveCursorLeft, .ctx = wm });
    try council.map(NORMAL, &.{.l}, .{ .f = moveCursorRight, .ctx = wm });

    // web
    try council.map(NORMAL, &.{.w}, .{ .f = moveCursorForwardWordStart, .ctx = wm });
    try council.map(NORMAL, &.{.e}, .{ .f = moveCursorForwardWordEnd, .ctx = wm });
    try council.map(NORMAL, &.{.b}, .{ .f = moveCursorBackwardsWordStart, .ctx = wm });
    try council.map(NORMAL, &.{ .left_shift, .w }, .{ .f = moveCursorForwardBIGWORDStart, .ctx = wm });
    try council.map(NORMAL, &.{ .left_shift, .e }, .{ .f = moveCursorForwardBIGWORDEnd, .ctx = wm });
    try council.map(NORMAL, &.{ .left_shift, .b }, .{ .f = moveCursorBackwardsBIGWORDStart, .ctx = wm });

    // $0
    try council.map(NORMAL, &.{.zero}, .{ .f = moveCursorToFirstNonSpaceCharacterOfLine, .ctx = wm });
    try council.map(NORMAL, &.{ .left_shift, .zero }, .{ .f = moveCursorToBeginningOfLine, .ctx = wm });
    try council.map(NORMAL, &.{ .left_shift, .four }, .{ .f = moveCursorToEndOfLine, .ctx = wm });

    ///////////////////////////// clear & delete

    // single quote
    try council.map(NORMAL, &.{ .d, .apostrophe }, .{ .f = deleteInSingleQuote, .ctx = wm });
    try council.map(NORMAL, &.{ .c, .apostrophe }, .{
        .f = deleteInSingleQuote,
        .ctx = wm,
        .contexts = NORMAL_TO_INSERT,
        .require_clarity_afterwards = true,
    });

    // word / WORD
    try council.map(NORMAL, &.{ .d, .semicolon }, .{ .f = deleteInWord, .ctx = wm });
    try council.map(NORMAL, &.{ .c, .semicolon }, .{
        .f = deleteInWord,
        .ctx = wm,
        .contexts = NORMAL_TO_INSERT,
        .require_clarity_afterwards = true,
    });

    try council.mapMany(NORMAL, &.{ &.{ .d, .s, .semicolon }, &.{ .s, .d, .semicolon } }, .{ .f = deleteInWORD, .ctx = wm });
    try council.mapMany(NORMAL, &.{ &.{ .c, .x, .semicolon }, &.{ .x, .c, .semicolon } }, .{
        .f = deleteInWORD,
        .ctx = wm,
        .contexts = NORMAL_TO_INSERT,
        .require_clarity_afterwards = true,
    });
}

fn mapVisualMode(wm: *WindowManager, council: *WindowManager.MappingCouncil) !void {

    // mode enter / exit
    try council.map(NORMAL, &.{.v}, .{ .f = enterVisualMode, .ctx = wm, .contexts = NORMAL_TO_VISUAL });
    try council.map(VISUAL, &.{.escape}, .{ .f = exitVisualMode, .ctx = wm, .contexts = VISUAL_TO_NORMAL });

    // hjkl
    try council.map(VISUAL, &.{.j}, .{ .f = moveCursorDown, .ctx = wm });
    try council.map(VISUAL, &.{.k}, .{ .f = moveCursorUp, .ctx = wm });
    try council.map(VISUAL, &.{.h}, .{ .f = moveCursorLeft, .ctx = wm });
    try council.map(VISUAL, &.{.l}, .{ .f = moveCursorRight, .ctx = wm });

    // web
    try council.map(VISUAL, &.{.w}, .{ .f = moveCursorForwardWordStart, .ctx = wm });
    try council.map(VISUAL, &.{.e}, .{ .f = moveCursorForwardWordEnd, .ctx = wm });
    try council.map(VISUAL, &.{.b}, .{ .f = moveCursorBackwardsWordStart, .ctx = wm });
    try council.map(VISUAL, &.{ .left_shift, .w }, .{ .f = moveCursorForwardBIGWORDStart, .ctx = wm });
    try council.map(VISUAL, &.{ .left_shift, .e }, .{ .f = moveCursorForwardBIGWORDEnd, .ctx = wm });
    try council.map(VISUAL, &.{ .left_shift, .b }, .{ .f = moveCursorBackwardsBIGWORDStart, .ctx = wm });

    // $0
    try council.map(VISUAL, &.{.zero}, .{ .f = moveCursorToFirstNonSpaceCharacterOfLine, .ctx = wm });
    try council.map(VISUAL, &.{ .left_shift, .zero }, .{ .f = moveCursorToBeginningOfLine, .ctx = wm });
    try council.map(VISUAL, &.{ .left_shift, .four }, .{ .f = moveCursorToEndOfLine, .ctx = wm });

    ///////////////////////////// clear & delete

    try council.map(VISUAL, &.{.d}, .{ .f = delete, .ctx = wm, .contexts = VISUAL_TO_NORMAL });
    try council.map(VISUAL, &.{.c}, .{ .f = delete, .ctx = wm, .contexts = VISUAL_TO_INSERT });

    ///////////////////////////// yank

    try council.map(VISUAL, &.{.y}, .{ .f = yankVisualSeletionToClipboard, .ctx = wm, .contexts = VISUAL_TO_NORMAL });
}

fn mapInsertMode(wm: *WindowManager, council: *WindowManager.MappingCouncil) !void {

    // mode enter / exit
    try council.map(NORMAL, &.{.i}, .{ .f = enterInsertMode_i, .ctx = wm, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{.a}, .{ .f = enterInsertMode_a, .ctx = wm, .contexts = NORMAL_TO_INSERT });
    try council.map(INSERT, &.{.escape}, .{ .f = exitInsertMode, .ctx = wm, .contexts = INSERT_TO_NORMAL });

    // iaoIAO
    try council.map(NORMAL, &.{ .left_shift, .i }, .{ .f = enterInsertMode_I, .ctx = wm, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{ .left_shift, .a }, .{ .f = enterInsertMode_A, .ctx = wm, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{.o}, .{ .f = enterInsertMode_o, .ctx = wm, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{ .left_shift, .o }, .{ .f = enterInsertMode_O, .ctx = wm, .contexts = NORMAL_TO_INSERT });
    try council.map(INSERT, &.{ .left_alt, .o }, .{ .f = enterInsertMode_o, .ctx = wm });
    try council.map(INSERT, &.{ .left_alt, .left_shift, .o }, .{ .f = enterInsertMode_O, .ctx = wm });

    // hkjl
    try council.map(INSERT, &.{ .escape, .h }, .{ .f = moveCursorLeft, .ctx = wm });
    try council.map(INSERT, &.{ .escape, .j }, .{ .f = moveCursorDown, .ctx = wm });
    try council.map(INSERT, &.{ .escape, .k }, .{ .f = moveCursorUp, .ctx = wm });
    try council.map(INSERT, &.{ .escape, .l }, .{ .f = moveCursorRight, .ctx = wm });

    // insert chars
    const InsertCharsCb = struct {
        chars: []const u8,
        wm: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try insertChars(self.wm, self.chars);
        }
        fn init(allocator: std.mem.Allocator, ctx: *anyopaque, chars: []const u8) !WindowManager.Callback {
            const self = try allocator.create(@This());
            const wm_ = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
            self.* = .{ .chars = chars, .wm = wm_ };
            return WindowManager.Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };
    try council.mapInsertCharacters(&.{INSERT}, wm, InsertCharsCb.init);

    // backspace
    try council.map(INSERT, &.{.backspace}, .{ .f = backspace, .ctx = wm });
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn deleteRanges(wm: *WindowManager, kind: WindowSource.DeleteRangesKind) !void {
    const active_window = wm.active_window orelse return;

    var handler = wm.wmap.get(active_window) orelse return;
    const result = try handler.source.deleteRanges(wm.a, active_window.cursor_manager, kind) orelse return;
    defer wm.a.free(result);

    for (handler.windows.keys()) |win| try win.processEditResult(wm.a, wm.qtree, result, wm.mall);
}

pub fn insertChars(wm: *WindowManager, chars: []const u8) !void {
    const active_window = wm.active_window orelse return;

    var handler = wm.wmap.get(active_window) orelse return;
    const result = try handler.source.insertChars(wm.a, chars, active_window.cursor_manager) orelse return;
    defer wm.a.free(result);

    for (handler.windows.keys()) |win| try win.processEditResult(wm.a, wm.qtree, result, wm.mall);
}

////////////////////////////////////////////////////////////////////////////////////////////// Inputs

///////////////////////////// Normal Mode

pub fn deleteInSingleQuote(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try deleteRanges(wm, .in_single_quote);
}

pub fn deleteInWord(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try deleteRanges(wm, .in_word);
}

pub fn deleteInWORD(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try deleteRanges(wm, .in_WORD);
}

///////////////////////////// Visual Mode

pub fn enterVisualMode(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.activateRangeMode();
}

pub fn exitVisualMode(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.activatePointMode();
}

pub fn delete(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try deleteRanges(wm, .range);
    try exitVisualMode(ctx);
}

///////////////////////////// Insert Mode

pub fn backspace(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try deleteRanges(wm, .backspace);
}

pub fn enterInsertMode_i(ctx: *anyopaque) !void {
    _ = ctx;
}

pub fn enterInsertMode_I(ctx: *anyopaque) !void {
    try moveCursorToBeginningOfLine(ctx);
    try enterInsertMode_i(ctx);
}

pub fn enterInsertMode_a(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.enterAFTERInsertMode(&window.ws.buf.ropeman);
}

pub fn enterInsertMode_A(ctx: *anyopaque) !void {
    try moveCursorToEndOfLine(ctx);
    try enterInsertMode_a(ctx);
}

pub fn enterInsertMode_o(ctx: *anyopaque) !void {
    try moveCursorToEndOfLine(ctx);
    try enterInsertMode_a(ctx);
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try insertChars(wm, "\n");
}

pub fn enterInsertMode_O(ctx: *anyopaque) !void {
    try moveCursorToBeginningOfLine(ctx);
    try enterInsertMode_i(ctx);
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    try insertChars(wm, "\n");
    try moveCursorUp(ctx);
}

pub fn exitInsertMode(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    try window.ws.buf.ropeman.registerLastPendingToHistory();
    window.cursor_manager.moveLeft(1, &window.ws.buf.ropeman);
}

///////////////////////////// Movement

// $ 0 ^

pub fn moveCursorToBeginningOfLine(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveToBeginningOfLine(&window.ws.buf.ropeman);
}

pub fn moveCursorToEndOfLine(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveToEndOfLine(&window.ws.buf.ropeman);
}

pub fn moveCursorToFirstNonSpaceCharacterOfLine(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveToFirstNonSpaceCharacterOfLine(&window.ws.buf.ropeman);
}

// hjkl

pub fn moveCursorUp(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveUp(1, &window.ws.buf.ropeman);
}

pub fn moveCursorDown(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveDown(1, &window.ws.buf.ropeman);
}

pub fn moveCursorLeft(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveLeft(1, &window.ws.buf.ropeman);
}

pub fn moveCursorRight(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.moveRight(1, &window.ws.buf.ropeman);
}

// Vim Word

pub fn moveCursorForwardWordStart(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.start, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardWordEnd(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.end, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorBackwardsWordStart(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.backwardsWord(.start, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardBIGWORDStart(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.start, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardBIGWORDEnd(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.end, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorBackwardsBIGWORDStart(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    window.cursor_manager.backwardsWord(.start, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

// yank to clipboard

pub fn yankVisualSeletionToClipboard(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const window = wm.active_window orelse return;
    const handler = wm.wmap.get(window) orelse return;

    const cursor_ranges = try window.cursor_manager.produceCursorRanges(wm.a);
    defer wm.a.free(cursor_ranges);
    if (cursor_ranges.len == 0) return;

    const byte_count = try handler.source.buf.ropeman.getRangeSize(cursor_ranges[0].start, cursor_ranges[0].end);
    const buffer: [:0]u8 = try wm.a.allocSentinel(u8, byte_count, 0);
    defer wm.a.free(buffer);

    _ = handler.source.buf.ropeman.getRange(cursor_ranges[0].start, cursor_ranges[0].end, buffer);

    /////////////////////////////

    wm.mall.rcb.setClipboardText(buffer);
    try exitVisualMode(ctx);
}
