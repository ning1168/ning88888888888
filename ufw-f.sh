#!/usr/bin/env bash

# ==================================================
# UFW / Fail2Ban 中文轻量管理脚本 精简优化版 v3
# 适合 Debian / Ubuntu VPS
#
# 功能：
# - UFW 防火墙安装/管理
# - Fail2Ban 防爆破安装/管理
# - 自动封禁扫描器
# - 默认日志保留 7 天
# - 主动清理日志
# - 一键自检 + 风险检测 + 安全评分
# - 所有检测尽量输出中文摘要，不刷原始长日志
#
# 快捷入口：
# sudo ufw -f
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
    mkdir -p /etc/logrotate.d

    cat >"$LOGROTATE_FILE" <<'EOF'
# UFW / Fail2Ban 日志限制
# daily    = 每天轮转
# rotate 7 = 只保留 7 天
# compress = 压缩旧日志

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

    echo "日志限制已设置：每天轮转，只保留 7 天。"
}

clean_security_logs() {
    need_root

    echo "========== 主动清理日志 =========="
    echo "此功能会清空当前 UFW / Fail2Ban 日志内容。"
    echo "不会卸载服务，不会删除配置。"
    echo
    read -rp "确认清理？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    for f in /var/log/fail2ban.log /var/log/ufw.log; do
        if [ -f "$f" ]; then
            : > "$f"
            echo "已清空：$f"
        else
            echo "未找到：$f"
        fi
    done

    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true

    systemctl reload fail2ban >/dev/null 2>&1 || true
    systemctl reload rsyslog >/dev/null 2>&1 || true

    echo "systemd 日志已尝试只保留最近 7 天。"
}

ensure_log_files() {
    mkdir -p /var/log
    touch /var/log/fail2ban.log
    touch /var/log/ufw.log
    chmod 640 /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
    chown root:adm /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
}

analyze_fail2ban_error() {
    echo "========== Fail2Ban 启动失败分析 =========="

    err="$(journalctl -u fail2ban -n 80 --no-pager 2>/dev/null; cat /tmp/f2b-test.log 2>/dev/null)"

    found=0

    if echo "$err" | grep -qi "Have not found any log file"; then
        echo "问题：某个防护找不到日志文件。"
        echo "建议：脚本会自动创建日志文件；如果仍失败，可先禁用扫描器，只保留 SSH 防护。"
        found=1
    fi

    if echo "$err" | grep -qi "No failure-id group"; then
        echo "问题：某个过滤规则不兼容当前日志格式。"
        echo "建议：禁用扫描器，保留 sshd 防爆破。"
        found=1
    fi

    if echo "$err" | grep -qi "ERROR"; then
        echo
        echo "错误摘要："
        echo "$err" | grep -i "ERROR" | tail -n 5
        found=1
    fi

    if [ "$found" = 0 ]; then
        echo "没有识别到明确原因。"
    fi
}

safe_restart_fail2ban() {
    ensure_log_files

    fail2ban-client -t >/tmp/f2b-test.log 2>&1
    if [ $? -ne 0 ]; then
        if [ -f /etc/fail2ban/jail.d/ufw-scanner.local ]; then
            mv /etc/fail2ban/jail.d/ufw-scanner.local /etc/fail2ban/jail.d/ufw-scanner.local.disabled
            echo "扫描器配置异常，已自动禁用 ufw-scanner，避免影响 SSH 防护。"
        fi

        fail2ban-client -t >/tmp/f2b-test.log 2>&1
        if [ $? -ne 0 ]; then
            analyze_fail2ban_error
            return 1
        fi
    fi

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban

    if systemctl is-active --quiet fail2ban; then
        echo "Fail2Ban 已正常运行。"
        return 0
    else
        analyze_fail2ban_error
        return 1
    fi
}

install_ufw() {
    need_root

    command -v ufw >/dev/null 2>&1 || pkg_install ufw

    echo
    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    ufw allow "${ssh_port}/tcp" comment "SSH 远程连接端口"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging on

    read -rp "是否启用 UFW？默认 Y：[Y/n] " yn
    yn="${yn:-Y}"

    case "$yn" in
        y|Y) ufw --force enable ;;
        *) echo "已跳过启用 UFW。" ;;
    esac

    systemctl enable ufw >/dev/null 2>&1 || true
    install_self_alias
    install_log_limit
    pause
}

edit_fail2ban_basic_config() {
    need_root

    echo "========== Fail2Ban 基础配置 =========="
    echo "不输入则使用默认值。"
    echo

    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    read -rp "失败次数，默认 5：" maxretry
    maxretry="${maxretry:-5}"

    read -rp "检测时间，默认 10m：" findtime
    findtime="${findtime:-10m}"

    read -rp "封禁时间，默认 1h：" bantime
    bantime="${bantime:-1h}"

    read -rp "递增封禁，默认开启：[Y/n] " inc
    inc="${inc:-Y}"

    case "$inc" in
        y|Y) bantime_increment="true" ;;
        *) bantime_increment="false" ;;
    esac

    mkdir -p /etc/fail2ban

    cat >/etc/fail2ban/jail.local <<EOF
# ==================================================
# Fail2Ban 基础防护配置
# 文件：/etc/fail2ban/jail.local
# ==================================================

[DEFAULT]

# 忽略 IP：这些 IP 不会被封禁
ignoreip = 127.0.0.1/8 ::1

# 封禁时间：10m=10分钟，1h=1小时，1d=1天
bantime = ${bantime}

# 检测时间：在这个时间内失败达到次数就封禁
findtime = ${findtime}

# 最大失败次数
maxretry = ${maxretry}

# 递增封禁：多次违规会越封越久
bantime.increment = ${bantime_increment}

# 使用 systemd 读取 SSH 登录日志
backend = systemd

# 使用 UFW 封禁 IP
banaction = ufw

# 不发邮件，只封禁，适合小机器
action = %(action_)s


[sshd]

# SSH 防爆破
enabled = true

# SSH 端口
port = ${ssh_port}

# SSH 规则
filter = sshd

# SSH 日志
logpath = %(sshd_log)s

# 使用 systemd 后端
backend = systemd
EOF

    echo "基础配置已写入。"
}

install_fail2ban() {
    need_root

    command -v fail2ban-client >/dev/null 2>&1 || pkg_install fail2ban

    edit_fail2ban_basic_config
    install_log_limit
    ensure_log_files
    safe_restart_fail2ban

    install_self_alias
    pause
}

install_scanner_jail() {
    need_root

    command -v fail2ban-client >/dev/null 2>&1 || {
        echo "请先安装 Fail2Ban。"
        pause
        return
    }

    ensure_log_files
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d

    cat >/etc/fail2ban/filter.d/ufw-scanner.conf <<'EOF'
# UFW 扫描器识别规则
# 用途：识别频繁触发 UFW BLOCK 的来源 IP

[Definition]

# 匹配 UFW BLOCK 日志中的来源 IP
failregex = ^.*\[UFW BLOCK\].*SRC=<HOST> .*$
ignoreregex =
EOF

    cat >/etc/fail2ban/jail.d/ufw-scanner.local <<'EOF'
# ==================================================
# UFW 自动封禁扫描器
# 文件：/etc/fail2ban/jail.d/ufw-scanner.local
# ==================================================

[ufw-scanner]

# 是否启用
enabled = true

# 读取 UFW 日志
logpath = /var/log/ufw.log

# 使用扫描器过滤规则
filter = ufw-scanner

# 检测时间窗口
findtime = 10m

# 10 分钟内触发 8 次 UFW BLOCK 就封禁
maxretry = 8

# 封禁 6 小时
bantime = 6h

# 使用 UFW 封禁
banaction = ufw

# 文件轮询读取日志，兼容性更好
backend = polling
EOF

    ufw logging on >/dev/null 2>&1 || true

    if safe_restart_fail2ban; then
        echo "扫描器已启用：ufw-scanner"
    else
        echo "扫描器启用失败，已尽量保护 sshd 防护不受影响。"
    fi

    pause
}

install_all_security() {
    install_log_limit
    install_ufw
    install_fail2ban
    install_scanner_jail
    install_log_limit
}

analyze_ufw_logs() {
    echo "========== UFW 拦截分析 =========="

    if [ ! -s /var/log/ufw.log ]; then
        echo "暂无 UFW 拦截日志。"
        echo "说明：没有日志不一定是异常，可能只是还没有外部访问被拦截。"
        return
    fi

    total="$(grep -c "UFW BLOCK" /var/log/ufw.log 2>/dev/null || echo 0)"
    echo "拦截记录数量：$total"

    if [ "$total" = "0" ]; then
        echo "分析：暂未发现 UFW BLOCK 拦截记录。"
        return
    fi

    echo
    echo "高频来源 IP："
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*SRC=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "来源 " $2 "，触发 " $1 " 次"}'

    echo
    echo "高频目标端口："
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*DPT=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "端口 " $2 "，被探测 " $1 " 次"}'
}

analyze_fail2ban_logs() {
    echo "========== Fail2Ban 封禁分析 =========="

    if [ -s /var/log/fail2ban.log ]; then
        bans="$(grep -ci " Ban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
        unbans="$(grep -ci " Unban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
        errors="$(grep -ci "ERROR" /var/log/fail2ban.log 2>/dev/null || echo 0)"

        echo "封禁次数：$bans"
        echo "解封次数：$unbans"
        echo "错误数量：$errors"

        if [ "$errors" != "0" ]; then
            echo "分析：日志中出现错误，建议进入 Fail2Ban 管理执行“测试/重启”。"
        fi

        echo
        echo "最近高频封禁 IP："
        grep " Ban " /var/log/fail2ban.log 2>/dev/null \
            | tail -n 100 \
            | sed -n 's/.*Ban \([^ ]*\).*/\1/p' \
            | sort | uniq -c | sort -nr | head -n 8 \
            | awk '{print "IP " $2 "，最近封禁 " $1 " 次"}'
    else
        echo "暂无 Fail2Ban 日志内容。"
        echo "说明：可能还没有封禁记录，或服务未运行。"
    fi
}

show_port_summary() {
    echo "========== 监听端口中文摘要 =========="

    if ! command -v ss >/dev/null 2>&1; then
        echo "未找到 ss 命令，无法分析监听端口。"
        return
    fi

    tmp="$(mktemp)"
    ss -tulnH 2>/dev/null > "$tmp"

    if [ ! -s "$tmp" ]; then
        echo "未检测到监听端口。"
        rm -f "$tmp"
        return
    fi

    total="$(wc -l < "$tmp" | xargs)"
    tcp_count="$(awk '$1=="tcp"{c++} END{print c+0}' "$tmp")"
    udp_count="$(awk '$1=="udp"{c++} END{print c+0}' "$tmp")"

    echo "监听总数：${total}"
    echo "TCP 监听：${tcp_count}"
    echo "UDP 监听：${udp_count}"
    echo

    echo "常见端口识别："

    has_common=0
    while read -r proto state recv send local peer rest; do
        port="$(echo "$local" | awk -F: '{print $NF}')"
        addr="$(echo "$local" | sed "s/:$port$//")"

        case "$port" in
            22)  name="SSH 远程登录"; risk="建议只放行你的 SSH 端口，并配合 Fail2Ban" ;;
            80)  name="HTTP 网站"; risk="如果没有建站，可关闭或拒绝" ;;
            443) name="HTTPS 网站"; risk="如果没有建站，可关闭或拒绝" ;;
            53)  name="DNS 解析"; risk="127.0.0.1/127.0.0.53/127.0.0.54 通常是本机 DNS，公网监听需谨慎" ;;
            25)  name="SMTP 邮件"; risk="小机器一般不建议开放，容易被滥用" ;;
            3306) name="MySQL 数据库"; risk="强烈建议不要公网开放" ;;
            5432) name="PostgreSQL 数据库"; risk="强烈建议不要公网开放" ;;
            6379) name="Redis 数据库"; risk="强烈建议不要公网开放" ;;
            27017) name="MongoDB 数据库"; risk="强烈建议不要公网开放" ;;
            *) continue ;;
        esac

        has_common=1
        echo "- ${proto^^} ${port}：${name}；监听地址：${addr}；提示：${risk}"
    done < "$tmp"

    if [ "$has_common" = 0 ]; then
        echo "未发现常见高风险端口。"
    fi

    echo
    public_count="$(awk '
        {
            local=$5
            if (local ~ /\[::\]:/ || local ~ /^:::/ || local ~ /^0\.0\.0\.0:/) c++
        }
        END{print c+0}
    ' "$tmp")"

    if [ "$public_count" -gt 0 ]; then
        echo "风险提示：检测到 ${public_count} 个可能监听在公网地址的端口。"
        echo "建议：确认这些端口是否真的需要对外开放，并用 UFW 限制。"
    else
        echo "公网监听风险：未发现明显 0.0.0.0 或 :: 全网监听。"
    fi

    rm -f "$tmp"
}

show_fail2ban_status_summary() {
    echo "========== Fail2Ban 防护摘要 =========="

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "Fail2Ban 未安装。"
        return
    fi

    if systemctl is-active --quiet fail2ban; then
        echo "服务状态：运行中"
    else
        echo "服务状态：未运行"
        analyze_fail2ban_error
        return
    fi

    jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"

    if [ -z "$jail_list" ]; then
        echo "启用防护：无"
        return
    fi

    echo "启用防护：$jail_list"
    echo

    for jail in $(echo "$jail_list" | tr ',' ' '); do
        jail="$(echo "$jail" | xargs)"
        [ -z "$jail" ] && continue

        echo "[$jail]"
        fail2ban-client status "$jail" 2>/dev/null \
            | awk -F: '
                /Currently failed/ {print "当前失败次数：" $2}
                /Total failed/ {print "累计失败次数：" $2}
                /Currently banned/ {print "当前封禁数量：" $2}
                /Total banned/ {print "累计封禁数量：" $2}
                /Banned IP list/ {print "封禁 IP：" $2}
            '
        echo
    done
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
    echo "========== 一键自检 + 风险检测 + 安全评分 =========="
    echo

    echo "【UFW】"
    if command -v ufw >/dev/null 2>&1; then
        ufw status | grep -qi "Status: active" && ok "UFW 已启用" || danger "UFW 未启用"

        ufw status verbose | grep -qi "Default: deny (incoming)" \
            && ok "默认入站为 deny" \
            || danger "默认入站不是 deny"

        if iptables -S 2>/dev/null | grep -q "ufw"; then
            ok "iptables 中检测到 UFW 规则"
        elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qi "ufw"; then
            ok "nftables 中检测到 UFW 规则"
        else
            warn "底层规则中未明显检测到 UFW，需手动确认"
        fi

        rule_count="$(ufw status numbered 2>/dev/null | grep -c '^\[' || true)"
        echo "UFW 规则数量：${rule_count}"
    else
        danger "UFW 未安装"
    fi

    echo
    echo "【Fail2Ban】"
    if command -v fail2ban-client >/dev/null 2>&1; then
        systemctl is-active --quiet fail2ban && ok "Fail2Ban 正在运行" || danger "Fail2Ban 未运行"

        jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"
        [ -n "$jail_list" ] && ok "启用防护：$jail_list" || warn "没有检测到启用中的 jail"

        fail2ban-client status sshd >/dev/null 2>&1 \
            && ok "sshd 防爆破已启用" \
            || warn "sshd 防爆破未启用"

        fail2ban-client status ufw-scanner >/dev/null 2>&1 \
            && ok "ufw-scanner 扫描器已启用" \
            || warn "ufw-scanner 未启用"
    else
        warn "Fail2Ban 未安装"
    fi

    echo
    echo "【日志与磁盘】"
    [ -f "$LOGROTATE_FILE" ] && grep -q "rotate 7" "$LOGROTATE_FILE" \
        && ok "日志限制为保留 7 天" \
        || warn "未检测到日志 7 天保留配置"

    root_use="$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ "${root_use:-0}" -ge 90 ]; then
        danger "根分区使用率超过 90%"
    elif [ "${root_use:-0}" -ge 75 ]; then
        warn "根分区使用率超过 75%"
    else
        ok "根分区空间正常"
    fi

    echo
    echo "【常见绕过风险】"
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        warn "Docker 正在运行，Docker 发布端口可能绕过 UFW"
    else
        ok "未检测到运行中的 Docker"
    fi

    echo
    show_port_summary

    echo
    [ "$score" -lt 0 ] && score=0
    echo "========== 当前安全评分 =========="
    echo "安全分：${score}/100"
    echo "高风险项：${danger_count}"
    echo "提醒项：${warn_count}"

    if [ "$score" -ge 85 ]; then
        echo "评级：优秀"
    elif [ "$score" -ge 70 ]; then
        echo "评级：良好"
    elif [ "$score" -ge 50 ]; then
        echo "评级：一般，需要检查"
    else
        echo "评级：较危险，建议立即处理"
    fi
}

ufw_menu() {
    while true; do
        clear
        echo "===== UFW ====="
        echo "1. 状态摘要"
        echo "2. 规则列表"
        echo "3. 放行端口"
        echo "4. 拒绝端口"
        echo "5. 删除规则"
        echo "6. 启用/禁用/重载/重置"
        echo "7. 拦截分析"
        echo "0. 返回"
        echo

        read -rp "选择：" c

        case "$c" in
            1)
                ufw status verbose
                ;;
            2)
                ufw status numbered
                ;;
            3)
                read -rp "端口，例如 80 或 443/tcp：" port
                ufw allow "$port" comment "用户允许规则"
                ;;
            4)
                read -rp "端口，例如 3306 或 3306/tcp：" port
                ufw deny "$port" comment "用户拒绝规则"
                ;;
            5)
                ufw status numbered
                read -rp "删除编号：" num
                ufw delete "$num"
                ;;
            6)
                echo "1. 启用  2. 禁用  3. 重载  4. 重置"
                read -rp "选择：" x
                case "$x" in
                    1) ufw --force enable ;;
                    2) ufw disable ;;
                    3) ufw reload ;;
                    4)
                        read -rp "确认重置？输入 YES：" yes
                        [ "$yes" = "YES" ] && ufw --force reset
                        ;;
                esac
                ;;
            7) analyze_ufw_logs ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac

        pause
    done
}

fail2ban_menu() {
    while true; do
        clear
        echo "===== Fail2Ban ====="
        echo "1. 防护摘要"
        echo "2. 编辑基础配置"
        echo "3. 启用扫描器"
        echo "4. 解封 IP"
        echo "5. 封禁分析"
        echo "6. 测试/重启"
        echo "7. 查看配置"
        echo "0. 返回"
        echo

        read -rp "选择：" c

        case "$c" in
            1) show_fail2ban_status_summary ;;
            2)
                edit_fail2ban_basic_config
                safe_restart_fail2ban
                ;;
            3) install_scanner_jail ;;
            4)
                read -rp "IP：" ip
                [ -z "$ip" ] && echo "IP 不能为空。" && pause && continue
                jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')"
                for jail in $jails; do
                    jail="$(echo "$jail" | xargs)"
                    fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
                done
                echo "已尝试从所有防护中解封：$ip"
                ;;
            5) analyze_fail2ban_logs ;;
            6)
                fail2ban-client -t >/tmp/f2b-test.log 2>&1
                if [ $? -eq 0 ]; then
                    echo "配置测试通过。"
                    systemctl restart fail2ban
                    systemctl is-active --quiet fail2ban && echo "重启成功。" || echo "重启失败。"
                else
                    analyze_fail2ban_error
                fi
                ;;
            7)
                echo "1. 基础配置  2. 扫描器配置"
                read -rp "选择：" x
                case "$x" in
                    1) cat /etc/fail2ban/jail.local 2>/dev/null || echo "未找到基础配置。" ;;
                    2)
                        cat /etc/fail2ban/jail.d/ufw-scanner.local 2>/dev/null \
                            || cat /etc/fail2ban/jail.d/ufw-scanner.local.disabled 2>/dev/null \
                            || echo "未找到扫描器配置。"
                        ;;
                esac
                ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac

        pause
    done
}

uninstall_ufw() {
    read -rp "确认卸载 UFW 并清理？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    ufw --force disable >/dev/null 2>&1 || true
    apt purge -y ufw
    apt autoremove -y
    rm -rf /etc/ufw
    rm -f "$WRAPPER_UFW"

    echo "UFW 已卸载。"
    pause
}

uninstall_fail2ban() {
    read -rp "确认卸载 Fail2Ban 并清理？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    apt purge -y fail2ban
    apt autoremove -y
    rm -rf /etc/fail2ban
    rm -f /var/log/fail2ban.log

    echo "Fail2Ban 已卸载。"
    pause
}

uninstall_script_only() {
    echo "只删除本管理脚本，不卸载 UFW / Fail2Ban。"
    read -rp "确认？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"

    echo "脚本入口已清理。"
    echo "当前目录脚本可手动删除：rm -f ./ufw-f.sh"
    pause
}

full_cleanup_all() {
    echo "危险：会卸载 UFW + Fail2Ban + 本脚本。"
    read -rp "确认？输入 YES：" yes
    [ "$yes" != "YES" ] && return

    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    ufw --force disable >/dev/null 2>&1 || true

    apt purge -y fail2ban ufw
    apt autoremove -y

    rm -rf /etc/fail2ban /etc/ufw
    rm -f /var/log/fail2ban.log
    rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"

    echo "已完成全部清理。"
    pause
}

main_menu() {
    need_root
    install_self_alias
    install_log_limit >/dev/null 2>&1 || true

    while true; do
        clear
        check_tools

        echo "===== UFW-F 管理 ====="
        [ "$UFW_OK" = 1 ] && echo "UFW：已安装" || echo "UFW：未安装"
        [ "$F2B_OK" = 1 ] && echo "Fail2Ban：已安装" || echo "Fail2Ban：未安装"
        echo
        echo "1. 一键安装"
        echo "2. UFW 管理"
        echo "3. Fail2Ban 管理"
        echo "4. 自检评分"
        echo "5. 日志分析"
        echo "6. 主动清理日志"
        echo "7. 卸载菜单"
        echo "0. 退出"
        echo

        read -rp "选择：" c

        case "$c" in
            1) install_all_security ;;
            2) ufw_menu ;;
            3) fail2ban_menu ;;
            4) security_self_check; pause ;;
            5)
                analyze_ufw_logs
                echo
                analyze_fail2ban_logs
                echo
                show_port_summary
                pause
                ;;
            6) clean_security_logs; pause ;;
            7)
                clear
                echo "===== 卸载菜单 ====="
                echo "1. 仅卸载本脚本"
                echo "2. 卸载 UFW"
                echo "3. 卸载 Fail2Ban"
                echo "4. 全部清理"
                echo "0. 返回"
                read -rp "选择：" x
                case "$x" in
                    1) uninstall_script_only ;;
                    2) uninstall_ufw ;;
                    3) uninstall_fail2ban ;;
                    4) full_cleanup_all ;;
                esac
                ;;
            0) exit 0 ;;
            *) echo "无效选择。"; pause ;;
        esac
    done
}

main_menu
