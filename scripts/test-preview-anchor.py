#!/usr/bin/env python3
"""Compile production preview geometry on Linux or macOS (no Apple SDK needed).

Only the CoreGraphics value types are shimmed. The layout and reservation
functions are extracted unchanged from the shipping sources.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
player = root / 'tweak/Sources/Redesigned/Player'
preview = (player / 'PlayerPreview.x').read_text()
artwork = (player / 'PlayerArtwork.x').read_text()


def section(source, start, end):
    assert source.count(start) == source.count(end) == 1
    return start + source.split(start)[1].split(end)[0]


geometry = section(preview, 'static CGRect sgrPreviewFrame(', 'static BOOL sgrShowing(')
offset = section(artwork, 'static CGFloat sgrPreviewAnchorOffset(', 'static void scaleCover(')
shim = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
typedef double CGFloat;
typedef long NSInteger;
typedef int BOOL;
#define YES 1
#define NO 0
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#define MIN(a,b) ((a) < (b) ? (a) : (b))
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
#define CGPointMake(x,y) ((CGPoint){x,y})
#define CGSizeMake(w,h) ((CGSize){w,h})
#define CGSizeZero ((CGSize){0,0})
#define CGRectMake(x,y,w,h) ((CGRect){{x,y},{w,h}})
#define CGRectNull CGRectMake(INFINITY, INFINITY, 0, 0)
#define CGRectGetMinX(r) ((r).origin.x)
#define CGRectGetMinY(r) ((r).origin.y)
#define CGRectGetMaxY(r) ((r).origin.y + (r).size.height)
#define CGRectGetMidY(r) ((r).origin.y + (r).size.height / 2)
#define CGRectIsNull(r) isinf((r).origin.x)
static BOOL CGRectEqualToRect(CGRect a, CGRect b) {
    return a.origin.x == b.origin.x && a.origin.y == b.origin.y &&
        a.size.width == b.size.width && a.size.height == b.size.height;
}
'''
tests = r'''
int main(void) {
    CGRect host = CGRectMake(0,0,402,874), info = CGRectMake(0,576,402,64);
    CGRect area = CGRectMake(0,110,402,466), cover = CGRectMake(24,162,354,354);
    CGFloat lift = sgrPreviewNeededLift(cover,info,host,area,88,YES);
    assert(lift == 44);
    CGFloat anchor = CGRectGetMidY(cover) - lift;
    CGFloat centered = sgrPreviewCenteredY(info,host,area);
    assert(centered == 343 && centered > anchor);
    assert(sgrPreviewKeepRecentText(NO,YES,0.5));
    assert(!sgrPreviewKeepRecentText(NO,YES,1.0));
    assert(!sgrPreviewKeepRecentText(NO,NO,0.1));
    assert(sgrPreviewKeepRecentText(YES,NO,10));
    // A native response can arrive before or after any number of layout passes.
    // Test upward/downward parent moves, and both playing/paused cover scales.
    for (int pass=0; pass<500; pass++) {
        CGFloat parentY = 118 + (pass % 5) * 22;
        CGRect native = CGRectMake(24,parentY,354,354);
        assert(!sgrPreviewAnchorNeedsUpdate(YES,info,info));
        CGFloat correction = sgrPreviewAnchorOffset(native,anchor);
        assert(fabs(CGRectGetMidY(native) + correction - anchor) < 0.001);
        for (int paused=0; paused<2; paused++) {
            CGFloat size = 354 * (paused ? 0.84 : 1);
            CGRect shown = CGRectMake(24,anchor-size/2,size,size);
            CGRect gap = sgrPreviewFrame(shown,info,host);
            assert(!CGRectIsNull(gap) && gap.size.height >= 88);
            assert(CGRectGetMinY(shown) >= CGRectGetMinY(area)+8);
        }
    }
    // No redundant movement when there is already room; cramped screens respect header.
    assert(sgrPreviewNeededLift(CGRectMake(24,118,354,354),info,host,area,88,YES) == 0);
    assert(sgrPreviewNeededLift(cover,CGRectMake(0,530,402,64),host,area,88,YES) == 44);
    assert(sgrPreviewNeededLift(cover,info,host,area,88,NO) == 0);
    assert(sgrPreviewAnchorNeedsUpdate(NO,info,info));
    assert(!sgrPreviewAnchorNeedsUpdate(YES,info,CGRectMake(0,576,402,80)));
    assert(sgrPreviewAnchorNeedsUpdate(YES,info,CGRectMake(0,600,402,64)));
    // Loading -> timed lyrics -> cache gaps/interludes -> track without lyrics -> disabled.
    BOOL reserved = sgrPreviewReservesSpace(YES,NO,NO,NO);
    assert(!reserved);
    reserved = sgrPreviewReservesSpace(YES,YES,YES,reserved);
    assert(reserved);
    for (int pass=0; pass<100; pass++) {
        reserved = sgrPreviewReservesSpace(YES,pass%3 == 0,YES,reserved);
        assert(reserved);
    }
    assert(!sgrPreviewReservesSpace(YES,NO,NO,reserved));
    assert(!sgrPreviewReservesSpace(NO,YES,YES,reserved));
    // Full lyrics/transition suspension does not erase the per-track reservation.
    assert(sgrPreviewReservesSpace(YES,NO,YES,reserved));
    puts("Preview anchor regression passed: late native layouts, pause, header bounds, cache gaps and track reset");
}
'''
# The preview must not request native availability just to decide its layout.
assert 'SGLyricsSpotifyHas(' not in preview
assert 'SGKaraokeProbeNativeLyrics(' not in preview
assert 'SGRPlayerSetPreviewAnchor(host, track, self.reserved ? self.anchorY : self.centeredY)' in preview
assert 'transform.ty = sgrPreviewAnchorOffset(tilt.bounds, target.y)' in artwork
with tempfile.TemporaryDirectory(prefix='preview-anchor-') as directory:
    source = Path(directory) / 'preview.c'
    binary = Path(directory) / 'preview'
    source.write_text(shim + geometry + offset + tests)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                    '-Wno-unused-function', str(source), '-lm', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
