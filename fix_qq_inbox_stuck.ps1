# 修复 QQ 邮箱 INBOX "更新中..." 卡住的问题
# 适用于 Windows PowerShell

param(
    [Parameter(Mandatory=$true)]
    [string]$DatabasePath,

    [Parameter(Mandatory=$false)]
    [int]$SkipToRecent = 100  # 只获取最近 N 封邮件
)

Write-Host "=== Delta Chat QQ 邮箱修复工具 ===" -ForegroundColor Cyan
Write-Host ""

# 检查数据库文件
if (-not (Test-Path $DatabasePath)) {
    Write-Host "错误: 数据库文件不存在: $DatabasePath" -ForegroundColor Red
    exit 1
}

# 检查 SQLite
$sqliteCmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqliteCmd) {
    Write-Host "错误: 未找到 sqlite3 命令" -ForegroundColor Red
    Write-Host "请从以下地址下载 SQLite:" -ForegroundColor Yellow
    Write-Host "https://www.sqlite.org/download.html" -ForegroundColor Cyan
    exit 1
}

# 备份数据库
$BackupPath = "$DatabasePath.backup-fix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "正在备份数据库到: $BackupPath" -ForegroundColor Yellow
Copy-Item $DatabasePath $BackupPath
Write-Host "备份完成!" -ForegroundColor Green
Write-Host ""

# 查看当前状态
Write-Host "=== 当前状态 ===" -ForegroundColor Cyan
$currentState = sqlite3 $DatabasePath @"
SELECT
    folder || ' : uid_next=' || uid_next || ', uidvalidity=' || uidvalidity
FROM imap_sync
WHERE folder IN ('INBOX', 'DeltaChat');
"@
Write-Host $currentState -ForegroundColor White

Write-Host ""
Write-Host "=== 已获取邮件数 ===" -ForegroundColor Cyan
$messageCount = sqlite3 $DatabasePath @"
SELECT
    folder || ' : ' || COUNT(*) || ' 封'
FROM imap
GROUP BY folder;
"@
Write-Host $messageCount -ForegroundColor White

# 询问用户
Write-Host ""
Write-Host "检测到问题：INBOX 的 uid_next 可能被设置为很小的值" -ForegroundColor Yellow
Write-Host "这会导致程序尝试获取所有历史邮件，造成'更新中...'卡住" -ForegroundColor Yellow
Write-Host ""
Write-Host "请选择修复方案:" -ForegroundColor Cyan
Write-Host "1. 只获取最近 $SkipToRecent 封邮件 (推荐)" -ForegroundColor Green
Write-Host "2. 只获取从现在开始的新邮件" -ForegroundColor Yellow
Write-Host "3. 自定义获取邮件数量" -ForegroundColor White
Write-Host "4. 取消" -ForegroundColor Gray
Write-Host ""

$choice = Read-Host "请输入选项 (1-4)"

switch ($choice) {
    "1" {
        Write-Host ""
        Write-Host "方案 1: 获取最近 $SkipToRecent 封邮件" -ForegroundColor Cyan
        Write-Host "注意：你需要知道邮箱中大约有多少封邮件" -ForegroundColor Yellow
        $totalEmails = Read-Host "请输入 QQ 邮箱 INBOX 中的邮件总数（在网页版查看）"

        if ($totalEmails -match '^\d+$') {
            $newUidNext = [int]$totalEmails - $SkipToRecent
            if ($newUidNext -lt 1) { $newUidNext = 1 }

            Write-Host "将设置 uid_next = $newUidNext (跳过前 $newUidNext 封，获取最后 $SkipToRecent 封)" -ForegroundColor Green

            sqlite3 $DatabasePath "UPDATE imap_sync SET uid_next=$newUidNext WHERE folder='INBOX';"

            Write-Host "修复完成!" -ForegroundColor Green
        } else {
            Write-Host "无效的数字" -ForegroundColor Red
            exit 1
        }
    }

    "2" {
        Write-Host ""
        Write-Host "方案 2: 只获取新邮件" -ForegroundColor Cyan
        Write-Host "警告：将跳过所有现有邮件，只处理从现在开始收到的新邮件" -ForegroundColor Red
        $confirm = Read-Host "确定吗? (y/n)"

        if ($confirm -eq 'y') {
            sqlite3 $DatabasePath "UPDATE imap_sync SET uid_next=999999 WHERE folder='INBOX';"
            Write-Host "修复完成!" -ForegroundColor Green
        } else {
            Write-Host "已取消" -ForegroundColor Gray
            exit 0
        }
    }

    "3" {
        Write-Host ""
        $customCount = Read-Host "请输入想要获取的最近邮件数量"
        $totalEmails = Read-Host "请输入邮箱中的邮件总数"

        if ($customCount -match '^\d+$' -and $totalEmails -match '^\d+$') {
            $newUidNext = [int]$totalEmails - [int]$customCount
            if ($newUidNext -lt 1) { $newUidNext = 1 }

            Write-Host "将设置 uid_next = $newUidNext" -ForegroundColor Green
            sqlite3 $DatabasePath "UPDATE imap_sync SET uid_next=$newUidNext WHERE folder='INBOX';"
            Write-Host "修复完成!" -ForegroundColor Green
        } else {
            Write-Host "无效的输入" -ForegroundColor Red
            exit 1
        }
    }

    "4" {
        Write-Host "已取消" -ForegroundColor Gray
        exit 0
    }

    default {
        Write-Host "无效的选项" -ForegroundColor Red
        exit 1
    }
}

# 显示修复后的状态
Write-Host ""
Write-Host "=== 修复后状态 ===" -ForegroundColor Cyan
$newState = sqlite3 $DatabasePath @"
SELECT
    folder || ' : uid_next=' || uid_next || ', uidvalidity=' || uidvalidity
FROM imap_sync
WHERE folder='INBOX';
"@
Write-Host $newState -ForegroundColor Green

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Cyan
Write-Host "备份文件: $BackupPath" -ForegroundColor Gray
Write-Host ""
Write-Host "请重启 Delta Chat，问题应该已解决！" -ForegroundColor Green
Write-Host "如果还有问题，可以用备份文件恢复：" -ForegroundColor Yellow
Write-Host "  copy `"$BackupPath`" `"$DatabasePath`"" -ForegroundColor Gray
