#!/bin/bash -eu
# Copyright 2016 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
##############################################################################

# Create a directory for instrumented dependencies.
TOR_DEPS=${SRC}/deps
mkdir -p $TOR_DEPS

# Build libevent with proper instrumentation.
cd ${SRC}/libevent
sh autogen.sh
./configure --prefix=${TOR_DEPS}
make -j$(nproc) clean
make -j$(nproc) all
make install

# Build OpenSSL with proper instrumentation.
cd ${SRC}/openssl
OPENSSL_CONFIGURE_FLAGS=""
if [[ $CFLAGS = *sanitize=memory* ]]
then
  OPENSSL_CONFIGURE_FLAGS="no-asm"
fi

./config no-shared --prefix=${TOR_DEPS} \
    enable-tls1_3 enable-rc5 enable-md2 enable-ec_nistp_64_gcc_128 enable-ssl3 \
    enable-ssl3-method enable-nextprotoneg enable-weak-ssl-ciphers $CFLAGS \
    -fno-sanitize=alignment $OPENSSL_CONFIGURE_FLAGS

make -j$(nproc) LDCMD="$CXX $CXXFLAGS"
make install

# Build zlib with proper instrumentation,
cd ${SRC}/zlib
./configure --prefix=${TOR_DEPS}
make -j$(nproc) clean
make -j$(nproc) all
make install

# Build tor and the fuzz targets.
cd ${SRC}/tor

sh autogen.sh

# We need to run configure with leak-checking disabled, or many of the
# test functions will fail.
export ASAN_OPTIONS=detect_leaks=0

./configure --disable-asciidoc --enable-oss-fuzz --disable-memory-sentinels \
    --with-libevent-dir=${SRC}/deps \
    --with-openssl-dir=${SRC}/deps \
    --with-zlib-dir=${SRC}/deps \
    --disable-gcc-hardening

make clean
make -j$(nproc) oss-fuzz-fuzzers

TORLIBS="src/or/libtor-testing.a"
TORLIBS="$TORLIBS src/common/libor-crypto-testing.a"
TORLIBS="$TORLIBS src/ext/keccak-tiny/libkeccak-tiny.a"
TORLIBS="$TORLIBS src/common/libcurve25519_donna.a"
TORLIBS="$TORLIBS src/ext/ed25519/ref10/libed25519_ref10.a"
TORLIBS="$TORLIBS src/ext/ed25519/donna/libed25519_donna.a"
TORLIBS="$TORLIBS src/common/libor-testing.a"
TORLIBS="$TORLIBS src/common/libor-ctime-testing.a"
TORLIBS="$TORLIBS src/common/libor-event-testing.a"
TORLIBS="$TORLIBS src/trunnel/libor-trunnel-testing.a"
TORLIBS="$TORLIBS -lm -Wl,-Bstatic -lssl -lcrypto -levent -lz -L${TOR_DEPS}/lib"
TORLIBS="$TORLIBS -Wl,-Bdynamic"

for fuzzer in src/test/fuzz/*.a; do
    output="${fuzzer%.a}"
    output="${output##*lib}"
    ${CXX} ${CXXFLAGS} -std=c++11 -lFuzzingEngine ${fuzzer} ${TORLIBS} -o ${OUT}/${output}

    corpus_dir="${SRC}/tor-fuzz-corpora/${output#oss-fuzz-}"
    if [ -d "${corpus_dir}" ]; then
      zip -j ${OUT}/${output}_seed_corpus.zip ${corpus_dir}/*
    fi
done
