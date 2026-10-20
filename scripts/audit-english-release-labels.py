"""Bounded English release-credit replay. Not execution of the iOS hooks.

One metadata query per provider, at most two lyric candidates, QQ then KuGou.
No artist-library search; no full lyrics, credentials or lyric keys in reports.
"""
from pathlib import Path
import datetime
import difflib
import importlib.util
import json
import sys

sys.stdout.reconfigure(encoding='utf-8')
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT/'scripts/audit-selective-lyrics.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

samples = [
    ('STAY (with Justin Bieber)', 'The Kid LAROI', 142),
    ("I Don't Care (with Justin Bieber)", 'Ed Sheeran', None),
    ('See You Again (feat. Charlie Puth)', 'Wiz Khalifa', None),
    ("We Don't Talk Anymore (feat. Selena Gomez)", 'Charlie Puth', None),
    ('Closer (feat. Halsey)', 'The Chainsmokers', None),
    ('Something Just Like This', 'The Chainsmokers', None),
    ('Señorita', 'Shawn Mendes', None),
    ('Die With A Smile', 'Lady Gaga', None),
]


def controls():
    for title, _, _ in samples:
        assert audit.title_match(title, audit.catalogue.title_core(title)), title
    for bad in ['STAY (Live)', 'STAY (with Justin Bieber Live)', 'STAY (Remix)',
                'STAY (with Orchestra)', 'STAY (Acoustic Cover)',
                'Stay - Justin Bieber&The Kid Laroi', 'STAY (Karaoke Version)']:
        assert not audit.title_match(bad, 'STAY (with Justin Bieber)'), bad
    assert audit.artist_score('恋雪海螺', 'The Kid LAROI') == 0
    assert audit.artist_score('The Kid LAROI, Justin Bieber', 'The Kid LAROI') > 0
    assert audit.title_match('STAY (Explicit)', 'STAY (with Justin Bieber)')
    assert not audit.title_match('STAY (Explicit)', 'STAY (Clean)')
    assert not audit.title_match('STAY (Live) (Explicit)', 'STAY')
    print('PASS: English credit equivalence and strict version/artist negative controls', flush=True)


def run(stay_only=False):
    controls()
    rows = []
    for title, artist, duration in samples[:1] if stay_only else samples:
        row = {'spotify_title': title, 'spotify_artist': artist,
               'search_title': audit.catalogue.title_core(title), 'providers': {}}
        try:
            if duration is None:
                reference = audit.apple(audit.catalogue.title_core(title), artist, 'us')
                duration = reference['seconds']
                row['duration_reference'] = {k:v for k,v in reference.items() if k != 'text'}
            track = {'title':title, 'artist':artist, 'seconds':duration}
            row['seconds'] = duration
            hits = []
            for provider in ['qqmusic', 'kugou']:
                try:
                    hit = audit.search(track, provider, strategy=True)
                    row['providers'][provider] = ({k:v for k,v in hit.items() if k != 'text'}
                                                  if hit else {'status':'no_verified_candidate'})
                    if hit: hits.append(hit)
                except Exception as error:
                    row['providers'][provider] = {'status':'unavailable', 'error':str(error)}
            if len(hits) == 2:
                ratio = difflib.SequenceMatcher(None, hits[0]['text'], hits[1]['text'], autojunk=False).ratio()
                row['original_similarity'] = round(ratio, 4)
                row['status'] = 'corroborated' if ratio >= 0.70 else 'conflicting_text'
            else:
                row['status'] = 'verified_metadata_single_source' if hits else 'unavailable'
        except Exception as error:
            row.update(status='unavailable', error=str(error))
        rows.append(row)
        print(title, row['status'], row.get('original_similarity',''), flush=True)
    report = {'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'method':'Windows metadata/lyrics replay; iOS and visual behavior unverified',
              'limits':{'search_rows':12, 'lyric_candidates_per_provider':2,
                        'metadata_queries_per_provider':1, 'providers':['qqmusic','kugou']},
              'tracks':rows}
    target = ROOT/'docs'/('stay-release-label-audit-2026-10-20.json' if stay_only else 'english-release-label-audit-2026-10-20.json')
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('REPORT', target, flush=True)


if __name__ == '__main__':
    if '--controls-only' in sys.argv: controls()
    else: run('--stay-only' in sys.argv)
