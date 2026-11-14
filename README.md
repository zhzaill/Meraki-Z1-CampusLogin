# 校园网 Portal 自动登录（OpenWrt / Dr.COM）

在 OpenWrt 路由器上通过 5GHz STA 连接校园无线，自动完成 Dr.COM Portal 认证，为 LAN 设备提供共享上网。

## 拓扑

```text
校园无线 <CAMPUS_SSID> (5GHz)
        |
  wlan0 STA (DHCP)
        |
  OpenWrt NAT / 防火墙
        |
  <LAN_IP>/24 + 2.4GHz AP <AP_SSID>
        |
  PC / 手机 / 服务器
```

校园侧通常只允许单设备在线，因此由路由器统一完成认证，LAN 内设备共享。

## 认证流程

```text
POST http://<PORTAL_IP>:801/eportal/?c=ACSetting&a=Login&protocol=http:&hostname=<PORTAL_IP>&iTermType=1&wlanuserip=<IP>&wlanacip=<AC_IP>&mac=00-00-00-00-00-00&ip=<IP>&enAdvert=0&queryACIP=0&loginMethod=1
Referer: http://<PORTAL_IP>/
Content-Type: application/x-www-form-urlencoded
```

表单字段：`DDDDD`（账号）、`upass`（密码）、`R1`、`R2`、`R3`、`R6`、`para`、`0MKKey`、`buttonClicked`、`redirect_url`、`err_flag`、`username`、`password`、`user`、`cmd`、`Login`。

成功判定：返回 `302` 且 `Location` 指向 `/3.htm`。`ErrorMsg=512` 或 `inuse` 时 12 秒后重试一次，其余拒绝不再重试。

## 运行逻辑（`campus-login.sh`，cron 每分钟）

1. 取 `wlan0` 地址与默认路由；没有则进入自愈阶梯：第 2、12 次连续失败重启 `wwan`，第 6、20、40 次重载无线。
2. 多目标探测（`generate_204`、百度、QQ、搜狐），连续 2 次失败才判定离线。
3. 登录前预检 Portal 可达性；不可达只记录，不提交账号密码。
4. 门户根页若为注销页（`Dr.COMWebLoginID_1.htm`），说明 AC 认为已在线：写 `auth-ok` 并跳过 POST。
5. POST 节流 300 秒，单次流程最多 2 次；成功后在线期间保持静默。

状态、日志、标记全部位于 `/tmp`，重启清空。

## 辅助组件

- `deploy/etc/nettask/wlan-watchdog.sh`：每 2 分钟检查关联；连续未关联时在内存中清除 BSSID 钉定并重载射频，交回自动漫游，不写 flash。
- `dns/`：dnsmasq → DNSCrypt（`127.0.0.1:5353`）加密解析，强制域名清单绕开污染，国内 DNS 兜底。

## 部署

1. 复制 `campus.conf.example` 为 `/etc/nettask/campus.conf`，填入账号、密码、Portal 地址。
2. 上传 `campus-login.sh` 与 `wlan-watchdog.sh` 到 `/etc/nettask/`，`chmod 755`。
3. crontab：

```cron
* * * * * /etc/nettask/campus-login.sh >/dev/null 2>&1
*/2 * * * * /etc/nettask/wlan-watchdog.sh >/dev/null 2>&1
```

## 配置项

| 变量 | 说明 |
|---|---|
| `IFACE` | 上联接口，默认 `wlan0` |
| `ACIP` | 校园 AC 地址 |
| `PORTAL_HOST` / `PORTAL_URL` | Portal 地址 |
| `USERNAME` / `PASSWORD` | 校园账号与密码 |
| `PROBE_URLS` | 在线探测目标 |
| `PORTAL_TIMEOUT` / `PROBE_TIMEOUT` | 超时（秒） |
| `LOGIN_RETRY_DELAY` / `LOGIN_THROTTLE` | 重试间隔 / 节流 |
| `OFFLINE_STREAK` | 判定离线所需的连续失败次数 |

## 状态检查

```sh
iw dev wlan0 link
ip -4 addr show wlan0
cat /tmp/campus-login.status
tail -50 /tmp/campus-login.log
cat /tmp/wlan-watchdog.miss 2>/dev/null
crontab -l
logread | grep campus-login
```

## 注意

- 凭据只保存在设备的 `campus.conf`，不进入仓库。
- 老设备 NAND 磨损明显，日常运维优先使用 runtime 修改（`uci set` 不 `commit`），避免频繁写 flash。
- 校园侧偶发短时中断属外部因素，脚本会在恢复后自动确认认证。
