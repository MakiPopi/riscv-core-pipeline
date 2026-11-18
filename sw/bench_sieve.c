// Sieve of Eratosthenes below 1000, with a self-check against the known answers:
// 168 primes, largest 997, sum 76127. Returns 0 on success, 1/2/3 for a wrong count/largest/sum.
#define N 1000

static unsigned char composite[N];

int main(void) {
  unsigned int count = 0, largest = 0, sum = 0;
  for (unsigned int i = 2; i < N; i++) {
    if (!composite[i]) {
      count++;
      largest = i;
      sum += i;
      for (unsigned int j = i + i; j < N; j += i) composite[j] = 1;
    }
  }
  if (count != 168) return 1;
  if (largest != 997) return 2;
  if (sum != 76127) return 3;
  return 0;
}
