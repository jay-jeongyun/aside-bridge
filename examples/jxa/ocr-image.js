// OCR an image with Apple's Vision framework. Prints "cx,cy<TAB>text" per line.
// Usage (through the bridge, so it has your permissions):
//   bridgectl sh "osascript -l JavaScript examples/jxa/ocr-image.js IMAGE [OFFSET_X OFFSET_Y SCALE]"
// OFFSET/SCALE convert pixel coords back to screen points (Retina screenshots: SCALE=2).
// The built-in `bridgectl ocr --win APP` does capture + OCR + coordinates in one call.
ObjC.import('Vision'); ObjC.import('AppKit');
function run(argv) {
  if (argv.length < 1) return 'usage: ocr-image.js IMAGE [OFFSET_X OFFSET_Y SCALE]';
  var img = $.NSImage.alloc.initWithContentsOfFile(argv[0]);
  var rep = img.representations.objectAtIndex(0);
  var W = rep.pixelsWide, H = rep.pixelsHigh;
  var ox = +argv[1] || 0, oy = +argv[2] || 0, sc = +argv[3] || 2;
  var req = $.VNRecognizeTextRequest.alloc.init;
  req.recognitionLevel = 0;                       // accurate
  req.usesLanguageCorrection = true;
  req.recognitionLanguages = $(['en-US', 'ko-KR']); // edit for your languages
  var h = $.VNImageRequestHandler.alloc.initWithURLOptions($.NSURL.fileURLWithPath(argv[0]), $({}));
  h.performRequestsError($([req]), null);
  var r = req.results, out = [];
  for (var i = 0; i < r.count; i++) {
    var ob = r.objectAtIndex(i), b = ob.boundingBox;
    var cx = ox + (b.origin.x + b.size.width / 2) * W / sc;
    var cy = oy + (1 - (b.origin.y + b.size.height / 2)) * H / sc;
    out.push(Math.round(cx) + ',' + Math.round(cy) + '\t' + ob.topCandidates(1).objectAtIndex(0).string.js);
  }
  return out.join('\n');
}
