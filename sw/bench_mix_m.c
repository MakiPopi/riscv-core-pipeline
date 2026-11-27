// Kernels that need multiply, divide and remainder (built for rv32im). Self-checking: returns 0 on success,
// 1/2/3 if the matrix checksum / the gcd sum / the signed division sum is wrong. Expected values come from an
// independent Python model with C semantics (unsigned wraparound, signed division truncating toward zero).
#define N 12

static unsigned int A[N][N], B[N][N], C[N][N];

static unsigned int next(unsigned int x) {      // xorshift32
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return x;
}

static unsigned int gcd(unsigned int a, unsigned int b) {   // Euclid: one remainder per step
  while (b != 0) {
    unsigned int t = a % b;
    a = b;
    b = t;
  }
  return a;
}

int main(void) {
  unsigned int x = 2463534242u;

  // 1. 12x12 matrix multiply: 1728 multiplies
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) {
      x = next(x); A[i][j] = x & 0xFFFF;
      x = next(x); B[i][j] = x & 0xFFFF;
    }
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) {
      unsigned int acc = 0;
      for (int k = 0; k < N; k++) acc += A[i][k] * B[k][j];
      C[i][j] = acc;
    }
  unsigned int csum = 0;
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) csum += C[i][j];

  // 2. gcd of 300 pairs: 3442 remainders in total
  unsigned int gsum = 0;
  for (int i = 0; i < 300; i++) {
    x = next(x);
    unsigned int a = (x & 0xFFFFF) + 1;
    x = next(x);
    unsigned int b = (x & 0xFFFFF) + 1;
    gsum += gcd(a, b);
  }

  // 3. signed division and remainder by a divisor the compiler cannot know (3..10), negative dividends half the time
  unsigned int ssum = 0;
  for (int k = 0; k < 300; k++) {
    x = next(x);
    int v = (int)x;
    int d = (int)((x >> 28) & 7) + 3;
    ssum += (unsigned int)(v / d) + (unsigned int)(v % d);
  }

  if (csum != 0xa6343a77u) return 1;
  if (gsum != 1308u) return 2;
  if (ssum != 0xcd1d90fbu) return 3;
  return 0;
}
