// This file is part of Handmade Studio.

// This file was copied & modified from:
// repository: https://github.com/Aandreba/zigrc
// version:    0.4.0
// commit:     2acd7db3bcfce3d19ef1608ceb8017a7784663c4
// file(s):    src/root.zig

// MIT License
//
// Copyright (c) 2023 Alex Andreba
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//////////////////////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn TrimmedRc(comptime T: type, Count: type) type {
    return struct {
        value: *T,

        const Self = @This();
        const Inner = struct {
            count: Count,
            value: T,

            fn innerSize() comptime_int {
                return @sizeOf(@This());
            }

            fn innerAlign() comptime_int {
                return @alignOf(@This());
            }
        };

        pub fn init(a: Allocator, t: T) Allocator.Error!Self {
            const inner = try a.create(Inner);
            inner.* = Inner{ .count = 1, .value = t };
            return Self{ .value = &inner.value };
        }

        pub fn strongCount(self: *const Self) usize {
            return self.innerPtr().count;
        }

        pub fn retain(self: *Self) Self {
            self.innerPtr().count += 1;
            return self.*;
        }

        pub fn release(self: Self, a: Allocator) void {
            const ptr = self.innerPtr();
            ptr.count -= 1;
            if (ptr.count == 0) a.destroy(ptr);
        }

        pub fn innerSize() comptime_int {
            return Inner.innerSize();
        }

        pub fn innerAlign() comptime_int {
            return Inner.innerAlign();
        }

        inline fn innerPtr(self: *const Self) *Inner {
            return @alignCast(@fieldParentPtr("value", self.value));
        }
    };
}
