#!/bin/sh
# Shared DingTalk custom-robot webhook push helper. Sourced (not executed
# directly) by mwan3-notify-worker.sh and cpe-usb-watchdog so the HMAC-SHA256
# signing ("加签"), JSON escaping, retry logic and message layout exist in
# exactly one place - every producer's push looks the same regardless of
# which script sent it.
#
# Provides:
#   dingtalk_notify "<event>" "<source>" "<iface>" "<detail>"
#     - The entry point every producer should use. Title is always
#       "<设备型号> - <event>", used for the chat/notification list preview.
#       DingTalk's markdown msgtype only renders the "text" field inside the
#       message bubble itself (the title never appears there), so the same
#       "<设备型号> - <event>" heading is repeated at the top of the body
#       (as a level-3 "### " markdown heading - DingTalk renders that bold;
#       level 4+ headings render as plain, non-bold text), followed by a
#       fixed 来源/接口/时间/详情 skeleton. <event> should be a short label
#       ("test5g 恢复", "CPE 假死"), <detail> one short plain sentence - what
#       happened and the outcome/action taken, no parenthetical asides.
#
#   dingtalk_push "<title>" "<markdown body>"
#     - Lower-level primitive dingtalk_notify is built on; only call this
#       directly for a push that doesn't fit the standard skeleton.
#     - Returns 0 once DingTalk confirms delivery ("errcode":0 in the
#       response).
#     - Returns 1 if curl/openssl are missing,
#       /etc/mwan3-notify/dingtalk.conf is missing or incomplete, or all
#       retries are exhausted - callers don't need their own
#       dependency/config checks before calling.
#     - Retries DINGTALK_RETRY_COUNT times, DINGTALK_RETRY_INTERVAL apart, on
#       failure (a link transition is often accompanied by exactly the
#       network instability that would make the push itself fail
#       transiently).
#
# Callers should set DINGTALK_LOG_TAG before calling dingtalk_push (used as
# the `logger -t` tag); it defaults to "dingtalk-notify" if unset.
#
# Install to /usr/bin/dingtalk-notify.sh on the router.

DINGTALK_CONF="${DINGTALK_CONF:-/etc/mwan3-notify/dingtalk.conf}"
DINGTALK_WEBHOOK_BASE="https://oapi.dingtalk.com/robot/send"
DINGTALK_CURL_TIMEOUT=10
DINGTALK_RETRY_INTERVAL=10
DINGTALK_RETRY_COUNT=5
# This repo only ever builds for one device (see CLAUDE.md) - a fixed label
# is simpler and more predictable than uci's mutable system.hostname, which
# defaults to "OpenWrt" and is easy to leave unrenamed.
DINGTALK_DEVICE="RAX3000M"

_dingtalk_log() {
	logger -t "${DINGTALK_LOG_TAG:-dingtalk-notify}" "$1"
}

_dingtalk_body() {
	local title="$1" source="$2" iface="$3" detail="$4" ts

	ts=$(date "+%Y-%m-%d %H:%M:%S")
	printf '### %s\n\n- **来源**: %s\n- **接口**: %s\n- **时间**: %s\n- **详情**: %s' \
		"$title" "$source" "$iface" "$ts" "$detail"
}

dingtalk_notify() {
	local event="$1" source="$2" iface="$3" detail="$4" title

	title="${DINGTALK_DEVICE} - ${event}"
	dingtalk_push "$title" "$(_dingtalk_body "$title" "$source" "$iface" "$detail")"
}

# DingTalk's "加签" (signature) security setting: sign =
# base64(hmac_sha256(secret, "<timestamp-ms>\n<secret>")), urlencoded into
# the sign query param. See
# https://open.dingtalk.com/document/robots/customize-robot-security-settings
#
# Base64's alphabet only ever produces '+', '/', '=' as characters that need
# escaping in a query string, so a full urlencode implementation isn't
# needed - sed covers it.
_dingtalk_sign() {
	local timestamp="$1" secret="$2" sign

	sign=$(printf '%s\n%s' "$timestamp" "$secret" \
		| openssl dgst -sha256 -hmac "$secret" -binary \
		| openssl base64 \
		| tr -d '\n')
	printf '%s' "$sign" | sed -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# Escapes a string for embedding inside a JSON string value: backslash and
# quotes first (order matters), then the literal newlines that come from a
# multi-line body joined into one JSON string.
_dingtalk_json_escape() {
	sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/\\n/g'
}

dingtalk_push() {
	local title="$1" body="$2"
	local title_escaped body_escaped json timestamp sign url resp attempt=0

	[ -x /usr/bin/curl ] || { _dingtalk_log "curl not installed, skipping push"; return 1; }
	[ -x /usr/bin/openssl ] || { _dingtalk_log "openssl not installed, skipping push"; return 1; }
	[ -f "$DINGTALK_CONF" ] || { _dingtalk_log "$DINGTALK_CONF missing, skipping push"; return 1; }

	# shellcheck disable=SC1090
	. "$DINGTALK_CONF"
	if [ -z "$ACCESS_TOKEN" ] || [ -z "$SECRET" ]; then
		_dingtalk_log "$DINGTALK_CONF missing ACCESS_TOKEN/SECRET, skipping push"
		return 1
	fi

	title_escaped=$(printf '%s' "$title" | _dingtalk_json_escape)
	body_escaped=$(printf '%s' "$body" | _dingtalk_json_escape)
	json="{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"${title_escaped}\",\"text\":\"${body_escaped}\"},\"at\":{\"isAtAll\":false}}"

	while :; do
		timestamp=$(( $(date +%s) * 1000 ))
		sign=$(_dingtalk_sign "$timestamp" "$SECRET")
		url="${DINGTALK_WEBHOOK_BASE}?access_token=${ACCESS_TOKEN}&timestamp=${timestamp}&sign=${sign}"

		if resp=$(curl -sS -m "$DINGTALK_CURL_TIMEOUT" -H 'Content-Type: application/json' -d "$json" "$url" 2>&1) \
			&& printf '%s' "$resp" | grep -q '"errcode"[[:space:]]*:[[:space:]]*0'; then
			_dingtalk_log "push sent (title: $title, attempt $((attempt + 1)))"
			return 0
		fi

		attempt=$((attempt + 1))
		if [ "$attempt" -gt "$DINGTALK_RETRY_COUNT" ]; then
			_dingtalk_log "push FAILED after $attempt attempts (title: $title, resp: $resp), giving up"
			return 1
		fi
		_dingtalk_log "push failed (resp: $resp), retry $attempt/$DINGTALK_RETRY_COUNT in ${DINGTALK_RETRY_INTERVAL}s"
		sleep "$DINGTALK_RETRY_INTERVAL"
	done
}
