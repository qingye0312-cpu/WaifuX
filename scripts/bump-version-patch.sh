#!/usr/bin/env bash
# 将 VERSION 的末位 patch +1，并同步到 project.yml + Docs/appcast.xml，随后 git add。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VFILE="$ROOT/VERSION"
v=$(tr -d '[:space:]' < "$VFILE")
major=$(echo "$v" | cut -d. -f1)
minor=$(echo "$v" | cut -d. -f2)
patch=$(echo "$v" | cut -d. -f3)
if [ -z "$patch" ]; then patch=0; fi
patch=$((patch + 1))
newv="$major.$minor.$patch"
printf '%s\n' "$newv" > "$VFILE"
bash "$ROOT/scripts/sync-version.sh"

# 同步 Docs/appcast.xml（Sparkle 自动更新 feed）
# 从 git commit（subject + body）自动生成更新内容（与 CI release.yml 逻辑一致）
APPLECAST="$ROOT/Docs/appcast.xml"
if [ -f "$APPLECAST" ]; then
  PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

  PREV_TAG=$(cd "$ROOT" && git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
  # subject 作标题，body 每行作嵌套 <li>（见 generate-appcast-changelog.py）
  if [ -n "$PREV_TAG" ]; then
    export APPCAST_DESC=$(cd "$ROOT" && python3 "$ROOT/scripts/generate-appcast-changelog.py" \
      --format html --version "$newv" --since "$PREV_TAG")
  else
    export APPCAST_DESC=$(cd "$ROOT" && python3 "$ROOT/scripts/generate-appcast-changelog.py" \
      --format html --version "$newv")
  fi
  export APPCAST_VERSION="$newv"
  export APPCAST_PUB_DATE="$PUB_DATE"

  # 用 Python 重写整个 appcast.xml（@@ 占位，避免 body 中 {} 触发 format）
  cd "$ROOT" && python3 -c "
import os
version = os.environ['APPCAST_VERSION']
pub_date = os.environ['APPCAST_PUB_DATE']
desc = os.environ.get('APPCAST_DESC', '')
xml = '''<?xml version=\"1.0\" encoding=\"utf-8\"?>
<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">
  <channel>
    <title>WaifuX</title>
    <link>https://jipika.github.io/WaifuX/appcast.xml</link>
    <description>WaifuX Updates</description>
    <language>zh</language>
    <item>
      <title>Version @@VERSION@@</title>
      <sparkle:version>@@VERSION@@</sparkle:version>
      <sparkle:shortVersionString>@@VERSION@@</sparkle:shortVersionString>
      <pubDate>@@PUB_DATE@@</pubDate>
      <description><![CDATA[
@@DESC@@
      ]]></description>
      <enclosure
        url=\"https://github.com/jipika/WaifuX/releases/download/v@@VERSION@@/WaifuX.dmg\"
        type=\"application/octet-stream\"
        length=\"0\"
      />
    </item>
  </channel>
</rss>
'''
xml = (xml
  .replace('@@VERSION@@', version)
  .replace('@@PUB_DATE@@', pub_date)
  .replace('@@DESC@@', desc))
with open('Docs/appcast.xml', 'w') as f:
    f.write(xml)
"

  echo "Synced appcast.xml -> $newv (changelog from ${PREV_TAG:-初始版本})" >&2
fi

cd "$ROOT" && git add VERSION project.yml Docs/appcast.xml
echo "githooks: 合并自动递增版本 -> $newv" >&2
