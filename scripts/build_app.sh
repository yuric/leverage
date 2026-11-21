#!/bin/bash
# Builds dist/Leverage.app, the one app bundle the owner opens from Finder
# (milestone 2 plan PK-1). Run it once on the Mac the app will run on:
#
#   scripts/build_app.sh                 # everything, in this Mac's Docker too
#   scripts/build_app.sh --no-image      # the bundle only (CI's mac job)
#
# 1. Unless --no-image: builds the API image in
#    this Mac's Docker, and pulls the PostgreSQL image compose.yaml pins, by
#    its digest, so the app's first start needs no network.
# 2. Builds the app, helper, runner and MCP server in release mode.
# 3. Assembles dist/Leverage.app: the four programs in Contents/MacOS; in
#    Contents/Resources the icon and the compose file scripts/app_compose.py
#    makes from compose.yaml; Info.plist from mac/Packaging/Info.plist with
#    the version and the image tag.
# 4. Signs the bundle ad hoc (no notarization: the app works on the Mac it
#    was built on) and checks the signature and the Info.plist.
#
# <version> is Leverage::VERSION in api/config/application.rb.
# API_IMAGE_TAG can name an isolated image for a verification build. Options:
#   --no-image            skip step 1 (the tag is still written to Info.plist)
#   --scratch-path DIR    Swift's build folder (default: mac/.build)
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
image=1
scratch=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-image) image=0 ;;
    --scratch-path)
      [ $# -ge 2 ] || { echo "build_app: --scratch-path needs a folder" >&2; exit 2; }
      scratch=(--scratch-path "$2"); shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build_app: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf 'build_app: %s\n' "$*"; }

version=$(sed -n 's/^[[:space:]]*VERSION = "\([^"]*\)"[[:space:]]*$/\1/p' "$root/api/config/application.rb")
case "$version" in
  ''|*[!A-Za-z0-9._-]*|*$'\n'*)
    echo "build_app: no single Leverage::VERSION in api/config/application.rb" >&2; exit 1 ;;
esac
tag=${API_IMAGE_TAG:-$version}
case "$tag" in
  [-.]*|*[!A-Za-z0-9._-]*) echo "build_app: invalid API_IMAGE_TAG" >&2; exit 2 ;;
esac

# 1. The images, in this Mac's Docker.
if [ "$image" = 1 ]; then
  command -v docker >/dev/null || { echo "build_app: docker is not on PATH (or pass --no-image)" >&2; exit 1; }
  postgres=$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(postgres:[^[:space:]]*@sha256:[0-9a-f]\{64\}\)[[:space:]]*$/\1/p' "$root/compose.yaml")
  [ "$(printf '%s\n' "$postgres" | grep -c .)" = 1 ] \
    || { echo "build_app: compose.yaml does not pin exactly one postgres image by digest" >&2; exit 1; }
  say "building the API image leverage-api:$tag"
  docker build --tag "leverage-api:$tag" "$root/api"
  say "pulling $postgres"
  docker pull "$postgres"
fi

# 2. The four programs, in release mode, with every lane of the package.
say "building the Swift programs in release mode"
unset LEVERAGE_ONLY
for product in LeverageApp LeverageHelper LeverageRunner LeverageMCP; do
  swift build --package-path "$root/mac" ${scratch[@]+"${scratch[@]}"} -c release --product "$product"
done
bin=$(swift build --package-path "$root/mac" ${scratch[@]+"${scratch[@]}"} -c release --show-bin-path)

# 3. The bundle.
app="$root/dist/Leverage.app"
contents="$app/Contents"
say "assembling $app"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
for product in LeverageApp LeverageHelper LeverageRunner LeverageMCP; do
  install -m 0755 "$bin/$product" "$contents/MacOS/$product"
done

cp "$root/mac/Packaging/Info.plist" "$contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$contents/Info.plist"
plutil -replace LeverageAPIImageTag -string "$tag" "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"

python3 -I "$root/scripts/app_compose.py" --input "$root/compose.yaml" --output "$contents/Resources/compose.yaml"

work=$(mktemp -d "${TMPDIR:-/tmp}/leverage-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
sips -s format png "$root/mac/Packaging/AppIcon.svg" --out "$work/AppIcon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/AppIcon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$work/AppIcon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"

# 4. The ad-hoc signature: the embedded programs first, then the bundle,
#    which signs the app's own program.
say "signing ad hoc"
codesign --force --sign - --timestamp=none "$contents/MacOS/LeverageHelper"
codesign --force --sign - --timestamp=none "$contents/MacOS/LeverageRunner"
codesign --force --sign - --timestamp=none "$contents/MacOS/LeverageMCP"
codesign --force --sign - --timestamp=none "$app"

plutil -lint "$contents/Info.plist"
codesign --verify --strict "$app"
say "done: $app (version $version, image leverage-api:$tag$([ "$image" = 1 ] || printf ', image not built'))"
