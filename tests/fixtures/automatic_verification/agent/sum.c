#include <stdio.h>

int main(void) {
    long total = 0;
    for (int i = 1; i <= 100; ++i) total += i;
    printf("%ld\n", total);
    return 0;
}
