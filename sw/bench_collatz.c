// Collatz ("3n+1") steps for every start value 1..100. The branch on n & 1 depends on the data and
// is hard to predict. Known answers: 27 takes 111 steps, 97 takes 118 (the longest below 100), and the
// total is 3142. Returns 0 on success, 1/2/3 for a wrong steps(27) / longest / total.
int main(void) {
  unsigned int total = 0, best = 0, best_n = 0, steps27 = 0;

  for (unsigned int start = 1; start <= 100; start++) {
    unsigned int n = start, steps = 0;
    while (n != 1) {
      if (n & 1) n = (n << 1) + n + 1;   // 3n + 1 without a multiply
      else       n >>= 1;
      steps++;
    }
    total += steps;
    if (steps > best) { best = steps; best_n = start; }
    if (start == 27) steps27 = steps;
  }

  if (steps27 != 111) return 1;
  if (best != 118 || best_n != 97) return 2;
  if (total != 3142) return 3;
  return 0;
}
