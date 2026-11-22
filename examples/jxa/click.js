// Click at screen coordinates (points).
//   bridgectl sh "osascript -l JavaScript examples/jxa/click.js 400 300"
// (Prefer the built-in, guarded `bridgectl click X Y`.)
ObjC.import('CoreGraphics');
function run(argv) {
  var x = parseFloat(argv[0]), y = parseFloat(argv[1]);
  if (isNaN(x) || isNaN(y)) return 'usage: click.js X Y';
  var p = $.CGPointMake(x, y);
  $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, p, 0)); delay(0.2);
  $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, p, 0)); delay(0.05);
  $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, p, 0));
  return 'clicked ' + x + ',' + y;
}
