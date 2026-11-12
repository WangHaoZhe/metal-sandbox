set -eu
mkdir runtime
cp ../sum.c runtime/sum.c
clang runtime/sum.c -o runtime/sum
actual=$(runtime/sum)
test "$actual" = 5050
printf '{"sum":%s}\n' "$actual" > metrics.json
printf 'sum=%s\n' "$actual"
