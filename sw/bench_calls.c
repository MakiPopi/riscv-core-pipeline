// Calls and returns: recursive fib(18) = 2584 (8361 calls), then 400 calls through a table of
// function pointers, checked against the same computation written as an if-chain.
// Returns 0 on success, 1 if fib is wrong, 2 if the two computations differ.
typedef unsigned int (*op_t)(unsigned int);

static unsigned int __attribute__((noinline)) fib(unsigned int n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

static unsigned int __attribute__((noinline)) op_add(unsigned int x) { return x + 7; }
static unsigned int __attribute__((noinline)) op_xor(unsigned int x) { return x ^ 0x5a5a; }
static unsigned int __attribute__((noinline)) op_rot(unsigned int x) { return (x << 3) | (x >> 29); }
static unsigned int __attribute__((noinline)) op_sub(unsigned int x) { return x - 3; }

// volatile: the compiler must load the pointer each time, so these stay real indirect calls
static op_t volatile ops[4] = {op_add, op_xor, op_rot, op_sub};

int main(void) {
  if (fib(18) != 2584) return 1;

  unsigned int via_table = 1, via_chain = 1;
  for (unsigned int i = 0; i < 400; i++) {
    via_table = ops[i & 3](via_table);
    unsigned int k = i & 3;
    if (k == 0)      via_chain = via_chain + 7;
    else if (k == 1) via_chain = via_chain ^ 0x5a5a;
    else if (k == 2) via_chain = (via_chain << 3) | (via_chain >> 29);
    else             via_chain = via_chain - 3;
  }
  return via_table == via_chain ? 0 : 2;
}
