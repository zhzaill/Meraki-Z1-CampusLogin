#!/bin/sh
# wlan0 链路看门狗（无 flash 写入版，2026-11-10）
# 钉定的校园 AP 连续 2 次未关联时，只在内存里删除 bssid 并重载 radio0，交回自动漫游；
# 不执行 uci commit，避免在磨损 NAND 上反复写。重启后仍按 /etc/config 的钉定值启动。
STATE=/tmp/wlan-watchdog.miss
COOLDOWN=/tmp/wlan-watchdog.last

if iw dev wlan0 link 2>/dev/null | grep -q '^Connected to'; then
    rm -f "$STATE"
    exit 0
fi

n="$(cat "$STATE" 2>/dev/null || echo 0)"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
echo "$n" > "$STATE"
logger -t wlan-watchdog "wlan0 unassociated miss=$n"

[ "$n" -ge 2 ] || exit 0

now="$(date +%s)"
last="$(cat "$COOLDOWN" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $((now - last)) -lt 600 ]; then
    logger -t wlan-watchdog "recovery cooldown active; no action"
    rm -f "$STATE"
    exit 0
fi
echo "$now" > "$COOLDOWN"
rm -f "$STATE"

if [ -n "$(uci -q get wireless.sta_radio0.bssid)" ]; then
    logger -t wlan-watchdog "clearing BSSID pin at runtime (no flash write); auto roam"
    uci -q delete wireless.sta_radio0.bssid
else
    logger -t wlan-watchdog "no BSSID pin; forcing radio0 reload"
fi
wifi reload radio0

exit 0
