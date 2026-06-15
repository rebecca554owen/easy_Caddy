
实现功能

Caddy 一键部署 & 管理脚本  ==================
 1) 安装 Caddy（如已安装则跳过）
 2) 配置 & 启用反向代理
 3) 查看 Caddy 服务状态
 4) 查看当前反向代理配置
 5) 删除指定的反向代理
 6) 重启 Caddy 服务
 7) 卸载 Caddy（删除配置）
 0) 退出


支持 Debian/Ubuntu系统

配置反向代理时，上游地址支持 `127.0.0.1:3000`、`http://127.0.0.1:3000/api`、`https://example.com`，或只输入端口 `3000`。末尾多余的 `/` 会自动去掉；带路径时只转发相同路径和子路径，例如 `/api` 和 `/api/*`。

常见问题：

- `caddy.service is not active, cannot reload`：表示 Caddy 当前没有运行。脚本会在 Caddy 未运行时自动改用 `systemctl restart caddy` 来启动并加载配置。
- `sudo: unable to resolve host xxx: Name or service not known`：这是系统 hostname 没有写入 `/etc/hosts`，不是 Caddy 配置错误。可用 `hostname` 查看当前主机名，然后把主机名加入 `/etc/hosts`，例如：

```bash
echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts
```

请选择以下任意一种方式一键安装和启动 Caddy 服务：

方式一：下载脚本后执行

```bash
curl -o easyCaddy.sh https://raw.githubusercontent.com/rebecca554owen/easy_Caddy/refs/heads/main/easyCaddy.sh && chmod +x easyCaddy.sh && ./easyCaddy.sh
```

方式二：直接通过 bash 执行远程脚本

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rebecca554owen/easy_Caddy/refs/heads/main/easyCaddy.sh)"
```

## AI Skill

仓库内维护了一个 Codex skill：`skills/manage-caddy`。它用于让 AI 在目标 Debian/Ubuntu 服务器上直接完成 Caddy 安装、反向代理配置、校验、重载/启动、删除、卸载和常见故障排查。

复制到本地 Codex skills 目录：

```bash
mkdir -p ~/.codex/skills
cp -R skills/manage-caddy ~/.codex/skills/
```

或使用软链接，方便跟随仓库更新：

```bash
mkdir -p ~/.codex/skills
ln -s "$(pwd)/skills/manage-caddy" ~/.codex/skills/manage-caddy
```
