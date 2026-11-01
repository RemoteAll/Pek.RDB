// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    UnsupportedStatement,
    UnsupportedType,
    InvalidNumber,
} || std.mem.Allocator.Error;

// ---------------- 词法 ----------------

pub const TokenTag = enum {
    eof,
    ident,
    string,
    number,
    lparen,
    rparen,
    comma,
    semicolon,
    star,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    minus,
    plus,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    pub fn next(self: *Lexer) Error!Token {
        self.skipSpace();
        if (self.pos >= self.src.len) return .{ .tag = .eof, .text = "" };
        const c = self.src[self.pos];
        switch (c) {
            '(' => {
                self.pos += 1;
                return .{ .tag = .lparen, .text = "(" };
            },
            ')' => {
                self.pos += 1;
                return .{ .tag = .rparen, .text = ")" };
            },
            ',' => {
                self.pos += 1;
                return .{ .tag = .comma, .text = "," };
            },
            ';' => {
                self.pos += 1;
                return .{ .tag = .semicolon, .text = ";" };
            },
            '*' => {
                self.pos += 1;
                return .{ .tag = .star, .text = "*" };
            },
            '+' => {
                self.pos += 1;
                return .{ .tag = .plus, .text = "+" };
            },
            '-' => {
                self.pos += 1;
                return .{ .tag = .minus, .text = "-" };
            },
            '=' => {
                self.pos += 1;
                return .{ .tag = .eq, .text = "=" };
            },
            '<' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .tag = .le, .text = "<=" };
                }
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                    self.pos += 2;
                    return .{ .tag = .ne, .text = "<>" };
                }
                self.pos += 1;
                return .{ .tag = .lt, .text = "<" };
            },
            '>' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .tag = .ge, .text = ">=" };
                }
                self.pos += 1;
                return .{ .tag = .gt, .text = ">" };
            },
            '!' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .tag = .ne, .text = "!=" };
                }
                return error.UnexpectedToken;
            },
            '\'' => return self.lexString(),
            '"', '`' => return self.lexQuotedIdent(c),
            '[' => return self.lexBracketIdent(),
            else => {},
        }
        if (std.ascii.isAlphabetic(c) or c == '_') return self.lexIdent();
        if (std.ascii.isDigit(c)) return self.lexNumber();
        return error.UnexpectedToken;
    }

    fn lexIdent(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
                self.pos += 1;
            } else break;
        }
        return .{ .tag = .ident, .text = self.src[start..self.pos] };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }
        return .{ .tag = .number, .text = self.src[start..self.pos] };
    }

    fn lexString(self: *Lexer) Error!Token {
        self.pos += 1; // '
        const start = self.pos;
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '\'') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                    self.pos += 2;
                    continue;
                }
                const text = self.src[start..self.pos];
                self.pos += 1;
                return .{ .tag = .string, .text = text };
            }
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }

    fn lexQuotedIdent(self: *Lexer, quote: u8) Error!Token {
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == quote) {
                const text = self.src[start..self.pos];
                self.pos += 1;
                return .{ .tag = .ident, .text = text };
            }
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }

    fn lexBracketIdent(self: *Lexer) Error!Token {
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == ']') {
                const text = self.src[start..self.pos];
                self.pos += 1;
                return .{ .tag = .ident, .text = text };
            }
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }
};

// ---------------- AST ----------------

pub const ColumnType = enum { integer, bigint, real, double, text, blob, boolean, datetime };

pub const ColumnDef = struct {
    name: []const u8,
    col_type: ColumnType,
    primary_key: bool = false,
    auto_increment: bool = false,
    not_null: bool = false,
};

pub const CreateTable = struct {
    if_not_exists: bool = false,
    name: []const u8,
    columns: []ColumnDef,
};

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const Insert = struct {
    or_replace: bool = false,
    table: []const u8,
    columns: []const []const u8,
    rows: []const []Value,
};

pub const SelectItem = union(enum) {
    star,
    column: []const u8,
    /// 聚合：`COUNT(*)` / `COUNT(col)` / `SUM(col)` / `AVG(col)` / `MIN(col)` / `MAX(col)`。
    aggregate: Agg,
};

/// 聚合函数。只支持这五个；`GROUP BY` 之外用它们时整表当作一个组（SQL 语义）。
pub const AggFunc = enum {
    count,
    sum,
    avg,
    min,
    max,

    /// 规范名（全小写）：既是输出列名的前缀，也是 `ORDER BY` 匹配的键。
    pub fn name(self: AggFunc) []const u8 {
        return @tagName(self);
    }
};

pub const Agg = struct {
    func: AggFunc,
    /// `null` 只允许给 `COUNT(*)`（其余非法的在解析阶段就拒掉）。
    column: ?[]const u8 = null,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge };

pub const Expr = struct {
    column: []const u8,
    op: CmpOp,
    value: Value,
};

pub const OrderItem = struct {
    column: []const u8,
    desc: bool = false,
};

/// `HAVING <聚合> <op> <常量>`。
///
/// 只支持这个形状：`HAVING` 的真需求就是「按聚合结果过滤组」（`HAVING COUNT(*) > 1`、
/// `HAVING SUM(x) > n`），做成通用表达式树要先有表达式求值，而我们的 `WHERE`
/// 也只支持单列比较 —— 两边保持一致，不引入半成品。
pub const Having = struct {
    agg: Agg,
    op: CmpOp,
    value: Value,
};

pub const Select = struct {
    items: []SelectItem,
    table: []const u8,
    where: ?Expr = null,
    /// `GROUP BY` 列（按书写顺序）；为空且含聚合时整表一个组。
    group_by: [][]const u8 = &.{},
    /// 分组后的过滤（作用在聚合结果上，不是原始行）。
    having: ?Having = null,
    order_by: []OrderItem = &.{},
    limit: ?u32 = null,
    offset: ?u32 = null,
};

pub const Assign = struct {
    column: []const u8,
    value: Value,
};
pub const Update = struct {
    table: []const u8,
    assignments: []Assign,
    where: ?Expr = null,
};

pub const Delete = struct {
    table: []const u8,
    where: ?Expr = null,
};

pub const Statement = union(enum) {
    create_table: CreateTable,
    insert: Insert,
    select: Select,
    update: Update,
    delete: Delete,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    stmt: Statement,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// ---------------- 语法 ----------------

const Parser = struct {
    arena: std.mem.Allocator,
    lexer: Lexer,
    tok: Token = .{ .tag = .eof, .text = "" },

    /// SQL 字符串字面量里的 '' 表示一个单引号；复制到 arena 时还原。
    fn dupUnescaped(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
        if (std.mem.indexOf(u8, text, "''") == null) return arena.dupe(u8, text);
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                try out.append(arena, '\'');
                i += 1;
            } else {
                try out.append(arena, text[i]);
            }
        }
        return out.toOwnedSlice(arena);
    }

    fn advance(self: *Parser) Error!void {
        self.tok = try self.lexer.next();
    }

    fn isKw(tok: Token, kw: []const u8) bool {
        return tok.tag == .ident and std.ascii.eqlIgnoreCase(tok.text, kw);
    }

    fn acceptKw(self: *Parser, kw: []const u8) Error!bool {
        if (isKw(self.tok, kw)) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn expectKw(self: *Parser, kw: []const u8) Error!void {
        if (!try self.acceptKw(kw)) return error.UnexpectedToken;
    }

    fn expectTag(self: *Parser, tag: TokenTag) Error!Token {
        if (self.tok.tag != tag) return error.UnexpectedToken;
        const t = self.tok;
        try self.advance();
        return t;
    }

    fn parseIdent(self: *Parser) Error![]const u8 {
        const t = try self.expectTag(.ident);
        return self.arena.dupe(u8, t.text);
    }

    fn parseType(text: []const u8) Error!ColumnType {
        const map = .{
            .{ "integer", ColumnType.integer },
            .{ "int", ColumnType.integer },
            .{ "bigint", ColumnType.bigint },
            .{ "real", ColumnType.real },
            .{ "double", ColumnType.double },
            .{ "float", ColumnType.double },
            .{ "text", ColumnType.text },
            .{ "varchar", ColumnType.text },
            .{ "string", ColumnType.text },
            .{ "blob", ColumnType.blob },
            .{ "boolean", ColumnType.boolean },
            .{ "bool", ColumnType.boolean },
            .{ "datetime", ColumnType.datetime },
        };
        inline for (map) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }
        return error.UnsupportedType;
    }

    fn parseValue(self: *Parser) Error!Value {
        switch (self.tok.tag) {
            .string => {
                const t = self.tok;
                try self.advance();
                return .{ .text = try dupUnescaped(self.arena, t.text) };
            },
            .number => {
                const t = self.tok;
                try self.advance();
                if (std.mem.indexOfScalar(u8, t.text, '.') != null) {
                    return .{ .real = std.fmt.parseFloat(f64, t.text) catch return error.InvalidNumber };
                }
                return .{ .integer = std.fmt.parseInt(i64, t.text, 10) catch return error.InvalidNumber };
            },
            .minus => {
                try self.advance();
                const t = try self.expectTag(.number);
                return .{ .integer = -(std.fmt.parseInt(i64, t.text, 10) catch return error.InvalidNumber) };
            },
            .ident => {
                if (isKw(self.tok, "null")) {
                    try self.advance();
                    return .null;
                }
                if (isKw(self.tok, "true")) {
                    try self.advance();
                    return .{ .integer = 1 };
                }
                if (isKw(self.tok, "false")) {
                    try self.advance();
                    return .{ .integer = 0 };
                }
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseCreateTable(self: *Parser) Error!Statement {
        try self.expectKw("create");
        try self.expectKw("table");
        var if_not_exists = false;
        if (try self.acceptKw("if")) {
            try self.expectKw("not");
            try self.expectKw("exists");
            if_not_exists = true;
        }
        const name = try self.parseIdent();
        _ = try self.expectTag(.lparen);

        var cols: std.ArrayList(ColumnDef) = .empty;
        const a = self.arena;
        while (true) {
            const col_name = try self.parseIdent();
            const ty_text = try self.parseIdent();
            var col = ColumnDef{
                .name = col_name,
                .col_type = try parseType(ty_text),
            };
            while (true) {
                if (try self.acceptKw("primary")) {
                    try self.expectKw("key");
                    col.primary_key = true;
                    if (try self.acceptKw("autoincrement")) col.auto_increment = true;
                } else if (try self.acceptKw("not")) {
                    try self.expectKw("null");
                    col.not_null = true;
                } else if (try self.acceptKw("default")) {
                    _ = try self.parseValue();
                } else break;
            }
            try cols.append(a, col);

            if (self.tok.tag == .comma) {
                try self.advance();
                continue;
            }
            break;
        }
        _ = try self.expectTag(.rparen);

        const columns = try a.dupe(ColumnDef, cols.items);
        cols.deinit(a);

        var pk_count: usize = 0;
        for (columns) |c| {
            if (c.primary_key) pk_count += 1;
        }
        if (pk_count != 1) return error.UnexpectedToken;

        return .{ .create_table = .{
            .if_not_exists = if_not_exists,
            .name = name,
            .columns = columns,
        } };
    }

    fn parseInsert(self: *Parser) Error!Statement {
        try self.expectKw("insert");
        var or_replace = false;
        if (try self.acceptKw("or")) {
            try self.expectKw("replace");
            or_replace = true;
        }
        try self.expectKw("into");
        const table = try self.parseIdent();

        var columns: []const []const u8 = &.{};
        if (self.tok.tag == .lparen) {
            try self.advance();
            var list: std.ArrayList([]const u8) = .empty;
            while (true) {
                try list.append(self.arena, try self.parseIdent());
                if (self.tok.tag == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expectTag(.rparen);
            columns = try self.arena.dupe([]const u8, list.items);
            list.deinit(self.arena);
        }

        try self.expectKw("values");
        var rows: std.ArrayList([]Value) = .empty;
        while (true) {
            _ = try self.expectTag(.lparen);
            var vals: std.ArrayList(Value) = .empty;
            while (true) {
                try vals.append(self.arena, try self.parseValue());
                if (self.tok.tag == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            _ = try self.expectTag(.rparen);
            try rows.append(self.arena, try self.arena.dupe(Value, vals.items));
            vals.deinit(self.arena);

            if (self.tok.tag == .comma) {
                try self.advance();
                continue;
            }
            break;
        }

        return .{ .insert = .{
            .or_replace = or_replace,
            .table = table,
            .columns = columns,
            .rows = try self.arena.dupe([]Value, rows.items),
        } };
    }

    fn parseExpr(self: *Parser) Error!Expr {
        const column = try self.parseIdent();
        const op: CmpOp = switch (self.tok.tag) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => return error.UnexpectedToken,
        };
        try self.advance();
        return .{ .column = column, .op = op, .value = try self.parseValue() };
    }

    fn parseAggFunc(text: []const u8) ?AggFunc {
        const map = .{
            .{ "count", AggFunc.count },
            .{ "sum", AggFunc.sum },
            .{ "avg", AggFunc.avg },
            .{ "min", AggFunc.min },
            .{ "max", AggFunc.max },
        };
        inline for (map) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }
        return null;
    }

    /// 一个选择项：`*` / 列名 / 聚合调用。
    ///
    /// 聚合的识别方式是「标识符后面紧跟 `(`」—— 与 SQLite 一致（函数名不是关键字）。
    /// 未知函数名不当作列名硬吞：报 `UnsupportedStatement`，否则
    /// `SELECT nosuchfunc(x) FROM t` 会被误解析成两列。
    fn parseSelectItem(self: *Parser) Error!SelectItem {
        if (self.tok.tag == .star) {
            try self.advance();
            return .star;
        }
        const name = try self.parseIdent();
        if (self.tok.tag != .lparen) return .{ .column = name };

        const func = parseAggFunc(name) orelse return error.UnsupportedStatement;
        try self.advance(); // (
        var col: ?[]const u8 = null;
        if (self.tok.tag == .star) {
            // 只有 COUNT(*) 合法：`SUM(*)` / `AVG(*)` 没有意义
            if (func != .count) return error.UnsupportedStatement;
            try self.advance();
        } else {
            col = try self.parseIdent();
        }
        _ = try self.expectTag(.rparen);
        return .{ .aggregate = .{ .func = func, .column = col } };
    }

    /// `ORDER BY` 的排序键：列名或聚合表达式。
    ///
    /// 聚合表达式归一成与**输出列名**相同的文本（`count(*)` / `sum(x)`），
    /// 这样 `selectGrouped` 排序时只需按列名匹配，不必再写一套表达式比较。
    fn parseOrderTarget(self: *Parser) Error![]const u8 {
        const name = try self.parseIdent();
        if (self.tok.tag != .lparen) return name;

        const func = parseAggFunc(name) orelse return error.UnsupportedStatement;
        try self.advance(); // (
        var col: ?[]const u8 = null;
        if (self.tok.tag == .star) {
            if (func != .count) return error.UnsupportedStatement;
            try self.advance();
        } else {
            col = try self.parseIdent();
        }
        _ = try self.expectTag(.rparen);
        return if (col) |c|
            try std.fmt.allocPrint(self.arena, "{s}({s})", .{ func.name(), c })
        else
            try std.fmt.allocPrint(self.arena, "{s}(*)", .{func.name()});
    }

    fn parseHaving(self: *Parser) Error!Having {
        const name = try self.parseIdent();
        const func = parseAggFunc(name) orelse return error.UnsupportedStatement;
        _ = try self.expectTag(.lparen);
        var col: ?[]const u8 = null;
        if (self.tok.tag == .star) {
            if (func != .count) return error.UnsupportedStatement;
            try self.advance();
        } else {
            col = try self.parseIdent();
        }
        _ = try self.expectTag(.rparen);

        const op: CmpOp = switch (self.tok.tag) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => return error.UnexpectedToken,
        };
        try self.advance();
        return .{ .agg = .{ .func = func, .column = col }, .op = op, .value = try self.parseValue() };
    }

    fn parseSelect(self: *Parser) Error!Statement {
        try self.expectKw("select");
        var items: std.ArrayList(SelectItem) = .empty;
        while (true) {
            try items.append(self.arena, try self.parseSelectItem());
            if (self.tok.tag == .comma) {
                try self.advance();
                continue;
            }
            break;
        }

        try self.expectKw("from");
        const table = try self.parseIdent();

        var sel = Select{
            .items = try self.arena.dupe(SelectItem, items.items),
            .table = table,
        };
        items.deinit(self.arena);

        if (try self.acceptKw("where")) {
            sel.where = try self.parseExpr();
        }

        if (try self.acceptKw("group")) {
            try self.expectKw("by");
            var gb: std.ArrayList([]const u8) = .empty;
            while (true) {
                try gb.append(self.arena, try self.parseIdent());
                if (self.tok.tag == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            sel.group_by = try self.arena.dupe([]const u8, gb.items);
            gb.deinit(self.arena);
        }

        if (try self.acceptKw("having")) {
            sel.having = try self.parseHaving();
        }

        if (try self.acceptKw("order")) {
            try self.expectKw("by");
            var order: std.ArrayList(OrderItem) = .empty;
            while (true) {
                var item = OrderItem{ .column = try self.parseOrderTarget() };
                if (try self.acceptKw("desc")) {
                    item.desc = true;
                } else {
                    _ = try self.acceptKw("asc");
                }
                try order.append(self.arena, item);
                if (self.tok.tag == .comma) {
                    try self.advance();
                    continue;
                }
                break;
            }
            sel.order_by = try self.arena.dupe(OrderItem, order.items);
            order.deinit(self.arena);
        }

        if (try self.acceptKw("limit")) {
            const t = try self.expectTag(.number);
            sel.limit = std.fmt.parseInt(u32, t.text, 10) catch return error.InvalidNumber;
            if (try self.acceptKw("offset")) {
                const o = try self.expectTag(.number);
                sel.offset = std.fmt.parseInt(u32, o.text, 10) catch return error.InvalidNumber;
            }
        }

        return .{ .select = sel };
    }

    fn parseUpdate(self: *Parser) Error!Statement {
        try self.expectKw("update");
        const table = try self.parseIdent();
        try self.expectKw("set");
        var assigns: std.ArrayList(Assign) = .empty;
        while (true) {
            const col = try self.parseIdent();
            if (self.tok.tag != .eq) return error.UnexpectedToken;
            try self.advance();
            try assigns.append(self.arena, .{ .column = col, .value = try self.parseValue() });
            if (self.tok.tag == .comma) {
                try self.advance();
                continue;
            }
            break;
        }
        var upd = Update{
            .table = table,
            .assignments = try self.arena.dupe(Assign, assigns.items),
        };
        assigns.deinit(self.arena);
        if (try self.acceptKw("where")) upd.where = try self.parseExpr();
        return .{ .update = upd };
    }

    fn parseDelete(self: *Parser) Error!Statement {
        try self.expectKw("delete");
        try self.expectKw("from");
        const table = try self.parseIdent();
        var del = Delete{ .table = table };
        if (try self.acceptKw("where")) del.where = try self.parseExpr();
        return .{ .delete = del };
    }

    fn parseStatement(self: *Parser) Error!Statement {
        if (isKw(self.tok, "create")) return self.parseCreateTable();
        if (isKw(self.tok, "insert")) return self.parseInsert();
        if (isKw(self.tok, "select")) return self.parseSelect();
        if (isKw(self.tok, "update")) return self.parseUpdate();
        if (isKw(self.tok, "delete")) return self.parseDelete();
        return error.UnsupportedStatement;
    }
};

/// 解析一条 SQL；AST 由内部 arena 持有，调用方负责 `deinit`。src 需在 AST 使用期间有效。
pub fn parse(alloc: std.mem.Allocator, src: []const u8) Error!Parsed {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    var p = Parser{ .arena = arena.allocator(), .lexer = .{ .src = src } };
    try p.advance();
    const stmt = try p.parseStatement();

    if (p.tok.tag == .semicolon) try p.advance();
    if (p.tok.tag != .eof) return error.UnexpectedToken;

    return .{ .arena = arena, .stmt = stmt };
}

// ---------------- 测试 ----------------

test "lexer basic tokens" {
    var lx = Lexer{ .src = "SELECT id, name FROM users WHERE age >= 18;" };
    const expected = [_]TokenTag{ .ident, .ident, .comma, .ident, .ident, .ident, .ident, .ident, .ge, .number, .semicolon, .eof };
    for (expected) |tag| {
        const t = try lx.next();
        try std.testing.expectEqual(tag, t.tag);
    }
}

test "lexer string escape and quoted ident" {
    var lx = Lexer{ .src = "INSERT INTO \"my table\" VALUES ('it''s ok')" };
    var tags: [7]TokenTag = undefined;
    var texts: [7][]const u8 = undefined;
    var i: usize = 0;
    while (i < tags.len) : (i += 1) {
        const t = try lx.next();
        tags[i] = t.tag;
        texts[i] = t.text;
    }
    try std.testing.expectEqualStrings("my table", texts[2]);
    try std.testing.expectEqualStrings("it''s ok", texts[5]);
}

test "parse create table" {
    const src = "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, age INTEGER)";
    var p = try parse(std.testing.allocator, src);
    defer p.deinit();
    switch (p.stmt) {
        .create_table => |c| {
            try std.testing.expect(c.if_not_exists);
            try std.testing.expectEqualStrings("users", c.name);
            try std.testing.expectEqual(@as(usize, 3), c.columns.len);
            try std.testing.expect(c.columns[0].primary_key);
            try std.testing.expect(c.columns[0].auto_increment);
            try std.testing.expectEqual(ColumnType.text, c.columns[1].col_type);
            try std.testing.expect(c.columns[1].not_null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse insert multi-row" {
    const src = "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30), (2, 'O''Brien', 25)";
    var p = try parse(std.testing.allocator, src);
    defer p.deinit();
    switch (p.stmt) {
        .insert => |ins| {
            try std.testing.expectEqualStrings("users", ins.table);
            try std.testing.expectEqual(@as(usize, 3), ins.columns.len);
            try std.testing.expectEqual(@as(usize, 2), ins.rows.len);
            try std.testing.expectEqual(@as(i64, 30), ins.rows[0][2].integer);
            try std.testing.expectEqualStrings("O'Brien", ins.rows[1][1].text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse select where order limit" {
    const src = "SELECT id, name FROM users WHERE age >= 25 ORDER BY age DESC, id ASC LIMIT 10 OFFSET 2";
    var p = try parse(std.testing.allocator, src);
    defer p.deinit();
    switch (p.stmt) {
        .select => |s| {
            try std.testing.expectEqualStrings("users", s.table);
            try std.testing.expectEqual(@as(usize, 2), s.items.len);
            try std.testing.expect(s.where != null);
            try std.testing.expectEqual(@as(i64, 25), s.where.?.value.integer);
            try std.testing.expectEqual(@as(usize, 2), s.order_by.len);
            try std.testing.expect(s.order_by[0].desc);
            try std.testing.expectEqual(@as(u32, 10), s.limit.?);
            try std.testing.expectEqual(@as(u32, 2), s.offset.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse select star" {
    var p = try parse(std.testing.allocator, "SELECT * FROM t LIMIT 5");
    defer p.deinit();
    switch (p.stmt) {
        .select => |s| {
            try std.testing.expectEqual(@as(usize, 1), s.items.len);
            switch (s.items[0]) {
                .star => {},
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse update and delete" {
    var p = try parse(std.testing.allocator, "UPDATE users SET name = 'X', age = 31 WHERE id = 1");
    defer p.deinit();
    switch (p.stmt) {
        .update => |u| {
            try std.testing.expectEqualStrings("users", u.table);
            try std.testing.expectEqual(@as(usize, 2), u.assignments.len);
            try std.testing.expectEqualStrings("age", u.assignments[1].column);
            try std.testing.expect(u.where != null);
        },
        else => return error.TestUnexpectedResult,
    }

    var q = try parse(std.testing.allocator, "DELETE FROM users WHERE age < 18");
    defer q.deinit();
    switch (q.stmt) {
        .delete => |d| {
            try std.testing.expectEqualStrings("users", d.table);
            try std.testing.expect(d.where != null);
            try std.testing.expectEqual(@as(i64, 18), d.where.?.value.integer);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unsupported statement rejected" {
    try std.testing.expectError(error.UnsupportedStatement, parse(std.testing.allocator, "WITH x AS (SELECT 1) SELECT * FROM x"));
}

test "parse HAVING 聚合比较" {
    var p = try parse(std.testing.allocator, "SELECT g, COUNT(*) FROM t GROUP BY g HAVING COUNT(*) > 1 ORDER BY g");
    defer p.deinit();
    const s = p.stmt.select;
    try std.testing.expect(s.having != null);
    try std.testing.expectEqual(AggFunc.count, s.having.?.agg.func);
    try std.testing.expect(s.having.?.agg.column == null);
    try std.testing.expectEqual(CmpOp.gt, s.having.?.op);
    try std.testing.expectEqual(@as(i64, 1), s.having.?.value.integer);

    var q = try parse(std.testing.allocator, "SELECT g FROM t GROUP BY g HAVING SUM(x) >= 100");
    defer q.deinit();
    try std.testing.expectEqual(AggFunc.sum, q.stmt.select.having.?.agg.func);
    try std.testing.expectEqualStrings("x", q.stmt.select.having.?.agg.column.?);
    try std.testing.expectEqual(CmpOp.ge, q.stmt.select.having.?.op);

    // HAVING 后面必须是聚合调用，否则拒绝（不猜）
    try std.testing.expectError(
        error.UnsupportedStatement,
        parse(std.testing.allocator, "SELECT g FROM t GROUP BY g HAVING g > 1"),
    );
}

test "parse group by with aggregates" {
    var p = try parse(std.testing.allocator,
        "SELECT g, COUNT(*), SUM(x), AVG(x), MIN(x), MAX(x) FROM t GROUP BY g ORDER BY g DESC LIMIT 3");
    defer p.deinit();
    const s = p.stmt.select;
    try std.testing.expectEqual(@as(usize, 6), s.items.len);
    try std.testing.expectEqualStrings("g", s.items[0].column);
    try std.testing.expectEqual(AggFunc.count, s.items[1].aggregate.func);
    try std.testing.expect(s.items[1].aggregate.column == null); // COUNT(*)
    try std.testing.expectEqualStrings("x", s.items[2].aggregate.column.?);
    try std.testing.expectEqual(AggFunc.avg, s.items[3].aggregate.func);
    try std.testing.expectEqual(AggFunc.min, s.items[4].aggregate.func);
    try std.testing.expectEqual(AggFunc.max, s.items[5].aggregate.func);
    try std.testing.expectEqual(@as(usize, 1), s.group_by.len);
    try std.testing.expectEqualStrings("g", s.group_by[0]);
    try std.testing.expect(s.order_by[0].desc);
    try std.testing.expectEqual(@as(u32, 3), s.limit.?);
}

test "aggregate without group by parses (whole table = one group)" {
    var p = try parse(std.testing.allocator, "SELECT COUNT(*) FROM t WHERE x > 1");
    defer p.deinit();
    const s = p.stmt.select;
    try std.testing.expectEqual(@as(usize, 0), s.group_by.len);
    try std.testing.expectEqual(AggFunc.count, s.items[0].aggregate.func);
}

test "aggregate syntax errors are rejected, not silently read as columns" {
    const a = std.testing.allocator;
    // 未知函数名：不能当成列名吞掉
    try std.testing.expectError(error.UnsupportedStatement, parse(a, "SELECT nosuchfunc(x) FROM t"));
    // SUM(*) 没有意义
    try std.testing.expectError(error.UnsupportedStatement, parse(a, "SELECT SUM(*) FROM t"));
    // 缺右括号
    try std.testing.expectError(error.UnexpectedToken, parse(a, "SELECT COUNT(x FROM t"));
}
