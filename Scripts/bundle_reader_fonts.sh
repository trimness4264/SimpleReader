#!/bin/sh
set -eu

cache_dir=$1
bundle_dir=$2
mkdir -p "$cache_dir" "$bundle_dir"

checksum_matches() {
    [ -f "$1" ] && [ "$(/usr/bin/shasum -a 256 < "$1" | cut -d ' ' -f 1)" = "$2" ]
}

bundle_font() {
    name=$1
    url=$2
    checksum=$3
    cached="$cache_dir/$name"

    if ! checksum_matches "$cached" "$checksum"; then
        echo "Downloading reader font: $name"
        download=$(mktemp "$cache_dir/$name.XXXXXX")
        trap 'rm -f "$download"' EXIT
        /usr/bin/curl --fail --location --silent --show-error --retry 2 \
            --connect-timeout 15 --max-time 120 --output "$download" "$url"
        if ! checksum_matches "$download" "$checksum"; then
            echo "error: SHA-256 mismatch for reader font $name" >&2
            exit 1
        fi
        mv -f "$download" "$cached"
        trap - EXIT
    fi

    cp -f "$cached" "$bundle_dir/$name"
}

wenkai=https://github.com/lxgw/LxgwWenKai/releases/download/v1.522
source_serif=https://raw.githubusercontent.com/adobe-fonts/source-serif/4.005R/TTF

bundle_font LXGWWenKai-Regular.ttf "$wenkai/LXGWWenKai-Regular.ttf" 39ad71264b588165b469e35e6afb162a378dacd1f95348160240ba9038ac3009
bundle_font SourceSerif4-Regular.ttf "$source_serif/SourceSerif4-Regular.ttf" e5a4ee6a3d87bb9024796be390c6771e2a0eb1883dae25effaf57ca01668e24b
bundle_font SourceSerif4-Bold.ttf "$source_serif/SourceSerif4-Bold.ttf" 7cf4f4e1ad74f45058d5bc61716b82560442fbdcd9d3654d2dea96bf6c683d86
bundle_font SourceSerif4-It.ttf "$source_serif/SourceSerif4-It.ttf" 9d2950a8f1da66e21502c35d646a1d2148e79f9ea43fd2158cf02f5232e7f430
bundle_font SourceSerif4-BoldIt.ttf "$source_serif/SourceSerif4-BoldIt.ttf" 7b215b37f8873f5579f3f8d2ded3ca7c588e2f435cd996605ebfc5befe2cd5eb
