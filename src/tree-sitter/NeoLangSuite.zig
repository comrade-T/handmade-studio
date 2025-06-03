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

const NeoLangSuite = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ts = @import("bindings.zig");
pub const NeoStoredQuery = @import("NeoStoredQuery.zig");

pub const SupportedLanguages = enum { zig };

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
language: *const ts.Language,
queries: std.ArrayListUnmanaged(NeoStoredQuery) = .{},

//////////////////////////////////////////////////////////////////////////////////////////////

// TODO:
