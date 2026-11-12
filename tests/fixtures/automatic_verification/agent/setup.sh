set -eu
test ! -e tests
clang sum.c -o sum
./sum
