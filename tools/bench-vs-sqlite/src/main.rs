//! SQLite 对照基准（与 spike-zig 的 bench 同数据集、同口径）。
//!
//! 口径：
//! - `journal_mode=WAL`、`synchronous=NORMAL`（SQLite 的常规推荐配置）；
//! - 1,000,000 行，主键 i64 递增，值 32B；
//! - `put` = 逐行 autocommit（对应 Zig 侧的逐行 put + 组提交）；
//! - `put_txn` = 单事务批量插入（对照批量写）；
//! - `get` = 10 万次随机主键点查（预编译语句）；
//! - `scan` = 主键范围 1 万行；
//! - `recover_ms` = 关闭后重开 + 首查耗时。

use std::time::Instant;

use rusqlite::{params, Connection};

const N: i64 = 1_000_000;
const GET_N: i64 = 100_000;
const SCAN_LO: i64 = 500_000;
const SCAN_HI: i64 = 510_000;

fn sqlite_paths() -> (&'static str, &'static str, &'static str) {
    ("bench-sqlite.db", "bench-sqlite.db-wal", "bench-sqlite.db-shm")
}

fn cleanup() {
    let (db, wal, shm) = sqlite_paths();
    for p in [db, wal, shm] {
        let _ = std::fs::remove_file(p);
    }
}

fn open_conn() -> rusqlite::Result<Connection> {
    let (db, _, _) = sqlite_paths();
    let conn = Connection::open(db)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    Ok(conn)
}

fn main() -> rusqlite::Result<()> {
    cleanup();

    let conn = open_conn()?;
    println!("sqlite_version,{}", rusqlite::version());
    println!("journal_mode,{}", conn.query_row("PRAGMA journal_mode", [], |r| r.get::<_, String>(0))?);

    conn.execute_batch("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")?;
    let value = [b'x'; 32];

    // 逐行 autocommit
    let t0 = Instant::now();
    {
        let mut stmt = conn.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
        for i in 0..N {
            stmt.execute(params![i, &value[..]])?;
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    println!("put,{},{}", N, N as f64 / secs);

    // 单事务批量插入（独立表 t2）
    conn.execute_batch("CREATE TABLE t2(id INTEGER PRIMARY KEY, v BLOB)")?;
    let t0 = Instant::now();
    {
        conn.execute_batch("BEGIN")?;
        {
            let mut stmt = conn.prepare("INSERT INTO t2(id, v) VALUES (?1, ?2)")?;
            for i in 0..N {
                stmt.execute(params![i, &value[..]])?;
            }
        }
        conn.execute_batch("COMMIT")?;
    }
    let secs = t0.elapsed().as_secs_f64();
    println!("put_txn,{},{}", N, N as f64 / secs);

    // 点查
    let t0 = Instant::now();
    let mut hits: i64 = 0;
    {
        let mut stmt = conn.prepare("SELECT v FROM t WHERE id = ?1")?;
        let mut x: u64 = 88_172_645_463_325_252;
        for _ in 0..GET_N {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let id = (x % N as u64) as i64;
            let v: Vec<u8> = stmt.query_row(params![id], |r| r.get(0))?;
            if !v.is_empty() {
                hits += 1;
            }
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    println!("get,{},{}", GET_N, GET_N as f64 / secs);
    println!("get_hits,{},{}", GET_N, hits);

    // 范围扫描
    let t0 = Instant::now();
    let count: i64 = {
        let mut stmt = conn.prepare("SELECT id FROM t WHERE id >= ?1 AND id < ?2")?;
        let mut rows = stmt.query(params![SCAN_LO, SCAN_HI])?;
        let mut c = 0i64;
        while rows.next()?.is_some() {
            c += 1;
        }
        c
    };
    let secs = t0.elapsed().as_secs_f64();
    println!("scan,{},{}", count, count as f64 / secs);

    // 范围扫描（带值，与 Zig 侧同口径）
    let t0 = Instant::now();
    let mut bytes: i64 = 0;
    {
        let mut stmt = conn.prepare("SELECT id, v FROM t WHERE id >= ?1 AND id < ?2")?;
        let mut rows = stmt.query(params![SCAN_LO, SCAN_HI])?;
        while let Some(row) = rows.next()? {
            let _id: i64 = row.get(0)?;
            let v: Vec<u8> = row.get(1)?;
            bytes += v.len() as i64;
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    println!("scan_v,{},{}", bytes / 32, (bytes as f64 / 32.0) / secs);

    drop(conn);

    // 重开 + 首查
    let t0 = Instant::now();
    let conn2 = open_conn()?;
    let _: Vec<u8> = conn2.query_row("SELECT v FROM t WHERE id = ?1", params![12345i64], |r| r.get(0))?;
    let ms = t0.elapsed().as_secs_f64() * 1000.0;
    println!("recover,{},{}", N, ms);
    println!("recover_read,1,1");

    drop(conn2);

    // ---------------- 并发写（对齐 Zig 侧「跨表并行」：每线程独立库文件） ----------------
    let conc_per: i64 = 300_000;
    for nt in [1usize, 2, 4] {
        // (a) 逐行 autocommit —— 对应 Zig 侧逐行 put（Zig 有跨行组提交，SQLite 这里是每行一次提交）
        let t0 = Instant::now();
        std::thread::scope(|s| {
            for i in 0..nt {
                s.spawn(move || -> rusqlite::Result<()> {
                    let path = format!("bench-conc-{i}.db");
                    let _ = std::fs::remove_file(&path);
                    let c = Connection::open(&path)?;
                    c.pragma_update(None, "journal_mode", "WAL")?;
                    c.pragma_update(None, "synchronous", "NORMAL")?;
                    c.execute_batch("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")?;
                    let mut stmt = c.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
                    for k in 0..conc_per {
                        stmt.execute(params![k, &value[..]])?;
                    }
                    drop(stmt);
                    drop(c);
                    let _ = std::fs::remove_file(&path);
                    let _ = std::fs::remove_file(format!("{path}-wal"));
                    let _ = std::fs::remove_file(format!("{path}-shm"));
                    Ok(())
                });
            }
        });
        let secs = t0.elapsed().as_secs_f64();
        let total = conc_per as f64 * nt as f64;
        println!("conc_put_{}t_auto,{},{}", nt, total as i64, total / secs);

        // (b) 每线程单事务 —— 对应 Zig 侧批量写能力（SQLite 的最佳形态）
        let t0 = Instant::now();
        std::thread::scope(|s| {
            for i in 0..nt {
                s.spawn(move || -> rusqlite::Result<()> {
                    let path = format!("bench-conc-t-{i}.db");
                    let _ = std::fs::remove_file(&path);
                    let c = Connection::open(&path)?;
                    c.pragma_update(None, "journal_mode", "WAL")?;
                    c.pragma_update(None, "synchronous", "NORMAL")?;
                    c.execute_batch("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")?;
                    c.execute_batch("BEGIN")?;
                    {
                        let mut stmt = c.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
                        for k in 0..conc_per {
                            stmt.execute(params![k, &value[..]])?;
                        }
                    }
                    c.execute_batch("COMMIT")?;
                    drop(c);
                    let _ = std::fs::remove_file(&path);
                    let _ = std::fs::remove_file(format!("{path}-wal"));
                    let _ = std::fs::remove_file(format!("{path}-shm"));
                    Ok(())
                });
            }
        });
        let secs = t0.elapsed().as_secs_f64();
        let total = conc_per as f64 * nt as f64;
        println!("conc_put_{}t_txn,{},{}", nt, total as i64, total / secs);
    }

    // ---------------- 超内存数据集（200 万行） ----------------
    {
        const BIG: i64 = 2_000_000;
        let path = "bench-big.db";
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(format!("{path}-wal"));
        let _ = std::fs::remove_file(format!("{path}-shm"));

        let c = Connection::open(path)?;
        c.pragma_update(None, "journal_mode", "WAL")?;
        c.pragma_update(None, "synchronous", "NORMAL")?;
        c.execute_batch("CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)")?;

        let t0 = Instant::now();
        c.execute_batch("BEGIN")?;
        {
            let mut stmt = c.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
            for i in 0..BIG {
                stmt.execute(params![i, &value[..]])?;
            }
        }
        c.execute_batch("COMMIT")?;
        let secs = t0.elapsed().as_secs_f64();
        println!("big_put_txn,{},{}", BIG, BIG as f64 / secs);

        // 随机点查
        let t0 = Instant::now();
        let mut hits: i64 = 0;
        {
            let mut stmt = c.prepare("SELECT v FROM t WHERE id = ?1")?;
            let mut x: u64 = 88_172_645_463_325_252;
            for _ in 0..GET_N {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (x % BIG as u64) as i64;
                let v: Vec<u8> = stmt.query_row(params![id], |r| r.get(0))?;
                if !v.is_empty() {
                    hits += 1;
                }
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("big_get,{},{}", GET_N, GET_N as f64 / secs);
        println!("big_get_hits,{},{}", GET_N, hits);

        // 范围扫描（仅 key，与 Zig big_scan_refs 同口径）
        let t0 = Instant::now();
        let count: i64 = {
            let mut stmt = c.prepare("SELECT id FROM t WHERE id >= ?1 AND id < ?2")?;
            let mut rows = stmt.query(params![SCAN_LO, SCAN_HI])?;
            let mut c2 = 0i64;
            while rows.next()?.is_some() {
                c2 += 1;
            }
            c2
        };
        let secs = t0.elapsed().as_secs_f64();
        println!("big_scan,{},{}", count, count as f64 / secs);

        drop(c);

        let t0 = Instant::now();
        let c2 = Connection::open(path)?;
        c2.pragma_update(None, "journal_mode", "WAL")?;
        c2.pragma_update(None, "synchronous", "NORMAL")?;
        let _: Vec<u8> = c2.query_row("SELECT v FROM t WHERE id = ?1", params![12345i64], |r| r.get(0))?;
        println!("big_recover,{},{}", BIG, t0.elapsed().as_secs_f64() * 1000.0);
        drop(c2);
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(format!("{path}-wal"));
        let _ = std::fs::remove_file(format!("{path}-shm"));
    }

    // ---------------- 随机原地 UPDATE（目标线 §16.1：SQLite 强项） ----------------
    // 在已存在的 100 万行表 t 上随机改 10 万行的值；两种形态都测：
    //   upd_random_auto = 逐条 autocommit；upd_random_txn = 单事务（SQLite 最佳形态，主对比口径）。
    {
        let c3 = open_conn()?;
        let value2 = [b'y'; 32];

        let t0 = Instant::now();
        {
            let mut stmt = c3.prepare("UPDATE t SET v = ?1 WHERE id = ?2")?;
            let mut x: u64 = 88_172_645_463_325_252;
            for _ in 0..GET_N {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (x % N as u64) as i64;
                stmt.execute(params![&value2[..], id])?;
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("upd_random_auto,{},{}", GET_N, GET_N as f64 / secs);

        let t0 = Instant::now();
        c3.execute_batch("BEGIN")?;
        {
            let mut stmt = c3.prepare("UPDATE t SET v = ?1 WHERE id = ?2")?;
            let mut x: u64 = 88_172_645_463_325_252;
            for _ in 0..GET_N {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (x % N as u64) as i64;
                stmt.execute(params![&value2[..], id])?;
            }
        }
        c3.execute_batch("COMMIT")?;
        let secs = t0.elapsed().as_secs_f64();
        println!("upd_random_txn,{},{}", GET_N, GET_N as f64 / secs);

        // 更新后点查（与 Zig 侧 upd_get 同口径）
        let t0 = Instant::now();
        let mut hits: i64 = 0;
        {
            let mut stmt = c3.prepare("SELECT v FROM t WHERE id = ?1")?;
            let mut x: u64 = 88_172_645_463_325_252;
            for _ in 0..GET_N {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (x % N as u64) as i64;
                let v: Vec<u8> = stmt.query_row(params![id], |r| r.get(0))?;
                if !v.is_empty() {
                    hits += 1;
                }
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("upd_get,{},{}", GET_N, GET_N as f64 / secs);
        println!("upd_get_hits,{},{}", GET_N, hits);
        drop(c3);
    }

    Ok(())
}
