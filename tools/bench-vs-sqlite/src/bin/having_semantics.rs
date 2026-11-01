//! SQLite 语义 oracle：把 HAVING / 聚合的边界情况用**真实 SQLite** 跑一遍并打印结果。
//!
//! 用途：`spike-zig` 的 `exec.zig` 测试里关于 HAVING 的期望值（尤其 NULL 的三值逻辑）
//! 不能靠"我读规范觉得是这样"来定 —— 这份程序给出标准答案，两边逐行对齐。
//!
//! 跑法：`cargo run --release --bin having_semantics`
//!
//! 期望输出（SQLite 3.53.2 实测，与 `exec.zig` 的测试断言逐条对应）：
//!   Q1 g=1,2 / g=4,3             <- COUNT(*) >= 2
//!   Q2 g=1,30 / g=4,6            <- g=3 的 SUM 是 NULL，被 HAVING 排除（三值逻辑）
//!   Q3 g=1,30 / g=2,5 / g=3,NULL / g=4,6   <- 不加 HAVING 时 NULL 组确实存在
//!   Q4 (空表) 0 行                <- HAVING COUNT(*) > 0 把唯一那行过滤掉
//!   Q5 g=2 / g=3 / g=4            <- HAVING 作用在文本聚合 MIN(s) 上（本表 g=4 的 MIN='q'）
//!   Q6 g=2 / g=3                  <- HAVING 用不在选择列表里的聚合
//!   Q7 SQLite **接受** `SELECT COUNT(*) ... ORDER BY g`（我们报 ColumnNotFound，已知差异、
//!      已写进 docs/架构设计.md §16.1.38 的「已知边界」）

use rusqlite::Connection;

fn dump(conn: &Connection, sql: &str) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare(sql)?;
    let ncols = stmt.column_count();
    let mut rows = stmt.query([])?;
    let mut n = 0usize;
    while let Some(r) = rows.next()? {
        let mut cells: Vec<String> = Vec::with_capacity(ncols);
        for i in 0..ncols {
            let v: rusqlite::types::Value = r.get(i)?;
            cells.push(match v {
                rusqlite::types::Value::Null => "NULL".to_string(),
                rusqlite::types::Value::Integer(x) => x.to_string(),
                rusqlite::types::Value::Real(x) => format!("{x}"),
                rusqlite::types::Value::Text(s) => s,
                rusqlite::types::Value::Blob(b) => format!("<blob {}B>", b.len()),
            });
        }
        println!("    {}", cells.join(","));
        n += 1;
    }
    println!("    (rows={n})");
    Ok(())
}

fn main() -> rusqlite::Result<()> {
    println!("sqlite_version,{}", rusqlite::version());
    let conn = Connection::open_in_memory()?;
    conn.execute_batch(
        "CREATE TABLE h(id INTEGER PRIMARY KEY, g INTEGER, x INTEGER, s TEXT);
         INSERT INTO h(id,g,x,s) VALUES
            (1,1,10,'b'), (2,1,20,'a'), (3,2,5,'z'),
            (4,3,NULL,'m'), (5,4,1,'q'), (6,4,2,'r'), (7,4,3,'s');
         CREATE TABLE e(id INTEGER PRIMARY KEY, g INTEGER);",
    )?;

    println!("Q1  COUNT(*) >= 2");
    dump(&conn, "SELECT g, COUNT(*) FROM h GROUP BY g HAVING COUNT(*) >= 2 ORDER BY g")?;

    println!("Q2  SUM(x) >= 6   (g=3 的 SUM 是 NULL)");
    dump(&conn, "SELECT g, SUM(x) FROM h GROUP BY g HAVING SUM(x) >= 6 ORDER BY g")?;

    println!("Q3  不加 HAVING（证 NULL 组确实存在）");
    dump(&conn, "SELECT g, SUM(x) FROM h GROUP BY g ORDER BY g")?;

    println!("Q4  空表 + HAVING COUNT(*) > 0");
    dump(&conn, "SELECT COUNT(*) FROM e HAVING COUNT(*) > 0")?;

    println!("Q5  HAVING 作用在文本聚合 MIN(s) > 'b'");
    dump(&conn, "SELECT g FROM h GROUP BY g HAVING MIN(s) > 'b' ORDER BY g")?;

    println!("Q6  HAVING 用不在选择列表里的聚合");
    dump(&conn, "SELECT g FROM h GROUP BY g HAVING COUNT(*) = 1 ORDER BY g")?;

    println!("Q7  ORDER BY 只引用输出列：`SELECT COUNT(*) ... ORDER BY g` 是否被 SQLite 接受");
    match dump(&conn, "SELECT COUNT(*) FROM h GROUP BY g ORDER BY g") {
        Ok(()) => println!("    -> SQLite ACCEPTS it (we reject with ColumnNotFound)"),
        Err(e) => println!("    -> SQLite rejects: {e}"),
    }

    Ok(())
}
