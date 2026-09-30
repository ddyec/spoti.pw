#import <Foundation/Foundation.h>

#define SGKeyLyricsDiagnostics @"spotifyglass.lyricsDiagnostics"
BOOL SGLyricsDiagnosticsEnabled(void);
void SGLyricsLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void SGLyricsDiagnosticsClear(void);
void SGLyricsDiagnosticsExport(void (^done)(NSURL *file));
