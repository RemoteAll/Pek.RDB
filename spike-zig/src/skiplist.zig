// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");

pub const MAX_HEIGHT: usize = 12;
const NIL: u32 = std.math.maxInt(u32);

pub const Entry = struct {
    key: []const u8,
    seq: u64,
    flags: u8,
    value: []const u8,
};

pub const Node = struct {
    key_off: u32,
    key_len: u32,
    val_off: u32,
    val_len: u32,
    seq: u64,
    flags: u8,
    height: u8,
    next: [MAX_HEIGHT]u32,
};

fn keyCmp(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    if (a.len == b.len) return .eq;
    return if (a.len < b.len) .lt else .gt;
}

/// Arena SkipList：按 (key ASC, seq DESC) 排序，同 key 的多个版本连续存放。
pub const Skiplist = struct {
    alloc: std.mem.Allocator,
    arena: std.ArrayList(u8) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    head: [MAX_HEIGHT]u32 = @splat(NIL),
    height: u8 = 1,
    /// 「顺序追加」快路径的状态（对齐 RocksDB `InlineSkipList::prev_` 与 SQLite 升序 rowid 快路）。
    ///
    /// `prev_node` = 最后一次插入且**落在链尾**的节点；`prev[lvl]` = 它在各层的前驱。
    /// 因为 `prev_node.next[0] == NIL`（它是最大值），各层 `prev[lvl]` 也就是该层的最大节点，
    /// 所以新 key 比它大时前驱必然还是这些节点 —— 插入可以完全跳过 `find()` 的逐层搜索。
    ///
    /// 收益：升序灌数据（PK 自增、时序、日志）从 O(log n) 降到 O(1)；
    /// 乱序写入第一个不满足的点就回退 `find()`，正确性不受影响。
    prev: [MAX_HEIGHT]u32 = @splat(NIL),
    prev_node: u32 = NIL,
    rng: u64 = 0x9E3779B97F4A7C15,
    count: usize = 0,
    bytes: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Skiplist {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Skiplist) void {
        self.arena.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn len(self: *const Skiplist) usize {
        return self.count;
    }

    pub fn sizeBytes(self: *const Skiplist) usize {
        return self.bytes;
    }

    fn keyOf(self: *const Skiplist, n: *const Node) []const u8 {
        return self.arena.items[n.key_off..][0..n.key_len];
    }

    fn valueOf(self: *const Skiplist, n: *const Node) []const u8 {
        return self.arena.items[n.val_off..][0..n.val_len];
    }

    fn before(key_a: []const u8, seq_a: u64, key_b: []const u8, seq_b: u64) bool {
        return switch (keyCmp(key_a, key_b)) {
            .lt => true,
            .gt => false,
            .eq => seq_a > seq_b, // 新版本在前
        };
    }

    fn nextRand(self: *Skiplist) u64 {
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng = x;
        return x;
    }

    fn randomHeight(self: *Skiplist) u8 {
        var h: u8 = 1;
        while (h < MAX_HEIGHT and (self.nextRand() & 0x3) == 0) h += 1;
        return h;
    }

    fn find(
        self: *const Skiplist,
        key: []const u8,
        seq: u64,
        pred: *[MAX_HEIGHT]u32,
        succ: *[MAX_HEIGHT]u32,
    ) void {
        // 关键：从最高层逐层下滑，下一层从上一层停下的节点继续，
        // 否则每层都从 head 重扫 → 插入退化成 O(n)。
        var cur: u32 = NIL;
        var lvl: usize = self.height;
        while (lvl > 0) {
            lvl -= 1;
            var p = cur;
            var c: u32 = if (p == NIL) self.head[lvl] else self.nodes.items[p].next[lvl];
            while (c != NIL) {
                const n = &self.nodes.items[c];
                if (before(self.keyOf(n), n.seq, key, seq)) {
                    p = c;
                    c = n.next[lvl];
                } else break;
            }
            pred[lvl] = p;
            succ[lvl] = c;
            cur = p;
        }
    }

    pub fn insert(self: *Skiplist, key: []const u8, seq: u64, flags: u8, value: []const u8) !void {
        var pred: [MAX_HEIGHT]u32 = @splat(NIL);
        var succ: [MAX_HEIGHT]u32 = @splat(NIL);
        // 快路径：上一个节点落在链尾且新 key 比它大 ⇒ 各层前驱已知，不必搜索。
        // **必须要求 `next[0] == NIL`**：否则中间可能夹着别的节点（例如 10、20 之后插 15，
        // 再插 25 时若沿用 15 的前驱就会漏掉 20），那是会造出乱序链的静默错误。
        var fast = false;
        if (self.prev_node != NIL) {
            const pn = &self.nodes.items[self.prev_node];
            if (pn.next[0] == NIL and before(self.keyOf(pn), pn.seq, key, seq)) {
                var lvl: usize = 0;
                while (lvl < self.height) : (lvl += 1) {
                    // 层数低于 prev_node 高度的层，前驱就是 prev_node 本身
                    const p: u32 = if (lvl < pn.height) self.prev_node else self.prev[lvl];
                    pred[lvl] = p;
                    succ[lvl] = if (p == NIL) self.head[lvl] else self.nodes.items[p].next[lvl];
                }
                fast = true;
            }
        }
        if (!fast) self.find(key, seq, &pred, &succ);

        // 幂等重放：同 key + 同 seq 覆盖值
        if (succ[0] != NIL) {
            const n = &self.nodes.items[succ[0]];
            if (n.seq == seq and keyCmp(self.keyOf(n), key) == .eq) {
                const val_off: u32 = @intCast(self.arena.items.len);
                try self.arena.appendSlice(self.alloc, value);
                n.val_off = val_off;
                n.val_len = @intCast(value.len);
                n.flags = flags;
                self.bytes += value.len;
                return;
            }
        }

        const h = self.randomHeight();
        const key_off: u32 = @intCast(self.arena.items.len);
        try self.arena.appendSlice(self.alloc, key);
        const val_off: u32 = @intCast(self.arena.items.len);
        try self.arena.appendSlice(self.alloc, value);

        const idx: u32 = @intCast(self.nodes.items.len);
        var node: Node = .{
            .key_off = key_off,
            .key_len = @intCast(key.len),
            .val_off = val_off,
            .val_len = @intCast(value.len),
            .seq = seq,
            .flags = flags,
            .height = h,
            .next = @splat(NIL),
        };

        var lvl: usize = 0;
        while (lvl < h) : (lvl += 1) {
            const p = if (lvl < self.height) pred[lvl] else NIL;
            const s = if (lvl < self.height) succ[lvl] else self.head[lvl];
            node.next[lvl] = s;
            if (p == NIL) {
                self.head[lvl] = idx;
            } else {
                self.nodes.items[p].next[lvl] = idx;
            }
        }
        try self.nodes.append(self.alloc, node);
        if (h > self.height) self.height = h;
        // 只有「插到了链尾」才记录快路径状态；否则作废（否则前驱会指向已过时的位置）。
        if (succ[0] == NIL) {
            var l2: usize = 0;
            while (l2 < self.height) : (l2 += 1) self.prev[l2] = pred[l2];
            self.prev_node = idx;
        } else {
            self.prev_node = NIL;
        }
        self.count += 1;
        self.bytes += 64 + key.len + value.len;
    }

    /// 取 key 在 snapshot 下可见的最新版本（含墓碑，flags 由调用方判断）。
    pub fn get(self: *const Skiplist, key: []const u8, snapshot: u64) ?Entry {
        var pred: [MAX_HEIGHT]u32 = @splat(NIL);
        var succ: [MAX_HEIGHT]u32 = @splat(NIL);
        self.find(key, std.math.maxInt(u64), &pred, &succ);
        var cur = succ[0];
        while (cur != NIL) {
            const n = &self.nodes.items[cur];
            const k = self.keyOf(n);
            switch (keyCmp(k, key)) {
                .gt => return null,
                .lt => {},
                .eq => {
                    if (n.seq <= snapshot) {
                        return .{ .key = k, .seq = n.seq, .flags = n.flags, .value = self.valueOf(n) };
                    }
                },
            }
            cur = n.next[0];
        }
        return null;
    }

    pub const Iterator = struct {
        list: *const Skiplist,
        cur: u32,

        pub fn next(self: *Iterator) ?Entry {
            if (self.cur == NIL) return null;
            const n = &self.list.nodes.items[self.cur];
            self.cur = n.next[0];
            return .{
                .key = self.list.keyOf(n),
                .seq = n.seq,
                .flags = n.flags,
                .value = self.list.valueOf(n),
            };
        }
    };

    pub fn iterator(self: *const Skiplist) Iterator {
        return .{ .list = self, .cur = self.head[0] };
    }

    /// 从 start（含）开始迭代。
    pub fn iteratorFrom(self: *const Skiplist, start: []const u8) Iterator {
        var pred: [MAX_HEIGHT]u32 = @splat(NIL);
        var succ: [MAX_HEIGHT]u32 = @splat(NIL);
        self.find(start, std.math.maxInt(u64), &pred, &succ);
        return .{ .list = self, .cur = succ[0] };
    }

    pub fn reset(self: *Skiplist) void {
        self.arena.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.head = @splat(NIL);
        self.height = 1;
        self.count = 0;
        self.bytes = 0;
        // 节点数组清空后旧索引全部失效，快路径状态必须一起作废
        self.prev = @splat(NIL);
        self.prev_node = NIL;
    }
};

test "skiplist insert/get/order" {
    var sk = Skiplist.init(std.testing.allocator);
    defer sk.deinit();

    try sk.insert("b", 1, 0, "v1");
    try sk.insert("a", 1, 0, "a1");
    try sk.insert("b", 2, 0, "v2");
    try sk.insert("c", 1, 0, "c1");

    try std.testing.expectEqual(@as(usize, 4), sk.len());

    const b2 = sk.get("b", 2).?;
    try std.testing.expectEqualStrings("v2", b2.value);
    const b1 = sk.get("b", 1).?;
    try std.testing.expectEqualStrings("v1", b1.value);
    const b0 = sk.get("b", 0);
    try std.testing.expect(b0 == null);

    var it = sk.iterator();
    var keys: [4][]const u8 = undefined;
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) keys[i] = e.key;
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("b", keys[1]);
    try std.testing.expectEqualStrings("b", keys[2]);
    try std.testing.expectEqualStrings("c", keys[3]);
}

test "skiplist tombstone visible by snapshot" {
    var sk = Skiplist.init(std.testing.allocator);
    defer sk.deinit();
    try sk.insert("k", 1, 0, "v");
    try sk.insert("k", 2, 1, ""); // 删除
    try std.testing.expectEqualStrings("v", sk.get("k", 1).?.value);
    try std.testing.expectEqual(@as(u8, 1), sk.get("k", 2).?.flags);
}

test "顺序追加快路径：升序 / 回退 / 再升序都必须保持严格有序" {
    var sk = Skiplist.init(std.testing.allocator);
    defer sk.deinit();

    // 1) 纯升序（走链尾追加快路径）
    for (0..200) |i| {
        var kb: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i});
        try sk.insert(k, 1, 0, "v");
    }
    // 2) 插入一个夹在中间的 key：快路径必须判定失效并回退到 find()
    //    （这正是「10、20 之后插 15，再插 25 会漏掉 20」那个静默错误的场景）
    try sk.insert("k0000a", 1, 0, "mid");
    // 3) 继续更大 key：新的链尾重新建立快路径
    for (200..400) |i| {
        var kb: [16]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d:0>4}", .{i});
        try sk.insert(k, 1, 0, "v");
    }

    // 全表遍历必须严格升序，且 mid 落在 k0000 与 k0001 之间
    var prev: ?[]const u8 = null;
    var n: usize = 0;
    var it = sk.iterator();
    while (it.next()) |e| {
        if (prev) |p| try std.testing.expect(keyCmp(p, e.key) == .lt);
        if (std.mem.eql(u8, e.key, "k0000a")) {
            try std.testing.expectEqualStrings("k0000", prev.?);
        }
        prev = e.key;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 401), n);
}
