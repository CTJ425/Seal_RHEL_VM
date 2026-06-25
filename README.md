# RHEL8/RHEL9/RHEL10 VM Template Seal Script

# 編輯紀錄

| 編輯日期 | 編輯人員 | 編輯內容 |
| --- | --- | --- |
| 2026/06/25 | Ivan Chen | 初版 |
| 2026/06/25 | Ivan Chen | 強化 OS 判斷與必要清理步驟錯誤處理 |
| 2026/06/25 | Ivan Chen | 補強 NetworkManager 介面名稱綁定清理 |
| 2026/06/25 | Ivan Chen | 補充 RHEL/Rocky 10.x 支援與 Satellite 套件偵測修正 |

# 適用版本

- Red Hat Enterprise Linux 8.x
- Red Hat Enterprise Linux 9.x
- Red Hat Enterprise Linux 10.x
- Rocky Linux 8.x
- Rocky Linux 9.x
- Rocky Linux 10.x

# 檔案說明

| 檔案 | 說明 |
| --- | --- |
| `seal-rhel-template.sh` | 自動判斷 RHEL/Rocky 相容系統 8.x、9.x 或 10.x，並清理 VM 範本化前不應保留的主機識別資料。 |

# 使用方式

先將 script 複製到要封裝成範本的 VM，並確認使用 root 權限執行。

```bash
chmod +x seal-rhel-template.sh
sudo ./seal-rhel-template.sh --dry-run
sudo ./seal-rhel-template.sh --yes
```

如果要在清理完成後自動關機：

```bash
sudo ./seal-rhel-template.sh --yes --poweroff
```

# 參數

| 參數 | 說明 |
| --- | --- |
| `--dry-run` | 僅顯示會執行的動作，不修改系統。 |
| `--yes` | 略過互動確認，適合自動化流程使用。 |
| `--poweroff` | 清理完成後執行 `systemctl poweroff` 關機。 |
| `-h`, `--help` | 顯示使用說明。 |

# Script 執行內容

## 自動判斷系統版本

Script 會讀取 `/etc/os-release`，確認作業系統屬於 RHEL/Rocky 相容系列，並判斷主要版本為 8、9 或 10。若不是 RHEL/Rocky 相容的 8.x、9.x 或 10.x，script 會停止執行。

## 取消 RHEL 註冊

當系統識別為 RHEL 且存在 `subscription-manager` 時，會執行：

```bash
subscription-manager unregister
subscription-manager remove --all
subscription-manager clean
```

Rocky Linux 會略過此步驟。

## 清除網路識別資訊

Script 會清除下列檔案中的 MAC、UUID、NetworkManager 連線唯一識別資訊與介面名稱綁定：

- `/etc/sysconfig/network-scripts/ifcfg-*`
- `/etc/NetworkManager/system-connections/*.nmconnection`

同時會刪除：

```bash
/etc/udev/rules.d/70-persistent-*
```

## 清空 hosts 與 DNS resolver

Script 會清空以下檔案內容，但不刪除檔案本身：

```bash
/etc/hosts
/etc/resolv.conf
```

## 重設主機名稱

```bash
hostnamectl set-hostname localhost.localdomain
```

## 刪除 SSH Host Keys

```bash
rm -f /etc/ssh/ssh_host_*
```

新的 SSH host keys 會在 VM 從範本開機後由系統重新產生。

## 重設 Machine ID

RHEL/Rocky 8.x：

```bash
rm -f /var/lib/dbus/machine-id
printf 'uninitialized\n' > /etc/machine-id
```

RHEL/Rocky 9.x 與 10.x：

```bash
rm -f /etc/machine-id
printf 'uninitialized\n' > /etc/machine-id
chmod 644 /etc/machine-id
```

RHEL/Rocky 9.x 與 10.x 需要保留 `/etc/machine-id` 權限為 `644`，避免影響 dbus-broker 與相關服務。

## 清理選用元件

如果系統存在相關工具或檔案，script 會清理：

- Satellite/Katello consumer package 與 `/etc/rhsm/facts/katello.facts`
- iSCSI initiator name：`/etc/iscsi/initiatorname.iscsi`
- cloud-init logs 與 seed data
- Red Hat Insights 註冊

## 清除 Shell History

Script 會刪除 root 與一般使用者家目錄下的 `.bash_history`。

# 注意事項

- 請先使用 `--dry-run` 確認動作。
- 必要清理步驟失敗時，script 會停止執行；選用元件清理失敗時，script 會記錄訊息並繼續。
- 執行前請確認 VM 不再需要保留目前的註冊、網路、SSH host key、machine-id 與 history 資料。
- 清理完成後應關機，再將 VM 轉換為範本。
