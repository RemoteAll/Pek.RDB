// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-PekRDB-Commercial
// 个人使用免费；商业使用需商业授权，或同样以 AGPL-3.0 开源（见 LICENSE）。
const std = @import("std");
const build_options = @import("build_options");

// ---- KV 核心：**不依赖 SQL 层**（`-Dsql=false` 时仍然完整可编）----
// 这条分层契约靠 `zig build test -Dsql=false` 机械验证，不是口号。
pub const codec = @import("codec.zig");
pub const skiplist = @import("skiplist.zig");
pub const wal = @import("wal.zig");
pub const segment = @import("segment.zig");
pub const table = @import("table.zig");
pub const shutdown = @import("shutdown.zig");
/// 固定池分配器（§16.5 `-Dalloc` 档：无系统堆也能跑 KV 全流程）
pub const pool = @import("pool.zig");

// ---- SQL 层（`-Dsql=false` 时整层编译掉）----
// §16.5 硬约束：任何能力都必须能**编译期关闭**。关掉这一层之后，KV 核心的回归
// （table/segment/wal/skiplist 自己的用例）必须仍然全绿。
pub const sql = if (build_options.sql) @import("sql.zig") else struct {};
pub const schema = if (build_options.sql) @import("schema.zig") else struct {};
pub const exec = if (build_options.sql) @import("exec.zig") else struct {};
pub const catalog = if (build_options.sql) @import("catalog.zig") else struct {};
pub const engine = if (build_options.sql) @import("engine.zig") else struct {};
pub const m0 = @import("m0.zig");
pub const m0_spi = @import("m0_spi.zig");
pub const m0_diag = @import("m0_diag.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("m0_diag_test.zig");
    // 差分/注入用例直接调 `engine`/`sql`，SQL 层关掉时它们无从谈起。
    if (build_options.sql) _ = @import("fuzz_diff.zig");
}
