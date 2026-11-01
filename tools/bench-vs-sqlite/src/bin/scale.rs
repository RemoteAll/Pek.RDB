// 容量阶梯的 SQLite 对照（决策记录九十/九十一）。
//
// 为什么要单独一个 bin：主基准 `bench-vs-sqlite` 固定 100 万行，
// 而「支持 440 亿行时性能不比 SQLite 低」这条要求必须在**同一规模**上验证。
//
// 用法：
//   cargo run --release --bin scale -- 100000000 bench-scale.db
//
// 数据形态与 Zig 侧 `zig build run-scale` 完全一致：
//   id = 0..N-1（INTEGER PRIMARY KEY），v = 32 字节 BLOB（全 'x'）。
//   写入粒度也一致：每 1024 行一个事务（对应我方 putBatch 一次 WAL 提交）。
use rusqlite::{params, Connection};
use std::time::Instant;

fn per_sec(n: u64, secs: f64) -> f64 {
    if secs <= 0.0 {
        0.0
    } else {
        n as f64 / secs
    }
}

fn main() -> rusqlite::Result<()> {
    let mut args = std::env::args().skip(1);
    let rows: u64 = args
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100_000_000);
    let db = args.next().unwrap_or_else(|| "bench-scale.db".to_string());
    for p in [db.clone(), format!("{db}-wal"), format!("{db}-shm")] {
        let _ = std::fs::remove_file(p);
    }

    let value = vec![b'x'; 32];
    {
        let conn = Connection::open(&db)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")?;

        // ---------------- 灌数据（每 1024 行一个事务，与我方 putBatch 同粒度） ----------------
        let t0 = Instant::now();
        {
            let mut stmt = conn.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
            let mut i: u64 = 0;
            while i < rows {
                let n = std::cmp::min(1024, rows - i);
                conn.execute_batch("BEGIN")?;
                for k in 0..n {
                    stmt.execute(params![(i + k) as i64, &value])?;
                }
                conn.execute_batch("COMMIT")?;
                i += n;
                if i % 10_000_000 == 0 {
                    eprintln!("progress,{i},{}", t0.elapsed().as_millis());
                }
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("sqlite_scale_put,{},{}", rows, per_sec(rows, secs));

        // ---------------- 落盘体积 ----------------
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
        let disk = std::fs::metadata(&db).map(|m| m.len()).unwrap_or(0);
        println!("sqlite_scale_disk_bytes,{},{}", rows, disk);

        // ---------------- 全表扫描（流式，取列值） ----------------
        {
            let t0 = Instant::now();
            let mut n: u64 = 0;
            let mut acc: u64 = 0;
            let mut stmt = conn.prepare("SELECT id, v FROM t")?;
            let mut it = stmt.query([])?;
            while let Some(r) = it.next()? {
                let _id: i64 = r.get(0)?;
                if let Ok(v) = r.get_ref(1) {
                    if let rusqlite::types::ValueRef::Blob(b) = v {
                        acc = acc.wrapping_add(b.len() as u64);
                    }
                }
                n += 1;
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("sqlite_scale_scan,{},{}", n, per_sec(n, secs));
            println!("sqlite_scale_scan_acc,{},0", acc);
        }

        // ---------------- 点查（同一串 xorshift 序列，与 Zig 侧一致） ----------------
        let probes: u64 = 20_000;
        let hit_query = |client: &Connection, probes: u64| -> rusqlite::Result<(u64, f64)> {
            let mut stmt = client.prepare("SELECT v FROM t WHERE id = ?1")?;
            let mut x: u64 = 88172645463325252;
            let mut hits: u64 = 0;
            let t0 = Instant::now();
            for _ in 0..probes {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (x % rows) as i64;
                let mut it = stmt.query([id])?;
                if it.next()?.is_some() {
                    hits += 1;
                }
            }
            Ok((hits, t0.elapsed().as_secs_f64()))
        };
        {
            let (hits, secs) = hit_query(&conn, probes)?;
            println!("sqlite_scale_get_hit,{},{}", hits, per_sec(probes, secs));
            // 第二遍（页已热），与我方 `scale_get_hit_warm` 同口径
            let (hits2, secs2) = hit_query(&conn, probes)?;
            println!("sqlite_scale_get_hit_warm,{},{}", hits2, per_sec(probes, secs2));
        }
        {
            let mut stmt = conn.prepare("SELECT v FROM t WHERE id = ?1")?;
            let mut x: u64 = 88172645463325252;
            let mut found: u64 = 0;
            let t0 = Instant::now();
            for _ in 0..probes {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (rows + (x % rows) + 1) as i64;
                let mut it = stmt.query([id])?;
                if it.next()?.is_some() {
                    found += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("sqlite_scale_get_miss,{},{}", probes - found, per_sec(probes, secs));
        }
    }

    // ---------------- 重开（open 与 open+首次点查分开报，别把两件事混成一个数） ----------------
    for round in 0..2 {
        let t0 = Instant::now();
        let conn = Connection::open(&db)?;
        let us = t0.elapsed().as_micros();
        println!("sqlite_scale_reopen_us,open,{}", us);
        let t1 = Instant::now();
        let _: Option<Vec<u8>> = conn
            .query_row("SELECT v FROM t WHERE id = 0", [], |r| r.get(0))
            .ok();
        println!(
            "sqlite_scale_reopen_us,open_first_get,{}",
            t1.elapsed().as_micros()
        );
        drop(conn);
        let _ = round;
    }

    println!("sqlite_scale_done,{},0", rows);
    Ok(())
}
