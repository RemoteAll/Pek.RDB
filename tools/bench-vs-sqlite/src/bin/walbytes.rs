//! 为什么「逐行 autocommit」的 SQLite 比我们慢一个数量级？
//!
//! 假设：SQLite 的 WAL 是**页粒度**的 —— 每次提交都要把整页（默认 4096B）写进 WAL，
//! 而我们每行只写 ~50B。若成立，把 `page_size` 从 4096 降到 512，
//! 单行写入的 WAL 字节应降到约 1/8，吞吐应随之上去。
//!
//! 本程序只做这一件事，输出两个数：
//! 1. 每行写入 WAL 的字节数（`wal_autocheckpoint=0`，让 WAL 一直增长以便直接量文件大小）
//! 2. 吞吐（保持默认 autocheckpoint，与主基准同口径）
//!
//! 用法：`walbytes.exe`

use std::time::Instant;

use rusqlite::{params, Connection};

/// 测字节数用的行数（WAL 会增长到 GB 级，别用 100 万）
const N_BYTES: i64 = 20_000;
/// 测吞吐用的行数
const N_SPEED: i64 = 200_000;

const VALUE: [u8; 32] = [b'x'; 32];

fn db_path(page_size: u32, tag: &str) -> String {
    format!("bench-walbytes-{tag}-{page_size}.db")
}

fn cleanup(path: &str) {
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{path}{suffix}"));
    }
}

fn wal_len(path: &str) -> u64 {
    std::fs::metadata(format!("{path}-wal"))
        .map(|m| m.len())
        .unwrap_or(0)
}

/// 打开一个按指定页大小初始化的 WAL + NORMAL 连接。
fn open(page_size: u32, autocheckpoint_off: bool, tag: &str) -> rusqlite::Result<(Connection, String)> {
    let path = db_path(page_size, tag);
    cleanup(&path);
    let conn = Connection::open(&path)?;
    // page_size 必须在对新库做任何写之前设置才生效
    conn.pragma_update(None, "page_size", page_size as i64)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    if autocheckpoint_off {
        conn.pragma_update(None, "wal_autocheckpoint", 0)?;
    }
    conn.execute_batch("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")?;
    Ok((conn, path))
}

/// 每行实际写进 WAL 的字节数。
///
/// `wal_autocheckpoint = 0` 让 WAL 只增不减，循环结束后文件大小就是累计写入量
/// —— 这是**直接测量**，不是用「页大小 + 24 字节帧头」推出来的。
fn bytes_per_row(page_size: u32) -> rusqlite::Result<(f64, u64)> {
    let (conn, path) = open(page_size, true, "bytes")?;
    let before = wal_len(&path);
    {
        let mut stmt = conn.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
        for i in 0..N_BYTES {
            stmt.execute(params![i, &VALUE[..]])?;
        }
    }
    // 让 WAL 里最后一批也落下来，避免读到中间态
    let _ = conn.pragma_update(None, "synchronous", "FULL");
    let after = wal_len(&path);
    let bytes = after.saturating_sub(before);
    drop(conn);
    cleanup(&path);
    Ok((bytes as f64 / N_BYTES as f64, bytes))
}

/// 吞吐（与主基准同口径：默认 autocheckpoint、逐行 autocommit）。
fn rows_per_sec(page_size: u32) -> rusqlite::Result<f64> {
    let (conn, path) = open(page_size, false, "speed")?;
    let t0 = Instant::now();
    {
        let mut stmt = conn.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
        for i in 0..N_SPEED {
            stmt.execute(params![i, &VALUE[..]])?;
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    drop(conn);
    cleanup(&path);
    Ok(N_SPEED as f64 / secs)
}

/// 单事务批量插入时每行写入 WAL 的字节数（对照 Zig 侧 `putBatch`）。
///
/// 这是**真正同口径**的一组：双方都把 N 行放在一次提交里，
/// 每行的提交开销被摊掉，剩下的差异才是引擎本身。
fn bytes_per_row_txn(page_size: u32) -> rusqlite::Result<f64> {
    let (conn, path) = open(page_size, true, "txn")?;
    let before = wal_len(&path);
    {
        conn.execute_batch("BEGIN")?;
        {
            let mut stmt = conn.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
            for i in 0..N_BYTES {
                stmt.execute(params![i, &VALUE[..]])?;
            }
        }
        conn.execute_batch("COMMIT")?;
    }
    let after = wal_len(&path);
    let bytes = after.saturating_sub(before);
    drop(conn);
    cleanup(&path);
    Ok(bytes as f64 / N_BYTES as f64)
}

fn main() -> rusqlite::Result<()> {
    println!("metric,page_size,tag,count,value");
    for ps in [4096u32, 512] {
        let (bpr, total) = bytes_per_row(ps)?;
        println!("wal_bytes_per_row,{ps},bytes,{N_BYTES},{bpr:.2}");
        println!("wal_bytes_total,{ps},bytes,{N_BYTES},{total}");
        let rps = rows_per_sec(ps)?;
        println!("rows_per_sec,{ps},speed,{N_SPEED},{rps:.0}");
        let txn = bytes_per_row_txn(ps)?;
        println!("wal_bytes_per_row_txn,{ps},txn,{N_BYTES},{txn:.2}");
    }
    Ok(())
}
