# Nginx 1.26.2 — 单机部署

> 二进制 RPM 安装（源码编译 TODO）

---

## 一键执行

```bash
# 安装（二进制 RPM，本地包优先）
bash install_nginx.sh

# 指定端口
bash install_nginx.sh --port 8080

# 卸载（保留 /etc/nginx）
bash uninstall_nginx.sh

# 卸载（含配置）
bash uninstall_nginx.sh --data
```

---

## 版本信息

| 项目 | 值 |
|------|-----|
| Nginx | **1.26.2**（最新 stable） |
| 二进制包 | `nginx-1.26.2-1.el9.ngx.x86_64.rpm` |
| 下载 | https://nginx.org/packages/centos/9/x86_64/RPMS/ |

---

## 安装流程

```
[0/6] 已安装检测  →  版本一致则跳过
[1/6] 获取 RPM    →  本地目录 → /tmp/build-cache/ → 下载
[2/6] 安装 RPM    →  rpm -ivh
[3/6] 配置        →  日志目录 / 反向代理模板
[4/6] systemd     →  enable + start
[5/6] 功能验证    →  进程 + 端口 + HTTP 响应
[6/6] 完成
```

---

## 目录结构

```
nginx/
├── .gitignore
├── README.md
├── install_nginx.sh          # 二进制 RPM 安装
└── uninstall_nginx.sh        # 卸载清理
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--port` | HTTP 监听端口 | 80 |
| 环境变量 `NGINX_PORT` | 同 --port | 80 |
| 环境变量 `LOG_DIR` | 日志目录 | /var/log/nginx |

---

## 端口

| 端口 | 用途 |
|------|------|
| 80 | HTTP |
| 443 | HTTPS（预留） |

---

## 反向代理模板

安装后自动生成模板文件：

```
/etc/nginx/conf.d/reverse-proxy-template.conf.disabled
```

使用方法：去掉 `.disabled` 后缀，修改 `proxy_pass` 目标地址后 `systemctl reload nginx`。

---

## 系统要求

| 资源 | 最低 |
|------|------|
| CPU | 1 Core |
| 内存 | 512 MB |
| 磁盘 | 1 GB |

---

## 管理命令

```bash
systemctl start nginx        # 启动
systemctl stop nginx         # 停止
systemctl reload nginx       # 热重载配置
systemctl restart nginx      # 重启
systemctl status nginx       # 状态
journalctl -u nginx -f       # 日志
```

## 卸载

```bash
bash uninstall_nginx.sh         # 保留 /etc/nginx
bash uninstall_nginx.sh --data  # 全部清理
```

---

## TODO

- [ ] 源码编译模式：`nginx-1.26.2.tar.gz → ./configure → make → make install`
