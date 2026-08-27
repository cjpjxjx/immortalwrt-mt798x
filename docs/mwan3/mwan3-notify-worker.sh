#!/bin/sh
# Background worker for mwan3-notify.sh - detached via start-stop-daemon, so
# it can wait/retry for minutes without holding up the netifd/mwan3 hotplug
# chain that spawned it (see mwan3-notify.sh's own comment for why).
#
# Args: $1=ACTION ($2=connected|disconnected)  $2=INTERFACE
#
# Only wait/retry stage of its own: repair-lock wait. mwan3-check.sh (see
# its REPAIR_LOCK) can itself restart mwan3 or bounce a member to fix
# "tracking is paused"/missing routes, and that alone can make mwan3track
# re-announce connected/disconnected for a link that never actually went
# down. So before treating this event as real, wait for
# /tmp/mwan3-check.repairing to clear: check now, then up to
# REPAIR_WAIT_RETRIES more times REPAIR_WAIT_INTERVAL apart. If it is still
# there after all checks, mwan3-check's own MAX_ROUNDS repair loop has
# failed to resolve things within that time - push a distinct "repair timed
# out" alert instead of the normal connected/disconnected one, so a real,
# unresolved problem is not swallowed by this de-noising logic.
#
# The push itself (signing, retrying on transient send failure) is handled
# by dingtalk-notify.sh - see that file.
#
# Install to /usr/bin/mwan3-notify-worker.sh on the router.

ACTION="$1"
INTERFACE="$2"

DINGTALK_LIB="/usr/bin/dingtalk-notify.sh"
DINGTALK_LOG_TAG="mwan3-notify"

# Must match mwan3-check.sh's REPAIR_LOCK ($NAME=mwan3-check).
REPAIR_LOCK="/tmp/mwan3-check.repairing"
REPAIR_WAIT_INTERVAL=60
REPAIR_WAIT_RETRIES=2

log() {
	logger -t "mwan3-notify" "$1"
}

# shellcheck disable=SC1091
[ -x "$DINGTALK_LIB" ] || { log "$DINGTALK_LIB missing or not executable, skipping"; exit 0; }
. "$DINGTALK_LIB"

wait_out_repair_lock() {
	local checked=0

	while [ -e "$REPAIR_LOCK" ]; do
		if [ "$checked" -ge "$REPAIR_WAIT_RETRIES" ]; then
			return 1
		fi
		checked=$((checked + 1))
		log "$INTERFACE $ACTION: mwan3-check repair in progress, waiting ${REPAIR_WAIT_INTERVAL}s (check $checked/$REPAIR_WAIT_RETRIES)"
		sleep "$REPAIR_WAIT_INTERVAL"
	done
	return 0
}

case "$ACTION" in
	connected)
		event="${INTERFACE} 恢复"
		detail="线路 ${INTERFACE} 恢复正常。"
		;;
	disconnected)
		event="${INTERFACE} 掉线"
		detail="线路 ${INTERFACE} 已断开，mwan3 正在按策略自动切换。"
		;;
	*)
		exit 0
		;;
esac

if wait_out_repair_lock; then
	dingtalk_notify "$event" "mwan3" "$INTERFACE" "$detail"
else
	dingtalk_notify "${INTERFACE} 修复超时" "mwan3" "$INTERFACE" \
		"mwan3-check 约 $((REPAIR_WAIT_INTERVAL * REPAIR_WAIT_RETRIES / 60)) 分钟内未能解除修复锁，链路可能未真正恢复，请人工检查。"
fi
