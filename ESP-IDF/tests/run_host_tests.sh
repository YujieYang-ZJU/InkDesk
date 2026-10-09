#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkdesk-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cc -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -fsanitize=address,undefined -g \
  -I"$root/main" -I"$root/main/vendor" \
  "$root/main/protocol.c" "$root/main/sha256.c" "$root/main/vendor/cJSON.c" "$root/tests/protocol_test.c" \
  -o "$test_dir/protocol_test" -lm
"$test_dir/protocol_test"
cc -shared -fPIC -std=c11 "$root/main/sha256.c" -o "$test_dir/libsha256.dylib"
python3 - "$test_dir/libsha256.dylib" <<'PY'
import ctypes, hashlib, random, sys
lib = ctypes.CDLL(sys.argv[1])
lib.ink_sha256_hex.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
rng = random.Random(8179)
for size in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1024, 48000]:
    data = rng.randbytes(size)
    output = ctypes.create_string_buffer(65)
    lib.ink_sha256_hex(data, size, output)
    assert output.value.decode() == hashlib.sha256(data).hexdigest(), size
print('SHA-256 independently agrees with Python hashlib, including a 48,000-byte frame.')
PY
