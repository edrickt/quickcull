#!/usr/bin/env bash
# Downloads raw sample fixtures (positive + negative) with sha256 pinning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/QuickCullCoreTests/Fixtures/raws"
mkdir -p "$DEST"
fetch() { # url sha256 name
  local url="$1" sum="$2" name="$3"
  echo "Fetching $name ..."
  curl -fsSL -o "$DEST/$name" "$url"
  echo "$sum  $DEST/$name" | shasum -a 256 -c -
}
fetch "https://raw.pixls.us/data/Canon/EOS%2030D/IMG_0062.CR2"        fb216f8df8d7abca4eb9d9f8dc594c1d2b69d0a6369fb8b4107743343c37144f img_0062.cr2
fetch "https://raw.pixls.us/data/Canon/Canon%20EOS%20M200/_MG_2233.CR3" 0585a468143c6606936d0ffbff1788c6c02e3610d8ecb50614e21492fbacd052 mg_2233.cr3
fetch "https://raw.pixls.us/data/Nikon/1%20J1/_DSC8140.NEF"          1d3b7c26b012cf585d46a28c9c83876d687a6e215b7d0bdf8d062c82ab626401 dsc8140.nef
fetch "https://raw.pixls.us/data/Sony/DSLR-A100/_DSC0258.ARW"        4df7981ac4baec9648b4f106751ea4b09a6e27bc70a15f8ef09bec051fec362d dsc0258.arw
fetch "https://raw.pixls.us/data/Fujifilm/FinePix%20E550/RAW_FUJI_E550.RAF" 82d1010a1eb8cdf4b2de7ca30a3a4db4e96f290536f06ed2798a67c1fe81e6ae fuji_e550.raf
fetch "https://raw.pixls.us/data/Olympus/C5050Z/RAW_OLYMPUS_C5050Z.ORF" f4b013e78204ebaadd740d93416080856b3c51ec154760e2e2de0e552873044a olympus_c5050z.orf
fetch "https://raw.pixls.us/data/Panasonic/DC-FZ45/P1000336.RW2"     30c02f392d1d0dfba93cff429172b768225f11da2ce6a6b40a195611d8486954 p1000336.rw2
fetch "https://raw.pixls.us/data/Pentax/K-01/_IGP2068.DNG"          4c9aac2ce2720154616ad7678385d1ec1f626d6464a1d5c6a5a4d821a78a608d pentax_k01.dng
fetch "https://raw.githubusercontent.com/exiftool/exiftool/master/t/images/CanonRaw.cr2" b5d3d26f3c85bcb35a52515eac060e2e362161893504013589ffd9ad2e9b004b bad_truncated.cr2
fetch "https://raw.githubusercontent.com/exiftool/exiftool/master/t/images/FujiFilm.raf" e12e30bd0cf5f160b82b93f043696c04d1d5f4628f1fdd19abdab9f8328d8bf0 bad_truncated.raf
fetch "https://raw.githubusercontent.com/exiftool/exiftool/master/t/images/PhaseOne.iiq" 306efa7671f144b56cc0af8f7e22e8d3f7e33efe422fd0135f894bd3739c27be bad_truncated.iiq
echo "All fixtures fetched."
