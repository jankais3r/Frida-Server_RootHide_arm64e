#!/usr/bin/env bash
set -euo pipefail

src="${1:?Usage: build-roothide.sh SOURCE OUTPUT VERSION}"
out="${2:?Missing output directory}"
version="${3:?Missing version}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Expected a stable X.Y.Z version" >&2
  exit 1
}

# "-" is ad-hoc signing: no certificate, account or keychain required.
export IOS_CERTID="-"
export MACOS_CERTID="-"
export FRIDA_VERSION="$version"
export PYTHON
PYTHON="$(command -v python3)"

for tool in gmake dpkg-deb xcrun codesign lipo install_name_tool; do
  command -v "$tool" >/dev/null || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

mkdir -p "$out"
out="$(cd "$out" && pwd)"
cd "$src"
src="$(pwd)"

actual_version="$("$PYTHON" releng/frida_version.py)"
if [[ "$actual_version" != "$version" ]]; then
  echo "Version mismatch: requested $version, source says $actual_version" >&2
  exit 1
fi

core="$src/subprojects/frida-core"
packager="$core/tools/package-server-fruity.sh"
test -f "$packager"

# Older releases used frida; newer releases use frida-1.0.
if grep -Fq 'usr/lib/frida-1.0/frida-agent.dylib' "$packager"; then
  agent_dir="frida-1.0"
elif grep -Fq 'usr/lib/frida/frida-agent.dylib' "$packager"; then
  agent_dir="frida"
else
  echo "Unrecognized upstream agent layout; review packaging script" >&2
  exit 1
fi

work="$(mktemp -d "$src/roothide-work.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Build separate slices so the server can remain arm64e-only.
# Disable automatic compat builds: we supply the fat agent ourselves.
for arch in arm64 arm64e; do
  export MESON_BUILD_ROOT="$src/build-roothide-$arch"

  ./configure \
    --prefix=/var/jb \
    --host="ios-$arch" \
    -- \
    -Dserver=enabled \
    -Dgadget=disabled \
    -Dportal=disabled \
    -Dinject=disabled \
    -Dgraft_tool=disabled \
    -Dfrida_tools=disabled \
    -Dfrida_python=disabled \
    -Dfrida_node=disabled \
    -Dfrida_net=disabled \
    -Dfrida_swift=disabled \
    -Dfrida_qml=disabled \
    -Dbindir=usr/bin \
    -Dlibdir=usr/lib \
    -Dfrida-gum:tests=disabled \
    -Dfrida-core:tests=disabled \
    -Dfrida-core:assets=installed \
    -Dfrida-core:compat=disabled \
    "-Dfrida-core:asset_path_template=/var/jb/usr/lib/$agent_dir"

  # Only the agent is required from the arm64 build.
  gmake frida-agent

  built_core="$MESON_BUILD_ROOT/subprojects/frida-core"
  cp "$built_core/lib/agent/frida-agent.dylib" \
    "$work/frida-agent-$arch.dylib"

  if [[ "$arch" == arm64e ]]; then
    gmake frida-server
    cp "$built_core/server/frida-server" "$work/frida-server"
  fi

  # Reclaim disk space before building the next architecture.
  rm -rf "$MESON_BUILD_ROOT"
done

unset MESON_BUILD_ROOT

# Follow the guide's RootHide staging arrangement.
prefix="$work/stage/var/jb"
mkdir -p "$prefix/usr/bin" "$prefix/usr/lib/$agent_dir"

server="$prefix/usr/bin/frida-server"
agent="$prefix/usr/lib/$agent_dir/frida-agent.dylib"

cp "$work/frida-server" "$server"

lipo -create \
  "$work/frida-agent-arm64.dylib" \
  "$work/frida-agent-arm64e.dylib" \
  -output "$agent"

install_name_tool -id FridaAgent "$agent"
chmod 755 "$server" "$agent"

# Retain upstream server entitlements, without a developer certificate.
codesign --force --sign "-" \
  --timestamp=none \
  --generate-entitlement-der \
  --entitlements "$core/server/frida-server.xcent" \
  "$server"

# Re-sign after merging slices and changing the install name.
codesign --force --sign "-" \
  --timestamp=none \
  --generate-entitlement-der \
  "$agent"

codesign --verify --verbose "$server"
codesign --verify --verbose "$agent"

# Explicit architecture checks.
test "$(lipo -archs "$server")" = "arm64e"
lipo "$agent" -verify_arch arm64 arm64e

deb="$out/frida_${version}_iphoneos-arm64e.deb"

# Pass the INNER prefix, exactly as the guide does for RootHide.
sh -eu "$packager" "iphoneos-arm64e" "$prefix" "$deb"

test -s "$deb"
test "$(dpkg-deb -f "$deb" Architecture)" = "iphoneos-arm64e"
test "$(dpkg-deb -f "$deb" Version)" = "$version"

# Verify the actual packaged payload, not just the staging files.
unpacked="$work/unpacked"
dpkg-deb -x "$deb" "$unpacked"

test -f "$unpacked/usr/sbin/frida-server"
test -f "$unpacked/usr/lib/$agent_dir/frida-agent.dylib"
test -f "$unpacked/Library/LaunchDaemons/re.frida.server.plist"
test ! -d "$unpacked/var/jb"

test "$(lipo -archs "$unpacked/usr/sbin/frida-server")" = "arm64e"
lipo "$unpacked/usr/lib/$agent_dir/frida-agent.dylib" \
  -verify_arch arm64 arm64e

codesign --verify "$unpacked/usr/sbin/frida-server"
codesign --verify "$unpacked/usr/lib/$agent_dir/frida-agent.dylib"

{
  echo "Frida version: $version"
  echo "Upstream commit: $(git rev-parse HEAD)"
  echo "Runner architecture: $(uname -m)"
  xcodebuild -version
  echo "Server architectures: $(lipo -archs "$server")"
  echo "Agent architectures: $(lipo -archs "$agent")"
  echo
  git submodule status --recursive
} > "$out/BUILD-INFO.txt"

(
  cd "$out"
  shasum -a 256 \
    "frida_${version}_iphoneos-arm64e.deb" \
    BUILD-INFO.txt > SHA256SUMS
)

dpkg-deb --info "$deb"
echo "Built: $deb"
