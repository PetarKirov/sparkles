// @filename: helper.d
module helper;

/// How many bits of color a terminal can address per channel.
enum ColorDepth { mono = 1, indexed = 8, truecolor = 24 }
// @filename: app.d
module app;
import helper;

auto depth = ColorDepth.truecolor;
//   ^?
//                      ^?
