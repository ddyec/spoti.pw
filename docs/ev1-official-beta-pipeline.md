# EV1 → official spoti.pw 1.0 Beta

This branch adds packaging only. It does not compile the old public tag or bring
in the prior custom lyrics branch. The official release kit supplies the actual
1.0.0-beta.1 implementation, including QQ Music and KuGou.

1. EEVEE branch: `ddyec/EeveeSpotifyReincarnated`,
   `feat/ev1-spoti-companion-20261019`; run **Build IPA (NO PATCH)** with the
   user's vanilla decrypted Spotify 9.1.90 URL. The artifact is `EV1-IPA`.
2. On this branch run **EV1 then official spoti.pw Beta**, supplying that
   successful EEVEE Action run ID. This downloads that exact intermediate IPA,
   checks its provenance and kit-supported version, applies the official kit,
   and uploads the final IPA and preservation report as an Actions artifact.

The script verifies existing main-executable dependencies and compares EEVEE's
binary/framework/resource bytes before and after patching. It adds a strong
dependency from spotifyglass to the existing EEVEE load path. This gives the
initializer order an explicit dependency: EEVEE writes `lyricsSource=4` before
Chroma's constructors cache their decision about the lyrics owner. Only Mach-O
header padding is modified; the official dylib's section contents are checked
unchanged. If there is no padding, resources are missing, or dependencies were
removed, packaging stops.

The official Chroma kit still warns about EEVEE coexistence. Retaining the warning
is appropriate until device acceptance. A build and preservation report do not
prove that all remaining private-class hooks are compatible at runtime.

Sign the completed IPA with the user's normal signer, then test playback/login,
one appearance owner, QQ-only and QQ-first lyrics, track changes and a relaunch
after old settings have been imported. Use the EV1 intermediate IPA to isolate
EEVEE behavior from the combined app if a regression appears.
