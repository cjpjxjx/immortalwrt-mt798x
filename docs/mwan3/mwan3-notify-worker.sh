#!/bin/sh
# Background worker for mwan3-notify.sh - detached via start-stop-daemon, so
# it can wait/retry for minutes without holding up the netifd/mwan3 hotplug
# chain that spawned it (see mwan3-notify.sh's own comment for why).
#
# Args: $1=ACTION ($2=connected|disconnected)  $2=INTERFACE  $3=DEVICE
#
# Two independent wait/retry stages:
#
#   1. Repair-lock wait: mwan3-check.sh (see its REPAIR_LOCK) can itself
#      restart mwan3 or bounce a member to fix "tracking is paused"/missing
#      routes, and that alone can make mwan3track re-announce
#      connected/disconnected for a link that never actually went down. So
#      before treating this event as real, wait for /tmp/mwan3-check.repairing
#      to clear: check now, then up to REPAIR_WAIT_RETRIES more times
#      REPAIR_WAIT_INTERVAL apart. If it is still there after all checks,
#      mwan3-check's own MAX_ROUNDS repair loop has failed to resolve things
#      within that time - send a distinct "repair timed out" alert instead
#      of the normal connected/disconnected one, so a real, unresolved
#      problem is not swallowed by this de-noising logic.
#
#   2. Send retry: a link transition is often accompanied by exactly the
#      network instability that would make an SMTP send itself fail (the
#      failover this is reporting may still be settling). Retry msmtp on
#      failure, SEND_RETRY_INTERVAL apart, up to SEND_RETRY_COUNT times.
#
# Install to /usr/bin/mwan3-notify-worker.sh on the router.

ACTION="$1"
INTERFACE="$2"
DEVICE="$3"

CONF_DIR="/etc/mwan3-notify"
MSMTPRC="$CONF_DIR/msmtprc"
MAIL_TO_FILE="$CONF_DIR/mail_to"

# Must match mwan3-check.sh's REPAIR_LOCK ($NAME=mwan3-check).
REPAIR_LOCK="/tmp/mwan3-check.repairing"
REPAIR_WAIT_INTERVAL=60
REPAIR_WAIT_RETRIES=2

SEND_RETRY_INTERVAL=10
SEND_RETRY_COUNT=5

log() {
	logger -t "mwan3-notify" "$1"
}

send_mail() {
	local subject="$1" extra_body="$2"
	local mail_to hostname ts attempt=0

	mail_to=$(cat "$MAIL_TO_FILE")
	hostname=$(uci -q get system.@system[0].hostname)
	[ -n "$hostname" ] || hostname="RAX3000M"
	ts=$(date "+%Y-%m-%d %H:%M:%S")

	while :; do
		if {
			echo "To: $mail_to"
			echo "Subject: [mwan3] $hostname - $subject"
			echo "Content-Type: text/plain; charset=utf-8"
			echo ""
			echo "接口: $INTERFACE"
			echo "设备: $DEVICE"
			echo "事件: $ACTION"
			echo "时间: $ts"
			[ -n "$extra_body" ] && { echo ""; echo "$extra_body"; }
			echo ""
			mwan3 status 2>/dev/null
		} | msmtp -C "$MSMTPRC" -a default "$mail_to"; then
			log "$INTERFACE $ACTION: mail sent to $mail_to (subject: $subject, attempt $((attempt + 1)))"
			return 0
		fi

		attempt=$((attempt + 1))
		if [ "$attempt" -gt "$SEND_RETRY_COUNT" ]; then
			log "$INTERFACE $ACTION: mail send FAILED after $attempt attempts (subject: $subject), giving up"
			return 1
		fi
		log "$INTERFACE $ACTION: mail send failed, retry $attempt/$SEND_RETRY_COUNT in ${SEND_RETRY_INTERVAL}s"
		sleep "$SEND_RETRY_INTERVAL"
	done
}

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
		state="恢复"
		;;
	disconnected)
		state="掉线"
		;;
	*)
		exit 0
		;;
esac

if wait_out_repair_lock; then
	send_mail "$INTERFACE $state" ""
else
	send_mail "$INTERFACE 看门狗修复超时" \
		"mwan3-check 在约 $((REPAIR_WAIT_INTERVAL * REPAIR_WAIT_RETRIES / 60)) 分钟内未能解除修复锁，链路问题可能未被自动修复，请人工检查。"
fi
