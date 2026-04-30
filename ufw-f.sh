#!/usr/bin/env bash
# ==================================================
# UFW-F 终极版：UFW / Fail2Ban 中文安全管理工具
# 适合 Debian / Ubuntu 1核1G VPS
#
# 特点：
# - 推荐安装：UFW + Fail2Ban SSH 防爆破
# - ufw-scanner 扫描器默认不启用，可手动开启
# - 默认日志保留 7 天
# - 支持批量放行 / 拒绝端口
# - 公网端口 / 服务中文分析
# - 危险端口提示
# - 自检评分
# - 最小安全模式
# - 配置备份
# - 卸载清理
# - sudo ufw -f 进入菜单
# ==================================================

set -u

REAL_UFW="/usr/sbin/ufw"
SELF_MENU="/usr/local/sbin/ufw-f-menu"
WRAPPER_UFW="/usr/local/sbin/ufw"
LOGROTATE_FILE="/etc/logrotate.d/ufw-fail2ban-lite"
BACKUP_DIR="/root/ufw-f-backup"
CURRENT_SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ==================================================
# UI
# ==================================================

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

clear_screen() {
    clear
}

title() {
    echo
    echo "========== $1 =========="
}

section() {
    echo
    echo "【$1】"
}

ok() {
    echo "✅ $1"
}

warn() {
    echo "⚠️  $1"
}

bad() {
    echo "❌ $1"
}

info() {
    echo "- $1"
}

confirm_yes() {
    msg="$1"
    echo
    warn "$msg"
    read -rp "确认继续？输入 YES：" yes
    [ "$yes" = "YES" ]
}

# ==================================================
# 基础工具
# ==================================================

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

port_name() {
    case "$1" in
        20|21) echo "FTP文件传输" ;;
        22) echo "SSH远程登录" ;;
        25|465|587) echo "邮件服务" ;;
        53) echo "DNS解析" ;;
        80) echo "HTTP网站" ;;
        443) echo "HTTPS网站" ;;
        8080) echo "常见Web服务" ;;
        8443) echo "常见HTTPS面板/服务" ;;
        3306) echo "MySQL数据库" ;;
        5432) echo "PostgreSQL数据库" ;;
        6379) echo "Redis数据库" ;;
        27017) echo "MongoDB数据库" ;;
        *) echo "自定义服务" ;;
    esac
}

is_danger_port() {
    case "$1" in
        21|25|3306|5432|6379|27017) return 0 ;;
        *) return 1 ;;
    esac
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    ts="$(date +%Y%m%d-%H%M%S)"
    dir="$BACKUP_DIR/$ts"
    mkdir -p "$dir"

    [ -d /etc/ufw ] && cp -a /etc/ufw "$dir/" 2>/dev/null || true
    [ -d /etc/fail2ban ] && cp -a /etc/fail2ban "$dir/" 2>/dev/null || true
    ufw status numbered >"$dir/ufw-status.txt" 2>/dev/null || true

    ok "配置已备份：$dir"
}

# ==================================================
# 日志
# ==================================================

install_log_limit() {
    mkdir -p /etc/logrotate.d

    cat >"$LOGROTATE_FILE" <<'EOF'
# UFW / Fail2Ban 日志限制
# 每天轮转，只保留 7 天，避免小机器日志占满磁盘

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
}

ensure_log_files() {
    mkdir -p /var/log
    touch /var/log/fail2ban.log /var/log/ufw.log
    chmod 640 /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
    chown root:adm /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
}

clean_security_logs() {
    title "主动清理日志"
    echo "会清空当前 UFW / Fail2Ban 日志，不删除配置。"

    confirm_yes "清理日志后，历史分析数据会被清空。" || return

    : > /var/log/fail2ban.log 2>/dev/null || true
    : > /var/log/ufw.log 2>/dev/null || true

    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true

    systemctl reload fail2ban >/dev/null 2>&1 || true
    systemctl reload rsyslog >/dev/null 2>&1 || true

    ok "日志已清理。"
}

# ==================================================
# UFW
# ==================================================

show_ufw_status() {
    title "防火墙状态 / 规则"

    if ! command -v ufw >/dev/null 2>&1; then
        bad "UFW 未安装"
        return
    fi

    v="$(ufw status verbose 2>/dev/null || true)"

    section "状态摘要"
    echo "$v" | grep -qi "Status: active" \
        && ok "防火墙已启用" \
        || bad "防火墙未启用"

    echo "$v" | grep -qi "Logging: on" \
        && ok "日志已开启" \
        || warn "日志未开启或状态未知"

    echo "$v" | grep -qi "Default: deny (incoming)" \
        && ok "默认入站：拒绝，安全" \
        || bad "默认入站不是拒绝，建议检查"

    echo "$v" | grep -qi "allow (outgoing)" \
        && ok "默认出站：允许，正常" \
        || warn "默认出站不是允许，请确认"

    section "规则说明"
    info "ALLOW IN = 允许外部访问本机端口"
    info "DENY IN  = 拒绝外部访问本机端口"
    info "(v6)     = IPv6规则"

    section "规则列表"
    ufw status numbered
}

batch_allow_ports() {
    title "批量放行端口"
    echo "可一次输入多个端口，例如：80 443 8443"
    echo "也支持协议，例如：80/tcp 53/udp"
    echo

    read -rp "请输入要放行的端口：" ports
    [ -z "$ports" ] && warn "未输入端口。" && return

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        if is_danger_port "$clean"; then
            warn "端口 $clean 是高风险端口：$(port_name "$clean")"
            read -rp "确认放行 $p？输入 YES：" yes
            [ "$yes" != "YES" ] && { warn "已跳过：$p"; continue; }
        fi
    done

    backup_configs

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        if is_danger_port "$clean"; then
            # 前面已经确认过，但这里避免空输入误操作
            true
        fi

        ufw allow "$p" comment "用户允许规则"
        ok "已放行 $p（$(port_name "$clean")）"
    done
}

batch_deny_ports() {
    title "批量拒绝端口"
    echo "可一次输入多个端口，例如：3306 6379 27017"
    echo "也支持协议，例如：3306/tcp 53/udp"
    echo

    read -rp "请输入要拒绝的端口：" ports
    [ -z "$ports" ] && warn "未输入端口。" && return

    backup_configs

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        ufw deny "$p" comment "用户拒绝规则"
        ok "已拒绝 $p（$(port_name "$clean")）"
    done
}

delete_ufw_rule() {
    title "删除 UFW 规则"
    echo "请输入最左边 [] 里的编号。"
    echo "注意：IPv4 和 IPv6 规则通常需要分别删除。"
    echo

    ufw status numbered
    echo

    read -rp "输入要删除的编号：" num
    [ -z "$num" ] && warn "未输入编号。" && return

    backup_configs
    ufw delete "$num"
}

minimal_safe_mode() {
    title "最小安全模式"
    echo "作用：重置 UFW，只放行 SSH 端口，默认入站拒绝。"
    echo "适合临时收紧服务器暴露面。"
    echo

    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    confirm_yes "此操作会重置 UFW 规则，只保留 SSH ${ssh_port}/tcp。" || return

    backup_configs

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${ssh_port}/tcp" comment "SSH远程连接端口"
    ufw logging low
    ufw --force enable

    ok "最小安全模式已应用：只放行 SSH ${ssh_port}/tcp。"
}

install_ufw() {
    title "安装 / 配置 UFW 防火墙"

    command -v ufw >/dev/null 2>&1 || pkg_install ufw

    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    ufw allow "${ssh_port}/tcp" comment "SSH远程连接端口"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging low

    echo
    warn "请确认 SSH ${ssh_port}/tcp 已放行，否则可能断开连接。"
    read -rp "是否启用 UFW？默认 Y：[Y/n] " yn
    yn="${yn:-Y}"

    case "$yn" in
        y|Y) ufw --force enable ;;
        *) warn "已跳过启用 UFW。" ;;
    esac

    systemctl enable ufw >/dev/null 2>&1 || true
    install_log_limit
    install_self_alias

    ok "UFW 配置完成。"
}

# ==================================================
# Fail2Ban
# ==================================================

analyze_fail2ban_error() {
    title "Fail2Ban 启动失败分析"

    err="$(journalctl -u fail2ban -n 80 --no-pager 2>/dev/null; cat /tmp/f2b-test.log 2>/dev/null)"
    found=0

    if echo "$err" | grep -qi "Have not found any log file"; then
        bad "某个防护找不到日志文件"
        info "建议：禁用扫描器，只保留 SSH 防爆破。"
        found=1
    fi

    if echo "$err" | grep -qi "No failure-id group"; then
        bad "过滤规则不兼容当前日志格式"
        info "建议：禁用扫描器，重新测试。"
        found=1
    fi

    if echo "$err" | grep -qi "ERROR"; then
        bad "检测到错误摘要："
        echo "$err" | grep -i "ERROR" | tail -n 5
        found=1
    fi

    [ "$found" = 0 ] && warn "没有识别到明确原因。"
}

safe_restart_fail2ban() {
    ensure_log_files

    fail2ban-client -t >/tmp/f2b-test.log 2>&1
    if [ $? -ne 0 ]; then
        if [ -f /etc/fail2ban/jail.d/ufw-scanner.local ]; then
            mv /etc/fail2ban/jail.d/ufw-scanner.local /etc/fail2ban/jail.d/ufw-scanner.local.disabled
            warn "扫描器配置异常，已自动禁用，避免影响 SSH 防护。"
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
        ok "Fail2Ban 已正常运行。"
    else
        analyze_fail2ban_error
    fi
}

edit_fail2ban_basic_config() {
    title "Fail2Ban SSH 防爆破配置"
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
# Fail2Ban 基础防护配置

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

# 使用 systemd 读取日志
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

filter = sshd
logpath = %(sshd_log)s
backend = systemd
EOF

    ok "Fail2Ban SSH 防护配置已写入。"
}

install_fail2ban() {
    title "安装 / 配置 Fail2Ban"

    command -v fail2ban-client >/dev/null 2>&1 || pkg_install fail2ban

    backup_configs
    edit_fail2ban_basic_config
    install_log_limit
    ensure_log_files
    safe_restart_fail2ban

    install_self_alias
}

show_fail2ban_status() {
    title "Fail2Ban 防护摘要"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        bad "Fail2Ban 未安装"
        return
    fi

    if ! systemctl is-active --quiet fail2ban; then
        bad "服务状态：未运行"
        analyze_fail2ban_error
        return
    fi

    ok "服务状态：运行中"

    jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"

    if [ -z "$jail_list" ]; then
        warn "启用防护：无"
        return
    fi

    section "启用防护"
    echo "$jail_list"

    for jail in $(echo "$jail_list" | tr ',' ' '); do
        jail="$(echo "$jail" | xargs)"
        [ -z "$jail" ] && continue

        section "$jail"
        fail2ban-client status "$jail" 2>/dev/null \
            | awk -F: '
                /Currently failed/ {print "- 当前失败次数：" $2}
                /Total failed/ {print "- 累计失败次数：" $2}
                /Currently banned/ {print "- 当前封禁数量：" $2}
                /Total banned/ {print "- 累计封禁数量：" $2}
                /Banned IP list/ {print "- 封禁 IP：" $2}
            '
    done
}

install_scanner_jail() {
    title "启用 ufw-scanner 扫描器"
    echo "扫描器会读取 UFW 日志，自动封禁频繁扫端口的 IP。"
    echo "1核1G 小机器默认不建议开启，除非经常被扫描。"

    confirm_yes "启用扫描器会增加少量日志读取和匹配开销。" || return

    command -v fail2ban-client >/dev/null 2>&1 || {
        bad "请先安装 Fail2Ban。"
        return
    }

    backup_configs
    ensure_log_files
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d

    cat >/etc/fail2ban/filter.d/ufw-scanner.conf <<'EOF'
# UFW 扫描器识别规则
[Definition]
failregex = ^.*\[UFW BLOCK\].*SRC=<HOST> .*$
ignoreregex =
EOF

    cat >/etc/fail2ban/jail.d/ufw-scanner.local <<'EOF'
# UFW 自动封禁扫描器
[ufw-scanner]
enabled = true
logpath = /var/log/ufw.log
filter = ufw-scanner
findtime = 10m
maxretry = 12
bantime = 6h
banaction = ufw
backend = polling
EOF

    ufw logging low >/dev/null 2>&1 || true
    safe_restart_fail2ban
}

disable_scanner_jail() {
    title "禁用 ufw-scanner 扫描器"

    if [ -f /etc/fail2ban/jail.d/ufw-scanner.local ]; then
        backup_configs
        mv /etc/fail2ban/jail.d/ufw-scanner.local /etc/fail2ban/jail.d/ufw-scanner.local.disabled
        systemctl restart fail2ban >/dev/null 2>&1 || true
        ok "已禁用 ufw-scanner。"
    else
        warn "未发现已启用的 ufw-scanner。"
    fi
}

unban_ip() {
    title "解封 IP"

    read -rp "请输入要解封的 IP：" ip
    [ -z "$ip" ] && warn "IP 不能为空。" && return

    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')"

    for jail in $jails; do
        jail="$(echo "$jail" | xargs)"
        fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
    done

    ok "已尝试从所有防护中解封：$ip"
}

# ==================================================
# 分析
# ==================================================

analyze_ufw_logs() {
    title "UFW 拦截分析"

    if [ ! -s /var/log/ufw.log ]; then
        warn "暂无 UFW 拦截日志。"
        return
    fi

    total="$(grep -c "UFW BLOCK" /var/log/ufw.log 2>/dev/null || echo 0)"
    echo "拦截记录数量：$total"

    [ "$total" = "0" ] && return

    section "高频来源 IP"
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*SRC=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- 来源 " $2 "，触发 " $1 " 次"}'

    section "高频目标端口"
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*DPT=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- 端口 " $2 "，被探测 " $1 " 次"}'
}

analyze_fail2ban_logs() {
    title "Fail2Ban 封禁分析"

    if [ ! -s /var/log/fail2ban.log ]; then
        warn "暂无 Fail2Ban 日志内容。"
        return
    fi

    echo "封禁次数：$(grep -ci " Ban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
    echo "解封次数：$(grep -ci " Unban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
    echo "错误数量：$(grep -ci "ERROR" /var/log/fail2ban.log 2>/dev/null || echo 0)"

    section "最近高频封禁 IP"
    grep " Ban " /var/log/fail2ban.log 2>/dev/null \
        | tail -n 100 \
        | sed -n 's/.*Ban \([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- IP " $2 "，最近封禁 " $1 " 次"}'
}

show_public_port_summary() {
    title "公网端口 / 服务分析"

    if ! command -v ss >/dev/null 2>&1; then
        bad "未找到 ss 命令，无法分析端口。"
        return
    fi

    tmp="$(mktemp)"
    ss -tulpenH 2>/dev/null > "$tmp"

    if [ ! -s "$tmp" ]; then
        warn "未检测到监听端口。"
        rm -f "$tmp"
        return
    fi

    awk '
        {
            local=$5
            if (local ~ /^0\.0\.0\.0:/ || local ~ /^\[::\]:/ || local ~ /^:::/ || local ~ /^\*:/) print
        }
    ' "$tmp" > "$tmp.public"

    if [ ! -s "$tmp.public" ]; then
        ok "未发现明显公网监听端口。"
        rm -f "$tmp" "$tmp.public"
        return
    fi

    echo "公网监听数量：$(wc -l < "$tmp.public" | xargs)"
    echo "说明：公网监听表示外部网络可能访问到该端口，最终还要看 UFW 和云安全组。"

    section "公网监听明细"

    awk '
    {
        proto=$1
        local=$5
        port=local
        sub(/^.*:/,"",port)

        proc="-"
        pid="-"

        if ($0 ~ /users:\(\("/) {
            proc=$0
            sub(/^.*users:\(\("/,"",proc)
            sub(/".*$/,"",proc)

            pid=$0
            sub(/^.*pid=/,"",pid)
            sub(/,.*/,"",pid)
            if (pid !~ /^[0-9]+$/) pid="-"
        }

        key=proto ":" port ":" proc ":" pid
        if (!seen[key]++) print proto, port, proc, pid
    }' "$tmp.public" | while read -r proto port proc pid; do
        upper="$(echo "$proto" | tr '[:lower:]' '[:upper:]')"

        if [ "$proc" = "-" ] || [ -z "$proc" ]; then
            service="$(port_name "$port")"
            proc_show="未知进程"
        else
            service="$proc"
            proc_show="$proc"
        fi

        if is_danger_port "$port"; then
            bad "${upper} ${port}（$(port_name "$port")）"
            echo "   运行服务：${service}"
            echo "   进程：${proc_show}"
            echo "   风险：不建议公网开放"
        else
            echo "- ${upper} ${port}（$(port_name "$port")）"
            echo "   运行服务：${service}"
            echo "   进程：${proc_show}"
        fi
    done

    section "危险端口检查"
    danger=0
    for p in 21 25 3306 5432 6379 27017; do
        if grep -Eq ":${p}[[:space:]]" "$tmp.public"; then
            bad "发现公网监听危险端口 ${p}：$(port_name "$p")"
            danger=1
        fi
    done

    [ "$danger" = 0 ] && ok "未发现常见数据库/邮件/FTP 危险端口公网监听。"

    rm -f "$tmp" "$tmp.public"
}

# ==================================================
# 自检
# ==================================================

security_self_check() {
    clear_screen
    title "安全检测报告"

    score=100
    warn_count=0
    bad_count=0

    add_warn() {
        warn "$1"
        score=$((score-8))
        warn_count=$((warn_count+1))
    }

    add_bad() {
        bad "$1"
        score=$((score-15))
        bad_count=$((bad_count+1))
    }

    section "防火墙"
    if command -v ufw >/dev/null 2>&1; then
        ufw status | grep -qi "Status: active" \
            && ok "UFW 已启用" \
            || add_bad "UFW 未启用"

        ufw status verbose | grep -qi "Default: deny (incoming)" \
            && ok "默认入站为拒绝" \
            || add_bad "默认入站不是拒绝"

        if iptables -S 2>/dev/null | grep -q "ufw"; then
            ok "iptables 中检测到 UFW 规则"
        elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qi "ufw"; then
            ok "nftables 中检测到 UFW 规则"
        else
            add_warn "底层规则中未明显检测到 UFW"
        fi

        rule_count="$(ufw status numbered 2>/dev/null | grep -c '^\[' || true)"
        info "UFW 规则数量：${rule_count}"
    else
        add_bad "UFW 未安装"
    fi

    section "防爆破"
    if command -v fail2ban-client >/dev/null 2>&1; then
        systemctl is-active --quiet fail2ban \
            && ok "Fail2Ban 正在运行" \
            || add_bad "Fail2Ban 未运行"

        jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"
        [ -n "$jail_list" ] \
            && ok "启用防护：$jail_list" \
            || add_warn "没有检测到启用中的防护"

        fail2ban-client status sshd >/dev/null 2>&1 \
            && ok "SSH 防爆破已启用" \
            || add_warn "SSH 防爆破未启用"
    else
        add_warn "Fail2Ban 未安装"
    fi

    section "日志与磁盘"
    [ -f "$LOGROTATE_FILE" ] && grep -q "rotate 7" "$LOGROTATE_FILE" \
        && ok "日志限制为保留 7 天" \
        || add_warn "未检测到日志 7 天保留配置"

    root_use="$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ "${root_use:-0}" -ge 90 ]; then
        add_bad "根分区使用率超过 90%"
    elif [ "${root_use:-0}" -ge 75 ]; then
        add_warn "根分区使用率超过 75%"
    else
        ok "根分区空间正常"
    fi

    section "Docker 风险"
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        add_warn "Docker 正在运行，Docker 发布端口可能绕过 UFW"
    else
        ok "未检测到运行中的 Docker"
    fi

    show_public_port_summary

    [ "$score" -lt 0 ] && score=0

    title "评分结果"
    echo "安全分：${score} / 100"
    echo "高风险项：${bad_count}"
    echo "提醒项：${warn_count}"

    if [ "$score" -ge 85 ]; then
        ok "评级：优秀"
    elif [ "$score" -ge 70 ]; then
        warn "评级：良好"
    elif [ "$score" -ge 50 ]; then
        warn "评级：一般，需要检查"
    else
        bad "评级：较危险，建议立即处理"
    fi
}

# ==================================================
# 推荐安装
# ==================================================

install_recommended_security() {
    title "推荐安装"
    echo "将安装 / 配置："
    info "UFW 防火墙"
    info "Fail2Ban SSH 防爆破"
    info "日志保留 7 天"
    info "不会默认启用 ufw-scanner 扫描器"
    echo

    confirm_yes "开始推荐安装？" || return

    install_ufw
    install_fail2ban
    install_log_limit

    ok "推荐安全配置完成。"
}

# ==================================================
# 卸载
# ==================================================

uninstall_menu() {
    clear_screen
    echo "===== 卸载菜单 ====="
    echo "1. 仅卸载本脚本"
    echo "2. 卸载 UFW"
    echo "3. 卸载 Fail2Ban"
    echo "4. 全部清理"
    echo "0. 返回"
    echo

    read -rp "选择：" x

    case "$x" in
        1)
            title "仅卸载本脚本"
            echo "会删除："
            info "$SELF_MENU"
            info "$WRAPPER_UFW"
            info "$LOGROTATE_FILE"
            info "$CURRENT_SCRIPT"
            echo
            echo "不会卸载 UFW / Fail2Ban。"

            confirm_yes "确认仅卸载本脚本？" || return

            rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"

            if [ -f "$CURRENT_SCRIPT" ] && echo "$CURRENT_SCRIPT" | grep -q "^/"; then
                rm -f "$CURRENT_SCRIPT"
            fi

            ok "本脚本已清理完成。"
            echo "现在退出菜单。"
            exit 0
            ;;
        2)
            confirm_yes "确认卸载 UFW？" || return

            ufw --force disable >/dev/null 2>&1 || true
            apt purge -y ufw
            apt autoremove -y
            rm -rf /etc/ufw "$WRAPPER_UFW"

            ok "UFW 已卸载。"
            ;;
        3)
            confirm_yes "确认卸载 Fail2Ban？" || return

            systemctl stop fail2ban >/dev/null 2>&1 || true
            systemctl disable fail2ban >/dev/null 2>&1 || true
            apt purge -y fail2ban
            apt autoremove -y
            rm -rf /etc/fail2ban

            ok "Fail2Ban 已卸载。"
            ;;
        4)
            confirm_yes "确认全部清理？这会卸载 UFW + Fail2Ban + 本脚本。" || return

            systemctl stop fail2ban >/dev/null 2>&1 || true
            ufw --force disable >/dev/null 2>&1 || true
            apt purge -y fail2ban ufw
            apt autoremove -y
            rm -rf /etc/fail2ban /etc/ufw
            rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"
            [ -f "$CURRENT_SCRIPT" ] && rm -f "$CURRENT_SCRIPT" 2>/dev/null || true

            ok "已全部清理。"
            exit 0
            ;;
    esac

    pause
}

# ==================================================
# 菜单
# ==================================================

ufw_menu() {
    while true; do
        clear_screen
        echo "===== 防火墙管理（UFW）====="
        echo "1. 状态 / 规则"
        echo "2. 批量放行端口"
        echo "3. 批量拒绝端口"
        echo "4. 删除规则"
        echo "5. 启用 / 禁用 / 重载 / 重置"
        echo "6. 拦截分析"
        echo "7. 最小安全模式"
        echo "0. 返回"
        echo

        read -rp "选择：" c

        case "$c" in
            1) show_ufw_status ;;
            2) batch_allow_ports ;;
            3) batch_deny_ports ;;
            4) delete_ufw_rule ;;
            5)
                title "UFW 操作"
                echo "1. 启用"
                echo "2. 禁用"
                echo "3. 重载"
                echo "4. 重置"
                read -rp "选择：" x
                case "$x" in
                    1) ufw --force enable ;;
                    2) ufw disable ;;
                    3) ufw reload ;;
                    4)
                        confirm_yes "确认重置全部 UFW 规则？" && backup_configs && ufw --force reset
                        ;;
                esac
                ;;
            6) analyze_ufw_logs ;;
            7) minimal_safe_mode ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac

        pause
    done
}

fail2ban_menu() {
    while true; do
        clear_screen
        echo "===== 防爆破管理（Fail2Ban）====="
        echo "1. 防护摘要"
        echo "2. 编辑 SSH 防爆破配置"
        echo "3. 启用 ufw-scanner 扫描器"
        echo "4. 禁用 ufw-scanner 扫描器"
        echo "5. 解封 IP"
        echo "6. 封禁分析"
        echo "7. 测试 / 重启"
        echo "0. 返回"
        echo

        read -rp "选择：" c

        case "$c" in
            1) show_fail2ban_status ;;
            2)
                backup_configs
                edit_fail2ban_basic_config
                safe_restart_fail2ban
                ;;
            3) install_scanner_jail ;;
            4) disable_scanner_jail ;;
            5) unban_ip ;;
            6) analyze_fail2ban_logs ;;
            7)
                title "Fail2Ban 测试 / 重启"
                fail2ban-client -t >/tmp/f2b-test.log 2>&1
                if [ $? -eq 0 ]; then
                    ok "配置测试通过。"
                    systemctl restart fail2ban
                    systemctl is-active --quiet fail2ban && ok "重启成功。" || bad "重启失败。"
                else
                    analyze_fail2ban_error
                fi
                ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac

        pause
    done
}

analysis_menu() {
    clear_screen
    analyze_ufw_logs
    echo
    analyze_fail2ban_logs
    echo
    show_public_port_summary
    pause
}

main_menu() {
    need_root
    install_self_alias
    install_log_limit >/dev/null 2>&1 || true

    while true; do
        clear_screen
        check_tools

        echo "===== UFW-F 终极版 ====="
        [ "$UFW_OK" = 1 ] && echo "防火墙 UFW：已安装" || echo "防火墙 UFW：未安装"
        [ "$F2B_OK" = 1 ] && echo "防爆破 Fail2Ban：已安装" || echo "防爆破 Fail2Ban：未安装"
        echo
        echo "1. 推荐安装"
        echo "2. 防火墙管理"
        echo "3. 防爆破管理"
        echo "4. 安全检测报告"
        echo "5. 日志 / 公网端口 / 服务分析"
        echo "6. 主动清理日志"
        echo "7. 备份配置"
        echo "8. 卸载菜单"
        echo "0. 退出"
        echo

        read -rp "选择：" c

        case "$c" in
            1) install_recommended_security; pause ;;
            2) ufw_menu ;;
            3) fail2ban_menu ;;
            4) security_self_check; pause ;;
            5) analysis_menu ;;
            6) clean_security_logs; pause ;;
            7) backup_configs; pause ;;
            8) uninstall_menu ;;
            0) exit 0 ;;
            *) warn "无效选择。"; pause ;;
        esac
    done
}

main_menu#!/usr/bin/env bash
# ==================================================
# UFW-F 清爽终极版：UFW / Fail2Ban 中文安全管理工具
# 适合 Debian / Ubuntu 1核1G VPS
#
# 特点：
# - 推荐安装：UFW + Fail2Ban SSH 防爆破
# - ufw-scanner 扫描器默认不启用，可手动开启
# - 默认日志保留 7 天
# - 支持批量放行 / 拒绝端口
# - 公网端口 / 服务中文分析
# - 危险端口提示
# - 自检评分
# - 最小安全模式
# - 配置备份
# - 卸载清理
# - sudo ufw -f 进入菜单
# ==================================================

set -u

REAL_UFW="/usr/sbin/ufw"
SELF_MENU="/usr/local/sbin/ufw-f-menu"
WRAPPER_UFW="/usr/local/sbin/ufw"
LOGROTATE_FILE="/etc/logrotate.d/ufw-fail2ban-lite"
BACKUP_DIR="/root/ufw-f-backup"
CURRENT_SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ==================================================
# UI
# ==================================================

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

clear_screen() {
    clear
}

title() {
    echo
    echo "========== $1 =========="
}

section() {
    echo
    echo "【$1】"
}

ok() {
    echo "✅ $1"
}

warn() {
    echo "⚠️  $1"
}

bad() {
    echo "❌ $1"
}

info() {
    echo "- $1"
}

confirm_yes() {
    msg="$1"
    echo
    warn "$msg"
    read -rp "确认继续？输入 YES：" yes
    [ "$yes" = "YES" ]
}

# ==================================================
# 基础工具
# ==================================================

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

port_name() {
    case "$1" in
        20|21) echo "FTP文件传输" ;;
        22) echo "SSH远程登录" ;;
        25|465|587) echo "邮件服务" ;;
        53) echo "DNS解析" ;;
        80) echo "HTTP网站" ;;
        443) echo "HTTPS网站" ;;
        8080) echo "常见Web服务" ;;
        8443) echo "常见HTTPS面板/服务" ;;
        3306) echo "MySQL数据库" ;;
        5432) echo "PostgreSQL数据库" ;;
        6379) echo "Redis数据库" ;;
        27017) echo "MongoDB数据库" ;;
        *) echo "自定义服务" ;;
    esac
}

is_danger_port() {
    case "$1" in
        21|25|3306|5432|6379|27017) return 0 ;;
        *) return 1 ;;
    esac
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    ts="$(date +%Y%m%d-%H%M%S)"
    dir="$BACKUP_DIR/$ts"
    mkdir -p "$dir"

    [ -d /etc/ufw ] && cp -a /etc/ufw "$dir/" 2>/dev/null || true
    [ -d /etc/fail2ban ] && cp -a /etc/fail2ban "$dir/" 2>/dev/null || true
    ufw status numbered >"$dir/ufw-status.txt" 2>/dev/null || true

    ok "配置已备份：$dir"
}

# ==================================================
# 日志
# ==================================================

install_log_limit() {
    mkdir -p /etc/logrotate.d

    cat >"$LOGROTATE_FILE" <<'EOF'
# UFW / Fail2Ban 日志限制
# 每天轮转，只保留 7 天，避免小机器日志占满磁盘

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
}

ensure_log_files() {
    mkdir -p /var/log
    touch /var/log/fail2ban.log /var/log/ufw.log
    chmod 640 /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
    chown root:adm /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
}

clean_security_logs() {
    title "主动清理日志"
    echo "会清空当前 UFW / Fail2Ban 日志，不删除配置。"

    confirm_yes "清理日志后，历史分析数据会被清空。" || return

    : > /var/log/fail2ban.log 2>/dev/null || true
    : > /var/log/ufw.log 2>/dev/null || true

    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true

    systemctl reload fail2ban >/dev/null 2>&1 || true
    systemctl reload rsyslog >/dev/null 2>&1 || true

    ok "日志已清理。"
}

# ==================================================
# UFW
# ==================================================

show_ufw_status() {
    title "防火墙状态 / 规则"

    if ! command -v ufw >/dev/null 2>&1; then
        bad "UFW 未安装"
        return
    fi

    v="$(ufw status verbose 2>/dev/null || true)"

    section "状态摘要"
    echo "$v" | grep -qi "Status: active" \
        && ok "防火墙已启用" \
        || bad "防火墙未启用"

    echo "$v" | grep -qi "Logging: on" \
        && ok "日志已开启" \
        || warn "日志未开启或状态未知"

    echo "$v" | grep -qi "Default: deny (incoming)" \
        && ok "默认入站：拒绝，安全" \
        || bad "默认入站不是拒绝，建议检查"

    echo "$v" | grep -qi "allow (outgoing)" \
        && ok "默认出站：允许，正常" \
        || warn "默认出站不是允许，请确认"

    section "规则说明"
    info "ALLOW IN = 允许外部访问本机端口"
    info "DENY IN  = 拒绝外部访问本机端口"
    info "(v6)     = IPv6规则"

    section "规则列表"
    ufw status numbered
}

batch_allow_ports() {
    title "批量放行端口"
    echo "可一次输入多个端口，例如：80 443 8443"
    echo "也支持协议，例如：80/tcp 53/udp"
    echo

    read -rp "请输入要放行的端口：" ports
    [ -z "$ports" ] && warn "未输入端口。" && return

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        if is_danger_port "$clean"; then
            warn "端口 $clean 是高风险端口：$(port_name "$clean")"
            read -rp "确认放行 $p？输入 YES：" yes
            [ "$yes" != "YES" ] && { warn "已跳过：$p"; continue; }
        fi
    done

    backup_configs

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        if is_danger_port "$clean"; then
            # 前面已经确认过，但这里避免空输入误操作
            true
        fi

        ufw allow "$p" comment "用户允许规则"
        ok "已放行 $p（$(port_name "$clean")）"
    done
}

batch_deny_ports() {
    title "批量拒绝端口"
    echo "可一次输入多个端口，例如：3306 6379 27017"
    echo "也支持协议，例如：3306/tcp 53/udp"
    echo

    read -rp "请输入要拒绝的端口：" ports
    [ -z "$ports" ] && warn "未输入端口。" && return

    backup_configs

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        ufw deny "$p" comment "用户拒绝规则"
        ok "已拒绝 $p（$(port_name "$clean")）"
    done
}

delete_ufw_rule() {
    title "删除 UFW 规则"
    echo "请输入最左边 [] 里的编号。"
    echo "注意：IPv4 和 IPv6 规则通常需要分别删除。"
    echo

    ufw status numbered
    echo

    read -rp "输入要删除的编号：" num
    [ -z "$num" ] && warn "未输入编号。" && return

    backup_configs
    ufw delete "$num"
}

minimal_safe_mode() {
    title "最小安全模式"
    echo "作用：重置 UFW，只放行 SSH 端口，默认入站拒绝。"
    echo "适合临时收紧服务器暴露面。"
    echo

    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    confirm_yes "此操作会重置 UFW 规则，只保留 SSH ${ssh_port}/tcp。" || return

    backup_configs

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${ssh_port}/tcp" comment "SSH远程连接端口"
    ufw logging low
    ufw --force enable

    ok "最小安全模式已应用：只放行 SSH ${ssh_port}/tcp。"
}

install_ufw() {
    title "安装 / 配置 UFW 防火墙"

    command -v ufw >/dev/null 2>&1 || pkg_install ufw

    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"

    ufw allow "${ssh_port}/tcp" comment "SSH远程连接端口"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging low

    echo
    warn "请确认 SSH ${ssh_port}/tcp 已放行，否则可能断开连接。"
    read -rp "是否启用 UFW？默认 Y：[Y/n] " yn
    yn="${yn:-Y}"

    case "$yn" in
        y|Y) ufw --force enable ;;
        *) warn "已跳过启用 UFW。" ;;
    esac

    systemctl enable ufw >/dev/null 2>&1 || true
    install_log_limit
    install_self_alias

    ok "UFW 配置完成。"
}

# ==================================================
# Fail2Ban
# ==================================================

analyze_fail2ban_error() {
    title "Fail2Ban 启动失败分析"

    err="$(journalctl -u fail2ban -n 80 --no-pager 2>/dev/null; cat /tmp/f2b-test.log 2>/dev/null)"
    found=0

    if echo "$err" | grep -qi "Have not found any log file"; then
        bad "某个防护找不到日志文件"
        info "建议：禁用扫描器，只保留 SSH 防爆破。"
        found=1
    fi

    if echo "$err" | grep -qi "No failure-id group"; then
        bad "过滤规则不兼容当前日志格式"
        info "建议：禁用扫描器，重新测试。"
        found=1
    fi

    if echo "$err" | grep -qi "ERROR"; then
        bad "检测到错误摘要："
        echo "$err" | grep -i "ERROR" | tail -n 5
        found=1
    fi

    [ "$found" = 0 ] && warn "没有识别到明确原因。"
}

safe_restart_fail2ban() {
    ensure_log_files

    fail2ban-client -t >/tmp/f2b-test.log 2>&1
    if [ $? -ne 0 ]; then
        if [ -f /etc/fail2ban/jail.d/ufw-scanner.local ]; then
            mv /etc/fail2ban/jail.d/ufw-scanner.local /etc/fail2ban/jail.d/ufw-scanner.local.disabled
            warn "扫描器配置异常，已自动禁用，避免影响 SSH 防护。"
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
        ok "Fail2Ban 已正常运行。"
    else
        analyze_fail2ban_error
    fi
}

edit_fail2ban_basic_config() {
    title "Fail2Ban SSH 防爆破配置"
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
# Fail2Ban 基础防护配置

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

# 使用 systemd 读取日志
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

filter = sshd
logpath = %(sshd_log)s
backend = systemd
EOF

    ok "Fail2Ban SSH 防护配置已写入。"
}

install_fail2ban() {
    title "安装 / 配置 Fail2Ban"

    command -v fail2ban-client >/dev/null 2>&1 || pkg_install fail2ban

    backup_configs
    edit_fail2ban_basic_config
    install_log_limit
    ensure_log_files
    safe_restart_fail2ban

    install_self_alias
}

show_fail2ban_status() {
    title "Fail2Ban 防护摘要"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        bad "Fail2Ban 未安装"
        return
    fi

    if ! systemctl is-active --quiet fail2ban; then
        bad "服务状态：未运行"
        analyze_fail2ban_error
        return
    fi

    ok "服务状态：运行中"

    jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"

    if [ -z "$jail_list" ]; then
        warn "启用防护：无"
        return
    fi

    section "启用防护"
    echo "$jail_list"

    for jail in $(echo "$jail_list" | tr ',' ' '); do
        jail="$(echo "$jail" | xargs)"
        [ -z "$jail" ] && continue

        section "$jail"
        fail2ban-client status "$jail" 2>/dev/null \
            | awk -F: '
                /Currently failed/ {print "- 当前失败次数：" $2}
                /Total failed/ {print "- 累计失败次数：" $2}
                /Currently banned/ {print "- 当前封禁数量：" $2}
                /Total banned/ {print "- 累计封禁数量：" $2}
                /Banned IP list/ {print "- 封禁 IP：" $2}
            '
    done
}

install_scanner_jail() {
    title "启用 ufw-scanner 扫描器"
    echo "扫描器会读取 UFW 日志，自动封禁频繁扫端口的 IP。"
    echo "1核1G 小机器默认不建议开启，除非经常被扫描。"

    confirm_yes "启用扫描器会增加少量日志读取和匹配开销。" || return

    command -v fail2ban-client >/dev/null 2>&1 || {
        bad "请先安装 Fail2Ban。"
        return
    }

    backup_configs
    ensure_log_files
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d

    cat >/etc/fail2ban/filter.d/ufw-scanner.conf <<'EOF'
# UFW 扫描器识别规则
[Definition]
failregex = ^.*\[UFW BLOCK\].*SRC=<HOST> .*$
ignoreregex =
EOF

    cat >/etc/fail2ban/jail.d/ufw-scanner.local <<'EOF'
# UFW 自动封禁扫描器
[ufw-scanner]
enabled = true
logpath = /var/log/ufw.log
filter = ufw-scanner
findtime = 10m
maxretry = 12
bantime = 6h
banaction = ufw
backend = polling
EOF

    ufw logging low >/dev/null 2>&1 || true
    safe_restart_fail2ban
}

disable_scanner_jail() {
    title "禁用 ufw-scanner 扫描器"

    if [ -f /etc/fail2ban/jail.d/ufw-scanner.local ]; then
        backup_configs
        mv /etc/fail2ban/jail.d/ufw-scanner.local /etc/fail2ban/jail.d/ufw-scanner.local.disabled
        systemctl restart fail2ban >/dev/null 2>&1 || true
        ok "已禁用 ufw-scanner。"
    else
        warn "未发现已启用的 ufw-scanner。"
    fi
}

unban_ip() {
    title "解封 IP"

    read -rp "请输入要解封的 IP：" ip
    [ -z "$ip" ] && warn "IP 不能为空。" && return

    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')"

    for jail in $jails; do
        jail="$(echo "$jail" | xargs)"
        fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
    done

    ok "已尝试从所有防护中解封：$ip"
}

# ==================================================
# 分析
# ==================================================

analyze_ufw_logs() {
    title "UFW 拦截分析"

    if [ ! -s /var/log/ufw.log ]; then
        warn "暂无 UFW 拦截日志。"
        return
    fi

    total="$(grep -c "UFW BLOCK" /var/log/ufw.log 2>/dev/null || echo 0)"
    echo "拦截记录数量：$total"

    [ "$total" = "0" ] && return

    section "高频来源 IP"
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*SRC=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- 来源 " $2 "，触发 " $1 " 次"}'

    section "高频目标端口"
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*DPT=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- 端口 " $2 "，被探测 " $1 " 次"}'
}

analyze_fail2ban_logs() {
    title "Fail2Ban 封禁分析"

    if [ ! -s /var/log/fail2ban.log ]; then
        warn "暂无 Fail2Ban 日志内容。"
        return
    fi

    echo "封禁次数：$(grep -ci " Ban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
    echo "解封次数：$(grep -ci " Unban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
    echo "错误数量：$(grep -ci "ERROR" /var/log/fail2ban.log 2>/dev/null || echo 0)"

    section "最近高频封禁 IP"
    grep " Ban " /var/log/fail2ban.log 2>/dev/null \
        | tail -n 100 \
        | sed -n 's/.*Ban \([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- IP " $2 "，最近封禁 " $1 " 次"}'
}

show_public_port_summary() {
    title "公网端口 / 服务分析"

    if ! command -v ss >/dev/null 2>&1; then
        bad "未找到 ss 命令，无法分析端口。"
        return
    fi

    tmp="$(mktemp)"
    ss -tulpenH 2>/dev/null > "$tmp"

    if [ ! -s "$tmp" ]; then
        warn "未检测到监听端口。"
        rm -f "$tmp"
        return
    fi

    awk '
        {
            local=$5
            if (local ~ /^0\.0\.0\.0:/ || local ~ /^\[::\]:/ || local ~ /^:::/ || local ~ /^\*:/) print
        }
    ' "$tmp" > "$tmp.public"

    if [ ! -s "$tmp.public" ]; then
        ok "未发现明显公网监听端口。"
        rm -f "$tmp" "$tmp.public"
        return
    fi

    echo "公网监听数量：$(wc -l < "$tmp.public" | xargs)"
    echo "说明：公网监听表示外部网络可能访问到该端口，最终还要看 UFW 和云安全组。"

    section "公网监听明细"

    awk '
    {
        proto=$1
        local=$5
        port=local
        sub(/^.*:/,"",port)

        proc="-"
        pid="-"

        if ($0 ~ /users:\(\("/) {
            proc=$0
            sub(/^.*users:\(\("/,"",proc)
            sub(/".*$/,"",proc)

            pid=$0
            sub(/^.*pid=/,"",pid)
            sub(/,.*/,"",pid)
            if (pid !~ /^[0-9]+$/) pid="-"
        }

        key=proto ":" port ":" proc ":" pid
        if (!seen[key]++) print proto, port, proc, pid
    }' "$tmp.public" | while read -r proto port proc pid; do
        upper="$(echo "$proto" | tr '[:lower:]' '[:upper:]')"

        if [ "$proc" = "-" ] || [ -z "$proc" ]; then
            service="$(port_name "$port")"
            proc_show="未知进程"
        else
            service="$proc"
            proc_show="$proc"
        fi

        if is_danger_port "$port"; then
            bad "${upper} ${port}（$(port_name "$port")）"
            echo "   运行服务：${service}"
            echo "   进程：${proc_show}"
            echo "   风险：不建议公网开放"
        else
            echo "- ${upper} ${port}（$(port_name "$port")）"
            echo "   运行服务：${service}"
            echo "   进程：${proc_show}"
        fi
    done

    section "危险端口检查"
    danger=0
    for p in 21 25 3306 5432 6379 27017; do
        if grep -Eq ":${p}[[:space:]]" "$tmp.public"; then
            bad "发现公网监听危险端口 ${p}：$(port_name "$p")"
            danger=1
        fi
    done

    [ "$danger" = 0 ] && ok "未发现常见数据库/邮件/FTP 危险端口公网监听。"

    rm -f "$tmp" "$tmp.public"
}

# ==================================================
# 自检
# ==================================================

security_self_check() {
    clear_screen
    title "安全检测报告"

    score=100
    warn_count=0
    bad_count=0

    add_warn() {
        warn "$1"
        score=$((score-8))
        warn_count=$((warn_count+1))
    }

    add_bad() {
        bad "$1"
        score=$((score-15))
        bad_count=$((bad_count+1))
    }

    section "防火墙"
    if command -v ufw >/dev/null 2>&1; then
        ufw status | grep -qi "Status: active" \
            && ok "UFW 已启用" \
            || add_bad "UFW 未启用"

        ufw status verbose | grep -qi "Default: deny (incoming)" \
            && ok "默认入站为拒绝" \
            || add_bad "默认入站不是拒绝"

        if iptables -S 2>/dev/null | grep -q "ufw"; then
            ok "iptables 中检测到 UFW 规则"
        elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qi "ufw"; then
            ok "nftables 中检测到 UFW 规则"
        else
            add_warn "底层规则中未明显检测到 UFW"
        fi

        rule_count="$(ufw status numbered 2>/dev/null | grep -c '^\[' || true)"
        info "UFW 规则数量：${rule_count}"
    else
        add_bad "UFW 未安装"
    fi

    section "防爆破"
    if command -v fail2ban-client >/dev/null 2>&1; then
        systemctl is-active --quiet fail2ban \
            && ok "Fail2Ban 正在运行" \
            || add_bad "Fail2Ban 未运行"

        jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"
        [ -n "$jail_list" ] \
            && ok "启用防护：$jail_list" \
            || add_warn "没有检测到启用中的防护"

        fail2ban-client status sshd >/dev/null 2>&1 \
            && ok "SSH 防爆破已启用" \
            || add_warn "SSH 防爆破未启用"
    else
        add_warn "Fail2Ban 未安装"
    fi

    section "日志与磁盘"
    [ -f "$LOGROTATE_FILE" ] && grep -q "rotate 7" "$LOGROTATE_FILE" \
        && ok "日志限制为保留 7 天" \
        || add_warn "未检测到日志 7 天保留配置"

    root_use="$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ "${root_use:-0}" -ge 90 ]; then
        add_bad "根分区使用率超过 90%"
    elif [ "${root_use:-0}" -ge 75 ]; then
        add_warn "根分区使用率超过 75%"
    else
        ok "根分区空间正常"
    fi

    section "Docker 风险"
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        add_warn "Docker 正在运行，Docker 发布端口可能绕过 UFW"
    else
        ok "未检测到运行中的 Docker"
    fi

    show_public_port_summary

    [ "$score" -lt 0 ] && score=0

    title "评分结果"
    echo "安全分：${score} / 100"
    echo "高风险项：${bad_count}"
    echo "提醒项：${warn_count}"

    if [ "$score" -ge 85 ]; then
        ok "评级：优秀"
    elif [ "$score" -ge 70 ]; then
        warn "评级：良好"
    elif [ "$score" -ge 50 ]; then
        warn "评级：一般，需要检查"
    else
        bad "评级：较危险，建议立即处理"
    fi
}

# ==================================================
# 推荐安装
# ==================================================

install_recommended_security() {
    title "推荐安装"
    echo "将安装 / 配置："
    info "UFW 防火墙"
    info "Fail2Ban SSH 防爆破"
    info "日志保留 7 天"
    info "不会默认启用 ufw-scanner 扫描器"
    echo

    confirm_yes "开始推荐安装？" || return

    install_ufw
    install_fail2ban
    install_log_limit

    ok "推荐安全配置完成。"
}

# ==================================================
# 卸载
# ==================================================

uninstall_menu() {
    clear_screen
    echo "===== 卸载菜单 ====="
    echo "1. 仅卸载本脚本"
    echo "2. 卸载 UFW"
    echo "3. 卸载 Fail2Ban"
    echo "4. 全部清理"
    echo "0. 返回"
    echo

    read -rp "选择：" x

    case "$x" in
        1)
            title "仅卸载本脚本"
            echo "会删除："
            info "$SELF_MENU"
            info "$WRAPPER_UFW"
            info "$LOGROTATE_FILE"
            info "$CURRENT_SCRIPT"
            echo
            echo "不会卸载 UFW / Fail2Ban。"

            confirm_yes "确认仅卸载本脚本？" || return

            rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"

            if [ -f "$CURRENT_SCRIPT" ] && echo "$CURRENT_SCRIPT" | grep -q "^/"; then
                rm -f "$CURRENT_SCRIPT"
            fi

            ok "本脚本已清理完成。"
            echo "现在退出菜单。"
            exit 0
            ;;
        2)
            confirm_yes "确认卸载 UFW？" || return

            ufw --force disable >/dev/null 2>&1 || true
            apt purge -y ufw
            apt autoremove -y
            rm -rf /etc/ufw "$WRAPPER_UFW"

            ok "UFW 已卸载。"
            ;;
        3)
            confirm_yes "确认卸载 Fail2Ban？" || return

            systemctl stop fail2ban >/dev/null 2>&1 || true
            systemctl disable fail2ban >/dev/null 2>&1 || true
            apt purge -y fail2ban
            apt autoremove -y
            rm -rf /etc/fail2ban

            ok "Fail2Ban 已卸载。"
            ;;
        4)
            confirm_yes "确认全部清理？这会卸载 UFW + Fail2Ban + 本脚本。" || return

            systemctl stop fail2ban >/dev/null 2>&1 || true
            ufw --force disable >/dev/null 2>&1 || true
            apt purge -y fail2ban ufw
            apt autoremove -y
            rm -rf /etc/fail2ban /etc/ufw
            rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"
            [ -f "$CURRENT_SCRIPT" ] && rm -f "$CURRENT_SCRIPT" 2>/dev/null || true

            ok "已全部清理。"
            exit 0
            ;;
    esac

    pause
}


# ==================================================
# 服务 / 进程中文分析
# ==================================================

service_cn_name() {
    name="$1"
    case "$name" in
        ssh|sshd|ssh.service|sshd.service) echo "SSH远程登录服务" ;;
        nginx|nginx.service) echo "Nginx网站服务" ;;
        apache2|httpd|apache2.service|httpd.service) echo "Apache网站服务" ;;
        caddy|caddy.service) echo "Caddy网站服务" ;;
        mysql|mysqld|mariadb|mysql.service|mariadb.service) echo "MySQL/MariaDB数据库" ;;
        redis-server|redis|redis.service|redis-server.service) echo "Redis缓存数据库" ;;
        postgresql|postgres|postgresql.service) echo "PostgreSQL数据库" ;;
        docker|dockerd|docker.service) echo "Docker容器服务" ;;
        fail2ban|fail2ban-server|fail2ban.service) echo "Fail2Ban防爆破服务" ;;
        ufw|ufw.service) echo "UFW防火墙服务" ;;
        systemd-resolved|systemd-resolved.service) echo "系统DNS解析服务" ;;
        cron|crond|cron.service|crond.service) echo "定时任务服务" ;;
        rsyslog|rsyslog.service) echo "系统日志服务" ;;
        x-ui|x-ui.service) echo "X-UI面板服务" ;;
        sing-box|sing-box.service) echo "Sing-box代理服务" ;;
        hysteria|hysteria.service|hysteria-server.service) echo "Hysteria代理服务" ;;
        trojan|trojan.service) echo "Trojan代理服务" ;;
        v2ray|v2ray.service) echo "V2Ray代理服务" ;;
        nezha-agent|nezha-dashboard|nezha-agent.service|nezha-dashboard.service) echo "哪吒监控服务" ;;
        *) echo "未知/自定义服务" ;;
    esac
}

service_risk_hint() {
    name="$1"
    case "$name" in
        mysql|mysqld|mariadb|postgresql|postgres|redis|redis-server)
            echo "数据库类服务，不建议公网开放端口"
            ;;
        docker|dockerd)
            echo "Docker可能发布端口绕过UFW，需要特别检查"
            ;;
        ssh|sshd)
            echo "远程登录入口，建议配合Fail2Ban并限制来源IP"
            ;;
        nginx|apache2|httpd|caddy)
            echo "网站服务，确认只开放80/443等必要端口"
            ;;
        x-ui|sing-box|hysteria|trojan|v2ray)
            echo "代理/面板类服务，建议限制管理端口来源IP"
            ;;
        *)
            echo "请确认是否为你需要运行的服务"
            ;;
    esac
}

show_running_services_cn() {
    title "运行服务 / 进程中文摘要"

    section "系统服务"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | awk '{print $1}' \
            | grep -Ev '^(user@|session-|dbus-|systemd-|getty@|serial-getty@)' \
            | while read -r unit; do
                [ -z "$unit" ] && continue
                short="$(echo "$unit" | sed 's/\.service$//')"
                echo "- ${unit}"
                echo "  中文说明：$(service_cn_name "$short")"
                echo "  提醒：$(service_risk_hint "$short")"
            done
    else
        warn "当前系统没有 systemctl，无法读取系统服务。"
    fi

    section "公网监听进程"
    if ! command -v ss >/dev/null 2>&1; then
        warn "未找到 ss 命令，无法分析监听进程。"
        return
    fi

    tmp="$(mktemp)"
    ss -tulpenH 2>/dev/null > "$tmp"

    awk '$5 ~ /^0\.0\.0\.0:/ || $5 ~ /^\[::\]:/ || $5 ~ /^:::/ || $5 ~ /^\*:/' "$tmp" > "$tmp.public"

    if [ ! -s "$tmp.public" ]; then
        ok "未发现明显公网监听进程。"
        rm -f "$tmp" "$tmp.public"
        return
    fi

    awk '
    {
        proto=toupper($1)
        local=$5
        port=local
        sub(/^.*:/,"",port)

        proc="未知进程"
        if ($0 ~ /users:\(\("/) {
            proc=$0
            sub(/^.*users:\(\("/,"",proc)
            sub(/".*$/,"",proc)
        }

        key=proto ":" port ":" proc
        if (!seen[key]++) print proto, port, proc
    }' "$tmp.public" | while read -r proto port proc; do
        echo "- ${proto} ${port}"
        echo "  端口说明：$(port_name "$port")"
        echo "  运行进程：${proc}"
        echo "  中文说明：$(service_cn_name "$proc")"
        echo "  提醒：$(service_risk_hint "$proc")"
    done

    rm -f "$tmp" "$tmp.public"
}

simple_dashboard() {
    clear_screen
    title "安全状态总览"

    section "核心状态"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
        ok "防火墙：已启用"
    else
        bad "防火墙：未启用"
    fi

    if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
        ok "防爆破：运行中"
    else
        warn "防爆破：未运行或未安装"
    fi

    if [ -f "$LOGROTATE_FILE" ]; then
        ok "日志限制：已配置7天保留"
    else
        warn "日志限制：未检测到"
    fi

    section "公网端口"
    show_public_port_summary
}

# ==================================================
# 菜单
# ==================================================

ufw_menu() {
    while true; do
        clear_screen
        echo "===== 防火墙管理（UFW）====="
        echo "1. 状态 / 规则"
        echo "2. 批量放行端口"
        echo "3. 批量拒绝端口"
        echo "4. 删除规则"
        echo "5. 启用 / 禁用 / 重载 / 重置"
        echo "6. 拦截分析"
        echo "7. 最小安全模式"
        echo "0. 返回"
        echo

        read -rp "选择：" c

        case "$c" in
            1) show_ufw_status ;;
            2) batch_allow_ports ;;
            3) batch_deny_ports ;;
            4) delete_ufw_rule ;;
            5)
                title "UFW 操作"
                echo "1. 启用"
                echo "2. 禁用"
                echo "3. 重载"
                echo "4. 重置"
                read -rp "选择：" x
                case "$x" in
                    1) ufw --force enable ;;
                    2) ufw disable ;;
                    3) ufw reload ;;
                    4)
                        confirm_yes "确认重置全部 UFW 规则？" && backup_configs && ufw --force reset
                        ;;
                esac
                ;;
            6) analyze_ufw_logs ;;
            7) minimal_safe_mode ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac

        pause
    done
}

fail2ban_menu() {
    while true; do
        clear_screen
        echo "===== 防爆破管理（Fail2Ban）====="
        echo "1. 防护摘要"
        echo "2. 编辑 SSH 防爆破配置"
        echo "3. 启用 ufw-scanner 扫描器"
        echo "4. 禁用 ufw-scanner 扫描器"
        echo "5. 解封 IP"
        echo "6. 封禁分析"
        echo "7. 测试 / 重启"
        echo "0. 返回"
        echo

        read -rp "选择：" c

        case "$c" in
            1) show_fail2ban_status ;;
            2)
                backup_configs
                edit_fail2ban_basic_config
                safe_restart_fail2ban
                ;;
            3) install_scanner_jail ;;
            4) disable_scanner_jail ;;
            5) unban_ip ;;
            6) analyze_fail2ban_logs ;;
            7)
                title "Fail2Ban 测试 / 重启"
                fail2ban-client -t >/tmp/f2b-test.log 2>&1
                if [ $? -eq 0 ]; then
                    ok "配置测试通过。"
                    systemctl restart fail2ban
                    systemctl is-active --quiet fail2ban && ok "重启成功。" || bad "重启失败。"
                else
                    analyze_fail2ban_error
                fi
                ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac

        pause
    done
}

analysis_menu() {
    clear_screen
    analyze_ufw_logs
    echo
    analyze_fail2ban_logs
    echo
    show_public_port_summary
    pause
}

main_menu() {
    need_root
    install_self_alias
    install_log_limit >/dev/null 2>&1 || true

    while true; do
        clear_screen
        check_tools

        echo "===== UFW-F 清爽终极版 ====="
        [ "$UFW_OK" = 1 ] && echo "防火墙：已安装" || echo "防火墙：未安装"
        [ "$F2B_OK" = 1 ] && echo "防爆破：已安装" || echo "防爆破：未安装"
        echo
        echo "1. 状态总览"
        echo "2. 推荐安装"
        echo "3. 防火墙管理"
        echo "4. 防爆破管理"
        echo "5. 服务/进程查询"
        echo "6. 安全检测报告"
        echo "7. 日志与端口分析"
        echo "8. 清理/备份/卸载"
        echo "0. 退出"
        echo

        read -rp "选择：" c

        case "$c" in
            1) simple_dashboard; pause ;;
            2) install_recommended_security; pause ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) show_running_services_cn; pause ;;
            6) security_self_check; pause ;;
            7) analysis_menu ;;
            8)
                clear_screen
                echo "===== 清理 / 备份 / 卸载 ====="
                echo "1. 主动清理日志"
                echo "2. 备份配置"
                echo "3. 卸载菜单"
                echo "0. 返回"
                read -rp "选择：" x
                case "$x" in
                    1) clean_security_logs; pause ;;
                    2) backup_configs; pause ;;
                    3) uninstall_menu ;;
                esac
                ;;
            0) exit 0 ;;
            *) warn "无效选择。"; pause ;;
        esac
    done
}

main_menu
