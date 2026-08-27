#!/bin/sh
# mwan3 link up/down DingTalk alert entry point for RAX3000M - hooked from
# /etc/mwan3.user, called synchronously inside the netifd/mwan3track hotplug
# chain (which holds procd_lock - see /etc/hotplug.d/iface/16-mwan3-user), so
# this must return fast.
#
# All the slow parts - waiting out a possible mwan3-check repair in
# progress, and retrying the webhook push on transient failures during the
# very network instability a failover itself causes - run in a detached
# background worker (mwan3-notify-worker.sh) started via start-stop-daemon,
# not inline here.
#
# Silently does nothing if the DingTalk webhook is not configured yet or
# curl/openssl aren't installed, so deploying this script ahead of
# configuring credentials is harmless. See docs/rax3000m-mwan3-failover.md
# section 7.
#
# Install to /usr/bin/mwan3-notify.sh on the router.

CONF_DIR="/etc/mwan3-notify"
DINGTALK_CONF="$CONF_DIR/dingtalk.conf"
DINGTALK_LIB="/usr/bin/dingtalk-notify.sh"
WORKER="/usr/bin/mwan3-notify-worker.sh"

log() {
	logger -t "mwan3-notify" "$1"
}

case "$ACTION" in
	connected|disconnected) ;;
	*) exit 0 ;;
esac

[ -x /usr/bin/curl ] || { log "curl not installed, skipping"; exit 0; }
[ -x /usr/bin/openssl ] || { log "openssl not installed, skipping"; exit 0; }
[ -f "$DINGTALK_LIB" ] || { log "$DINGTALK_LIB missing, skipping"; exit 0; }
[ -f "$DINGTALK_CONF" ] || { log "not configured ($DINGTALK_CONF missing), skipping"; exit 0; }
[ -x "$WORKER" ] || { log "$WORKER missing or not executable, skipping"; exit 0; }

# One worker per interface at a time: a second event for the same interface
# arriving while a worker is still waiting out a repair lock or retrying a
# push would otherwise race it over the same repair-lock check. If that
# happens the newer event is dropped rather than queued - acceptable here
# since mwan3's own down=3/up=3 confirmation (~15s) already filters out
# rapid flapping before it reaches this hook.
#
# BusyBox start-stop-daemon's -x matches argv[0] in /proc/PID/cmdline, which
# for a shell script is the interpreter (/bin/sh), not the script path - so
# -x must name the interpreter, with the script passed as the first -- arg.
# Using the script path as -x (matching nothing) was verified to silently
# defeat dedup: two events would both start a worker.
PIDFILE="/tmp/mwan3-notify.${INTERFACE}.pid"

start-stop-daemon -S -b -m -p "$PIDFILE" -x /bin/sh -- "$WORKER" "$ACTION" "$INTERFACE" \
	&& log "$INTERFACE $ACTION, worker started" \
	|| log "$INTERFACE $ACTION, worker already running for this interface, event dropped"
