const std = @import("std");

// Copied & Edited from https://github.com/ziglibs/treez

// TREE_SITTER_LANGUAGE_VERSION 14
// TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION 13

pub const Symbol = enum(u16) { _ };
pub const FieldId = enum(u16) { _ };
pub const StateId = enum(u16) { _ };

pub const InputEncoding = enum(c_uint) {
    utf_8,
    utf_16,
};

pub const SymbolType = enum(c_uint) {
    regular,
    anonymous,
    auxiliary,
};

pub const Point = extern struct {
    row: u32,
    column: u32,
};

pub const Range = extern struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,
};

pub const Input = extern struct {
    payload: ?*anyopaque,
    read: ?*const fn (payload: ?*anyopaque, byte_index: u32, position: Point, bytes_read: *u32) callconv(.C) [*:0]const u8,
    encoding: InputEncoding,
};

pub const LogType = enum(c_uint) {
    parse,
    lex,
};

pub const Logger = extern struct {
    context: ?*anyopaque,
    log_fn: ?*const fn (context: ?*anyopaque, log_type: LogType, log: [*:0]const u8) callconv(.C) void,
};

const StandardLogger = struct {
    fn log(context: ?*anyopaque, log_type: LogType, msg: [*:0]const u8) callconv(.C) void {
        _ = context;

        switch (log_type) {
            .lex => std.log.scoped(.tree_sitter_lex).debug("{s}", .{std.mem.span(msg)}),
            .parse => std.log.scoped(.tree_sitter_parse).debug("{s}", .{std.mem.span(msg)}),
        }
    }
};

pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

pub const Language = opaque {
    pub const GetError = error{Unknown};
    pub fn get(comptime language_name: []const u8) GetError!*const Language {
        const ext = @extern(?*const fn () callconv(.C) ?*const Language, .{
            .name = std.fmt.comptimePrint("tree_sitter_{s}", .{language_name}),
        }) orelse @compileError(std.fmt.comptimePrint("Cannot find extern tree_sitter_{s}", .{language_name}));

        return ext() orelse error.Unknown;
    }

    pub fn getSymbolCount(language: *const Language) u32 {
        return externs.ts_language_symbol_count(language);
    }

    pub fn getSymbolName(language: *const Language, symbol: Symbol) []const u8 {
        return std.mem.span(externs.ts_language_symbol_name(language, symbol));
    }

    pub fn getSymbolForName(language: *const Language, name: []const u8, is_named: bool) Symbol {
        return externs.ts_language_symbol_for_name(language, name.ptr, @as(u32, @intCast(name.len)), is_named);
    }

    pub fn getFieldCount(language: *const Language) u32 {
        return externs.ts_language_field_count(language);
    }

    pub fn getFieldNameForId(language: *const Language, field: FieldId) [*:0]const u8 {
        return std.mem.span(externs.ts_language_field_name_for_id(language, field));
    }

    pub fn getFieldIdForName(language: *const Language, name: []const u8) FieldId {
        return externs.ts_language_field_id_for_name(language, name.ptr, @as(u32, @intCast(name.len)));
    }

    pub fn getSymbolType(language: *const Language, symbol: Symbol) SymbolType {
        return externs.ts_language_symbol_type(language, symbol);
    }

    pub fn getLanguageVersion(language: *const Language) u32 {
        return externs.ts_language_version(language);
    }

    pub const externs = struct {
        pub extern fn ts_language_symbol_count(?*const Language) u32;
        pub extern fn ts_language_symbol_name(?*const Language, Symbol) [*:0]const u8;
        pub extern fn ts_language_symbol_for_name(self: ?*const Language, string: [*]const u8, length: u32, is_named: bool) Symbol;
        pub extern fn ts_language_field_count(?*const Language) u32;
        pub extern fn ts_language_field_name_for_id(?*const Language, FieldId) [*:0]const u8;
        pub extern fn ts_language_field_id_for_name(?*const Language, [*]const u8, u32) FieldId;
        pub extern fn ts_language_symbol_type(?*const Language, Symbol) SymbolType;
        pub extern fn ts_language_version(?*const Language) u32;
    };
};

pub const Parser = opaque {
    pub const InitError = error{Unknown};
    pub fn create() InitError!*Parser {
        return externs.ts_parser_new() orelse return error.Unknown;
    }

    pub fn destroy(parser: *Parser) void {
        externs.ts_parser_delete(parser);
    }

    pub const SetLanguageError = error{VersionMismatch};
    pub fn setLanguage(parser: *Parser, language: *const Language) SetLanguageError!void {
        if (!externs.ts_parser_set_language(parser, language)) return error.VersionMismatch;
    }

    pub fn getLanguage(parser: *const Parser) ?*const Language {
        return if (externs.ts_parser_language(parser)) |language| language else null;
    }

    pub const SetIncludedRangesError = error{Unknown};
    pub fn setIncludedRanges(parser: *Parser, ranges: []const Range) void {
        if (!externs.ts_parser_set_included_ranges(parser, ranges.ptr, @as(u32, @intCast(ranges.len))))
            return error.Unknown;
    }

    pub fn getIncludedRanges(parser: *const Parser) []const Range {
        var length: u32 = 0;
        return externs.ts_parser_included_ranges(parser, &length)[0..length];
    }

    pub const ParseError = error{ NoLanguage, Unknown };
    pub fn parse(parser: Parser, old_tree: ?*Tree, input: Input) ParseError!*Tree {
        return if (externs.ts_parser_parse(parser, old_tree, input)) |tree|
            tree
        else
            (if (parser.getLanguage()) |_|
                error.Unknown
            else
                error.NoLanguage);
    }

    pub fn parseString(parser: *Parser, old_tree: ?*Tree, string: []const u8) ParseError!*Tree {
        return if (externs.ts_parser_parse_string(parser, old_tree, string.ptr, @as(u32, @intCast(string.len)))) |tree|
            tree
        else
            (if (parser.getLanguage()) |_|
                error.Unknown
            else
                error.NoLanguage);
    }

    pub fn parseStringWithEncoding(parser: *Parser, old_tree: ?*Tree, string: []const u8, encoding: InputEncoding) ParseError!*Tree {
        return if (externs.ts_parser_parse_string(parser, old_tree, string.ptr, @as(u32, @intCast(string.len)), encoding)) |tree|
            tree
        else
            (if (parser.getLanguage()) |_|
                error.Unknown
            else
                error.NoLanguage);
    }

    pub fn reset(parser: *Parser) void {
        externs.ts_parser_reset(parser);
    }

    pub fn setTimeout(parser: *Parser, microseconds: u64) void {
        externs.ts_parser_set_timeout_micros(parser, microseconds);
    }

    pub fn getTimeout(parser: *const Parser) u64 {
        return externs.ts_parser_timeout_micros(parser);
    }

    pub fn setCancellationFlag(parser: *Parser, flag: ?*const usize) void {
        externs.ts_parser_set_cancellation_flag(parser, flag);
    }

    pub fn getCancellationFlag(parser: *const Parser) ?*const usize {
        return externs.ts_parser_cancellation_flag(parser);
    }

    pub fn setLogger(parser: *Parser, logger: Logger) void {
        externs.ts_parser_set_logger(parser, logger);
    }

    pub fn useStandardLogger(parser: *Parser) void {
        parser.setLogger(.{
            .context = @as(*anyopaque, @ptrCast(parser)),
            .log_fn = &StandardLogger.log,
        });
    }

    pub fn getLogger(parser: *const Parser) Logger {
        return externs.ts_parser_logger(parser);
    }

    pub fn printDotGraphs(parser: *Parser, file: std.fs.File) void {
        externs.ts_parser_print_dot_graphs(parser, file.handle);
    }

    pub const externs = struct {
        pub extern fn ts_parser_new() ?*Parser;
        pub extern fn ts_parser_delete(parser: ?*Parser) void;
        pub extern fn ts_parser_set_language(self: ?*Parser, language: ?*const Language) bool;
        pub extern fn ts_parser_language(self: ?*const Parser) ?*const Language;
        pub extern fn ts_parser_set_included_ranges(self: ?*Parser, ranges: [*]const Range, length: u32) bool;
        pub extern fn ts_parser_included_ranges(self: ?*const Parser, length: *u32) [*]const Range;
        pub extern fn ts_parser_parse(self: ?*Parser, old_tree: ?*const Tree, input: Input) ?*Tree;
        pub extern fn ts_parser_parse_string(self: ?*Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32) ?*Tree;
        pub extern fn ts_parser_parse_string_encoding(self: ?*Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32, encoding: InputEncoding) ?*Tree;
        pub extern fn ts_parser_reset(self: ?*Parser) void;
        pub extern fn ts_parser_set_timeout_micros(self: ?*Parser, timeout: u64) void;
        pub extern fn ts_parser_timeout_micros(self: ?*const Parser) u64;
        pub extern fn ts_parser_set_cancellation_flag(self: ?*Parser, flag: ?*const usize) void;
        pub extern fn ts_parser_cancellation_flag(self: ?*const Parser) ?*const usize;
        pub extern fn ts_parser_set_logger(self: ?*Parser, logger: Logger) void;
        pub extern fn ts_parser_logger(self: ?*const Parser) Logger;
        pub extern fn ts_parser_print_dot_graphs(self: ?*Parser, file: c_int) void;
    };
};

pub const Tree = opaque {
    pub const DupeError = error{Unknown};
    pub fn dupe(tree: *const Tree) DupeError!*Tree {
        return externs.ts_tree_copy(tree) orelse return error.Unknown;
    }

    pub fn destroy(tree: *Tree) void {
        externs.ts_tree_delete(tree);
    }

    pub fn getRootNode(tree: *const Tree) Node {
        return externs.ts_tree_root_node(tree);
    }

    pub fn getRootNodeWithOffset(tree: *const Tree, offset_bytes: u32, offset_point: Point) Node {
        return externs.ts_tree_root_node_with_offset(tree, offset_bytes, offset_point);
    }

    pub fn getLanguage(tree: *const Tree) *const Language {
        return externs.ts_tree_language(tree).?;
    }

    pub fn getIncludedRanges(tree: *const Tree) []const Range {
        var length: u32 = 0;
        return externs.ts_tree_included_ranges(tree, &length)[0..length];
    }

    /// Apply a text diff to the tree
    pub fn edit(tree: *Tree, the_edit: *const InputEdit) void {
        externs.ts_tree_edit(tree, the_edit);
    }

    pub fn getChangedRanges(old: *const Tree, new: *const Tree) []const Range {
        var length: u32 = 0;
        return externs.ts_tree_get_changed_ranges(old, new, &length)[0..length];
    }

    pub fn printDotGraph(tree: *const Tree, file: std.fs.File) void {
        externs.ts_tree_print_dot_graph(tree, file.handle);
    }

    pub const Cursor = extern struct {
        tree: ?*const anyopaque,
        id: ?*const anyopaque,
        context: [2]u32,

        pub fn create(node: Node) Cursor {
            return externs.ts_tree_cursor_new(node);
        }

        pub fn destroy(cursor: *Cursor) void {
            externs.ts_tree_cursor_delete(cursor);
        }

        pub fn reset(cursor: *Cursor, node: Node) void {
            return externs.ts_tree_cursor_reset(cursor, node);
        }

        pub fn getCurrentNode(cursor: *const Cursor) Node {
            return externs.ts_tree_cursor_current_node(cursor);
        }

        pub fn getCurrentFieldName(cursor: *const Cursor) []const u8 {
            return externs.ts_tree_cursor_current_field_name(cursor);
        }

        pub fn getCurrentFieldId(cursor: *const Cursor) FieldId {
            return externs.ts_tree_cursor_current_field_id(cursor);
        }

        /// Returns true on success
        pub fn gotoParent(cursor: *Cursor) bool {
            return externs.ts_tree_cursor_goto_parent(cursor);
        }

        /// Returns true on success
        pub fn gotoNextSibling(cursor: *Cursor) bool {
            return externs.ts_tree_cursor_goto_next_sibling(cursor);
        }

        /// Returns true on success
        pub fn gotoFirstChild(cursor: *Cursor) bool {
            return externs.ts_tree_cursor_goto_first_child(cursor);
        }

        pub fn gotoFirstChildForByte(cursor: *Cursor, byte: u32) bool {
            return if (externs.ts_tree_cursor_goto_first_child_for_byte(cursor, byte) == -1)
                false
            else
                true;
        }

        pub fn gotoFirstChildForPoint(cursor: *Cursor, point: Point) bool {
            return if (externs.ts_tree_cursor_goto_first_child_for_point(cursor, point) == -1)
                false
            else
                true;
        }

        pub fn dupe(cursor: *const Cursor) Cursor {
            return externs.ts_tree_cursor_copy(cursor);
        }
    };

    pub const externs = struct {
        pub extern fn ts_tree_copy(self: ?*const Tree) ?*Tree;
        pub extern fn ts_tree_delete(self: ?*Tree) void;
        pub extern fn ts_tree_root_node(self: ?*const Tree) Node;
        pub extern fn ts_tree_root_node_with_offset(self: ?*const Tree, offset_bytes: u32, offset_point: Point) Node;
        pub extern fn ts_tree_language(?*const Tree) ?*const Language;
        pub extern fn ts_tree_included_ranges(?*const Tree, length: *u32) [*]Range;
        pub extern fn ts_tree_edit(self: ?*Tree, edit: *const InputEdit) void;
        pub extern fn ts_tree_get_changed_ranges(old_tree: ?*const Tree, new_tree: ?*const Tree, length: *u32) [*]Range;
        pub extern fn ts_tree_print_dot_graph(?*const Tree, file_descriptor: c_int) void;

        pub extern fn ts_tree_cursor_new(Node) Cursor;
        pub extern fn ts_tree_cursor_delete(*Cursor) void;
        pub extern fn ts_tree_cursor_reset(*Cursor, Node) void;
        pub extern fn ts_tree_cursor_current_node(*const Cursor) Node;
        pub extern fn ts_tree_cursor_current_field_name(*const Cursor) [*:0]const u8;
        pub extern fn ts_tree_cursor_current_field_id(*const Cursor) FieldId;
        pub extern fn ts_tree_cursor_goto_parent(*Cursor) bool;
        pub extern fn ts_tree_cursor_goto_next_sibling(*Cursor) bool;
        pub extern fn ts_tree_cursor_goto_first_child(*Cursor) bool;
        pub extern fn ts_tree_cursor_goto_first_child_for_byte(*Cursor, u32) i64;
        pub extern fn ts_tree_cursor_goto_first_child_for_point(*Cursor, Point) i64;
        pub extern fn ts_tree_cursor_copy(*const Cursor) Cursor;
    };
};

pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,

    pub const ChildIterator = struct {
        node: Node,
        index: u32 = 0,

        pub fn next(iterator: ChildIterator) ?Node {
            defer iterator.index += 1;

            var maybe_child = iterator.node.getChild(iterator.index);
            return if (maybe_child.isNull())
                null
            else
                maybe_child;
        }
    };

    pub const NamedChildIterator = struct {
        node: Node,
        index: u32 = 0,

        pub fn next(iterator: NamedChildIterator) ?Node {
            defer iterator.index += 1;

            var maybe_child = iterator.node.getNamedChild(iterator.index);
            return if (maybe_child.isNull())
                null
            else
                maybe_child;
        }
    };

    pub fn getTree(node: Node) Tree {
        return node.tree.?;
    }

    pub fn getType(node: Node) []const u8 {
        return std.mem.span(externs.ts_node_type(node));
    }

    pub fn getSymbol(node: Node) Symbol {
        return externs.ts_node_symbol(node);
    }

    pub fn getStartByte(node: Node) u32 {
        return externs.ts_node_start_byte(node);
    }

    pub fn getStartPoint(node: Node) Point {
        return externs.ts_node_start_point(node);
    }

    pub fn getEndByte(node: Node) u32 {
        return externs.ts_node_end_byte(node);
    }

    pub fn getEndPoint(node: Node) Point {
        return externs.ts_node_end_point(node);
    }

    pub fn getRange(node: Node) Range {
        return .{
            .start_byte = node.getStartByte(),
            .start_point = node.getStartPoint(),
            .end_byte = node.getEndByte(),
            .end_point = node.getEndPoint(),
        };
    }

    /// Caller must call `freeSExpressionString` when done
    pub fn asSExpressionString(node: Node) []const u8 {
        return std.mem.span(externs.ts_node_string(node));
    }

    pub fn freeSExpressionString(str: []const u8) void {
        // TODO: Use allocator + set_allocator
        std.c.free(@as(*anyopaque, @ptrCast(@constCast(str.ptr))));
    }

    pub fn format(node: Node, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        const str = node.asSExpressionString();
        try writer.print("Node({s})", .{str});
        defer freeSExpressionString(str);
    }

    pub fn isNull(node: Node) bool {
        return externs.ts_node_is_null(node);
    }

    pub fn isNamed(node: Node) bool {
        return externs.ts_node_is_named(node);
    }

    pub fn isMissing(node: Node) bool {
        return externs.ts_node_is_missing(node);
    }

    pub fn isExtra(node: Node) bool {
        return externs.ts_node_is_extra(node);
    }

    pub fn hasChanges(node: Node) bool {
        return externs.ts_node_has_changes(node);
    }

    pub fn hasError(node: Node) bool {
        return externs.ts_node_has_error(node);
    }

    /// Remember to check with isNull (root)
    pub fn getParent(node: Node) Node {
        return externs.ts_node_parent(node);
    }

    /// Remember to check with isNull
    pub fn getChild(node: Node, child_index: u32) Node {
        return externs.ts_node_child(node, child_index);
    }

    /// NOTE: If you're iterating with this frequently,
    /// you should be using TreeCursor
    pub fn childIterator(node: Node) ChildIterator {
        return ChildIterator{ .node = node };
    }

    pub fn getFieldNameForChild(node: Node, child_index: u32) ?[]const u8 {
        return std.mem.span(externs.ts_node_field_name_for_child(node, child_index) orelse return null);
    }

    pub fn getChildCount(node: Node) u32 {
        return externs.ts_node_child_count(node);
    }

    /// Remember to check with isNull
    pub fn getNamedChild(node: Node, child_index: u32) Node {
        return externs.ts_node_named_child(node, child_index);
    }

    /// NOTE: If you're iterating with this frequently,
    /// you should be using TreeCursor
    pub fn namedChildIterator(node: Node) NamedChildIterator {
        return NamedChildIterator{ .node = node };
    }

    pub fn getNamedChildCount(node: Node) u32 {
        return externs.ts_node_named_child_count(node);
    }

    /// Remember to check with isNull
    pub fn getChildByFieldName(node: Node, field_name: []const u8) Node {
        return externs.ts_node_child_by_field_name(node, field_name.ptr, @as(u32, @intCast(field_name.len)));
    }

    /// Remember to check with isNull
    pub fn getChildByFieldId(node: Node, field_id: FieldId) Node {
        return externs.ts_node_child_by_field_name(node, field_id);
    }

    // TODO: Sibling iterators

    pub fn nextSibling(node: Node) Node {
        return externs.ts_node_next_sibling(node);
    }

    pub fn prevSibling(node: Node) Node {
        return externs.ts_node_prev_sibling(node);
    }

    pub fn nextNamedSibling(node: Node) Node {
        return externs.ts_node_next_named_sibling(node);
    }

    pub fn prevNamedSibling(node: Node) Node {
        return externs.ts_node_prev_named_sibling(node);
    }

    /// Apply a text diff to the node
    pub fn edit(node: *Node, the_edit: *const InputEdit) void {
        externs.ts_node_edit(node, the_edit);
    }

    pub fn eql(a: Node, b: Node) bool {
        return externs.ts_node_eq(a, b);
    }

    pub fn parseState(node: Node) StateId {
        return externs.ts_node_parse_state(node);
    }

    pub const externs = struct {
        pub extern fn ts_node_type(Node) [*:0]const u8;
        pub extern fn ts_node_symbol(Node) Symbol;
        pub extern fn ts_node_start_byte(Node) u32;
        pub extern fn ts_node_start_point(Node) Point;
        pub extern fn ts_node_end_byte(Node) u32;
        pub extern fn ts_node_end_point(Node) Point;
        pub extern fn ts_node_string(Node) [*:0]u8;
        pub extern fn ts_node_is_null(Node) bool;
        pub extern fn ts_node_is_named(Node) bool;
        pub extern fn ts_node_is_missing(Node) bool;
        pub extern fn ts_node_is_extra(Node) bool;
        pub extern fn ts_node_has_changes(Node) bool;
        pub extern fn ts_node_has_error(Node) bool;
        pub extern fn ts_node_parent(Node) Node;
        pub extern fn ts_node_child(Node, u32) Node;
        pub extern fn ts_node_field_name_for_child(Node, u32) ?[*:0]const u8;
        pub extern fn ts_node_child_count(Node) u32;
        pub extern fn ts_node_named_child(Node, u32) Node;
        pub extern fn ts_node_named_child_count(Node) u32;
        pub extern fn ts_node_child_by_field_name(self: Node, field_name: [*]const u8, field_name_length: u32) Node;
        pub extern fn ts_node_child_by_field_id(Node, FieldId) Node;
        pub extern fn ts_node_next_sibling(Node) Node;
        pub extern fn ts_node_prev_sibling(Node) Node;
        pub extern fn ts_node_next_named_sibling(Node) Node;
        pub extern fn ts_node_prev_named_sibling(Node) Node;
        pub extern fn ts_node_first_child_for_byte(Node, u32) Node;
        pub extern fn ts_node_first_named_child_for_byte(Node, u32) Node;
        pub extern fn ts_node_descendant_for_byte_range(Node, u32, u32) Node;
        pub extern fn ts_node_descendant_for_point_range(Node, Point, Point) Node;
        pub extern fn ts_node_named_descendant_for_byte_range(Node, u32, u32) Node;
        pub extern fn ts_node_named_descendant_for_point_range(Node, Point, Point) Node;
        pub extern fn ts_node_edit(*Node, *const InputEdit) void;
        pub extern fn ts_node_eq(Node, Node) bool;

        pub extern fn ts_node_parse_state(Node) StateId;
    };
};

pub const Query = opaque {
    pub const Quantifier = enum(c_uint) {
        zero,
        zero_or_one,
        zero_or_more,
        one,
        one_or_more,
    };

    pub const PredicateStep = extern struct {
        pub const Type = enum(c_uint) {
            done,
            capture,
            string,
        };

        type: Type,
        value_id: u32,
    };

    const ErrorValues = enum(c_uint) {
        none,
        syntax,
        node_type,
        field,
        capture,
        structure,
        language,
    };

    pub const CreateError = error{
        InvalidSyntax,
        InvalidNodeType,
        InvalidField,
        InvalidCapture,
        InvalidStructure,
        InvalidLanguage,
    };

    pub fn create(
        language: *const Language,
        source: []const u8,
    ) CreateError!*Query {
        var error_offset: u32 = 0;
        var error_type: ErrorValues = .none;

        return if (externs.ts_query_new(language, source.ptr, @as(u32, @intCast(source.len)), &error_offset, &error_type)) |query|
            query
        else switch (error_type) {
            .none => unreachable,
            .syntax => error.InvalidSyntax,
            .node_type => error.InvalidNodeType,
            .field => error.InvalidField,
            .capture => error.InvalidCapture,
            .structure => error.InvalidStructure,
            .language => error.InvalidLanguage,
        };
    }

    pub fn destroy(query: *Query) void {
        externs.ts_query_delete(query);
    }

    pub fn getPatternCount(query: *const Query) u32 {
        return externs.ts_query_pattern_count(query);
    }

    pub fn getCaptureCount(query: *const Query) u32 {
        return externs.ts_query_capture_count(query);
    }

    pub fn getStringCount(query: *const Query) u32 {
        return externs.ts_query_string_count(query);
    }

    pub fn getStartByteForPattern(query: *const Query, pattern_index: u32) u32 {
        return externs.ts_query_start_byte_for_pattern(query, pattern_index);
    }

    pub fn getEndByteForPattern(query: *const Query, pattern_index: u32) u32 {
        return externs.ts_query_end_byte_for_pattern(query, pattern_index);
    }

    pub fn getPredicatesForPattern(query: *const Query, pattern_index: u32) []const PredicateStep {
        var len: u32 = 0;
        return externs.ts_query_predicates_for_pattern(query, pattern_index, &len)[0..len];
    }

    pub fn isPatternRooted(query: *const Query, pattern_index: u32) bool {
        return externs.ts_query_is_pattern_rooted(query, pattern_index);
    }

    pub fn isPatternNonLocal(query: *const Query, pattern_index: u32) bool {
        return externs.ts_query_is_pattern_non_local(query, pattern_index);
    }

    pub fn isPatternGuaranteedAtStep(query: *const Query, byte_offset: u32) bool {
        return externs.ts_query_is_pattern_guaranteed_at_step(query, byte_offset);
    }

    pub fn getCaptureNameForId(query: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        return externs.ts_query_capture_name_for_id(query, id, &len)[0..len];
    }

    pub fn getCaptureQuantifierForId(query: *const Query, pattern_id: u32, capture_id: u32) Quantifier {
        return externs.ts_query_capture_quantifier_for_id(query, pattern_id, capture_id);
    }

    pub fn getStringValueForId(query: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        return externs.ts_query_string_value_for_id(query, id, &len)[0..len];
    }

    pub fn disableCapture(query: *Query, capture: []const u8) void {
        externs.ts_query_disable_capture(query, capture.ptr, @as(u32, @intCast(capture.len)));
    }

    pub fn disablePattern(query: *Query, pattern_index: u32) void {
        externs.ts_query_disable_pattern(query, pattern_index);
    }

    pub const Match = extern struct {
        id: u32,
        pattern_index: u16,
        captures_len: u16,
        captures_ptr: [*]const Capture,

        pub fn captures(match: Match) []const Capture {
            return match.captures_ptr[0..match.captures_len];
        }
    };

    pub const Capture = extern struct {
        node: Node,
        id: u32,
    };

    pub const Cursor = opaque {
        pub const CursorCreateError = error{Unknown};
        pub fn create() CursorCreateError!*Cursor {
            return externs.ts_query_cursor_new() orelse return error.Unknown;
        }

        pub fn destroy(cursor: *Cursor) void {
            externs.ts_query_cursor_delete(cursor);
        }

        pub fn execute(cursor: *Cursor, query: *const Query, node: Node) void {
            externs.ts_query_cursor_exec(cursor, query, node);
        }

        pub fn didExceedMatchLimit(cursor: *const Cursor) bool {
            return externs.ts_query_cursor_did_exceed_match_limit(cursor);
        }

        pub fn getMatchLimit(cursor: *const Cursor) u32 {
            return externs.ts_query_cursor_match_limit(cursor);
        }

        pub fn setMatchLimit(cursor: *Cursor, limit: u32) void {
            externs.ts_query_cursor_set_match_limit(cursor, limit);
        }

        pub fn setByteRange(cursor: *Cursor, start: u32, end: u32) void {
            externs.ts_query_cursor_set_byte_range(cursor, start, end);
        }

        pub fn setPointRange(cursor: *Cursor, start: Point, end: Point) void {
            externs.ts_query_cursor_set_point_range(cursor, start, end);
        }

        pub fn nextMatch(cursor: *Cursor) ?Match {
            var match: Query.Match = undefined;
            return if (externs.ts_query_cursor_next_match(cursor, &match))
                match
            else
                null;
        }

        pub fn removeMatch(cursor: Cursor, id: u32) void {
            externs.ts_query_cursor_remove_match(cursor, id);
        }

        pub fn nextCapture(cursor: *Cursor) ?struct { Query.Match, u32 } {
            var match: Query.Match = undefined;
            var capture_index: u32 = 0;
            return if (externs.ts_query_cursor_next_capture(cursor, &match, &capture_index))
                .{ match, capture_index }
            else
                null;
        }
    };

    pub const externs = struct {
        pub extern fn ts_query_new(language: ?*const Language, source: [*]const u8, source_len: u32, error_offset: *u32, error_type: *Query.ErrorValues) ?*Query;
        pub extern fn ts_query_delete(?*Query) void;
        pub extern fn ts_query_pattern_count(?*const Query) u32;
        pub extern fn ts_query_capture_count(?*const Query) u32;
        pub extern fn ts_query_string_count(?*const Query) u32;
        pub extern fn ts_query_start_byte_for_pattern(?*const Query, u32) u32;
        pub extern fn ts_query_predicates_for_pattern(self: ?*const Query, pattern_index: u32, length: *u32) [*]const PredicateStep;
        pub extern fn ts_query_is_pattern_rooted(self: ?*const Query, pattern_index: u32) bool;
        pub extern fn ts_query_is_pattern_non_local(self: ?*const Query, pattern_index: u32) bool;
        pub extern fn ts_query_is_pattern_guaranteed_at_step(self: ?*const Query, byte_offset: u32) bool;
        pub extern fn ts_query_capture_name_for_id(?*const Query, id: u32, length: *u32) [*]const u8;
        pub extern fn ts_query_capture_quantifier_for_id(?*const Query, pattern_id: u32, capture_id: u32) Quantifier;
        pub extern fn ts_query_string_value_for_id(?*const Query, id: u32, length: *u32) [*]const u8;
        pub extern fn ts_query_disable_capture(?*Query, [*]const u8, u32) void;
        pub extern fn ts_query_disable_pattern(?*Query, u32) void;

        pub extern fn ts_query_cursor_new() ?*Query.Cursor;
        pub extern fn ts_query_cursor_delete(?*Query.Cursor) void;
        pub extern fn ts_query_cursor_exec(?*Query.Cursor, ?*const Query, Node) void;
        pub extern fn ts_query_cursor_did_exceed_match_limit(?*const Query.Cursor) bool;
        pub extern fn ts_query_cursor_match_limit(?*const Query.Cursor) u32;
        pub extern fn ts_query_cursor_set_match_limit(?*Query.Cursor, u32) void;
        pub extern fn ts_query_cursor_set_byte_range(?*Query.Cursor, u32, u32) void;
        pub extern fn ts_query_cursor_set_point_range(?*Query.Cursor, Point, Point) void;
        pub extern fn ts_query_cursor_next_match(?*Query.Cursor, match: *Query.Match) bool;
        pub extern fn ts_query_cursor_remove_match(?*Query.Cursor, id: u32) void;
        pub extern fn ts_query_cursor_next_capture(?*Query.Cursor, match: *Query.Match, capture_index: *u32) bool;
    };
};

// TODO: set allocator model; not compatible with Zig's as free doesn't take a length
// pub extern fn ts_set_allocator(new_malloc: ?*const fn (usize) callconv(.C) ?*anyopaque, new_calloc: ?*const fn (usize, usize) callconv(.C) ?*anyopaque, new_realloc: ?*const fn (?*anyopaque, usize) callconv(.C) ?*anyopaque, new_free: ?*const fn (?*anyopaque) callconv(.C) void) void;

// Higher level constructs

pub const CursorWithValidation = struct {
    // We only support #eq?

    pub const EqualPredicate = struct {
        a: []const u8,
        b: union(enum) { string: []const u8, capture: []const u8 },
    };

    pub const PredicateList = std.ArrayListUnmanaged(EqualPredicate);
    pub const PredicateMap = std.AutoHashMapUnmanaged(u32, packed struct { index: u32, len: u32 });

    pub const CaptureIdNameMap = std.StringHashMapUnmanaged(u32);

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
                if (!std.mem.eql(u8, query.getStringValueForId(@as(u32, @intCast(preds[index].value_id))), "eq?")) @panic("Only the 'eq?' predicate is supported by treez at the moment.");
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
