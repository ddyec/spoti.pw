"""Small live preflight on Windows. Metadata replay + independent lyric text comparison.
The native Objective-C regression suite runs separately in the IPA Action.
Never writes full lyrics, access keys, or authentication data into the report.
"""
import base64
import ctypes
import datetime
import difflib
import importlib.util
import json
import re
import sys
import unicodedata
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('catalogue', ROOT/'scripts/probe-lyrics-catalogue.py')
catalogue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalogue)

def search_text(s):
    value = unicodedata.normalize('NFKC', s or '')
    if any('\u3400' <= c <= '\u9fff' for c in value):
        # The Windows-native equivalent of the production Traditional-Simplified transform.
        fn = ctypes.windll.kernel32.LCMapStringEx
        out = ctypes.create_unicode_buffer(len(value)*3+1)
        count = fn('zh-CN', 0x02000000, value, len(value), out, len(out), None, None, 0)
        if count: value = out.value
    return value

def normalized(s):
    return ''.join(c for c in search_text(s).casefold() if c.isalnum())

def title_match(a,b):
    ca,cb = catalogue.title_core(a),catalogue.title_core(b)
    x,y = normalized(ca),normalized(cb)
    if x and x == y:return True
    if any(c in ca+cb for c in '()[]（）【】'):return False
    return catalogue.title_match(ca,cb)

def artist_score(a,b):
    return sum(any(normalized(x) == normalized(y) for x in catalogue.SEP.split(a))
               for y in catalogue.SEP.split(b))

CREDIT = re.compile(catalogue.pattern('credit', 'BOOL SGLyricsTimedCredit('), re.I)
RECORDING_CREDIT = re.compile(catalogue.pattern('recordingCredit', 'BOOL SGLyricsTimedCredit('), re.I)

def lyric_text(text):
    # Compare original text only, not translator/uploader credits or timing syntax.
    rows=[]
    for row in (text or '').splitlines():
        if not re.match(r'^\[\d',row):continue
        row=re.sub(r'\[[^]]*\]|<[^>]*>|\(\d+,\d+(?:,\d+)?\)','',row)
        if CREDIT.search(row) or RECORDING_CREDIT.search(row):continue
        rows.append(normalized(row))
    return ''.join(rows)

def apple(title,artist,country):
    url='https://itunes.apple.com/search'
    data=catalogue.get(url,term=title+' '+artist,entity='song',limit=12,country=country)
    for row in data.get('results',[]):
        if title_match(row.get('trackName',''),title) and artist_score(row.get('artistName',''),artist):
            return dict(title=row['trackName'],artist=row['artistName'],seconds=round(row['trackTimeMillis']/1000),
                        album=row.get('collectionName'),reference=row.get('trackViewUrl'))
    raise ValueError('Apple reference recording not found')

def search(track,provider,strategy=False,reference=None):
    title,artist,seconds=track['title'],track['artist'],track['seconds']
    if strategy:title,artist=search_text(title),search_text(artist)
    lead=catalogue.SEP.split(artist)[0]
    if provider=='netease':
        root=catalogue.get('https://music.163.com/api/search/get',s=catalogue.title_core(title)+' '+lead,type=1,limit=12)
        if root.get('code')!=200:raise ValueError('NetEase search code '+str(root.get('code')))
        rows=[dict(id=r['id'],title=r['name'],artist=', '.join(a['name'] for a in r.get('artists',[])),
                   seconds=r.get('duration',0)//1000,aliases=r.get('alias',[])+r.get('transNames',[])+r.get('tns',[]))
              for r in root.get('result',{}).get('songs',[])]
        slack=3
    elif provider=='qqmusic':
        request={'comm':{'ct':'19','cv':'1859','uin':'0'},'req':{'method':'DoSearchForQQMusicDesktop',
          'module':'music.search.SearchCgiService','param':{'grp':1,'num_per_page':12,'page_num':1,
          'query':catalogue.title_core(title)+' '+lead,'search_type':0}}}
        root=catalogue.fetch('https://u.y.qq.com/cgi-bin/musicu.fcg',request)
        if root.get('req',{}).get('code')!=0:raise ValueError('QQ search code '+str(root.get('req',{}).get('code')))
        rows=[dict(id=r.get('id'),title=r.get('title',r.get('songname','')),artist=', '.join(a['name'] for a in r.get('singer',[])),
                   seconds=r.get('interval',0),aliases=[]) for r in root.get('req',{}).get('data',{}).get('body',{}).get('song',{}).get('list',[])]
        slack=6
    else:
        root=catalogue.get('https://krcs.kugou.com/search',ver=1,man='yes',client='mobi',hash='',album_audio_id='',
                           keyword=lead+' - '+catalogue.title_core(title),duration=seconds*1000)
        if root.get('status')!=200:raise ValueError('KuGou search status '+str(root.get('status')))
        def duration(raw):
            if strategy:return raw if abs(raw-seconds)<abs(raw//1000-seconds) else raw//1000
            return raw//1000
        rows=[dict(id=r.get('id'),title=r.get('song',''),artist=r.get('singer',''),seconds=duration(r.get('duration',0)),
                   aliases=[],accesskey=r.get('accesskey')) for r in root.get('candidates',[])]
        slack=8
    fitting=[r for r in rows if any(title_match(t,title) for t in [r['title']]+r['aliases']) and
             (artist_score(r['artist'],artist)>0 or reference) and r['seconds']>0 and abs(r['seconds']-seconds)<=slack]
    fitting.sort(key=lambda r:(not title_match(r['title'],title),-artist_score(r['artist'],artist),abs(r['seconds']-seconds)))
    for row in fitting[:2]:
        if provider=='netease':
            body=catalogue.get('https://music.163.com/api/song/lyric/v1',id=row['id'],lv=1,yv=1,tv=-1,rv=-1,yrv=-1)
            text=(body.get('lrc') or {}).get('lyric','') or (body.get('yrc') or {}).get('lyric','')
        elif provider=='qqmusic':
            body=catalogue.qq_lyrics(row['id'])
            try:text=base64.b64decode(body.get('lyric') or '').decode('utf-8')
            except (ValueError,UnicodeDecodeError):text=''
        else:
            body=catalogue.get('https://lyrics.kugou.com/download',ver=1,client='pc',id=row['id'],accesskey=row['accesskey'],fmt='krc',charset='utf8')
            data=base64.b64decode(body.get('content') or '')
            if data[:4]!=b'krc1':continue
            key=bytes([64,71,97,119,94,50,116,71,81,54,49,45,206,210,110,105])
            text=zlib.decompress(bytes(c^key[i%16] for i,c in enumerate(data[4:]))).decode('utf-8')
        original=lyric_text(text)
        if reference and difflib.SequenceMatcher(None,reference,original,autojunk=False).ratio()<0.70:continue
        if len(original)>=40:
            return {k:v for k,v in row.items() if k!='accesskey'}|{'original_characters':len(original),'text':original}
    return None

samples=[
 ('zh','鴻門宴','李榮浩','tw',204),('en','Animals','Maroon 5','us',231),
 ('zh','晴天','周杰倫','tw',None),('zh','水星記','郭頂','tw',None),
 ('en','Yellow','Coldplay','us',None),('en','The Scientist','Coldplay','us',None),
 ('ja','夜に駆ける','YOASOBI','jp',None),('ja','夏霞','あたらよ','jp',None),
 ('ko','Spring Day','BTS','us',None),('ko','Love poem','IU','us',None),('fr','Dernière danse','Indila','fr',None),
 ('es','La camisa negra','Juanes','mx',None)]

def composition(title):
    return normalized(re.sub(r'\s*\([^)]*\)\s*$','',title))

if __name__=='__main__' and '--finish-round2-controls' in sys.argv:
    path=ROOT/'docs/lyrics-live-audit-round2-2026-10-18.json'
    report=json.loads(path.read_text(encoding='utf-8'))
    tracks={t['title']:t for t in report['tracks']}
    controls=[];versions=[]
    for control in report['wrong_song_controls']:
        if composition(control['wanted'])!=composition(control['wrong_song']):
            controls.append(control);continue
        wanted,other=tracks[control['wanted']],tracks[control['wrong_song']]
        versions.append(control|{'kind':'same_composition_different_recording',
            'title_rejected':not title_match(wanted['title'],other['title']),
            'duration_gap':abs(wanted['seconds']-other['seconds']),
            'rejected':not title_match(wanted['title'],other['title']) and abs(wanted['seconds']-other['seconds'])>8})
        unrelated=next(t for t in report['tracks'] if composition(t['title'])!=composition(wanted['title']))
        first=search(wanted,'netease',True);wrong=search(unrelated,'netease',True)
        if not first or not wrong:raise RuntimeError('Unrelated lyric control could not be acquired')
        score=difflib.SequenceMatcher(None,first['text'],wrong['text'],autojunk=False).ratio()
        controls.append({'wanted':wanted['title'],'wrong_song':unrelated['title'],'similarity':round(score,4),'rejected':score<0.70})
    report['wrong_song_controls']=controls;report['version_controls']=versions
    report['all_passed']=all(t['status']=='verified' for t in report['tracks']) and len(controls)==len(report['tracks']) and all(c['rejected'] for c in controls) and all(c['rejected'] for c in versions)
    report['control_note']='Different recordings of the same composition are checked by version title and duration, and have an additional unrelated-lyrics control.'
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print('ALL_PASSED',report['all_passed'], 'SONGS',len(tracks),'WRONG_LYRICS',len(controls),'VERSIONS',len(versions))
    sys.exit(0 if report['all_passed'] else 1)

if __name__=='__main__':
    out=ROOT/'docs/lyrics-live-audit-2026-10-18.json'
    fresh='--fresh-round' in sys.argv
    if fresh:
        samples=[
            ('zh','十年','陳奕迅','tw',None),('zh','遇見','孫燕姿','tw',None),
            ('zh','寶貝 (In the Night)','張懸','tw',None),('zh','寶貝 (In a Day)','張懸','tw',None),('en','Someone Like You','Adele','us',None),
            ('en','cardigan','Taylor Swift','us',None),('en','No Surprises','Radiohead','us',None),
            ('ja','Lemon','米津玄師','jp',None),('ja','カタオモイ','Aimer','jp',None),
            ('ko','Fine','TAEYEON','us',None),('fr','Alors on danse','Stromae','fr',None),
            ('es','Antología','Shakira','mx',None),('de','Sonne','Rammstein','de',None)]
        old=json.loads(out.read_text(encoding='utf-8'))
        assert not {normalized(t['title']) for t in old['tracks']} & {normalized(t[1]) for t in samples}
    strategy='--strategy-check' in sys.argv or fresh
    previous=json.loads(out.read_text(encoding='utf-8')) if ('--retry-unverified' in sys.argv or strategy) and out.exists() else {'tracks':[]}
    if fresh:previous={'tracks':[]}
    kept={(t['language'],normalized(t['title'])):t for t in previous['tracks'] if t['status']=='verified' or '--add-only' in sys.argv}
    results=[]
    originals=[]
    qq_unavailable=False
    for language,title,artist,country,seconds in samples:
        if (language,normalized(title)) in kept:
            results.append(kept[language,normalized(title)]);continue
        track=dict(language=language,title=title,artist=artist,seconds=seconds)
        try:
            if seconds:track['reference']='provided Spotify device log, 2026-10-18'
            else:track.update(apple(title,artist,country))
            matches=[]; providers=[]
            for provider in ('netease','qqmusic','kugou'):
                if fresh and provider=='qqmusic' and qq_unavailable:
                    providers.append({'provider':provider,'status':'skipped_source_unavailable'});continue
                try:
                    lookup=dict(track)
                    if strategy and matches:
                        lookup.update(title=matches[0]['title'],artist=matches[0]['artist'])
                    candidate=search(lookup,provider,strategy)
                    if candidate:matches.append(candidate);providers.append({'provider':provider,'status':'matched','candidate':{k:v for k,v in candidate.items() if k!='text'}})
                    else:providers.append({'provider':provider,'status':'no_match'})
                except Exception as exc:
                    providers.append({'provider':provider,'status':'request_error','error':str(exc)[:150]})
                    if fresh and provider=='qqmusic':qq_unavailable=True
                if len(matches)==2:break
            # Independent reference only for this diagnostic experiment, not a new production fallback.
            if strategy and len(matches)==1:
                try:
                    row=catalogue.get('https://lrclib.net/api/get',track_name=track['title'],artist_name=track['artist'],duration=track['seconds'])
                    text=lyric_text(row.get('syncedLyrics',''))
                    if title_match(row.get('trackName',''),track['title']) and artist_score(row.get('artistName',''),track['artist']) and abs(row.get('duration',0)-track['seconds'])<=3 and len(text)>=40:
                        candidate=dict(id=row['id'],title=row['trackName'],artist=row['artistName'],seconds=row['duration'],text=text,original_characters=len(text))
                        matches.append(candidate);providers.append({'provider':'lrclib-diagnostic-reference','status':'matched','candidate':{k:v for k,v in candidate.items() if k!='text'}})
                except Exception as exc:providers.append({'provider':'lrclib-diagnostic-reference','status':'request_error','error':str(exc)[:150]})
            track['providers']=providers
            if fresh and not matches:
                # Exercise production's existing reference-text path for regional artist names.
                # A named official recording from LRCLIB stands in for the reference lyrics
                # Spotify would supply; no alias is guessed or hard-coded into production.
                try:
                    row=catalogue.get('https://lrclib.net/api/get',track_name=track['title'],artist_name=track['artist'],duration=track['seconds'])
                    reference=lyric_text(row.get('syncedLyrics',''))
                    if title_match(row.get('trackName',''),track['title']) and artist_score(row.get('artistName',''),track['artist']) and abs(row.get('duration',0)-track['seconds'])<=3 and len(reference)>=40:
                        candidate=search(track,'netease',strategy,reference)
                        if candidate:
                            matches=[candidate,dict(id=row['id'],title=row['trackName'],artist=row['artistName'],seconds=row['duration'],text=reference)]
                            providers.append({'provider':'netease-reference-validation','status':'matched','candidate':{k:v for k,v in candidate.items() if k!='text'}})
                            providers.append({'provider':'lrclib-diagnostic-reference','status':'matched','candidate':{k:v for k,v in matches[1].items() if k!='text'}})
                            track['requires_existing_reference']=True
                except Exception as exc:providers.append({'provider':'reference-validation','status':'request_error','error':str(exc)[:150]})
            if len(matches)==2:
                ratio=difflib.SequenceMatcher(None,matches[0]['text'],matches[1]['text'],autojunk=False).ratio()
                track['independent_text_similarity']=round(ratio,4)
                track['status']='verified' if ratio>=0.70 else 'REVIEW_BODY_MISMATCH'
                originals.append((track['title'],matches[0]['text']))
            else:track['status']='metadata_only' if matches else 'no_match'
        except Exception as exc:track.update(status='reference_error',error=str(exc)[:150])
        results.append(track)
        print(language,title,track['status'],track.get('independent_text_similarity',''),flush=True)
    report={'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':f'{len(samples)} recordings, {len({s[0] for s in samples})} languages, metadata replay and independent original-text comparison; no audio listening or device validation',
            'tracks':results,'meme_regression_rejected':not title_match('Animals (金坷垃)','Animals')}
    if strategy:
        out=ROOT/'docs/lyrics-live-audit-strategy-2026-10-18.json'
        report['strategy']='Simplified Chinese search, reuse confirmed catalogue spelling, infer mixed duration unit; LRCLIB is diagnostic reference only'
    if fresh:
        out=ROOT/'docs/lyrics-live-audit-round2-2026-10-18.json'
        report['reused_results']=0
        controls=[]
        for i,(title,text) in enumerate(originals):
            other,wrong=next(originals[(i+offset)%len(originals)] for offset in range(1,len(originals))
                if composition(originals[(i+offset)%len(originals)][0])!=composition(title))
            score=difflib.SequenceMatcher(None,text,wrong,autojunk=False).ratio()
            controls.append({'wanted':title,'wrong_song':other,'similarity':round(score,4),'rejected':score<0.70})
        report['wrong_song_controls']=controls
        report['all_passed']=len(results)==len(samples) and all(t['status']=='verified' for t in results) and len(controls)==len(samples) and all(c['rejected'] for c in controls)
    out.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print('REPORT',out,flush=True)
    if fresh:
        print('ALL_PASSED',report['all_passed'],flush=True)
        sys.exit(0 if report['all_passed'] else 1)
