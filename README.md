# ehostctl

Emacs frontend for [hostctl](https://github.com/guumaster/hostctl) — 在 Emacs 中管理 `/etc/hosts` profiles 和 host 条目。

## 功能

- **两层视图** — 第一层展示 profiles 概览，回车进入第二层查看具体 host 条目
- **Transient 菜单** — 按 `?` 调出操作菜单，提供操作可发现性
- **Profile 管理** — 启用/禁用/切换/添加/删除 profile
- **Host 条目管理** — 在 profile 内添加/删除单条 host 记录
- **备份与恢复** — 支持 hosts 文件的备份和恢复

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
| `b` | `b` | `b` | 备份 hosts 文件 |
| `R` | `R` | `R` | 从备份恢复 |
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

## 自定义

```elisp
;; hostctl 可执行文件路径（默认 "hostctl"）
(setq ehostctl-hostctl-executable "hostctl")

;; 写操作是否使用 sudo（默认 t）
(setq ehostctl-use-sudo t)

;; sudo 可执行文件路径（默认 "sudo"）
(setq ehostctl-sudo-executable "sudo")
```

## License

GPL-3.0
