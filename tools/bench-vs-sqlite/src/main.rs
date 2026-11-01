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

use rusqlite::{params, types::ValueRef, Connection};

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

    // 大样本范围扫描（20 万行，区间 0..200000，与 Zig 侧 scan_full / scan_refs_full 同口径）。
    // 上面那两档只扫 1 万行，绝对耗时 <1µs，测的是固定开销与计时粒度 ——
    // 用它比「扫描能力」会让两边区间重叠、永远得不出结论。
    {
        let t0 = Instant::now();
        let mut n: usize = 0;
        {
            let mut stmt = conn.prepare("SELECT id FROM t WHERE id >= ?1 AND id < ?2")?;
            let mut rows = stmt.query(params![0i64, 200_000i64])?;
            while rows.next()?.is_some() {
                n += 1;
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("scan_big,{},{}", n, n as f64 / secs);
    }
    {
        let t0 = Instant::now();
        let mut bytes: i64 = 0;
        {
            let mut stmt = conn.prepare("SELECT id, v FROM t WHERE id >= ?1 AND id < ?2")?;
            let mut rows = stmt.query(params![0i64, 200_000i64])?;
            while let Some(row) = rows.next()? {
                let _id: i64 = row.get(0)?;
                let v: Vec<u8> = row.get(1)?;
                bytes += v.len() as i64;
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("scan_v_big,{},{}", bytes / 32, (bytes as f64 / 32.0) / secs);
    }

    // 范围扫描（20 万行）· **收集引用**：对等 Zig 的 `scan_refs`。
    //
    // 为什么必须有这一档：`scan_refs` 会把每条命中记录收进数组（20 万 × 48B = 9.6MB 写入），
    // 而 `scan_big` 只推进游标、一条都不收 —— 拿这两个比得出「我们 0.70×」是**口径不对等**的产物。
    // 这里补上「SQLite 也收集」的版本：用 `get_ref` 取引用（**不复制 payload**），
    // 与 `RefRecord{key 指针,len, seq, flags, value 指针,len}` 做的工作等价。
    {
        let t0 = Instant::now();
        let mut out: Vec<(i64, i64)> = Vec::with_capacity(200_000);
        {
            let mut stmt = conn.prepare("SELECT id, v FROM t WHERE id >= ?1 AND id < ?2")?;
            let mut rows = stmt.query(params![0i64, 200_000i64])?;
            while let Some(row) = rows.next()? {
                let id: i64 = row.get(0)?;
                let vlen = row.get_ref(1)?.as_blob().map(|b| b.len()).unwrap_or(0) as i64;
                out.push((id, vlen));
            }
        }
        let secs = t0.elapsed().as_secs_f64();
        println!("scan_big_collect,{},{}", out.len(), out.len() as f64 / secs);
    }

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

        // 落盘占用：与 Zig 的 `big_disk_bytes` 对等。
        //
        // 先 `wal_checkpoint(TRUNCATE)` 把 WAL 归并回主库 —— 我们那边 flush 完会删掉 WAL，
        // 不 checkpoint 就是拿「我们已收尾」比「SQLite 未收尾」，不公平。
        // 统计 db + -wal + -shm 三个文件的实际字节数（不含任何我们的口径换算）。
        {
            let _ = c.pragma_update(None, "wal_checkpoint", "TRUNCATE");
            let fsz = |p: &str| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            let total = fsz(path) + fsz(&format!("{path}-wal")) + fsz(&format!("{path}-shm"));
            println!("big_disk_bytes,{},{}", BIG, total);
            // Print with decimals: integer division turned 41.56 into 41 and the Zig side's
            // 40.92 into 40, so both sides were biased but by different amounts.
            println!("big_disk_bytes_row,1,{:.3}", total as f64 / BIG as f64);
        }

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

        // 纯遍历计数（不取值）。与上面 big_scan 的差别只是样本从 1 万行放大到 50 万行 ——
        // 1 万行的绝对耗时 <1µs，测的是固定开销而非扫描能力。
        {
            let t0 = Instant::now();
            let mut n: usize = 0;
            {
                let mut stmt = c.prepare("SELECT id FROM t WHERE id >= 0 AND id < 500000")?;
                let mut rows = stmt.query([])?;
                while rows.next()?.is_some() {
                    n += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("big_count,{},{}", n, n as f64 / secs);
        }

        // 超内存 · 区间「只数行」（20 万行）：对等 Zig 的 `big_count_range`。
        // big_scan 只扫 1 万行、绝对耗时 <1µs；big_count 扫 50 万行但起点 0 ——
        // 这一档固定 20 万行区间，与内存内那档同样本量，便于横比「内存内 vs 超内存」衰减幅度。
        {
            let t0 = Instant::now();
            let mut n: usize = 0;
            {
                let mut stmt = c.prepare("SELECT id FROM t WHERE id >= 0 AND id < 200000")?;
                let mut rows = stmt.query([])?;
                while rows.next()?.is_some() {
                    n += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("big_count_range,{},{}", n, n as f64 / secs);
        }

        drop(c);

        // 纯 open（与 Zig 的 `Table.open` 对等）：只开连接 + 两次 pragma，**不做任何查询**。
        // 原口径里还带了一条 `query_row`，而 Zig 侧 `big_recover` 只量 open ——
        // 两边做的事不同，比出来的倍数没有意义（这是本项目第 5 次踩同一个坑）。
        {
            let t0 = Instant::now();
            let c_open = Connection::open(path)?;
            c_open.pragma_update(None, "journal_mode", "WAL")?;
            c_open.pragma_update(None, "synchronous", "NORMAL")?;
            println!("big_recover_open,{},{}", BIG, t0.elapsed().as_secs_f64() * 1000.0);
            drop(c_open);
        }

        // 重开 + 首次点查（原口径，保留作参考，不计入对等结论）
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

        // DELETE：100 万行表上按主键删 10 万行，一次提交。
        //
        // 口径与 Zig 侧 `del_100k` 逐条对齐：同一个 xorshift64 序列（种子 88172645463325252）、
        // 同样取 `x % N`、同样「循环内只记账、末尾一次提交」。
        // 注意 id 可能重复（随机序列会撞），两边都一样，所以剩余行数要实测而不是算。
        {
            let t0 = Instant::now();
            c3.execute_batch("BEGIN")?;
            {
                let mut stmt = c3.prepare("DELETE FROM t WHERE id = ?1")?;
                let mut x: u64 = 88_172_645_463_325_252;
                for _ in 0..GET_N {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    let id = (x % N as u64) as i64;
                    stmt.execute([id])?;
                }
            }
            c3.execute_batch("COMMIT")?;
            let secs = t0.elapsed().as_secs_f64();
            println!("del_100k,{},{}", GET_N, GET_N as f64 / secs);
        }
        // 正确性 1：被删的 key 必须查不到
        {
            let mut hits: i64 = 0;
            let mut stmt = c3.prepare("SELECT 1 FROM t WHERE id = ?1")?;
            let mut x: u64 = 88_172_645_463_325_252;
            for _ in 0..GET_N {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                let id = (x % N as u64) as i64;
                let mut rows = stmt.query([id])?;
                if rows.next()?.is_some() {
                    hits += 1;
                }
            }
            println!("del_deleted_hits,{},{}", GET_N, hits);
        }
        // 正确性 2：剩余行数（实测，不用 n - get_n 推算 —— 随机序列有重复值）
        {
            let cnt: i64 = c3.query_row("SELECT COUNT(*) FROM t", [], |r| r.get(0))?;
            println!("del_remaining,{},{}", N, cnt);
        }

        // 分页查询（与 Zig 侧 sql_limit10 / sql_full 同口径，同一张 100 万行表）
        {
            let t0 = Instant::now();
            let mut n: usize = 0;
            {
                let mut stmt = c3.prepare("SELECT * FROM t LIMIT 10")?;
                let mut rows = stmt.query([])?;
                while rows.next()?.is_some() {
                    n += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("sql_limit10,{},{}", n, n as f64 / secs);
        }
        // SQL 点查：与 Zig 侧 `sql_get` **同一个随机序列、同样的主键分布** ——
        // 走 SQL 接口做 10 万次主键点查（不是 `get` 那种直连存储 API）。
        // 随机数用 xorshift64 + 同一个种子，否则两边点的不是同一批 key，比较无意义。
        {
            let t0 = Instant::now();
            let mut hits: i64 = 0;
            let mut x: u64 = 88_172_645_463_325_252;
            {
                let mut stmt = c3.prepare("SELECT id, v FROM t WHERE id = ?1")?;
                let mut k: i64 = 0;
                while k < GET_N {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    let id = (x % N as u64) as i64;
                    let mut rows = stmt.query([id])?;
                    if rows.next()?.is_some() {
                        hits += 1;
                    }
                    k += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("sql_get,{},{}", GET_N, GET_N as f64 / secs);
            println!("sql_get_hits,{},{}", GET_N, hits);
        }
        {
            let t0 = Instant::now();
            let mut n: usize = 0;
            {
                let mut stmt = c3.prepare("SELECT * FROM t")?;
                let mut rows = stmt.query([])?;
                while rows.next()?.is_some() {
                    n += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("sql_full,{},{}", n, n as f64 / secs);
        }
        // 上面的 sql_full 只推进游标、**不取列值**。SQLite 的 `OP_Column` 是惰性的：
        // 不调用 `column_*` 就根本不解码，所以那个数字只代表「游标推进」。
        // 这一档把两列都真读出来（都用零拷贝，不 malloc）：
        //   id -> i64 值拷贝；v -> `get_ref` 取切片，与 Zig 侧「text 指向 mmap 不复制」同口径。
        // 这才是与 `sql_each`（我们每行都完整解码两列）对等的比较。
        {
            let t0 = Instant::now();
            let mut n: usize = 0;
            let mut acc: i64 = 0;
            {
                let mut stmt = c3.prepare("SELECT * FROM t")?;
                let mut rows = stmt.query([])?;
                while let Some(r) = rows.next()? {
                    acc = acc.wrapping_add(r.get::<_, i64>(0)?);
                    if let Ok(ValueRef::Blob(b)) = r.get_ref(1) {
                        acc = acc.wrapping_add(b.len() as i64);
                    }
                    n += 1;
                }
            }
            let secs = t0.elapsed().as_secs_f64();
            println!("sql_full_touch,{},{}", n, n as f64 / secs);
            println!("sql_full_touch_acc,{},{}", n, acc);
        }

        // 聚合 / GROUP BY：与 Zig 侧 `sql_group_by` / `sql_agg_full` 同数据集
        // （id = 0..N-1、g = id % 100000、x = id % 1000）。
        //
        // 用**独立库文件**：① 不干扰 `t`（加列会改 sql_full / sql_each 的每行字节量，
        // 历史轮次就没法对齐）；② 能单独量落盘占用（`agg_disk_bytes`），
        // 因为「读得快」若要归因于「表更小」，两边都得给出字节数。
        {
            let agg_db = "bench-agg.db";
            let agg_wal = "bench-agg.db-wal";
            let agg_shm = "bench-agg.db-shm";
            for p in [agg_db, agg_wal, agg_shm] {
                let _ = std::fs::remove_file(p);
            }
            let ca = Connection::open(agg_db)?;
            ca.pragma_update(None, "journal_mode", "WAL")?;
            ca.pragma_update(None, "synchronous", "NORMAL")?;
            ca.execute_batch("CREATE TABLE agg(id INTEGER PRIMARY KEY, g INTEGER, x INTEGER)")?;
            {
                // 灌数据不计时（与 Zig 侧一致：那是准备，不是被测行为）
                ca.execute_batch("BEGIN")?;
                {
                    let mut stmt = ca.prepare("INSERT INTO agg(id, g, x) VALUES (?1, ?2, ?3)")?;
                    for i in 0..N {
                        stmt.execute(params![i, i % 100_000, i % 1_000])?;
                    }
                }
                ca.execute_batch("COMMIT")?;
            }
            // 落盘占用：checkpoint 后取文件大小（与 Zig「flush 后 WAL 归零」的稳态对齐）
            ca.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
            // io::Error 不能 `?` 成 rusqlite::Error（两边错误类型不同），显式取默认值
            let agg_bytes = std::fs::metadata(agg_db).map(|m| m.len()).unwrap_or(0);
            println!("agg_disk_bytes,{},{}", N, agg_bytes);

            // GROUP BY g：10 万组
            {
                let t0 = Instant::now();
                let mut groups: usize = 0;
                let mut digest: i64 = 0;
                {
                    let mut stmt = ca.prepare("SELECT g, COUNT(*), SUM(x) FROM agg GROUP BY g")?;
                    let mut rows = stmt.query([])?;
                    while let Some(r) = rows.next()? {
                        let cnt: i64 = r.get(1)?;
                        let sum: i64 = r.get(2)?;
                        digest = digest.wrapping_add(cnt.wrapping_mul(1_000_003).wrapping_add(sum));
                        groups += 1;
                    }
                }
                let secs = t0.elapsed().as_secs_f64();
                println!("sql_group_by,{},{}", N, N as f64 / secs);
                println!("sql_group_by_groups,{},0", groups);
                println!("sql_group_by_digest,{},{}", groups, digest);
            }

            // 全表聚合（无 GROUP BY）
            {
                let t0 = Instant::now();
                let (cnt, sum, min, max): (i64, i64, i64, i64) = ca.query_row(
                    "SELECT COUNT(*), SUM(x), MIN(x), MAX(x) FROM agg",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )?;
                let secs = t0.elapsed().as_secs_f64();
                println!("sql_agg_full,{},{}", N, N as f64 / secs);
                println!("sql_agg_cnt,{},0", cnt);
                println!("sql_agg_sum,{},0", sum);
                println!("sql_agg_minmax,{},{}", min, max);
            }
        }
        drop(c3);
    }

    Ok(())
}
