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
const Session = @import("../Session.zig");
const WindowSource = Session.WindowManager.WindowSource;
const Callback = Session.Callback;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn mapKeys(sess: *Session) !void {
    try mapNormalMode(sess, sess.council);
    try mapVisualMode(sess, sess.council);
    try mapInsertMode(sess, sess.council);
}

const NORMAL = "normal";
const VISUAL = "visual";
const INSERT = "insert";
const G_PREFIX = "G_PREFIX";

const NORMAL_TO_INSERT = Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{INSERT} };
const INSERT_TO_NORMAL = Callback.Contexts{ .remove = &.{INSERT}, .add = &.{NORMAL} };
const NORMAL_TO_VISUAL = Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{VISUAL} };
const VISUAL_TO_NORMAL = Callback.Contexts{ .remove = &.{VISUAL}, .add = &.{NORMAL} };
const VISUAL_TO_INSERT = Callback.Contexts{ .remove = &.{VISUAL}, .add = &.{INSERT} };

const NORMAL_TO_G_PREFIX = Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{G_PREFIX} };
const G_PREFIX_TO_NORMAL = Callback.Contexts{ .remove = &.{G_PREFIX}, .add = &.{NORMAL} };

fn mapNormalMode(sess: *Session, c: *Session.MappingCouncil) !void {

    // hjkl
    try c.map(NORMAL, &.{ .w, .j }, .{ .f = moveCursorDown, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .k }, .{ .f = moveCursorUp, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .h }, .{ .f = moveCursorLeft, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .l }, .{ .f = moveCursorRight, .ctx = sess });

    // web
    try c.map(NORMAL, &.{ .w, .i }, .{ .f = moveCursorForwardWordStart, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .o }, .{ .f = moveCursorForwardWordEnd, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .u }, .{ .f = moveCursorBackwardsWordStart, .ctx = sess });

    try c.map(NORMAL, &.{ .left_shift, .w, .i }, .{ .f = moveCursorForwardBIGWORDStart, .ctx = sess });
    try c.map(NORMAL, &.{ .left_shift, .w, .o }, .{ .f = moveCursorForwardBIGWORDEnd, .ctx = sess });
    try c.map(NORMAL, &.{ .left_shift, .w, .u }, .{ .f = moveCursorBackwardsBIGWORDStart, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .left_shift, .i }, .{ .f = moveCursorForwardBIGWORDStart, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .left_shift, .o }, .{ .f = moveCursorForwardBIGWORDEnd, .ctx = sess });
    try c.map(NORMAL, &.{ .w, .left_shift, .u }, .{ .f = moveCursorBackwardsBIGWORDStart, .ctx = sess });

    // $0
    try c.map(NORMAL, &.{.zero}, .{ .f = moveCursorToFirstNonSpaceCharacterOfLine, .ctx = sess });
    try c.map(NORMAL, &.{ .left_shift, .zero }, .{ .f = moveCursorToBeginningOfLine, .ctx = sess });
    try c.map(NORMAL, &.{ .left_shift, .four }, .{ .f = moveCursorToEndOfLine, .ctx = sess });

    ///////////////////////////// clear & delete

    // single quote
    try c.map(NORMAL, &.{ .d, .apostrophe }, .{ .f = deleteInSingleQuote, .ctx = sess });
    try c.map(NORMAL, &.{ .c, .apostrophe }, .{
        .f = deleteInSingleQuote,
        .ctx = sess,
        .contexts = NORMAL_TO_INSERT,
        .require_clarity_afterwards = true,
    });

    // word / WORD
    try c.map(NORMAL, &.{ .d, .semicolon }, .{ .f = deleteInWord, .ctx = sess });
    try c.map(NORMAL, &.{ .c, .semicolon }, .{
        .f = deleteInWord,
        .ctx = sess,
        .contexts = NORMAL_TO_INSERT,
        .require_clarity_afterwards = true,
    });

    try c.mapMany(NORMAL, &.{ &.{ .d, .s, .semicolon }, &.{ .s, .d, .semicolon } }, .{ .f = deleteInWORD, .ctx = sess });
    try c.mapMany(NORMAL, &.{ &.{ .c, .x, .semicolon }, &.{ .x, .c, .semicolon } }, .{
        .f = deleteInWORD,
        .ctx = sess,
        .contexts = NORMAL_TO_INSERT,
        .require_clarity_afterwards = true,
    });

    // g prefix
    try c.map(NORMAL, &.{.g}, .{ .f = nop, .ctx = sess, .contexts = NORMAL_TO_G_PREFIX });
}

fn mapVisualMode(sess: *Session, council: *Session.MappingCouncil) !void {

    // mode enter / exit
    try council.map(NORMAL, &.{.v}, .{ .f = enterVisualMode, .ctx = sess, .contexts = NORMAL_TO_VISUAL });
    try council.map(VISUAL, &.{.escape}, .{ .f = exitVisualMode, .ctx = sess, .contexts = VISUAL_TO_NORMAL });

    // hjkl
    try council.map(VISUAL, &.{.j}, .{ .f = moveCursorDown, .ctx = sess });
    try council.map(VISUAL, &.{.k}, .{ .f = moveCursorUp, .ctx = sess });
    try council.map(VISUAL, &.{.h}, .{ .f = moveCursorLeft, .ctx = sess });
    try council.map(VISUAL, &.{.l}, .{ .f = moveCursorRight, .ctx = sess });

    // web
    try council.map(VISUAL, &.{.w}, .{ .f = moveCursorForwardWordStart, .ctx = sess });
    try council.map(VISUAL, &.{.e}, .{ .f = moveCursorForwardWordEnd, .ctx = sess });
    try council.map(VISUAL, &.{.b}, .{ .f = moveCursorBackwardsWordStart, .ctx = sess });
    try council.map(VISUAL, &.{ .left_shift, .w }, .{ .f = moveCursorForwardBIGWORDStart, .ctx = sess });
    try council.map(VISUAL, &.{ .left_shift, .e }, .{ .f = moveCursorForwardBIGWORDEnd, .ctx = sess });
    try council.map(VISUAL, &.{ .left_shift, .b }, .{ .f = moveCursorBackwardsBIGWORDStart, .ctx = sess });

    // $0
    try council.map(VISUAL, &.{.zero}, .{ .f = moveCursorToFirstNonSpaceCharacterOfLine, .ctx = sess });
    try council.map(VISUAL, &.{ .left_shift, .zero }, .{ .f = moveCursorToBeginningOfLine, .ctx = sess });
    try council.map(VISUAL, &.{ .left_shift, .four }, .{ .f = moveCursorToEndOfLine, .ctx = sess });

    ///////////////////////////// clear & delete

    try council.map(VISUAL, &.{.d}, .{ .f = delete, .ctx = sess, .contexts = VISUAL_TO_NORMAL });
    try council.map(VISUAL, &.{.c}, .{ .f = delete, .ctx = sess, .contexts = VISUAL_TO_INSERT });

    ///////////////////////////// yank

    try council.map(VISUAL, &.{.y}, .{ .f = yankVisualSeletionToClipboard, .ctx = sess, .contexts = VISUAL_TO_NORMAL });

    ////////////////////////////////////////////////////////////////////////////////////////////// Alternate

    try map(sess, NORMAL, &.{ .v, .o }, &.{ enterVisualMode, moveCursorForwardWordEnd }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .o }, &.{moveCursorForwardWordEnd}, .{});
    try map(sess, NORMAL, &.{ .v, .left_shift, .o }, &.{ enterVisualMode, moveCursorForwardBIGWORDEnd }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .left_shift, .o }, &.{moveCursorForwardBIGWORDEnd}, .{});

    try map(sess, NORMAL, &.{ .v, .i }, &.{ enterVisualMode, moveCursorForwardWordStart }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .i }, &.{moveCursorForwardWordStart}, .{});
    try map(sess, NORMAL, &.{ .v, .left_shift, .i }, &.{ enterVisualMode, moveCursorForwardBIGWORDStart }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .left_shift, .i }, &.{moveCursorForwardBIGWORDStart}, .{});

    try map(sess, NORMAL, &.{ .v, .u }, &.{ enterVisualMode, moveCursorBackwardsWordStart }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .u }, &.{moveCursorBackwardsWordStart}, .{});
    try map(sess, NORMAL, &.{ .v, .left_shift, .u }, &.{ enterVisualMode, moveCursorBackwardsBIGWORDStart }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .left_shift, .u }, &.{moveCursorBackwardsBIGWORDStart}, .{});

    try map(sess, NORMAL, &.{ .v, .j }, &.{ enterVisualMode, moveCursorDown }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .j }, &.{moveCursorDown}, .{});
    try map(sess, NORMAL, &.{ .v, .k }, &.{ enterVisualMode, moveCursorUp }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .k }, &.{moveCursorUp}, .{});
    try map(sess, NORMAL, &.{ .v, .h }, &.{ enterVisualMode, moveCursorLeft }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .h }, &.{moveCursorLeft}, .{});
    try map(sess, NORMAL, &.{ .v, .l }, &.{ enterVisualMode, moveCursorRight }, NORMAL_TO_VISUAL);
    try map(sess, VISUAL, &.{ .v, .l }, &.{moveCursorRight}, .{});
}

fn mapInsertMode(sess: *Session, council: *Session.MappingCouncil) !void {

    // mode enter / exit
    try council.map(NORMAL, &.{.i}, .{ .f = enterInsertMode_i, .ctx = sess, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{.a}, .{ .f = enterInsertMode_a, .ctx = sess, .contexts = NORMAL_TO_INSERT });
    try council.map(INSERT, &.{.escape}, .{ .f = exitInsertMode, .ctx = sess, .contexts = INSERT_TO_NORMAL });

    // iaoIAO
    try council.map(NORMAL, &.{ .left_shift, .i }, .{ .f = enterInsertMode_I, .ctx = sess, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{ .left_shift, .a }, .{ .f = enterInsertMode_A, .ctx = sess, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{.o}, .{ .f = enterInsertMode_o, .ctx = sess, .contexts = NORMAL_TO_INSERT });
    try council.map(NORMAL, &.{ .left_shift, .o }, .{ .f = enterInsertMode_O, .ctx = sess, .contexts = NORMAL_TO_INSERT });
    try council.map(INSERT, &.{ .left_alt, .o }, .{ .f = enterInsertMode_o, .ctx = sess });
    try council.map(INSERT, &.{ .left_alt, .left_shift, .o }, .{ .f = enterInsertMode_O, .ctx = sess });

    // hkjl
    try council.map(INSERT, &.{ .escape, .h }, .{ .f = moveCursorLeft, .ctx = sess });
    try council.map(INSERT, &.{ .escape, .j }, .{ .f = moveCursorDown, .ctx = sess });
    try council.map(INSERT, &.{ .escape, .k }, .{ .f = moveCursorUp, .ctx = sess });
    try council.map(INSERT, &.{ .escape, .l }, .{ .f = moveCursorRight, .ctx = sess });

    // insert chars
    const InsertCharsCb = struct {
        chars: []const u8,
        sess: *Session,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try insertChars(self.sess, self.chars);
        }
        fn init(allocator: std.mem.Allocator, ctx: *anyopaque, chars: []const u8) !Session.Callback {
            const self = try allocator.create(@This());
            const sess_ = @as(*Session, @ptrCast(@alignCast(ctx)));
            self.* = .{ .chars = chars, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };
    try council.mapInsertCharacters(&.{INSERT}, sess, InsertCharsCb.init);

    // backspace
    try council.map(INSERT, &.{.backspace}, .{ .f = backspace, .ctx = sess });
}

////////////////////////////////////////////////////////////////////////////////////////////// g prefix

// fn mapGMode(sess: *Session) !void {
//     const c = sess.council;
//
//     try c.map(G_PREFIX, &.{.d}, .{ .f = sendGoToDeclarationRequest, .ctx = sess, .contexts = G_PREFIX_TO_NORMAL });
// }
//
// fn sendGoToDeclarationRequest(ctx: *anyopaque) !void {
//     const session = @as(*Session, @ptrCast(@alignCast(ctx)));
//     const wm = session.getActiveCanvasWindowManager() orelse return;
//     const active_window = wm.active_window orelse return;
//
//     // TODO: integrate Session with LSPClient
//     // TODO: create a method in LSPClient
// }

fn nop(ctx: *anyopaque) !void {
    _ = ctx;
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn deleteRanges(session: *Session, kind: WindowSource.DeleteRangesKind) !void {
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const active_window = wm.active_window orelse return;

    var handler = wm.wmap.get(active_window) orelse return;
    const result = try handler.source.deleteRanges(wm.a, active_window.cursor_manager, kind) orelse return;
    defer wm.a.free(result);

    for (handler.windows.keys()) |win| try win.processEditResult(wm.a, wm.qtree, result, wm.mall);
}

pub fn insertChars(session: *Session, chars: []const u8) !void {
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const active_window = wm.active_window orelse return;

    var handler = wm.wmap.get(active_window) orelse return;
    const result = try handler.source.insertChars(wm.a, chars, active_window.cursor_manager) orelse return;
    defer wm.a.free(result);

    for (handler.windows.keys()) |win| try win.processEditResult(wm.a, wm.qtree, result, wm.mall);
}

////////////////////////////////////////////////////////////////////////////////////////////// Inputs

///////////////////////////// Normal Mode

pub fn deleteInSingleQuote(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try deleteRanges(session, .in_single_quote);
}

pub fn deleteInWord(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try deleteRanges(session, .in_word);
}

pub fn deleteInWORD(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try deleteRanges(session, .in_WORD);
}

///////////////////////////// Visual Mode

pub fn enterVisualMode(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.activateRangeMode();
}

pub fn exitVisualMode(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.activatePointMode();
}

pub fn delete(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try deleteRanges(session, .range);
    try exitVisualMode(ctx);
}

///////////////////////////// Insert Mode

pub fn backspace(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try deleteRanges(session, .backspace);
}

pub fn enterInsertMode_i(ctx: *anyopaque) !void {
    _ = ctx;
}

pub fn enterInsertMode_I(ctx: *anyopaque) !void {
    try moveCursorToBeginningOfLine(ctx);
    try enterInsertMode_i(ctx);
}

pub fn enterInsertMode_a(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
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
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try insertChars(session, "\n");
}

pub fn enterInsertMode_O(ctx: *anyopaque) !void {
    try moveCursorToBeginningOfLine(ctx);
    try enterInsertMode_i(ctx);
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    try insertChars(session, "\n");
    try moveCursorUp(ctx);
}

pub fn exitInsertMode(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    // FIXME: if there were no edits, the flawed logic will cause bad frees
    try window.ws.buf.ropeman.registerLastPendingToHistory();
    window.cursor_manager.moveLeft(1, &window.ws.buf.ropeman);
}

///////////////////////////// Movement

// $ 0 ^

pub fn moveCursorToBeginningOfLine(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveToBeginningOfLine(&window.ws.buf.ropeman);
}

pub fn moveCursorToEndOfLine(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveToEndOfLine(&window.ws.buf.ropeman);
}

pub fn moveCursorToFirstNonSpaceCharacterOfLine(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveToFirstNonSpaceCharacterOfLine(&window.ws.buf.ropeman);
}

// hjkl

pub fn moveCursorUp(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveUp(1, &window.ws.buf.ropeman);
}

pub fn moveCursorDown(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveDown(1, &window.ws.buf.ropeman);
}

pub fn moveCursorLeft(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveLeft(1, &window.ws.buf.ropeman);
}

pub fn moveCursorRight(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.moveRight(1, &window.ws.buf.ropeman);
}

// Vim Word

pub fn moveCursorForwardWordStart(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.start, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardWordEnd(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.end, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorBackwardsWordStart(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.backwardsWord(.start, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardBIGWORDStart(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.start, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardBIGWORDEnd(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.forwardWord(.end, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorBackwardsBIGWORDStart(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const window = wm.active_window orelse return;
    window.cursor_manager.backwardsWord(.start, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

// yank to clipboard

pub fn yankVisualSeletionToClipboard(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
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

////////////////////////////////////////////////////////////////////////////////////////////// Combine callbacks into 1 mapping

fn map(sess: *Session, mode: []const u8, keys: []const Session.ip_.Key, funcs: []const Callback.F, contexts: Callback.Contexts) !void {
    try sess.council.map(mode, keys, try CombineCb.init(sess.council.arena.allocator(), sess, funcs, contexts));
}

const CombineCb = struct {
    ctx: *anyopaque,
    funcs: []const Callback.F,
    fn f(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        for (self.funcs) |func| {
            try func(self.ctx);
        }
    }
    fn init(allocator: std.mem.Allocator, ctx: *anyopaque, funcs: []const Callback.F, contexts: Callback.Contexts) !Session.Callback {
        const self = try allocator.create(@This());
        self.* = .{ .funcs = funcs, .ctx = ctx };
        return Session.Callback{ .f = @This().f, .ctx = self, .contexts = contexts };
    }
};
