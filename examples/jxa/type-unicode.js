// Type arbitrary Unicode text (Hangul, Japanese, emoji...) with CGEvent unicode strings.
// Temporarily switches to the ABC layout so an input method cannot compose over the events.
//   bridgectl sh "osascript -l JavaScript examples/jxa/type-unicode.js 'Hello 안녕 😀'"
// (The built-in `bridgectl type 'text'` does the same with the safety guard.)
ObjC.import('CoreGraphics'); ObjC.import('Carbon');
function run(argv) {
  var text = argv.join(' ');
  var src = $.TISCopyCurrentKeyboardInputSource();
  var abc = null;
  var list = ObjC.castRefToObject($.TISCreateInputSourceList($({ 'TISPropertyInputSourceID': 'com.apple.keylayout.ABC' }), false));
  if (list && list.count > 0) { abc = list.objectAtIndex(0); $.TISSelectInputSource(abc); delay(0.15); }
  var chars = Array.from(text);
  for (var i = 0; i < chars.length; i++) {
    if (chars[i] == '\n') {
      $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 36, true));
      $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 36, false));
      delay(0.02); continue;
    }
    var s = $(chars[i]), n = s.length, arr = [];
    for (var k = 0; k < n; k++) arr.push(s.characterAtIndex(k));
    var down = $.CGEventCreateKeyboardEvent(null, 0, true), up = $.CGEventCreateKeyboardEvent(null, 0, false);
    $.CGEventKeyboardSetUnicodeString(down, n, arr); $.CGEventKeyboardSetUnicodeString(up, n, arr);
    $.CGEventPost($.kCGHIDEventTap, down); $.CGEventPost($.kCGHIDEventTap, up); delay(0.015);
  }
  if (abc) { delay(0.1); $.TISSelectInputSource(src); }
  return 'typed ' + chars.length;
}
