# Chinese Mod Settings

Based on the tested lyric timeline fix `0d93ca0`. In a Chinese preferred-language
environment (`zh`, including `zh-Hans` and `zh-Hant`), mod-owned settings text now
uses a Simplified Chinese catalogue. Other languages retain the original English.
The language follows iOS's app language preference and is read at presentation;
there is no new preference key or migration.

The compiled catalogue includes the main settings entry, page titles, grouped
headers/footers, options, dynamic status labels, alerts and actions, restart/reset
prompts, lyrics/source/translation/meaning controls, player/background settings,
navbar editing, audio effects, privacy/labs/flags, updates/backup and diagnostics.
Formatting templates are translated before interpolation, preserving parameter
ordering and types. Footer measurement uses the translated text. Artist names,
custom navbar titles and imported file names use an explicit raw presentation
path. Preference keys, flag identifiers, URIs, keys and saved values are unchanged.
Legal license texts and external release notes retain their original wording.

`localization/zh-Hans.json` is the editable source. Run
`python3 scripts/generate-localization.py` after edits. The generated
`Core/SGChinese.inc` is compiled into the tweak, so packaging requires no extra
resource bundle. Only mod-owned settings use the localized alert factories;
Spotify's UIKit classes are not swizzled.

`python3 scripts/test-localization.py` checks catalogue consistency and format
arguments, and on macOS compiles the production Foundation lookup to verify
Chinese language selection, fallback, nil/unknown text, identifiers and dynamic
formatting. It is called by the existing identity-regression workflow entry.
Layer checks and the existing lyric/layout regression also remain in place.

Device acceptance: install the resulting IPA using the normal signer, restart,
and open Mod Settings with Spotify/iOS configured for Chinese. Check the main
page, Lyrics > Sources, Player > Background, Audio effects, reset/restart prompts,
and long descriptions. Switch the app language to English and restart to verify
the original English fallback. Existing options should retain their saved state.
