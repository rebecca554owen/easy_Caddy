#!/usr/bin/env bash
# caddy_proxy_tool.sh
# 功能：
#   1) 自动安装/卸载 Caddy
#   2) 配置反向代理
#   3) 查看 Caddy 服务状态（在菜单界面显示）
#   4) 查看当前反向代理配置，并显示上游服务是否在运行
#   5) 删除指定的反向代理配置
#   6) 重启 Caddy 服务
#   7) 一键删除 Caddy（卸载并删除配置文件）
# 适用于 Debian/Ubuntu 系列系统

# Caddyfile 默认路径
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_CONFIG_DIR="/etc/caddy"
BACKUP_CADDYFILE="${CADDYFILE}.bak"

# 反向代理配置存储
PROXY_CONFIG_FILE="/etc/caddy/caddy_reverse_proxies.txt"

function is_valid_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        return 1
    fi

    return 0
}

function is_valid_host() {
    local host=$1

    if [[ "$host" == "localhost" ]]; then
        return 0
    fi

    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        IFS='.' read -r -a octets <<< "$host"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi

    if [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])$ ]]; then
        return 0
    fi

    return 1
}

function is_valid_site_address() {
    local site=$1

    if [[ "$site" =~ ^:[0-9]+$ ]]; then
        is_valid_port "${site#:}"
        return $?
    fi

    if [[ "$site" =~ ^localhost(:[0-9]+)?$ ]]; then
        if [[ "$site" == *:* ]]; then
            is_valid_port "${site##*:}"
            return $?
        fi
        return 0
    fi

    if [[ "$site" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])(:[0-9]+)?$ ]]; then
        if [[ "$site" == *:* ]]; then
            is_valid_port "${site##*:}"
            return $?
        fi
        return 0
    fi

    return 1
}

function normalize_upstream_path() {
    local path=$1

    if [[ -z "$path" ]]; then
        echo ""
        return 0
    fi

    if [[ "$path" != /* ]]; then
        return 1
    fi

    if [[ "$path" =~ [[:space:]#?] ]]; then
        return 1
    fi

    if [[ ! "$path" =~ ^/[A-Za-z0-9._~/%-]*$ ]]; then
        return 1
    fi

    while [[ "$path" == */ && "$path" != "/" ]]; do
        path=${path%/}
    done

    if [[ "$path" == "/" ]]; then
        echo ""
    else
        echo "$path"
    fi
}

function parse_host_port_path() {
    local raw=$1
    local host_port=""
    local path=""
    local host=""
    local port=""

    if [[ "$raw" == */* ]]; then
        host_port="${raw%%/*}"
        path="/${raw#*/}"
    else
        host_port="$raw"
    fi

    if [[ "$host_port" != *:* ]]; then
        return 1
    fi

    host="${host_port%:*}"
    port="${host_port##*:}"

    if ! is_valid_host "$host"; then
        return 1
    fi

    if ! is_valid_port "$port"; then
        return 1
    fi

    path=$(normalize_upstream_path "$path") || return 1
    echo "${host}|${port}|${path}"
}

function render_proxy_block() {
    local domain=$1
    local upstream=$2
    local scheme=""
    local rest=""
    local proxy_upstream=""
    local upstream_path=""

    if [[ "$upstream" == http://* ]]; then
        scheme="http"
        rest="${upstream#http://}"
    else
        scheme="https"
        rest="${upstream#https://}"
    fi

    proxy_upstream="${scheme}://${rest%%/*}"
    if [[ "$rest" == */* ]]; then
        upstream_path="/${rest#*/}"
    fi

    echo "${domain} {"
    if [ -n "$upstream_path" ]; then
        echo "    @proxy_path path ${upstream_path} ${upstream_path}/*"
        echo "    reverse_proxy @proxy_path ${proxy_upstream} {"
    else
        echo "    reverse_proxy ${proxy_upstream} {"
    fi
    echo "        lb_try_duration 600s"
    echo "        flush_interval -1"
    echo "        transport http {"
    echo "            dial_timeout 30s"
    echo "            response_header_timeout 600s"
    echo "            read_timeout 600s"
    echo "            write_timeout 600s"
    if [ "$scheme" = "https" ]; then
        echo "            tls"
    fi
    echo "        }"
    echo "    }"
    echo "}"
}

function validate_caddy_config_file() {
    local config_file=$1
    sudo caddy validate --config "$config_file" --adapter caddyfile >/dev/null
}

function apply_caddy_config() {
    local candidate_file=$1

    if ! validate_caddy_config_file "$candidate_file"; then
        echo "Caddy 配置校验失败，未应用新配置。"
        return 1
    fi

    sudo cp "$CADDYFILE" "$BACKUP_CADDYFILE.rollback"
    sudo cp "$candidate_file" "$CADDYFILE"

    if sudo systemctl reload caddy; then
        sudo rm -f "$BACKUP_CADDYFILE.rollback"
        return 0
    fi

    echo "Caddy 重新加载失败，正在回滚配置..."
    sudo cp "$BACKUP_CADDYFILE.rollback" "$CADDYFILE"
    sudo systemctl reload caddy >/dev/null 2>&1
    sudo rm -f "$BACKUP_CADDYFILE.rollback"
    return 1
}

#--------------------------------------------
# 检查 Caddy 是否已安装
#--------------------------------------------
function check_caddy_installed() {
    if command -v caddy >/dev/null 2>&1; then
        return 0  # 已安装
    else
        return 1  # 未安装
    fi
}

#--------------------------------------------
# 安装 Caddy（官方仓库）
#--------------------------------------------
function install_caddy() {
    echo "开始安装 Caddy..."
    # 安装依赖
    sudo apt-get update
    sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl

    # 添加官方 GPG key
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    # 添加官方源
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list

    # 更新并安装 Caddy
    sudo apt-get update
    sudo apt-get install -y caddy

    if check_caddy_installed; then
        echo "Caddy 安装成功！"
    else
        echo "Caddy 安装失败，请检查日志。"
        exit 1
    fi
}

#--------------------------------------------
# 检查指定端口服务是否在运行
#--------------------------------------------
function check_port_running() {
    local host=$1
    local port=$2
    if timeout 1 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

function normalize_upstream() {
    local raw=$1
    local normalized=${raw}
    local parsed=""
    local host=""
    local port=""
    local path=""

    while [[ "$normalized" == */ ]]; do
        normalized=${normalized%/}
    done

    if [[ "$normalized" =~ ^[0-9]{1,5}$ ]]; then
        if ! is_valid_port "$normalized"; then
            return 1
        fi
        echo "http://127.0.0.1:${normalized}"
        return 0
    fi

    parsed=$(parse_host_port_path "$normalized")
    if [ $? -eq 0 ]; then
        IFS='|' read -r host port path <<< "$parsed"
        echo "http://${host}:${port}${path}"
        return 0
    fi

    if [[ "$normalized" =~ ^https?:// ]]; then
        local scheme=${normalized%%://*}
        local rest=${normalized#*://}
        local host_port=""

        if [[ "$rest" == */* ]]; then
            host_port="${rest%%/*}"
            path="/${rest#*/}"
        else
            host_port="$rest"
            path=""
        fi

        if [[ "$host_port" == *:* ]]; then
            parsed=$(parse_host_port_path "$rest")
            if [ $? -eq 0 ]; then
                IFS='|' read -r host port path <<< "$parsed"
                echo "${scheme}://${host}:${port}${path}"
                return 0
            fi
        else
            host="$host_port"
            if ! is_valid_host "$host"; then
                return 1
            fi
            path=$(normalize_upstream_path "$path") || return 1
            echo "${scheme}://${host}${path}"
            return 0
        fi
    fi

    return 1
}

function get_upstream_host_port() {
    local upstream=$1
    local scheme=""
    local host_port=""
    local host=""
    local port=""

    if [[ "$upstream" == http://* ]]; then
        scheme="http"
        host_port="${upstream#http://}"
    elif [[ "$upstream" == https://* ]]; then
        scheme="https"
        host_port="${upstream#https://}"
    else
        return 1
    fi

    host_port="${host_port%%/*}"

    if [[ "$host_port" == *:* ]]; then
        host="${host_port%:*}"
        port="${host_port##*:}"
    else
        host="$host_port"
        if [ "$scheme" = "https" ]; then
            port="443"
        else
            port="80"
        fi
    fi

    echo "${host} ${port}"
}

function write_proxy_block() {
    local domain=$1
    local upstream=$2
    render_proxy_block "$domain" "$upstream" | sudo tee -a "$CADDYFILE" >/dev/null
}

#--------------------------------------------
# 配置反向代理（输入域名及上游地址）
#--------------------------------------------
function setup_reverse_proxy() {
    local upstream=""
    local candidate_file=""

    echo "请输入域名（例如 example.com）："
    read domain
    if [ -z "$domain" ]; then
        echo "域名输入不能为空。"
        return
    fi

    if ! is_valid_site_address "$domain"; then
        echo "域名格式无效，仅支持合法域名、通配域名、localhost、localhost:端口 或 :端口。"
        return
    fi

    echo "请输入上游地址（例如 127.0.0.1:3000、http://127.0.0.1:3000/api、https://example.com，或只输入端口 3000）："
    read upstream_input
    if [ -z "$upstream_input" ]; then
        echo "上游地址不能为空。"
        return
    fi

    upstream=$(normalize_upstream "$upstream_input")
    if [ $? -ne 0 ]; then
        echo "上游地址格式无效，仅支持 host:port、http://host、https://host、http://host:port、https://host:port、可选路径，或纯端口。"
        return
    fi

    # 检查 Caddyfile 是否备份过，没有则备份一下
    if [ ! -f "$BACKUP_CADDYFILE" ]; then
        sudo cp "$CADDYFILE" "$BACKUP_CADDYFILE"
    fi

    candidate_file=$(mktemp)
    sudo cp "$CADDYFILE" "$candidate_file"
    render_proxy_block "$domain" "$upstream" | sudo tee -a "$candidate_file" >/dev/null

    echo "配置反向代理：${domain} -> ${upstream}"
    if ! apply_caddy_config "$candidate_file"; then
        rm -f "$candidate_file"
        echo "新配置未生效。"
        return
    fi
    rm -f "$candidate_file"

    echo "${domain} -> ${upstream}" | sudo tee -a "$PROXY_CONFIG_FILE" >/dev/null

    echo "新配置已生效。"

    # 检查上游服务状态
    read upstream_host upstream_port < <(get_upstream_host_port "$upstream")
    status=$(check_port_running "$upstream_host" "$upstream_port")
    echo "上游服务（${upstream_host}:${upstream_port}）状态：$status"
    echo "Caddy 服务状态："
    systemctl status caddy --no-pager
}

#--------------------------------------------
# 查看 Caddy 服务状态
#--------------------------------------------
function show_caddy_status() {
    if check_caddy_installed; then
        echo "Caddy 服务状态："
        systemctl status caddy --no-pager
    else
        echo "系统中未安装 Caddy。"
    fi
}

#--------------------------------------------
# 查看反向代理配置，并显示上游服务状态
#--------------------------------------------
function show_reverse_proxies() {
    local upstream=""
    local upstream_host=""
    local upstream_port=""
    local status=""

    if [ -f "$PROXY_CONFIG_FILE" ]; then
        echo "当前反向代理配置："
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno+1))
            upstream=$(echo "$line" | awk -F' -> ' '{print $2}')
            upstream=$(normalize_upstream "$upstream")
            if [ $? -eq 0 ] && read upstream_host upstream_port < <(get_upstream_host_port "$upstream"); then
                status=$(check_port_running "$upstream_host" "$upstream_port")
            else
                status="配置无效"
            fi
            echo "${lineno}) ${line} [上游服务状态：$status]"
        done < "$PROXY_CONFIG_FILE"
    else
        echo "没有配置任何反向代理。"
    fi
}

#--------------------------------------------
# 删除指定的反向代理
#--------------------------------------------
function delete_reverse_proxy() {
    local proxy_count=0
    local candidate_file=""
    local temp_proxy_file=""
    local original_upstream=""

    show_reverse_proxies
    echo "请输入要删除的反向代理配置编号："
    read proxy_number
    if [[ ! "$proxy_number" =~ ^[0-9]+$ ]] || [ "$proxy_number" -le 0 ]; then
        echo "无效的输入。"
        return
    fi

    if [ ! -f "$PROXY_CONFIG_FILE" ]; then
        echo "没有可删除的反向代理配置。"
        return
    fi

    proxy_count=$(wc -l < "$PROXY_CONFIG_FILE")
    if [ "$proxy_number" -gt "$proxy_count" ]; then
        echo "编号超出范围。"
        return
    fi

    if [ ! -f "$BACKUP_CADDYFILE" ]; then
        echo "未找到 Caddyfile 备份，无法安全重建配置。"
        return
    fi

    candidate_file=$(mktemp)
    temp_proxy_file=$(mktemp)
    sudo cp "$BACKUP_CADDYFILE" "$candidate_file"
    sudo cp "$PROXY_CONFIG_FILE" "$temp_proxy_file"

    sed -i "${proxy_number}d" "$temp_proxy_file"

    if [ -s "$temp_proxy_file" ]; then
        while IFS= read -r line; do
            # 解析格式 "域名 -> 上游地址"
            domain=$(echo "$line" | awk -F' -> ' '{print $1}')
            upstream=$(echo "$line" | awk -F' -> ' '{print $2}')
            original_upstream="$upstream"
            if ! is_valid_site_address "$domain"; then
                echo "发现无效域名记录：${domain}"
                rm -f "$candidate_file" "$temp_proxy_file"
                return
            fi
            upstream=$(normalize_upstream "$upstream")
            if [ $? -ne 0 ]; then
                echo "发现无效上游记录：${original_upstream}"
                rm -f "$candidate_file" "$temp_proxy_file"
                return
            fi
            render_proxy_block "$domain" "$upstream" | sudo tee -a "$candidate_file" >/dev/null
        done < "$temp_proxy_file"
    fi

    if ! apply_caddy_config "$candidate_file"; then
        rm -f "$candidate_file" "$temp_proxy_file"
        echo "删除后的配置未生效。"
        return
    fi

    if [ -s "$temp_proxy_file" ]; then
        sudo cp "$temp_proxy_file" "$PROXY_CONFIG_FILE"
    else
        sudo rm -f "$PROXY_CONFIG_FILE"
    fi

    rm -f "$candidate_file" "$temp_proxy_file"
    echo "反向代理删除成功！"
}

#--------------------------------------------
# 重启 Caddy 服务
#--------------------------------------------
function restart_caddy() {
    echo "正在重启 Caddy 服务..."
    sudo systemctl restart caddy
    echo "Caddy 服务已重启。"
    systemctl status caddy --no-pager
}

#--------------------------------------------
# 一键删除 Caddy（卸载并删除配置）
#--------------------------------------------
function remove_caddy() {
    echo "确定要卸载 Caddy 并删除配置文件吗？(y/n)"
    read confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 停止并卸载
        sudo systemctl stop caddy
        sudo apt-get remove --purge -y caddy

        # 删除仓库源
        sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
        sudo apt-get update

        # 删除配置文件
        if [ -f "$BACKUP_CADDYFILE" ]; then
            sudo rm -f "$CADDYFILE" "$BACKUP_CADDYFILE"
        else
            sudo rm -f "$CADDYFILE"
        fi

        # 删除反向代理配置文件
        if [ -f "$PROXY_CONFIG_FILE" ]; then
            sudo rm -f "$PROXY_CONFIG_FILE"
        fi

        echo "Caddy 已卸载并删除配置文件。"
    else
        echo "操作已取消。"
    fi
}

#--------------------------------------------
# 显示菜单（顶部显示 Caddy 运行状态）
#--------------------------------------------
function show_menu() {
    echo "============================================="
    # 显示 Caddy 运行状态
    caddy_status=$(systemctl is-active caddy 2>/dev/null)
    if [ "$caddy_status" == "active" ]; then
        echo "Caddy 状态：运行中"
    else
        echo "Caddy 状态：未运行"
    fi
    echo "           Caddy 一键部署 & 管理脚本          "
    echo "============================================="
    echo " 1) 安装 Caddy（如已安装则跳过）"
    echo " 2) 配置 & 启用反向代理（输入域名及上游地址）"
    echo " 3) 查看 Caddy 服务状态"
    echo " 4) 查看当前反向代理配置（显示上游服务状态）"
    echo " 5) 删除指定的反向代理"
    echo " 6) 重启 Caddy 服务"
    echo " 7) 卸载 Caddy（删除配置）"
    echo " 0) 退出"
    echo "============================================="
}

#--------------------------------------------
# 主循环
#--------------------------------------------
while true; do
    show_menu
    read -p "请输入选项: " opt
    case "$opt" in
        1)
            if check_caddy_installed; then
                echo "Caddy 已安装，跳过安装。"
            else
                install_caddy
            fi
            ;;
        2)
            if ! check_caddy_installed; then
                echo "Caddy 未安装，先执行安装步骤。"
                install_caddy
            fi
            setup_reverse_proxy
            ;;
        3)
            show_caddy_status
            ;;
        4)
            show_reverse_proxies
            ;;
        5)
            delete_reverse_proxy
            ;;
        6)
            restart_caddy
            ;;
        7)
            remove_caddy
            ;;
        0)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新输入。"
            ;;
    esac
    echo
done
