-- 修复 QQ 邮箱 INBOX "更新中..." 卡住的问题
--
-- 问题原因：uid_next 被设置为 1，导致程序从头获取所有历史邮件
-- 解决方案：将 uid_next 跳到一个较大的值，只获取最近的邮件

-- 步骤 1: 查看当前状态
SELECT
    folder,
    uid_next as 当前位置,
    uidvalidity as 有效性,
    modseq as 修改序列
FROM imap_sync
WHERE folder IN ('INBOX', 'DeltaChat');

-- 步骤 2: 查看已获取的邮件数量
SELECT
    folder as 文件夹,
    COUNT(*) as 已获取邮件数
FROM imap
GROUP BY folder;

-- 步骤 3: 修复 INBOX (根据实际情况调整数字)
--
-- 方案 A: 跳过所有历史邮件，只获取新邮件
-- 警告：这会跳过所有未读邮件，只处理从现在开始收到的新邮件
-- UPDATE imap_sync SET uid_next=999999 WHERE folder='INBOX';

-- 方案 B: 获取最近 100 封邮件（推荐）
-- 1. 先查看当前 INBOX 有多少封邮件（在 QQ 邮箱网页版查看）
-- 2. 假设有 5000 封邮件，想获取最后 100 封
-- 3. 计算: 5000 - 100 = 4900
-- UPDATE imap_sync SET uid_next=4900 WHERE folder='INBOX';

-- 方案 C: 获取最近 500 封邮件
-- UPDATE imap_sync SET uid_next=4500 WHERE folder='INBOX';

-- 步骤 4: 验证修改
SELECT
    folder,
    uid_next as 新位置,
    uidvalidity
FROM imap_sync
WHERE folder='INBOX';

-- 步骤 5: (可选) 清理已获取的错误数据
-- 如果你想重新开始，可以删除已获取的邮件记录
-- DELETE FROM imap WHERE folder='INBOX';

-- 使用说明：
-- 1. 关闭 Delta Chat
-- 2. 找到数据库文件 (通常是 dc.db)
-- 3. 运行: sqlite3 dc.db < fix_qq_inbox_stuck.sql
-- 4. 根据输出结果，取消注释一个方案的 UPDATE 语句
-- 5. 再次运行脚本执行 UPDATE
-- 6. 重启 Delta Chat
