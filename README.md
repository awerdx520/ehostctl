# ehostctl

Emacs frontend for [hostctl](https://github.com/guumaster/hostctl) — 在 Emacs 中管理 `/etc/hosts` profiles 和 host 条目。

## 功能

- **两层视图** — 第一层展示 profiles 概览，回车进入第二层查看具体 host 条目
- **Transient 菜单** — 按 `?` 调出操作菜单，提供操作可发现性
- **Profile 管理** — 启用/禁用/切换/添加/删除 profile
- **Host 条目管理** — 在 profile 内添加/删除单条 host 记录
- **自动备份** — 写操作前自动备份、可配置定时周期备份
- **备份与恢复** — 手动备份、备份列表浏览、一键 undo 恢复

## 依赖

- Emacs 28.1+
- [hostctl](https://github.com/guumaster/hostctl) CLI 工具
- `sudo` 权限（写操作需要）

## 安装

### 手动安装

```elisp
(add-to-list 'load-path "/path/to/ehostctl")
(require 'ehostctl)
```

### use-package

```elisp
(use-package ehostctl
  :load-path "/path/to/ehostctl")
```

### use-package + straight.el

```elisp
(use-package ehostctl
  :straight '(ehostctl :type git :host github
                       :repo "awerdx520/ehostctl" :branch "master")
  :general (leader! "te" 'ehostctl)
  :init
  (setq ehostctl-notes-file
        (expand-file-name "ehostctl-notes.eld" xxxx-cache-dir)))
```

## 使用

```
M-x ehostctl
```

打开 profile 列表视图。

### 备份与恢复

**自动备份** — 每次写操作（启用/禁用/切换/添加/删除等）执行前，ehostctl 会自动将当前 `/etc/hosts` 复制到备份目录。同一操作内的多次写入（如 rename = copy + remove）只触发一次备份。通过 `ehostctl-auto-backup` 变量控制开关。

**定时备份** — 通过 `ehostctl-backup-mode` 全局 minor mode 管理。打开 ehostctl 时自动启用；也可在 init.el 中独立启用，实现 Emacs 启动后持续后台备份，无需打开 ehostctl 界面。默认每小时备份一次，通过 `ehostctl-periodic-backup-interval` 配置间隔，设为 `nil` 禁用。

**手动备份** — 按 `b` 立即创建一份备份。

定时备份和手动备份均异步执行，不阻塞 Emacs。写操作前的自动备份同步执行以确保数据安全。

**恢复** — 两种方式：
- 按 `U` 一键恢复到最近一次备份（恢复前会先自动备份当前状态，防止误操作）
- 按 `R` 打开备份列表，浏览所有备份（含时间戳、类型、大小），选择任意一个恢复

备份文件存储在 `~/.ehostctl/backups/`，文件名格式为 `{类型}-YYYYMMDD-HHMMSS.bak`，类型分为 `auto`（写操作前）、`periodic`（定时）、`manual`（手动）。超过保留上限（默认 50 个）时自动清理最旧的备份。

### Profile 列表快捷键

| 键 | Emacs | Evil | 操作 |
|----|-------|------|------|
| `RET` | `RET` | `RET` | 进入 profile，查看 host 条目 |
| `e` | `e` | `e` | 启用 profile |
| `d` | `d` | `d` | 禁用 profile |
| `t` | `t` | `t` | 切换 profile 状态 |
| 删除 | `D` | `x` | 删除 profile |
| `a` | `a` | `a` | 添加新 profile |
| `c` | `c` | `c` | 复制 profile |
| `m` | `m` | `m` | 合并到其他 profile |
| `r` | `r` | `r` | 重命名 profile |
| `n` | `n` | `n` | 编辑 profile 描述 |
| `b` | `b` | `b` | 手动备份 hosts 文件 |
| `R` | `R` | `R` | 打开备份列表 |
| `U` | `U` | `U` | 从最近备份恢复（undo） |
| 刷新 | `g` | `gr` | 刷新列表 |
| 退出 | `q` | `q` | 退出 |
| `?` | `?` | `?` | 打开操作菜单 |

### Host 条目快捷键

| 键 | Emacs | Evil | 操作 |
|----|-------|------|------|
| `a` | `a` | `a` | 添加 host 条目 |
| 删除 | `d` | `x` | 删除 host 条目 |
| `c` | `c` | `c` | 复制到其他 profile |
| `m` | `m` | `m` | 移动到其他 profile |
| `n` | `n` | `n` | 编辑 host 描述 |
| 刷新 | `g` | `gr` | 刷新列表 |
| 退出 | `q` | `q` | 返回 profile 列表 |
| `?` | `?` | `?` | 打开操作菜单 |

### 备份列表快捷键

| 键 | Emacs | Evil | 操作 |
|----|-------|------|------|
| `RET` | `RET` | `RET` | 从选中备份恢复 |
| 删除 | `d` | `x` | 删除选中备份 |
| 刷新 | `g` | `gr` | 刷新列表 |
| 退出 | `q` | `q` | 退出 |

## 自定义

```elisp
;; hostctl 可执行文件路径（默认 "hostctl"）
(setq ehostctl-hostctl-executable "hostctl")

;; 写操作是否使用 sudo（默认 t）
(setq ehostctl-use-sudo t)

;; sudo 可执行文件路径（默认 "sudo"）
(setq ehostctl-sudo-executable "sudo")

;; 写操作前自动备份（默认 t）
(setq ehostctl-auto-backup t)

;; 备份存储目录（默认 "~/.ehostctl/backups/"）
(setq ehostctl-backup-directory "~/.ehostctl/backups/")

;; 最多保留备份数（默认 50）
(setq ehostctl-backup-max-count 50)

;; 定时备份间隔秒数，nil 禁用（默认 3600）
(setq ehostctl-periodic-backup-interval 3600)

;; 独立启用后台定时备份（无需打开 ehostctl 界面）
(ehostctl-backup-mode 1)
```

## License

GPL-3.0
