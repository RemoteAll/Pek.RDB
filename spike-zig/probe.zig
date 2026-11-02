const std = @import("std");

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ArrayList 是 unmanaged（allocator 由调用方传入）
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(alloc);
    try list.append(alloc, 1);
    try list.append(alloc, 2);
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));

    // 0.17: Mutex 在 std.Io，不在 std.Thread
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(io);
    mutex.unlock(io);

    var seq = std.atomic.Value(u64).init(0);
    _ = seq.fetchAdd(1, .monotonic);

    const h = std.hash.Wyhash.hash(0, "abc");

    const dir = std.Io.Dir.cwd();
    var f = try dir.createFile(io, "probe-tmp.bin", .{ .read = true, .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, "hello world", 0);
    try f.sync(io);
    var buf: [5]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    defer dir.deleteFile(io, "probe-tmp.bin") catch {};

    std.debug.print("list={d} hash={x} read={s} n={d}\n", .{ list.items.len, h, buf[0..n], n });
}


