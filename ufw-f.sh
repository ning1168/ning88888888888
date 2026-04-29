#!/usr/bin/env bash

# ==================================================
# UFW / Fail2Ban 中文轻量管理脚本 增强版
# 支持：
# - 安装 UFW 防火墙
# - 安装 Fail2Ban 防爆破
# - 自动封禁扫描器
# - 日志只保留 7 天
# - 一键自检 + 风险检测 + 安全评分
# - 彻底卸载本脚本
# - ufw -f 快捷进入管理菜单
#
# 适合 Debian / Ubuntu 小型 VPS
# ==================================================

set -u

REAL_UFW="/usr/sbin/ufw"
SELF_MENU="/usr/local/sbin/ufw-f-menu"
WRAPPER_UFW="/usr/local/sbin/ufw"
LOGROTATE_FILE="/etc/logrotate.d/ufw-fail2ban-lite"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 权限运行：sudo $0"
        exit 1
    fi
}

pause() {
    echo
    read -rp "按回车继续..."
}

pkg_install() {
    apt update
    apt install -y "$@"
}

install_self_alias() {
    cp "$0" "$SELF_MENU"
    chmod +x "$SELF_MENU"

    if [ -x "$REAL_UFW" ]; then
        cat >"$WRAPPER_UFW" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-f" ]; then
    exec /usr/local/sbin/ufw-f-menu
else
    exec /usr/sbin/ufw "$@"
fi
EOF
        chmod +x "$WRAPPER_UFW"
    fi
}

check_tools() {
    command -v ufw >/dev/null 2>&1 && UFW_OK=1 || UFW_OK=0
    command -v fail2ban-client >/dev/null 2>&1 && F2B_OK=1 || F2B_OK=0
}

install_log_limit() {
    need_root

    mkdir -p /etc/logrotate.d

    cat >"$LOGROTATE_FILE" <<'EOF'
# ==================================================
# UFW / Fail2Ban 日志限制配置
# 说明：
# - 每天轮转一次日志
# - 只保留 7 天
# - 自动压缩旧日志
# - 避免小内存 VPS 被日志占满磁盘
# ==================================================

/var/log/fail2ban.log
/var/log/ufw.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl reload fail2ban >/dev/null 2>&1 || true
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF

    echo "日志限制已设置：UFW / Fail2Ban 日志只保留 7 天。"
}

install_ufw() {
    need_root

    if command -v ufw >/dev/null 2>&1; then
        echo "UFW 防火墙已安装，跳过安装。"
    else
        pkg_install ufw
    fi

    echo
    read -rp "请输入需要放行的 SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    ufw allow "${ssh_port}/tcp" comment "SSH 远程连接端口"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging on

    echo
    echo "即将启用 UFW 防火墙。"
    echo "请确认 SSH 端口 ${ssh_port}/tcp 已放行，否则可能无法远程连接服务器。"
    read -rp "是否启用 UFW？[Y/n]：" yn
    yn="${yn:-Y}"

    case "$yn" in
        y|Y)
            ufw --force enable
            systemctl enable ufw >/dev/null 2>&1 || true
            systemctl restart ufw >/dev/null 2>&1 || true
            ;;
        *)
            echo "已跳过启用 UFW。"
            ;;
    esac

    install_self_alias
    install_log_limit
    pause
}

edit_fail2ban_basic_config() {
    need_root

    echo
    echo "========== Fail2Ban 基础防护配置 =========="
    echo "不输入则使用默认值。"
    echo

    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    read -rp "最大失败次数 maxretry，默认 5：" maxretry
    maxretry="${maxretry:-5}"

    read -rp "检测时间窗口 findtime，默认 10m：" findtime
    findtime="${findtime:-10m}"

    read -rp "封禁时间 bantime，默认 1h：" bantime
    bantime="${bantime:-1h}"

    read -rp "是否启用递增封禁？默认 y：[Y/n] " inc
    inc="${inc:-Y}"

    case "$inc" in
        y|Y) bantime_increment="true" ;;
        *) bantime_increment="false" ;;
    esac

    mkdir -p /etc/fail2ban

    cat >/etc/fail2ban/jail.local <<EOF
# ==================================================
# Fail2Ban 基础防护配置
# 文件位置：/etc/fail2ban/jail.local
# ==================================================

[DEFAULT]

# 忽略 IP
# 这里的 IP 不会被封禁
# 默认包含本机地址，避免系统自己封自己
ignoreip = 127.0.0.1/8 ::1

# 封禁时间
# 例子：
# 10m = 10 分钟
# 1h  = 1 小时
# 1d  = 1 天
bantime = ${bantime}

# 检测时间窗口
# 在这个时间范围内失败次数达到 maxretry，就会被封禁
findtime = ${findtime}

# 最大失败次数
# 例如设置 5，表示 findtime 时间内失败 5 次就封禁
maxretry = ${maxretry}

# 递增封禁
# true  = 多次违规会越封越久
# false = 每次都使用固定封禁时间
bantime.increment = ${bantime_increment}

# 日志后端
# systemd 适合 Debian / Ubuntu 新系统，轻量稳定
backend = systemd

# 封禁动作
# ufw 表示使用 UFW 防火墙封禁 IP
banaction = ufw

# 邮件通知
# 默认关闭，只封禁，不发邮件，适合轻量 VPS
action = %(action_)s


[sshd]

# SSH 登录防爆破
# 用于防止别人暴力猜 SSH 密码
enabled = true

# SSH 端口
# 如果你改过 SSH 端口，这里必须对应
port = ${ssh_port}

# 使用 sshd 过滤规则
filter = sshd

# SSH 日志路径
# %(sshd_log)s 是 Fail2Ban 自动识别的 SSH 日志
logpath = %(sshd_log)s

# 使用 systemd 读取日志
backend = systemd
EOF

    echo "基础防护配置已写入：/etc/fail2ban/jail.local"
}

install_fail2ban() {
    need_root

    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "Fail2Ban 已安装，跳过安装。"
    else
        pkg_install fail2ban
    fi

    edit_fail2ban_basic_config
    install_log_limit

    systemctl enable fail2ban
    systemctl restart fail2ban

    install_self_alias
    echo "Fail2Ban 基础防护已启用。"
    pause
}

install_scanner_jail() {
    need_root

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "请先安装 Fail2Ban。"
        pause
        return
    fi

    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d

    cat >/etc/fail2ban/filter.d/ufw-scanner.conf <<'EOF'
# ==================================================
# UFW 扫描器识别规则
# 文件位置：/etc/fail2ban/filter.d/ufw-scanner.conf
# ==================================================

[Definition]

# 匹配 UFW BLOCK 日志中的来源 IP
# 用于识别频繁撞端口、扫端口、恶意探测的 IP
failregex = ^.*\[UFW BLOCK\].*SRC=<HOST> .*$

# 忽略规则
ignoreregex =
EOF

    cat >/etc/fail2ban/jail.d/ufw-scanner.local <<'EOF'
# ==================================================
# UFW 自动封禁扫描器配置
# 文件位置：/etc/fail2ban/jail.d/ufw-scanner.local
# ==================================================

[ufw-scanner]

# 是否启用这个防护
enabled = true

# 读取 UFW 日志
logpath = /var/log/ufw.log

# 使用扫描器识别规则
filter = ufw-scanner

# 检测时间窗口
# 10 分钟内触发多次就封禁
findtime = 10m

# 最大失败次数
# 10 分钟内触发 8 次 UFW BLOCK 就封禁
maxretry = 8

# 封禁时间
# 默认封禁 6 小时
bantime = 6h

# 使用 UFW 封禁
banaction = ufw

# 日志后端
backend = auto
EOF

    ufw logging on >/dev/null 2>&1 || true
    install_log_limit
    systemctl restart fail2ban

    echo "自动封禁扫描器已启用。"
    echo "防护名称：ufw-scanner"
    pause
}

install_all_security() {
    install_ufw
    install_fail2ban
    install_scanner_jail
    install_log_limit
    echo "一键安全防护安装完成。"
    pause
}

security_self_check() {
    need_root

    score=100
    warn_count=0
    danger_count=0

    ok() { echo "✅ $1"; }
    warn() { echo "⚠️  $1"; score=$((score-8)); warn_count=$((warn_count+1)); }
    danger() { echo "❌ $1"; score=$((score-15)); danger_count=$((danger_count+1)); }

    clear
    echo "========== 一键自检 + 风险检测 + 当前安全评分 =========="
    echo

    echo "【1】UFW 防火墙状态"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -qi "Status: active"; then
            ok "UFW 已启用"
        else
            danger "UFW 未启用，本机防火墙可能没有生效"
        fi

        ufw_status_verbose="$(ufw status verbose 2>/dev/null || true)"
        echo "$ufw_status_verbose" | grep -qi "Default: deny (incoming)" \
            && ok "默认入站策略为 deny，未放行端口会被拦截" \
            || danger "默认入站策略不是 deny，可能存在全部放行风险"

        echo "$ufw_status_verbose" | grep -qi "allow (outgoing)" \
            && ok "默认出站策略为 allow，正常访问外网不受影响" \
            || warn "默认出站策略不是 allow，请确认是否符合你的需求"

        ufw status numbered
    else
        danger "未安装 UFW"
    fi

    echo
    echo "【2】底层防火墙规则检测"
    if command -v iptables >/dev/null 2>&1; then
        iptables -S | grep -q "ufw" \
            && ok "检测到底层 iptables 中存在 UFW 规则" \
            || warn "iptables 中没有明显 UFW 规则，可能 UFW 未正确写入规则"
    else
        warn "未找到 iptables 命令，无法检查底层规则"
    fi

    if command -v nft >/dev/null 2>&1; then
        nft list ruleset 2>/dev/null | grep -qi "ufw" \
            && ok "检测到 nftables 中存在 UFW 规则" \
            || warn "nftables 中没有明显 UFW 规则，这在部分系统不一定是问题"
    fi

    echo
    echo "【3】SSH 连接安全"
    ssh_port_guess="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
    ssh_port_guess="${ssh_port_guess:-22}"

    if command -v ufw >/dev/null 2>&1; then
        ufw status | grep -Eq "${ssh_port_guess}(/tcp)?[[:space:]]+ALLOW" \
            && ok "SSH 端口 ${ssh_port_guess} 已在 UFW 中放行" \
            || warn "没有明显看到 SSH 端口 ${ssh_port_guess} 放行规则，请确认避免断连"

        ufw status | grep -Eq "22(/tcp)?[[:space:]]+ALLOW" \
            && warn "检测到 22 端口放行，如果你没有改 SSH 端口，容易被扫描爆破" \
            || ok "未看到 22 端口明显放行，若你使用自定义 SSH 端口，这是好事"
    fi

    echo
    echo "【4】Fail2Ban 防爆破状态"
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban; then
            ok "Fail2Ban 服务正在运行"
        else
            danger "Fail2Ban 服务未运行"
        fi

        jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"
        if [ -n "$jail_list" ]; then
            ok "当前启用的防护：$jail_list"
        else
            warn "未检测到启用中的 Fail2Ban Jail"
        fi

        fail2ban-client status sshd >/dev/null 2>&1 \
            && ok "sshd 防爆破已启用" \
            || warn "sshd 防爆破未启用或读取失败"

        fail2ban-client status ufw-scanner >/dev/null 2>&1 \
            && ok "自动封禁扫描器 ufw-scanner 已启用" \
            || warn "未启用自动封禁扫描器 ufw-scanner"
    else
        warn "未安装 Fail2Ban"
    fi

    echo
    echo "【5】日志保留与磁盘风险"
    if [ -f "$LOGROTATE_FILE" ]; then
        grep -q "rotate 7" "$LOGROTATE_FILE" \
            && ok "日志轮转已配置为保留 7 天" \
            || warn "日志轮转存在，但不是保留 7 天"
    else
        warn "未找到日志保留 7 天配置"
    fi

    df -h /
    root_use="$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ "${root_use:-0}" -ge 90 ]; then
        danger "根分区磁盘使用率超过 90%，日志或服务可能出问题"
    elif [ "${root_use:-0}" -ge 75 ]; then
        warn "根分区磁盘使用率超过 75%，建议清理"
    else
        ok "根分区空间看起来正常"
    fi

    echo
    echo "【6】常见绕过本机防火墙风险"
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
            warn "检测到 Docker 正在运行。Docker 发布端口可能绕过 UFW，需要单独检查 Docker 防火墙规则"
        else
            ok "检测到 Docker 但未运行"
        fi
    else
        ok "未检测到 Docker"
    fi

    if ss -tulpen >/dev/null 2>&1; then
        echo
        echo "当前监听端口："
        ss -tulpen | awk 'NR==1 || /LISTEN|UNCONN/'
    else
        warn "无法使用 ss 查看监听端口"
    fi

    echo
    echo "【7】云服务商安全组提醒"
    echo "说明：云服务商安全组是外层防火墙，UFW 是服务器本机防火墙。"
    echo "如果云控制台全部放行，本机 UFW 仍然应该能拦截。"
    echo "如果你禁用了某端口但仍能访问，常见原因："
    echo "1. UFW 实际没有 active"
    echo "2. 默认入站不是 deny"
    echo "3. 服务通过 Docker 发布端口绕过 UFW"
    echo "4. 访问的是 IPv6，但你只限制了 IPv4"
    echo "5. 规则顺序或 allow 规则仍存在"
    echo "6. 服务在内网访问，不经过你以为的公网入口"
    echo "7. 云厂商控制台放行不是问题本身，它只是不会帮你挡流量"

    echo
    if [ "$score" -lt 0 ]; then score=0; fi
    echo "========== 当前安全评分 =========="
    echo "安全分：${score}/100"
    echo "高风险项：${danger_count}"
    echo "提醒项：${warn_count}"
    echo

    if [ "$score" -ge 85 ]; then
        echo "评级：优秀"
    elif [ "$score" -ge 70 ]; then
        echo "评级：良好"
    elif [ "$score" -ge 50 ]; then
        echo "评级：一般，需要检查"
    else
        echo "评级：较危险，建议立即处理"
    fi

    pause
}

show_fail2ban_running_protection() {
    echo "========== 当前正在运行的 Fail2Ban 防护 =========="
    fail2ban-client status
    echo
    echo "提示：Jail list 后面的名称就是当前启用的防护。"
}

show_all_jail_detail() {
    echo "========== 所有 Jail 防护详情 =========="
    jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')

    if [ -z "${jails:-}" ]; then
        echo "没有检测到正在运行的 Jail。"
        return
    fi

    for jail in $jails; do
        jail="$(echo "$jail" | xargs)"
        echo
        echo "---------- ${jail} ----------"
        fail2ban-client status "$jail"
    done
}

show_banned_all() {
    echo "========== 所有防护的封禁 IP =========="
    jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')

    if [ -z "${jails:-}" ]; then
        echo "没有检测到正在运行的 Jail。"
        return
    fi

    for jail in $jails; do
        jail="$(echo "$jail" | xargs)"
        echo
        echo "---------- ${jail} ----------"
        fail2ban-client status "$jail" | grep "Banned IP list" || true
    done
}

unban_ip_menu() {
    read -rp "请输入要解封的 IP：" ip

    if [ -z "$ip" ]; then
        echo "IP 不能为空。"
        return
    fi

    echo
    echo "1. 从 sshd 防护中解封"
    echo "2. 从 ufw-scanner 防护中解封"
    echo "3. 从所有防护中尝试解封"
    read -rp "请选择：" c

    case "$c" in
        1) fail2ban-client set sshd unbanip "$ip" ;;
        2) fail2ban-client set ufw-scanner unbanip "$ip" ;;
        3)
            jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')
            for jail in $jails; do
                jail="$(echo "$jail" | xargs)"
                fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
            done
            echo "已尝试从所有防护中解封 ${ip}"
            ;;
        *) echo "无效选择。" ;;
    esac
}

ufw_menu() {
    while true; do
        clear
        echo "========== UFW 防火墙管理 =========="
        echo "1. 查看状态"
        echo "2. 查看详细状态"
        echo "3. 列出规则编号"
        echo "4. 添加允许端口"
        echo "5. 添加拒绝端口"
        echo "6. 删除规则编号"
        echo "7. 删除指定端口允许规则"
        echo "8. 启用 UFW 防火墙"
        echo "9. 禁用 UFW 防火墙"
        echo "10. 重载 UFW 防火墙"
        echo "11. 重置 UFW 防火墙"
        echo "12. 开启 UFW 日志"
        echo "13. 关闭 UFW 日志"
        echo "14. 一键自检 + 风险检测 + 安全评分"
        echo "0. 返回主菜单"
        echo

        read -rp "请选择：" c

        case "$c" in
            1) ufw status ;;
            2) ufw status verbose ;;
            3) ufw status numbered ;;
            4)
                read -rp "端口，例如 80 或 443/tcp：" port
                ufw allow "$port" comment "用户添加允许规则"
                ;;
            5)
                read -rp "端口，例如 3306 或 3306/tcp：" port
                ufw deny "$port" comment "用户添加拒绝规则"
                ;;
            6)
                ufw status numbered
                read -rp "请输入要删除的规则编号：" num
                ufw delete "$num"
                ;;
            7)
                read -rp "端口，例如 80 或 443/tcp：" port
                ufw delete allow "$port"
                ;;
            8) ufw --force enable ;;
            9) ufw disable ;;
            10) ufw reload ;;
            11)
                read -rp "确认重置所有 UFW 规则？输入 YES：" yes
                [ "$yes" = "YES" ] && ufw --force reset
                ;;
            12) ufw logging on ;;
            13) ufw logging off ;;
            14) security_self_check; return ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac

        pause
    done
}

fail2ban_menu() {
    while true; do
        clear
        echo "========== Fail2Ban 防爆破 / 扫描器管理 =========="
        echo "1. 查看 Fail2Ban 服务状态"
        echo "2. 查看当前正在运行的防护"
        echo "3. 查看所有防护详情"
        echo "4. 查看 SSH 防爆破状态"
        echo "5. 查看所有封禁 IP"
        echo "6. 解封 IP"
        echo "7. 编辑基础防护配置"
        echo "8. 启用自动封禁扫描器"
        echo "9. 查看 Fail2Ban 日志"
        echo "10. 查看 UFW 扫描器日志来源"
        echo "11. 测试 Fail2Ban 配置"
        echo "12. 重载 Fail2Ban 配置"
        echo "13. 重启 Fail2Ban 服务"
        echo "14. 停止 Fail2Ban 服务"
        echo "15. 启动 Fail2Ban 服务"
        echo "16. 查看基础配置文件"
        echo "17. 查看扫描器配置文件"
        echo "18. 安装/刷新日志保留 7 天配置"
        echo "19. 一键自检 + 风险检测 + 安全评分"
        echo "0. 返回主菜单"
        echo

        read -rp "请选择：" c

        case "$c" in
            1) systemctl status fail2ban --no-pager ;;
            2) show_fail2ban_running_protection ;;
            3) show_all_jail_detail ;;
            4) fail2ban-client status sshd ;;
            5) show_banned_all ;;
            6) unban_ip_menu ;;
            7)
                edit_fail2ban_basic_config
                fail2ban-client reload
                systemctl restart fail2ban
                ;;
            8) install_scanner_jail ;;
            9)
                if [ -f /var/log/fail2ban.log ]; then
                    tail -n 100 /var/log/fail2ban.log
                else
                    journalctl -u fail2ban -n 100 --no-pager
                fi
                ;;
            10)
                if [ -f /var/log/ufw.log ]; then
                    tail -n 100 /var/log/ufw.log
                else
                    echo "未找到 /var/log/ufw.log，可以先执行：ufw logging on"
                fi
                ;;
            11) fail2ban-client -t ;;
            12) fail2ban-client reload ;;
            13) systemctl restart fail2ban ;;
            14) systemctl stop fail2ban ;;
            15) systemctl start fail2ban ;;
            16) cat /etc/fail2ban/jail.local ;;
            17)
                echo "========== Jail 配置 =========="
                cat /etc/fail2ban/jail.d/ufw-scanner.local 2>/dev/null || echo "未安装 ufw-scanner"
                echo
                echo "========== Filter 配置 =========="
                cat /etc/fail2ban/filter.d/ufw-scanner.conf 2>/dev/null || true
                ;;
            18) install_log_limit ;;
            19) security_self_check; return ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac

        pause
    done
}

uninstall_ufw() {
    need_root
    read -rp "确认卸载 UFW 并清理配置？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    ufw --force disable >/dev/null 2>&1 || true
    apt purge -y ufw
    apt autoremove -y
    rm -rf /etc/ufw
    rm -f "$WRAPPER_UFW"

    echo "UFW 已卸载并清理。"
    pause
}

uninstall_fail2ban() {
    need_root
    read -rp "确认卸载 Fail2Ban 并清理配置？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    apt purge -y fail2ban
    apt autoremove -y
    rm -rf /etc/fail2ban
    rm -f /var/log/fail2ban.log

    echo "Fail2Ban 已卸载并清理。"
    pause
}

uninstall_this_script_only() {
    need_root

    echo "此功能只清理本管理脚本，不卸载 UFW / Fail2Ban。"
    echo "会删除："
    echo "$SELF_MENU"
    echo "$WRAPPER_UFW"
    echo "$LOGROTATE_FILE"
    echo
    read -rp "确认彻底卸载本脚本？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    rm -f "$SELF_MENU"
    rm -f "$WRAPPER_UFW"
    rm -f "$LOGROTATE_FILE"

    echo "本脚本快捷入口和日志轮转配置已清理。"
    echo "UFW / Fail2Ban 本体未卸载。"
    echo "如果你是通过当前目录 ./ufw-f.sh 运行的，也可以手动删除：rm -f ./ufw-f.sh"
    pause
}

full_cleanup_all() {
    need_root

    echo "危险操作：这会卸载 UFW、Fail2Ban，并删除本脚本相关配置。"
    read -rp "确认全部清理？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    ufw --force disable >/dev/null 2>&1 || true

    apt purge -y fail2ban ufw
    apt autoremove -y

    rm -rf /etc/fail2ban /etc/ufw
    rm -f /var/log/fail2ban.log
    rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"

    echo "已尽量完成全部清理。"
    pause
}

main_menu() {
    need_root
    check_tools
    install_self_alias

    while true; do
        clear
        check_tools
        echo "========== UFW / Fail2Ban 轻量管理菜单 =========="
        echo "本机状态："
        [ "$UFW_OK" = 1 ] && echo "UFW 防火墙：已安装" || echo "UFW 防火墙：未安装"
        [ "$F2B_OK" = 1 ] && echo "Fail2Ban 防爆破：已安装" || echo "Fail2Ban 防爆破：未安装"
        echo
        echo "1. 安装 UFW 防火墙"
        echo "2. 安装 Fail2Ban 防爆破"
        echo "3. UFW 管理"
        echo "4. Fail2Ban 管理"
        echo "5. 卸载 UFW 并清理"
        echo "6. 卸载 Fail2Ban 并清理"
        echo "7. 一键安装 UFW + Fail2Ban + 扫描器防护"
        echo "8. 安装/刷新日志保留 7 天配置"
        echo "9. 一键自检 + 风险检测 + 当前安全评分"
        echo "10. 仅卸载本管理脚本"
        echo "11. 全部清理：卸载 UFW + Fail2Ban + 本脚本"
        echo "0. 退出"
        echo

        read -rp "请选择：" c

        case "$c" in
            1) install_ufw ;;
            2) install_fail2ban ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) uninstall_ufw ;;
            6) uninstall_fail2ban ;;
            7) install_all_security ;;
            8) install_log_limit; pause ;;
            9) security_self_check ;;
            10) uninstall_this_script_only ;;
            11) full_cleanup_all ;;
            0) exit 0 ;;
            *) echo "无效选择。"; pause ;;
        esac
    done
}

main_menu
