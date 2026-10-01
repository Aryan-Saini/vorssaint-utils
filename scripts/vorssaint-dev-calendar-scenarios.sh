#!/usr/bin/env bash
#
# vorssaint-dev-calendar-scenarios.sh — fill a throwaway "Vorssaint Test" calendar with
# events timed from now, to try the island's multi-event countdown and Join button by hand.
#
#   vorssaint-dev-calendar-scenarios.sh overlap     two meetings at the same time (Zoom + Meet)
#   vorssaint-dev-calendar-scenarios.sh staggered   one soon, one 12 min later (Webex + Slack)
#   vorssaint-dev-calendar-scenarios.sh join        one Teams call in 7 min: island opens at T-5
#   vorssaint-dev-calendar-scenarios.sh ongoing     one under way, one starting soon (Meet + Discord)
#   vorssaint-dev-calendar-scenarios.sh platforms   every supported service at once (stress test)
#   vorssaint-dev-calendar-scenarios.sh clean       delete the "Vorssaint Test" calendar
#
# Each run clears the calendar first, so scenarios never pile up. Goes through Calendar.app
# with AppleScript (asks for Automation access once). The calendar lands in Calendar's
# default account, so with iCloud it syncs to the phone until `clean`. No alarms are set.
#
# Vorssaint DEV needs Settings > Island > Calendar > Event countdown on (or the events
# chosen from their menu), and "Time left in current event" on for `ongoing`.
set -euo pipefail

CALENDAR="Vorssaint Test"

# osascript snippet: an event `minutes` from the current minute, lasting `length` minutes.
event() { # title start-minutes length-minutes url location notes
    printf 'make new event at end of events of c with properties {summary:%s, start date:(base + (%s * minutes)), end date:(base + ((%s + %s) * minutes)), url:%s, location:%s, description:%s}\n' \
        "$(quote "$1")" "$2" "$2" "$3" "$(quote "$4")" "$(quote "$5")" "$(quote "$6")"
}
quote() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }

# run make "<event lines>" recreates the calendar with them; run clean only deletes it.
run() {
    local body=""
    [[ "$1" == "make" ]] && body="set c to make new calendar with properties {name:\"$CALENDAR\"}
    set base to current date
    set seconds of base to 0
    $2"
    /usr/bin/osascript >/dev/null <<APPLESCRIPT
tell application "Calendar"
    if exists calendar "$CALENDAR" then delete calendar "$CALENDAR"
    $body
end tell
APPLESCRIPT
}

case "${1:-}" in
overlap)
    run make "$(event "PCF meeting" 4 30 "https://us02web.zoom.us/j/81234567890?pwd=abc123" "" "Weekly PCF sync")
$(event "Meeting with Krista" 4 45 "" "Room 4" "Agenda: https://docs.google.com/document/d/1
Join: https://meet.google.com/abc-defg-hij")"
    echo "Two meetings start in 4 min. Expect: island opens on its own; closed island shows two dots,"
    echo "\"+1\", titles taking turns every 5 s; Up next lists both, Join on each (Zoom, Meet)." ;;
staggered)
    run make "$(event "Design review" 3 30 "" "" "Join Webex: https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fcompany.webex.com%2Fmeet%2Fkrista&data=1")
$(event "Sync with Jay" 15 15 "https://app.slack.com/huddle/T0123/C0456" "" "")"
    echo "Design review in 3 min, Sync with Jay in 15. Expect: \"Design review +1\", clock with"
    echo "\"· then <time>\", no swapping; Join on Design review (Webex, through Outlook safe links)." ;;
join)
    run make "$(event "Client call" 7 30 "" "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d" "")"
    echo "One Teams call in 7 min. Expect: plain countdown now; in about 2 min the island opens"
    echo "by itself with Join (Teams logo). Join opens Teams if installed; ▾ has the other options." ;;
ongoing)
    run make "$(event "Standup" -10 30 "https://meet.google.com/xyz-abcd-efg" "" "")
$(event "1:1 with Sirjak" 8 30 "" "" "https://discord.gg/vorssaint")"
    echo "Standup under way (Meet), 1:1 in 8 min (Discord). Expect with time left on: mint clock for"
    echo "Standup's end and the 1:1 after it; the agenda card for Standup shows Join." ;;
platforms)
    lines=""
    i=0
    for pair in \
        "Zoom|https://zoom.us/j/1111111111" "Google Meet|https://meet.google.com/aaa-bbbb-ccc" \
        "Teams|https://teams.microsoft.com/l/meetup-join/19%3ameeting_y%40thread.v2/0" \
        "Webex|https://company.webex.com/meet/aryan" "Slack huddle|https://app.slack.com/huddle/T1/C2" \
        "Discord|https://discord.gg/abc" "Skype|https://join.skype.com/abcDEF" \
        "GoTo|https://meet.goto.com/123456789" "Jitsi|https://meet.jit.si/VorssaintTest" \
        "Whereby|https://whereby.com/vorssaint" "FaceTime|https://facetime.apple.com/join#v=1&p=abc" \
        "Chime|https://chime.aws/1234567890"; do
        lines+="$(event "${pair%%|*} test" $((3 + i % 2)) 20 "${pair#*|}" "" "")"$'\n'
        i=$((i + 1))
    done
    run make "$lines"
    echo "Twelve calls in 3 to 4 min, one per service. Expect: three dots and \"+11\", Up next lists"
    echo "all with the right logo (Whereby, FaceTime and Chime use a video mark)." ;;
clean)
    run clean ""
    echo "Deleted the \"$CALENDAR\" calendar." ;;
*)
    sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
