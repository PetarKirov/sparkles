import { Effect, Context } from 'effect';
import { run, bench, group } from 'mitata';

const ITERS = 10_000_000;

class NativeEnv {
  constructor(
    public a: number,
    public b: number,
    public c: number,
  ) {}
}

function runNative(env: NativeEnv): number {
  let sum = 0;
  for (let i = 0; i < ITERS; i++) {
    sum += env.a + env.b + env.c;
  }
  return sum;
}

class CapA extends Context.Tag('CapA')<CapA, { readonly v: number }>() {}
class CapB extends Context.Tag('CapB')<CapB, { readonly v: number }>() {}
class CapC extends Context.Tag('CapC')<CapC, { readonly v: number }>() {}

const compute = Effect.gen(function* () {
  const a = yield* CapA;
  const b = yield* CapB;
  const c = yield* CapC;
  return a.v + b.v + c.v;
});

function runEffectTS(): number {
  const program = Effect.loop(0, {
    step: i => i + 1,
    while: i => i < ITERS,
    body: () => compute,
    discard: true,
  });

  const runnable = Effect.provide(
    program,
    Context.empty().pipe(
      Context.add(CapA, { v: 1 }),
      Context.add(CapB, { v: 2 }),
      Context.add(CapC, { v: 3 }),
    ),
  );

  Effect.runSync(runnable);
  return 0;
}

group(`Effect System Overhead (${ITERS} iters)`, () => {
  bench('TypeScript (Native)', () => {
    runNative(new NativeEnv(1, 2, 3));
  }).baseline();

  bench('TypeScript (Effect-TS)', () => {
    runEffectTS();
  });
});

const main = async () => {
  await run({
    colors: false,
    format: 'mitata',
  });
};

main();
