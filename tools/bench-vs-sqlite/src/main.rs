//! SQLite 瀵圭収鍩哄噯锛堜笌 spike-zig 鐨?bench 鍚屾暟鎹泦銆佸悓鍙ｅ緞锛夈€?
//!
//! 鍙ｅ緞锛?
//! - `journal_mode=WAL`銆乣synchronous=NORMAL`锛圫QLite 鐨勫父瑙勬帹鑽愰厤缃級锛?
//! - 1,000,000 琛岋紝涓婚敭 i64 閫掑锛屽€?32B锛?
//! - `put` = 閫愯 autocommit锛堝搴?Zig 渚х殑閫愯 put + 缁勬彁浜わ級锛?
//! - `put_txn` = 鍗曚簨鍔℃壒閲忔彃鍏ワ紙瀵圭収鎵归噺鍐欙級锛?
//! - `get` = 10 涓囨闅忔満涓婚敭鐐规煡锛堥缂栬瘧璇彞锛夛紱
//! - `scan` = 涓婚敭鑼冨洿 1 涓囪锛?
//! - `recover_ms` = 鍏抽棴鍚庨噸寮€ + 棣栨煡鑰楁椂銆?

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

    // 閫愯 autocommit
    let t0 = Instant::now();
    {
        let mut stmt = conn.prepare("INSERT INTO t(id, v) VALUES (?1, ?2)")?;
        for i in 0..N {
            stmt.execute(params![i, &value[..]])?;
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    println!("put,{},{}", N, N as f64 / secs);

    // 鍗曚簨鍔℃壒閲忔彃鍏ワ紙鐙珛琛?t2锛?
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

    // 鐐规煡
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

    // 鑼冨洿鎵弿
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

    // 鑼冨洿鎵弿锛堝甫鍊硷紝涓?Zig 渚у悓鍙ｅ緞锛?
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

    // 澶ф牱鏈寖鍥存壂鎻忥紙20 涓囪锛屽尯闂?0..200000锛屼笌 Zig 渚?scan_full / scan_refs_full 鍚屽彛寰勶級銆?
    // 涓婇潰閭ｄ袱妗ｅ彧鎵?1 涓囪锛岀粷瀵硅€楁椂 <1碌s锛屾祴鐨勬槸鍥哄畾寮€閿€涓庤鏃剁矑搴?鈥斺€?
    // 鐢ㄥ畠姣斻€屾壂鎻忚兘鍔涖€嶄細璁╀袱杈瑰尯闂撮噸鍙犮€佹案杩滃緱涓嶅嚭缁撹銆?
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

    // 鑼冨洿鎵弿锛?0 涓囪锛壜?**鏀堕泦寮曠敤**锛氬绛?Zig 鐨?`scan_refs`銆?
    //
    // 涓轰粈涔堝繀椤绘湁杩欎竴妗ｏ細`scan_refs` 浼氭妸姣忔潯鍛戒腑璁板綍鏀惰繘鏁扮粍锛?0 涓?脳 48B = 9.6MB 鍐欏叆锛夛紝
    // 鑰?`scan_big` 鍙帹杩涙父鏍囥€佷竴鏉￠兘涓嶆敹 鈥斺€?鎷胯繖涓や釜姣斿緱鍑恒€屾垜浠?0.70脳銆嶆槸**鍙ｅ緞涓嶅绛?*鐨勪骇鐗┿€?
    // 杩欓噷琛ヤ笂銆孲QLite 涔熸敹闆嗐€嶇殑鐗堟湰锛氱敤 `get_ref` 鍙栧紩鐢紙**涓嶅鍒?payload**锛夛紝
    // 涓?`RefRecord{key 鎸囬拡,len, seq, flags, value 鎸囬拡,len}` 鍋氱殑宸ヤ綔绛変环銆?
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

    // 閲嶅紑 + 棣栨煡
    let t0 = Instant::now();
    let conn2 = open_conn()?;
    let _: Vec<u8> = conn2.query_row("SELECT v FROM t WHERE id = ?1", params![12345i64], |r| r.get(0))?;
    let ms = t0.elapsed().as_secs_f64() * 1000.0;
    println!("recover,{},{}", N, ms);
    println!("recover_read,1,1");

    drop(conn2);

    // ---------------- 骞跺彂鍐欙紙瀵归綈 Zig 渚с€岃法琛ㄥ苟琛屻€嶏細姣忕嚎绋嬬嫭绔嬪簱鏂囦欢锛?----------------
    let conc_per: i64 = 300_000;
    for nt in [1usize, 2, 4] {
        // (a) 閫愯 autocommit 鈥斺€?瀵瑰簲 Zig 渚ч€愯 put锛圸ig 鏈夎法琛岀粍鎻愪氦锛孲QLite 杩欓噷鏄瘡琛屼竴娆℃彁浜わ級
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

        // (b) 姣忕嚎绋嬪崟浜嬪姟 鈥斺€?瀵瑰簲 Zig 渚ф壒閲忓啓鑳藉姏锛圫QLite 鐨勬渶浣冲舰鎬侊級
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

    // ---------------- 瓒呭唴瀛樻暟鎹泦锛?00 涓囪锛?----------------
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

        // 钀界洏鍗犵敤锛氫笌 Zig 鐨?`big_disk_bytes` 瀵圭瓑銆?
        //
        // 鍏?`wal_checkpoint(TRUNCATE)` 鎶?WAL 褰掑苟鍥炰富搴?鈥斺€?鎴戜滑閭ｈ竟 flush 瀹屼細鍒犳帀 WAL锛?
        // 涓?checkpoint 灏辨槸鎷裤€屾垜浠凡鏀跺熬銆嶆瘮銆孲QLite 鏈敹灏俱€嶏紝涓嶅叕骞炽€?
        // 缁熻 db + -wal + -shm 涓変釜鏂囦欢鐨勫疄闄呭瓧鑺傛暟锛堜笉鍚换浣曟垜浠殑鍙ｅ緞鎹㈢畻锛夈€?
        {
            let _ = c.pragma_update(None, "wal_checkpoint", "TRUNCATE");
            let fsz = |p: &str| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            let total = fsz(path) + fsz(&format!("{path}-wal")) + fsz(&format!("{path}-shm"));
            println!("big_disk_bytes,{},{}", BIG, total);
            // Print with decimals: integer division turned 41.56 into 41 and the Zig side's
            // 40.92 into 40, so both sides were biased but by different amounts.
            println!("big_disk_bytes_row,1,{:.3}", total as f64 / BIG as f64);
        }

        // 闅忔満鐐规煡
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

        // 鑼冨洿鎵弿锛堜粎 key锛屼笌 Zig big_scan_refs 鍚屽彛寰勶級
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

        // 绾亶鍘嗚鏁帮紙涓嶅彇鍊硷級銆備笌涓婇潰 big_scan 鐨勫樊鍒彧鏄牱鏈粠 1 涓囪鏀惧ぇ鍒?50 涓囪 鈥斺€?
        // 1 涓囪鐨勭粷瀵硅€楁椂 <1碌s锛屾祴鐨勬槸鍥哄畾寮€閿€鑰岄潪鎵弿鑳藉姏銆?
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

        // 瓒呭唴瀛?路 鍖洪棿銆屽彧鏁拌銆嶏紙20 涓囪锛夛細瀵圭瓑 Zig 鐨?`big_count_range`銆?
        // big_scan 鍙壂 1 涓囪銆佺粷瀵硅€楁椂 <1碌s锛沚ig_count 鎵?50 涓囪浣嗚捣鐐?0 鈥斺€?
        // 杩欎竴妗ｅ浐瀹?20 涓囪鍖洪棿锛屼笌鍐呭瓨鍐呴偅妗ｅ悓鏍锋湰閲忥紝渚夸簬妯瘮銆屽唴瀛樺唴 vs 瓒呭唴瀛樸€嶈“鍑忓箙搴︺€?
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

        // 绾?open锛堜笌 Zig 鐨?`Table.open` 瀵圭瓑锛夛細鍙紑杩炴帴 + 涓ゆ pragma锛?*涓嶅仛浠讳綍鏌ヨ**銆?
        // 鍘熷彛寰勯噷杩樺甫浜嗕竴鏉?`query_row`锛岃€?Zig 渚?`big_recover` 鍙噺 open 鈥斺€?
        // 涓よ竟鍋氱殑浜嬩笉鍚岋紝姣斿嚭鏉ョ殑鍊嶆暟娌℃湁鎰忎箟锛堣繖鏄湰椤圭洰绗?5 娆¤俯鍚屼竴涓潙锛夈€?
        {
            let t0 = Instant::now();
            let c_open = Connection::open(path)?;
            c_open.pragma_update(None, "journal_mode", "WAL")?;
            c_open.pragma_update(None, "synchronous", "NORMAL")?;
            println!("big_recover_open,{},{}", BIG, t0.elapsed().as_secs_f64() * 1000.0);
            drop(c_open);
        }

        // 閲嶅紑 + 棣栨鐐规煡锛堝師鍙ｅ緞锛屼繚鐣欎綔鍙傝€冿紝涓嶈鍏ュ绛夌粨璁猴級
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

    // ---------------- 闅忔満鍘熷湴 UPDATE锛堢洰鏍囩嚎 搂16.1锛歋QLite 寮洪」锛?----------------
    // 鍦ㄥ凡瀛樺湪鐨?100 涓囪琛?t 涓婇殢鏈烘敼 10 涓囪鐨勫€硷紱涓ょ褰㈡€侀兘娴嬶細
    //   upd_random_auto = 閫愭潯 autocommit锛泆pd_random_txn = 鍗曚簨鍔★紙SQLite 鏈€浣冲舰鎬侊紝涓诲姣斿彛寰勶級銆?
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

        // 鏇存柊鍚庣偣鏌ワ紙涓?Zig 渚?upd_get 鍚屽彛寰勶級
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

        // DELETE锛?00 涓囪琛ㄤ笂鎸変富閿垹 10 涓囪锛屼竴娆℃彁浜ゃ€?
        //
        // 鍙ｅ緞涓?Zig 渚?`del_100k` 閫愭潯瀵归綈锛氬悓涓€涓?xorshift64 搴忓垪锛堢瀛?88172645463325252锛夈€?
        // 鍚屾牱鍙?`x % N`銆佸悓鏍枫€屽惊鐜唴鍙璐︺€佹湯灏句竴娆℃彁浜ゃ€嶃€?
        // 娉ㄦ剰 id 鍙兘閲嶅锛堥殢鏈哄簭鍒椾細鎾烇級锛屼袱杈归兘涓€鏍凤紝鎵€浠ュ墿浣欒鏁拌瀹炴祴鑰屼笉鏄畻銆?
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
        // 姝ｇ‘鎬?1锛氳鍒犵殑 key 蹇呴』鏌ヤ笉鍒?
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
        // 姝ｇ‘鎬?2锛氬墿浣欒鏁帮紙瀹炴祴锛屼笉鐢?n - get_n 鎺ㄧ畻 鈥斺€?闅忔満搴忓垪鏈夐噸澶嶅€硷級
        {
            let cnt: i64 = c3.query_row("SELECT COUNT(*) FROM t", [], |r| r.get(0))?;
            println!("del_remaining,{},{}", N, cnt);
        }

        // 鍒嗛〉鏌ヨ锛堜笌 Zig 渚?sql_limit10 / sql_full 鍚屽彛寰勶紝鍚屼竴寮?100 涓囪琛級
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
        // SQL 鐐规煡锛氫笌 Zig 渚?`sql_get` **鍚屼竴涓殢鏈哄簭鍒椼€佸悓鏍风殑涓婚敭鍒嗗竷** 鈥斺€?
        // 璧?SQL 鎺ュ彛鍋?10 涓囨涓婚敭鐐规煡锛堜笉鏄?`get` 閭ｇ鐩磋繛瀛樺偍 API锛夈€?
        // 闅忔満鏁扮敤 xorshift64 + 鍚屼竴涓瀛愶紝鍚﹀垯涓よ竟鐐圭殑涓嶆槸鍚屼竴鎵?key锛屾瘮杈冩棤鎰忎箟銆?
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
        // 鎺掑簭 + 鍒嗛〉锛坱op-N锛夛細涓?Zig 渚?`sql_orderby_limit10` 鍚屼竴鏉¤鍙ャ€佸悓涓€寮?100 涓囪琛ㄣ€?
        //
        // SQLite 鑷繁涔熸湁 sorter 鐨?top-N 浼樺寲锛堝彧瑕佸墠 N 鍚嶅氨涓嶄繚鐣欏叏閮級锛?
        // 鎵€浠ヨ繖涓€妗ｆ槸銆屼袱杈归兘鏈?top-N 浼樺寲銆嶇殑瀵圭瓑姣旇緝锛岃€屼笉鏄嬁鎴戜滑鐨勫叏閲忔帓搴忔瘮瀹冦€?
        //
        // **閲嶅 200 娆″彇涓綅**锛堝璁?2026-11-02锛夛細鍗曟 ~50 碌s 琚満鍣ㄦ姈鍔ㄦ饭娌★紝
        // 涓?Zig 渚у悓鍙ｅ緞銆俙prepare` 绉诲埌璁℃椂澶?鈥斺€?涓や晶閮戒笉鎶娿€岀紪璇?瑙ｆ瀽銆嶇畻杩涘幓銆?
        {
            let mut stmt = c3.prepare("SELECT * FROM t ORDER BY id DESC LIMIT 10")?;
            const REPS: usize = 200;
            let mut samples: Vec<(f64, usize)> = Vec::with_capacity(REPS);
            for _ in 0..REPS {
                let t0 = Instant::now();
                let mut n: usize = 0;
                {
                    let mut rows = stmt.query([])?;
                    while rows.next()?.is_some() {
                        n += 1;
                    }
                }
                samples.push((t0.elapsed().as_secs_f64(), n));
            }
            samples.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
            let (med, n) = samples[REPS / 2];
            println!("sql_orderby_limit10,{},{}", n, n as f64 / med);
            // 鍗曚綅缁熶竴鎴?**寰**锛堜笌 Zig 渚у悓瀛楁鍚嶏紝渚夸簬涓や晶鐩存帴瀵圭収锛?
            println!("sql_orderby_limit10_med_us,{},{:.1}", REPS, med * 1e6);
        }
        // 涓婇潰鐨?sql_full 鍙帹杩涙父鏍囥€?*涓嶅彇鍒楀€?*銆係QLite 鐨?`OP_Column` 鏄儼鎬х殑锛?
        // 涓嶈皟鐢?`column_*` 灏辨牴鏈笉瑙ｇ爜锛屾墍浠ラ偅涓暟瀛楀彧浠ｈ〃銆屾父鏍囨帹杩涖€嶃€?
        // 杩欎竴妗ｆ妸涓ゅ垪閮界湡璇诲嚭鏉ワ紙閮界敤闆舵嫹璐濓紝涓?malloc锛夛細
        //   id -> i64 鍊兼嫹璐濓紱v -> `get_ref` 鍙栧垏鐗囷紝涓?Zig 渚с€宼ext 鎸囧悜 mmap 涓嶅鍒躲€嶅悓鍙ｅ緞銆?
        // 杩欐墠鏄笌 `sql_each`锛堟垜浠瘡琛岄兘瀹屾暣瑙ｇ爜涓ゅ垪锛夊绛夌殑姣旇緝銆?
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

        // 鑱氬悎 / GROUP BY锛氫笌 Zig 渚?`sql_group_by` / `sql_agg_full` 鍚屾暟鎹泦
        // 锛坕d = 0..N-1銆乬 = id % 100000銆亁 = id % 1000锛夈€?
        //
        // 鐢?*鐙珛搴撴枃浠?*锛氣憼 涓嶅共鎵?`t`锛堝姞鍒椾細鏀?sql_full / sql_each 鐨勬瘡琛屽瓧鑺傞噺锛?
        // 鍘嗗彶杞灏辨病娉曞榻愶級锛涒憽 鑳藉崟鐙噺钀界洏鍗犵敤锛坄agg_disk_bytes`锛夛紝
        // 鍥犱负銆岃寰楀揩銆嶈嫢瑕佸綊鍥犱簬銆岃〃鏇村皬銆嶏紝涓よ竟閮藉緱缁欏嚭瀛楄妭鏁般€?
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
            ca.execute_batch("CREATE TABLE agg(id INTEGER PRIMARY KEY, g INTEGER NOT NULL, x INTEGER NOT NULL)")?;
            {
                // 鐏屾暟鎹笉璁℃椂锛堜笌 Zig 渚т竴鑷达細閭ｆ槸鍑嗗锛屼笉鏄娴嬭涓猴級
                ca.execute_batch("BEGIN")?;
                {
                    let mut stmt = ca.prepare("INSERT INTO agg(id, g, x) VALUES (?1, ?2, ?3)")?;
                    for i in 0..N {
                        stmt.execute(params![i, i % 100_000, i % 1_000])?;
                    }
                }
                ca.execute_batch("COMMIT")?;
            }
            // 钀界洏鍗犵敤锛歝heckpoint 鍚庡彇鏂囦欢澶у皬锛堜笌 Zig銆宖lush 鍚?WAL 褰掗浂銆嶇殑绋虫€佸榻愶級
            ca.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
            // io::Error 涓嶈兘 `?` 鎴?rusqlite::Error锛堜袱杈归敊璇被鍨嬩笉鍚岋級锛屾樉寮忓彇榛樿鍊?
            let agg_bytes = std::fs::metadata(agg_db).map(|m| m.len()).unwrap_or(0);
            println!("agg_disk_bytes,{},{}", N, agg_bytes);

            // GROUP BY g锛?0 涓囩粍
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

            // 鍏ㄨ〃鑱氬悎锛堟棤 GROUP BY锛?
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

            // HAVING + ORDER BY 鑱氬悎 + LIMIT锛坱op-N锛夈€備笌 Zig 渚у悓涓€鏉?SQL銆?
            // 蹇呴』甯︽绾ф帓搴忛敭 g锛氬彧鎸?SUM(x) 鎺掑簭鏃?100 涓粍骞跺垪锛?
            // 涓や晶鐨勫苟鍒楅『搴忎笉涓€瀹氱浉鍚岋紝digest 灏变細鈥滈兘瀵逛絾瀵逛笉涓娾€濄€?
            {
                let t0 = Instant::now();
                let mut n: usize = 0;
                let mut digest: i64 = 0;
                {
                    let mut stmt = ca.prepare(
                        "SELECT g, COUNT(*), SUM(x) FROM agg GROUP BY g HAVING SUM(x) > 4500 \
                         ORDER BY SUM(x) DESC, g ASC LIMIT 10",
                    )?;
                    let mut rows = stmt.query([])?;
                    while let Some(r) = rows.next()? {
                        let cnt: i64 = r.get(1)?;
                        let sum: i64 = r.get(2)?;
                        digest = digest.wrapping_add(cnt.wrapping_mul(1_000_003).wrapping_add(sum));
                        n += 1;
                    }
                }
                let secs = t0.elapsed().as_secs_f64();
                println!("sql_having_top10,{},{}", N, N as f64 / secs);
                println!("sql_having_rows,{},0", n);
                println!("sql_having_digest,{},{}", n, digest);
            }

            // 浜岀骇绱㈠紩锛氫笌 Zig 渚у悓涓€鏉＄储寮曪紙agg(g)锛夈€佸悓涓€涓叉煡璇€佸悓涓€浠?digest銆?
            // 杈圭晫涓?Zig 渚т竴鑷达細鍙鐩栧崟鍒楃瓑鍊兼煡璇€?
            {
                let before = std::fs::metadata(agg_db).map(|m| m.len()).unwrap_or(0);
                let t0 = Instant::now();
                ca.execute_batch("CREATE INDEX idx_g ON agg(g)")?;
                println!("sql_index_build,{},{}", N, t0.elapsed().as_millis());
                ca.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
                let after = std::fs::metadata(agg_db).map(|m| m.len()).unwrap_or(0);
                println!("sql_index_disk_bytes,{},{}", N, after.saturating_sub(before));

                let lookups: u64 = 5_000;
                let mut x: u64 = 88172645463325252;
                let mut total_rows: usize = 0;
                let mut digest: i64 = 0;
                let t0 = Instant::now();
                // Same criteria: select a column that is NEITHER the indexed one NOR the PK.
                // `SELECT id` would be a covering-index read on the SQLite side (the index
                // entry carries the rowid) while we still have to fetch the row -- that is a
                // different criteria, so the probe uses `x`.
                {
                    let mut stmt = ca.prepare("SELECT x FROM agg WHERE g = ?1")?;
                    for _ in 0..lookups {
                        x ^= x << 13;
                        x ^= x >> 7;
                        x ^= x << 17;
                        let g = (x % 100_000) as i64;
                        let mut rows = stmt.query([g])?;
                        while let Some(r) = rows.next()? {
                            digest = digest.wrapping_add(r.get::<_, i64>(0)?);
                            total_rows += 1;
                        }
                    }
                }
                let secs = t0.elapsed().as_secs_f64();
                println!("sql_index_eq,{},{}", total_rows, lookups as f64 / secs);
                println!("sql_index_eq_rows,{},0", total_rows);
                println!("sql_index_eq_digest,{},{}", total_rows, digest);

                // ORDER BY <indexed col> ASC LIMIT 10：与 Zig 侧 `sql_orderby_index10` 同一条语句。
                // 索引 `idx_g(g)` 直接给出 g 的顺序，投影里的 `x` 不是索引列 ⇒ 两侧都必须回表；
                // 同样 200 次取中位，`prepare` 在计时外。
                {
                    let mut stmt = ca.prepare("SELECT x, g FROM agg ORDER BY g ASC LIMIT 10")?;
                    const REPS: usize = 200;
                    let mut samples: Vec<(f64, usize)> = Vec::with_capacity(REPS);
                    let mut got_rows: usize = 0;
                    let mut digest: i64 = 0;
                    for _ in 0..REPS {
                        let t0 = Instant::now();
                        let mut n: usize = 0;
                        let mut d: i64 = 0;
                        {
                            let mut rows = stmt.query([])?;
                            while let Some(r) = rows.next()? {
                                d = d
                                    .wrapping_add(r.get::<_, i64>(0)?.wrapping_mul(31))
                                    .wrapping_add(r.get::<_, i64>(1)?);
                                n += 1;
                            }
                        }
                        samples.push((t0.elapsed().as_secs_f64(), n));
                        got_rows += n;
                        digest = digest.wrapping_add(d);
                    }
                    samples.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
                    let (med, n) = samples[REPS / 2];
                    println!("sql_orderby_index10,{},{}", n, n as f64 / med);
                    println!("sql_orderby_index10_rows,{},0", got_rows);
                    println!("sql_orderby_index10_digest,{},{}", got_rows, digest);
                    println!("sql_orderby_index10_med_us,{},{:.1}", REPS, med * 1e6);
                }

                // WHERE + ORDER BY the same indexed column + LIMIT: the index gives both the
                // range lower bound and the order, so both sides should stop after 10 rows.
                // This closes the gap noted for our engine (WHERE still forced a full scan).
                {
                    let mut stmt = ca.prepare(
                        "SELECT x, g FROM agg WHERE g >= 50000 ORDER BY g ASC LIMIT 10",
                    )?;
                    const REPS: usize = 200;
                    let mut samples: Vec<(f64, usize)> = Vec::with_capacity(REPS);
                    let mut got_rows: usize = 0;
                    let mut digest: i64 = 0;
                    for _ in 0..REPS {
                        let t0 = Instant::now();
                        let mut n: usize = 0;
                        let mut d: i64 = 0;
                        {
                            let mut rows = stmt.query([])?;
                            while let Some(r) = rows.next()? {
                                d = d
                                    .wrapping_add(r.get::<_, i64>(0)?.wrapping_mul(31))
                                    .wrapping_add(r.get::<_, i64>(1)?);
                                n += 1;
                            }
                        }
                        samples.push((t0.elapsed().as_secs_f64(), n));
                        got_rows += n;
                        digest = digest.wrapping_add(d);
                    }
                    samples.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
                    let (med, n) = samples[REPS / 2];
                    println!("sql_where_orderby_index10,{},{}", n, n as f64 / med);
                    println!("sql_where_orderby_index10_rows,{},0", got_rows);
                    println!("sql_where_orderby_index10_digest,{},{}", got_rows, digest);
                    println!("sql_where_orderby_index10_med_us,{},{:.1}", REPS, med * 1e6);
                }
            }
        }
        drop(c3);
    }

    Ok(())
}
