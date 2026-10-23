#!/usr/bin/env python3
"""Validate the compiled catalogue and exercise the production Foundation lookup on macOS."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'scripts/generate-localization.py'), '--check'], check=True)
translations = json.loads((root / 'localization/zh-Hans.json').read_text())
required = ['Mod Settings', 'Redesigned UI', 'Player', 'Lyrics', 'Audio effects', 'Privacy & clutter',
            'Updates', 'Sources', 'Translation language', 'Background', 'Reset all settings?',
            'Performance diagnostics', 'Cancel', 'About this switch', 'Line meanings']
assert all(key in translations for key in required)
if sys.platform != 'darwin':
    print('Catalogue checks passed; Foundation runtime checks require the macOS Action')
    sys.exit(0)
source = r'''
#import <Foundation/Foundation.h>
#import "SGLocalization.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        assert([SGTextForLanguage(@"Mod Settings", @"zh-Hans") isEqualToString:@"模组设置"]);
        assert([SGTextForLanguage(@"Lyrics", @"zh-Hant-TW") isEqualToString:@"歌词"]);
        assert([SGTextForLanguage(@"Cancel", @"en-US") isEqualToString:@"Cancel"]);
        assert([SGTextForLanguage(@"Cancel", @"fr-FR") isEqualToString:@"Cancel"]);
        assert(!SGTextForLanguage(nil, @"zh"));
        for (NSString *raw in @[@"spoti.pw", @"spotifyglass.redesign.playerLyricsPreview",
            @"https://open.spotify.com/track/123", @"sl_pk_example", @"Artist — 我的自定义名称", @"GraphicalEQ: 20 -1.2;"]) {
            assert([SGTextForLanguage(raw, @"zh") isEqualToString:raw]);
        }
        NSString *format = SGTextForLanguage(@"Downloading %lld %% · %lld of %@", @"zh");
        assert(([[NSString stringWithFormat:format, 50ll, 235ll, @"470 MB"] isEqualToString:@"正在下载 50 % · 235 / 470 MB"]));
        format = SGTextForLanguage(@"Spotify %@ isn't supported", @"zh");
        assert(([[NSString stringWithFormat:format, @"9.1.90"] isEqualToString:@"不支持 Spotify 9.1.90"]));
        puts("PASS: Chinese locale selection, English fallback, raw identifiers and formatted UI text");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='spoti-localization-') as directory:
    main = Path(directory) / 'main.m'
    main.write_text(source)
    binary = Path(directory) / 'test'
    core = root / 'tweak/Sources/Core'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    '-I', str(core), str(main), str(core / 'SGLocalization.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
