const std = @import("std");

const Match = struct {
    score: i32,
    matches: []const usize,
    path_index: usize,

    pub fn moreThan(_: void, a: Match, b: Match) bool {
        return a.score > b.score;
    }
};

const StringSortCtx = struct {
    matches: []const Match,
    paths: []const []const u8,

    pub fn lessThan(self: StringSortCtx, a: Match, b: Match) bool {
        return std.mem.order(u8, self.paths[a.path_index], self.paths[b.path_index]) == .lt;
    }
};

test {
    // const sort_ctx = StringSortCtx{ .matches = self.match_list.items, .paths = self.path_list.items };
    // std.mem.sort(Match, self.match_list.items, sort_ctx, StringSortCtx.lessThan);
}
