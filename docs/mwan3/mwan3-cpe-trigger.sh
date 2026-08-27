#!/bin/sh
# Event-driven entry point for cpe-usb-watchdog - hooked from /etc/mwan3.user
# alongside mwan3-notify.sh.
#
# Why: the watchdog is otherwise driven by cron every 5 minutes, so a CPE
# gadget hang can go unnoticed for that long. mwan3's own tracker already
# notices within ~15s and reports cpe5g disconnected, so that event is a free
# hint that the link may have hung again - run the watchdog right then instead
# of waiting for the timer. The cron entry stays: it is what retries a repair
# that did not take, what confirms recovery after a CPE reboot, and what still
# runs when mwan3's tracker is itself wedged and never emits an event at all.
#
# Kept separate from mwan3-notify.sh on purpose: that script exits early when
# curl/openssl/dingtalk.conf are missing, which would silently disable the
# repair trigger too. Alerting is optional here, repairing is not.
#
# Nothing here decides whether the CPE is actually faulty - cpe-usb-watchdog's
# own entry checks do, and they already cover everything an event-driven run
# adds: a link that is down at the netifd level, a router-side interface
# problem that belongs to mwan3-check, a CPE still booting from a previous
# repair, and a cron run already in progress (its mkdir lock decides that race
# atomically, and MAX_RUNTIME is below the cron interval).
#
# Like mwan3-notify.sh this runs synchronously inside the netifd/mwan3track
# hotplug chain while procd_lock is held, so it must return immediately. A
# plain "&" would not do: the backgrounded child inherits the lock fd and would
# hold it for the length of a repair. start-stop-daemon -b closes the extra
# descriptors when it daemonizes. Its -x must name the interpreter, not the
# script (see docs/rax3000m-mwan3-failover.md sections 7.1 and 7.2).
#
# Install to /usr/bin/mwan3-cpe-trigger.sh on the router.

WATCHDOG="/usr/bin/cpe-usb-watchdog"
IFACE="cpe5g"

# Matches the cron cadence. The event path exists to cut detection latency,
# not to run the watchdog more often than the timer does: a flapping link
# emits "disconnected" repeatedly, and the soft reset - unlike the CPE reboot
# - has no rate limit of its own.
COOLDOWN=300
STAMP="/tmp/cpe-usb-watchdog.last-trigger"
PIDFILE="/tmp/cpe-usb-watchdog.trigger.pid"

log() {
	logger -t "mwan3-cpe-trigger" "$1"
}

[ "$ACTION" = "disconnected" ] || exit 0
[ "$INTERFACE" = "$IFACE" ] || exit 0
[ -x "$WATCHDOG" ] || { log "$WATCHDOG missing or not executable, skipping"; exit 0; }

last=$(awk '{ print $1; exit }' "$STAMP" 2>/dev/null)
case "$last" in
	''|*[!0-9]*) last=0 ;;
esac
now=$(date +%s)
if [ "$last" != 0 ] && [ $((now - last)) -lt "$COOLDOWN" ]; then
	log "$IFACE disconnected, but a run was triggered $((now - last))s ago, leaving this one to cron"
	exit 0
fi

if start-stop-daemon -S -b -m -p "$PIDFILE" -x /bin/sh -- "$WATCHDOG"; then
	date '+%s %Y-%m-%dT%H:%M:%S' > "$STAMP"
	log "$IFACE disconnected, cpe-usb-watchdog started"
else
	log "$IFACE disconnected, a triggered watchdog run is still active, event dropped"
fi
