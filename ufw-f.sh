#!/usr/bin/env bash
# ==================================================
# UFW-F 最终极简版
# Debian / Ubuntu 适用
#
# 功能：
# - 推荐安装 UFW + Fail2Ban SSH 防爆破
# - 防火墙：状态、放行、拒绝、删除、启停、重置
# - 删除规则：按端口删除，支持 IPv4+IPv6 / 仅IPv4 / 仅IPv6
# - 防爆破：状态、重建SSH防护、解封IP、测试重启
# - 查看分析：对外端口/服务、异常开放端口、UFW拦截、Fail2Ban封禁
# - 日志：默认保留7天，可主动清理
# - 卸载：卸载脚本 / UFW / Fail2Ban / 全部清理
#
# 快捷入口：
# sudo ufw -f
# ==================================================

set -u

REAL_UFW="/usr/sbin/ufw"
SELF_MENU="/usr/local/sbin/ufw-f-menu"
WRAPPER_UFW="/usr/local/sbin/ufw"
LOGROTATE_FILE="/etc/logrotate.d/ufw-fail2ban-lite"
CURRENT_SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ==================================================
# 基础
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

title() {
    echo
    echo "===== $1 ====="
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

confirm_yes() {
    warn "$1"
    read -rp "确认继续？输入 yes/y：" yes
    case "$yes" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

pkg_install() {
    apt update
    apt install -y "$@"
}

check_tools() {
    command -v ufw >/dev/null 2>&1 && UFW_OK=1 || UFW_OK=0
    command -v fail2ban-client >/dev/null 2>&1 && F2B_OK=1 || F2B_OK=0
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

install_log_limit() {
    mkdir -p /etc/logrotate.d
    cat >"$LOGROTATE_FILE" <<'EOF'
# UFW / Fail2Ban 日志限制：每天轮转，只保留7天

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

port_name() {
    case "$1" in
        20|21) echo "FTP" ;;
        22) echo "SSH" ;;
        23) echo "Telnet" ;;
        25|465|587) echo "邮件" ;;
        53) echo "DNS" ;;
        80) echo "HTTP" ;;
        443) echo "HTTPS" ;;
        8080) echo "Web" ;;
        8443) echo "HTTPS/面板" ;;
        3306) echo "MySQL" ;;
        5432) echo "PostgreSQL" ;;
        6379) echo "Redis" ;;
        27017) echo "MongoDB" ;;
        3389) echo "远程桌面" ;;
        *) echo "自定义" ;;
    esac
}

is_danger_port() {
    case "$1" in
        21|23|25|3306|5432|6379|27017|3389) return 0 ;;
        *) return 1 ;;
    esac
}

service_cn_name() {
    name="$1"
    case "$name" in
        ssh|sshd) echo "SSH远程登录" ;;
        nginx) echo "Nginx网站服务" ;;
        apache2|httpd) echo "Apache网站服务" ;;
        caddy) echo "Caddy网站服务" ;;
        mysql|mysqld|mariadb) echo "MySQL/MariaDB数据库" ;;
        redis|redis-server) echo "Redis数据库" ;;
        postgres|postgresql) echo "PostgreSQL数据库" ;;
        docker|dockerd|docker-proxy) echo "Docker相关进程" ;;
        fail2ban|fail2ban-server) echo "Fail2Ban防爆破" ;;
        systemd-resolved) echo "系统DNS解析" ;;
        rsyslog) echo "系统日志服务" ;;
        cron|crond) echo "定时任务" ;;
        x-ui) echo "X-UI面板" ;;
        sing-box) echo "Sing-box服务" ;;
        hysteria|hysteria-server) echo "Hysteria服务" ;;
        trojan) echo "Trojan服务" ;;
        v2ray) echo "V2Ray服务" ;;
        nezha-agent|nezha-dashboard) echo "哪吒监控" ;;
        *) echo "未知/自定义" ;;
    esac
}

service_hint() {
    name="$1"
    case "$name" in
        docker-proxy)
            echo "Docker端口映射，可能绕过UFW"
            ;;
        docker|dockerd)
            echo "Docker可能发布端口绕过UFW"
            ;;
        mysql|mysqld|mariadb|redis|redis-server|postgres|postgresql)
            echo "数据库不建议公网开放"
            ;;
        ssh|sshd)
            echo "远程入口，建议配合Fail2Ban"
            ;;
        nginx|apache2|httpd|caddy)
            echo "网站服务，一般只需80/443"
            ;;
        x-ui|sing-box|hysteria|hysteria-server|trojan|v2ray)
            echo "面板/代理服务，管理端口建议限制IP"
            ;;
        *)
            echo "确认是否需要对外运行"
            ;;
    esac
}


# 从 UFW 编号规则中查找端口对应的规则编号
# 参数1：端口
# 参数2：all / v4 / v6
ufw_find_rule_nums() {
    port="$1"
    scope="$2"

    ufw status numbered 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            \[*)
                num="$(echo "$line" | sed -n 's/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p')"
                [ -z "$num" ] && continue

                case "$scope" in
                    v4) echo "$line" | grep -q "(v6)" && continue ;;
                    v6) echo "$line" | grep -q "(v6)" || continue ;;
                esac

                # 去掉编号和(v6)，只检查 To 字段附近是否匹配端口
                body="$(echo "$line" | sed 's/^\[[^]]*\][[:space:]]*//' | sed 's/(v6)//g')"
                to_field="$(echo "$body" | awk '{print $1}')"
                clean_to="$(echo "$to_field" | sed 's#/tcp##;s#/udp##')"

                if [ "$clean_to" = "$port" ]; then
                    echo "$num"
                fi
                ;;
        esac
    done | sort -nr
}

# 按编号静默删除，避免交互，且不用 ufw --force delete（部分版本会打印帮助）
ufw_delete_num_quiet() {
    num="$1"
    printf 'y\n' | ufw delete "$num" >/dev/null 2>&1
}

# ==================================================
# 状态 / 安装
# ==================================================

dashboard() {
    title "状态总览"

    check_tools

    if [ "$UFW_OK" = 1 ] && ufw status | grep -qi "Status: active"; then
        ok "防火墙：已启用"
    elif [ "$UFW_OK" = 1 ]; then
        bad "防火墙：未启用"
    else
        bad "防火墙：未安装"
    fi

    if [ "$F2B_OK" = 1 ] && systemctl is-active --quiet fail2ban; then
        ok "防爆破：运行中"
    elif [ "$F2B_OK" = 1 ]; then
        warn "防爆破：未运行"
    else
        warn "防爆破：未安装"
    fi

    [ -f "$LOGROTATE_FILE" ] && ok "日志：保留7天" || warn "日志：未配置7天限制"

    echo "磁盘：$(df / | awk 'NR==2 {print $5}')"
    echo

    show_open_ports_simple
}

recommended_install() {
    title "推荐安装"
    echo "安装/配置：UFW + Fail2Ban SSH防爆破 + 日志7天限制"
    echo "不会安装面板，不会常驻运行本脚本。"
    echo

    confirm_yes "开始推荐安装？" || return

    install_log_limit

    command -v ufw >/dev/null 2>&1 || pkg_install ufw

    read -rp "SSH端口，默认22：" ssh_port
    ssh_port="${ssh_port:-22}"

    ufw allow "${ssh_port}/tcp" comment "SSH远程连接端口"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging low

    warn "请确认 SSH ${ssh_port}/tcp 已放行。"
    read -rp "是否启用UFW？默认Y：[Y/n] " yn
    yn="${yn:-Y}"
    case "$yn" in
        y|Y|yes|YES|Yes) ufw --force enable ;;
        *) warn "已跳过启用UFW" ;;
    esac

    systemctl enable ufw >/dev/null 2>&1 || true

    command -v fail2ban-client >/dev/null 2>&1 || pkg_install fail2ban
    write_fail2ban_config
    restart_fail2ban_safe

    install_self_alias

    ok "推荐安装完成"
}

# ==================================================
# UFW 极简规则显示
# ==================================================

show_open_ports_simple() {
    title "开放端口"

    if ! command -v ufw >/dev/null 2>&1; then
        bad "UFW未安装"
        return
    fi

    v="$(ufw status verbose 2>/dev/null || true)"
    echo "$v" | grep -qi "Status: active" && ok "状态：已启用" || bad "状态：未启用"
    echo "$v" | grep -qi "Default: deny (incoming)" && ok "入站：默认拒绝" || warn "入站：不是默认拒绝"

    tmp="$(mktemp)"

    ufw status 2>/dev/null | awk '
        NR>4 && $0 !~ /^--/ && /ALLOW/ {
            to=$1
            if ($2=="(v6)") to=to" (v6)"
            print to
        }
    ' > "$tmp"

    echo
    if [ ! -s "$tmp" ]; then
        echo "暂无开放端口"
        rm -f "$tmp"
        return
    fi

    awk '
    {
        raw=$0
        v6 = raw ~ /\(v6\)/
        gsub(/\(v6\)/,"",raw)
        gsub(/\/tcp/,"",raw)
        gsub(/\/udp/,"",raw)
        gsub(/[[:space:]]/,"",raw)
        if (raw=="") next
        if (v6) ipv6[raw]=1; else ipv4[raw]=1
        ports[raw]=1
    }
    END {
        for (p in ports) {
            tag=""
            if (ipv4[p] && ipv6[p]) tag="v4+v6"
            else if (ipv4[p]) tag="v4"
            else if (ipv6[p]) tag="v6"
            print p "|" tag
        }
    }' "$tmp" | sort -n | while IFS="|" read -r port tag; do
        if is_danger_port "$port"; then
            echo "❌ ${port}（${tag}，$(port_name "$port")）"
        else
            echo "- ${port}（${tag}，$(port_name "$port")）"
        fi
    done

    rm -f "$tmp"
}
show_ufw_raw_rules() {
    title "详细规则"
    echo "ALLOW IN=放行，DENY IN=拒绝，(v6)=IPv6"
    echo
    ufw status numbered
}

ufw_allow_ports() {
    title "放行端口"
    echo "多个端口用空格，例如：80 443 8443"
    read -rp "端口：" ports
    [ -z "$ports" ] && warn "未输入端口" && return

    for p in $ports; do
        clean="$(echo "$p" | sed 's#/.*##')"
        if is_danger_port "$clean"; then
            warn "$clean 是高风险端口：$(port_name "$clean")"
            read -rp "确认放行 $p？输入 yes/y：" yes
            case "$yes" in
                y|Y|yes|YES|Yes) ;;
                *) warn "跳过 $p"; continue ;;
            esac
        fi
        ufw allow "$p" comment "用户允许规则"
        ok "已放行 $p"
    done
}

ufw_deny_ports() {
    title "拒绝端口"
    echo "多个端口用空格，例如：3306 6379"
    read -rp "端口：" ports
    [ -z "$ports" ] && warn "未输入端口" && return

    for p in $ports; do
        ufw deny "$p" comment "用户拒绝规则"
        ok "已拒绝 $p"
    done
}

ufw_delete_by_port() {
    title "删除端口规则"
    echo "1. 删除 v4+v6"
    echo "2. 只删 v4"
    echo "3. 只删 v6"
    echo "4. 按编号删"
    echo

    show_open_ports_simple
    echo

    read -rp "模式，默认1：" mode
    mode="${mode:-1}"

    case "$mode" in
        1|2|3)
            read -rp "端口，多个用空格：" ports
            [ -z "$ports" ] && warn "未输入端口" && return

            for p in $ports; do
                clean="$(echo "$p" | sed 's#/.*##')"

                case "$mode" in
                    1) scope="all"; label="$p" ;;
                    2) scope="v4"; label="$p 的v4规则" ;;
                    3) scope="v6"; label="$p 的v6规则" ;;
                esac

                mapfile -t nums < <(ufw_find_rule_nums "$clean" "$scope")

                if [ "${#nums[@]}" -eq 0 ]; then
                    warn "未找到 ${label}"
                else
                    ok "将删除编号：${nums[*]}"
                    for n in "${nums[@]}"; do
                        ufw_delete_num_quiet "$n"
                    done
                    ok "已删除 ${label}"
                fi
            done
            ;;
        4)
            show_ufw_raw_rules
            echo
            read -rp "编号，多个用空格，会自动倒序：" nums
            [ -z "$nums" ] && warn "未输入编号" && return
            for n in $(echo "$nums" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nr); do
                ufw_delete_num_quiet "$n"
            done
            ;;
        *)
            warn "无效模式"
            ;;
    esac
}
ufw_action_menu() {
    title "防火墙操作"
    echo "1. 启用"
    echo "2. 禁用"
    echo "3. 重载"
    echo "4. 重置"
    echo "0. 返回"
    echo

    read -rp "选择：" x
    case "$x" in
        1) ufw --force enable ;;
        2) ufw disable ;;
        3) ufw reload ;;
        4)
            confirm_yes "重置会删除所有UFW规则" || return
            ufw --force reset
            ;;
    esac
}

ufw_menu() {
    while true; do
        clear
        echo "===== 防火墙 ====="
        echo "1. 状态/开放端口"
        echo "2. 放行端口"
        echo "3. 拒绝端口"
        echo "4. 删除端口规则"
        echo "5. 启停/重载/重置"
        echo "6. 详细规则"
        echo "0. 返回"
        echo

        read -rp "选择：" c
        case "$c" in
            1) show_open_ports_simple; pause ;;
            2) ufw_allow_ports; pause ;;
            3) ufw_deny_ports; pause ;;
            4) ufw_delete_by_port; pause ;;
            5) ufw_action_menu; pause ;;
            6) show_ufw_raw_rules; pause ;;
            0) return ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

# ==================================================
# Fail2Ban
# ==================================================

write_fail2ban_config() {
    title "SSH防爆破配置"
    echo "不输入则使用默认值。"
    echo

    read -rp "SSH端口，默认22：" ssh_port
    ssh_port="${ssh_port:-22}"

    read -rp "失败次数，默认5：" maxretry
    maxretry="${maxretry:-5}"

    read -rp "检测时间，默认10m：" findtime
    findtime="${findtime:-10m}"

    read -rp "封禁时间，默认1h：" bantime
    bantime="${bantime:-1h}"

    mkdir -p /etc/fail2ban

    cat >/etc/fail2ban/jail.local <<EOF
# Fail2Ban基础防护配置

[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend = systemd
banaction = ufw
action = %(action_)s

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = %(sshd_log)s
backend = systemd
EOF
}

restart_fail2ban_safe() {
    ensure_log_files

    fail2ban-client -t >/tmp/f2b-test.log 2>&1
    if [ $? -ne 0 ]; then
        bad "Fail2Ban配置测试失败"
        grep -i "ERROR" /tmp/f2b-test.log | tail -n 5 || cat /tmp/f2b-test.log
        return 1
    fi

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban

    systemctl is-active --quiet fail2ban && ok "Fail2Ban运行中" || bad "Fail2Ban启动失败"
}

fail2ban_status() {
    title "防爆破状态"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        bad "Fail2Ban未安装"
        return
    fi

    systemctl is-active --quiet fail2ban && ok "服务：运行中" || bad "服务：未运行"

    jail_list="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | xargs || true)"
    [ -z "$jail_list" ] && { warn "无启用防护"; return; }

    echo "防护：$jail_list"

    for jail in $(echo "$jail_list" | tr ',' ' '); do
        jail="$(echo "$jail" | xargs)"
        echo
        echo "[$jail]"
        fail2ban-client status "$jail" 2>/dev/null \
            | awk -F: '
                /Currently failed/ {print "- 当前失败：" $2}
                /Total failed/ {print "- 累计失败：" $2}
                /Currently banned/ {print "- 当前封禁：" $2}
                /Total banned/ {print "- 累计封禁：" $2}
                /Banned IP list/ {print "- 封禁IP：" $2}
            '
    done
}

install_fail2ban_base() {
    command -v fail2ban-client >/dev/null 2>&1 || pkg_install fail2ban
    write_fail2ban_config
    restart_fail2ban_safe
}

fail2ban_unban_ip() {
    title "解封IP"
    read -rp "IP：" ip
    [ -z "$ip" ] && warn "IP不能为空" && return

    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' ' ')"
    for jail in $jails; do
        jail="$(echo "$jail" | xargs)"
        fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
    done

    ok "已尝试解封：$ip"
}

fail2ban_test_restart() {
    title "测试/重启"
    fail2ban-client -t >/tmp/f2b-test.log 2>&1
    if [ $? -eq 0 ]; then
        ok "配置测试通过"
        systemctl restart fail2ban
        systemctl is-active --quiet fail2ban && ok "重启成功" || bad "重启失败"
    else
        bad "配置测试失败"
        grep -i "ERROR" /tmp/f2b-test.log | tail -n 5 || cat /tmp/f2b-test.log
    fi
}

fail2ban_menu() {
    while true; do
        clear
        echo "===== 防爆破 ====="
        echo "1. 状态"
        echo "2. 安装/重建SSH防护"
        echo "3. 解封IP"
        echo "4. 测试/重启"
        echo "0. 返回"
        echo

        read -rp "选择：" c
        case "$c" in
            1) fail2ban_status; pause ;;
            2) install_fail2ban_base; pause ;;
            3) fail2ban_unban_ip; pause ;;
            4) fail2ban_test_restart; pause ;;
            0) return ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

# ==================================================
# 查看分析
# ==================================================

show_public_ports() {
    title "对外端口/服务"

    if ! command -v ss >/dev/null 2>&1; then
        bad "未找到ss命令"
        return
    fi

    tmp="$(mktemp)"
    ss -tulpenH 2>/dev/null > "$tmp"

    awk '
        {
            local=$5
            if (local !~ /^127\./ && local !~ /^\[::1\]/ && local !~ /^::1:/ && local !~ /^localhost:/) print
        }
    ' "$tmp" > "$tmp.out"

    if [ ! -s "$tmp.out" ]; then
        ok "未发现对外监听端口"
        rm -f "$tmp" "$tmp.out"
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
    }' "$tmp.out" | while read -r proto port proc; do
        if is_danger_port "$port"; then
            bad "${proto} ${port}（$(port_name "$port")）"
        else
            echo "- ${proto} ${port}（$(port_name "$port")）"
        fi
        echo "  进程：$proc"
        echo "  说明：$(service_cn_name "$proc")"
        echo "  提醒：$(service_hint "$proc")"
    done

    rm -f "$tmp" "$tmp.out"
}

ufw_allowed_ports_cache() {
    ufw status 2>/dev/null \
        | awk 'NR>4 && $0 !~ /^--/ && /ALLOW/ {print $1}' \
        | sed 's/(v6)//g;s#/tcp##;s#/udp##' \
        | xargs -n1 2>/dev/null \
        | sort -u
}

check_abnormal_open_ports() {
    title "异常开放检测"

    if ! command -v ss >/dev/null 2>&1; then
        bad "未找到ss命令"
        return
    fi

    tmp="$(mktemp)"
    pub="$(mktemp)"
    allow="$(mktemp)"
    abnormal="$(mktemp)"

    ss -tulpenH 2>/dev/null > "$tmp"

    awk '
        {
            local=$5
            if (local !~ /^127\./ && local !~ /^\[::1\]/ && local !~ /^::1:/ && local !~ /^localhost:/) print
        }
    ' "$tmp" > "$pub"

    ufw_allowed_ports_cache > "$allow"

    if [ ! -s "$pub" ]; then
        ok "未发现对外监听端口"
        rm -f "$tmp" "$pub" "$allow" "$abnormal"
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
    }' "$pub" | while read -r proto port proc; do
        if grep -qx "$port" "$allow"; then
            continue
        fi

        echo "$proto|$port|$proc" >> "$abnormal"

        if echo "$proc" | grep -qi "docker-proxy"; then
            bad "${proto} ${port}（$(port_name "$port")）疑似Docker绕过UFW"
            echo "  进程：$proc"
            echo "  建议：改为 127.0.0.1:${port}:${port} 或确认需要公网暴露"
        else
            warn "${proto} ${port}（$(port_name "$port")）未在UFW放行但对外监听"
            echo "  进程：$proc"
            echo "  建议：确认是否由面板/iptables/其他程序开放"
        fi

        if is_danger_port "$port"; then
            echo "  风险：高风险端口"
        fi

        echo
    done

    [ ! -s "$abnormal" ] && ok "未发现明显异常开放端口"

    rm -f "$tmp" "$pub" "$allow" "$abnormal"
}

analyze_ufw_logs() {
    title "UFW拦截分析"

    if [ ! -s /var/log/ufw.log ]; then
        warn "暂无UFW日志"
        return
    fi

    total="$(grep -c "UFW BLOCK" /var/log/ufw.log 2>/dev/null || echo 0)"
    echo "拦截数量：$total"

    [ "$total" = "0" ] && return

    echo
    echo "高频来源："
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*SRC=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- " $2 "，" $1 "次"}'

    echo
    echo "高频端口："
    grep "UFW BLOCK" /var/log/ufw.log 2>/dev/null \
        | sed -n 's/.*DPT=\([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- " $2 "，" $1 "次"}'
}

analyze_fail2ban_logs() {
    title "Fail2Ban封禁分析"

    if [ ! -s /var/log/fail2ban.log ]; then
        warn "暂无Fail2Ban日志"
        return
    fi

    echo "封禁：$(grep -ci " Ban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
    echo "解封：$(grep -ci " Unban " /var/log/fail2ban.log 2>/dev/null || echo 0)"
    echo "错误：$(grep -ci "ERROR" /var/log/fail2ban.log 2>/dev/null || echo 0)"

    echo
    echo "最近封禁IP："
    grep " Ban " /var/log/fail2ban.log 2>/dev/null \
        | tail -n 100 \
        | sed -n 's/.*Ban \([^ ]*\).*/\1/p' \
        | sort | uniq -c | sort -nr | head -n 8 \
        | awk '{print "- " $2 "，" $1 "次"}'
}

view_menu() {
    while true; do
        clear
        echo "===== 查看分析 ====="
        echo "1. 对外端口/服务"
        echo "2. 异常开放检测"
        echo "3. UFW拦截分析"
        echo "4. Fail2Ban封禁分析"
        echo "0. 返回"
        echo

        read -rp "选择：" c
        case "$c" in
            1) show_public_ports; pause ;;
            2) check_abnormal_open_ports; pause ;;
            3) analyze_ufw_logs; pause ;;
            4) analyze_fail2ban_logs; pause ;;
            0) return ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

# ==================================================
# 清理/卸载
# ==================================================

clean_logs() {
    title "清理日志"
    echo "会清空当前UFW/Fail2Ban日志。"

    confirm_yes "清理日志后历史分析会清空" || return

    : > /var/log/fail2ban.log 2>/dev/null || true
    : > /var/log/ufw.log 2>/dev/null || true

    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=7d >/dev/null 2>&1 || true

    systemctl reload fail2ban >/dev/null 2>&1 || true
    systemctl reload rsyslog >/dev/null 2>&1 || true

    ok "日志已清理"
}

uninstall_script_only() {
    title "卸载本脚本"
    echo "不会卸载UFW/Fail2Ban。"
    confirm_yes "确认卸载本脚本？" || return

    rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"

    if [ -f "$CURRENT_SCRIPT" ] && echo "$CURRENT_SCRIPT" | grep -q "^/"; then
        rm -f "$CURRENT_SCRIPT"
    fi

    ok "本脚本已清理"
    exit 0
}

uninstall_ufw() {
    confirm_yes "确认卸载UFW？" || return

    ufw --force disable >/dev/null 2>&1 || true
    apt purge -y ufw
    apt autoremove -y
    rm -rf /etc/ufw "$WRAPPER_UFW"

    ok "UFW已卸载"
}

uninstall_fail2ban() {
    confirm_yes "确认卸载Fail2Ban？" || return

    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    apt purge -y fail2ban
    apt autoremove -y
    rm -rf /etc/fail2ban

    ok "Fail2Ban已卸载"
}

full_cleanup() {
    confirm_yes "确认全部清理？会卸载UFW + Fail2Ban + 本脚本。" || return

    systemctl stop fail2ban >/dev/null 2>&1 || true
    ufw --force disable >/dev/null 2>&1 || true

    apt purge -y fail2ban ufw
    apt autoremove -y

    rm -rf /etc/fail2ban /etc/ufw
    rm -f "$SELF_MENU" "$WRAPPER_UFW" "$LOGROTATE_FILE"
    [ -f "$CURRENT_SCRIPT" ] && rm -f "$CURRENT_SCRIPT" 2>/dev/null || true

    ok "已全部清理"
    exit 0
}

clean_menu() {
    while true; do
        clear
        echo "===== 清理/卸载 ====="
        echo "1. 清理日志"
        echo "2. 卸载本脚本"
        echo "3. 卸载UFW"
        echo "4. 卸载Fail2Ban"
        echo "5. 全部清理"
        echo "0. 返回"
        echo

        read -rp "选择：" c
        case "$c" in
            1) clean_logs; pause ;;
            2) uninstall_script_only ;;
            3) uninstall_ufw; pause ;;
            4) uninstall_fail2ban; pause ;;
            5) full_cleanup ;;
            0) return ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

# ==================================================
# 主菜单
# ==================================================

main_menu() {
    need_root
    install_self_alias
    install_log_limit >/dev/null 2>&1 || true

    while true; do
        clear
        check_tools

        echo "===== UFW-F 最终极简版 ====="
        [ "$UFW_OK" = 1 ] && echo "防火墙：已安装" || echo "防火墙：未安装"
        [ "$F2B_OK" = 1 ] && echo "防爆破：已安装" || echo "防爆破：未安装"
        echo
        echo "1. 状态总览"
        echo "2. 推荐安装"
        echo "3. 防火墙"
        echo "4. 防爆破"
        echo "5. 查看分析"
        echo "6. 清理/卸载"
        echo "0. 退出"
        echo

        read -rp "选择：" c

        case "$c" in
            1) dashboard; pause ;;
            2) recommended_install; pause ;;
            3) ufw_menu ;;
            4) fail2ban_menu ;;
            5) view_menu ;;
            6) clean_menu ;;
            0) exit 0 ;;
            *) warn "无效选择"; pause ;;
        esac
    done
}

main_menu
