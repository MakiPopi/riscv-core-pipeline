// Insertion sort of 128 pseudo-random words, with a self-check.
// Returns 0 if the result is correct, 1 if the sum changed, 2 if the array is not sorted.
#define N 128

static unsigned int a[N];

// xorshift32: a random-looking sequence from shifts and xors only (no multiply)
static unsigned int next(unsigned int x) {
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return x;
}

int main(void) {
  unsigned int x = 12345, sum_before = 0, sum_after = 0;

  for (int i = 0; i < N; i++) {
    x = next(x);
    a[i] = x;
    sum_before += x;
  }

  for (int i = 1; i < N; i++) {
    unsigned int key = a[i];
    int j = i - 1;
    while (j >= 0 && a[j] > key) {
      a[j + 1] = a[j];
      j--;
    }
    a[j + 1] = key;
  }

  for (int i = 0; i < N; i++) sum_after += a[i];
  if (sum_before != sum_after) return 1;
  for (int i = 1; i < N; i++)
    if (a[i - 1] > a[i]) return 2;
  return 0;
}
