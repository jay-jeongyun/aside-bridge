# Example: a messenger app with no AppleScript dictionary (KakaoTalk for Mac)

KakaoTalk is a popular messenger in Korea. Its Mac app has **no AppleScript dictionary**,
so it is a good real-world example of driving an app with System Events UI scripting,
synthetic input and OCR through AsideBridge. The same techniques apply to many apps.

UI element names below are from the Korean-language UI (app version 26.x, 2026) and
will differ by version and language. Inspect your own UI with Accessibility Inspector.

## Findings

- Launch / bring back the main window: `bridgectl sh 'open -a KakaoTalk'`.
- Main window `카카오톡` ("KakaoTalk"): buttons 1 Friends (Cmd+1), 2 Chats (Cmd+2), 3 More.
  Lists are `UI element 1 of scroll area 1` (an AXTable). Row text:
  `value of every static text of UI element 1 of row i`.
- **Sending a message** works by setting the text area value and pressing the send button:
  ```applescript
  tell application "System Events" to tell process "KakaoTalk"
      set w to window "<chat window name>"
      set ta to text area 1 of scroll area 2 of w
      set focused of ta to true
      set value of ta to "<text>"       -- non-Latin text is fine this way
      click (first button of w whose name is "전송")   -- "Send"
  end tell
  ```
  Verify: the text area becomes empty and the row count of the message list grows.
- **Non-Latin text input**: with a Korean input method active, `keystroke "한글"` produces garbage and
  `keystroke "v" using command down` may not paste. Use AX `set value`, or `bridgectl type` (CGEvent
  unicode, switches to ABC temporarily), or clipboard + `key code 9 using command down`.
- **Attaching a file**: click the file icon in the chat window, type `/` in the open panel,
  set the path field, Enter, then confirm the send dialog. The app may ask for folder access once.
- **Reading messages**: message bubbles return empty AX values, so read them with OCR
  (`bridgectl ocr --win KakaoTalk`, or `read-chat.sh` here).

## Safety

Anything that sends messages as the user must show the exact recipient and text to the user
and get explicit approval first. Do not automate sending without that step.

## read-chat.sh

Opens a chat by search, OCRs it page by page while scrolling up, then closes the window.

```bash
bridgectl sh "$PWD/examples/apps/kakaotalk/read-chat.sh 'search text' 'Exact chat name' /tmp/chat 3" --timeout 120
```
