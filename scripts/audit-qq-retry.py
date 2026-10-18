"""Fresh QQ-only replay of phone-log failures, plus bounded independent text checks."""
import datetime
import difflib
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit',root/'scripts/audit-selective-lyrics.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
tracks = [dict(title=t,artist=a,seconds=s) for t,a,s in [
    ('Moon Halo','HOYO-MiX',204), ('Attention','Charlie Puth',209), ('夏霞','Atarayo',229),
    ('晴天','周杰倫',269), ('Animals','Maroon 5',231)]]
rows=[]
for track in tracks:
    row=dict(track)
    try:
        selected=audit.search(track,'qqmusic',True)
        row['qq']=None if not selected else {k:v for k,v in selected.items() if k!='text'}
        row['status']='qq_missing' if not selected else 'qq_payload_verified_metadata'
        if selected:
            # Diagnostic reference only. The QQ-only runtime does not request this provider.
            other=None
            for provider in ['netease','kugou']:
                # Reference-text path handles regional artist spelling without guessed aliases.
                other=audit.search(track,provider,True,selected['text'])
                if other:
                    row['reference_provider']=provider
                    break
            if other:
                ratio=difflib.SequenceMatcher(None,selected['text'],other['text'],autojunk=False).ratio()
                row['independent_similarity']=round(ratio,4)
                row['status']='verified' if ratio>=0.70 else 'body_mismatch'
    except Exception as exc:row.update(status='request_error',error=str(exc)[:180])
    rows.append(row)
    print(track['title'],row['status'],row.get('independent_similarity',''),flush=True)
report=dict(captured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    scope='Fresh public QQ search (12 metadata rows), at most two lyric candidates. NetEase queried solely as diagnostic original-text reference. No iOS or audio verification.',
    tracks=rows,meme_rejected=not audit.title_match('Animals (金坷垃)','Animals'))
report['all_passed']=all(r['status']=='verified' for r in rows) and report['meme_rejected']
path=root/'docs/lyrics-qq-retry-2026-10-18.json'
path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print('REPORT',path,'ALL_PASSED',report['all_passed'])
raise SystemExit(0 if report['all_passed'] else 1)
