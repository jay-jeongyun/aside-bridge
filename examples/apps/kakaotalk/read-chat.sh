#!/bin/bash
# read-chat.sh QUERY "EXACT CHAT NAME" OUT_PREFIX [PAGES]
# Opens a KakaoTalk chat via the search field, OCRs it while scrolling up, then closes it.
# Run THROUGH the bridge (needs Accessibility + Screen Recording):
#   bridgectl sh "/path/to/read-chat.sh 'query' 'Chat name' /tmp/chat 3" --timeout 120
# UI labels are from the Korean UI of KakaoTalk 26.x; adjust for your version/language.
set -u
Q=$1; NAME=$2; OUT=$3; PAGES=${4:-3}
HERE="$(cd "$(dirname "$0")" && pwd)"
EX="$HERE/../.."
BRIDGECTL="python3 ${ASIDEBRIDGE_HOME:-$HOME/.asidebridge}/bridgectl.py"
MAIN_WINDOW="카카오톡"           # main window title
SEARCH_FIELD="텍스트 필드 검색"   # search text field description
SEARCH_BUTTON="검색"             # search button description
CLOSE_BUTTON="닫기 버튼"          # close button description

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# window bounds "x,y,w,h" of the chat window
winrect() {
  osascript -l JavaScript "$EX/jxa/window-list.js" | awk -F' \\| ' -v n="$1" '$2==n {print $4; exit}'
}

POS=$(osascript <<AS
tell application "KakaoTalk" to activate
tell application "System Events" to tell process "KakaoTalk"
  set w to window "$(esc "$MAIN_WINDOW")"
  perform action "AXRaise" of w
  click button 2 of w
  delay 0.3
  if not (exists (first text field of w whose description is "$(esc "$SEARCH_FIELD")")) then
    click (first button of w whose description is "$(esc "$SEARCH_BUTTON")")
    delay 0.5
  end if
  set tf to (first text field of w whose description is "$(esc "$SEARCH_FIELD")")
  set focused of tf to true
  set value of tf to "$(esc "$Q")"
  delay 1.5
  set t to UI element 1 of scroll area 1 of w
  repeat with i from 1 to (count of rows of t)
    set r to row i of t
    if (value of static text 1 of UI element 1 of r) is "$(esc "$NAME")" then
      set p to position of r
      set sz to size of r
      return ((item 1 of p) + 150) & "|" & ((item 2 of p) + (item 2 of sz) / 2)
    end if
  end repeat
  return "NOTFOUND"
end tell
AS
)
[ "$POS" = "NOTFOUND" ] && { echo "chat not found: $NAME" >&2; exit 3; }
IFS='|' read -r CX CY <<< "$(echo "$POS" | tr -d ' ,')"
$BRIDGECTL dclick "${CX%.*}" "${CY%.*}" --idle 0 >/dev/null; sleep 2
RECT=$(winrect "$NAME"); echo "opened: $NAME rect=$RECT"
[ -z "$RECT" ] && { echo "chat window not visible" >&2; exit 4; }
IFS=',' read -r X Y W H <<< "$RECT"
for p in $(seq 0 "$PAGES"); do
  screencapture -x -R"$X,$Y,$W,$H" "$OUT-$p.png"; echo "--- page $p"
  osascript -l JavaScript "$EX/jxa/ocr-image.js" "$OUT-$p.png" "$X" "$Y" 2 | cut -f2
  $BRIDGECTL move $((X + W / 2)) $((Y + H / 2 - 60)) --idle 0 >/dev/null
  $BRIDGECTL scroll 10 --idle 0 >/dev/null; sleep 1.2
done
osascript -e "tell application \"System Events\" to tell process \"KakaoTalk\" to click (first button of window \"$(esc "$NAME")\" whose description is \"$(esc "$CLOSE_BUTTON")\")" >/dev/null 2>&1
