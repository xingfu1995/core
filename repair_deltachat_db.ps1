# Delta Chat 数据库修复和重置脚本
# 适用于 Windows PowerShell

param(
    [Parameter(Mandatory=$true)]
    [string]$DatabasePath,

    [string]$Password = "",

    [switch]$ResetEmailFetch,

    [switch]$ForceRepair
)

Write-Host "=== Delta Chat 数据库修复工具 ===" -ForegroundColor Cyan
Write-Host ""

# 检查数据库文件是否存在
if (-not (Test-Path $DatabasePath)) {
    Write-Host "错误: 数据库文件不存在: $DatabasePath" -ForegroundColor Red
    exit 1
}

# 备份原始数据库
$BackupPath = "$DatabasePath.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "正在备份数据库到: $BackupPath" -ForegroundColor Yellow
Copy-Item $DatabasePath $BackupPath
Write-Host "备份完成!" -ForegroundColor Green
Write-Host ""

# 检查是否安装了 SQLite
$sqliteCmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqliteCmd) {
    Write-Host "警告: 未找到 sqlite3 命令" -ForegroundColor Yellow
    Write-Host "请从以下地址下载 SQLite:" -ForegroundColor Yellow
    Write-Host "https://www.sqlite.org/download.html" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "下载后将 sqlite3.exe 放到此脚本目录或添加到 PATH" -ForegroundColor Yellow
    exit 1
}

# 尝试修复数据库
if ($ForceRepair) {
    Write-Host "正在尝试修复数据库..." -ForegroundColor Yellow

    $RepairedPath = "$DatabasePath.repaired"

    # 导出并重建
    $dumpFile = "$DatabasePath.dump.sql"

    Write-Host "步骤 1/3: 导出数据..." -ForegroundColor Yellow
    if ($Password) {
        # 如果有密码，需要使用 sqlcipher
        Write-Host "检测到加密数据库，需要使用 SQLCipher" -ForegroundColor Yellow
        $sqlcipherCmd = Get-Command sqlcipher -ErrorAction SilentlyContinue
        if (-not $sqlcipherCmd) {
            Write-Host "错误: 未找到 sqlcipher 命令" -ForegroundColor Red
            Write-Host "请从以下地址下载 SQLCipher:" -ForegroundColor Yellow
            Write-Host "https://www.zetetic.net/sqlcipher/" -ForegroundColor Cyan
            exit 1
        }

        @"
PRAGMA key = '$Password';
.output $dumpFile
.dump
.quit
"@ | sqlcipher $DatabasePath
    } else {
        sqlite3 $DatabasePath ".dump" | Out-File -Encoding UTF8 $dumpFile
    }

    Write-Host "步骤 2/3: 创建新数据库..." -ForegroundColor Yellow
    if (Test-Path $dumpFile) {
        Get-Content $dumpFile | sqlite3 $RepairedPath
        Write-Host "步骤 3/3: 验证新数据库..." -ForegroundColor Yellow

        $integrity = sqlite3 $RepairedPath "PRAGMA integrity_check;"
        if ($integrity -eq "ok") {
            Write-Host "修复成功!" -ForegroundColor Green
            Write-Host "修复后的数据库: $RepairedPath" -ForegroundColor Cyan
        } else {
            Write-Host "修复失败，数据库仍有问题: $integrity" -ForegroundColor Red
        }
    } else {
        Write-Host "导出失败，无法修复" -ForegroundColor Red
    }
}

# 重置邮件获取
if ($ResetEmailFetch) {
    Write-Host ""
    Write-Host "正在重置邮件获取状态..." -ForegroundColor Yellow

    $targetDb = if (Test-Path "$DatabasePath.repaired") { "$DatabasePath.repaired" } else { $DatabasePath }

    $sqlCommands = @"
UPDATE imap_sync SET uid_next=0;
SELECT 'Folders reset:' as info;
SELECT folder, uid_next, uidvalidity FROM imap_sync;
"@

    if ($Password) {
        @"
PRAGMA key = '$Password';
$sqlCommands
.quit
"@ | sqlcipher $targetDb
    } else {
        $sqlCommands | sqlite3 $targetDb
    }

    Write-Host "邮件获取状态已重置!" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== 操作完成 ===" -ForegroundColor Cyan
Write-Host "备份文件: $BackupPath" -ForegroundColor Gray
