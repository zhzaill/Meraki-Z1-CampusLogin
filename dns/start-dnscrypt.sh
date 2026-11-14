#!/bin/sh

BASE=/etc/nettask/dns
LOG=/tmp/dnscrypt-proxy.log
PID=/tmp/dnscrypt-proxy.pid
CONF="$BASE/dnscrypt-proxy.toml"

if [ -s "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    exit 0
fi

SSL_CERT_FILE="$BASE/ca/ca-certificates.crt" \
    "$BASE/bin/dnscrypt-proxy" -config "$CONF" \
    -pidfile "$PID" -logfile "$LOG" >/dev/null 2>&1