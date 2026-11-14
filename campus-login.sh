#!/bin/sh
set -u

BASE_DIR=/etc/nettask
CONF="$BASE_DIR/campus.conf"
[ -f "$CONF" ] && . "$CONF"

: "${IFACE:=wlan0}"
: "${ACIP:=10.10.9.200}"
: "${PORTAL_HOST:=1.1.1.1}"
: "${PORTAL_URL:=http://1.1.1.1/}"
: "${USERNAME:=}"
: "${PASSWORD:=}"
# 多目标探测（任意一个通过即视为在线）
: "${PROBE_URLS:=http://connect.rom.miui.com/generate_204 http://www.baidu.com/ http://www.qq.com/ http://www.sohu.com/}"
# Direct portal checks are used before a login POST so DNS or upstream
# failures are not misreported as bad credentials. The portal is slow at
# times; 4s produced false "unreachable" readings under load.
: "${PORTAL_TIMEOUT:=8}"
# Per-URL timeout for the online probe (generate_204 / baidu / qq / sohu).
: "${PROBE_TIMEOUT:=6}"
# Dr.COM may need several seconds to clear an old session before the next
# POST succeeds; the HAR showed an 11-second gap between attempts.
: "${LOGIN_RETRY_DELAY:=12}"
# 两次登录尝试的最小间隔（秒），防止高频登录被认证系统限流/踢会话
: "${LOGIN_THROTTLE:=300}"
# 连续探测失败多少次才判定真断线（防抖）
: "${OFFLINE_STREAK:=2}"

LOG=/tmp/campus-login.log
STATUS=/tmp/campus-login.status
LOCK=/tmp/campus-login.lock
NOIP_STRIKES=/tmp/campus-login.noip-strikes
BOOT_MARK=/tmp/campus-login.boot-marked
# Keep runtime history off NAND by default; override PERSIST_LOG in campus.conf
# only when a persistent copy is explicitly required.
: "${PERSIST_LOG:=/tmp/nettask-boot-history.log}"
LASTTRY=/tmp/campus-login.lasttry
STREAK=/tmp/campus-login.streak
OFFLINE_SINCE=/tmp/campus-login.offline-since
PORTAL_HEADERS=/tmp/campus-portal.headers
AUTH_OK=/tmp/campus-login.auth-ok

LOGIN_URL="http://${PORTAL_HOST}:801/eportal/?c=ACSetting&a=Login&protocol=http:&hostname=${PORTAL_HOST}&iTermType=1"

log() {
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg" >> "$LOG"
    logger -t campus-login "$*"
}

trim_log() {
    f="$LOG"
    if [ -f "$f" ] && [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 400 ]; then
        tail -n 200 "$f" > "$f.trim"
        mv "$f.trim" "$f"
    fi
}
trim_log

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

get_ip() {
    ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

uptime_secs() {
    cut -d. -f1 /proc/uptime
}

persist_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$PERSIST_LOG"
    if [ "$(wc -l < "$PERSIST_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
        tail -n 150 "$PERSIST_LOG" > /tmp/boot-history.trim
        mv /tmp/boot-history.trim "$PERSIST_LOG"
    fi
}

record_boot_once() {
    [ -e "$BOOT_MARK" ] && return
    persist_event "boot ip=${IP:-none} uptime=$(uptime_secs)s"
    touch "$BOOT_MARK"
}

recover_uplink() {
    reason="$1"
    strikes="$(cat "$NOIP_STRIKES" 2>/dev/null || echo 0)"
    up="$(uptime_secs)"
    if [ "$up" -lt 120 ]; then
        echo 0 > "$NOIP_STRIKES"
        log "$reason; boot grace (${up}s), waiting"
        return 0
    fi
    strikes=$((strikes + 1))
    echo "$strikes" > "$NOIP_STRIKES"
    log "$reason; recovery strike=$strikes"
    case "$strikes" in
        2|12)
            log "recovery: restarting wwan interface"
            persist_event "recovery: restart wwan, reason=$reason"
            ubus call network.interface.wwan down
            sleep 2
            ubus call network.interface.wwan up
            ;;
        6|20|40)
            log "recovery: reloading wireless radios"
            persist_event "recovery: reload wifi, reason=$reason"
            wifi reload
            ;;
    esac
}

# 在线判定：多目标 HTTP 探测，排除校园网 Portal 劫持响应
is_online() {
    for url in $PROBE_URLS; do
        resp="$(wget -S -O /tmp/.campus-probe --timeout="$PROBE_TIMEOUT" --tries=1 --max-redirect=0 "$url" 2>&1)"
        echo "$resp" | grep -qiE 'HTTP/[0-9.]+ 204' && return 0
        echo "$resp" | grep -qE 'HTTP/[0-9.]+ 200' || continue
        echo "$resp" | grep -qi 'DrcomServer' && continue
        echo "$resp" | grep -qi 'eportal' && continue
        [ -s /tmp/.campus-probe ] && return 0
    done
    return 1
}

# Return success when the portal itself answers. A portal response may be a
# 200 page or a redirect; both prove that the gateway path is reachable.
portal_reachable() {
    for url in "$PORTAL_URL" "${PORTAL_URL}a70.htm" "http://${PORTAL_HOST}:801/eportal/"; do
        resp="$(wget -S -O /tmp/.campus-portal --timeout="$PORTAL_TIMEOUT" --tries=1 "$url" 2>&1)"
        printf '%s\n' "$resp" > "$PORTAL_HEADERS"
        echo "$resp" | grep -qE 'HTTP/[0-9.]+ [234][0-9][0-9]' && return 0
    done
    return 1
}

portal_failure_reason() {
    echo "$1" | grep -qiE 'timed out|timeout|host is unreachable|network is unreachable|failed:' && echo unreachable && return
    echo "$1" | grep -qiE 'HTTP/[0-9.]+ ' && echo response && return
    echo transport-error
}

# Portal 根页为注销页时，说明 AC 已把本 IP 视为在线。Dr.COM 对已在线 IP 的
# 登录请求只会返回 512/inuse，重复提交还可能扰动现有会话，因此直接认定已认证。
portal_authenticated() {
    wget -q -O /tmp/.campus-portal --timeout="$PORTAL_TIMEOUT" --tries=1 --max-redirect=0 "$PORTAL_URL" 2>/dev/null
    grep -qi 'Dr\.COMWebLoginID_1\.htm' /tmp/.campus-portal 2>/dev/null
}

now_epoch() { date +%s; }

IP="$(get_ip)"
record_boot_once

if [ -z "$IP" ]; then
    recover_uplink "no IPv4 on $IFACE"
    exit 1
fi

if ! ip route | grep -q "^default .* dev $IFACE"; then
    recover_uplink "default route is not via $IFACE"
    exit 0
fi

rm -f "$NOIP_STRIKES"

# 记录本次是否由在线分支进入，供后续状态文案区分。
ONLINE=0

if is_online; then
    ONLINE=1
    rm -f "$STREAK"
    if [ -f "$AUTH_OK" ]; then
        if [ -f "$OFFLINE_SINCE" ]; then
            since="$(cat "$OFFLINE_SINCE" 2>/dev/null || echo 0)"
            dur=$(( $(now_epoch) - since ))
            persist_event "internet restored after ${dur}s probe outage, ip=$IP"
            log "internet restored after ${dur}s probe outage ip=$IP"
            rm -f "$OFFLINE_SINCE"
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') portal-authenticated internet-reachable ip=$IP" > "$STATUS"
        exit 0
    fi
    # 门户根页是注销页时直接认定已认证，避免对已在线 IP 重复 POST。
    if portal_authenticated; then
        touch "$AUTH_OK"
        log "portal reports authenticated (logout page) ip=$IP"
        echo "$(date '+%Y-%m-%d %H:%M:%S') portal-authenticated internet-reachable ip=$IP" > "$STATUS"
        exit 0
    fi
    log "internet probe passed but Portal authentication is unconfirmed; continuing login flow ip=$IP"
    streak="$OFFLINE_STREAK"
else
    # Probe failures are debounced; a reachable whitelist endpoint alone never
    # suppresses the first Portal login attempt after boot.
    streak="$(cat "$STREAK" 2>/dev/null || echo 0)"
    case "$streak" in ''|*[!0-9]*) streak=0 ;; esac
    streak=$((streak + 1))
    [ "$streak" -gt 999 ] && streak=999
    echo "$streak" > "$STREAK"

    if [ ! -f "$OFFLINE_SINCE" ]; then
        now_epoch > "$OFFLINE_SINCE"
        persist_event "internet probe outage ip=$IP"
        log "internet probe outage ip=$IP"
    fi

    if [ "$streak" -lt "$OFFLINE_STREAK" ]; then
        log "probe failed streak=$streak, waiting before login"
        echo "$(date '+%Y-%m-%d %H:%M:%S') probe-fail ip=$IP streak=$streak" > "$STATUS"
        exit 0
    fi
fi

# Do not send credentials when the gateway cannot reach the Portal at all.
# This prevents repeated POSTs during an upstream/AP outage and preserves a
# useful distinction in the status and log.
if ! portal_reachable; then
    reason="$(portal_failure_reason "$(cat "$PORTAL_HEADERS" 2>/dev/null)")"
    log "portal unreachable reason=$reason ip=$IP; login POST skipped"
    echo "$(date '+%Y-%m-%d %H:%M:%S') portal-unreachable ip=$IP reason=$reason" > "$STATUS"
    exit 1
fi

# 已在线（注销页）时不提交登录；上游探测失败只记录，等待探测恢复。
if portal_authenticated; then
    touch "$AUTH_OK"
    log "portal reports authenticated (logout page); login POST skipped ip=$IP"
    if [ "$ONLINE" = 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') portal-authenticated internet-reachable ip=$IP" > "$STATUS"
        exit 0
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') portal-authenticated upstream-probe-failing ip=$IP" > "$STATUS"
    exit 1
fi

# 登录节流：避免每分钟重复登录触发认证系统保护
now="$(now_epoch)"
last="$(cat "$LASTTRY" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $((now - last)) -lt "$LOGIN_THROTTLE" ]; then
    log "login throttled (last try $((now - last))s ago), streak=$streak"
    echo "$(date '+%Y-%m-%d %H:%M:%S') offline ip=$IP throttled" > "$STATUS"
    exit 1
fi
now_epoch > "$LASTTRY"

USER_ENC="$(printf '%s' "$USERNAME" | sed 's/,/%2C/g; s/@/%40/g')"
COOKIE_USER="$(printf '%s' "$USERNAME" | sed 's/,/%2C/g')"
COOKIE_VALUE="program=NEW; vlan=0; ssid=null; areaID=null; ISP_select=@telecom; md5_login2=${COOKIE_USER}%7C${PASSWORD}; ip=${IP}"

attempt=1
while [ "$attempt" -le 2 ]; do
    IP="$(get_ip)"
    if [ -z "$IP" ]; then
        log "lost IPv4 before login"
        exit 1
    fi
    URL="${LOGIN_URL}&wlanuserip=${IP}&wlanacip=${ACIP}&mac=00-00-00-00-00-00&ip=${IP}&enAdvert=0&queryACIP=0&loginMethod=1"
    BODY="DDDDD=${USER_ENC}&upass=${PASSWORD}&R1=0&R2=0&R3=0&R6=0&para=00&0MKKey=123456&buttonClicked=&redirect_url=&err_flag=&username=&password=&user=&cmd=&Login="
    RESP="$(wget -S -O /tmp/campus-login.out --timeout=8 --tries=1 --max-redirect=0 \
        --user-agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36' \
        --referer="$PORTAL_URL" \
        --header='Origin: http://1.1.1.1' \
        --header='Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
        --header='Accept-Language: zh-CN,zh;q=0.9' \
        --header='Upgrade-Insecure-Requests: 1' \
        --header="Cookie: ${COOKIE_VALUE}" \
        --header='Content-Type: application/x-www-form-urlencoded' \
        --post-data="$BODY" "$URL" 2>&1)"
    printf '%s\n' "$RESP" > "$PORTAL_HEADERS"

    LOCATION="$(echo "$RESP" | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tail -n 1 | tr -d '\r')"
    if echo "$RESP" | grep -qiE 'HTTP/[0-9.]+ 302' && echo "$LOCATION" | grep -qiE '^http://1\.1\.1\.1(:80)?/3\.htm([?]|$)'; then
        log "login OK ip=$IP"
        touch "$AUTH_OK"
        echo "$(date '+%Y-%m-%d %H:%M:%S') login-ok ip=$IP" > "$STATUS"
        rm -f "$STREAK"
        exit 0
    fi
    if echo "$LOCATION" | grep -qi 'ErrorMsg=aW51c2UsIGxvZ2luIGFnYWlu'; then
        log "login failed: inuse, another session active ip=$IP"
    elif echo "$LOCATION" | grep -qi 'ErrorMsg=NTEy'; then
        log "login deferred: Portal/RADIUS status pending (512) ip=$IP"
    elif echo "$RESP" | grep -qiE 'timed out|timeout|host is unreachable|network is unreachable|failed:'; then
        log "login transport failure reason=$(portal_failure_reason "$RESP") ip=$IP"
    else
        log "login response rejected status=$(echo "$RESP" | grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | tail -n 1) location=$(echo "$RESP" | grep -i 'location:' | tail -n 1) ip=$IP"
    fi

    if [ "$attempt" -lt 2 ]; then
        if echo "$LOCATION" | grep -qiE 'ErrorMsg=(aW51c2UsIGxvZ2luIGFnYWlu|NTEy)'; then
            log "retrying Portal login after ${LOGIN_RETRY_DELAY}s; previous Location=$LOCATION"
            sleep "$LOGIN_RETRY_DELAY"
        else
            log "Portal did not return a retryable inuse/512 response; stopping retries"
            break
        fi
    fi
    attempt=$((attempt + 1))
done

if is_online; then
    log "external probe passed but Portal did not confirm authentication; last Location=$LOCATION ip=$IP"
    echo "$(date '+%Y-%m-%d %H:%M:%S') portal-unconfirmed ip=$IP" > "$STATUS"
else
    log "still offline after Portal login attempts; last Location=$LOCATION ip=$IP"
    echo "$(date '+%Y-%m-%d %H:%M:%S') offline ip=$IP" > "$STATUS"
fi
exit 1
