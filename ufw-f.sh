#!/usr/bin/env bash
# UFW / Fail2Ban 中文轻量管理脚本 v4
# sudo ufw -f 进入菜单

set -u

REAL_UFW="/usr/sbin/ufw"
SELF_MENU="/usr/local/sbin/ufw-f-menu"
WRAPPER_UFW="/usr/local/sbin/ufw"
LOGROTATE_FILE="/etc/logrotate.d/ufw-fail2ban-lite"

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo $0"; exit 1; }; }
pause(){ echo; read -rp "按回车继续..."; }
pkg_install(){ apt update && apt install -y "$@"; }

install_self_alias(){
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

check_tools(){
    command -v ufw >/dev/null 2>&1 && UFW_OK=1 || UFW_OK=0
    command -v fail2ban-client >/dev/null 2>&1 && F2B_OK=1 || F2B_OK=0
}

install_log_limit(){
    mkdir -p /etc/logrotate.d
    cat >"$LOGROTATE_FILE" <<'EOF'
# UFW / Fail2Ban 日志限制：每天轮转，只保留 7 天

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

ensure_log_files(){
    mkdir -p /var/log
    touch /var/log/fail2ban.log /var/log/ufw.log
    chmod 640 /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
    chown root:adm /var/log/fail2ban.log /var/log/ufw.log 2>/dev/null || true
}

clean_security_logs(){
    echo "会清空 UFW / Fail2Ban 当前日志，不删除配置。"
    read -rp "确认清理？输入 YES：" yes
    [ "$yes" = "YES" ] || return
    : > /var/log/fail2ban.log 2>/dev/null || true
    : > /var/log/ufw.log 2>/dev/null || true
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true
    systemctl reload fail2ban >/dev/null 2>&1 || true
    systemctl reload rsyslog >/dev/null 2>&1 || true
    echo "日志已清理，systemd 日志已尝试只保留 7 天。"
}

port_name(){
    case "$1" in
        20|21) echo "FTP 文件传输" ;;
        22) echo "SSH 远程登录" ;;
        25|465|587) echo "邮件发送服务" ;;
        53) echo "DNS 域名解析" ;;
        80) echo "HTTP 网站" ;;
        443) echo "HTTPS 网站" ;;
        8080) echo "常见 Web 服务" ;;
        8443) echo "常见 HTTPS 面板/服务" ;;
        3306) echo "MySQL 数据库" ;;
        5432) echo "PostgreSQL 数据库" ;;
        6379) echo "Redis 数据库" ;;
        27017) echo "MongoDB 数据库" ;;
        *) echo "未知/自定义服务" ;;
    esac
}

show_ufw_summary(){
    echo "========== UFW 防火墙中文摘要 =========="
    command -v ufw >/dev/null 2>&1 || { echo "UFW 未安装。"; return; }

    v="$(ufw status verbose 2>/dev/null || true)"
    echo "$v" | grep -qi "Status: active" && echo "状态：已启用" || echo "状态：未启用"
    echo "$v" | grep -qi "Logging: on" && echo "日志：已开启" || echo "日志：未开启或未知"
    echo "$v" | grep -qi "Default: deny (incoming)" && echo "默认入站：拒绝，安全" || echo "默认入站：不是拒绝，建议检查"
    echo "$v" | grep -qi "allow (outgoing)" && echo "默认出站：允许，正常" || echo "默认出站：不是允许，请确认"

    echo
    echo "规则中文摘要："
    ufw status | awk 'NR>4 && $0 !~ /^--/ && NF>=3' | while read -r line; do
        to="$(echo "$line" | awk '{print $1}')"
        action="$(echo "$line" | grep -q "ALLOW" && echo "放行" || echo "$line" | grep -q "DENY" && echo "拒绝" || echo "其他")"
        port="$(echo "$to" | sed 's/(v6)//g;s#/tcp##;s#/udp##' | xargs)"
        proto="自动"; echo "$to" | grep -q "/tcp" && proto="TCP"; echo "$to" | grep -q "/udp" && proto="UDP"
        echo "$to" | grep -q "(v6)" && ipver="IPv6" || ipver="IPv4"
        [ -n "$port" ] && echo "- ${action} ${port}，协议 ${proto}，${ipver}，说明：$(port_name "$port")"
    done
}

batch_allow_ports(){
    echo "可一次输入多个端口，例如：80 443 8443"
    echo "也支持协议：80/tcp 53/udp"
    read -rp "放行端口：" ports
    [ -z "$ports" ] && echo "未输入。" && return
    for p in $ports; do
        ufw allow "$p" comment "用户允许规则"
        clean="$(echo "$p" | sed 's#/.*##')"
        echo "已放行：$p，说明：$(port_name "$clean")"
    done
}

batch_deny_ports(){
    echo "可一次输入多个端口，例如：3306 6379 27017"
    echo "也支持协议：3306/tcp 53/udp"
    read -rp "拒绝端口：" ports
    [ -z "$ports" ] && echo "未输入。" && return
    for p in $ports; do
        ufw deny "$p" comment "用户拒绝规则"
        clean="$(echo "$p" | sed 's#/.*##')"
        echo "已拒绝：$p，说明：$(port_name "$clean")"
    done
}

delete_ufw_rule_cn(){
    echo "========== 删除 UFW 规则 =========="
    mapfile -t rules < <(ufw status numbered 2>/dev/null | grep '^\[')
    [ "${#rules[@]}" -eq 0 ] && echo "没有可删除的规则。" && return

    for r in "${rules[@]}"; do
        num="$(echo "$r" | sed -n 's/^\[\s*\([0-9]\+\)\].*/\1/p')"
        to="$(echo "$r" | sed 's/^\[[^]]*\]//' | awk '{print $1}')"
        action="$(echo "$r" | grep -q "ALLOW" && echo "放行" || echo "$r" | grep -q "DENY" && echo "拒绝" || echo "规则")"
        port="$(echo "$to" | sed 's/(v6)//g;s#/tcp##;s#/udp##' | xargs)"
        echo "编号 ${num}：${action}端口 ${port}，说明：$(port_name "$port")"
    done

    read -rp "输入要删除的编号：" num
    [ -n "$num" ] && ufw delete "$num"
}

analyze_fail2ban_error(){
    echo "========== Fail2Ban 启动失败分析 =========="
    err="$(journalctl -u fail2ban -n 80 --no-pager 2>/dev/null; cat /tmp/f2b-test.log 2>/dev/null)"
    found=0
    echo "$err" | grep -qi "Have not found any log file" && { echo "问题：某个防护找不到日志文件。"; found=1; }
    echo "$err" | grep -qi "No failure-id group" && { echo "问题：过滤规则不兼容当前日志格式。"; found=1; }
    echo "$err" | grep -qi "ERROR" && { echo "错误摘要："; echo "$err" | grep -i "ERROR" | tail -n 5; found=1; }
    [ "$found" = 0 ] && echo "没有识别到明确原因。"
}

safe_restart_fail2ban(){
    ensure_log_files
    fail2ban-client -t >/tmp/f2b-test.log 2>&1
    if [ $? -ne 0 ]; then
        [ -f /etc/fail2ban/jail.d/ufw-scanner.local ] && mv /etc/fail2ban/jail.d/ufw-scanner.local /etc/fail2ban/jail.d/ufw-scanner.local.disabled
        fail2ban-client -t >/tmp/f2b-test.log 2>&1 || { analyze_fail2ban_error; return 1; }
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    systemctl is-active --quiet fail2ban && echo "Fail2Ban 已正常运行。" || analyze_fail2ban_error
}

install_ufw(){
    command -v ufw >/dev/null 2>&1 || pkg_install ufw
    read -rp "SSH 端口，默认 22：" ssh_port
    ssh_port="${ssh_port:-22}"
    ufw allow "${ssh_port}/tcp" comment "SSH 远程连接端口"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging on
    read -rp "是否启用 UFW？默认 Y：[Y/n] " yn
    yn="${yn:-Y}"
    case "$yn" in y|Y) ufw --force enable ;; *) echo "已跳过启用 UFW。" ;; esac
    systemctl enable ufw >/dev/null 2>&1 || true
    install_self_alias
    install_log_limit
    pause
}

edit_fail2ban_basic_config(){
    echo "========== Fail2Ban 基础配置 =========="
    echo "不输入则使用默认值。"
    read -rp "SSH 端口，默认 22：" ssh_port; ssh_port="${ssh_port:-22}"
    read -rp "失败次数，默认 5：" maxretry; maxretry="${maxretry:-5}"
    read -rp "检测时间，默认 10m：" findtime; findtime="${findtime:-10m}"
    read -rp "封禁时间，默认 1h：" bantime; bantime="${bantime:-1h}"
    read -rp "递增封禁，默认开启：[Y/n] " inc; inc="${inc:-Y}"
    case "$inc" in y|Y) bantime_increment="true" ;; *) bantime_increment="false" ;; esac
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
# 不发邮件，只封禁
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
    echo "基础配置已写入。"
}

install_fail2ban(){
    command -v fail2ban-client >/dev/null 2>&1 || pkg_install fail2ban
    edit_fail2ban_basic_config
    install_log_limit
    ensure_log_files
    safe_restart_fail2ban
    install_self_alias
    pause
}

install_scanner_jail(){
    command -v fail2ban-client >/dev/null 2>&1 || { echo "请先安装 Fail2Ban。"; pause; return; }
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
maxretry = 8
bantime = 6h
banaction = ufw
backend = polling
EOF
    ufw logging on >/dev/null 2>&1 || true
    safe_restart_fail2ban && echo "扫描器已启用：ufw-scanner"
    pause
}

install_all_security(){
    install_log_limit
    install_ufw
    install_fail2ban
    install_scanner_jail
    install_log_limit
}

analyze_ufw_logs(){
    echo "========== UFW 拦截分析 =========="
    [ ! -s /var/log/ufw.log ] && { echo "暂无 UFW 拦截日志。"; return; }
    total="$(grep -c "UFW BLOCK" /var/log/ufw.log 2>/dev/null || echo 0)"
    echo "拦截记录数量：$total"
    [ "$total" = "0" ] && return
    echo "高频来源 IP："
    grep "UFW BLOCK" /var/log/ufw.log | sed -n 's/.*SRC=\([^ ]*\).*/\1/p' | sort | uniq -c | sort -nr | head -n 8 | awk '{print "来源 " $2 "，触发 " $1 " 次"}'
    echo "高频目标端口："
    grep "UFW BLOCK" /var/log/ufw.log | sed -n 's/.*DPT=\([^ ]*\).*/\1/p' | sort | uniq -c | sort -nr | head -n 8 | awk '{print "端口 " $2 "，被探测 " $1 " 次"}'
}

analyze_fail2ban_logs(){
    echo "========== Fail2Ban 封禁分析 =========="
    [ ! -s /var/log/fail2ban.log ] && { echo "暂无 Fail2Ban 日志内容。"; return; }
    echo "封禁次数：$(grep -ci " Ban " /var/log/fail2ban.log || echo 0)"
    echo "解封次数：$(grep -ci " Unban " /var/log/fail2ban.log || echo 0)"
    echo "错误数量：$(grep -ci "ERROR" /var/log/fail2ban.log || echo 0)"
    echo "最近高频封禁 IP："
    grep " Ban " /var/log/fail2ban.log | tail -n 100 | sed -n 's/.*Ban \([^ ]*\).*/\1/p' | sort | uniq -c | sort -nr | head -n 8 | awk '{print "IP " $2 "，最近封禁 " $1 " 次"}'
}

show_port_summary(){
    echo "========== 监听端口中文摘要 =========="
    command -v ss >/dev/null 2>&1 || { echo "未找到 ss 命令。"; return; }
    tmp="$(mktemp)"
    ss -tulpenH 2>/dev/null > "$tmp"
    [ ! -s "$tmp" ] && { echo "未检测到监听端口。"; rm -f "$tmp"; return; }

    echo "监听总数：$(wc -l < "$tmp" | xargs)"
    echo "TCP 监听：$(awk '$1=="tcp"{c++} END{print c+0}' "$tmp")"
    echo "UDP 监听：$(awk '$1=="udp"{c++} END{print c+0}' "$tmp")"
    echo
    echo "监听明细："

    awk '
    {
        proto=$1; local=$5; port=local; sub(/^.*:/,"",port);
        addr=local; sub(":" port "$","",addr);
        proc="-";
        if ($0 ~ /users:\(\("/) { proc=$0; sub(/^.*users:\(\("/,"",proc); sub(/".*$/,"",proc); }
        key=proto ":" port ":" addr ":" proc;
        if (!seen[key]++) print proto, port, addr, proc;
    }' "$tmp" | while read -r proto port addr proc; do
        [ -z "$port" ] && continue
        case "$addr" in 127.*|::1|localhost*) scope="本机监听" ;; 0.0.0.0|::|\[::\]|*) scope="可能公网监听" ;; esac
        upper="$(echo "$proto" | tr '[:lower:]' '[:upper:]')"
        [ "$proc" = "-" ] && svc="$(port_name "$port")" || svc="$proc"
        echo "- ${upper} ${port}：$(port_name "$port")；范围：${scope}；进程/服务：${svc}"
    done

    public_count="$(awk '{local=$5; if (local ~ /\[::\]:/ || local ~ /^:::/ || local ~ /^0\.0\.0\.0:/ || local ~ /^\*:/) c++} END{print c+0}' "$tmp")"
    echo
    echo "风险提示：检测到 ${public_count} 个明显全网监听端口。"
    rm -f "$tmp"
}

show_fail2ban_status_summary(){
    echo "========== Fail2Ban 防护摘要 =========="
    command -v fail2ban-client >/dev/null 2>&1 || { echo "Fail2Ban 未安装。"; return; }
    systemctl is-active --quiet fail2ban || { echo "服务状态：未运行"; analyze_fail2ban_error; return; }
    echo "服务状态：运行中"
    jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"
    [ -z "$jail_list" ] && { echo "启用防护：无"; return; }
    echo "启用防护：$jail_list"
    for jail in $(echo "$jail_list" | tr ',' ' '); do
        jail="$(echo "$jail" | xargs)"
        echo "[$jail]"
        fail2ban-client status "$jail" 2>/dev/null | awk -F: '/Currently failed/{print "当前失败次数："$2}/Total failed/{print "累计失败次数："$2}/Currently banned/{print "当前封禁数量："$2}/Total banned/{print "累计封禁数量："$2}/Banned IP list/{print "封禁 IP："$2}'
    done
}

security_self_check(){
    score=100; warn_count=0; danger_count=0
    ok(){ echo "✅ $1"; }
    warn(){ echo "⚠️  $1"; score=$((score-8)); warn_count=$((warn_count+1)); }
    danger(){ echo "❌ $1"; score=$((score-15)); danger_count=$((danger_count+1)); }

    clear
    echo "========== 一键自检 + 风险检测 + 安全评分 =========="
    echo "【UFW】"
    if command -v ufw >/dev/null 2>&1; then
        ufw status | grep -qi "Status: active" && ok "UFW 已启用" || danger "UFW 未启用"
        ufw status verbose | grep -qi "Default: deny (incoming)" && ok "默认入站为拒绝" || danger "默认入站不是拒绝"
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
    else
        warn "Fail2Ban 未安装"
    fi

    echo
    echo "【日志与磁盘】"
    [ -f "$LOGROTATE_FILE" ] && grep -q "rotate 7" "$LOGROTATE_FILE" && ok "日志限制为保留 7 天" || warn "未检测到日志 7 天保留配置"
    root_use="$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    [ "${root_use:-0}" -ge 90 ] && danger "根分区使用率超过 90%" || ok "根分区空间未超过 90%"

    echo
    show_port_summary

    [ "$score" -lt 0 ] && score=0
    echo
    echo "安全分：${score}/100"
    echo "高风险项：${danger_count}"
    echo "提醒项：${warn_count}"
    [ "$score" -ge 85 ] && echo "评级：优秀" || [ "$score" -ge 70 ] && echo "评级：良好" || [ "$score" -ge 50 ] && echo "评级：一般" || echo "评级：较危险"
}

ufw_menu(){
    while true; do
        clear
        echo "===== UFW ====="
        echo "1. 状态摘要"
        echo "2. 规则中文列表"
        echo "3. 批量放行端口"
        echo "4. 批量拒绝端口"
        echo "5. 删除规则"
        echo "6. 启用/禁用/重载/重置"
        echo "7. 拦截分析"
        echo "0. 返回"
        read -rp "选择：" c
        case "$c" in
            1|2) show_ufw_summary ;;
            3) batch_allow_ports ;;
            4) batch_deny_ports ;;
            5) delete_ufw_rule_cn ;;
            6)
                echo "1. 启用  2. 禁用  3. 重载  4. 重置"
                read -rp "选择：" x
                case "$x" in
                    1) ufw --force enable ;;
                    2) ufw disable ;;
                    3) ufw reload ;;
                    4) read -rp "确认重置？输入 YES：" yes; [ "$yes" = "YES" ] && ufw --force reset ;;
                esac ;;
            7) analyze_ufw_logs ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac
        pause
    done
}

fail2ban_menu(){
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
        read -rp "选择：" c
        case "$c" in
            1) show_fail2ban_status_summary ;;
            2) edit_fail2ban_basic_config; safe_restart_fail2ban ;;
            3) install_scanner_jail ;;
            4)
                read -rp "IP：" ip
                jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')"
                for jail in $jails; do fail2ban-client set "$(echo "$jail" | xargs)" unbanip "$ip" >/dev/null 2>&1 || true; done
                echo "已尝试解封：$ip" ;;
            5) analyze_fail2ban_logs ;;
            6) fail2ban-client -t >/tmp/f2b-test.log 2>&1 && { echo "配置测试通过。"; systemctl restart fail2ban; } || analyze_fail2ban_error ;;
            7) cat /etc/fail2ban/jail.local 2>/dev/null || echo "未找到配置。" ;;
            0) return ;;
            *) echo "无效选择。" ;;
        esac
        pause
    done
}

uninstall_menu(){
    clear
    echo "===== 卸载菜单 ====="
    echo "1. 仅卸载本脚本"
    echo "2. 卸载 UFW"
    echo "3. 卸载 Fail2Ban"
    echo "4. 全部清理"
    echo "0. 返回"
    read -rp "选择：" x
    case "$x" in
        1) rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"; echo "脚本入口已清理。" ;;
        2) ufw --force disable >/dev/null 2>&1 || true; apt purge -y ufw; apt autoremove -y; rm -rf /etc/ufw "$WRAPPER_UFW"; echo "UFW 已卸载。" ;;
        3) systemctl stop fail2ban >/dev/null 2>&1 || true; systemctl disable fail2ban >/dev/null 2>&1 || true; apt purge -y fail2ban; apt autoremove -y; rm -rf /etc/fail2ban; echo "Fail2Ban 已卸载。" ;;
        4) systemctl stop fail2ban >/dev/null 2>&1 || true; ufw --force disable >/dev/null 2>&1 || true; apt purge -y fail2ban ufw; apt autoremove -y; rm -rf /etc/fail2ban /etc/ufw; rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"; echo "已全部清理。" ;;
    esac
    pause
}

main_menu(){
    need_root
    install_self_alias
    install_log_limit >/dev/null 2>&1 || true
    while true; do
        clear
        check_tools
        echo "===== UFW-F 管理 v4 ====="
        [ "$UFW_OK" = 1 ] && echo "UFW：已安装" || echo "UFW：未安装"
        [ "$F2B_OK" = 1 ] && echo "Fail2Ban：已安装" || echo "Fail2Ban：未安装"
        echo
        echo "1. 一键安装"
        echo "2. UFW 管理"
        echo "3. Fail2Ban 管理"
        echo "4. 自检评分"
        echo "5. 日志/端口分析"
        echo "6. 主动清理日志"
        echo "7. 卸载菜单"
        echo "0. 退出"
        read -rp "选择：" c
        case "$c" in
            1) install_all_security ;;
            2) ufw_menu ;;
            3) fail2ban_menu ;;
            4) security_self_check; pause ;;
            5) analyze_ufw_logs; echo; analyze_fail2ban_logs; echo; show_port_summary; pause ;;
            6) clean_security_logs; pause ;;
            7) uninstall_menu ;;
            0) exit 0 ;;
            *) echo "无效选择。"; pause ;;
        esac
    done
}

main_menu
