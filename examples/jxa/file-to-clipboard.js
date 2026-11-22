// Put a FILE on the clipboard (like Cmd+C in Finder), so Cmd+V attaches it in chat/mail apps.
//   bridgectl sh "osascript -l JavaScript examples/jxa/file-to-clipboard.js /path/to/file.pdf"
ObjC.import('AppKit');
function run(argv) {
  if (!argv[0]) return 'usage: file-to-clipboard.js PATH';
  var pb = $.NSPasteboard.generalPasteboard;
  pb.clearContents;
  return pb.writeObjects($([$.NSURL.fileURLWithPath(argv[0])])) ? 'ok' : 'fail';
}
