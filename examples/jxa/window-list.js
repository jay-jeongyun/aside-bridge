// List all on-screen windows: "app | title | layer | x,y,w,h".
// bridgectl jxa -f examples/jxa/window-list.js
// (The built-in `bridgectl wins [filter]` returns the same as JSON and is faster.)
ObjC.import('CoreGraphics');
function run() {
  var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
  var out = [];
  for (var i = 0; i < list.count; i++) {
    var d = list.objectAtIndex(i);
    var b = d.objectForKey('kCGWindowBounds');
    var title = d.objectForKey('kCGWindowName');
    out.push([
      d.objectForKey('kCGWindowOwnerName').js,
      title ? title.js : '',
      'L' + d.objectForKey('kCGWindowLayer').js,
      [b.objectForKey('X').js, b.objectForKey('Y').js, b.objectForKey('Width').js, b.objectForKey('Height').js].join(',')
    ].join(' | '));
  }
  return out.join('\n');
}
