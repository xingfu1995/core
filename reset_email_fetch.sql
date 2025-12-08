-- Delta Chat 邮件获取重置脚本
-- 在数据库损坏时尝试只修改必要的表

-- 方法 1：重置所有文件夹的 uid_next
UPDATE imap_sync SET uid_next=0;

-- 方法 2：只重置 INBOX
-- UPDATE imap_sync SET uid_next=0 WHERE folder='INBOX';

-- 方法 3：完全清空重新同步
-- UPDATE imap_sync SET uid_next=0, uidvalidity=0, modseq=0;
-- DELETE FROM imap;

-- 查看结果
SELECT folder, uid_next, uidvalidity, modseq FROM imap_sync;
