#!/bin/sh
# Writes a one-item Sparkle appcast to stdout.
# Usage: make-appcast.sh <version> <build> <zip-url> '<sign_update output>'
#   sign_update prints: sparkle:edSignature="..." length="..."
set -eu
VERSION="$1"; BUILD="$2"; URL="$3"; SIGNATURE="$4"
MIN_OS="13.0"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>JRG</title>
    <item>
      <title>JRG ${VERSION}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <enclosure url="${URL}" type="application/octet-stream" ${SIGNATURE} />
    </item>
  </channel>
</rss>
XML
