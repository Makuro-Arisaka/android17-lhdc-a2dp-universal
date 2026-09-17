{{DESC}}

---

### 安装

下载本页附件 **`{{ID}}.zip`**，在 KernelSU / Magisk 管理器里选「从本地安装」，**重启后生效**
（KernelSU 会先放进 `modules_update/`，重启才转正）。

```bash
adb push {{ID}}.zip /data/local/tmp/
adb shell su -c 'ksud module install /data/local/tmp/{{ID}}.zip'
```

> 如果设备上还留着旧 ID 的同款模块，装新的之后要一并卸掉 —— 换 ID 等于换了一个模块，
> 两份同时存在会各挂一层 overlay。

### 校验

| 项 | 值 |
|---|---|
| 模块 ID | `{{ID}}` |
| 版本 | `{{TAG}}` |
| 大小 | {{SIZE}} 字节 |
| sha256 | `{{SHA256}}` |

```bash
sha256sum {{ID}}.zip   # 应与上表一致
```

### 这个包是怎么来的

由 GitHub Actions 在 `{{SHA}}` 上跑 `./build.sh --reproducible` 构建。
时间戳取自 commit 时间，所以**任何人都能在本地构建出字节一致的同一个包** ——
可据此核对这个附件确实来自上面那个提交的源码，而不是事后塞进去的二进制。

适用前提、诊断方法与排障：[README](https://github.com/{{REPO}}/blob/{{TAG}}/README.md)
