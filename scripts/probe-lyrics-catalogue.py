#!/usr/bin/env python3
"""Windows-native live catalogue audit. Metadata replay, not Objective-C/iOS execution.
No full lyrics, authentication data or lyric access keys are written to the report.
"""
import concurrent.futures as cf
import sys
sys.stdout.reconfigure(encoding="utf-8")
import base64, zlib
import datetime, hashlib, json, random, re, unicodedata, urllib.parse, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tweak/Sources/Shared/LyricsSources/LyricsMatching.m'
TEXT = SOURCE.read_text(encoding='utf-8')
# Reuse production regex literals rather than maintain separate title/version tables.
def pattern(variable, begin):
    part = TEXT.split(begin, 1)[1]
    return json.loads(re.search(variable + r' = \[NSRegularExpression regularExpressionWithPattern:\s*(@"(?:\\.|[^"\\])*")', part).group(1)[1:])
SUFFIX = re.compile(pattern('suffix', 'NSString *SGLyricsSearchTitle('))
THEME = re.compile(pattern('theme', 'NSString *SGLyricsSearchTitle('), re.I)
VERSION = re.compile(pattern('version', 'NSString *SGLyricsSearchTitle('), re.I)
FEATURED = re.compile(pattern('featured', 'NSString *SGLyricsSearchTitle('), re.I)
REJECT_REST = json.loads(re.search(r'for \(NSString \*version in @(\[.*?\])\)', TEXT, re.S).group(1).replace('@"','"'))
SEP = re.compile(pattern('separator','static NSArray<NSString *> *artistParts('), re.I)
def comparable(s):
    return ''.join(c for c in unicodedata.normalize('NFKD', s or '').casefold() if c.isalnum())
def title_core(s):
    value = FEATURED.sub('',unicodedata.normalize('NFKC', s or ''))
    m=SUFFIX.search(value)
    return value[:m.start()].strip() if m and m.start()>0 and THEME.search(m.group()) and not VERSION.search(m.group()) else value.strip()
def title_match(a,b):
    a,b=comparable(title_core(a)),comparable(title_core(b))
    if not a or not b:return False
    if a==b:return True
    longer,shorter=sorted((a,b),key=len,reverse=True)
    if shorter not in longer:return False
    rest=longer.replace(shorter,'',1)
    return bool(rest) and all('\u3400'<=c<='\u9fff' for c in rest) and not any('\u3400'<=c<='\u9fff' for c in shorter) and not any(v in rest for v in REJECT_REST)
def artist_score(a,b):
    # Literal and long-substring paths are replayed. Foundation kana transliteration is
    # NOT substituted by a guessed mapping: uncertain kana/Latin pairs are reported.
    score=0
    for wanted in SEP.split(b or ''):
        name=comparable(wanted)
        if len(name)<2:continue
        if any((other==name or (len(name)>=6 and len(other)>=6 and (name in other or other in name))) for other in map(comparable,SEP.split(a or ''))):score+=1
    return score
HEADERS={'User-Agent':'Mozilla/5.0','Referer':'https://music.163.com'}
def fetch(url,body=None):
    req=urllib.request.Request(url,data=json.dumps(body).encode() if body else None, headers=HEADERS|({'Content-Type':'application/json','Referer':'https://y.qq.com/'} if body else {}))
    with urllib.request.urlopen(req,timeout=15) as response:return json.load(response)
def get(url,**params):return fetch(url+'?'+urllib.parse.urlencode(params))
def summary_payload(d):
    result={}
    for k in ('lrc','yrc','tlyric','romalrc','yromalrc'):
        text=(d.get(k) or {}).get('lyric','');result[k+'_chars']=len(text)
    return result
QQ='https://u.y.qq.com/cgi-bin/musicu.fcg'
def qq_search(q):
    d=fetch(QQ,{'comm':{'ct':'19','cv':'1859','uin':'0'},'req':{'method':'DoSearchForQQMusicDesktop','module':'music.search.SearchCgiService','param':{'grp':1,'num_per_page':40,'page_num':1,'query':q,'search_type':0}}})
    if d.get('req',{}).get('code')!=0:raise ValueError('QQ search rejected '+str(d.get('req',{}).get('code')))
    return d.get('req',{}).get('data',{}).get('body',{}).get('song',{}).get('list',[])
def qq_lyrics(songid):
    key='music.musichallSong.PlayLyricInfo.GetPlayLyricInfo'
    d=fetch(QQ,{key:{'method':'GetPlayLyricInfo','module':'music.musichallSong.PlayLyricInfo','param':{'crypt':0,'qrc':0,'trans':1,'roma':1,'songID':songid}}})
    return d.get(key,{}).get('data',{})
def probe(track):
    try:
        lookup=get('https://itunes.apple.com/lookup',id=track['id'],country=track['region']).get('results',[])
        song=next((s for s in lookup if s.get('trackId')==int(track['id'])),None)
        if not song or not song.get('trackTimeMillis'):raise ValueError('Apple duration missing')
        track['seconds']=song['trackTimeMillis']//1000
    except Exception as e:track['error']=str(e);return track
    title,artist,seconds=track['title'],track['artist'],track['seconds']
    lead=SEP.split(artist)[0];keyword=title_core(title)+' '+lead
    providers={}
    for provider in ('netease','qqmusic','kugou'):
        try:
            if provider=='netease':
                root=get('https://music.163.com/api/search/get',s=keyword,type=1,limit=40)
                if root.get('code')!=200:raise ValueError('search code '+str(root.get('code')))
                raw=root.get('result',{}).get('songs',[])
                rows=[dict(id=s['id'],title=s['name'],artist=', '.join(a['name'] for a in s.get('artists',[])),seconds=s.get('duration',0)//1000,aliases=s.get('alias',[])+s.get('transNames',[])+s.get('tns',[])) for s in raw]
                slack=3
            elif provider=='qqmusic':
                raw=qq_search(keyword)
                rows=[dict(id=s.get('id'),title=s.get('title',s.get('songname','')),artist=', '.join(a['name'] for a in s.get('singer',[])),seconds=s.get('interval',0),aliases=[]) for s in raw];slack=6
                if not any(title_match(s['title'],title) and artist_score(s['artist'],artist) and abs(s['seconds']-seconds)<=slack for s in rows):
                    raw=qq_search(title_core(title));rows=[dict(id=s.get('id'),title=s.get('title',s.get('songname','')),artist=', '.join(a['name'] for a in s.get('singer',[])),seconds=s.get('interval',0),aliases=[]) for s in raw]
            else:
                root=get('https://krcs.kugou.com/search',ver=1,man='yes',client='mobi',hash='',album_audio_id='',keyword=lead+' - '+title_core(title),duration=seconds*1000)
                raw=root.get('candidates',[]);slack=8
                rows=[dict(id=s.get('id'),title=s.get('song',''),artist=s.get('singer',''),seconds=s.get('duration',0)//1000,aliases=[]) for s in raw]
            for s in rows:
                s['title_pass']=any(title_match(t,title) for t in [s['title']]+s['aliases']);s['artist_matches']=artist_score(s['artist'],artist);s['duration_pass']=bool(s['seconds']) and abs(s['seconds']-seconds)<=slack
            fitting=[s for s in rows if s['title_pass'] and s['artist_matches'] and s['duration_pass']]
            fitting.sort(key=lambda s:(-s['artist_matches'],abs(s['seconds']-seconds)))
            evidence=[s for s in rows if s['title_pass'] and not s['artist_matches'] and s['duration_pass']]
            selected=None
            for s in fitting[:3 if provider=='netease' else 6 if provider=='qqmusic' else 3]:
                if provider=='netease':
                    d=get('https://music.163.com/api/song/lyric/v1',id=s['id'],lv=1,yv=1,tv=-1,rv=-1,yrv=-1);s['payload']=summary_payload(d)
                    usable=bool((d.get('lrc') or {}).get('lyric') or (d.get('yrc') or {}).get('lyric'))
                elif provider=='qqmusic':
                    d=qq_lyrics(s['id']);s['payload']={k+'_encoded_chars':len(d.get(k) or '') for k in ('lyric','trans','roma')};usable=bool(d.get('lyric'))
                else:
                    access=next((c.get('accesskey') for c in raw if str(c.get('id'))==str(s['id'])),None)
                    d=get('https://lyrics.kugou.com/download',ver=1,client='pc',id=s['id'],accesskey=access,fmt='krc',charset='utf8')
                    encoded=base64.b64decode(d.get('content') or '')
                    if encoded[:4]!=b'krc1':usable=False
                    else:
                        key=bytes([64,71,97,119,94,50,116,71,81,54,49,45,206,210,110,105])
                        decoded=zlib.decompress(bytes(c ^ key[i%16] for i,c in enumerate(encoded[4:])),bufsize=1024*1024).decode('utf-8')
                        s['payload']={'krc_chars':len(decoded),'timed_rows':len(re.findall(r'^\[\d+,\d+\]',decoded,re.M)),'has_language_tag':'[language:' in decoded}
                        usable=s['payload']['timed_rows']>0
                if usable:selected=s;break
            providers[provider]={'search_count':len(rows),'fitting_count':len(fitting),'selected':selected,'requires_original_evidence':evidence[:3],'status':('lyric_payload' if selected else 'needs_evidence' if evidence else 'no_metadata_match')}
        except Exception as e:providers[provider]={'status':'request_error','error':str(e)[:180]}
    track['providers']=providers;print(track['region'],title, {k:v['status'] for k,v in providers.items()},flush=True);return track
if __name__=='__main__':
    out=ROOT/'docs/lyrics-catalogue-audit-2026-09-30.json'
    previous=json.loads(out.read_text(encoding='utf-8')) if out.exists() else {'tracks':[],'feeds':[]}
    completed=[t for t in previous['tracks'] if t.get('providers')]
    if '--replay' in sys.argv:
        with cf.ThreadPoolExecutor(max_workers=3) as executor: results=list(executor.map(probe,completed))
        previous['tracks']=results; previous['captured_at']=datetime.datetime.now(datetime.timezone.utc).isoformat(); previous['production_source_sha256']=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
        out.write_text(json.dumps(previous,ensure_ascii=False,indent=2),encoding='utf-8'); print('REPORT',out); sys.exit(0)
    sampled_regions={t['region'] for t in completed}
    tracks=[]; feeds=[]
    def chart(region):
        errors=[]
        for limit in (50,10):
            url=f'https://rss.marketingtools.apple.com/api/v2/{region}/music/most-played/{limit}/songs.json'
            try:return region,url,fetch(url)['feed'],errors
            except Exception as e:errors.append(str(e))
        return region,url,None,errors
    with cf.ThreadPoolExecutor(max_workers=4) as executor:
        charts=list(executor.map(chart,[r for r in ('us','jp','cn','kr','fr','gb') if r not in sampled_regions]))
    for region,url,feed,errors in charts:
        if not feed:feeds.append({'url':url,'errors':errors});continue
        feeds.append({'url':url,'updated':feed['updated'],'prior_errors':errors})
        rng=random.Random(20260930+sum(map(ord,region)))
        for rank,s in rng.sample(list(enumerate(feed['results'],1)),4):
            tracks.append({'region':region,'rank':rank,'id':s['id'],'title':s['name'],'artist':s['artistName'],'url':s['url']})
    with cf.ThreadPoolExecutor(max_workers=3) as executor:results=completed+list(executor.map(probe,tracks))
    report={'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'seed':20260930,'method':'Stratified random chart entries; failed feeds retained and retried at top-10 if top-50 unavailable. Actual sample size is tracks length; Apple metadata input; portable metadata replay only. No Spotify lyric reference, no Objective-C execution, no audio identity proof. Kana/Latin transform is excluded from replay. Payload availability does not prove every selected candidate is correct.','production_source_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'feeds':previous['feeds']+feeds,'tracks':results}
    out.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');print('REPORT',out,flush=True)
