#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=${XBRL_WORK:-"$ROOT/tests/xbrl-taxonomies"}
SOURCES=${XBRL_SOURCES:-"$WORK/sources.txt"}
CACHE=${XBRL_CACHE:-"$WORK/cache"}
DOWNLOADS=${XBRL_DOWNLOADS:-"$WORK/downloads"}
PAGES=${XBRL_PAGES:-"$WORK/pages"}
MANIFEST=${XBRL_MANIFEST:-"$WORK/manifest.urls"}
UA=${XBRL_USER_AGENT:-"Mozilla/5.0 HaXml-xsdtohaskell/1.0 taxonomy compatibility check"}

mkdir -p "$CACHE" "$DOWNLOADS" "$PAGES"
: > "$MANIFEST.raw"
: > "$MANIFEST.dirs.raw"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        exit 1
    fi
}

require_tool curl
require_tool unzip
require_tool sed
require_tool sort

url_scheme() {
    case "$1" in
        https://*) printf '%s\n' https ;;
        http://*)  printf '%s\n' http ;;
        *)         return 1 ;;
    esac
}

url_no_scheme() {
    case "$1" in
        https://*) printf '%s\n' "${1#https://}" ;;
        http://*)  printf '%s\n' "${1#http://}" ;;
        *)         return 1 ;;
    esac
}

url_host() {
    rest=$(url_no_scheme "$1")
    printf '%s\n' "${rest%%/*}"
}

url_path() {
    rest=$(url_no_scheme "$1")
    case "$rest" in
        */*) printf '%s\n' "/${rest#*/}" ;;
        *)   printf '%s\n' "/" ;;
    esac
}

url_dir_path() {
    path=$(url_path "$1")
    case "$path" in
        */) printf '%s\n' "${path#/}" ;;
        */*) printf '%s\n' "${path%/*}" | sed 's,^/,,' ;;
        *) printf '%s\n' "" ;;
    esac
}

file_key() {
    printf '%s' "$1" | sed 's,^[a-z][a-z]*://,,; s,[/?#&=:%],_,g'
}

fetch_html() {
    url=$1
    out=$2
    if [ ! -s "$out" ] || [ "${XBRL_REFRESH:-0}" = 1 ]; then
        curl -fsSL --retry 3 -A "$UA" -o "$out" "$url"
    fi
}

html_links() {
    base=$1
    file=$2
    scheme=$(url_scheme "$base")
    host=$(url_host "$base")
    dir=$base
    case "$dir" in
        */) ;;
        *) dir=${dir%/*}/ ;;
    esac

    sed -n \
        -e 's/&amp;/\&/g' \
        -e 's/.*href="\([^"]*\)".*/\1/p' \
        -e "s/.*href='\([^']*\)'.*/\1/p" \
        "$file" |
    while IFS= read -r href; do
        case "$href" in
            ""|\#*|mailto:*|javascript:*) ;;
            http://*|https://*) printf '%s\n' "$href" ;;
            /*) printf '%s://%s%s\n' "$scheme" "$host" "$href" ;;
            *) printf '%s%s\n' "$dir" "$href" ;;
        esac
    done
}

record_links_from_html() {
    base=$1
    html=$2
    html_links "$base" "$html" |
    while IFS= read -r link; do
        clean=${link%%#*}
        clean=${clean%%\?*}
        case "$clean" in
            *[Ss]ample*.zip|*[Pp]ublic-[Ss]amples*.zip)
                ;;
            http://*.zip|https://*.zip|http://*.xsd|https://*.xsd)
                printf '%s\n' "$clean" >> "$MANIFEST.raw"
                ;;
            https://xbrl.sec.gov/*/|https://xbrl.fasb.org/*/)
                printf '%s\n' "$clean" >> "$MANIFEST.dirs.raw"
                ;;
        esac
    done
}

while IFS= read -r source; do
    case "$source" in
        ""|\#*) continue ;;
    esac
    clean=${source%%#*}
    clean=${clean%%\?*}
    case "$clean" in
        *[Ss]ample*.zip|*[Pp]ublic-[Ss]amples*.zip)
            ;;
        http://*.zip|https://*.zip|http://*.xsd|https://*.xsd)
            printf '%s\n' "$clean" >> "$MANIFEST.raw"
            ;;
        https://xbrl.sec.gov/*/|https://xbrl.fasb.org/*/)
            printf '%s\n' "$clean" >> "$MANIFEST.dirs.raw"
            ;;
        http://*|https://*)
            page="$PAGES/$(file_key "$clean").html"
            echo "Fetching page $clean"
            if fetch_html "$clean" "$page"; then
                record_links_from_html "$clean" "$page"
            else
                echo "warning: could not fetch page $clean" >&2
            fi
            ;;
        *)
            echo "skipping unrecognized source: $source" >&2
            ;;
    esac
done < "$SOURCES"

sort -u "$MANIFEST.dirs.raw" > "$MANIFEST.dirs.queue"
: > "$MANIFEST.dirs.seen"

while [ -s "$MANIFEST.dirs.queue" ]; do
    dir=$(sed -n '1p' "$MANIFEST.dirs.queue")
    sed '1d' "$MANIFEST.dirs.queue" > "$MANIFEST.dirs.next"
    mv "$MANIFEST.dirs.next" "$MANIFEST.dirs.queue"

    if grep -Fx "$dir" "$MANIFEST.dirs.seen" >/dev/null 2>&1; then
        continue
    fi
    printf '%s\n' "$dir" >> "$MANIFEST.dirs.seen"

    page="$PAGES/$(file_key "$dir").html"
    echo "Crawling directory $dir"
    if ! fetch_html "$dir" "$page"; then
        echo "warning: could not fetch directory $dir" >&2
        continue
    fi

    html_links "$dir" "$page" |
    while IFS= read -r link; do
        clean=${link%%#*}
        clean=${clean%%\?*}
        case "$clean" in
            *[Ss]ample*.zip|*[Pp]ublic-[Ss]amples*.zip)
                ;;
            http://*.zip|https://*.zip|http://*.xsd|https://*.xsd)
                printf '%s\n' "$clean" >> "$MANIFEST.raw"
                ;;
            "$dir"*/)
                case "$clean" in
                    "$dir../"*|"$dir./"*) ;;
                    *) printf '%s\n' "$clean" >> "$MANIFEST.dirs.queue" ;;
                esac
                ;;
        esac
    done
    sort -u "$MANIFEST.dirs.queue" > "$MANIFEST.dirs.sorted"
    mv "$MANIFEST.dirs.sorted" "$MANIFEST.dirs.queue"
done

sort -u "$MANIFEST.raw" > "$MANIFEST"

cache_path_for_url() {
    url=$1
    scheme=$(url_scheme "$url")
    host=$(url_host "$url")
    path=$(url_path "$url")
    printf '%s/%s/%s%s\n' "$CACHE" "$scheme" "$host" "$path"
}

download_path_for_url() {
    url=$1
    scheme=$(url_scheme "$url")
    host=$(url_host "$url")
    path=$(url_path "$url")
    printf '%s/%s/%s%s\n' "$DOWNLOADS" "$scheme" "$host" "$path"
}

copy_archive_file() {
    zip_url=$1
    tmp_file=$2
    rel=$3
    scheme=$(url_scheme "$zip_url")
    host=$(url_host "$zip_url")
    dir_path=$(url_dir_path "$zip_url")
    zip_name=${zip_url##*/}
    zip_stem=${zip_name%.zip}

    case "$rel" in
        */) return 0 ;;
        xbrl.sec.gov/*|xbrl.fasb.org/*|xbrl.ifrs.org/*)
            target="$CACHE/$scheme/$rel"
            ;;
        [0-9][0-9][0-9][0-9]/xbrl.sec.gov/*|[0-9][0-9][0-9][0-9]/xbrl.fasb.org/*|[0-9][0-9][0-9][0-9]/xbrl.ifrs.org/*)
            target="$CACHE/$scheme/${rel#*/}"
            ;;
        "$zip_stem"/*)
            target="$CACHE/$scheme/$host/$dir_path/${rel#*/}"
            ;;
        *)
            target="$CACHE/$scheme/$host/$dir_path/$rel"
            ;;
    esac

    mkdir -p "$(dirname "$target")"
    [ ! -e "$target" ] || chmod u+w "$target" 2>/dev/null || true
    cp -p "$tmp_file/$rel" "$target"
    chmod u+w "$target" 2>/dev/null || true
}

extract_zip() {
    url=$1
    zip=$2
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/haxml-xbrl.XXXXXX")
    unzip -oq "$zip" -d "$tmp"
    find "$tmp" -type f | sort |
    while IFS= read -r file; do
        rel=${file#"$tmp"/}
        copy_archive_file "$url" "$tmp" "$rel"
    done
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
}

while IFS= read -r url; do
    case "$url" in
        *.xsd)
            target=$(cache_path_for_url "$url")
            mkdir -p "$(dirname "$target")"
            if [ ! -s "$target" ] || [ "${XBRL_REFRESH:-0}" = 1 ]; then
                echo "Downloading XSD $url"
                curl -fsSL --retry 3 -A "$UA" -o "$target" "$url"
            fi
            ;;
        *.zip)
            zip=$(download_path_for_url "$url")
            mkdir -p "$(dirname "$zip")"
            if [ ! -s "$zip" ] || [ "${XBRL_REFRESH:-0}" = 1 ]; then
                echo "Downloading package $url"
                curl -fsSL --retry 3 -A "$UA" -o "$zip" "$url"
            fi
            echo "Extracting package $url"
            extract_zip "$url" "$zip"
            ;;
    esac
done < "$MANIFEST"

xsd_count=$(find "$CACHE" -type f -name '*.xsd' | wc -l | sed 's/^ *//')
echo "Cached $xsd_count XSD files under $CACHE"
