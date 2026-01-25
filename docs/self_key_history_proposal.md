# 统计自己用过的私钥方案

## 概述

本方案用于统计账户历史上用过多少个不同的私钥。通过解析发出邮件中的 `Autocrypt` header，提取公钥指纹并存入新表进行去重统计。

---

## 背景

- 私钥可能丢失，但发出的邮件中包含当时使用的公钥
- `Autocrypt` header 包含发送者的公钥
- 通过分析历史邮件可以还原使用过的私钥数量

---

## 实现方案

### 1. 创建新表

**文件**: `src/sql/migrations.rs`

在 migrations.rs 中添加新的迁移：

```rust
if dbversion < 69 {
    sql.execute_migration(
        "CREATE TABLE self_key_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fingerprint TEXT NOT NULL UNIQUE,
            public_key BLOB,
            first_seen INTEGER DEFAULT 0
        ) STRICT;",
        69,
    )
    .await?;
}
```

**表结构说明**:

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | INTEGER | 主键，自增 |
| `fingerprint` | TEXT | 公钥指纹，唯一约束用于去重 |
| `public_key` | BLOB | 可选，存储完整公钥数据 |
| `first_seen` | INTEGER | 首次发现该公钥的时间戳 |

---

### 2. 在 receive_imf 中记录公钥

**文件**: `src/receive_imf.rs`

**插入位置**: 约 855 行，`from_id == ContactId::SELF` 判断处

```rust
// 在处理发出的邮件时，记录使用的公钥
if !mime_parser.incoming {
    if let Some(fingerprint) = &mime_parser.autocrypt_fingerprint {
        context.sql.execute(
            "INSERT INTO self_key_history (fingerprint, first_seen)
             VALUES (?, ?)
             ON CONFLICT (fingerprint) DO NOTHING",
            (fingerprint, std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64),
        ).await?;
    }
}
```

---

### 3. 关键代码位置参考

| 文件 | 行号 | 变量/函数 | 说明 |
|------|------|----------|------|
| `src/mimeparser.rs` | 104 | `autocrypt_fingerprint: Option<String>` | 公钥指纹字段 |
| `src/mimeparser.rs` | 425-426 | `autocrypt_header.public_key.dc_fingerprint().hex()` | 指纹计算 |
| `src/receive_imf.rs` | 855 | `if from_id == ContactId::SELF` | 判断是否自己发出 |
| `src/aheader.rs` | 85-136 | `Aheader::from_str()` | 解析 Autocrypt header |

---

## 查询接口

### 统计私钥数量

```sql
SELECT COUNT(*) FROM self_key_history;
```

### 列出所有用过的私钥

```sql
SELECT
    fingerprint,
    datetime(first_seen, 'unixepoch', 'localtime') as first_used
FROM self_key_history
ORDER BY first_seen ASC;
```

### 在代码中查询

```rust
/// 获取用过的私钥数量
pub async fn get_self_key_count(context: &Context) -> Result<usize> {
    context.sql.count("SELECT COUNT(*) FROM self_key_history", ()).await
}

/// 获取所有用过的私钥指纹
pub async fn get_self_key_fingerprints(context: &Context) -> Result<Vec<String>> {
    context.sql.query_map(
        "SELECT fingerprint FROM self_key_history ORDER BY first_seen",
        (),
        |row| row.get(0),
        |rows| rows.collect::<Result<Vec<_>, _>>().map_err(Into::into),
    ).await
}
```

---

## 判断邮件是否加密

### 方法 1: 解析时判断 (MIME 结构)

**文件**: `src/decrypt.rs:29`

```rust
use crate::decrypt::get_encrypted_mime;

let mail = mailparse::parse_mail(raw_bytes)?;
if get_encrypted_mime(&mail).is_some() {
    // 这是 PGP 加密邮件
}
```

### 方法 2: 解析后判断

**文件**: `src/mimeparser.rs:967`

```rust
// MimeMessage 解析后
if mime_parser.was_encrypted() {
    // 邮件已加密且签名有效
}
```

### 方法 3: 数据库查询

```sql
-- 加密消息 (param 包含 c=1)
SELECT * FROM msgs WHERE param LIKE '%c=1%';

-- 未加密消息
SELECT * FROM msgs WHERE param NOT LIKE '%c=1%' OR param IS NULL;
```

### 方法 4: Message 对象判断

**文件**: `src/message.rs:823-827`

```rust
let msg = Message::load_from_db(context, msg_id).await?;
if msg.get_showpadlock() {
    // 显示加密锁图标（已加密）
}
```

---

## 未加密邮件分类方案

### 在 Chatlist 中过滤未加密邮件

**文件**: `src/chatlist.rs`

```rust
impl Chatlist {
    /// 加载包含未加密消息的聊天列表
    pub async fn try_load_unencrypted(context: &Context) -> Result<Self> {
        let process_row = |row: &rusqlite::Row| {
            let chat_id: ChatId = row.get(0)?;
            let msg_id: Option<MsgId> = row.get(1)?;
            Ok((chat_id, msg_id))
        };

        let ids = context.sql.query_map(
            "SELECT c.id, m.id
             FROM chats c
             INNER JOIN msgs m ON c.id = m.chat_id
             WHERE c.id > 9
               AND c.blocked != 1
               AND (m.param NOT LIKE '%c=1%' OR m.param IS NULL)
               AND m.hidden = 0
             GROUP BY c.id
             ORDER BY m.timestamp DESC, m.id DESC",
            (),
            process_row,
            |rows| rows.collect::<std::result::Result<Vec<_>, _>>().map_err(Into::into),
        ).await?;

        Ok(Chatlist { ids })
    }
}
```

---

## 数据库表结构参考

### 现有相关表

```sql
-- 私钥存储表
CREATE TABLE keypairs (
    id INTEGER PRIMARY KEY,
    addr TEXT DEFAULT '' COLLATE NOCASE,
    is_default INTEGER DEFAULT 0,
    private_key,
    public_key,
    created INTEGER DEFAULT 0
);

-- 公钥存储表 (联系人的公钥)
CREATE TABLE public_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fingerprint TEXT NOT NULL UNIQUE,
    public_key BLOB NOT NULL
) STRICT;

-- 消息表 (param 字段包含加密标志)
CREATE TABLE msgs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER,
    from_id INTEGER,
    param TEXT DEFAULT '',  -- 包含 'c=1' 表示加密
    ...
);
```

### 新增表

```sql
-- 自己用过的公钥历史记录
CREATE TABLE self_key_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fingerprint TEXT NOT NULL UNIQUE,
    public_key BLOB,
    first_seen INTEGER DEFAULT 0
) STRICT;
```

---

## 流程图

```
┌─────────────────────────────────────────────────────────────┐
│                    邮件接收流程                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  receive_imf()  │
                    │ src/receive_imf.rs
                    └────────┬────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ 解析 MimeMessage │
                    │ src/mimeparser.rs
                    └────────┬────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ 提取 Autocrypt   │
                    │ header 中的公钥  │
                    └────────┬────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
    ┌─────────────────┐             ┌─────────────────┐
    │ incoming = true │             │ incoming = false│
    │   (收到的邮件)   │             │   (发出的邮件)   │
    └────────┬────────┘             └────────┬────────┘
              │                               │
              ▼                               ▼
    ┌─────────────────┐             ┌─────────────────┐
    │ 存储发送者公钥   │             │ 记录自己的公钥   │
    │ → public_keys   │             │ → self_key_history
    └─────────────────┘             └─────────────────┘
                                              │
                                              ▼
                                    ┌─────────────────┐
                                    │ 统计用过的私钥  │
                                    │ SELECT COUNT(*) │
                                    │ FROM self_key_history
                                    └─────────────────┘
```

---

## 注意事项

1. **PKESK Key ID 是通配符**: Delta Chat 使用 `encrypt_to_key_anonymous()` 加密，收到的加密邮件中的 Key ID 是通配符，无法用于识别私钥

2. **只有发出的邮件有效**: 只有发出的邮件的 `Autocrypt` header 包含自己的公钥

3. **数据库迁移版本**: 添加新表时需要更新 `DBVERSION` 常量 (`src/sql/migrations.rs:26`)

4. **指纹格式**: 使用大写十六进制字符串，40 个字符

---

## 文件修改清单

| 文件 | 修改内容 |
|------|---------|
| `src/sql/migrations.rs` | 添加 `self_key_history` 表迁移 |
| `src/receive_imf.rs` | 在发出邮件处理时记录公钥 |
| `src/chatlist.rs` | (可选) 添加未加密邮件过滤方法 |

---

## 作者

本方案由 Claude 根据 Delta Chat Core 代码库分析生成

**日期**: 2026-01-25
