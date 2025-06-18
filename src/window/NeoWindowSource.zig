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

////////////////////////////////////////////////////////////////////////////////////////////////

const NeoWindowSource = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const LangHub = @import("NeoLangHub");
const Orchestrator = @import("BufferOrchestrator");
const Buffer = Orchestrator.Buffer;

//////////////////////////////////////////////////////////////////////////////////////////////

buf: *Buffer,

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    const a = std.testing.allocator;
    var lang_hub = LangHub{ .a = a };
    defer lang_hub.deinit();

    var orchestrator = Orchestrator{ .a = a };
    defer orchestrator.deinit();

    {
        const buf = try orchestrator.createBufferFromString("const Allocator = std.mem.Allocator");
        try eq(true, try lang_hub.parseMainTree(buf, .{ .lang_choice = .zig }));

        // TODO: what else do I want to test?
        // - capturing stuffs
        // - iterate through those captures
    }
}
