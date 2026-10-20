#!/bin/bash
# Builds the client tools Backup and Restore run, from the vendors' source, into build/tools.
# Usage: scripts/build-tools.sh [--clean]
# Run outside Claude Code's sandbox. A clean build takes a while; scripts/build-app.sh copies
# the result into Moonrow.app (Contents/Helpers/tools, Contents/Resources/tools.json).
#
# Every tool is universal (arm64 and x86_64), runs on macOS 14 and needs nothing outside the
# folder: one kit per release, plus the libraries they share in lib/ (the tools find them through
# the rpath @loader_path/../lib).
#
#   tools.json               the kits: id, product, version, family, tools
#   lib/                     libpq (PostgreSQL 18's, for every PostgreSQL kit), OpenSSL
#   postgresql-10 … -18/     pg_dump, pg_restore, psql
#   mysql-57/, mysql-80/     mysqldump, mysql
#   mariadb-123/             mariadb-dump, mariadb
# (Kit folders have no dots: codesign takes a dotted folder in Contents/Helpers for a bundle.)
#   Licenses/                each project's licence, and SOURCES (where the code came from)
#
# Downloads and work folders are kept in build/tools-src. A part already built from the same
# sources (its archive, the patches for it, the parts it links and CMake) isn't built again; a
# change to a part's build options alone doesn't rebuild it, so use --clean then (it starts over).
# build/tools/.stamp holds this script's hash: when it matches, nothing runs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

work="$root/build/tools-src"
out="$root/build/tools"
patches="$root/scripts/tools-patches"
stamp="$( (cat "$0"; if [ -d "$patches" ]; then find "$patches" -type f | sort | xargs cat; fi) | shasum -a 256 | cut -c1-16)"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$work/build" "$work/deps" "$work/stage" "$out"
elif [ -f "$out/.stamp" ] && [ "$(cat "$out/.stamp")" = "$stamp" ]; then
  echo "build/tools is up to date"
  exit 0
fi

export MACOSX_DEPLOYMENT_TARGET=14.0
jobs="$(sysctl -n hw.ncpu)"
archs="arm64 x86_64"
host_arch="$(uname -m)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"

# name, url, sha256
openssl=(openssl-3.5.9.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
  603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a)
zstd=(zstd-1.5.7.tar.gz https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
  eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3)
lz4=(lz4-1.10.0.tar.gz https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz
  537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b)
cmake=(cmake-3.31.12-macos-universal.tar.gz https://github.com/Kitware/CMake/releases/download/v3.31.12/cmake-3.31.12-macos-universal.tar.gz
  799af7fd545db9bf1b9cfe72f8095880e727a2d4e0df0e3dffc3bc7b95c2d3b0)
mysql57=(mysql-boost-5.7.44.tar.gz https://cdn.mysql.com/archives/mysql-5.7/mysql-boost-5.7.44.tar.gz
  b8fe262c4679cb7bbc379a3f1addc723844db168628ce2acf78d33906849e491)
mysql80=(mysql-boost-8.0.46.tar.gz https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-boost-8.0.46.tar.gz
  dff4332ee7f8f37fc0516c66763600a22a81c8192c743c477b6484206e314f2f)
# Oracle moves a release to the archive once the next one is out.
mysql80_archive=https://cdn.mysql.com/archives/mysql-8.0/mysql-boost-8.0.46.tar.gz
mariadb=(mariadb-12.3.3.tar.gz https://archive.mariadb.org/mariadb-12.3.3/source/mariadb-12.3.3.tar.gz
  e99d739fd4a55f9a11dea7bd2287a262673e287550af3071c8469dd2bec0c163)
# version, sha256 (ftp.postgresql.org/pub/source/v<version>/postgresql-<version>.tar.bz2)
postgres_versions="
10.23 94a4b2528372458e5662c18d406629266667c437198160a18cdfd2c4a4d6eee9
11.22 2cb7c97d7a0d7278851bbc9c61f467b69c094c72b81740b751108e7892ebe1f0
12.22 8df3c0474782589d3c6f374b5133b1bd14d168086edbc13c6e72e67dd4527a3b
13.23 6ec3c82726af92b7dec873fa1cdf881eca92a4219787dfad05acb6b10e041fd6
14.24 a7fa7ed3d558172355f51406097a7bd4f6b473be80f311ef7cda96bf383d8897
15.19 e1a64a87a46b825b88c082e4518161a47aab53c45694964f8ba1df28f7859f89
16.15 c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed
17.11 dd27f2b3c59e73ed14aa3324901242bf69a032a6347805f274e6260322d42979
18.6 555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f
"

mkdir -p "$work/dl" "$work/build" "$work/stage" "$work/deps"
sources="$work/SOURCES"
: > "$sources"

# fetch <name> <url> <sha256> [fallback url]: downloads once, checks the hash every time.
fetch() {
  local file="$work/dl/$1"
  if [ ! -f "$file" ]; then
    curl -fsSL --retry 3 -o "$file.part" "$2" || { [ -n "${4:-}" ] && curl -fsSL --retry 3 -o "$file.part" "$4"; }
    mv "$file.part" "$file"
  fi
  echo "$3  $file" | shasum -a 256 -c --status || { echo "error: $1 doesn't match its SHA-256" >&2; exit 1; }
  printf '%s\n  %s\n  sha256 %s\n' "$1" "$2" "$3" >> "$sources"
}

# unpack <tarball> <folder>: a fresh copy of the source in build/<folder>.
unpack() {
  rm -rf "$work/build/$2"
  mkdir -p "$work/build/$2"
  tar -xf "$work/dl/$1" -C "$work/build/$2" --strip-components 1
  # Patches for a release are in tools-patches/<its folder, without the architecture>.
  local name="${2%-arm64}"
  name="${name%-x86_64}"
  if [ -d "$patches/$name" ]; then
    for p in "$patches/$name"/*.patch; do patch -s -d "$work/build/$2" -p1 < "$p"; done
  fi
}

triple() { [ "$1" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin; }

# relink <file>: OpenSSL and libpq by @rpath, the rpath to lib/, nothing from the build folders.
relink() {
  local f="$1" dep base
  for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}'); do
    base="$(basename "$dep")"
    case "$base" in
      libssl.3.dylib|libcrypto.3.dylib) [ "$dep" = "@rpath/$base" ] || install_name_tool -change "$dep" "@rpath/$base" "$f" ;;
      libpq.5*.dylib) [ "$dep" = "@rpath/libpq.5.dylib" ] || install_name_tool -change "$dep" "@rpath/libpq.5.dylib" "$f" ;;
    esac
  done
  # A path given twice at link time is there twice; each delete takes one (in every slice).
  local rp
  while rp="$(otool -l "$f" | awk '/cmd LC_RPATH/ {getline; getline; print $2; exit}')" && [ -n "$rp" ]; do
    install_name_tool -delete_rpath "$rp" "$f"
  done
  case "$f" in
    *.dylib) ;;
    *) install_name_tool -add_rpath @loader_path/../lib "$f" ;;
  esac
}

# Each part built is recorded in stage/.<part>.done with what it was built from: its archives
# and their SHA-256, a hash of its patches, and what was recorded for the parts it builds on. A
# part is built again when that changes, so a new version or hash rebuilds only the parts that
# use it. (Markers from before, stage/.<part>-done, said only the major version; they're dropped.)
rm -f "$work"/stage/.*-done
# patched <folder>: a hash of the patches for a release (tools-patches/<folder>), or "none".
patched() {
  if [ -d "$patches/$1" ]; then cat "$patches/$1"/*.patch | shasum -a 256 | cut -c1-16; else echo none; fi
}
is_built() { [ "$(cat "$work/stage/.$1.done" 2>/dev/null)" = "$2" ]; }
mark_built() { printf '%s\n' "$2" > "$work/stage/.$1.done"; }

# MARK: - Build tools

fetch "${cmake[@]}"
if [ ! -x "$work/cmake/CMake.app/Contents/bin/cmake" ]; then
  rm -rf "$work/cmake"
  mkdir -p "$work/cmake"
  tar -xf "$work/dl/${cmake[0]}" -C "$work/cmake" --strip-components 1
fi
cmake_bin="$work/cmake/CMake.app/Contents/bin/cmake"
cmake_from="${cmake[0]} ${cmake[2]}"

# MARK: - OpenSSL, zstd, lz4 (universal, in deps/)

deps="$work/deps"
fetch "${openssl[@]}"
openssl_from="${openssl[0]} ${openssl[2]} patches $(patched openssl)"
if ! is_built openssl "$openssl_from"; then
  for arch in $archs; do
    unpack "${openssl[0]}" "openssl-$arch"
    (
      cd "$work/build/openssl-$arch"
      # The system's /etc/ssl: its cert.pem holds macOS's root certificates.
      ./Configure "darwin64-$arch-cc" --prefix="$work/build/openssl-$arch-install" --libdir=lib --openssldir=/private/etc/ssl \
        shared no-tests no-docs no-apps no-engine no-module "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
      make -j"$jobs" build_libs >/dev/null
      make install_dev >/dev/null
    )
  done
  rm -rf "$deps/include/openssl" && mkdir -p "$deps/include" "$deps/lib"
  cp -R "$work/build/openssl-arm64-install/include/openssl" "$deps/include/"
  # Both builds are LP64 and configure the same; check the headers agree.
  diff -r "$work/build/openssl-arm64-install/include/openssl" "$work/build/openssl-x86_64-install/include/openssl" >/dev/null
  for lib in libssl.3.dylib libcrypto.3.dylib; do
    lipo -create "$work/build/openssl-arm64-install/lib/$lib" "$work/build/openssl-x86_64-install/lib/$lib" -output "$deps/lib/$lib"
    install_name_tool -id "@rpath/$lib" "$deps/lib/$lib"
  done
  install_name_tool -change "$work/build/openssl-arm64-install/lib/libcrypto.3.dylib" @rpath/libcrypto.3.dylib "$deps/lib/libssl.3.dylib"
  install_name_tool -change "$work/build/openssl-x86_64-install/lib/libcrypto.3.dylib" @rpath/libcrypto.3.dylib "$deps/lib/libssl.3.dylib" 2>/dev/null || true
  ln -sf libssl.3.dylib "$deps/lib/libssl.dylib"
  ln -sf libcrypto.3.dylib "$deps/lib/libcrypto.dylib"
  mark_built openssl "$openssl_from"
fi

fetch "${zstd[@]}"
fetch "${lz4[@]}"
compression_from="${zstd[0]} ${zstd[2]} patches $(patched zstd); ${lz4[0]} ${lz4[2]} patches $(patched lz4)"
if ! is_built compression "$compression_from"; then
  unpack "${zstd[0]}" zstd
  make -C "$work/build/zstd/lib" -j"$jobs" libzstd.a CFLAGS="-O2 -arch arm64 -arch x86_64" >/dev/null
  cp "$work/build/zstd/lib/libzstd.a" "$deps/lib/"
  cp "$work/build/zstd/lib/zstd.h" "$work/build/zstd/lib/zstd_errors.h" "$work/build/zstd/lib/zdict.h" "$deps/include/"
  unpack "${lz4[0]}" lz4
  make -C "$work/build/lz4/lib" -j"$jobs" liblz4.a CFLAGS="-O2 -arch arm64 -arch x86_64" >/dev/null
  cp "$work/build/lz4/lib/liblz4.a" "$deps/lib/"
  cp "$work/build/lz4/lib/lz4.h" "$work/build/lz4/lib/lz4hc.h" "$work/build/lz4/lib/lz4frame.h" "$deps/include/"
  mark_built compression "$compression_from"
fi

# MARK: - PostgreSQL

# One configure and build per architecture (configure picks code per CPU, e.g. its CRC-32C),
# cross-compiling the one this Mac doesn't run; nothing built is run during the build.
# postgres <version> <what it's built from>
postgres() {
  local version="$1" major="${1%%.*}" id="postgresql-${1%%.*}" from="$2"
  local stage="$work/stage/$id"
  is_built "$id" "$from" && return
  rm -rf "$stage" && mkdir -p "$stage"
  for arch in $archs; do
    local dir="postgresql-$version-$arch"
    unpack "postgresql-$version.tar.bz2" "$dir"
    local flags=(--prefix=/opt/moonrow-postgresql --without-readline --without-icu --with-openssl --with-zlib
                 --without-gssapi --without-ldap --without-pam --without-libxml --without-perl --without-python --without-tcl)
    if [ "$major" -ge 14 ]; then flags+=(--with-lz4); fi
    if [ "$major" -ge 15 ]; then flags+=(--with-zstd); fi
    if [ "$arch" != "$host_arch" ]; then flags+=(--host="$(triple "$arch")" --build="$(triple "$host_arch")"); fi
    (
      cd "$work/build/$dir"
      # Functions newer than the deployment target aren't used (old branches check by linking).
      ac_cv_func_strchrnul=no ac_cv_func_memset_s=yes \
      CC="clang -arch $arch" CFLAGS="-O2 -isysroot $sdk" \
      CPPFLAGS="-I$deps/include" LDFLAGS="-L$deps/lib -Wl,-rpath,$deps/lib" \
      LZ4_CFLAGS="-I$deps/include" LZ4_LIBS="$deps/lib/liblz4.a" \
      ZSTD_CFLAGS="-I$deps/include" ZSTD_LIBS="$deps/lib/libzstd.a" \
        ./configure "${flags[@]}" >"$work/build/$dir.configure.log" 2>&1 \
        || { tail -30 "$work/build/$dir.configure.log"; tail -60 config.log; exit 1; }
      # Generated headers first, alone: old branches race on them under -j.
      { make -C src/backend generated-headers || make -C src/backend submake-errcodes; } >"$work/build/$dir.make.log" 2>&1 \
        || { tail -40 "$work/build/$dir.make.log"; exit 1; }
      make -C src/bin/pg_dump -j"$jobs" >>"$work/build/$dir.make.log" 2>&1 || { tail -40 "$work/build/$dir.make.log"; exit 1; }
      make -C src/bin/psql -j"$jobs" >>"$work/build/$dir.make.log" 2>&1 || { tail -40 "$work/build/$dir.make.log"; exit 1; }
      if [ "$major" = 18 ]; then make -C src/interfaces/libpq -j"$jobs" >>"$work/build/$dir.make.log" 2>&1; fi
    )
  done
  for tool in pg_dump pg_restore psql; do
    local path=src/bin/pg_dump/$tool
    [ "$tool" = psql ] && path=src/bin/psql/psql
    lipo -create "$work/build/postgresql-$version-arm64/$path" "$work/build/postgresql-$version-x86_64/$path" -output "$stage/$tool"
    relink "$stage/$tool"
  done
  if [ "$major" = 18 ]; then
    lipo -create "$work/build/postgresql-$version-arm64/src/interfaces/libpq/libpq.5.dylib" \
      "$work/build/postgresql-$version-x86_64/src/interfaces/libpq/libpq.5.dylib" -output "$stage/libpq.5.dylib"
    install_name_tool -id @rpath/libpq.5.dylib "$stage/libpq.5.dylib"
    relink "$stage/libpq.5.dylib"
  fi
  cp "$work/build/postgresql-$version-arm64/COPYRIGHT" "$stage/LICENSE"
  for arch in $archs; do rm -rf "$work/build/postgresql-$version-$arch"; done
  mark_built "$id" "$from"
}

while read -r version sha; do
  [ -n "$version" ] || continue
  fetch "postgresql-$version.tar.bz2" "https://ftp.postgresql.org/pub/source/v$version/postgresql-$version.tar.bz2" "$sha"
  echo "PostgreSQL $version"
  postgres "$version" "postgresql-$version.tar.bz2 $sha patches $(patched "postgresql-$version"); $openssl_from; $compression_from"
done <<< "$postgres_versions"

# MARK: - MySQL and MariaDB

# MySQL: one universal build. The helpers the build runs (error messages, character set tables)
# run natively, and the targets are just the two client programs, linked with the client
# library. Sources CMake picks for the host's CPU only (zstd's x86_64 assembly) are turned off.
# MariaDB picks code and defines per CPU throughout, so it builds once per architecture: natively
# first, then cross-compiled with the native build's helpers (IMPORT_EXECUTABLES).
# cmake_client <id> <what it's built from> <tarball> <folder> <universal|split> <targets…> -- <arguments…>
cmake_client() {
  local id="$1" from="$2" tarball="$3" dir="$4" layout="$5"
  shift 5
  local targets=() args=()
  while [ "$1" != -- ]; do targets+=("$1"); shift; done
  shift
  args=("$@")
  local stage="$work/stage/$id"
  is_built "$id" "$from" && return
  rm -rf "$stage" && mkdir -p "$stage"
  unpack "$tarball" "$dir"
  # cmake_build <folder> <architectures> [arguments]
  cmake_build() {
    local folder="$1" architectures="$2"
    shift 2
    mkdir -p "$work/build/$dir/$folder"
    (
      cd "$work/build/$dir/$folder"
      "$cmake_bin" .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$architectures" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,$deps/lib" -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,$deps/lib" \
        -DWITH_SSL="$deps" -DOPENSSL_ROOT_DIR="$deps" -DWITH_ZLIB=bundled -DWITH_UNIT_TESTS=OFF \
        "${args[@]}" "$@" >"$work/build/$dir-$folder.cmake.log" 2>&1 || { tail -60 "$work/build/$dir-$folder.cmake.log"; exit 1; }
      "$cmake_bin" --build . -j "$jobs" --target "${targets[@]}" >"$work/build/$dir-$folder.make.log" 2>&1 \
        || { grep -E "error|Error" "$work/build/$dir-$folder.make.log" | head -40; tail -20 "$work/build/$dir-$folder.make.log"; exit 1; }
    )
  }
  built() { find "$work/build/$dir/$1" -type f -perm -u+x -name "$2" | head -1; }
  local tool
  if [ "$layout" = universal ]; then
    cmake_build out "arm64;x86_64"
    for tool in "${targets[@]}"; do cp "$(built out "$tool")" "$stage/$tool"; done
  else
    local other=x86_64
    [ "$host_arch" = x86_64 ] && other=arm64
    cmake_build "out-$host_arch" "$host_arch"
    "$cmake_bin" --build "$work/build/$dir/out-$host_arch" --target import_executables >/dev/null
    cmake_build "out-$other" "$other" -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$other" \
      -DIMPORT_EXECUTABLES="$work/build/$dir/out-$host_arch/import_executables.cmake"
    for tool in "${targets[@]}"; do
      lipo -create "$(built "out-$host_arch" "$tool")" "$(built "out-$other" "$tool")" -output "$stage/$tool"
    done
  fi
  for tool in "${targets[@]}"; do relink "$stage/$tool"; done
}

fetch "${mysql57[@]}"
echo "MySQL 5.7"
mysql57_from="${mysql57[0]} ${mysql57[2]} patches $(patched mysql-5.7); $openssl_from; $cmake_from"
# (5.7's WITHOUT_SERVER wants storage/ndb, which the source archive lacks; only the two targets
# are built anyway.)
cmake_client mysql-5.7 "$mysql57_from" "${mysql57[0]}" mysql-5.7 universal mysqldump mysql -- \
  -DWITH_EMBEDDED_SERVER=OFF -DWITH_BOOST=../boost -DWITH_EDITLINE=bundled -DWITH_LZ4=bundled \
  -DCMAKE_CXX_STANDARD=11 -DCMAKE_CXX_FLAGS="-Wno-register -Wno-deprecated-declarations -Wno-enum-constexpr-conversion" \
  -DCMAKE_C_FLAGS="-Wno-implicit-function-declaration -Wno-incompatible-function-pointer-types -Wno-int-conversion"
if ! is_built mysql-5.7 "$mysql57_from"; then
  cp "$work/build/mysql-5.7/LICENSE" "$work/stage/mysql-5.7/LICENSE"
  rm -rf "$work/build/mysql-5.7"
  mark_built mysql-5.7 "$mysql57_from"
fi

fetch "${mysql80[@]}" "$mysql80_archive"
echo "MySQL 8.0"
mysql80_from="${mysql80[0]} ${mysql80[2]} patches $(patched mysql-8.0); $openssl_from; $cmake_from"
cmake_client mysql-8.0 "$mysql80_from" "${mysql80[0]}" mysql-8.0 universal mysqldump mysql -- \
  -DWITHOUT_SERVER=ON -DWITH_BOOST=../boost -DWITH_EDITLINE=bundled -DWITH_ZSTD=bundled -DWITH_LZ4=bundled \
  -DWITH_FIDO=none -DWITH_AUTHENTICATION_LDAP=OFF -DWITH_AUTHENTICATION_KERBEROS=OFF -DWITH_ROUTER=OFF \
  -DWITH_ICU=bundled -DWITH_PROTOBUF=bundled -DWITH_RAPIDJSON=bundled \
  -DCMAKE_C_FLAGS=-DZSTD_DISABLE_ASM -DCMAKE_CXX_FLAGS=-DZSTD_DISABLE_ASM
if ! is_built mysql-8.0 "$mysql80_from"; then
  cp "$work/build/mysql-8.0/LICENSE" "$work/stage/mysql-8.0/LICENSE"
  rm -rf "$work/build/mysql-8.0"
  mark_built mysql-8.0 "$mysql80_from"
fi

fetch "${mariadb[@]}"
echo "MariaDB 12.3"
mariadb_from="${mariadb[0]} ${mariadb[2]} patches $(patched mariadb-12.3); $openssl_from; $cmake_from"
# The client's authentication plugins are built in, so nothing is loaded from a plugin folder.
cmake_client mariadb-12.3 "$mariadb_from" "${mariadb[0]}" mariadb-12.3 split mariadb-dump mariadb -- \
  -DWITHOUT_SERVER=ON -DWITH_READLINE=OFF -DWITH_LIBEDIT=OFF -DCONC_WITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF \
  -DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC -DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC -DCLIENT_PLUGIN_CLIENT_ED25519=STATIC \
  -DCLIENT_PLUGIN_PARSEC=STATIC -DCLIENT_PLUGIN_DIALOG=STATIC -DCLIENT_PLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
  -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF -DCLIENT_PLUGIN_REMOTE_IO=OFF -DPLUGIN_AUTH_GSSAPI=NO -DWITH_SAFEMALLOC=OFF
if ! is_built mariadb-12.3 "$mariadb_from"; then
  cp "$work/build/mariadb-12.3/COPYING" "$work/stage/mariadb-12.3/LICENSE"
  rm -rf "$work/build/mariadb-12.3"
  mark_built mariadb-12.3 "$mariadb_from"
fi

# MARK: - Output

rm -rf "$out"
mkdir -p "$out/lib" "$out/Licenses"
cp "$deps/lib/libssl.3.dylib" "$deps/lib/libcrypto.3.dylib" "$work/stage/postgresql-18/libpq.5.dylib" "$out/lib/"
manifest="["
add_kit() { # built id product version family tools…
  local built="$1" id="$2" product="$3" version="$4" family="$5"
  shift 5
  mkdir -p "$out/$id"
  local tool list=""
  for tool in "$@"; do
    cp "$work/stage/$built/$tool" "$out/$id/"
    list="$list${list:+,}\"$tool\""
  done
  cp "$work/stage/$built/LICENSE" "$out/Licenses/$product-$id.txt"
  [ "$manifest" = "[" ] || manifest="$manifest,"
  manifest="$manifest
  {\"id\":\"$id\",\"product\":\"$product\",\"version\":[${version//./,}],\"family\":\"$family\",\"tools\":[$list]}"
}
while read -r version sha; do
  [ -n "$version" ] || continue
  add_kit "postgresql-${version%%.*}" "postgresql-${version%%.*}" PostgreSQL "$version" postgres pg_dump pg_restore psql
done <<< "$postgres_versions"
add_kit mysql-5.7 mysql-57 MySQL 5.7.44 mysql mysqldump mysql
add_kit mysql-8.0 mysql-80 MySQL 8.0.46 mysql mysqldump mysql
add_kit mariadb-12.3 mariadb-123 MariaDB 12.3.3 mysql mariadb-dump mariadb
printf '%s\n]\n' "$manifest" > "$out/tools.json"
# One PostgreSQL licence is enough; the kits share it.
for f in "$out"/Licenses/PostgreSQL-*.txt; do [ "$f" = "$out/Licenses/PostgreSQL-postgresql-18.txt" ] || rm "$f"; done
mv "$out/Licenses/PostgreSQL-postgresql-18.txt" "$out/Licenses/PostgreSQL.txt"
mv "$out/Licenses/MySQL-mysql-80.txt" "$out/Licenses/MySQL-8.0.txt"
mv "$out/Licenses/MySQL-mysql-57.txt" "$out/Licenses/MySQL-5.7.txt"
mv "$out/Licenses/MariaDB-mariadb-123.txt" "$out/Licenses/MariaDB.txt"
tar -xOf "$work/dl/${openssl[0]}" openssl-3.5.9/LICENSE.txt > "$out/Licenses/OpenSSL.txt"
tar -xOf "$work/dl/${zstd[0]}" zstd-1.5.7/LICENSE > "$out/Licenses/zstd.txt"
tar -xOf "$work/dl/${lz4[0]}" lz4-1.10.0/lib/LICENSE > "$out/Licenses/lz4.txt"
{
  echo "The client tools in this folder were built by scripts/build-tools.sh from these source"
  echo "archives, unchanged except for the patches in scripts/tools-patches (if any). MySQL and"
  echo "MariaDB are under the GNU GPL version 2; their source is available from these addresses."
  echo
  awk '/^[^ ]/ { skip = /^cmake-/ } !skip' "$sources"
} > "$out/Licenses/SOURCES.txt"

# Check: universal, and nothing linked from outside the folder or the system.
status=0
for f in "$out"/lib/* "$out"/*/*; do
  case "$f" in "$out/Licenses/"*|"$out/tools.json") continue ;; esac
  archs_found="$(lipo -archs "$f")"
  [ "$archs_found" = "x86_64 arm64" ] || [ "$archs_found" = "arm64 x86_64" ] || { echo "error: $f is $archs_found" >&2; status=1; }
  for arch in $archs; do
    bad="$(otool -arch "$arch" -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(@rpath/|/usr/lib/|/System/)' || true)"
    [ -z "$bad" ] || { echo "error: $f ($arch) links $bad" >&2; status=1; }
  done
done
[ "$status" = 0 ] || exit 1
for tool in "$out"/postgresql-*/* "$out"/mysql-*/* "$out"/mariadb-*/*; do
  printf '%s: %s\n' "${tool#"$out"/}" "$("$tool" --version 2>&1 | head -1)"
done
echo "$stamp" > "$out/.stamp"
du -sh "$out"
